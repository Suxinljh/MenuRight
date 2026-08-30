import Foundation

enum FolderAuthorizationError: Equatable, Error {
    /// No authorized folder covers the requested URL (known before any write).
    case authorizationRequired(URL)
    /// Bookmark data could not be resolved.
    case bookmarkResolveFailed(URL)
    /// Bookmark is stale and refresh/persist did not complete.
    case staleBookmarkNeedsReauthorization(URL)
    /// startAccessingSecurityScopedResource returned false.
    case accessStartFailed(URL)
}

/// Thin seam so scoped-access lifecycle stays unit-testable without the real
/// security-scoped bookmark machinery.
struct ScopedAccessConfiguration {
    var resolveBookmark: (Data) throws -> (url: URL, isStale: Bool)
    var startAccess: (URL) -> Bool
    var stopAccess: (URL) -> Void
    var makeFreshBookmark: (URL) throws -> Data

    static let system = ScopedAccessConfiguration(
        resolveBookmark: { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        },
        startAccess: { url in url.startAccessingSecurityScopedResource() },
        stopAccess: { url in url.stopAccessingSecurityScopedResource() },
        makeFreshBookmark: { url in
            try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    )
}

/// Runs an operation while holding security-scoped access to the authorized
/// ancestor of a target URL. start/stop are always balanced (defer) — scoped
/// resource handles are never leaked.
enum FolderAuthorizationAccess {
    static func withAccess<Result>(
        to targetURL: URL,
        folders: [AuthorizedFolder],
        configuration config: ScopedAccessConfiguration = .system,
        persistRefreshedBookmark: ((AuthorizedFolder, Data) throws -> Void)? = nil,
        _ body: (URL) throws -> Result
    ) throws -> Result {
        guard var folder = AuthorizedURLResolver.folderMatching(targetURL, folders: folders) else {
            throw FolderAuthorizationError.authorizationRequired(targetURL)
        }

        let resolvedURL: URL
        let isStale: Bool
        do {
            let resolved = try config.resolveBookmark(folder.bookmarkData)
            resolvedURL = resolved.url
            isStale = resolved.isStale
        } catch {
            throw FolderAuthorizationError.bookmarkResolveFailed(targetURL)
        }

        var started = false
        defer {
            if started { config.stopAccess(resolvedURL) }
        }

        if isStale {
            // A stale bookmark may still resolve; take access, then refresh.
            guard config.startAccess(resolvedURL) else {
                throw FolderAuthorizationError.staleBookmarkNeedsReauthorization(targetURL)
            }
            started = true
            guard let persist = persistRefreshedBookmark else {
                throw FolderAuthorizationError.staleBookmarkNeedsReauthorization(targetURL)
            }
            do {
                let freshData = try config.makeFreshBookmark(resolvedURL)
                folder.bookmarkData = freshData
                try persist(folder, freshData)
            } catch {
                throw FolderAuthorizationError.staleBookmarkNeedsReauthorization(targetURL)
            }
        } else {
            guard config.startAccess(resolvedURL) else {
                throw FolderAuthorizationError.accessStartFailed(targetURL)
            }
            started = true
        }

        return try body(resolvedURL)
    }

    /// Applies access to every distinct authorized root covering targetURLs
    /// (e.g. source parents and the paste destination). Roots already covered
    /// by the same authorization are started exactly once; all scopes are
    /// stopped in reverse order on exit.
    static func withAccesses<Result>(
        to targetURLs: [URL],
        folders: [AuthorizedFolder],
        configuration config: ScopedAccessConfiguration = .system,
        _ body: () throws -> Result
    ) throws -> Result {
        for target in targetURLs where AuthorizedURLResolver.folderMatching(target, folders: folders) == nil {
            throw FolderAuthorizationError.authorizationRequired(target)
        }

        var uniqueFolders: [AuthorizedFolder] = []
        for target in targetURLs {
            if let folder = AuthorizedURLResolver.folderMatching(target, folders: folders),
               !uniqueFolders.contains(where: { $0.id == folder.id }) {
                uniqueFolders.append(folder)
            }
        }

        var startedScopes: [URL] = []
        defer {
            for scope in startedScopes.reversed() {
                config.stopAccess(scope)
            }
        }
        for folder in uniqueFolders {
            let resolved: (url: URL, isStale: Bool)
            do {
                resolved = try config.resolveBookmark(folder.bookmarkData)
            } catch {
                throw FolderAuthorizationError.bookmarkResolveFailed(URL(fileURLWithPath: folder.originalPath))
            }
            guard config.startAccess(resolved.url) else {
                throw FolderAuthorizationError.accessStartFailed(URL(fileURLWithPath: folder.originalPath))
            }
            startedScopes.append(resolved.url)
        }
        return try body()
    }
}
