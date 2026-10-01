import Foundation
import zlib

/// One member file of an archive written by `ZipWriter`.
struct ZipArchiveEntry: Equatable {
    /// POSIX-style relative entry name, e.g. `word/document.xml`.
    ///
    /// No leading `/`, no backslash, no `.`/`..` component: the name goes into
    /// the archive verbatim, and a traversal-shaped name would be a zip-slip
    /// payload for whoever unpacks it.
    let name: String
    let contents: Data

    init(name: String, contents: Data) {
        self.name = name
        self.contents = contents
    }
}

/// Everything that can make `ZipWriter.archive` refuse to produce bytes.
enum ZipWriterError: Error, Equatable {
    case invalidEntryName(String)
    /// More entries, a bigger entry, or a bigger archive than the 32-bit ZIP
    /// format can describe. ZIP64 is deliberately not implemented: the only
    /// archives this app writes are OOXML packages of a few kilobytes.
    case zip64Required(String)
    case deflateFailed(String)
}

/// Minimal ZIP **writer** for the OOXML packages of P6-b (decision D6-W1).
///
/// Why hand-rolled instead of a dependency: the app needs to produce three
/// fixed, small, known-in-advance packages (docx/xlsx/pptx). A full ZIP
/// implementation would add a third-party dependency for exactly one code path,
/// and the Finder extension must stay free of it entirely. zlib already ships
/// with the OS, so the only parts we implement are the container format and
/// CRC32 (via zlib).
///
/// Deliberately **not** supported, because nothing needs it:
/// - ZIP64 (files/archives ≥ 4 GiB, > 65535 entries): rejected explicitly.
/// - Encryption, data descriptors, multi-disk.
/// - Per-entry comments (the archive-level comment **is** written: the
///   compression dialog's "标签" goes into the end-of-central-directory record).
/// - Directory entries: OOXML packages only address parts by full name.
/// - Adjusting the MS-DOS timestamp: every entry gets a fixed 1980-01-01 stamp,
///   so the same input produces byte-identical output (testable, diffable).
///
/// Compression: DEFLATE, falling back to STORED when deflating does not shrink
/// an entry (already-compressed or tiny payloads). Both methods are read by
/// every OOXML consumer; the choice is per entry and recorded in the headers.
enum ZipWriter {

    /// Local file header / central directory / end of central directory.
    private enum Signature {
        static let localFileHeader: UInt32 = 0x0403_4b50
        static let centralDirectoryHeader: UInt32 = 0x0201_4b50
        static let endOfCentralDirectory: UInt32 = 0x0605_4b50
    }

    /// "Version needed to extract" 2.0 = deflate + folders. Every reader since
    /// PKZIP 2.0 understands this; 1.0 would not cover DEFLATE.
    private static let versionNeeded: UInt16 = 20
    /// 1980-01-01 00:00:00 in MS-DOS date/time. See the type comment: fixed to
    /// keep the output deterministic.
    private static let dosTime: UInt16 = 0x0000
    private static let dosDate: UInt16 = 0x0021
    /// General-purpose bit 11: file name is UTF-8 (not the legacy CP437).
    private static let utf8NameFlag: UInt16 = 0x0800

    private static let maximumEntries = 0xFFFF
    private static let maximumSize: UInt64 = 0xFFFF_FFFF

