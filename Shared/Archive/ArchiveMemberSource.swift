import Foundation
import SWCompression
import zlib

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

/// A source that holds something the caller has to release: a joined split
/// archive, a decoder, a scratch directory of decrypted files.
///
/// The extractor releases it when the run is over, whatever the outcome; `deinit`
/// is the backstop. Sources that hold nothing simply do not conform.
protocol ArchiveMemberSourceClosing: AnyObject {
    func close()
}

enum ArchiveMemberSourceError: Error, Equatable {
    case unsupportedFormat(String)
    case corrupted(String)
}

/// Builds the right source for a file, by content (see `ArchiveFormats`).
enum ArchiveMemberSourceFactory {
    /// - Parameter password: the password for an encrypted ZIP or 7z. Unused by
    ///   the other containers, which carry no password this build can honour.
    /// - Parameter maximumPayloadBytes: the extraction size limit, threaded down
    ///   so every format can refuse an oversized payload while reading it rather
    ///   than after it is already in memory. `.max` means "no limit".
    static func make(
        url: URL,
        format: ArchiveFormat?,
        password: String? = nil,
        maximumPayloadBytes: Int64 = .max
    ) throws -> ArchiveMemberSource {
        guard let format = format ?? ArchiveFormats.detect(at: url) else {
            throw ArchiveError.unsupportedFormat("“\(url.lastPathComponent)” is not an archive this build can read")
        }
        switch format {
        case .zip:
            return try ZipMemberSource(url: url, password: password, maximumPayloadBytes: maximumPayloadBytes)
        case .sevenZip:
            // An encrypted 7z goes through PLzmaSDK: SWCompression refuses them,
            // and (when the header is encrypted too) cannot even list them.
            if let password, !password.isEmpty, SevenZipEncryption.needsPassword(archiveURL: url) {
                return SevenZipPasswordMemberSource(archiveURL: url, password: password)
            }
            do {
                return try LibraryMemberSource(
                    validating: url,
                    format: format,
                    maximumPayloadBytes: maximumPayloadBytes
                )
            } catch let error as ArchiveError {
                // `init(validating:)` 的 unsupportedFormat 对 7z 有两种含义：
                // 真的不是 7z，或者头被加密了（`info` 返回 nil）。
                if case .unsupportedFormat = error, SevenZipEncryption.needsPassword(archiveURL: url) {
                    throw ArchiveError.passwordRequired(url.lastPathComponent)
                }
                throw error
            }
        case .tar:
            return try LibraryMemberSource(validating: url, format: format, maximumPayloadBytes: maximumPayloadBytes)
        case .gzip, .bzip2, .xz:
            return SingleMemberSource(url: url, format: format, maximumPayloadBytes: maximumPayloadBytes)
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
    /// The password an encrypted archive is unlocked with; nil for plain ones.
    private let password: String?
    /// The extractor's payload cap, enforced while inflating rather than after.
    private let maximumPayloadBytes: Int64

    init(url: URL, password: String? = nil, maximumPayloadBytes: Int64 = .max) throws {
        self.password = password
        self.maximumPayloadBytes = maximumPayloadBytes
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
            return try reader.contents(
                of: reader.entries[member.index],
                password: password,
                maximumOutputBytes: maximumPayloadBytes
            )
        } catch let error as ZipReaderError {
            switch error {
            case .passwordRequired(let name):
                throw ArchiveError.passwordRequired(name)
            case .badPassword(let name):
                throw ArchiveError.badPassword(name)
            case .inflateExceedsLimit(let detail):
                // 头部声明的大小不可信：这是压缩炸弹，报成体积超限，
                // 而不是「归档损坏」。
                throw ArchiveError.tooLarge(detail)
            default:
                throw ArchiveError.notAnArchive(ArchiveExtractor.describe(error))
            }
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
    /// The extractor's payload cap; `.max` means "no limit".
    private let maximumPayloadBytes: Int64
    private let metadata: [ArchiveMember]
    private var opened: [(name: String, data: Data?)]?

    /// `nil` 表示「不是这种格式」（解析不出条目）。
    init?(url: URL, format: ArchiveFormat, maximumPayloadBytes: Int64 = .max) {
        self.url = url
        self.format = format
        self.maximumPayloadBytes = maximumPayloadBytes
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let metadata = Self.metadata(of: data, format: format) else { return nil }
        self.metadata = metadata
    }

    /// 和 `init?` 的区别是「读不出来」会明确报错：文件不存在 / 无权限是
    /// `readFailed`，解析不出条目才是 `unsupportedFormat`。`init?` 只回答
    /// 「这是不是这种格式」，两者在 factory 里不能被混为一谈。
    init(validating url: URL, format: ArchiveFormat, maximumPayloadBytes: Int64 = .max) throws {
        self.url = url
        self.format = format
        self.maximumPayloadBytes = maximumPayloadBytes
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ArchiveError.readFailed("“\(url.lastPathComponent)” could not be read: \(error.localizedDescription)")
        }
        guard let metadata = Self.metadata(of: data, format: format) else {
            throw ArchiveError.unsupportedFormat("“\(url.lastPathComponent)” is not a readable \(format.rawValue) archive")
        }
        self.metadata = metadata
    }

    private static func metadata(of data: Data, format: ArchiveFormat) -> [ArchiveMember]? {
        guard let infos = infos(of: data, format: format) else { return nil }
        return infos.enumerated().map { index, info in
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
            try checkFileSize()
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
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
                    // An encrypted archive lists fine but refuses to decode: that
                    // is a password question, not an unsupported coder.
                    if let sevenZipError = error as? SevenZipError, case .encryptionNotSupported = sevenZipError {
                        throw ArchiveError.passwordRequired(url.lastPathComponent)
                    }
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
        // 声明大小可能说谎：真正解出来的 payload 再量一次。
        guard maximumPayloadBytes == .max || data.count <= maximumPayloadBytes else {
            throw ArchiveError.tooLarge("“\(member.name)” expands past the \(maximumPayloadBytes) byte limit")
        }
        return data
    }

    /// TAR 是未压缩的，档案文件大小就是 payload 大小，读进内存前先挡一道；
    /// 7z 的压缩包通常小于解压结果，真正的保证来自 planner 对每个条目声明大小
    /// 的检查，这里只是一道额外的门槛。
    private func checkFileSize() throws {
        guard maximumPayloadBytes != .max else { return }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard fileSize > maximumPayloadBytes else { return }
        throw ArchiveError.tooLarge("“\(url.lastPathComponent)” is larger than the \(maximumPayloadBytes) byte limit")
    }
}

// MARK: - gzip / bzip2 / xz (single member, optionally a tar inside)

/// The open-then-inflate cache for the one payload these formats have.
///
/// Without it every member of a `.tar.gz` re-inflates the whole tarball: 100
/// entries meant 100 decompressions (and 100 chances to blow the size guard
/// only after the fact). `members()` and `contents(of:)` share this one result.
private final class PayloadCache: @unchecked Sendable {
    private let lock = NSLock()
    private let produce: () throws -> Data
    private var cached: Data?

    init(produce: @escaping () throws -> Data) {
        self.produce = produce
    }

    /// The lock is held across decompression on purpose: a second caller should
    /// wait for the first rather than start a duplicate (and duplicate-limit)
    /// decompression. Failures are not cached, so a retry re-reads the file.
    func payload() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let data = try produce()
        cached = data
        return data
    }
}

/// Streaming gzip inflate.
///
/// SWCompression only offers `GzipArchive.unarchive`, which materializes the
/// whole result before returning — a bomb would already be in memory by then.
/// zlib can be stopped mid-stream, so the limit is enforced as bytes come out.
/// (zlib also verifies the trailing CRC32/ISIZE, matching what `unarchive` did.)
private enum BoundedGzip {
    static func inflate(_ data: Data, maximumBytes: Int64) throws -> Data {
        guard !data.isEmpty else { throw ArchiveError.notAnArchive("the gzip stream is empty") }

        var stream = z_stream()
        // 47 = 15 window bits + 32: auto-detect a gzip or zlib header.
        let initResult = inflateInit2_(&stream, 47, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { throw ArchiveError.notAnArchive("could not start gzip inflate (zlib \(initResult))") }
        defer { inflateEnd(&stream) }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let chunkSize = buffer.count
        var status: Int32 = Z_OK

        try data.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(raw.count)
            while status == Z_OK {
                var produced = 0
                buffer.withUnsafeMutableBytes { out in
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    produced = chunkSize - Int(stream.avail_out)
                }
                if produced > 0 {
                    // 先判上限再 append：超出的块不会进入 output。
                    guard maximumBytes == .max || Int64(output.count) + Int64(produced) <= maximumBytes else {
                        throw ArchiveError.tooLarge("the gzip payload expands past the \(maximumBytes) byte limit")
                    }
                    output.append(contentsOf: buffer[0..<produced])
                }
            }
        }

        // Z_BUF_ERROR 就是「输入用完了但流没结束」，即截断。
        guard status == Z_STREAM_END else {
            throw ArchiveError.notAnArchive("the gzip stream is corrupt or truncated (zlib \(status))")
        }
        return output
    }
}

/// The xz stream index states every block's uncompressed size, so the total can
/// be read off the end of the file without decompressing anything.
///
/// Every step is best-effort: anything unexpected returns `nil` so the caller
/// falls back to checking after decompression. A parser that rejected an
/// archive it merely failed to understand would be worse than no parser.
private enum XZIndex {
    static func declaredUncompressedSize(of data: Data) -> Int64? {
        // 24 = 12-byte stream header + 12-byte stream footer.
        guard data.count >= 24 else { return nil }
        let base = data.startIndex
        let footer = data.count - 12
        // Stream Footer: CRC32(4) | backward size(4) | stream flags(2) | "YZ".
        guard data[base + footer + 10] == 0x59, data[base + footer + 11] == 0x5A else { return nil }
        let backward = UInt32(data[base + footer + 4])
            | (UInt32(data[base + footer + 5]) << 8)
            | (UInt32(data[base + footer + 6]) << 16)
            | (UInt32(data[base + footer + 7]) << 24)
        // Backward size counts the index field (excluding its own CRC32) in
        // units of four bytes, minus one.
        let indexSize = Int(backward &+ 1) * 4
        guard indexSize > 0, indexSize <= footer else { return nil }

        var cursor = footer - indexSize
        guard data[base + cursor] == 0x00 else { return nil }
        cursor += 1
        guard let count = readVarint(data, &cursor, limit: footer), count <= UInt64(footer) else { return nil }
        var total: Int64 = 0
        for _ in 0..<count {
            // Record: unpadded size, then uncompressed size.
            guard readVarint(data, &cursor, limit: footer) != nil,
                  let uncompressed = readVarint(data, &cursor, limit: footer) else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(Int64(clamping: uncompressed))
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    /// xz multi-byte integers: little-endian groups of seven bits, high bit set
    /// means "another byte follows".
    private static func readVarint(_ data: Data, _ cursor: inout Int, limit: Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while cursor < limit {
            let byte = data[data.startIndex + cursor]
            cursor += 1
            guard shift < 64 else { return nil }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}

/// The whole-file compression formats: one member whose name is derived from the
/// file name. `.tar.gz` (and `.tgz`, `.tar.bz2`, `.tar.xz`) peel one layer and
/// are then treated as a TAR.
///
/// gzip is inflated with a hard streaming limit (and its trailing ISIZE checked
/// first); xz's index is read up front; bzip2 declares nothing and has no
/// streaming API here, so for it the limit still only runs *after*
/// decompression, and the compressed file itself is checked first. That residual
/// risk is documented in the README rather than hidden.
struct SingleMemberSource: ArchiveMemberSource {
    private let url: URL
    private let format: ArchiveFormat
    private let tarInside: Bool
    /// The extractor's payload cap; `.max` means "no limit".
    private let maximumPayloadBytes: Int64
    private let cache: PayloadCache

    init(url: URL, format: ArchiveFormat, maximumPayloadBytes: Int64 = .max) {
        self.url = url
        self.format = format
        self.maximumPayloadBytes = maximumPayloadBytes
        self.tarInside = ArchiveFormats.isCompressedTar(url.lastPathComponent)
        self.cache = PayloadCache {
            try Self.decompress(url: url, format: format, maximumBytes: maximumPayloadBytes)
        }
    }

    /// 解压一份 payload 并保证它不超过 `maximumBytes`。各格式能提前预判的
    /// 就提前预判，不能预判的也必须用完再量一次。
    private static func decompress(url: URL, format: ArchiveFormat, maximumBytes: Int64) throws -> Data {
        switch format {
        case .gzip:
            let compressed = try Data(contentsOf: url, options: [.mappedIfSafe])
            // ISIZE（尾部四字节）声明了解压后大小，先挡一道，免得为一个明显
            // 超限的文件启动解压。
            if let declared = declaredGzipSize(of: compressed), maximumBytes != .max, declared > maximumBytes {
                throw ArchiveError.tooLarge("“\(url.lastPathComponent)” declares \(declared) bytes, over the \(maximumBytes) byte limit")
            }
            return try BoundedGzip.inflate(compressed, maximumBytes: maximumBytes)
        case .bzip2:
            // bzip2 头部不声明解压后大小，SWCompression 也没有流式 API，只能
            // 解压后再查：恶意文件在判定前仍会完整物化一次。
            let data = try BZip2.decompress(data: Data(contentsOf: url, options: [.mappedIfSafe]))
            guard maximumBytes == .max || data.count <= maximumBytes else {
                throw ArchiveError.tooLarge("“\(url.lastPathComponent)” expands to \(data.count) bytes, over the \(maximumBytes) byte limit")
            }
            return data
        case .xz:
            let compressed = try Data(contentsOf: url, options: [.mappedIfSafe])
            // index 说的总量只是个更早的提示；解析失败就当作未知，绝不拒绝。
            if let declared = XZIndex.declaredUncompressedSize(of: compressed), maximumBytes != .max, declared > maximumBytes {
                throw ArchiveError.tooLarge("“\(url.lastPathComponent)” declares \(declared) bytes, over the \(maximumBytes) byte limit")
            }
            let data = try XZArchive.unarchive(archive: compressed)
            guard maximumBytes == .max || data.count <= maximumBytes else {
                throw ArchiveError.tooLarge("“\(url.lastPathComponent)” expands to \(data.count) bytes, over the \(maximumBytes) byte limit")
            }
            return data
        default:
            throw ArchiveError.unsupportedFormat(format.rawValue)
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
        // 解压失败要原样抛出，不能被 `try?` 吞成「这不是 TAR」。
        let data = try cache.payload()
        guard let entries = try? TarContainer.info(container: data) else {
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
        let data = try cache.payload()
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
    /// ISIZE, xz's stream index), so the size guard can run before decompressing.
    func declaredPayloadSize() -> Int64? {
        switch format {
        case .gzip:
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
            return Self.declaredGzipSize(of: data)
        case .xz:
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
            return XZIndex.declaredUncompressedSize(of: data)
        default:
            return nil
        }
    }

    /// gzip's ISIZE is the payload size modulo 2^32: small values are
    /// authoritative, large ones are treated as "unknown" rather than trusting a
    /// wrapped number.
    private static func declaredGzipSize(of data: Data) -> Int64? {
        guard data.count >= 4 else { return nil }
        let tail = [UInt8](data.suffix(4))
        let size = UInt32(tail[0]) | (UInt32(tail[1]) << 8) | (UInt32(tail[2]) << 16) | (UInt32(tail[3]) << 24)
        return size > 0 && size < 0x8000_0000 ? Int64(size) : nil
    }
}
