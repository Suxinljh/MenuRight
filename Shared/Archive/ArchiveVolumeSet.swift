//
//  ArchiveVolumeSet.swift
//  MenuRight
//
//  分卷压缩. Splitting an archive into `name.zip.001`, `.002`, … — the naming
//  7-Zip (`-v`), Keka, WinRAR and 360压缩 all write and read, for ZIP and 7z
//  alike, and the naming this app writes.
//

import Foundation

/// The `.001` split-archive convention: writing, discovering and joining parts.
///
/// Every format is split the same way — the archive image is cut into chunks and
/// the parts are a plain concatenation of it, so a `.001` set written here opens
/// in 7-Zip/Keka/WinRAR, and theirs opens here. The parts carry no extra header;
/// the first one *is* the front of the archive, which is why the magic bytes of
/// a `.001` read as its format (`ArchiveFormats.detect` uses that).
enum ArchiveVolumeSet {
    /// How many parts a set may have: `.001`…`.999`, 7-Zip's own ceiling. It also
    /// bounds the sibling search below, so probing is finite.
    static let maximumParts = 999

    /// `name.zip.001` → true. The name is the only marker there is.
    static func isFirstPart(_ url: URL) -> Bool {
        url.pathExtension == "001"
    }

    /// The parts that follow `firstPart`, plus `firstPart` itself, in order.
    ///
    /// Stops at the first gap: a `.003` left over from an older, longer set must
    /// not be glued onto a fresh two-part one.
    static func existingParts(firstPart url: URL) -> [URL] {
        guard isFirstPart(url) else { return [] }
        let base = url.deletingPathExtension()
        var parts = [url]
        for index in 2...maximumParts {
            let candidate = base.appendingPathExtension(partSuffix(index))
            guard FileManager.default.fileExists(atPath: candidate.path) else { break }
            parts.append(candidate)
        }
        return parts
    }

    /// `1` → `"001"`.
    static func partSuffix(_ index: Int) -> String {
        String(format: "%03d", index)
    }

    /// The part names a set with this base name occupies.
    static func partURLs(baseURL: URL, count: Int) -> [URL] {
        (1...max(count, 1)).map { baseURL.appendingPathExtension(partSuffix($0)) }
    }

    /// Cuts `data` into volumes of at most `volumeBytes` and writes them, in
    /// order, returning the part URLs.
    ///
    /// `overwrite: false` keeps an existing `.001` (`[.withoutOverwriting]` makes
    /// that atomic, so two runs cannot interleave); `overwrite: true` first
    /// removes every stale part of the same base — without that, a previous
    /// five-part run would leave its `.004`/`.005` behind and every reader would
    /// glue them onto the new image.
    ///
    /// The set is capped at `maximumParts`, the range the read side probes, and
    /// a failure part-way through deletes the parts this call already wrote: a
    /// lone `.001` with a stale tail otherwise reads as a complete archive. With
    /// `overwrite: false` an existing part is a conflict raised before the first
    /// byte, not a clobber discovered while writing the second.
    @discardableResult
    static func write(_ data: Data, baseURL: URL, volumeBytes: Int, overwrite: Bool) throws -> [URL] {
        let chunk = max(volumeBytes, 1)
        let count = max(1, (data.count + chunk - 1) / chunk)
        // `partSuffix` would grow a fourth digit past 999, a name `existingParts`
        // never probes for: the tail of such a set would be invisible to every
        // reader here. Refuse before writing rather than emit an unreadable set.
        guard count <= maximumParts else {
            throw ArchiveError.writeFailed(
                "“\(baseURL.lastPathComponent)”: the image needs \(count) parts, more than the \(maximumParts) a split set can have"
            )
        }
        let parts = partURLs(baseURL: baseURL, count: count)
        if overwrite {
            removeStaleParts(baseURL: baseURL)
        } else if let taken = parts.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            // `[.withoutOverwriting]` would otherwise abort on the second part
            // with the first already on disk, and that half set reads as a
            // complete one (`.001` is the marker, and the stale `.002` is glued
            // straight back on). Refuse before the first byte instead.
            throw ArchiveError.conflict("“\(taken.lastPathComponent)” already exists; refusing to overwrite it")
        }
        var written: [URL] = []
        do {
            let options: Data.WritingOptions = overwrite ? [.atomic] : [.withoutOverwriting]
            for (index, part) in parts.enumerated() {
                let start = index * chunk
                let end = min(start + chunk, data.count)
                try data.subdata(in: start..<end).write(to: part, options: options)
                written.append(part)
            }
        } catch {
            // Only the parts this call produced: a path that existed before
            // `write` was entered is not this rollback's to delete.
            for part in written {
                try? FileManager.default.removeItem(at: part)
            }
            throw error
        }
        return parts
    }

    /// Deletes every `base.001`…`base.999` that is there; missing ones are fine.
    ///
    /// One directory listing rather than 999 probes: a `removeItem` per index
    /// would be a thousand `unlink(2)` calls for the common no-stale-parts case.
    static func removeStaleParts(baseURL: URL) {
        let directory = baseURL.deletingLastPathComponent()
        let prefix = baseURL.lastPathComponent + "."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            let suffix = String(name.dropFirst(prefix.count))
            guard suffix.count == 3, suffix.allSatisfy(\.isNumber) else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// A split archive resolved into something the rest of the pipeline can read.
    struct Resolved {
        /// What to read: the archive itself, or a joined temporary copy.
        let url: URL
        /// The `.001`… set as it exists on disk; empty when `url` was not split.
        let parts: [URL]
        /// Non-nil when `url` is a temporary file that has to be removed again.
        let scratchDirectory: URL?

        /// The files 解压后删除压缩包 has to delete: every part of a split set,
        /// the archive itself otherwise.
        var sourceFiles: [URL] { parts.isEmpty ? [url] : parts }

        /// Removes the joined copy. Safe to call when there is none.
        func discard() {
            if let scratchDirectory { try? FileManager.default.removeItem(at: scratchDirectory) }
        }
    }

    /// Joins `name.zip.001` + `.002` + … into one temporary file, so that the
    /// password probe, format detection and the extractors all see an ordinary
    /// single-file archive.
    ///
    /// The copy is streamed: a split archive is exactly the case where the image
    /// is too large to want in memory twice.
    static func resolve(_ url: URL) throws -> Resolved {
        let parts = existingParts(firstPart: url)
        guard parts.count > 1 else { return Resolved(url: url, parts: [], scratchDirectory: nil) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuRight-Volumes", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let joined = directory.appendingPathComponent(url.deletingPathExtension().lastPathComponent)

        guard FileManager.default.createFile(atPath: joined.path, contents: nil) else {
            try? FileManager.default.removeItem(at: directory)
            throw ArchiveError.readFailed("“\(url.lastPathComponent)”: could not create the joined copy")
        }
        do {
            let writer = try FileHandle(forWritingTo: joined)
            defer { try? writer.close() }
            for part in parts {
                let reader = try FileHandle(forReadingFrom: part)
                defer { try? reader.close() }
                while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try writer.write(contentsOf: chunk)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw ArchiveError.readFailed("“\(url.lastPathComponent)”: \(error.localizedDescription)")
        }
        return Resolved(url: joined, parts: parts, scratchDirectory: directory)
    }
}
