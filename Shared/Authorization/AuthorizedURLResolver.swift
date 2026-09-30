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
    /// True when `descendant` is `ancestor` itself or lives below it.
    ///
    /// Component-wise comparison, so "/foo/barista" is NOT inside "/foo/bar".
    /// Both sides are standardized first (`..` and repeated separators are
    /// resolved lexically — no filesystem access, no symlink resolution).
    static func contains(_ ancestor: URL, _ descendant: URL) -> Bool {
        let ancestorComponents = ancestor.standardizedFileURL.pathComponents
        let descendantComponents = descendant.standardizedFileURL.pathComponents
        guard ancestorComponents.count <= descendantComponents.count else { return false }
        return Array(descendantComponents.prefix(ancestorComponents.count)) == ancestorComponents
    }

    /// True when `url` is a **direct** child of `directory` (exactly one extra
    /// path component). Used as the last containment check before a write, so a
    /// name that survived validation can never place the file elsewhere.
    static func isDirectChild(_ url: URL, of directory: URL) -> Bool {
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        return parent.pathComponents == directory.standardizedFileURL.pathComponents
    }

    /// Returns the most specific authorized ancestor of targetURL, or nil.
    ///
    /// This is a *pre-filter* over the stored metadata (`originalPath`). The
    /// authoritative capability is the security-scoped bookmark; callers must
    /// still confirm that the resolved bookmark root actually contains the
    /// target (see `FolderAuthorizationAccess`).
    static func folderMatching(_ targetURL: URL, folders: [AuthorizedFolder]) -> AuthorizedFolder? {
        let targetURL = targetURL.standardizedFileURL
        var best: AuthorizedFolder?
        var bestDepth = -1
        for folder in folders {
            let folderURL = URL(fileURLWithPath: folder.originalPath).standardizedFileURL
            let folderComponents = folderURL.pathComponents
            guard folderComponents.count > bestDepth else { continue }
            guard contains(folderURL, targetURL) else { continue }
            best = folder
            bestDepth = folderComponents.count
        }
        return best
    }

    /// Resolves whether a stored authorization is currently usable.
    /// Unavailable = the folder itself no longer exists.
    /// NeedsReauthorization = bookmark cannot resolve or access cannot start.
    ///
    /// NOTE: this starts/stops scoped access. Call it on an explicit refresh
    /// (view reload), never from a SwiftUI `body`.
    static func status(for folder: AuthorizedFolder) -> AuthorizationStatus {
        switch SecurityScopedBookmark.resolve(folder.bookmarkData) {
        case .failure:
            return .needsReauthorization
        case .success(let resolved):
            // `resolved` is the (url:isStale:) tuple; destructured explicitly so
            // the pattern does not rely on tuple splatting (a Swift 6 note).
            if resolved.isStale { return .needsReauthorization }
            if !FileManager.default.fileExists(atPath: resolved.url.path) {
                return .unavailable
            }
            let started = resolved.url.startAccessingSecurityScopedResource()
            defer {
                if started { resolved.url.stopAccessingSecurityScopedResource() }
            }
            return started ? .authorized : .needsReauthorization
        }
    }
}
