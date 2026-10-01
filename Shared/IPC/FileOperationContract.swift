import Foundation

/// Stable wire contract for the **P5-1** Main-App file-operation delegation.
///
/// The FinderSync extension sends an `IPCRequest` with `method == "fileOperation"`
/// and `payload == JSON-encoded FileOperationRequest`. The Main App replies with
/// an `IPCProtocol.Response` whose `result` (success) or `error` (failure) is
/// a JSON-encoded `FileOperationResponse`.
///
/// This contract is intentionally narrow — only the file operations migrated
/// in P5-1 are represented here. New operations extend `OperationKind`; we
/// never expose a generic "execute this path" RPC.
///
/// Every type is `Sendable`: requests and responses cross from the FinderSync
/// extension's `ipcQueue` to the main queue (and from the accept queue to a
/// connection queue in the main app), so they must be safely transferable
/// between isolation domains. They are immutable value types.
public enum FileOperationContract {

    /// The kind of file operation being requested. Each case carries only the
    /// data the Main App needs to validate and execute the request. Paths
    /// are always transmitted as raw POSIX strings (`URL.path`); the Main App
    /// canonicalises them before any filesystem or authorization check.
    public enum OperationKind: String, Codable, Equatable, Sendable {
        case createFile
        case createDirectory
        case moveItems
        /// P6: create a Finder alias next to (or beside) each source.
        case createAlias
        /// P6: set/clear the user-immutable flag (Finder "Locked").
        case setLocked
        /// P6: hand a directory to Terminal. Non-mutating, see `handleOpenTerminal`.
        case openTerminal
        /// P6-b: create a Word/Excel/PowerPoint document. The **main app**
        /// writes the OOXML package (`OOXMLDocumentFactory`); the extension only
        /// says which kind — the archive writer must never live in the
        /// sandboxed extension.
        case createDocument
        /// P6-b: create a Pages/Numbers/Keynote document by copying the blank
        /// template from the main app bundle. Fails with `templateMissing` when
        /// this build has no template for the kind.
        case createFromTemplate
        /// P7-b: open one of the user's favorite folders in Finder.
        case openFolder
        /// P7-b: open one of the user's favorite applications. `target` is an
        /// application path or a bundle identifier.
        case openApplication
        /// P7-b: open one of the user's favorite websites in the default
        /// browser. `target` must be http(s).
        ///
        /// All three are non-mutating hand-offs to LaunchServices: they are
        /// deliberately **not** gated on the folder-authorization store, for the
        /// same reason `openTerminal` is not — this app performs no filesystem
        /// work, and gating would make a favorite unusable in any folder the
        /// user has not separately authorized.
        case openURL
        /// P9: compress the selection into a new archive next to it.
        case compressItems
        /// P9: extract one or more archives.
        ///
        /// `destinationDirectory` nil means "each archive's own folder" — the
        /// menu's 解压到当前文件夹 — which does not require the extension to
        /// decide anything per item.
        case extractArchive
    }

    /// Per-operation arguments. Exactly one field is meaningful for any given
    /// `kind`; the others are ignored.
    public struct OperationArgs: Codable, Equatable, Sendable {
        /// Required for `createFile`. The parent directory (folder) path.
        public var directory: String?
        /// Required for `createFile`/`createDirectory`. User-facing preferred
        /// name. Main App applies collision resolution.
        public var name: String?
        /// Optional for `createFile`. Base64-encoded initial contents. nil
        /// means an empty file.
        public var contentsBase64: String?
        /// Required for `moveItems`. Source item paths (NOT parent dirs).
        /// Also used by `createAlias`/`setLocked` to carry the selection.
        public var sourcePaths: [String]?
        /// Required for `moveItems`. Destination folder path.
        /// Optional for `createAlias`: where the alias is created; nil means
        /// "next to each source".
        public var destinationDirectory: String?
        /// Required for `setLocked`. true = lock (undeletable), false = unlock.
        public var locked: Bool?
        /// Required for `createDocument`/`createFromTemplate`. The raw value of
        /// the `NewFileType` to create (`docx`, `xlsx`, `pptx`, `pages`,
        /// `numbers`, `keynote`). A raw value the receiving build does not know
        /// is rejected as `invalidRequest` — the contract stays version 1 and
        /// old payloads still decode (the field is optional).
        public var documentKind: String?
        /// Required for `openApplication`/`openURL`: the application path or
        /// bundle identifier, or the http(s) URL to open.
        public var target: String?
        /// Required for `compressItems`. The `ArchiveFormat` raw value to write
        /// (`zip` in this build). Unknown or unwritable values are rejected as
        /// `archiveUnsupported` rather than silently falling back.
        public var archiveFormat: String?
        /// Optional for `compressItems`. The archive's label — the "标签" the
        /// custom-compression dialog offers. Only ZIP stores one (as the
        /// end-of-central-directory comment); other formats accept and ignore
        /// it, which the dialog states.
        public var archiveLabel: String?
        /// Optional for `compressItems`. `ArchiveCompressionMode` raw value
        /// (`fast` / `standard` / `maximum`).
        public var archiveMode: String?
        /// Optional. `compressItems` + true opens the custom-compression dialog;
        /// `extractArchive` + true asks the user for a destination folder first
        /// (NSOpenPanel in the main app). Either way the extension is not the one
        /// choosing the options or the folder.
        public var customize: Bool?

