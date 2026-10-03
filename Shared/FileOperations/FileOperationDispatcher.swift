import Foundation
import os

/// A sensitive action the user can be asked to confirm before it runs
/// (`FilePermissionSettings.confirmDestructiveActions`, P7).
enum DestructiveAction: Equatable, Sendable {
    case lock(count: Int)
    case unlock(count: Int)
    case cutMove(count: Int)

    /// What the confirmation dialog names as the action.
    var titleKey: StringKey {
        switch self {
        case .lock: return .confirmDestructiveLock
        case .unlock: return .confirmDestructiveUnlock
        case .cutMove: return .confirmDestructiveCut
        }
    }

    var itemCount: Int {
        switch self {
        case .lock(let count), .unlock(let count), .cutMove(let count): return count
        }
    }
}

/// Asks the user to confirm a sensitive action.
///
/// Implemented by the main app (`DestructiveActionPrompter`); tests inject a
/// script. Like `ArchivePasswordPrompting` this is an injected seam, so the
/// dispatcher stays AppKit-free and headless-testable.
protocol DestructiveActionConfirming: Sendable {
    /// True when the user confirmed and the action may run.
    func confirm(_ action: DestructiveAction) -> Bool
}

/// **P5-1** Main-App-side dispatcher for file-operation requests received over
/// the App-Group Unix socket from the FinderSync extension.
///
/// Re-establishes authorization for every requested path BEFORE any
/// filesystem write:
///
///   incoming path
///     → standardized URL
///     → ancestor match against authorized folders
///     → resolve bookmark
///     → startAccessingSecurityScopedResource()
///     → run operation
///     → stopAccessingSecurityScopedResource() (deferred)
///
/// The dispatcher never trusts a claim from the extension; it re-resolves
/// the bookmark and re-validates the path. It also never accepts arbitrary
/// paths outside the authorized set, even for "reads", because there are no
/// reads in P5-1 — every operation is a write.
///
/// This file deliberately has NO AppKit dependency so it is unit-testable
/// headlessly. The test target injects an in-memory `FolderAuthorizationStore`
/// and a `ScopedAccessConfiguration` that bypasses real bookmarks.
/// `@unchecked Sendable`: the stored dependencies are immutable `let`s and the
/// dispatcher holds no per-request state; each `dispatch(payload:)` call is
/// independent. It is called from the server's concurrent connection queue.
public final class FileOperationDispatcher: @unchecked Sendable {

    public static let log = Logger(subsystem: "xin.ljhsu.MenuRight", category: "main-file-op")

    private let store: FolderAuthorizationStore?
    private let scopedConfig: ScopedAccessConfiguration
    private let opener: SystemOpener
    /// Where the blank Pages/Numbers/Keynote templates live (P6-b). Injectable
    /// because the unit tests must never depend on the app bundle's contents.
    private let templateDirectory: URL?
    /// Archive policy (P9) — conflict handling, size limit, metadata skipping.
    /// Injectable so a test never has to write the user's real settings.
    private let archiveSettings: () -> ArchiveSettings
    /// 文件权限 (`allowedActions` is consumed by the extension; the two safety
    /// switches are enforced here). Same closure seam as `archiveSettings` so
    /// tests inject a policy instead of writing the user's real settings.
    private let filePermissions: () -> FilePermissionSettings
    /// 终端应用 (P6): which terminal 打开终端 launches, and through which Finder
    /// service. Read per request so a settings change applies to the next action.
    private let generalSettings: () -> GeneralSettings
    /// 新建文件 (P6/P7): base name, enabled kinds and the optional template
    /// folder override.
    private let newFileSettings: () -> NewFileSettings
    /// Asks the user to confirm a sensitive action (`confirmDestructiveActions`).
    /// `nil` means "nobody can ask" — the setting only adds a prompt, so the
    /// action still runs.
    private let destructiveConfirmation: (any DestructiveActionConfirming)?
    /// "解压到指定位置…" needs a folder picker. It is a closure so this type
    /// stays Foundation-only and headless-testable; the app injects the AppKit
    /// panel (see `MainAppIPCServer`), tests inject a temp directory.
    private let folderChooser: () -> URL?
    /// Where an encrypted archive's password comes from. Like `folderChooser`,
    /// this is an injected seam: the main app hooks up the prompt + password book
    /// (`ArchivePasswordPrompter`), tests inject a script, and nothing here touches
    /// AppKit. `nil` means "nobody can ask", which reports an encrypted archive
    /// honestly instead of guessing a password.
    private let archivePasswordPrompting: (any ArchivePasswordPrompting)?

    init(
        store: FolderAuthorizationStore? = FolderAuthorizationStore.appGroupDefault(),
        scopedConfig: ScopedAccessConfiguration = .system,
        opener: SystemOpener = .system,
        templateDirectory: URL? = DocumentTemplateCatalog.bundledDirectory,
        archiveSettings: @escaping () -> ArchiveSettings = { SettingsStore.shared.settings.archives },
        filePermissions: @escaping () -> FilePermissionSettings = { SettingsStore.shared.settings.filePermissions },
        generalSettings: @escaping () -> GeneralSettings = { SettingsStore.shared.settings.general },
        newFileSettings: @escaping () -> NewFileSettings = { SettingsStore.shared.settings.newFile },
        folderChooser: @escaping () -> URL? = { nil },
        archivePasswordPrompting: (any ArchivePasswordPrompting)? = nil,
        destructiveConfirmation: (any DestructiveActionConfirming)? = nil
    ) {
        self.store = store
        self.scopedConfig = scopedConfig
        self.opener = opener
        self.templateDirectory = templateDirectory
        self.archiveSettings = archiveSettings
        self.filePermissions = filePermissions
        self.generalSettings = generalSettings
        self.newFileSettings = newFileSettings
        self.folderChooser = folderChooser
        self.archivePasswordPrompting = archivePasswordPrompting
        self.destructiveConfirmation = destructiveConfirmation
    }

    // MARK: - Settings-driven seams

    /// `restrictToAuthorizedFolders` (P7 — "仅在已授权的文件夹内创建或修改文件").
    ///
    /// On (the default) every mutating request must name a path covered by an
    /// authorized folder. Off means MenuRight stops refusing those paths up
    /// front: it attempts the operation, still going through a bookmark when one
    /// covers the target, and otherwise lets the macOS sandbox decide — which is
    /// exactly what the settings pane's footer says.
    private var restrictsToAuthorizedFolders: Bool {
        filePermissions().restrictToAuthorizedFolders
    }

    /// The terminal `打开终端` should use: the configured app and service, or
    /// `SystemOpener.system` (Terminal) when the user kept the default.
    private func terminalOpener() -> SystemOpener {
        let general = generalSettings()
        guard general.usesCustomTerminal else { return opener }
        let configuredURL = general.terminalApplicationURL
        // A configured-but-missing app (moved to the trash) falls back to the
        // built-in default rather than failing the click.
        if let configuredURL, !FileManager.default.fileExists(atPath: configuredURL.path) {
            Self.log.info("DISPATCH terminal app missing path=\(configuredURL.path, privacy: .public) — using default")
            return opener
        }
        return opener.reconfigured(
            terminalURL: configuredURL,
            serviceName: general.effectiveTerminalServiceName
        )
    }

