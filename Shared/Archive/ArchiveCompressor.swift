import Foundation
import SWCompression

/// Builds archives from Finder selections (P9).
///
/// Directory trees are walked in a stable order, empty folders are kept (an
/// entry per directory), and **symbolic links are skipped and reported**: a link
/// can point anywhere, so following one would mean packaging files the user did
/// not select, and storing one would mean writing it back on extraction.
///
/// A source file that cannot be read **fails the compression**: it must never
/// become a zero-byte entry that looks like a successful archive.
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
    static let writableFormats: [ArchiveFormat] = [.zip, .sevenZip, .tar, .gzip, .bzip2]

    /// File-name suffix produced per format. The compressed variants always wrap
    /// a TAR, which is what `.tar.gz` means.
    static func fileNameExtension(for format: ArchiveFormat) -> String? {
        switch format {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .tar: return "tar"
        case .gzip: return "tar.gz"
        case .bzip2: return "tar.bz2"
        case .xz, .rar: return nil
        }
    }

    static func canWrite(_ format: ArchiveFormat) -> Bool {
        fileNameExtension(for: format) != nil
    }

    /// Zips `sources` into `directory` under `preferredName` (already carrying
    /// its extension). Collisions follow `conflictPolicy` like extraction does.
    ///
    /// `control` is checkpointed once per entry while the tree is walked and
    /// again per entry while the archive is built, which is where it picks up a
    /// pause or a cancel. The archive is assembled in memory and written only at
    /// the very end, so a cancel throws `.cancelled` and leaves nothing behind —
    /// no partial file, no temp file to clean up.
    ///
    /// Progress is reported in two phases, both determinate: reading the sources
    /// (by bytes, against a metadata-only pre-walk) and writing the container (by
    /// entries, straight out of `ZipWriter`'s deflate loop).
    ///
    /// - Parameter password: 加密压缩. Non-nil and non-empty encrypts the archive:
    ///   PKWARE traditional ZIP encryption (see `ZipEncryption`) for ZIP, AES-256
    ///   for 7z. Every other format refuses rather than writing what the user did
    ///   not ask for. The password is never stored, never logged, and never leaves
    ///   the process.
    /// - Parameters:
    ///   - solid: 固实压缩, 7z only. `true` (the default, and what 7-Zip does)
    ///     compresses the whole archive as one block; `false` gives every file its
    ///     own block, which is larger but lets a reader pull one file out without
    ///     decompressing everything before it.
    ///   - encryptsFileNames: 加密文件名, 7z only. Encrypts the header as well, so
    ///     even the names inside need the password. Ignored without a password.
    ///   - volumeSizeMB: 分卷压缩. Non-nil and positive cuts the finished image
    ///     into `name.zip.001`, `.002`, … parts of at most this many MB, the
    ///     naming 7-Zip/Keka/WinRAR use and this app also reads back.
    static func compress(
        _ sources: [URL],
        into directory: URL,
        preferredName: String,
        format: ArchiveFormat,
        conflictPolicy: ArchiveConflictPolicy,
        sizeLimitMB: Int,
        mode: ArchiveCompressionMode = .standard,
        label: String? = nil,
        password: String? = nil,
        solid: Bool = true,
        encryptsFileNames: Bool = false,
        volumeSizeMB: Int? = nil,
        control: ArchiveOperationControl? = nil
    ) throws -> Report {
        guard !sources.isEmpty else { throw ArchiveError.writeFailed("nothing to compress") }
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

        // Metadata-only pre-walk: the read phase can only report a *fraction* if
        // something knows the denominator up front, and touching sizes is cheap
        // next to reading every byte below.
        let expectedBytes = sourceBytes(of: sources)
        control?.report(0)

        for source in sources {
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw ArchiveError.readFailed("“\(source.path)”: no such file")
            }
            try collect(
                url: source,
                entryName: source.lastPathComponent,
                into: &items,
                skippedLinks: &skippedLinks,
                total: &total,
                limit: limit,
                control: control,
                onBytesRead: { read in
                    guard expectedBytes > 0 else { return }
                    // Reading is the first half of the bar.
                    control?.report(0.5 * Double(read) / Double(expectedBytes))
                }
            )
        }

        // The container build is the second half, reported per entry.
        let entryCount = max(items.count, 1)
        let archive = try archiveData(
            items: items,
            format: format,
            fileExtension: fileExtension,
            mode: mode,
            label: label,
            password: password,
            solid: solid,
            encryptsFileNames: encryptsFileNames,
            control: control,
            onEntry: { index in
                control?.report(0.5 + 0.5 * Double(index) / Double(entryCount))
            }
        )
        control?.report(1)
        let volumeMB = volumeSizeMB.flatMap { $0 > 0 ? $0 : nil }
        let url = try destinationURL(
            in: directory,
            preferredName: preferredName,
            conflictPolicy: conflictPolicy,
            isSplit: volumeMB != nil
        )
        // The image is complete in memory by now, so this is the last chance to
        // honour a cancel that arrived while the final entry was being
        // compressed: past this point the destination would be written anyway.
        try control?.checkpoint()
        do {
            if let volumeMB {
                // 分卷压缩: the image is cut into `name.zip.001`, `.002`, … —
                // plain chunks, which is what makes the set readable by 7-Zip,
                // Keka and WinRAR as well as by this app (`ArchiveVolumeSet`).
                let parts = try ArchiveVolumeSet.write(
                    archive,
                    baseURL: url,
                    volumeBytes: volumeMB * 1024 * 1024,
                    overwrite: conflictPolicy == .overwrite
                )
                return Report(
                    archiveURL: parts.first ?? url,
                    entryCount: items.count,
                    totalInputBytes: Int(min(total, Int64(Int.max))),
                    skippedSymbolicLinks: skippedLinks
                )
            }
            if conflictPolicy == .overwrite {
                try archive.write(to: url, options: [.atomic])
            } else {
                try archive.write(to: url, options: [.withoutOverwriting])
            }
        } catch let error as ArchiveError {
            throw error
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
        limit: Int64,
        control: ArchiveOperationControl?,
        onBytesRead: ((Int64) -> Void)? = nil
    ) throws {
        try control?.checkpoint()
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
                    limit: limit,
                    control: control,
                    onBytesRead: onBytesRead
                )
            }
            return
        }

        let size = Int64(values?.fileSize ?? 0)
        total += size
        onBytesRead?(total)
        guard total <= limit else {
            throw ArchiveError.tooLarge("the selection is larger than the \(limit / 1024 / 1024) MB limit")
        }
        // A file that cannot be read must fail the compression instead of being
        // stored as a zero-byte entry: an archive that silently lost the content
        // of a file looks like a successful run and is only discovered much later.
        let contents: Data
        do {
            contents = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ArchiveError.readFailed("“\(entryName)”: \(error.localizedDescription)")
        }
        items.append(Item(entryName: entryName, url: url, isDirectory: false, contents: contents))
    }

    // MARK: - Format writers

    private static func archiveData(
        items: [Item],
        format: ArchiveFormat,
        fileExtension: String,
        mode: ArchiveCompressionMode,
        label: String?,
        password: String? = nil,
        solid: Bool = true,
        encryptsFileNames: Bool = false,
        control: ArchiveOperationControl? = nil,
        onEntry: ((Int) -> Void)? = nil
    ) throws -> Data {
        let wantsEncryption = !(password ?? "").isEmpty
        // ZIP (traditional) and 7z (AES-256) are the containers this build can
        // encrypt. Refusing beats writing a plain archive the dialog claimed was
        // encrypted.
        if wantsEncryption, format != .zip, format != .sevenZip {
            throw ArchiveError.encryptionUnsupported(
                "\(format.rawValue) archives cannot be encrypted by this build (ZIP and 7z can)"
            )
        }
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
                return try ZipWriter.archive(
                    entries,
                    comment: label,
                    level: mode.deflateLevel,
                    encryption: wantsEncryption ? ZipEncryption(password: password ?? "") : nil,
                    // Reported from inside the deflate loop: this is the part the
                    // user actually waits on, and it is the only place with a
                    // per-entry view of it.
                    onEntry: { index in
                        onEntry?(index)
                        try control?.checkpoint()
                    }
                )
            } catch let error as ZipWriterError {
                // "the password is empty" / "no randomness" are user-facing
                // reasons, not writer internals, so they keep their own case.
                if case .encryptionFailed(let reason) = error {
                    throw ArchiveError.encryptionUnsupported(reason)
                }
                throw ArchiveError.writeFailed(String(describing: error))
            } catch {
                throw ArchiveError.writeFailed(String(describing: error))
            }
        case .sevenZip:
            // PLzmaSDK takes the files themselves, so the entries are the
            // non-directory items of the walk. Directories become the prefixes
            // of those names; see `SevenZipWriter` for why an empty folder
            // cannot be stored in this container.
            let entries = items.compactMap { item -> SevenZipWriter.Entry? in
                guard !item.isDirectory else { return nil }
                return SevenZipWriter.Entry(archivePath: item.entryName, url: item.url)
            }
            return try SevenZipWriter.archive(
                entries: entries,
                mode: mode,
                password: password,
                solid: solid,
                encryptsFileNames: encryptsFileNames,
                control: control,
                // Reported while the entries are handed over (the writer
                // checkpoints there, and throws on a pause or a cancel); the
                // LZMA2 pass itself is one opaque call with no callback, so a
                // cancel can only land between entries.
                onEntry: { index in onEntry?(index) }
            )
        case .tar, .gzip, .bzip2:
            // These containers have no per-entry hook; the whole tree is walked
            // once inside `makeTar`, so a cancel can only land before it starts.
            try control?.checkpoint()
            onEntry?(items.count / 2)
            let tar = makeTar(items: items)
            onEntry?(items.count)
            switch format {
            case .tar:
                return tar
            case .gzip:
                // Not SWCompression's `GzipArchive.archive`: that one has no
                // level, so 压缩模式 would silently do nothing for `.tar.gz`.
                return try GzipWriter.archive(tar, level: mode.deflateLevel)
            case .bzip2:
                let blockSizes: [BZip2.BlockSize] = [.one, .two, .three, .four, .five, .six, .seven, .eight, .nine]
                return BZip2.compress(data: tar, blockSize: blockSizes[mode.bzip2BlockSize - 1])
            default:
                throw ArchiveError.unsupportedFormat(fileExtension)
            }
        case .xz, .rar:
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
        conflictPolicy: ArchiveConflictPolicy,
        isSplit: Bool = false
    ) throws -> URL {
        let candidate = directory.appendingPathComponent(preferredName)
        // A split set is recognised by its first part, so that is what a collision
        // is detected on — and what `keepBoth` has to make unique.
        let probe = isSplit
            ? candidate.appendingPathExtension(ArchiveVolumeSet.partSuffix(1))
            : candidate
        guard FileManager.default.fileExists(atPath: probe.path) else { return candidate }
        switch conflictPolicy {
        case .overwrite:
            return candidate
        case .skip:
            throw ArchiveError.conflict("“\(probe.lastPathComponent)” already exists")
        case .keepBoth:
            let siblings = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            let unique = FileNameResolver.uniqueName(preferred: probe.lastPathComponent, existing: siblings)
            // `uniqueName` numbers the name it was handed; for a split set that
            // carries the `.001` suffix, which the archive's base name must not.
            let base = isSplit ? (unique as NSString).deletingPathExtension : unique
            return directory.appendingPathComponent(base)
        }
    }

    /// Total size of the sources, from metadata only — no file contents are read.
    ///
    /// Used solely as the denominator of the read-phase progress bar. Walking a
    /// tree with `stat` is orders of magnitude cheaper than reading it, and the
    /// alternative (an indeterminate bar for the longest part of the operation)
    /// tells the user less.
    static func sourceBytes(of sources: [URL]) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        for source in sources {
            let values = try? source.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                guard let walker = FileManager.default.enumerator(
                    at: source,
                    includingPropertiesForKeys: keys,
                    options: [],
                    errorHandler: { _, _ in true }
                ) else { continue }
                for case let url as URL in walker {
                    let child = try? url.resourceValues(forKeys: Set(keys))
                    if child?.isSymbolicLink == true || child?.isDirectory == true { continue }
                    total += Int64(child?.fileSize ?? 0)
                }
            } else {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
