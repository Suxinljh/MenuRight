import Foundation

/// Everything that can make an extraction refuse to run or skip an entry.
enum ArchiveError: Error, Equatable {
    /// The selection is not an archive this build can open.
    case unsupportedFormat(String)
    case notAnArchive(String)
    /// An entry name tried to escape the destination directory (zip slip).
    case unsafePath(String)
    /// Payload above the configured limit. Checked *before* anything is written
    /// whenever the container declares sizes.
    case tooLarge(String)
    /// The destination name is taken and the policy says not to overwrite.
    case conflict(String)
    case readFailed(String)
    case writeFailed(String)
}

/// Why an entry was left out.
///
/// Conforms to `Error` only so `safeRelativePath` can return a `Result` and the
/// call sites keep `try`-style ergonomics; a skip is not a failure.
enum ArchiveSkipReason: Error, Equatable {
    /// Name would escape the destination (`../`, absolute, backslash, NUL).
    case unsafePath(String)
    /// A symlink entry: writing one is a documented way to escape the root.
    case symbolicLink
    /// `__MACOSX/`, `.DS_Store`, `._*` — with the default settings.
    case metadata
    /// Already there, policy is `.skip`.
    case conflict
    /// Writing over the archive we are reading.
    case wouldReplaceArchive
}

enum ArchiveEntryOutcome: Equatable {
    case written
    case skipped(ArchiveSkipReason)
    case failed(String)
}

struct ArchiveEntryResult: Equatable {
    let entryName: String
    let destinationPath: String?
    let outcome: ArchiveEntryOutcome

    var isFailure: Bool {
        if case .failed = outcome { return true }
        return false
    }

    var isSkip: Bool {
        if case .skipped = outcome { return true }
        return false
    }
}

struct ArchiveExtractionSummary: Equatable {
    let written: Int
    let skipped: Int
    let failed: Int

    var allSucceeded: Bool { failed == 0 && skipped == 0 }
}

/// One entry's decided fate, computed with **no filesystem access**.
enum ArchiveExtractionStep: Equatable {
    case directory(relativePath: String)
    case file(member: ArchiveMember, relativePath: String)
    case skipped(member: ArchiveMember, relativePath: String, reason: ArchiveSkipReason)
}

/// The pure half of extraction: names, limits, metadata and duplicate handling.
///
/// Keeping the decisions separate from the writes is what makes the security
/// rules testable without crafting real archives — and, since every format
/// funnels through `ArchiveMember`, the same rules cover ZIP, 7-Zip and TAR
/// without being re-implemented per backend.
enum ArchiveExtractionPlanner {
    /// Name prefixes/extensions that are metadata, not user content.
    static let metadataPrefixes = ["__MACOSX/"]
    static let metadataNames: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini"]

    /// Normalises an entry name into a destination-relative path.
    ///
    /// Returns the reason when the name must not be written. The rules are the
    /// OWASP "zip slip" set: no absolute paths, no `..` component, no
    /// backslashes (which some tools treat as separators), no NUL, no drive
    /// letters, and nothing that normalises to the root itself.
    static func safeRelativePath(_ rawName: String) -> Result<String, ArchiveSkipReason> {
        var name = rawName
        if name.utf8.contains(0) { return .failure(.unsafePath("NUL in entry name")) }
        if name.contains("\\") { return .failure(.unsafePath(rawName)) }
        if name.hasPrefix("/") { return .failure(.unsafePath(rawName)) }
        // "C:\..." or "C:/..." style absolute names.
        if name.count >= 2, name[name.index(name.startIndex, offsetBy: 1)] == ":" {
            return .failure(.unsafePath(rawName))
        }
        if name.isEmpty { return .failure(.unsafePath("empty entry name")) }

        // Directory entries end with "/": keep that information, drop the slash
        // for the component walk.
        let isDirectoryName = name.hasSuffix("/")
        if isDirectoryName { name.removeLast() }
        if name.isEmpty { return .failure(.unsafePath(rawName)) }

        var components: [String] = []
        for component in name.split(separator: "/", omittingEmptySubsequences: false) {
            switch component {
            case "", ".":
                continue
            case "..":
                // Never acceptable, even when it would stay inside: an entry
                // that leaves the root and comes back is a traversal payload.
                return .failure(.unsafePath(rawName))
            default:
                components.append(String(component))
            }
        }
        guard !components.isEmpty else { return .failure(.unsafePath(rawName)) }
        var relative = components.joined(separator: "/")
        if isDirectoryName { relative += "/" }
        return .success(relative)
    }

