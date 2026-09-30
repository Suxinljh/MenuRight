import Foundation
import zlib

/// One entry of a ZIP archive's central directory.
///
/// Everything the extraction policy needs to decide *before* any byte is
/// written: the name (the zip-slip surface), the sizes (the size guard), and the
/// POSIX mode (directory / symlink detection).
struct ZipEntryRecord: Equatable {
    let name: String
    let compressionMethod: UInt16
    let crc32: UInt32
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
    let isDirectory: Bool
    /// A symlink entry is rejected by the extractor: its "contents" are a target
    /// path, and writing one is how a zip escapes the destination directory.
    let isSymbolicLink: Bool
}

enum ZipReaderError: Error, Equatable {
    case notAnArchive
    case truncated
    /// ZIP64 (≥ 4 GiB parts, > 65535 entries) is deliberately unsupported: the
    /// size guard rejects payloads that large before this could matter.
    case zip64Unsupported
    case unsupportedCompression(UInt16)
    /// The archive is password-protected (`ZipError.encryptionNotSupported` in
    /// SWCompression); this build never handles encrypted entries.
    case encryptedNotSupported
    case corruptEntry(String)
    case crcMismatch(String)
    case inflateFailed(String)
}

/// Minimal ZIP **reader** for the extraction path.
///
/// Scope mirrors `ZipWriter`: the shapes this app creates plus what ordinary
/// tools produce for them (STORED + DEFLATE, no ZIP64, no encryption). Anything
/// else fails with a typed error instead of guessing.
///
/// The archive is kept as `Data`, and callers are expected to open it with
/// `.mappedIfSafe`, so a large archive is paged in rather than duplicated; the
/// central directory is parsed through one `withUnsafeBytes` view, and an entry
/// is inflated only when the extractor asks for it.
struct ZipReader {
    private enum Signature {
        static let centralDirectoryHeader: UInt32 = 0x0201_4b50
        static let endOfCentralDirectory: UInt32 = 0x0605_4b50
        static let zip64EndOfCentralDirectoryLocator: UInt32 = 0x0706_4b50
        static let localFileHeader: UInt32 = 0x0403_4b50
    }

    private let data: Data
    let entries: [ZipEntryRecord]
    /// Non-nil when the archive carries a comment; kept for diagnostics.
    let comment: String?

    init(fileURL: URL) throws {
        try self.init(data: try Data(contentsOf: fileURL, options: [.mappedIfSafe]))
    }

