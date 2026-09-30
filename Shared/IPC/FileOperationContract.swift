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
        public var sourcePaths: [String]?
        /// Required for `moveItems`. Destination folder path.
        public var destinationDirectory: String?

        public init(
            directory: String? = nil,
            name: String? = nil,
            contentsBase64: String? = nil,
            sourcePaths: [String]? = nil,
            destinationDirectory: String? = nil
        ) {
            self.directory = directory
            self.name = name
            self.contentsBase64 = contentsBase64
            self.sourcePaths = sourcePaths
            self.destinationDirectory = destinationDirectory
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