    static func isMetadata(_ relativePath: String) -> Bool {
        if metadataPrefixes.contains(where: { relativePath.hasPrefix($0) }) { return true }
        let leaf = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        if metadataNames.contains(leaf) { return true }
        return leaf.hasPrefix("._")
    }

    /// Plans every member, in archive order.
    ///
    /// - Throws `.tooLarge` when the payload the archive *declares* exceeds the
    ///   limit, before a single file is created — that is the zip-bomb guard.
    /// - Throws `.unsupportedFormat` for an entry the backend cannot inflate
    ///   rather than half-extracting and then failing.
    /// - Duplicate destination paths inside one archive are resolved the same
    ///   way as collisions with existing files (`keepBoth` numbers them, `skip`
    ///   drops the later one, `overwrite` lets it win).
    static func plan(
        members: [ArchiveMember],
        conflictPolicy: ArchiveConflictPolicy,
        skipsMetadataEntries: Bool,
        maximumUncompressedBytes: Int64
    ) throws -> [ArchiveExtractionStep] {
        let declaredPayload = members.reduce(Int64(0)) { $0 + max(0, $1.uncompressedSize) }
        guard declaredPayload <= maximumUncompressedBytes else {
            throw ArchiveError.tooLarge("\(declaredPayload) bytes declared, limit is \(maximumUncompressedBytes)")
        }

        var steps: [ArchiveExtractionStep] = []
        steps.reserveCapacity(members.count)
        var claimed = Set<String>()

        for member in members {
            guard member.isDecompressible else {
                throw ArchiveError.unsupportedFormat("“\(member.name)” uses a compression method this build cannot read")
            }

            let relative: String
            switch safeRelativePath(member.name) {
            case .success(let value):
                relative = value
            case .failure(let reason):
                steps.append(.skipped(member: member, relativePath: member.name, reason: reason))
                continue
            }

            if member.isSymbolicLink {
                steps.append(.skipped(member: member, relativePath: relative, reason: .symbolicLink))
                continue
            }
            if skipsMetadataEntries && isMetadata(relative) {
                steps.append(.skipped(member: member, relativePath: relative, reason: .metadata))
                continue
            }
            if member.uncompressedSize > maximumUncompressedBytes {
                throw ArchiveError.tooLarge("“\(member.name)” alone is \(member.uncompressedSize) bytes")
            }

            let key = relative.lowercased()
            if conflictPolicy == .skip, claimed.contains(key) {
                // Two entries with one name, and the policy is "don't touch
                // whatever is already there": the later one is dropped here,
                // before any write.
                steps.append(.skipped(member: member, relativePath: relative, reason: .conflict))
                continue
            }
            // `keepBoth` and `overwrite` both keep every step: collisions inside
            // one archive are resolved by the executor, which is the side that
            // knows what is already on disk (and numbers duplicates for
            // `keepBoth`).
            claimed.insert(key)
            steps.append(member.isDirectory
                ? .directory(relativePath: relative)
                : .file(member: member, relativePath: relative))
        }

        return steps
    }
}

/// The IO half: opens the archive through the right backend and performs the
/// planner's steps.
enum ArchiveExtractor {
    /// Extracts `archiveURL` into `destinationDirectory`.
    ///
    /// Nothing is written before the whole plan is validated (names, size,
    /// compression methods), so a rejected archive leaves the destination
    /// untouched.
    static func extract(
        archiveURL: URL,
        to destinationDirectory: URL,
        settings: ArchiveSettings,
        conflictPolicy: ArchiveConflictPolicy? = nil,
        sizeLimitMB: Int? = nil
    ) throws -> (results: [ArchiveEntryResult], summary: ArchiveExtractionSummary) {
        let policy = conflictPolicy ?? settings.conflictPolicy
        let limit = Int64(sizeLimitMB ?? settings.sizeLimitMB) * 1024 * 1024

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destinationDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ArchiveError.writeFailed("“\(destinationDirectory.path)” is not a folder")
        }