    /// Runs `body` with the template folder for this request: the user's override
    /// (with its security-scoped access held for the whole call) when it is
    /// reachable, otherwise the injected default (the app bundle's copy).
    ///
    /// The override folder is outside the container, so the access has to be held
    /// across the read *and* the copy — an "is it usable" check that stopped the
    /// access again would leave the copy unauthorized and fail the request with a
    /// sandbox error instead of falling back.
    private func withTemplateDirectory<T>(
        of settings: NewFileSettings,
        _ body: (URL?) -> T
    ) -> T {
        if let scoped = DocumentTemplateCatalog.withOverrideDirectory(for: settings, body) {
            return scoped
        }
        return body(templateDirectory)
    }

    /// The shared `NOT_AUTHORIZED` pre-check (P7).
    ///
    /// Returns a failure when `restrictToAuthorizedFolders` is on and any target
    /// is not covered by an authorized folder; returns nil when the request may
    /// proceed. With the restriction off, MenuRight does not refuse the request
    /// here — `withAuthorization(s)` still uses a bookmark when one covers the
    /// target and otherwise lets the operation (and the sandbox) decide.
    private func scopeFailure(
        for targets: [URL],
        folders: [AuthorizedFolder],
        operation: String,
        cid: String?
    ) -> FileOperationContract.Response? {
        guard restrictsToAuthorizedFolders else {
            Self.log.info("DISPATCH \(operation, privacy: .public) scope-precheck-skipped (restrictToAuthorizedFolders=off) cid=\(cid ?? "<none>", privacy: .public)")
            return nil
        }
        for target in targets {
            if AuthorizedURLResolver.folderMatching(target, folders: folders) == nil {
                Self.log.info("DISPATCH \(operation, privacy: .public) NOT_AUTHORIZED target=\(target.path, privacy: .public) cid=\(cid ?? "<none>", privacy: .public)")
                return .failure(
                    code: .pathOutsideAuthorizedScope,
                    message: "Path outside any authorized folder: \(target.path)"
                )
            }
        }
        return nil
    }

    /// The confirmation gate (P7). Returns a failure when the user cancelled a
    /// sensitive action, nil when it may run.
    ///
    /// A cancelled confirmation is reported as `.cancelledByUser`, which the
    /// extension treats as a silent no-op in every handler that can reach here
    /// (see the `cancelledByUser` guards in `FinderSync`).
    private func confirmationFailure(for action: DestructiveAction) -> FileOperationContract.Response? {
        guard filePermissions().confirmDestructiveActions, let confirmation = destructiveConfirmation else {
            return nil
        }
        guard confirmation.confirm(action) else {
            Self.log.info("DISPATCH \(String(describing: action), privacy: .public) CANCELLED by user confirmation")
            return .failure(code: .cancelledByUser, message: "The user cancelled this action.")
        }
        return nil
    }

    // MARK: - Dispatch entry point

    /// Decode a request payload, validate it, run it, return a wire response.
    /// This function never throws: every failure mode is encoded in the
    /// returned `Response.failure` so the transport layer can reply with a
    /// single IPCProtocol.Response.
    /// `control` is non-nil only for archive work: it is how a 暂停/取消 from the
    /// progress window reaches the compressor that is already running.
    ///
    /// Not `public`: `ArchiveOperationControl` is process-internal, and this type
    /// is compiled straight into the app and test targets rather than imported as
    /// a module, so internal access is all either of them needs.
    func dispatch(
        payload: String?,
        control: ArchiveOperationControl? = nil
    ) -> FileOperationContract.Response {
        guard let request = FileOperationContract.Request.decode(fromIPC: payload) else {
            Self.log.error("DISPATCH malformed request payload (decode failed)")
            return .failure(code: .invalidRequest, message: "Malformed request payload")
        }
        Self.log.info("DISPATCH received kind=\(request.kind.rawValue, privacy: .public) cid=\(request.clientRequestId ?? "<none>", privacy: .public)")

        switch request.kind {
        case .createFile:
            return handleCreateFile(request: request)
        case .createDirectory:
            return handleCreateDirectory(request: request)
        case .moveItems:
            return handleMoveItems(request: request)
        case .createAlias:
            return handleCreateAlias(request: request)
        case .setLocked:
            return handleSetLocked(request: request)
        case .openTerminal:
            return handleOpenTerminal(request: request)
        case .createDocument:
            return handleCreateDocument(request: request)
        case .createFromTemplate:
            return handleCreateFromTemplate(request: request)
        case .openFolder:
            return handleOpenFolder(request: request)
        case .openApplication:
            return handleOpenApplication(request: request)
        case .openURL:
            return handleOpenURL(request: request)
        case .compressItems:
            return handleCompressItems(request: request, control: control)
        case .extractArchive:
            return handleExtractArchive(request: request, control: control)
        }
    }

    // MARK: - Single-target create operations

    private func handleCreateFile(request: FileOperationContract.Request) -> FileOperationContract.Response {
        guard let directoryRaw = request.args.directory,
              let name = request.args.name,
              !name.isEmpty else {
            return .failure(code: .invalidRequest, message: "createFile requires directory and name")
        }
        // `name` arrives over IPC: treat it as untrusted until proven a single,
        // representable path component.
        if let reason = Self.validateName(name) {
            Self.log.info("DISPATCH createFile REJECTED name cid=\(request.clientRequestId ?? "<none>", privacy: .public) reason=\(reason, privacy: .public)")
            return .failure(code: .invalidRequest, message: reason)
        }
        let directory = canonicalize(directoryRaw)
        guard let directory else {
            return .failure(code: .invalidRequest, message: "Invalid directory path")
        }
        let contents: Data?
        if let b64 = request.args.contentsBase64 {
            guard let data = Data(base64Encoded: b64) else {
                return .failure(code: .invalidRequest, message: "contentsBase64 is not valid base64")
            }
            contents = data
        } else {
            contents = nil
        }

        return createFile(
            in: directory,
            preferredName: name,
            request: request,
            operation: "createFile"
        ) {
            FileOperationService.createFile(in: directory, preferredName: name, contents: contents)
        }
    }

    /// **P6-b** Generates a Word/Excel/PowerPoint package and writes it like any
    /// other new file.
    ///
    /// The extension never sends document bytes for these kinds: it names the
    /// kind, and the archive writer (`ZipWriter`) plus the OOXML templates live
    /// in the main app only. The generated bytes still go through the same
    /// authorization gate as `createFile` — generation is not a trust boundary,
    /// the write is.
    private func handleCreateDocument(request: FileOperationContract.Request) -> FileOperationContract.Response {
        guard let directoryRaw = request.args.directory,
              let name = request.args.name,
              !name.isEmpty else {
            return .failure(code: .invalidRequest, message: "createDocument requires directory and name")
        }
        guard let rawKind = request.args.documentKind,
              let type = NewFileType(rawValue: rawKind) else {
            return .failure(code: .invalidRequest, message: "createDocument requires a known documentKind")
        }
        guard type.category == .office else {
            return .failure(
                code: .unsupportedDocumentKind,
                message: "“\(rawKind)” is not an OOXML document kind (expected docx, xlsx or pptx)"
            )
        }
        if let reason = Self.validateName(name) {
            Self.log.info("DISPATCH createDocument REJECTED name cid=\(request.clientRequestId ?? "<none>", privacy: .public) reason=\(reason, privacy: .public)")
            return .failure(code: .invalidRequest, message: reason)
        }
        guard let directory = canonicalize(directoryRaw) else {
            return .failure(code: .invalidRequest, message: "Invalid directory path")
        }

        let contents: Data
        do {
            contents = try OOXMLDocumentFactory.data(for: type)
        } catch {
            Self.log.error("DISPATCH createDocument GENERATION FAILED kind=\(rawKind, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return .failure(
                code: .unsupportedDocumentKind,
                message: "Could not generate a \(rawKind) document: \(String(describing: error))"
            )
        }

        return createFile(
            in: directory,
            preferredName: name,
            request: request,
            operation: "createDocument"
        ) {
            FileOperationService.createFile(in: directory, preferredName: name, contents: contents)
        }
    }

