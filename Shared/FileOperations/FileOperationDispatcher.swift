import Foundation
import os

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
    /// "解压到指定位置…" needs a folder picker. It is a closure so this type
    /// stays Foundation-only and headless-testable; the app injects the AppKit
    /// panel (see `MainAppIPCServer`), tests inject a temp directory.
    private let folderChooser: () -> URL?

    init(
        store: FolderAuthorizationStore? = FolderAuthorizationStore.appGroupDefault(),
        scopedConfig: ScopedAccessConfiguration = .system,
        opener: SystemOpener = .system,
        templateDirectory: URL? = DocumentTemplateCatalog.bundledDirectory,
        archiveSettings: @escaping () -> ArchiveSettings = { SettingsStore.shared.settings.archives },
        folderChooser: @escaping () -> URL? = { nil }
    ) {
        self.store = store
        self.scopedConfig = scopedConfig
        self.opener = opener
        self.templateDirectory = templateDirectory
        self.archiveSettings = archiveSettings
        self.folderChooser = folderChooser
    }

    // MARK: - Dispatch entry point

    /// Decode a request payload, validate it, run it, return a wire response.
    /// This function never throws: every failure mode is encoded in the
    /// returned `Response.failure` so the transport layer can reply with a
    /// single IPCProtocol.Response.
    public func dispatch(payload: String?) -> FileOperationContract.Response {
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
            return handleCompressItems(request: request)
        case .extractArchive:
            return handleExtractArchive(request: request)
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
        guard let template = DocumentTemplateCatalog.templateURL(for: type, in: templateDirectory) else {
            let expected = DocumentTemplateCatalog.templateFileName(for: type) ?? "<unknown>"
            Self.log.error("DISPATCH createFromTemplate TEMPLATE_MISSING kind=\(rawKind, privacy: .public) expected=\(expected, privacy: .public) directory=\(self.templateDirectory?.path ?? "<none>", privacy: .public)")
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
    private func handleCompressItems(request: FileOperationContract.Request) -> FileOperationContract.Response {
        guard let sourceRaws = request.args.sourcePaths, !sourceRaws.isEmpty else {
            return .failure(code: .invalidRequest, message: "compressItems requires non-empty sourcePaths")
        }
        let rawFormat = request.args.archiveFormat ?? ArchiveFormat.zip.rawValue
        guard let format = ArchiveFormat(rawValue: rawFormat), ArchiveCompressor.canWrite(format) else {
            return .failure(
                code: .archiveUnsupported,
                message: "This build cannot create “\(rawFormat)” archives (ZIP, TAR, TAR.GZ and TAR.BZ2 are supported)."
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
        let scopeTargets = Array(Set(([destination] + sources.map { $0.deletingLastPathComponent() }).map(\.path)))
            .map { URL(fileURLWithPath: $0) }
        for target in scopeTargets where AuthorizedURLResolver.folderMatching(target, folders: folders) == nil {
            Self.log.info("DISPATCH compressItems NOT_AUTHORIZED target=\(target.path, privacy: .public)")
            return .failure(code: .pathOutsideAuthorizedScope, message: "Path outside any authorized folder: \(target.path)")
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
                    label: label
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

    /// Extracts one or more archives, each into its own folder unless a
    /// destination is given. Per-archive results: one bad archive must not stop
    /// the others.
    private func handleExtractArchive(request: FileOperationContract.Request) -> FileOperationContract.Response {
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
        for target in scopeTargets where AuthorizedURLResolver.folderMatching(target, folders: folders) == nil {
            Self.log.info("DISPATCH extractArchive NOT_AUTHORIZED target=\(target.path, privacy: .public)")
            return .failure(code: .pathOutsideAuthorizedScope, message: "Path outside any authorized folder: \(target.path)")
        }

        let settings = archiveSettings()
        return withAuthorizations(to: scopeTargets, folders: folders, cid: request.clientRequestId) {
            var items: [FileOperationContract.ItemResult] = []
            items.reserveCapacity(archives.count)
            for (index, archive) in archives.enumerated() {
                let destination = destinations[index]
                do {
                    let (results, summary) = try ArchiveExtractor.extract(
                        archiveURL: archive,
                        to: destination,
                        settings: settings
                    )
                    let unresolvable = results.first { result in
                        if case .failed = result.outcome { return true }
                        return false
                    }
                    let wroteNothing = summary.written == 0 && summary.skipped > 0
                    Self.log.info(
                        "DISPATCH extractArchive DONE archive=\(archive.path, privacy: .public) written=\(summary.written, privacy: .public) skipped=\(summary.skipped, privacy: .public) failed=\(summary.failed, privacy: .public)"
                    )
                    items.append(FileOperationContract.ItemResult(
                        sourcePath: archive.path,
                        destinationPath: destination.path,
                        success: summary.failed == 0 && !wroteNothing,
                        errorCode: summary.failed > 0 ? .archiveFailed : (wroteNothing ? .nameCollision : nil),
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
        case .unsupportedFormat, .notAnArchive: return .archiveUnsupported
        case .unsafePath: return .archiveUnsafePath
        case .tooLarge: return .archiveTooLarge
        case .conflict: return .nameCollision
        case .readFailed, .writeFailed: return .archiveFailed
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
        for target in scopeTargets {
            if AuthorizedURLResolver.folderMatching(target, folders: folders) == nil {
                Self.log.info("DISPATCH moveItems NOT_AUTHORIZED target=\(target.path, privacy: .public) cid=\(request.clientRequestId ?? "<none>", privacy: .public)")
                return .failure(
                    code: .pathOutsideAuthorizedScope,
                    message: "Path outside any authorized folder: \(target.path)"
                )
            }
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
        let aliasDirectories = destination.map { _ in sources.map { _ in destination! } }
            ?? sources.map { $0.deletingLastPathComponent() }
        let scopeTargets = Array(Set((aliasDirectories + sources.map { $0.deletingLastPathComponent() }).map(\.path)))
            .map { URL(fileURLWithPath: $0) }
        for target in scopeTargets where AuthorizedURLResolver.folderMatching(target, folders: folders) == nil {
            Self.log.info("DISPATCH createAlias NOT_AUTHORIZED target=\(target.path, privacy: .public)")
            return .failure(code: .pathOutsideAuthorizedScope, message: "Path outside any authorized folder: \(target.path)")
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
        for target in scopeTargets where AuthorizedURLResolver.folderMatching(target, folders: folders) == nil {
            Self.log.info("DISPATCH setLocked NOT_AUTHORIZED target=\(target.path, privacy: .public)")
            return .failure(code: .pathOutsideAuthorizedScope, message: "Path outside any authorized folder: \(target.path)")
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
        if let error = opener.openTerminal(directory) {
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
    private func withAuthorization(
        to target: URL,
        folders: [AuthorizedFolder],
        cid: String?,
        _ body: () -> FileOperationContract.Response
    ) -> FileOperationContract.Response {
        do {
            return try FolderAuthorizationAccess.withAccess(
                to: target,
                folders: folders,
                configuration: scopedConfig,
                persistRefreshedBookmark: persistenceHook()
            ) { _ in body() }
        } catch let error as FolderAuthorizationError {
            Self.log.info("DISPATCH auth FAILED target=\(target.path, privacy: .public) error=\(String(describing: error), privacy: .public) cid=\(cid ?? "<none>", privacy: .public)")
            return .failure(code: Self.mapAuthError(error), message: String(describing: error))
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
        do {
            return try FolderAuthorizationAccess.withAccesses(
                to: targets,
                folders: folders,
                configuration: scopedConfig,
                persistRefreshedBookmark: persistenceHook()
            ) { body() }
        } catch let error as FolderAuthorizationError {
            Self.log.info("DISPATCH multi-auth FAILED error=\(String(describing: error), privacy: .public) cid=\(cid ?? "<none>", privacy: .public)")
            return .failure(code: Self.mapAuthError(error), message: String(describing: error))
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
