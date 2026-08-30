import Foundation

/// Lifecycle states of a stored authorization.
enum AuthorizationStatus: Equatable {
    case authorized
    case needsReauthorization
    case unavailable
}

/// Pure ancestor matching between a requested Finder URL and the set of
/// authorized folders.
///
/// Comparisons use normalized URL path components: trailing slashes are
/// ignored and "/foo/bar" never matches "/foo/barista".
enum AuthorizedURLResolver {
    /// Returns the most specific authorized ancestor of targetURL, or nil.
    static func folderMatching(_ targetURL: URL, folders: [AuthorizedFolder]) -> AuthorizedFolder? {
        let targetComponents = targetURL.standardizedFileURL.pathComponents
        var best: AuthorizedFolder?
        var bestDepth = -1
        for folder in folders {
            let folderComponents = normalizedComponents(of: folder.originalPath)
            guard folderComponents.count > bestDepth else { continue }
            guard folderComponents.count <= targetComponents.count else { continue }
            guard Array(targetComponents.prefix(folderComponents.count)) == folderComponents else { continue }
            best = folder
            bestDepth = folderComponents.count
        }
        return best
    }

    /// Resolves whether a stored authorization is currently usable.
    /// Unavailable = the folder itself no longer exists.
    /// NeedsReauthorization = bookmark cannot resolve or access cannot start.
    static func status(for folder: AuthorizedFolder) -> AuthorizationStatus {
        switch SecurityScopedBookmark.resolve(folder.bookmarkData) {
        case .failure:
            return .needsReauthorization
        case .success(let resolved, let isStale):
            if isStale { return .needsReauthorization }
            if !FileManager.default.fileExists(atPath: resolved.path) {
                return .unavailable
            }
            let started = resolved.startAccessingSecurityScopedResource()
            defer {
                if started { resolved.stopAccessingSecurityScopedResource() }
            }
            return started ? .authorized : .needsReauthorization
        }
    }

    private static func normalizedComponents(of path: String) -> [String] {
        URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    }
}