    /// **P6-b** Creates a Pages/Numbers/Keynote document by copying the blank
    /// template from the app bundle.
    ///
    /// Fails with `templateMissing` (not a generic error) when this build has no
    /// template for the kind, so the extension can say exactly what is wrong.
    /// The menu normally hides such kinds already — this is the belt to the
    /// availability payload's braces.
    private func handleCreateFromTemplate(request: FileOperationContract.Request) -> FileOperationContract.Response {
        guard let directoryRaw = request.args.directory,
              let name = request.args.name,
              !name.isEmpty else {
            return .failure(code: .invalidRequest, message: "createFromTemplate requires directory and name")
        }
        guard let rawKind = request.args.documentKind,
              let type = NewFileType(rawValue: rawKind) else {
            return .failure(code: .invalidRequest, message: "createFromTemplate requires a known documentKind")
        }
        guard type.category == .iWork else {
            return .failure(
                code: .unsupportedDocumentKind,
                message: "“\(rawKind)” is not a template-backed kind (expected pages, numbers or keynote)"
            )
        }
        // P7: the user may point the template folder at their own copy, which lives
        // outside the app's container. Everything that reads it — the "is the
        // template there" check and the copy in `createFile` — runs inside
        // `withTemplateDirectory`, so the override's security-scoped access is held
        // for the whole read. The app bundle's Templates folder is the fallback.
        return withTemplateDirectory(of: newFileSettings()) { directoryForTemplates in
            createTemplateBackedFile(
                type: type,
                rawKind: rawKind,
                name: name,
                directoryRaw: directoryRaw,
                directoryForTemplates: directoryForTemplates,
                request: request
            )
        }
    }

    /// The tail of `createFromTemplate`, split out so it can run while the
    /// override folder's security-scoped access is held (see
    /// `withTemplateDirectory(of:_:)`).
    private func createTemplateBackedFile(
        type: NewFileType,
        rawKind: String,
        name: String,
        directoryRaw: String,
        directoryForTemplates: URL?,
        request: FileOperationContract.Request
    ) -> FileOperationContract.Response {
        guard let template = DocumentTemplateCatalog.templateURL(for: type, in: directoryForTemplates) else {
            let expected = DocumentTemplateCatalog.templateFileName(for: type) ?? "<unknown>"
            Self.log.error("DISPATCH createFromTemplate TEMPLATE_MISSING kind=\(rawKind, privacy: .public) expected=\(expected, privacy: .public) directory=\(directoryForTemplates?.path ?? "<none>", privacy: .public)")
            return .failure(
                code: .templateMissing,
                message: "This build has no blank template for “\(rawKind)” (expected \(expected) in the app's Templates folder)."
            )
        }
        if let reason = Self.validateName(name) {
            Self.log.info("DISPATCH createFromTemplate REJECTED name cid=\(request.clientRequestId ?? "<none>", privacy: .public) reason=\(reason, privacy: .public)")
            return .failure(code: .invalidRequest, message: reason)
        }
        guard let directory = canonicalize(directoryRaw) else {
            return .failure(code: .invalidRequest, message: "Invalid directory path")
        }

        return createFile(
            in: directory,
            preferredName: name,
            request: request,
            operation: "createFromTemplate"
        ) {
            FileOperationService.createFileFromTemplate(template: template, in: directory, preferredName: name)
        }
    }

    // MARK: - P7-b: favorites