        let format = ArchiveFormats.detect(at: archiveURL)
        let source = try ArchiveMemberSourceFactory.make(url: archiveURL, format: format)

        // These containers state no payload size, so the guard has to happen on
        // the compressed file (and, for gzip, on its trailing ISIZE) before the
        // single payload is materialized.
        if let single = source as? SingleMemberSource {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: archiveURL.path)[.size] as? Int64) ?? 0
            if fileSize > limit {
                throw ArchiveError.tooLarge("“\(archiveURL.lastPathComponent)” is larger than the \(limit / 1024 / 1024) MB limit")
            }
            if let declared = single.declaredPayloadSize(), declared > limit {
                throw ArchiveError.tooLarge("\(declared) bytes declared, limit is \(limit)")
            }
        }

        let members = try source.members()
        let steps = try ArchiveExtractionPlanner.plan(
            members: members,
            conflictPolicy: policy,
            skipsMetadataEntries: settings.skipsMetadataEntries,
            maximumUncompressedBytes: limit
        )

        let manager = FileManager.default
        var results: [ArchiveEntryResult] = []
        results.reserveCapacity(steps.count)
        /// Destination paths created by *this* extraction, so two identical
        /// entries do not silently clobber each other.
        var taken = Set<String>()
        let archivePath = archiveURL.standardizedFileURL.path
        var writtenBytes: Int64 = 0

        for step in steps {
            switch step {
            case .skipped(let member, let relative, let reason):
                results.append(ArchiveEntryResult(
                    entryName: member.name,
                    destinationPath: relative,
                    outcome: .skipped(reason)
                ))

            case .directory(let relative):
                let url = destinationDirectory.appendingPathComponent(relative)
                do {
                    try manager.createDirectory(at: url, withIntermediateDirectories: true)
                    taken.insert(url.standardizedFileURL.path.lowercased())
                    results.append(ArchiveEntryResult(entryName: relative, destinationPath: url.path, outcome: .written))
                } catch {
                    results.append(ArchiveEntryResult(entryName: relative, destinationPath: url.path, outcome: .failed(error.localizedDescription)))
                }

            case .file(let member, let relative):
                let target = destinationDirectory.appendingPathComponent(relative)
                let outcome = write(
                    member: member,
                    source: source,
                    target: target,
                    relative: relative,
                    archivePath: archivePath,
                    policy: policy,
                    taken: &taken
                )
                if case .written = outcome.outcome, let path = outcome.path,
                   let size = (try? manager.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil {
                    writtenBytes += size
                    // Second line of defence for containers that declare no size:
                    // stop as soon as the payload crosses the limit.
                    if writtenBytes > limit {
                        try? manager.removeItem(atPath: path)
                        throw ArchiveError.tooLarge("extraction exceeded the \(limit / 1024 / 1024) MB limit")
                    }
                }
                results.append(ArchiveEntryResult(
                    entryName: member.name,
                    destinationPath: outcome.path ?? target.path,
                    outcome: outcome.outcome
                ))
            }
        }

        let summary = ArchiveExtractionSummary(
            written: results.filter { $0.outcome == .written }.count,
            skipped: results.filter(\.isSkip).count,
            failed: results.filter(\.isFailure).count
        )

        // Configured behaviour: remove the archive once it extracted cleanly.
        if settings.deletesArchiveAfterExtraction, summary.failed == 0 {
            try? manager.removeItem(at: archiveURL)
        }

        return (results, summary)
    }

    private struct WriteOutcome {
        let outcome: ArchiveEntryOutcome
        let path: String?
    }

    private static func write(
        member: ArchiveMember,
        source: ArchiveMemberSource,
        target: URL,
        relative: String,
        archivePath: String,
        policy: ArchiveConflictPolicy,
        taken: inout Set<String>
    ) -> WriteOutcome {
        let manager = FileManager.default
        var destination = target

        // Never write over the archive we are reading, whatever the policy.
        if destination.standardizedFileURL.path == archivePath {
            return WriteOutcome(outcome: .skipped(.wouldReplaceArchive), path: destination.path)
        }

        var isDirectory: ObjCBool = false
        let exists = manager.fileExists(atPath: destination.path, isDirectory: &isDirectory)

        if exists {
            switch policy {
            case .skip:
                return WriteOutcome(outcome: .skipped(.conflict), path: destination.path)
            case .overwrite:
                if isDirectory.boolValue {
                    // A file cannot replace a directory; leave the directory and
                    // report it instead of destroying it.
                    return WriteOutcome(outcome: .skipped(.conflict), path: destination.path)
                }
            case .keepBoth:
                if isDirectory.boolValue {
                    return WriteOutcome(outcome: .skipped(.conflict), path: destination.path)
                }
                destination = numbered(destination)
            }
        }

        // A path this extraction already wrote (two entries with the same name).
        while taken.contains(destination.standardizedFileURL.path.lowercased()) {
            guard policy == .keepBoth else {
                return WriteOutcome(outcome: .skipped(.conflict), path: destination.path)
            }
            destination = numbered(destination)
        }

        do {
            let contents = try source.contents(of: member)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if policy == .overwrite {
                try contents.write(to: destination, options: [.atomic])
            } else {
                try contents.write(to: destination, options: [.withoutOverwriting])
            }
            taken.insert(destination.standardizedFileURL.path.lowercased())
            return WriteOutcome(outcome: .written, path: destination.path)
        } catch let error as ArchiveError {
            return WriteOutcome(outcome: .failed(describe(error)), path: destination.path)
        } catch {
            return WriteOutcome(outcome: .failed(error.localizedDescription), path: destination.path)
        }
    }

    /// `a.txt` → `a 2.txt`, using the same rule as every other create path.
    private static func numbered(_ url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let unique = FileNameResolver.uniqueName(preferred: url.lastPathComponent, existing: siblings)
        return directory.appendingPathComponent(unique)
    }

    /// Maps a reader failure onto the extraction vocabulary.
    static func map(_ error: ZipReaderError, archive: URL) -> ArchiveError {
        switch error {
        case .notAnArchive, .truncated, .corruptEntry, .crcMismatch, .inflateFailed:
            return .notAnArchive("“\(archive.lastPathComponent)”: \(describe(error))")
        case .zip64Unsupported:
            return .unsupportedFormat("ZIP64 archives are not supported (over 4 GiB or more than 65535 entries)")
        case .unsupportedCompression, .encryptedNotSupported:
            return .unsupportedFormat(describe(error))
        }
    }

    /// Developer-facing description; the extension shows it verbatim on failure.
    static func describe(_ error: ArchiveError) -> String {
        switch error {
        case .unsupportedFormat(let detail): return "Unsupported archive: \(detail)"
        case .notAnArchive(let detail): return "Not a readable archive: \(detail)"
        case .unsafePath(let detail): return "Refused an entry that escapes the destination folder: \(detail)"
        case .tooLarge(let detail): return "Archive exceeds the size limit: \(detail)"
        case .conflict(let detail): return "A file with that name already exists: \(detail)"
        case .readFailed(let detail): return "Could not read the archive: \(detail)"
        case .writeFailed(let detail): return "Could not write the archive: \(detail)"
        }
    }

    static func describe(_ error: ZipReaderError) -> String {
        switch error {
        case .notAnArchive: return "not a ZIP archive"
        case .truncated: return "the archive is truncated"
        case .zip64Unsupported: return "ZIP64 is not supported"
        case .unsupportedCompression(let method): return "unsupported compression method \(method)"
        case .encryptedNotSupported: return "the archive is password-protected, which this build does not support"
        case .corruptEntry(let name): return "corrupt entry \(name)"
        case .crcMismatch(let name): return "CRC mismatch in \(name)"
        case .inflateFailed(let name): return "could not decompress \(name)"
        }
    }
}
