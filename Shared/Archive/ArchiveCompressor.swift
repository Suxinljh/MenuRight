import Foundation
import SWCompression

/// Builds archives from Finder selections (P9).
///
/// Directory trees are walked in a stable order, empty folders are kept (an
/// entry per directory), and **symbolic links are skipped and reported**: a link
/// can point anywhere, so following one would mean packaging files the user did
/// not select, and storing one would mean writing it back on extraction.
///
/// The archive is assembled in memory, so the configured size limit is enforced
/// on the *input* total as well: refusing with a clear error beats being killed
/// by the memory watchdog.
///
/// Formats:
/// - ZIP — our own `ZipWriter` (the reader half is `ZipReader`, and the two are
///   tested against each other).
/// - TAR — SWCompression's `TarContainer.create`.
/// - TAR.GZ / TAR.BZ2 — the same TAR, wrapped by `GzipArchive` / `Bzip2`.
///
/// 7-Zip and XZ are **read-only** in this build: SWCompression has no writer for
/// either, and writing 7-Zip would mean implementing a coder from scratch.
/// How hard the compressor tries — the dialog's 压缩模式.
///
/// It is a real knob, not decoration: it maps to the DEFLATE level for ZIP and
/// to the BZip2 block size for `.tar.bz2`. Formats without a compression
/// parameter (TAR is uncompressed; the library's gzip writer takes none) accept
/// it and ignore it, which the UI says out loud rather than pretending.
enum ArchiveCompressionMode: String, CaseIterable, Sendable {
    case fast
    case standard
    case maximum

    var titleKey: StringKey {
        switch self {
        case .fast: return .archiveModeFast
        case .standard: return .archiveModeStandard
        case .maximum: return .archiveModeMaximum
        }
    }

    /// DEFLATE level (zlib): 1 / 6 / 9.
    var deflateLevel: Int32 {
        switch self {
        case .fast: return 1
        case .standard: return 6
        case .maximum: return 9
        }
    }

    /// BZip2 block size, in the library's 1...9 scale.
    var bzip2BlockSize: Int {
        switch self {
        case .fast: return 1
        case .standard: return 5
        case .maximum: return 9
        }
    }
}

enum ArchiveCompressor {
    struct Report: Equatable {
        let archiveURL: URL
        let entryCount: Int
        let totalInputBytes: Int
        /// Paths (relative to the archive) left out because they are symlinks.
        let skippedSymbolicLinks: [String]
    }

    /// The formats this build can write, in menu order.
    static let writableFormats: [ArchiveFormat] = [.zip, .tar, .gzip, .bzip2]

    /// File-name suffix produced per format. The compressed variants always wrap
    /// a TAR, which is what `.tar.gz` means.
    static func fileNameExtension(for format: ArchiveFormat) -> String? {
        switch format {
        case .zip: return "zip"
        case .tar: return "tar"
        case .gzip: return "tar.gz"
        case .bzip2: return "tar.bz2"
        case .sevenZip, .xz, .rar: return nil
        }
    }

    static func canWrite(_ format: ArchiveFormat) -> Bool {
        fileNameExtension(for: format) != nil
    }

    /// Zips `sources` into `directory` under `preferredName` (already carrying
    /// its extension). Collisions follow `conflictPolicy` like extraction does.
    static func compress(
        _ sources: [URL],
        into directory: URL,
        preferredName: String,
        format: ArchiveFormat,
        conflictPolicy: ArchiveConflictPolicy,
        sizeLimitMB: Int,
        mode: ArchiveCompressionMode = .standard,
        label: String? = nil
    ) throws -> Report {
        guard !sources.isEmpty else { throw ArchiveError.readFailed("nothing to compress") }
        guard let fileExtension = fileNameExtension(for: format) else {
            throw ArchiveError.unsupportedFormat("This build cannot create \(format.rawValue) archives")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ArchiveError.writeFailed("“\(directory.path)” is not a folder")
        }

        let limit = Int64(sizeLimitMB) * 1024 * 1024
        var items: [Item] = []
        var skippedLinks: [String] = []
        var total: Int64 = 0

        for source in sources {
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw ArchiveError.readFailed("“\(source.path)” does not exist")
            }
            try collect(
                url: source,
                entryName: source.lastPathComponent,
                into: &items,
                skippedLinks: &skippedLinks,
                total: &total,
                limit: limit
            )
        }

        let archive = try archiveData(
            items: items,
            format: format,
            fileExtension: fileExtension,
            mode: mode,
            label: label
        )
        let url = try destinationURL(in: directory, preferredName: preferredName, conflictPolicy: conflictPolicy)
        do {
            if conflictPolicy == .overwrite {
                try archive.write(to: url, options: [.atomic])
            } else {
                try archive.write(to: url, options: [.withoutOverwriting])
            }
        } catch {
            throw ArchiveError.writeFailed(error.localizedDescription)
        }