    /// Opens a favorite folder in Finder.
    ///
    /// Not gated on the authorization store, exactly like `openTerminal`: this
    /// app performs no filesystem work on the folder (Finder does), and gating
    /// would make every favorite fail in folders the user has not separately
    /// authorized. The path still has to *be* an existing directory, which is a
    /// shape check, not a permission check.
    private func handleOpenFolder(request: FileOperationContract.Request) -> FileOperationContract.Response {
        guard let raw = request.args.directory, let directory = canonicalize(raw) else {
            return .failure(code: .invalidRequest, message: "openFolder requires a directory")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(code: .invalidDestination, message: "“\(directory.path)” is not a folder.")
        }
        if let error = opener.openFolder(directory) {
            Self.log.error("DISPATCH openFolder FAILED path=\(directory.path, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return .failure(code: .openFailed, message: error.localizedDescription)
        }
        Self.log.info("DISPATCH openFolder SUCCESS path=\(directory.path, privacy: .public)")
        return .success(createdPath: nil)
    }

    /// Opens a favorite application by path or bundle identifier.
    ///
    /// Existence is checked here rather than while the menu is built: the
    /// extension must not scan for installed applications in `menu(for:)`, and a
    /// favorite whose app was uninstalled has to produce a clear message.
    private func handleOpenApplication(request: FileOperationContract.Request) -> FileOperationContract.Response {
        guard let raw = request.args.target?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .failure(code: .invalidRequest, message: "openApplication requires a target")
        }
        if raw.contains("/") {
            // A path target: reject a relative or traversal-shaped one before
            // LaunchServices sees it.
            guard raw.hasPrefix("/"), canonicalize(raw) != nil else {
                return .failure(code: .invalidRequest, message: "Invalid application path: \(raw)")
            }
        }
        if let error = opener.openApplication(raw) {
            Self.log.error("DISPATCH openApplication FAILED target=\(raw, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return .failure(code: .openFailed, message: error.localizedDescription)
        }
        Self.log.info("DISPATCH openApplication SUCCESS target=\(raw, privacy: .public)")
        return .success(createdPath: nil)
    }

    /// Opens a favorite website. Only http(s) with a host is accepted — a
    /// `file:`/custom scheme from a menu entry is not something this path should
    /// ever hand to LaunchServices, whatever the settings payload says.
    private func handleOpenURL(request: FileOperationContract.Request) -> FileOperationContract.Response {
        guard let raw = request.args.target,
              let url = Self.validatedWebURL(raw) else {
            return .failure(code: .invalidRequest, message: "openURL requires an http(s) URL with a host")
        }
        if let error = opener.openURL(url) {
            Self.log.error("DISPATCH openURL FAILED url=\(url.absoluteString, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return .failure(code: .openFailed, message: error.localizedDescription)
        }
        Self.log.info("DISPATCH openURL SUCCESS url=\(url.absoluteString, privacy: .public)")
        return .success(createdPath: nil)
    }

    // MARK: - P9: compression and extraction

    /// Compresses the selection into one archive next to it.
    ///
    /// Reads the source parents and writes the destination folder, so both sides
    /// go through the authorization gate. Format support is explicit: this build
    /// writes ZIP / TAR / TAR.GZ / TAR.BZ2, and anything else is
    /// `archiveUnsupported` rather than a silent fallback to ZIP.
    private func handleCompressItems(
        request: FileOperationContract.Request,
        control: ArchiveOperationControl?
    ) -> FileOperationContract.Response {
        guard let sourceRaws = request.args.sourcePaths, !sourceRaws.isEmpty else {
            return .failure(code: .invalidRequest, message: "compressItems requires non-empty sourcePaths")
        }
        let rawFormat = request.args.archiveFormat ?? ArchiveFormat.zip.rawValue
        guard let format = ArchiveFormat(rawValue: rawFormat), ArchiveCompressor.canWrite(format) else {
            return .failure(
                code: .archiveUnsupported,
                message: "This build cannot create “\(rawFormat)” archives (ZIP, 7Z, TAR, TAR.GZ and TAR.BZ2 are supported)."
            )
        }

        // 允许的压缩格式 filters the 压缩 ▸ menu, but a menu built before the
        // setting changed can still arrive, so the app re-checks it against its
        // own settings. The custom dialog is exempt: it names the format itself.
        if request.args.customize != true, !archiveSettings().isEnabled(format) {
            return .failure(
                code: .archiveUnsupported,
                message: "Creating “\(format.rawValue)” archives is turned off in the archive settings."
            )
        }

        var sources: [URL] = []
        sources.reserveCapacity(sourceRaws.count)
        for raw in sourceRaws {
            guard let url = canonicalize(raw) else {
                return .failure(code: .invalidRequest, message: "Invalid source path: \(raw)")
            }
            sources.append(url)
        }
        guard let destinationRaw = request.args.destinationDirectory,
              let destination = canonicalize(destinationRaw) else {
            return .failure(code: .invalidRequest, message: "compressItems requires destinationDirectory")
        }

        let folders = currentFolders()
        let scopeTargets = Self.scopeTargets(sources: sources, destination: destination)
        if let failure = scopeFailure(for: scopeTargets, folders: folders, operation: "compressItems", cid: request.clientRequestId) {
            return failure
        }

        if request.args.customize == true {
            // The dialog owns the write from here; the extension gets an accepted
            // reply and stays silent (there is no created path yet, by design).
            let dialogSources = sources
            let defaultName = request.args.name
                ?? ArchiveCompressor.preferredArchiveName(for: sources, format: format)
            let settings = archiveSettings()
            ArchiveRequestCenter.shared.present(PendingArchiveRequest(
                sources: dialogSources,
                directory: destination,
                name: defaultName,
                label: "",
                format: format,
                mode: .standard
            ))
            Self.log.info("DISPATCH compressItems DEFERRED to dialog cid=\(request.clientRequestId ?? "<none>", privacy: .public) settingsLimit=\(settings.sizeLimitMB, privacy: .public)")
            return .success(createdPath: nil)
        }

        let settings = archiveSettings()
        // Unknown values fall back to the defaults rather than failing: the
        // dialog is the only producer, and a missing knob must never turn into
        // "could not compress".
        let mode = request.args.archiveMode.flatMap(ArchiveCompressionMode.init(rawValue:)) ?? .standard
        let label = request.args.archiveLabel
        return withAuthorizations(to: scopeTargets, folders: folders, cid: request.clientRequestId) {
            let preferredName = request.args.name
                ?? ArchiveCompressor.preferredArchiveName(for: sources, format: format)
            do {
                let report = try ArchiveCompressor.compress(
                    sources,
                    into: destination,
                    preferredName: preferredName,
                    format: format,
                    conflictPolicy: settings.conflictPolicy,
                    sizeLimitMB: settings.sizeLimitMB,
                    mode: mode,
                    label: label,
                    control: control
                )
                Self.log.info(
                    "DISPATCH compressItems SUCCESS path=\(report.archiveURL.path, privacy: .public) format=\(format.rawValue, privacy: .public) entries=\(report.entryCount, privacy: .public) skippedSymlinks=\(report.skippedSymbolicLinks.count, privacy: .public)"
                )
                return FileOperationContract.Response.success(createdPath: report.archiveURL.path)
            } catch let error as ArchiveError {
                Self.log.info("DISPATCH compressItems FAILURE \(String(describing: error), privacy: .public)")
                return FileOperationContract.Response.failure(
                    code: Self.mapArchiveError(error),
                    message: Self.describe(error)
                )
            } catch {
                Self.log.error("DISPATCH compressItems UNEXPECTED error=\(String(describing: error), privacy: .public)")
                return FileOperationContract.Response.failure(code: .archiveFailed, message: error.localizedDescription)
            }
        }
    }

    /// A deferred write that failed before anything was written, with a reason
    /// the dialog can show as-is.
    ///
    /// `handleCompressItems` answers the extension with a `Response`, but the
    /// dialog's write happens minutes later from a button action, where there is
    /// no `ErrorCode` to map into text.
    struct CustomCompressionFailure: Error {
        let message: String
    }

    /// Runs the write the custom-compression dialog owns.
    ///
    /// `handleCompressItems` only *parks* the request (`ArchiveRequestCenter`), so
    /// the security-scoped access it validated is long gone by the time 确定 is
    /// pressed. Without taking it again here the sandbox refuses to read the
    /// sources — "you don't have permission to view it" — for every folder the
    /// user had authorized (reported 2026-10-03 for the dialog; the plain menu
    /// path always went through `withAuthorizations`).
    ///
    /// Throws `CustomCompressionFailure` for authorization problems and the
    /// `ArchiveError` from the compressor itself (including `.cancelled`).
    func performCustomCompression(
        sources: [URL],
        into destination: URL,
        preferredName: String,
        format: ArchiveFormat,
        mode: ArchiveCompressionMode,
        label: String?,
        password: String?,
        solid: Bool = true,
        encryptsFileNames: Bool = false,
        volumeSizeMB: Int? = nil,
        settings: ArchiveSettings,
        control: ArchiveOperationControl?
    ) throws -> ArchiveCompressor.Report {
        let folders = currentFolders()
        let scopeTargets = Self.scopeTargets(sources: sources, destination: destination)
        if restrictsToAuthorizedFolders {
            for target in scopeTargets where AuthorizedURLResolver.folderMatching(target, folders: folders) == nil {
                Self.log.info("DISPATCH customCompression NOT_AUTHORIZED target=\(target.path, privacy: .public)")
                throw CustomCompressionFailure(message: "Path outside any authorized folder: \(target.path)")
            }
        } else {
            Self.log.info("DISPATCH customCompression scope-precheck-skipped (restrictToAuthorizedFolders=off)")
        }
        // With the restriction off, hold only the bookmarks that cover a target;
        // when none does, compress without scoped access and let the sandbox decide.
        let accessTargets = restrictsToAuthorizedFolders
            ? scopeTargets
            : scopeTargets.filter { AuthorizedURLResolver.folderMatching($0, folders: folders) != nil }
        let compress: () throws -> ArchiveCompressor.Report = {
            let report = try ArchiveCompressor.compress(
                sources,
                into: destination,
                preferredName: preferredName,
                format: format,
                conflictPolicy: settings.conflictPolicy,
                sizeLimitMB: settings.sizeLimitMB,
                mode: mode,
                label: label,
                password: password,
                solid: solid,
                encryptsFileNames: encryptsFileNames,
                volumeSizeMB: volumeSizeMB,
                control: control
            )
            Self.log.info(
                "DISPATCH customCompression SUCCESS path=\(report.archiveURL.path, privacy: .public) format=\(format.rawValue, privacy: .public) entries=\(report.entryCount, privacy: .public)"
            )
            return report
        }
        do {
            guard !accessTargets.isEmpty else { return try compress() }
            return try FolderAuthorizationAccess.withAccesses(
                to: accessTargets,
                folders: folders,
                configuration: scopedConfig,
                persistRefreshedBookmark: persistenceHook()
            ) {
                try compress()
            }
        } catch let error as FolderAuthorizationError {
            Self.log.info("DISPATCH customCompression AUTH_FAILED error=\(String(describing: error), privacy: .public)")
            throw CustomCompressionFailure(message: Self.describe(error))
        }
    }

    /// The directories an archive write touches: the destination plus the parent
    /// of every source. Each one needs its own security-scoped access.
    static func scopeTargets(sources: [URL], destination: URL) -> [URL] {
        Array(Set(([destination] + sources.map { $0.deletingLastPathComponent() }).map(\.path)))
            .map { URL(fileURLWithPath: $0) }
    }

    /// Extracts one or more archives, each into its own folder unless a
    /// destination is given. Per-archive results: one bad archive must not stop
    /// the others.
    private func handleExtractArchive(
        request: FileOperationContract.Request,
        control: ArchiveOperationControl?
    ) -> FileOperationContract.Response {
        guard let sourceRaws = request.args.sourcePaths, !sourceRaws.isEmpty else {
            return .failure(code: .invalidRequest, message: "extractArchive requires non-empty sourcePaths")
        }
        var archives: [URL] = []
        archives.reserveCapacity(sourceRaws.count)
        for raw in sourceRaws {
            guard let url = canonicalize(raw) else {
                return .failure(code: .invalidRequest, message: "Invalid archive path: \(raw)")
            }
            archives.append(url)
        }

        var explicitDestination: URL?
        if request.args.customize == true {
            // 解压到指定位置…: the destination does not exist yet, so the picker
            // runs first and the authorization checks below apply to what the
            // user chose — never to a path the extension supplied.
            guard let chosen = folderChooser() else {
                Self.log.info("DISPATCH extractArchive CANCELLED (no destination chosen)")
                return .failure(code: .operationFailed, message: "No destination folder was chosen.")
            }
            explicitDestination = chosen.standardizedFileURL
        } else if let raw = request.args.destinationDirectory {
            guard let url = canonicalize(raw) else {
                return .failure(code: .invalidRequest, message: "Invalid destination path")
            }
            explicitDestination = url
        }

        let destinations = archives.map { explicitDestination ?? $0.deletingLastPathComponent() }
        let folders = currentFolders()
        let scopeTargets = Array(Set((archives.map { $0.deletingLastPathComponent() } + destinations).map(\.path)))
            .map { URL(fileURLWithPath: $0) }
        if let failure = scopeFailure(for: scopeTargets, folders: folders, operation: "extractArchive", cid: request.clientRequestId) {
            return failure
        }

        let settings = archiveSettings()
        return withAuthorizations(to: scopeTargets, folders: folders, cid: request.clientRequestId) {
            // Unlock every archive BEFORE writing anything. An encrypted archive
            // needs a password (from the password book, or from the user), and a
            // prompt dismissed halfway through a batch must not leave the earlier
            // archives half-extracted.
            var passwords: [Result<String?, ArchiveError>] = []
            passwords.reserveCapacity(archives.count)
            for archive in archives {
                do {
                    switch try ArchivePasswordResolver.resolve(
                        archiveURL: archive,
                        prompting: archivePasswordPrompting
                    ) {
                    case .notNeeded:
                        passwords.append(.success(nil))
                    case .resolved(let password):
                        passwords.append(.success(password))
                    case .abandoned:
                        Self.log.info("DISPATCH extractArchive CANCELLED archive=\(archive.path, privacy: .public) reason=password-prompt-abandoned")
                        // The extension treats this as "user changed their mind"
                        // and stays quiet — see the `cancelledByUser` guards in
                        // `FinderSync`.
                        return .failure(code: .cancelledByUser, message: "No password was given; nothing was extracted.")
                    }
                } catch let error as ArchiveError {
                    passwords.append(.failure(error))
                } catch {
                    passwords.append(.failure(.readFailed(error.localizedDescription)))
                }
            }

            var items: [FileOperationContract.ItemResult] = []
            items.reserveCapacity(archives.count)
            for (index, archive) in archives.enumerated() {
                let destination = destinations[index]
                guard case .success(let password) = passwords[index] else {
                    guard case .failure(let error) = passwords[index] else { continue }
                    Self.log.info("DISPATCH extractArchive FAILURE archive=\(archive.path, privacy: .public) \(String(describing: error), privacy: .public)")
                    items.append(FileOperationContract.ItemResult(
                        sourcePath: archive.path,
                        destinationPath: destination.path,
                        success: false,
                        errorCode: Self.mapArchiveError(error),
                        message: Self.describe(error)
                    ))
                    continue
                }
                do {
                    // Each archive owns an equal slice of the request's bar.
                    let sliceStart = Double(index) / Double(max(archives.count, 1))
                    let sliceEnd = Double(index + 1) / Double(max(archives.count, 1))
                    let (results, summary) = try ArchiveExtractor.extract(
                        archiveURL: archive,
                        to: destination,
                        settings: settings,
                        password: password,
                        control: control,
                        progressRange: sliceStart...sliceEnd
                    )
                    let unresolvable = results.first { result in
                        if case .failed = result.outcome { return true }
                        return false
                    }
                    // "Nothing was written" only means "failed" when the names were
                    // taken: that is the one case where the user asked for files and
                    // got none of them. An archive that carried nothing but
                    // `__MACOSX/` noise, symlinks or names the planner refuses is a
                    // success — it used to be reported as a `.nameCollision`, which
                    // sent the user looking for a conflict that never existed.
                    let conflictsOnly = Self.wroteNothingOnConflictsOnly(summary, results)
                    Self.log.info(
                        "DISPATCH extractArchive DONE archive=\(archive.path, privacy: .public) written=\(summary.written, privacy: .public) skipped=\(summary.skipped, privacy: .public) failed=\(summary.failed, privacy: .public)"
                    )
                    items.append(FileOperationContract.ItemResult(
                        sourcePath: archive.path,
                        destinationPath: destination.path,
                        success: summary.failed == 0 && !conflictsOnly,
                        errorCode: summary.failed > 0 ? .archiveFailed : (conflictsOnly ? .nameCollision : nil),
                        message: Self.summaryMessage(summary, unresolvable: unresolvable)
                    ))
                } catch let error as ArchiveError {
                    Self.log.info("DISPATCH extractArchive FAILURE archive=\(archive.path, privacy: .public) \(String(describing: error), privacy: .public)")
                    items.append(FileOperationContract.ItemResult(
                        sourcePath: archive.path,
                        destinationPath: destination.path,
                        success: false,
                        errorCode: Self.mapArchiveError(error),
                        message: Self.describe(error)
                    ))
                } catch {
                    Self.log.error("DISPATCH extractArchive UNEXPECTED archive=\(archive.path, privacy: .public) error=\(String(describing: error), privacy: .public)")
                    items.append(FileOperationContract.ItemResult(
                        sourcePath: archive.path,
                        destinationPath: destination.path,
                        success: false,
                        errorCode: .archiveFailed,
                        message: error.localizedDescription
                    ))
                }
            }
            return .batchSuccess(items: items)
        }
    }

    /// True when the archive carried entries, none was written, none failed, and
    /// every entry was left behind because its name was already taken.
    ///
    /// Deliberately strict: a mixture that includes a metadata or unsafe-path skip
    /// is not a collision, and calling it one would be a wrong error code. The
    /// caller only uses this to choose between "success" and `.nameCollision`;
    /// `summary.failed` already covers the failures.
    private static func wroteNothingOnConflictsOnly(
        _ summary: ArchiveExtractionSummary,
        _ results: [ArchiveEntryResult]
    ) -> Bool {
        guard summary.written == 0, summary.failed == 0, summary.skipped > 0 else { return false }
        return !results.isEmpty && results.allSatisfy { result in
            if case .skipped(.conflict) = result.outcome { return true }
            return false
        }
    }

    private static func summaryMessage(_ summary: ArchiveExtractionSummary, unresolvable: ArchiveEntryResult?) -> String? {
        guard summary.written == 0 || summary.failed > 0 || summary.skipped > 0 else { return nil }
        var parts = ["\(summary.written) written"]
        if summary.skipped > 0 { parts.append("\(summary.skipped) skipped") }
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        if let message = unresolvable?.outcome, case .failed(let reason) = message {
            parts.append(reason)
        }
        return parts.joined(separator: ", ")
    }

    /// Maps an archive failure onto the stable wire codes.
    static func mapArchiveError(_ error: ArchiveError) -> FileOperationContract.ErrorCode {
        switch error {
        case .unsupportedFormat, .notAnArchive, .encryptionUnsupported: return .archiveUnsupported
        case .unsafePath: return .archiveUnsafePath
        case .tooLarge: return .archiveTooLarge
        case .conflict: return .nameCollision
        case .cancelled: return .cancelledByUser
        case .readFailed, .writeFailed: return .archiveFailed
        // `passwordRequired` only escapes when nothing could ask for a password,
        // and `badPassword` when the user's answer was wrong; both are archive
        // problems from the extension's point of view.
        case .passwordRequired, .badPassword: return .archiveFailed
        }
    }

    /// Developer-facing description; the extension shows it verbatim on failure.
    static func describe(_ error: ArchiveError) -> String {
        ArchiveExtractor.describe(error)
    }

    /// Shared tail of every single-file create: authorize the destination
    /// folder, run the write, map the outcome onto the wire response.
    ///
    /// `operation` only shapes the log line (`DISPATCH createFile SUCCESS …`),
    /// which the verification handbook greps for, so it is passed in rather than
    /// derived.
    private func createFile(
        in directory: URL,
        preferredName name: String,
        request: FileOperationContract.Request,
        operation: String,
        _ write: () -> Result<URL, FileOperationError>
    ) -> FileOperationContract.Response {
        let folders = currentFolders()
        return withAuthorization(to: directory, folders: folders, cid: request.clientRequestId) {
            switch write() {
            case .success(let url):
                Self.log.info("DISPATCH \(operation, privacy: .public) SUCCESS path=\(url.path, privacy: .public) cid=\(request.clientRequestId ?? "<none>", privacy: .public)")
                return FileOperationContract.Response.success(createdPath: url.path)
            case .failure(let error):
                Self.log.info("DISPATCH \(operation, privacy: .public) FAILURE \(Self.describe(error), privacy: .public) cid=\(request.clientRequestId ?? "<none>", privacy: .public)")
                return FileOperationContract.Response.failure(
                    code: Self.mapError(error),
                    message: error.userFacingDescription
                )
            }
        }
    }

    private func handleCreateDirectory(request: FileOperationContract.Request) -> FileOperationContract.Response {
        guard let directoryRaw = request.args.directory,
              let name = request.args.name,
              !name.isEmpty else {
            return .failure(code: .invalidRequest, message: "createDirectory requires directory and name")
        }
        if let reason = Self.validateName(name) {
            Self.log.info("DISPATCH createDirectory REJECTED name cid=\(request.clientRequestId ?? "<none>", privacy: .public) reason=\(reason, privacy: .public)")
            return .failure(code: .invalidRequest, message: reason)
        }
        let directory = canonicalize(directoryRaw)
        guard let directory else {
            return .failure(code: .invalidRequest, message: "Invalid directory path")
        }

        let folders = currentFolders()
        return withAuthorization(to: directory, folders: folders, cid: request.clientRequestId) {
            let result = FileOperationService.createDirectory(in: directory, preferredName: name)
            switch result {
            case .success(let url):
                Self.log.info("DISPATCH createDirectory SUCCESS path=\(url.path, privacy: .public) cid=\(request.clientRequestId ?? "<none>", privacy: .public)")
                return FileOperationContract.Response.success(createdPath: url.path)
            case .failure(let error):
                Self.log.info("DISPATCH createDirectory FAILURE \(Self.describe(error), privacy: .public) cid=\(request.clientRequestId ?? "<none>", privacy: .public)")
                return FileOperationContract.Response.failure(
                    code: Self.mapError(error),
                    message: error.userFacingDescription
                )
            }
        }
    }

    // MARK: - Multi-target move

    private func handleMoveItems(request: FileOperationContract.Request) -> FileOperationContract.Response {
        guard let sourceRaws = request.args.sourcePaths, !sourceRaws.isEmpty,
              let destRaw = request.args.destinationDirectory else {
            return .failure(code: .invalidRequest, message: "moveItems requires non-empty sourcePaths and destinationDirectory")
        }
        var sources: [URL] = []
        sources.reserveCapacity(sourceRaws.count)
        for raw in sourceRaws {
            guard let u = canonicalize(raw) else {
                return .failure(code: .invalidRequest, message: "Invalid source path: \(raw)")
            }
            sources.append(u)
        }
        guard let destination = canonicalize(destRaw) else {
            return .failure(code: .invalidRequest, message: "Invalid destination path")
        }

        // For moveItems we need scope on the destination AND every source
        // parent. Validate authorization BEFORE the scoped access helper runs,
        // so we can reject path-escape attempts cleanly.
        let folders = currentFolders()
        let scopeTargets = [destination] + sources.map { $0.deletingLastPathComponent() }
        if let failure = scopeFailure(for: scopeTargets, folders: folders, operation: "moveItems", cid: request.clientRequestId) {
            return failure
        }
        // 剪切/移动 is a sensitive action: ask first when the user wants that.
        if let cancelled = confirmationFailure(for: .cutMove(count: sources.count)) {
            return cancelled
        }

        return withAuthorizations(to: scopeTargets, folders: folders, cid: request.clientRequestId) {
            let results = FileOperationService.moveItems(sources, to: destination)
            let summary = FileOperationBatchSummary.summarize(results)
            let items = results.map { (item: FileOperationItemResult) -> FileOperationContract.ItemResult in
                switch item.status {
                case .success:
                    return FileOperationContract.ItemResult(
                        sourcePath: item.sourceURL.path,
                        destinationPath: item.destinationURL?.path,
                        success: true
                    )
                case .failed(let error):
                    return FileOperationContract.ItemResult(
                        sourcePath: item.sourceURL.path,
                        destinationPath: item.destinationURL?.path,
                        success: false,
                        errorCode: Self.mapError(error),
                        message: error.userFacingDescription
                    )
                }
            }
            Self.log.info(
                "DISPATCH moveItems DONE summary=\(Self.describe(summary), privacy: .public) count=\(items.count, privacy: .public) cid=\(request.clientRequestId ?? "<none>", privacy: .public)"
            )
            return FileOperationContract.Response.batchSuccess(items: items)
        }
    }

    // MARK: - P6: aliases, locking, opening a terminal

    /// Creates one Finder alias per source. The alias is written next to its
    /// source unless `destinationDirectory` is supplied, so both the sources'
    /// parents and the destination must be authorized (an alias is a write).
    private func handleCreateAlias(request: FileOperationContract.Request) -> FileOperationContract.Response {
        guard let sourceRaws = request.args.sourcePaths, !sourceRaws.isEmpty else {
            return .failure(code: .invalidRequest, message: "createAlias requires non-empty sourcePaths")
        }
        var sources: [URL] = []
        sources.reserveCapacity(sourceRaws.count)
        for raw in sourceRaws {
            guard let url = canonicalize(raw) else {
                return .failure(code: .invalidRequest, message: "Invalid source path: \(raw)")
            }
            sources.append(url)
        }
        var destination: URL?
        if let destRaw = request.args.destinationDirectory {
            guard let dest = canonicalize(destRaw) else {
                return .failure(code: .invalidRequest, message: "Invalid destination path")
            }
            destination = dest
        }

        let folders = currentFolders()
        // With a destination the alias of every source is written into it,
        // otherwise each alias lands next to its own source. Either way every one
        // of those directories is a write target and needs scope.
        let aliasDirectories: [URL]
        if let destination {
            aliasDirectories = Array(repeating: destination, count: sources.count)
        } else {
            aliasDirectories = sources.map { $0.deletingLastPathComponent() }
        }
        let scopeTargets = Array(Set((aliasDirectories + sources.map { $0.deletingLastPathComponent() }).map(\.path)))
            .map { URL(fileURLWithPath: $0) }
        if let failure = scopeFailure(for: scopeTargets, folders: folders, operation: "createAlias", cid: request.clientRequestId) {
            return failure
        }

        return withAuthorizations(to: scopeTargets, folders: folders, cid: request.clientRequestId) {
            var items: [FileOperationContract.ItemResult] = []
            items.reserveCapacity(sources.count)
            for (index, source) in sources.enumerated() {
                let directory = aliasDirectories[index]
                switch FileOperationService.createAlias(for: source, in: directory) {
                case .success(let aliasURL):
                    Self.log.info("DISPATCH createAlias SUCCESS source=\(source.path, privacy: .public) alias=\(aliasURL.path, privacy: .public)")
                    items.append(FileOperationContract.ItemResult(
                        sourcePath: source.path,
                        destinationPath: aliasURL.path,
                        success: true
                    ))
                case .failure(let error):
                    Self.log.info("DISPATCH createAlias FAILURE source=\(source.path, privacy: .public) \(Self.describe(error), privacy: .public)")
                    items.append(FileOperationContract.ItemResult(
                        sourcePath: source.path,
                        destinationPath: nil,
                        success: false,
                        errorCode: .aliasFailed,
                        message: error.userFacingDescription
                    ))
                }
            }
            return .batchSuccess(items: items)
        }
    }

    /// Sets or clears the user-immutable flag on every selected item.
    /// Per-item results: a single unreadable item must not fail the batch.
    private func handleSetLocked(request: FileOperationContract.Request) -> FileOperationContract.Response {
        guard let rawPaths = request.args.sourcePaths, !rawPaths.isEmpty,
              let locked = request.args.locked else {
            return .failure(code: .invalidRequest, message: "setLocked requires non-empty sourcePaths and locked")
        }
        var targets: [URL] = []
        targets.reserveCapacity(rawPaths.count)
        for raw in rawPaths {
            guard let url = canonicalize(raw) else {
                return .failure(code: .invalidRequest, message: "Invalid source path: \(raw)")
            }
            targets.append(url)
        }
        guard !targets.isEmpty else {
            return .failure(code: .invalidRequest, message: "setLocked requires at least one path")
        }

        let folders = currentFolders()
        let scopeTargets = Array(Set(targets.map { $0.deletingLastPathComponent().path }))
            .map { URL(fileURLWithPath: $0) }
        if let failure = scopeFailure(for: scopeTargets, folders: folders, operation: "setLocked", cid: request.clientRequestId) {
            return failure
        }
        // 锁定/解锁 is a sensitive action: ask first when the user wants that.
        if let cancelled = confirmationFailure(for: locked ? .lock(count: targets.count) : .unlock(count: targets.count)) {
            return cancelled
        }

        return withAuthorizations(to: scopeTargets, folders: folders, cid: request.clientRequestId) {
            var items: [FileOperationContract.ItemResult] = []
            items.reserveCapacity(targets.count)
            for target in targets {
                switch FileOperationService.setLocked(locked, at: target) {
                case .success:
                    Self.log.info("DISPATCH setLocked SUCCESS locked=\(locked, privacy: .public) path=\(target.path, privacy: .public)")
                    items.append(FileOperationContract.ItemResult(
                        sourcePath: target.path,
                        destinationPath: target.path,
                        success: true
                    ))
                case .failure(let error):
                    Self.log.info("DISPATCH setLocked FAILURE path=\(target.path, privacy: .public) \(Self.describe(error), privacy: .public)")
                    items.append(FileOperationContract.ItemResult(
                        sourcePath: target.path,
                        destinationPath: target.path,
                        success: false,
                        errorCode: .lockFailed,
                        message: error.userFacingDescription
                    ))
                }
            }
            return .batchSuccess(items: items)
        }
    }

    /// Opens a new terminal window at `directory`.
    ///
    /// Deliberately NOT gated on the folder-authorization store. The main app
    /// performs no filesystem work here: it validates that the path is an
    /// existing directory and hands it to LaunchServices, and Terminal (not
    /// sandboxed) applies its own access rules. Gating this on an explicit
    /// bookmark would make "Open Terminal" fail in every folder the user has not
    /// separately authorized, for no security benefit. Every *mutating*
    /// operation remains gate-protected.
    private func handleOpenTerminal(request: FileOperationContract.Request) -> FileOperationContract.Response {
        guard let raw = request.args.directory, let directory = canonicalize(raw) else {
            return .failure(code: .invalidRequest, message: "openTerminal requires a directory")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(code: .invalidDestination, message: "“\(directory.path)” is not a folder.")
        }
        if let error = terminalOpener().openTerminal(directory) {
            Self.log.error("DISPATCH openTerminal FAILED path=\(directory.path, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return .failure(code: .openFailed, message: error.localizedDescription)
        }
        Self.log.info("DISPATCH openTerminal SUCCESS path=\(directory.path, privacy: .public)")
        return .success(createdPath: nil)
    }

    // MARK: - Authorization wrappers

    /// Run `body` while holding security-scoped access for the authorized
    /// folder covering `target`. Catches `FolderAuthorizationError` and maps
    /// it to the wire error model.
    ///
    /// With `restrictToAuthorizedFolders` off and no bookmark covering the
    /// target, this skips the scoped access entirely and runs `body()` — the
    /// sandbox is then the only thing deciding whether the write is allowed.
    private func withAuthorization(
        to target: URL,
        folders: [AuthorizedFolder],
        cid: String?,
        _ body: () -> FileOperationContract.Response
    ) -> FileOperationContract.Response {
        if !restrictsToAuthorizedFolders,
           AuthorizedURLResolver.folderMatching(target, folders: folders) == nil {
            Self.log.info("DISPATCH auth bypassed (restrict off, no bookmark) target=\(target.path, privacy: .public) cid=\(cid ?? "<none>", privacy: .public)")
            return body()
        }
        do {
            return try FolderAuthorizationAccess.withAccess(
                to: target,
                folders: folders,
                configuration: scopedConfig,
                persistRefreshedBookmark: persistenceHook()
            ) { _ in body() }
        } catch let error as FolderAuthorizationError {
            Self.log.info("DISPATCH auth FAILED target=\(target.path, privacy: .public) error=\(String(describing: error), privacy: .public) cid=\(cid ?? "<none>", privacy: .public)")
            // The friendly text, not `String(describing:)`: the extension shows this
            // message as-is, and `authorizationRequired(URL: file:///…)` is not
            // something to put in front of a user. The log line above keeps the
            // exact case for diagnosis.
            return .failure(code: Self.mapAuthError(error), message: Self.describe(error))
        } catch {
            Self.log.error("DISPATCH auth UNEXPECTED target=\(target.path, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return .failure(code: .operationFailed, message: String(describing: error))
        }
    }

    private func withAuthorizations(
        to targets: [URL],
        folders: [AuthorizedFolder],
        cid: String?,
        _ body: () -> FileOperationContract.Response
    ) -> FileOperationContract.Response {
        // Restriction off: hold the bookmarks that do cover a target, and run
        // the rest without one (see `withAuthorization`).
        if !restrictsToAuthorizedFolders {
            let covered = targets.filter { AuthorizedURLResolver.folderMatching($0, folders: folders) != nil }
            if covered.isEmpty {
                Self.log.info("DISPATCH multi-auth bypassed (restrict off, no bookmark) count=\(targets.count, privacy: .public) cid=\(cid ?? "<none>", privacy: .public)")
                return body()
            }
            return performWithAuthorizations(to: covered, folders: folders, cid: cid, body)
        }
        return performWithAuthorizations(to: targets, folders: folders, cid: cid, body)
    }

    private func performWithAuthorizations(
        to targets: [URL],
        folders: [AuthorizedFolder],
        cid: String?,
        _ body: () -> FileOperationContract.Response
    ) -> FileOperationContract.Response {
        do {
            return try FolderAuthorizationAccess.withAccesses(
                to: targets,
                folders: folders,
                configuration: scopedConfig,
                persistRefreshedBookmark: persistenceHook()
            ) { body() }
        } catch let error as FolderAuthorizationError {
            Self.log.info("DISPATCH multi-auth FAILED error=\(String(describing: error), privacy: .public) cid=\(cid ?? "<none>", privacy: .public)")
            return .failure(code: Self.mapAuthError(error), message: Self.describe(error))
        } catch {
            Self.log.error("DISPATCH multi-auth UNEXPECTED error=\(String(describing: error), privacy: .public)")
            return .failure(code: .operationFailed, message: String(describing: error))
        }
    }

    // MARK: - Helpers

    /// Persistence hook for transparent stale-bookmark renewal (H3).
    ///
    /// `nil` when no store is configured (App Group unavailable): in that case
    /// `FolderAuthorizationAccess` reports `staleBookmarkNeedsReauthorization`,
    /// which is the pre-existing behaviour for the no-store case.
    private func persistenceHook() -> ((AuthorizedFolder, Data) throws -> Void)? {
        guard let store else { return nil }
        return { folder, _ in
            // `folder.bookmarkData` holds the freshly created bookmark by the
            // time this is called; `update` persists the whole row under a lock.
            try store.update(folder)
        }
    }

    /// Validates a wire-supplied `name` before it is used as a path component.
    ///
    /// Returns a human-readable reason when the name must be rejected, or nil
    /// when it is acceptable. The Main App receives `name` over IPC and must not
    /// assume the extension sent a well-formed single component: `/` and `..`
    /// would let `appendingPathComponent` escape the authorized directory.
    ///
    /// Leading dots are allowed (hidden files are a legitimate Finder concept);
    /// "." and ".." are not names, they are path navigation.
    static func validateName(_ name: String) -> String? {
        if name.isEmpty { return "name must not be empty" }
        if name == "." || name == ".." { return "name must not be “.” or “..”" }
        if name.contains("/") { return "name must not contain “/”" }
        if name.contains(":") { return "name must not contain “:”" }
        if name.utf8.contains(0) { return "name must not contain NUL" }
        // NAME_MAX on APFS/HFS+ is 255 bytes (not characters).
        if name.utf8.count > 255 { return "name must not exceed 255 bytes" }
        return nil
    }

    /// Standardize a raw path string into a `URL`. Rejects empty, relative,
    /// and non-file paths. Uses `URL.standardizedFileURL` so `..` and
    /// repeated `/` are normalised away.
    ///
    /// Internal (not private) so the unit tests can pin the path-escape
    /// rejections directly.
    func canonicalize(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        let url = URL(fileURLWithPath: raw)
        guard url.isFileURL else { return nil }
        let standardized = url.standardizedFileURL
        guard !standardized.path.isEmpty, standardized.path.hasPrefix("/") else { return nil }
        return standardized
    }

    /// Validates a wire-supplied web URL: http(s), with a host, no whitespace.
    ///
    /// Internal (not private) so the unit tests can pin the accepted shapes
    /// without spinning up the opener.
    static func validatedWebURL(_ raw: String) -> URL? {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !candidate.contains(" ") else { return nil }
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty
        else { return nil }
        return components.url
    }

    private func currentFolders() -> [AuthorizedFolder] {
        store?.loadFolders() ?? []
    }

    private static func describe(_ error: FileOperationError) -> String {
        if case .fileSystem(let domain, let code, let description, let posixCode) = error {
            var s = "domain=\(domain) code=\(code)"
            if let posixCode { s += " posix=\(posixCode)" }
            s += " desc=\(description)"
            return s
        }
        return String(describing: error)
    }

    /// Text for the dialog, which has no `ErrorCode` mapping to fall back on.
    static func describe(_ error: FolderAuthorizationError) -> String {
        switch error {
        case .authorizationRequired(let url):
            return "Path outside any authorized folder: \(url.path)"
        case .bookmarkResolveFailed(let url):
            return "The saved permission for “\(url.path)” could not be resolved; authorize the folder again."
        case .staleBookmarkNeedsReauthorization(let url):
            return "The saved permission for “\(url.path)” is stale; authorize the folder again."
        case .accessStartFailed(let url):
            return "“\(url.path)” could not be opened; authorize the folder again."
        }
    }

    private static func describe(_ summary: FileOperationBatchSummary) -> String {
        switch summary {
        case .allSucceeded: return "allSucceeded"
        case .allFailed: return "allFailed"
        case .partial: return "partial"
        }
    }

    /// Internal (not private) so the unit tests can pin the whole error-code
    /// mapping table without needing a real EPERM from the filesystem.
    static func mapError(_ error: FileOperationError) -> FileOperationContract.ErrorCode {
        switch error {
        case .destinationExists: return .nameCollision
        case .invalidMove: return .operationFailed
        case .invalidDestination: return .invalidDestination
        case .sourceDoesNotExist: return .sourceDoesNotExist
        case .fileSystem(_, _, _, let posixCode):
            if let posixCode, posixCode == EPERM || posixCode == EACCES {
                return .filesystemPermissionDenied
            }
            return .filesystemError
        case .unknown: return .operationFailed
        }
    }

    static func mapAuthError(_ error: FolderAuthorizationError) -> FileOperationContract.ErrorCode {
        switch error {
        case .authorizationRequired: return .notAuthorized
        case .bookmarkResolveFailed: return .bookmarkResolveFailed
        case .staleBookmarkNeedsReauthorization: return .staleBookmarkNeedsReauthorization
        case .accessStartFailed: return .accessStartFailed
        }
    }
}
