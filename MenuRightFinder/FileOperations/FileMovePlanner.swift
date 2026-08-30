import Foundation

/// Per-item move decision produced by the planner. Pure logic: filesystem facts
/// (is a URL a directory, does a target already exist) are injected via
/// closures so the planner is fully unit-testable.
enum FileMoveDecision: Equatable {
    case proceed(destinationURL: URL)
    case conflict(destinationURL: URL)
    case noOp
    case invalid(String)
}

struct FileMovePlan: Equatable {
    let sourceURL: URL
    let decision: FileMoveDecision
}

/// Guards and planning for Cut/Paste moves.
///
/// A normal FileManager multi-item move is not atomic, so each source is
/// planned independently and executed independently; the batch summary reports
/// partial success honestly instead of pretending to be transactional.
///
/// Containment and placement checks compare URL *path components*, which are
/// trailing-slash insensitive — "/a/b" and "/a/b/" are treated the same, and
/// "/foo/barista" is never a descendant of "/foo/bar".
enum FileMovePlanner {
    static func plan(
        sourceURLs: [URL],
        destinationDirectory: URL,
        isDirectory: (URL) -> Bool,
        fileExists: (URL) -> Bool
    ) -> [FileMovePlan] {
        let destination = destinationDirectory.standardizedFileURL
        return sourceURLs.map { source in
            FileMovePlan(
                sourceURL: source.standardizedFileURL,
                decision: decision(
                    for: source.standardizedFileURL,
                    destinationDirectory: destination,
                    isDirectory: isDirectory,
                    fileExists: fileExists
                )
            )
        }
    }

    private static func decision(
        for source: URL,
        destinationDirectory: URL,
        isDirectory: (URL) -> Bool,
        fileExists: (URL) -> Bool
    ) -> FileMoveDecision {
        let sourceComponents = source.pathComponents
        let destinationComponents = destinationDirectory.pathComponents

        // Same directory: moving an item back into its own parent is a no-op.
        if source.deletingLastPathComponent().pathComponents == destinationComponents {
            return .noOp
        }
        // Folder into itself (destination IS the folder).
        if sourceComponents == destinationComponents {
            return .invalid("The folder cannot be moved into itself.")
        }
        // Folder into one of its own subfolders.
        if isDirectory(source) && isDescendant(components: destinationComponents, ofComponents: sourceComponents) {
            return .invalid("The folder cannot be moved into its own subfolder.")
        }
        let target = destinationDirectory.appendingPathComponent(source.lastPathComponent).standardizedFileURL
        if fileExists(target) {
            return .conflict(destinationURL: target)
        }
        return .proceed(destinationURL: target)
    }

    /// True when url sits strictly below ancestor, compared component-wise.
    private static func isDescendant(components url: [String], ofComponents ancestor: [String]) -> Bool {
        guard ancestor.count < url.count else { return false }
        return Array(url.prefix(ancestor.count)) == ancestor
    }
}
