import Foundation
import os

private let bookmarkDiag = Logger(subsystem: "xin.ljhsu.MenuRight", category: "bookmark-diag")

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
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                return (url, isStale)
            } catch {
                let nsError = error as NSError
                bookmarkDiag.log("BOOKMARK resolve(withSecurityScope) FAILED outer domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) desc=\(nsError.localizedDescription, privacy: .public)")
                var uiPairs: [String] = []
                for (k, v) in nsError.userInfo {
                    uiPairs.append(String(describing: k) + "=" + String(describing: v))
                }
                let uiJoined: String = uiPairs.joined(separator: " | ")
                bookmarkDiag.log("BOOKMARK userInfo=[\(uiJoined, privacy: .public)]")
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    var uPairs: [String] = []
                    for (k, v) in underlying.userInfo {
                        uPairs.append(String(describing: k) + "=" + String(describing: v))
                    }
                    let uJoined: String = uPairs.joined(separator: " | ")
                    bookmarkDiag.log("BOOKMARK underlying domain=\(underlying.domain, privacy: .public) code=\(underlying.code, privacy: .public) desc=\(underlying.localizedDescription, privacy: .public) userInfo=[\(uJoined, privacy: .public)]")
                } else {
                    bookmarkDiag.log("BOOKMARK underlying: none")
                }
                var plainIsStale = false
                do {
                    _ = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &plainIsStale)
                    bookmarkDiag.log("BOOKMARK resolve(plain, no security scope) SUCCEEDED — bookmark data is valid; .withSecurityScope path is rejected for this process")
                } catch let plainError as NSError {
                    bookmarkDiag.log("BOOKMARK resolve(plain) FAILED domain=\(plainError.domain, privacy: .public) code=\(plainError.code, privacy: .public) desc=\(plainError.localizedDescription, privacy: .public)")
                }
                throw error
            }
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
    /// TEMPORARY DIAGNOSTICS: underlying-error detail for resolve/start failures.
    private static let diag = Logger(subsystem: "xin.ljhsu.MenuRight", category: "finder-sync-lifecycle")

    /// Resolves one authorized folder's bookmark and takes scoped access,
    /// transparently refreshing a stale bookmark and persisting the renewed
    /// data through `persistRefreshedBookmark`.
    ///
    /// `onStarted` fires as soon as scoped access has been taken — even when the
    /// subsequent refresh fails — so the caller can guarantee the matching
    /// `stopAccess` runs (start/stop balance is an invariant of this type).
    ///
    /// Stale handling is intentionally shared by the single-target and
    /// multi-target entry points: the same environment must not behave
    /// differently depending on how many paths an operation touches.
    private static func startAccess(
        for authorizedFolder: AuthorizedFolder,
        targetURL: URL,
        configuration config: ScopedAccessConfiguration,
        persistRefreshedBookmark: ((AuthorizedFolder, Data) throws -> Void)?,
        onStarted: (URL) -> Void
    ) throws -> URL {
        var folder = authorizedFolder
        let resolvedURL: URL
        let isStale: Bool
        do {
            let resolved = try config.resolveBookmark(folder.bookmarkData)
            resolvedURL = resolved.url
            isStale = resolved.isStale
        } catch {
            Self.diag.log("AUTHORIZATION bookmarkResolveFailed target=\(targetURL.path, privacy: .public) root=\(folder.originalPath, privacy: .public) underlying=\(String(describing: error), privacy: .public)")
            throw FolderAuthorizationError.bookmarkResolveFailed(targetURL)
        }

        guard config.startAccess(resolvedURL) else {
            if isStale {
                // A stale bookmark that cannot even start access needs the user.
                throw FolderAuthorizationError.staleBookmarkNeedsReauthorization(targetURL)
            }
            Self.diag.log("AUTHORIZATION accessStartFailed target=\(targetURL.path, privacy: .public) resolvedRoot=\(resolvedURL.path, privacy: .public)")
            throw FolderAuthorizationError.accessStartFailed(targetURL)
        }
        onStarted(resolvedURL)

        guard isStale else { return resolvedURL }

        // A stale bookmark may still resolve; take access, then refresh. If the
        // refresh cannot be persisted we surface "needs reauthorization" rather
        // than silently continuing to use stale data.
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
        return resolvedURL
    }

    /// The bookmark — not the stored `originalPath` metadata — is the
    /// authoritative capability. Matching only pre-filters; if the resolved root
    /// does not actually contain the target, refuse rather than operate on a
    /// path we cannot prove is authorized.
    private static func authorizeResolvedRoot(
        _ resolvedURL: URL,
        targetURL: URL,
        metadataRoot: String
    ) throws {
        guard AuthorizedURLResolver.contains(resolvedURL, targetURL) else {
            Self.diag.log("AUTHORIZATION resolvedRootDoesNotContainTarget target=\(targetURL.path, privacy: .public) resolvedRoot=\(resolvedURL.path, privacy: .public) metadataRoot=\(metadataRoot, privacy: .public)")
            throw FolderAuthorizationError.authorizationRequired(targetURL)
        }
    }

    static func withAccess<Result>(
        to targetURL: URL,
        folders: [AuthorizedFolder],
        configuration config: ScopedAccessConfiguration = .system,
        persistRefreshedBookmark: ((AuthorizedFolder, Data) throws -> Void)? = nil,
        _ body: (URL) throws -> Result
    ) throws -> Result {
        guard let folder = AuthorizedURLResolver.folderMatching(targetURL, folders: folders) else {
            throw FolderAuthorizationError.authorizationRequired(targetURL)
        }

        var startedURL: URL?
        defer {
            if let startedURL { config.stopAccess(startedURL) }
        }

        let resolvedURL = try startAccess(
            for: folder,
            targetURL: targetURL,
            configuration: config,
            persistRefreshedBookmark: persistRefreshedBookmark,
            onStarted: { startedURL = $0 }
        )
        try authorizeResolvedRoot(resolvedURL, targetURL: targetURL, metadataRoot: folder.originalPath)
        return try body(resolvedURL)
    }

    /// Applies access to every distinct authorized root covering targetURLs
    /// (e.g. source parents and the paste destination). Roots already covered
    /// by the same authorization are started exactly once; all scopes are
    /// stopped in reverse order on exit. Stale bookmarks are refreshed and
    /// persisted with the same policy as `withAccess`.
    static func withAccesses<Result>(
        to targetURLs: [URL],
        folders: [AuthorizedFolder],
        configuration config: ScopedAccessConfiguration = .system,
        persistRefreshedBookmark: ((AuthorizedFolder, Data) throws -> Void)? = nil,
        _ body: () throws -> Result
    ) throws -> Result {
        // Group the requested targets by the authorized folder that covers them,
        // preserving order, so each root is started exactly once.
        var ordered: [(folder: AuthorizedFolder, targets: [URL])] = []
        for target in targetURLs {
            guard let folder = AuthorizedURLResolver.folderMatching(target, folders: folders) else {
                throw FolderAuthorizationError.authorizationRequired(target)
            }
            if let index = ordered.firstIndex(where: { $0.folder.id == folder.id }) {
                ordered[index].targets.append(target)
            } else {
                ordered.append((folder, [target]))
            }
        }

        var startedScopes: [URL] = []
        defer {
            for scope in startedScopes.reversed() {
                config.stopAccess(scope)
            }
        }

        for entry in ordered {
            let metadataRoot = URL(fileURLWithPath: entry.folder.originalPath)
            let resolvedURL = try startAccess(
                for: entry.folder,
                targetURL: metadataRoot,
                configuration: config,
                persistRefreshedBookmark: persistRefreshedBookmark,
                onStarted: { startedScopes.append($0) }
            )
            for target in entry.targets {
                try authorizeResolvedRoot(resolvedURL, targetURL: target, metadataRoot: entry.folder.originalPath)
            }
        }
        return try body()
    }
}