    init(data: Data) throws {
        self.data = data

        var parsed: [ZipEntryRecord] = []
        var archiveComment: String?

        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count

            func u16(_ offset: Int) throws -> UInt16 {
                guard offset >= 0, offset + 2 <= count else { throw ZipReaderError.truncated }
                return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            }
            func u32(_ offset: Int) throws -> UInt32 {
                guard offset >= 0, offset + 4 <= count else { throw ZipReaderError.truncated }
                return UInt32(bytes[offset])
                    | (UInt32(bytes[offset + 1]) << 8)
                    | (UInt32(bytes[offset + 2]) << 16)
                    | (UInt32(bytes[offset + 3]) << 24)
            }

            // End of central directory: last occurrence whose comment length
            // exactly reaches the end of the file.
            guard count >= 22 else { throw ZipReaderError.notAnArchive }
            var endOffset = -1
            var commentLength = 0
            var candidate = count - 22
            let lowest = max(0, count - 22 - 65_535)
            while candidate >= lowest {
                if try u32(candidate) == Signature.endOfCentralDirectory {
                    let length = Int(try u16(candidate + 20))
                    if candidate + 22 + length == count {
                        endOffset = candidate
                        commentLength = length
                        break
                    }
                }
                candidate -= 1
            }
            guard endOffset >= 0 else { throw ZipReaderError.notAnArchive }
            if commentLength > 0 {
                archiveComment = String(decoding: bytes[(endOffset + 22)..<count], as: UTF8.self)
            }

            if endOffset >= 20, try u32(endOffset - 20) == Signature.zip64EndOfCentralDirectoryLocator {
                throw ZipReaderError.zip64Unsupported
            }

            let rawEntryCount = try u16(endOffset + 10)
            let directorySize = try u32(endOffset + 12)
            let directoryOffset = try u32(endOffset + 16)
            // The 16/32-bit sentinels mean the real values live in ZIP64 records.
            guard rawEntryCount != 0xFFFF, directoryOffset != 0xFFFF_FFFF, directorySize != 0xFFFF_FFFF else {
                throw ZipReaderError.zip64Unsupported
            }
            let entryCount = Int(rawEntryCount)
            let start = Int(directoryOffset)
            guard start + Int(directorySize) <= count else { throw ZipReaderError.truncated }

            parsed.reserveCapacity(entryCount)
            var cursor = start

            for _ in 0..<entryCount {
                guard try u32(cursor) == Signature.centralDirectoryHeader else {
                    throw ZipReaderError.corruptEntry("central directory record at \(cursor)")
                }
                let method = try u16(cursor + 10)
                let flags = try u16(cursor + 8)
                // General-purpose bit 0: the entry is encrypted. Refusing here
                // is the honest answer — the payload would otherwise fail as a
                // confusing CRC/inflate error.
                if flags & 0x0001 != 0 { throw ZipReaderError.encryptedNotSupported }
                let crc = try u32(cursor + 16)
                let rawCompressedSize = try u32(cursor + 20)
                let rawUncompressedSize = try u32(cursor + 24)
                let nameLength = Int(try u16(cursor + 28))
                let extraLength = Int(try u16(cursor + 30))
                let entryCommentLength = Int(try u16(cursor + 32))
                let externalAttributes = try u32(cursor + 38)
                let rawLocalOffset = try u32(cursor + 42)
                guard rawCompressedSize != 0xFFFF_FFFF, rawUncompressedSize != 0xFFFF_FFFF,
                      rawLocalOffset != 0xFFFF_FFFF else {
                    throw ZipReaderError.zip64Unsupported
                }
                guard cursor + 46 + nameLength <= count else { throw ZipReaderError.truncated }
                let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)

                let localOffset = Int(rawLocalOffset)
                guard localOffset + 30 <= count else { throw ZipReaderError.truncated }

                // High 16 bits of the external attributes hold the POSIX mode.
                let mode = UInt16((externalAttributes >> 16) & 0xFFFF)
                let fileType = mode & 0xF000
                parsed.append(ZipEntryRecord(
                    name: name,
                    compressionMethod: method,
                    crc32: crc,
                    compressedSize: Int(rawCompressedSize),
                    uncompressedSize: Int(rawUncompressedSize),
                    localHeaderOffset: localOffset,
                    isDirectory: name.hasSuffix("/") || fileType == 0x4000,
                    isSymbolicLink: fileType == 0xA000
                ))

                cursor += 46 + nameLength + extraLength + entryCommentLength
            }
        }

        entries = parsed
        comment = archiveComment
    }

    /// Inflates (or copies) one entry and verifies its CRC and size.
    func contents(of entry: ZipEntryRecord) throws -> Data {
        let payload: Data = try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let offset = entry.localHeaderOffset
            guard offset >= 0, offset + 30 <= bytes.count else { throw ZipReaderError.truncated }
            let signature = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
            guard signature == Signature.localFileHeader else { throw ZipReaderError.corruptEntry(entry.name) }

            let nameLength = Int(UInt16(bytes[offset + 26]) | (UInt16(bytes[offset + 27]) << 8))
            let extraLength = Int(UInt16(bytes[offset + 28]) | (UInt16(bytes[offset + 29]) << 8))
            let start = offset + 30 + nameLength + extraLength
            guard start + entry.compressedSize <= bytes.count else { throw ZipReaderError.truncated }
            // Copy just this entry; the rest of the archive stays unmaterialized.
            return Data(bytes[start..<(start + entry.compressedSize)])
        }

        let contents: Data
        switch entry.compressionMethod {
        case 0:
            contents = payload
        case 8:
            guard let inflated = Self.rawInflate(payload, expectedSize: entry.uncompressedSize) else {
                throw ZipReaderError.inflateFailed(entry.name)
            }
            contents = inflated
        default:
            throw ZipReaderError.unsupportedCompression(entry.compressionMethod)
        }

        guard contents.count == entry.uncompressedSize else {
            throw ZipReaderError.corruptEntry("\(entry.name) (size \(contents.count) ≠ \(entry.uncompressedSize))")
        }
        guard ZipWriter.crc32(contents) == entry.crc32 else {
            throw ZipReaderError.crcMismatch(entry.name)
        }
        return contents
    }

    /// Raw (header-less) DEFLATE, the stream shape a ZIP entry stores.
    static func rawInflate(_ payload: Data, expectedSize: Int) -> Data? {
        guard !payload.isEmpty else { return expectedSize == 0 ? Data() : nil }

        var stream = z_stream()
        let initResult = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var output = Data()
        if expectedSize > 0 { output.reserveCapacity(expectedSize) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let chunkSize = buffer.count
        var status: Int32 = Z_OK

        payload.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(raw.count)
            repeat {
                var produced = 0
                buffer.withUnsafeMutableBytes { out in
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    produced = chunkSize - Int(stream.avail_out)
                }
                if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }
            } while status == Z_OK
        }

        guard status == Z_STREAM_END else { return nil }
        return output
    }
}
