import Foundation
import SWCompression

/// One member of an archive, in the form the extraction policy needs.
///
/// Format-agnostic on purpose: the planner and the writer must not care whether
/// this came out of a ZIP central directory or SWCompression's 7-Zip header —
/// the zip-slip rules are the same either way, which is the whole point of
/// funnelling every format through one model.
struct ArchiveMember: Equatable {
    /// Position in the archive; identities can repeat names, so this is the key.
    let index: Int
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    /// Declared payload size, when the container states one.
    let uncompressedSize: Int64
    /// False when the container names a compression method this build cannot
    /// inflate (a ZIP with, say, method 12): the planner refuses it up front
    /// instead of half-extracting.
    let isDecompressible: Bool

    var isRegularFile: Bool { !isDirectory && !isSymbolicLink }
}

/// A container opened for inspection, with payloads materialized on demand.
///
/// `members` must be cheap and payload-free: the extractor runs the size guard
/// and the name rules on it **before** any payload is read, which is what turns
/// a zip bomb into `archiveTooLarge` instead of an out-of-memory kill.
protocol ArchiveMemberSource {
    func members() throws -> [ArchiveMember]
    func contents(of member: ArchiveMember) throws -> Data
}

enum ArchiveMemberSourceError: Error, Equatable {
    case unsupportedFormat(String)
    case corrupted(String)
}

/// Builds the right source for a file, by content (see `ArchiveFormats`).
enum ArchiveMemberSourceFactory {
    static func make(url: URL, format: ArchiveFormat?) throws -> ArchiveMemberSource {
        guard let format = format ?? ArchiveFormats.detect(at: url) else {
            throw ArchiveError.unsupportedFormat("“\(url.lastPathComponent)” is not an archive this build can read")
        }
        switch format {
        case .zip:
            return try ZipMemberSource(url: url)
        case .tar, .sevenZip:
            guard let source = LibraryMemberSource(url: url, format: format) else {
                throw ArchiveError.unsupportedFormat("“\(url.lastPathComponent)” is not a readable \(format.rawValue) archive")
            }
            return source
        case .gzip, .bzip2, .xz:
            return SingleMemberSource(url: url, format: format)
        case .rar:
            throw ArchiveError.unsupportedFormat("RAR is not supported (no pure-Swift, MIT-licensed implementation)")
        }
    }
}

// MARK: - ZIP (our own reader)

/// ZIP goes through `ZipReader` rather than the library: it is the format this
/// app also *writes*, the reader keeps payloads lazy, and the zip-slip rules
/// were built and tested against it.
struct ZipMemberSource: ArchiveMemberSource {
    private let reader: ZipReader

    init(url: URL) throws {
        do {
            reader = try ZipReader(fileURL: url)
        } catch let error as ZipReaderError {
            if case .unsupportedCompression = error {
                throw ArchiveError.unsupportedFormat(ArchiveExtractor.describe(error))
            }
            throw ArchiveError.notAnArchive(ArchiveExtractor.describe(error))
        }
    }

    func members() throws -> [ArchiveMember] {
        reader.entries.enumerated().map { index, record in
            ArchiveMember(
                index: index,
                name: record.name,
                isDirectory: record.isDirectory,
                isSymbolicLink: record.isSymbolicLink,
                uncompressedSize: Int64(record.uncompressedSize),
                isDecompressible: record.compressionMethod == 0 || record.compressionMethod == 8
            )
        }
    }

    func contents(of member: ArchiveMember) throws -> Data {
        guard reader.entries.indices.contains(member.index) else {
            throw ArchiveError.notAnArchive("entry index \(member.index) is out of range")
        }
        do {
            return try reader.contents(of: reader.entries[member.index])
        } catch let error as ZipReaderError {
            throw ArchiveError.notAnArchive(ArchiveExtractor.describe(error))
        }
    }
}

// MARK: - TAR and 7-Zip (SWCompression)

/// TAR and 7-Zip: metadata comes from the library's `info` API, payloads from
/// `open`, which is only called once the plan has passed the size guard.
///
/// The library's API is whole-`Data` (no streaming), so a payload is loaded in
/// one piece — acceptable precisely because the guard runs first, and why this
/// type keeps `open` out of `members()`.
final class LibraryMemberSource: ArchiveMemberSource {
    private let url: URL
    private let format: ArchiveFormat
    private let metadata: [ArchiveMember]
    private var opened: [(name: String, data: Data?)]?

    init?(url: URL, format: ArchiveFormat) {
        self.url = url
        self.format = format
        guard let data = try? Data(contentsOf: url), let infos = Self.infos(of: data, format: format) else { return nil }
        metadata = infos.enumerated().map { index, info in
            ArchiveMember(
                index: index,
                name: info.name,
                isDirectory: info.type == .directory,
                isSymbolicLink: info.type == .symbolicLink || info.type == .hardLink,
                uncompressedSize: Int64(info.size ?? 0),
                isDecompressible: true
            )
        }
    }

