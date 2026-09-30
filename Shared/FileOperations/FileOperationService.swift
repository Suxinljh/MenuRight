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

    private static func existingNames(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