        return Report(
            archiveURL: url,
            entryCount: items.count,
            totalInputBytes: Int(min(total, Int64(Int.max))),
            skippedSymbolicLinks: skippedLinks
        )
    }

    /// Archive name for a selection: the item's own name for one item, the
    /// shared parent folder for several, `Archive` when they come from different
    /// places.
    static func preferredArchiveName(for sources: [URL], format: ArchiveFormat) -> String {
        let fileExtension = fileNameExtension(for: format) ?? "zip"
        guard let first = sources.first else { return "Archive.\(fileExtension)" }
        if sources.count == 1 {
            return "\(first.lastPathComponent).\(fileExtension)"
        }
        let parents = Set(sources.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        guard parents.count == 1, let parent = parents.first else { return "Archive.\(fileExtension)" }
        let name = URL(fileURLWithPath: parent).lastPathComponent
        return name.isEmpty ? "Archive.\(fileExtension)" : "\(name).\(fileExtension)"
    }

    // MARK: - Walking

    private struct Item {
        let entryName: String
        let url: URL
        let isDirectory: Bool
        let contents: Data?
    }

    private static func collect(
        url: URL,
        entryName: String,
        into items: inout [Item],
        skippedLinks: inout [String],
        total: inout Int64,
        limit: Int64
    ) throws {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        if values?.isSymbolicLink == true {
            skippedLinks.append(entryName)
            return
        }

        if values?.isDirectory == true {
            items.append(Item(entryName: entryName, url: url, isDirectory: true, contents: nil))
            let children = ((try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                options: []
            )) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                try collect(
                    url: child,
                    entryName: "\(entryName)/\(child.lastPathComponent)",
                    into: &items,
                    skippedLinks: &skippedLinks,
                    total: &total,
                    limit: limit
                )
            }
            return
        }

        let size = Int64(values?.fileSize ?? 0)
        total += size
        guard total <= limit else {
            throw ArchiveError.tooLarge("the selection is larger than the \(limit / 1024 / 1024) MB limit")
        }
        items.append(Item(
            entryName: entryName,
            url: url,
            isDirectory: false,
            contents: (try? Data(contentsOf: url, options: [.mappedIfSafe])) ?? Data()
        ))
    }

    // MARK: - Format writers

    private static func archiveData(
        items: [Item],
        format: ArchiveFormat,
        fileExtension: String,
        mode: ArchiveCompressionMode,
        label: String?
    ) throws -> Data {
        switch format {
        case .zip:
            let entries = items.map { item in
                ZipArchiveEntry(
                    name: item.isDirectory ? item.entryName + "/" : item.entryName,
                    contents: item.contents ?? Data()
                )
            }
            do {
                // The label goes into the EOCD comment, which only ZIP has.
                return try ZipWriter.archive(entries, comment: label, level: mode.deflateLevel)
            } catch {
                throw ArchiveError.writeFailed(String(describing: error))
            }
        case .tar, .gzip, .bzip2:
            let tar = makeTar(items: items)
            switch format {
            case .tar:
                return tar
            case .gzip:
                do {
                    return try GzipArchive.archive(data: tar, fileName: nil, modificationTime: nil)
                } catch {
                    throw ArchiveError.writeFailed("gzip: \(error)")
                }
            case .bzip2:
                let blockSizes: [BZip2.BlockSize] = [.one, .two, .three, .four, .five, .six, .seven, .eight, .nine]
                return BZip2.compress(data: tar, blockSize: blockSizes[mode.bzip2BlockSize - 1])
            default:
                throw ArchiveError.unsupportedFormat(fileExtension)
            }
        case .sevenZip, .xz, .rar:
            throw ArchiveError.unsupportedFormat("This build cannot create \(format.rawValue) archives")
        }
    }

    /// TAR entries built by hand: the library writes the container, the caller
    /// decides the tree.
    ///
    /// Directory names get the conventional trailing slash *in addition to* the
    /// type flag (`TarContainer.create` does not add it), so tools that key on
    /// the name see a directory too.
    private static func makeTar(items: [Item]) -> Data {
        let entries = items.map { item -> TarEntry in
            let name = item.isDirectory ? item.entryName + "/" : item.entryName
            let info = TarEntryInfo(name: name, type: item.isDirectory ? .directory : .regular)
            return TarEntry(info: info, data: item.isDirectory ? nil : (item.contents ?? Data()))
        }
        return TarContainer.create(from: entries)
    }

    private static func destinationURL(
        in directory: URL,
        preferredName: String,
        conflictPolicy: ArchiveConflictPolicy
    ) throws -> URL {
        let candidate = directory.appendingPathComponent(preferredName)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        switch conflictPolicy {
        case .overwrite:
            return candidate
        case .skip:
            throw ArchiveError.conflict("“\(preferredName)” already exists")
        case .keepBoth:
            let siblings = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return directory.appendingPathComponent(
                FileNameResolver.uniqueName(preferred: preferredName, existing: siblings)
            )
        }
    }
}