    private static func infos(of data: Data, format: ArchiveFormat) -> [(name: String, type: ContainerEntryType, size: Int?)]? {
        switch format {
        case .tar:
            // `info` alone is not a validity check — it happily returns [] for
            // zero-filled input, while `formatOf` throws on data that is not a
            // TAR at all.
            guard (try? TarContainer.formatOf(container: data)) != nil,
                  let entries = try? TarContainer.info(container: data) else { return nil }
            return entries.map { ($0.name, $0.type, $0.size) }
        case .sevenZip:
            guard let entries = try? SevenZipContainer.info(container: data) else { return nil }
            return entries.map { ($0.name, $0.type, $0.size) }
        default:
            return nil
        }
    }

    func members() throws -> [ArchiveMember] {
        metadata
    }

    func contents(of member: ArchiveMember) throws -> Data {
        if opened == nil {
            let data = try Data(contentsOf: url)
            switch format {
            case .tar:
                guard let entries = try? TarContainer.open(container: data) else {
                    throw ArchiveError.notAnArchive("“\(url.lastPathComponent)” could not be opened as TAR")
                }
                opened = entries.map { ($0.info.name, $0.data) }
            case .sevenZip:
                do {
                    // `info` can list an archive whose coder we cannot run:
                    // 7-Zip's own BCJ/BCJ2 filters and py7zr's default
                    // (LZMA2 + BCJ) both fail here, and "unsupported" is a
                    // clearer answer than "corrupt".
                    opened = try SevenZipContainer.open(container: data).map { ($0.info.name, $0.data) }
                } catch {
                    throw ArchiveError.unsupportedFormat(
                        "7-Zip archive uses a coder this build cannot read (BCJ/BCJ2 filters are not supported)"
                    )
                }
            default:
                throw ArchiveError.unsupportedFormat(format.rawValue)
            }
        }
        guard let opened, opened.indices.contains(member.index) else {
            throw ArchiveError.notAnArchive("entry \(member.name) is missing from the archive")
        }
        guard let data = opened[member.index].data else {
            throw ArchiveError.notAnArchive("entry \(member.name) has no readable data")
        }
        return data
    }
}

// MARK: - gzip / bzip2 / xz (single member, optionally a tar inside)

/// The whole-file compression formats: one member whose name is derived from the
/// file name. `.tar.gz` (and `.tgz`, `.tar.bz2`, `.tar.xz`) peel one layer and
/// are then treated as a TAR.
///
/// These containers do not declare a payload size, so the size guard can only
/// run *after* decompression; the compressed file itself is checked first. That
/// residual risk is documented in the README rather than hidden.
struct SingleMemberSource: ArchiveMemberSource {
    private let url: URL
    private let format: ArchiveFormat
    private let tarInside: Bool
    private let payload: () throws -> Data

    init(url: URL, format: ArchiveFormat) {
        self.url = url
        self.format = format
        self.tarInside = ArchiveFormats.isCompressedTar(url.lastPathComponent)
        self.payload = {
            let data = try Data(contentsOf: url)
            switch format {
            case .gzip:
                return try GzipArchive.unarchive(archive: data)
            case .bzip2:
                return try BZip2.decompress(data: data)
            case .xz:
                return try XZArchive.unarchive(archive: data)
            default:
                throw ArchiveError.unsupportedFormat(format.rawValue)
            }
        }
    }

    func members() throws -> [ArchiveMember] {
        guard tarInside else {
            return [ArchiveMember(
                index: 0,
                name: ArchiveFormats.expandedName(forFileName: url.lastPathComponent, format: format),
                isDirectory: false,
                isSymbolicLink: false,
                // Unknown until decompressed: 0 means "declared size is not
                // available", so only the post-decompression check applies.
                uncompressedSize: 0,
                isDecompressible: true
            )]
        }
        guard let entries = try? TarContainer.info(container: try payload()) else {
            throw ArchiveError.notAnArchive("“\(url.lastPathComponent)” does not contain a TAR")
        }
        return entries.enumerated().map { index, info in
            ArchiveMember(
                index: index,
                name: info.name,
                isDirectory: info.type == .directory,
                isSymbolicLink: info.type == .symbolicLink || info.type == .hardLink,
                uncompressedSize: Int64(info.size ?? 0),
                isDecompressible: true
            )
        }
    }

    func contents(of member: ArchiveMember) throws -> Data {
        let data = try payload()
        guard tarInside else { return data }
        guard let entries = try? TarContainer.open(container: data), entries.indices.contains(member.index) else {
            throw ArchiveError.notAnArchive("entry \(member.name) is missing from the archive")
        }
        guard let contents = entries[member.index].data else {
            throw ArchiveError.notAnArchive("entry \(member.name) has no readable data")
        }
        return contents
    }

    /// The uncompressed size when the container states it (gzip's trailing
    /// ISIZE), so the size guard can run before decompressing.
    func declaredPayloadSize() -> Int64? {
        guard format == .gzip,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count >= 4 else { return nil }
        let tail = [UInt8](data.suffix(4))
        let size = UInt32(tail[0]) | (UInt32(tail[1]) << 8) | (UInt32(tail[2]) << 16) | (UInt32(tail[3]) << 24)
        // The field is modulo 2^32, so treat small values as authoritative and
        // large ones as "unknown" rather than trusting a wrapped number.
        return size > 0 && size < 0x8000_0000 ? Int64(size) : nil
    }
}
