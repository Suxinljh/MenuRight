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

    init(
        store: FolderAuthorizationStore? = FolderAuthorizationStore.appGroupDefault(),
        scopedConfig: ScopedAccessConfiguration = .system,
        opener: SystemOpener = .system
    ) {
        self.store = store
        self.scopedConfig = scopedConfig
        self.opener = opener
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

        let folders = currentFolders()
        return withAuthorization(to: directory, folders: folders, cid: request.clientRequestId) {
            let result = FileOperationService.createFile(in: directory, preferredName: name, contents: contents)
            switch result {
            case .success(let url):
                Self.log.info("DISPATCH createFile SUCCESS path=\(url.path, privacy: .public) cid=\(request.clientRequestId ?? "<none>", privacy: .public)")
                return FileOperationContract.Response.success(createdPath: url.path)
            case .failure(let error):
                Self.log.info("DISPATCH createFile FAILURE \(Self.describe(error), privacy: .public) cid=\(request.clientRequestId ?? "<none>", privacy: .public)")
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
