import Foundation

/// Filesystem mutations for File Operations. Foundation/FileManager only —
/// never shell commands. Writes happen only when a real Finder URL is supplied
/// by callers (the Finder Sync context); no paths are invented here.
enum FileOperationService {
    static func createFile(in directory: URL, preferredName: String, contents: Data?) -> Result<URL, FileOperationError> {
        guard isExistingDirectory(directory) else {
            return .failure(.invalidDestination(directory.path))
        }
        let name = FileNameResolver.uniqueName(preferred: preferredName, existing: existingNames(in: directory))
        let url = directory.appendingPathComponent(name)
        // Defence in depth: the dispatcher validates `name` at the IPC trust
        // boundary, but never write outside the requested directory even if a
        // caller skipped that validation.
        guard AuthorizedURLResolver.isDirectChild(url, of: directory) else {
            return .failure(.invalidMove("refusing to write outside “\(directory.path)”: \(name)"))
        }
        do {
            try (contents ?? Data()).write(to: url, options: [.withoutOverwriting])
            return .success(url)
        } catch {
            return .failure(FileOperationError.from(error))
        }
    }

    /// P6-b: creates a document by copying a blank template.
    ///
    /// Used for Pages/Numbers/Keynote, whose formats cannot be synthesized. The
    /// copy is a plain `copyItem`, so whichever shape the template has (an iWork
    /// package directory, or a flat file on a non-HFS volume) is preserved.
    /// Never overwrites: the destination name goes through `FileNameResolver`
    /// exactly like the generated kinds.
    static func createFileFromTemplate(
        template: URL,
        in directory: URL,
        preferredName: String
    ) -> Result<URL, FileOperationError> {
        guard isExistingDirectory(directory) else {
            return .failure(.invalidDestination(directory.path))
        }
        guard FileManager.default.fileExists(atPath: template.path) else {
            return .failure(.sourceDoesNotExist(template))
        }
        let name = FileNameResolver.uniqueName(preferred: preferredName, existing: existingNames(in: directory))
        let url = directory.appendingPathComponent(name)
        guard AuthorizedURLResolver.isDirectChild(url, of: directory) else {
            return .failure(.invalidMove("refusing to write outside “\(directory.path)”: \(name)"))
        }
        do {
            try FileManager.default.copyItem(at: template, to: url)
            return .success(url)
        } catch {
            return .failure(FileOperationError.from(error))
        }
    }

    static func createDirectory(in directory: URL, preferredName: String) -> Result<URL, FileOperationError> {
        guard isExistingDirectory(directory) else {
            return .failure(.invalidDestination(directory.path))
        }
        let name = FileNameResolver.uniqueName(preferred: preferredName, existing: existingNames(in: directory))
        let url = directory.appendingPathComponent(name)
        guard AuthorizedURLResolver.isDirectChild(url, of: directory) else {
            return .failure(.invalidMove("refusing to create outside “\(directory.path)”: \(name)"))
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return .success(url)
        } catch {
            return .failure(FileOperationError.from(error))
        }
    }