        public init(
            directory: String? = nil,
            name: String? = nil,
            contentsBase64: String? = nil,
            sourcePaths: [String]? = nil,
            destinationDirectory: String? = nil,
            locked: Bool? = nil,
            documentKind: String? = nil,
            target: String? = nil,
            archiveFormat: String? = nil,
            archiveLabel: String? = nil,
            archiveMode: String? = nil,
            customize: Bool? = nil
        ) {
            self.directory = directory
            self.name = name
            self.contentsBase64 = contentsBase64
            self.sourcePaths = sourcePaths
            self.destinationDirectory = destinationDirectory
            self.locked = locked
            self.documentKind = documentKind
            self.target = target
            self.archiveFormat = archiveFormat
            self.archiveLabel = archiveLabel
            self.archiveMode = archiveMode
            self.customize = customize
        }
    }

    /// Wire payload sent by the extension in `IPCRequest.payload`.
    public struct Request: Codable, Equatable, Sendable {
        public let kind: OperationKind
        public let args: OperationArgs
        /// Optional request id echoed back by the Main App for log
        /// correlation.
        public let clientRequestId: String?

        public init(kind: OperationKind, args: OperationArgs, clientRequestId: String? = nil) {
            self.kind = kind
            self.args = args
            self.clientRequestId = clientRequestId
        }
    }

    /// Stable error codes returned in `Response.failure.code`.
    ///
    /// The extension must select user-facing strings locally (or rely on the
    /// server-supplied `message`), but the codes are stable and must not be
    /// reshuffled. Anything the extension needs to distinguish at the UI
    /// layer should be a code here, not a string match.
    public enum ErrorCode: String, Codable, Equatable, Sendable {
        /// Main App rejected the request structurally (bad shape, missing
        /// fields, unknown kind).
        case invalidRequest = "invalid_request"
        /// Transport / security gate says this operation is not allowed.
        case notAllowed = "not_allowed"
        /// No authorized folder covers the requested path(s).
        case notAuthorized = "not_authorized"
        /// Bookmark data could not be resolved.
        case bookmarkResolveFailed = "bookmark_resolve_failed"
        /// Bookmark is stale; refresh / re-authorization required.
        case staleBookmarkNeedsReauthorization = "stale_bookmark_needs_reauthorization"
        /// startAccessingSecurityScopedResource returned false.
        case accessStartFailed = "access_start_failed"
        /// The requested path sits outside every authorized folder, even
        /// though some other path was authorized. Path-escape-attempt case.
        case pathOutsideAuthorizedScope = "path_outside_authorized_scope"
        /// Requested source item does not exist on disk.
        case sourceDoesNotExist = "source_does_not_exist"
        /// Destination is not a folder, doesn't exist, or can't accept items.
        case invalidDestination = "invalid_destination"
        /// Destination already contains the same name and was not overwritten.
        case nameCollision = "name_collision"
        /// Filesystem refused (EPERM, EACCES, read-only volume, etc).
        case filesystemPermissionDenied = "filesystem_permission_denied"
        /// Lower-level filesystem failure (disk full, IO error, etc).
        case filesystemError = "filesystem_error"
        /// Anything not otherwise classified.
        case operationFailed = "operation_failed"
        /// The user pressed 取消 in the progress window. Not a failure: the
        /// extension must not pop an error dialog for something the user asked
        /// for, and nothing was written (the archive is assembled in memory).
        case cancelledByUser = "cancelled_by_user"
        /// P6: creating a Finder alias failed (bookmark creation or write).
        case aliasFailed = "alias_failed"
        /// P6: setting/clearing the immutable flag failed.
        case lockFailed = "lock_failed"
        /// P6: opening Terminal for the given directory failed.
        case openFailed = "open_failed"
        /// P6-b: the bundled blank template for a Pages/Numbers/Keynote
        /// document is not present in this build, so nothing was created.
        ///
        /// The menu hides such kinds via the published `NewFileAvailability`;
        /// this code exists for the race where a template disappears between the
        /// publish and the click, and so the failure is never a generic
        /// `operation_failed`.
        case templateMissing = "template_missing"
        /// P6-b: this build does not know how to generate the requested
        /// document kind (unknown or unsupported raw value).
        case unsupportedDocumentKind = "unsupported_document_kind"
        /// P9: the archive is not a format this build can read, or its
        /// compression method is not supported.
        case archiveUnsupported = "archive_unsupported"
        /// P9: an entry name tried to escape the destination directory.
        case archiveUnsafePath = "archive_unsafe_path"
        /// P9: the payload exceeds the configured size limit (checked before
        /// anything is written).
        case archiveTooLarge = "archive_too_large"
        /// P9: the archive itself could not be opened, written or completed.
        case archiveFailed = "archive_failed"
    }

