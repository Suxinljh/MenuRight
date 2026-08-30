import Foundation

/// Outcome of a single filesystem mutation item (e.g. one file in a batch move).
struct FileOperationItemResult: Equatable {
    let sourceURL: URL
    let destinationURL: URL?
    let status: FileOperationStatus
}

enum FileOperationStatus: Equatable {
    case success
    case failed(FileOperationError)
}

/// Errors surfaced by file operations. Values are value-semantic so results can
/// be compared and unit-tested; the user-facing text is built by
/// userFacingDescription.
enum FileOperationError: Equatable, Error {
    /// Destination already contains an item with the same name (never auto-renamed).
    case destinationExists(URL)
    /// Planner-level guard, e.g. folder into itself / into a descendant.
    case invalidMove(String)
    /// The paste target is not an existing directory.
    case invalidDestination(String)
    /// A source item no longer exists on disk.
    case sourceDoesNotExist(URL)
    /// NSError from the filesystem, with POSIX code when derivable.
    case fileSystem(domain: String, code: Int, description: String, underlyingPOSIXCode: Int32?)
    /// Anything not otherwise classified.
    case unknown(String)

    var userFacingDescription: String {
        switch self {
        case .destinationExists(let url):
            return "A file named “\(url.lastPathComponent)” already exists in the destination."
        case .invalidMove(let reason):
            return reason
        case .invalidDestination(let path):
            return "“\(path)” is not a folder that can receive files."
        case .sourceDoesNotExist(let url):
            return "“\(url.lastPathComponent)” no longer exists."
        case .fileSystem(_, _, let description, let posixCode):
            if let posixCode, posixCode == EPERM {
                return "You don’t have permission to write to this folder."
            }
            return description
        case .unknown(let message):
            return message
        }
    }

    /// Wraps an arbitrary Error (typically NSError from FileManager) while
    /// keeping the original domain/code/POSIX details for logging.
    static func from(_ error: Error, context: URL) -> FileOperationError {
        let nsError = error as NSError
        var posixCode: Int32?
        if nsError.domain == NSPOSIXErrorDomain {
            posixCode = Int32(nsError.code)
        } else if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
                  underlying.domain == NSPOSIXErrorDomain {
            posixCode = Int32(underlying.code)
        }
        return .fileSystem(
            domain: nsError.domain,
            code: nsError.code,
            description: nsError.localizedDescription,
            underlyingPOSIXCode: posixCode
        )
    }
}

/// Batch classification: FileManager moveItem is not atomic across items, so a
/// multi-item move can end up partially complete. We report exactly that.
enum FileOperationBatchSummary: Equatable {
    case allSucceeded
    case partial(failures: [FileOperationItemResult])
    case allFailed(failures: [FileOperationItemResult])

    static func summarize(_ results: [FileOperationItemResult]) -> FileOperationBatchSummary {
        let failures = results.filter { result in
            if case .failed = result.status { return true }
            return false
        }
        if failures.isEmpty { return .allSucceeded }
        if failures.count == results.count { return .allFailed(failures: failures) }
        return .partial(failures: failures)
    }

    var failureCount: Int {
        switch self {
        case .allSucceeded: return 0
        case .partial(let failures): return failures.count
        case .allFailed(let failures): return failures.count
        }
    }
}