    /// Moves every source into destinationDirectory independently and reports
    /// per-item results. Never overwrites: conflicts are failures.
    static func moveItems(_ sourceURLs: [URL], to destinationDirectory: URL) -> [FileOperationItemResult] {
        guard isExistingDirectory(destinationDirectory) else {
            return sourceURLs.map { source in
                FileOperationItemResult(
                    sourceURL: source,
                    destinationURL: nil,
                    status: .failed(.invalidDestination(destinationDirectory.path))
                )
            }
        }
        let plans = FileMovePlanner.plan(
            sourceURLs: sourceURLs,
            destinationDirectory: destinationDirectory,
            isDirectory: { url in (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false },
            fileExists: { url in FileManager.default.fileExists(atPath: url.path) }
        )
        return plans.map(execute)
    }

    private static func execute(_ plan: FileMovePlan) -> FileOperationItemResult {
        switch plan.decision {
        case .noOp:
            return FileOperationItemResult(sourceURL: plan.sourceURL, destinationURL: plan.sourceURL, status: .success)
        case .invalid(let reason):
            return FileOperationItemResult(sourceURL: plan.sourceURL, destinationURL: nil, status: .failed(.invalidMove(reason)))
        case .conflict(let destinationURL):
            return FileOperationItemResult(sourceURL: plan.sourceURL, destinationURL: destinationURL, status: .failed(.destinationExists(destinationURL)))
        case .proceed(let destinationURL):
            guard FileManager.default.fileExists(atPath: plan.sourceURL.path) else {
                return FileOperationItemResult(sourceURL: plan.sourceURL, destinationURL: destinationURL, status: .failed(.sourceDoesNotExist(plan.sourceURL)))
            }
            do {
                try FileManager.default.moveItem(at: plan.sourceURL, to: destinationURL)
                return FileOperationItemResult(sourceURL: plan.sourceURL, destinationURL: destinationURL, status: .success)
            } catch {
                return FileOperationItemResult(sourceURL: plan.sourceURL, destinationURL: destinationURL, status: .failed(FileOperationError.from(error)))
            }
        }
    }

    // MARK: - P6: aliases and the immutable flag

    /// Preferred display name for a Finder alias, matching Finder's own
    /// "<name> alias" convention. Collision handling is the caller's job.
    static func aliasName(for source: URL) -> String {
        source.lastPathComponent + " alias"
    }

    /// Creates a Finder alias for `source` inside `directory`. Never overwrites:
    /// name collisions go through `FileNameResolver` like every other create.
    static func createAlias(for source: URL, in directory: URL) -> Result<URL, FileOperationError> {
        guard isExistingDirectory(directory) else {
            return .failure(.invalidDestination(directory.path))
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            return .failure(.sourceDoesNotExist(source))
        }
        let name = FileNameResolver.uniqueName(
            preferred: aliasName(for: source),
            existing: existingNames(in: directory)
        )
        let aliasURL = directory.appendingPathComponent(name)
        guard AuthorizedURLResolver.isDirectChild(aliasURL, of: directory) else {
            return .failure(.invalidMove("refusing to create an alias outside “\(directory.path)”: \(name)"))
        }
        do {
            // A Finder alias *is* a bookmark file. Deliberately NOT
            // `.withSecurityScope`: an alias must stay resolvable by Finder for
            // the user, and must not embed one of our app-scoped capabilities.
            let bookmark = try source.bookmarkData(
                options: [.suitableForBookmarkFile],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            try URL.writeBookmarkData(bookmark, to: aliasURL)
            return .success(aliasURL)
        } catch {
            return .failure(FileOperationError.from(error))
        }
    }

    /// Sets or clears the user-immutable flag — Finder's "Locked".
    ///
    /// Only the selected items are touched (no recursion): locking a folder
    /// makes the folder itself undeletable, which is the property users expect
    /// from "Locked", and recursively flagging its contents is slow and
    /// surprising. Unlocking is always offered alongside locking, otherwise a
    /// locked item could only be removed with the terminal.
    static func setLocked(_ locked: Bool, at url: URL) -> Result<Void, FileOperationError> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.sourceDoesNotExist(url))
        }
        do {
            try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: url.path)
            return .success(())
        } catch {
            return .failure(FileOperationError.from(error))
        }
    }

    /// Reads the user-immutable flag (`UF_IMMUTABLE`).
    ///
    /// Deliberately NOT `URL.resourceValues(forKeys:)`: `URL` caches fetched
    /// resource values per instance, so a read taken before a lock/unlock would
    /// keep reporting the stale value afterwards (caught by
    /// `testSetLockedAndUnlockRoundTrip`). `attributesOfItem` always stats.
    static func isLocked(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        return (attributes[.immutable] as? Bool) ?? false
    }

    private static func existingNames(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }
    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