    /// Batch item outcome for `moveItems` responses.
    public struct ItemResult: Codable, Equatable, Sendable {
        public let sourcePath: String
        public let destinationPath: String?
        public let success: Bool
        public let errorCode: ErrorCode?
        public let message: String?

        public init(
            sourcePath: String,
            destinationPath: String?,
            success: Bool,
            errorCode: ErrorCode? = nil,
            message: String? = nil
        ) {
            self.sourcePath = sourcePath
            self.destinationPath = destinationPath
            self.success = success
            self.errorCode = errorCode
            self.message = message
        }
    }

    /// Wire payload returned by the Main App. `success` carries the created
    /// path for create*; `batchSuccess` carries per-item results for
    /// `moveItems`. `failure` carries a stable error code and a
    /// developer-facing message.
    public enum Response: Codable, Equatable, Sendable {
        case success(createdPath: String?)
        case batchSuccess(items: [ItemResult])
        case failure(code: ErrorCode, message: String)
    }
}

// MARK: - IPC encoding helpers

extension FileOperationContract.Request {
    /// JSON-encode for `IPCProtocol.Request.payload`. Returns nil on encoder
    /// failure (should be impossible for these value types).
    public func encodedForIPC() -> String? {
        guard let data = try? JSONEncoder().encode(self),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Decode from `IPCProtocol.Request.payload`.
    public static func decode(fromIPC payload: String?) -> FileOperationContract.Request? {
        guard let payload, let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FileOperationContract.Request.self, from: data)
    }
}

extension FileOperationContract.Response {
    /// JSON-encode for `IPCProtocol.Response.result` or `.error`.
    public func encodedForIPC() -> String? {
        guard let data = try? JSONEncoder().encode(self),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Decode from `IPCProtocol.Response.result` or `.error`.
    public static func decode(fromIPC payload: String?) -> FileOperationContract.Response? {
        guard let payload, let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FileOperationContract.Response.self, from: data)
    }
}

// MARK: - Progress-window controls

/// What the progress window's buttons ask for.
///
/// Lives in the contract rather than next to the worker's control object
/// because **both** sides need it: the extension sends it, the Main App
/// applies it. `ArchiveOperationControl` (App-only, it touches `ArchiveError`)
/// is the other half.
public enum ArchiveControlAction: String, Codable, Equatable, Sendable {
    case pause
    case resume
    case cancel

    var titleKey: StringKey {
        switch self {
        case .pause: return .presenterProgressPause
        case .resume: return .presenterProgressResume
        case .cancel: return .presenterProgressCancel
        }
    }
}

/// Payload of the `fileOperationControl` IPC method.
public struct ArchiveControlRequest: Codable, Equatable, Sendable {
    /// The extension-generated id of the running operation — the only
    /// identifier both sides already agree on.
    public let clientRequestId: String
    public let action: ArchiveControlAction

    public init(clientRequestId: String, action: ArchiveControlAction) {
        self.clientRequestId = clientRequestId
        self.action = action
    }
}
