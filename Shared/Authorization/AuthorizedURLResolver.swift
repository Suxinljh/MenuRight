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
///
/// **Case.** `contains(_:_:)` is case-sensitive, which is the right answer on a
/// case-sensitive volume but wrong on the APFS default: `/Users/x/downloads/a`
/// and `/Users/x/Downloads/a` are one directory there, and a user who authorized
/// "Downloads" would be refused for typing "downloads". `containsOnDisk(_:_:)`
/// asks the volume which rule applies (cached per volume) and is what live
/// authorization checks use; the plain form stays available for callers that
/// only compare path strings.
///
/// **Symlinks.** Matching is lexical and deliberately never resolves symlinks:
/// that keeps it a pure function with no per-entry syscalls. A symlink *inside*
/// an authorized folder that points outside is therefore classified as inside —
/// the boundary in that case is enforced by the sandbox (which denies writing
/// through it) and by `isDirectChild` before a write, not by this pre-filter.
/// The stored bookmark, not this match, is the authoritative capability.
enum AuthorizedURLResolver {
    /// Volume cache for `containsOnDisk`; keyed by volume path so a whole
    /// operation costs one lookup.
    private static let sensitivityLock = NSLock()
    private static var sensitivityByVolume: [String: Bool] = [:]

    /// True when `descendant` is `ancestor` itself or lives below it.
    ///
    /// Component-wise comparison, so "/foo/barista" is NOT inside "/foo/bar".
    /// Both sides are standardized first (`..` and repeated separators are
    /// resolved lexically — no filesystem access, no symlink resolution).
    static func contains(_ ancestor: URL, _ descendant: URL, caseSensitive: Bool = true) -> Bool {
        let ancestorComponents = ancestor.standardizedFileURL.pathComponents
        let descendantComponents = descendant.standardizedFileURL.pathComponents
        guard ancestorComponents.count <= descendantComponents.count else { return false }
        let prefix = Array(descendantComponents.prefix(ancestorComponents.count))
        guard caseSensitive else {
            return zip(prefix, ancestorComponents).allSatisfy {
                $0.compare($1, options: [.caseInsensitive], range: nil, locale: nil) == .orderedSame
            }
        }
        return prefix == ancestorComponents
    }

    /// `contains` using the case rule the volume actually enforces. Falls back to
    /// case-sensitive when the volume cannot be inspected (a path that no longer
    /// exists), so an unknown volume can only under-match, never over-match.
    static func containsOnDisk(_ ancestor: URL, _ descendant: URL) -> Bool {
        contains(ancestor, descendant, caseSensitive: volumeSupportsCaseSensitiveNames(for: descendant))
    }

    /// True when the volume holding `url` distinguishes case in file names.
    ///
    /// The volume is read from `url` itself, or from its nearest existing
    /// ancestor when the path does not exist yet — a file that is about to be
    /// created is exactly the case this rule has to get right. Only a path whose
    /// whole ancestry is missing falls back to case-sensitive, which can only
    /// under-match, never over-match.
    static func volumeSupportsCaseSensitiveNames(for url: URL) -> Bool {
        var probe = url.standardizedFileURL
        while probe.pathComponents.count > 1, !FileManager.default.fileExists(atPath: probe.path) {
            probe.deleteLastPathComponent()
        }
        let volume = (try? probe.resourceValues(forKeys: [.volumeURLKey]).volume) ?? nil
        let key = volume?.path ?? probe.path
        sensitivityLock.lock()
        if let cached = sensitivityByVolume[key] {
            sensitivityLock.unlock()
            return cached
        }
        sensitivityLock.unlock()

        let values = try? probe.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let sensitive = values?.volumeSupportsCaseSensitiveNames ?? true
        sensitivityLock.lock()
        sensitivityByVolume[key] = sensitive
        sensitivityLock.unlock()
        return sensitive
    }

    /// True when `url` is a **direct** child of `directory` (exactly one extra
    /// path component). Used as the last containment check before a write, so a
    /// name that survived validation can never place the file elsewhere.
    ///
    /// Uses the volume's case rule for the same reason `containsOnDisk` does: on
    /// the APFS default "downloads" and "Downloads" are one directory, and
    /// refusing the write would be wrong.
    static func isDirectChild(_ url: URL, of directory: URL) -> Bool {
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        let caseSensitive = volumeSupportsCaseSensitiveNames(for: url)
        guard contains(directory, parent, caseSensitive: caseSensitive) else { return false }
        return parent.pathComponents.count == directory.standardizedFileURL.pathComponents.count
    }

    /// Returns the most specific authorized ancestor of targetURL, or nil.
    ///
    /// This is a *pre-filter* over the stored metadata (`originalPath`). The
    /// authoritative capability is the security-scoped bookmark; callers must
    /// still confirm that the resolved bookmark root actually contains the
    /// target (see `FolderAuthorizationAccess`). Matching uses the target
    /// volume's case rule: the stored `originalPath` is a string the user picked
    /// earlier, so its spelling can differ in case from the live URL.
    static func folderMatching(_ targetURL: URL, folders: [AuthorizedFolder]) -> AuthorizedFolder? {
        let targetURL = targetURL.standardizedFileURL
        let caseSensitive = volumeSupportsCaseSensitiveNames(for: targetURL)
        var best: AuthorizedFolder?
        var bestDepth = -1
        for folder in folders {
            let folderURL = URL(fileURLWithPath: folder.originalPath).standardizedFileURL
            let folderComponents = folderURL.pathComponents
            guard folderComponents.count > bestDepth else { continue }
            guard contains(folderURL, targetURL, caseSensitive: caseSensitive) else { continue }
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