    /// Builds a complete archive. Entry order is preserved; OOXML requires
    /// `[Content_Types].xml` to be the first part, and callers pass it first.
    ///
    /// - Parameters:
    ///   - comment: archive comment stored in the end-of-central-directory
    ///     record (the "标签" the compression dialog offers). Only ZIP carries
    ///     one; other formats leave that field disabled.
    ///   - level: DEFLATE level, so 压缩模式 can trade speed for size.
    static func archive(
        _ entries: [ZipArchiveEntry],
        comment: String? = nil,
        level: Int32 = Z_DEFAULT_COMPRESSION,
        /// Called before each entry is deflated, with its index. This loop is
        /// where compression time actually goes, so it is where progress and a
        /// pause/cancel request can be observed at a useful granularity.
        onEntry: ((Int) throws -> Void)? = nil
    ) throws -> Data {
        guard entries.count <= maximumEntries else {
            throw ZipWriterError.zip64Required("\(entries.count) entries exceeds the ZIP limit of \(maximumEntries)")
        }

        var output = Data()
        var centralDirectory = Data()

        for (index, entry) in entries.enumerated() {
            try onEntry?(index)
            let nameBytes = try nameBytes(for: entry.name)
            let uncompressedSize = UInt64(entry.contents.count)
            guard uncompressedSize <= maximumSize else {
                throw ZipWriterError.zip64Required("entry “\(entry.name)” is larger than 4 GiB")
            }
            guard UInt64(output.count) <= maximumSize else {
                throw ZipWriterError.zip64Required("archive exceeds 4 GiB")
            }

            let (method, payload) = try compressed(entry, level: level)
            let crc = crc32(entry.contents)
            let flags = nameBytes.allSatisfy { $0 < 0x80 } ? 0 : utf8NameFlag
            let localHeaderOffset = UInt32(output.count)

            // Local file header
            append(Signature.localFileHeader, to: &output)
            append(versionNeeded, to: &output)
            append(flags, to: &output)
            append(method, to: &output)
            append(dosTime, to: &output)
            append(dosDate, to: &output)
            append(crc, to: &output)
            append(UInt32(payload.count), to: &output)
            append(UInt32(uncompressedSize), to: &output)
            append(UInt16(nameBytes.count), to: &output)
            append(UInt16(0), to: &output)   // extra field length
            output.append(contentsOf: nameBytes)
            output.append(payload)

            // Central directory header (same fields, plus the local offset).
            append(Signature.centralDirectoryHeader, to: &centralDirectory)
            append(versionNeeded, to: &centralDirectory)
            append(versionNeeded, to: &centralDirectory)
            append(flags, to: &centralDirectory)
            append(method, to: &centralDirectory)
            append(dosTime, to: &centralDirectory)
            append(dosDate, to: &centralDirectory)
            append(crc, to: &centralDirectory)
            append(UInt32(payload.count), to: &centralDirectory)
            append(UInt32(uncompressedSize), to: &centralDirectory)
            append(UInt16(nameBytes.count), to: &centralDirectory)
            append(UInt16(0), to: &centralDirectory)   // extra field length
            append(UInt16(0), to: &centralDirectory)   // comment length
            append(UInt16(0), to: &centralDirectory)   // disk number start
            append(UInt16(0), to: &centralDirectory)   // internal attributes
            append(UInt32(0), to: &centralDirectory)   // external attributes
            append(localHeaderOffset, to: &centralDirectory)
            centralDirectory.append(contentsOf: nameBytes)
        }

        let centralDirectoryOffset = UInt32(output.count)
        output.append(centralDirectory)

        // End of central directory record.
        append(Signature.endOfCentralDirectory, to: &output)
        append(UInt16(0), to: &output)   // this disk
        append(UInt16(0), to: &output)   // disk with the central directory
        append(UInt16(entries.count), to: &output)
        append(UInt16(entries.count), to: &output)
        append(UInt32(centralDirectory.count), to: &output)
        append(centralDirectoryOffset, to: &output)
        // The ZIP comment lives in the EOCD record and is capped at 64 KiB.
        let commentBytes = Array((comment ?? "").utf8.prefix(0xFFFF))
        append(UInt16(commentBytes.count), to: &output)
        output.append(contentsOf: commentBytes)

        return output
    }

    // MARK: - Entry preparation

    /// Validates `name` and returns its UTF-8 bytes.
    private static func nameBytes(for name: String) throws -> [UInt8] {
        guard !name.isEmpty else { throw ZipWriterError.invalidEntryName("name is empty") }
        guard !name.hasPrefix("/") else { throw ZipWriterError.invalidEntryName(name) }
        guard !name.contains("\\") else { throw ZipWriterError.invalidEntryName(name) }
        guard !name.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw ZipWriterError.invalidEntryName(name)
        }
        let bytes = Array(name.utf8)
        guard bytes.count <= 0xFFFF else { throw ZipWriterError.invalidEntryName(name) }
        return bytes
    }

    /// DEFLATEs `entry`, unless storing is smaller — then store.
    ///
    /// Empty content is always stored: raw DEFLATE of zero bytes is a two-byte
    /// empty block, which is legal but pointless.
    private static func compressed(_ entry: ZipArchiveEntry, level: Int32) throws -> (method: UInt16, payload: Data) {
        guard !entry.contents.isEmpty else { return (0, Data()) }
        guard let deflated = rawDeflate(entry.contents, level: level) else {
            throw ZipWriterError.deflateFailed(entry.name)
        }
        return deflated.count < entry.contents.count ? (8, deflated) : (0, entry.contents)
    }

    // MARK: - zlib

    /// CRC-32 (IEEE 802.3), the checksum ZIP stores per entry.
    static func crc32(_ data: Data) -> UInt32 {
        guard !data.isEmpty else { return 0 }
        var value: uLong = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return }
            value = zlib.crc32(0, base, uInt(raw.count))
        }
        return UInt32(truncatingIfNeeded: value)
    }

    /// Raw DEFLATE (no zlib header/trailer, no gzip wrapper), which is what a
    /// ZIP entry's compressed payload is.
    ///
    /// `windowBits = -15` is what asks zlib for the raw stream; `deflateInit2`
    /// is a C macro and therefore invisible to Swift, so the ABI-level
    /// `deflateInit2_` is called with the size of `z_stream` explicitly.
    static func rawDeflate(_ data: Data, level: Int32 = Z_DEFAULT_COMPRESSION) -> Data? {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        let initResult = deflateInit2_(
            &stream,
            level,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else { return nil }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var status: Int32 = Z_OK

        data.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(raw.count)
            repeat {
                var produced = 0
                buffer.withUnsafeMutableBytes { out in
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = deflate(&stream, Z_FINISH)
                    produced = chunkSize - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(contentsOf: buffer[0..<produced])
                }
            } while status == Z_OK
        }

        return status == Z_STREAM_END ? output : nil
    }

    // MARK: - Little-endian helpers

    private static func append(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
