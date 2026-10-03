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
    /// General-purpose bit 0: the payload carries a 12-byte ZipCrypto header and
    /// the compressed bytes are encrypted. The CRC here is the **plaintext** CRC,
    /// which is why it can be used to verify a password.
    let isEncrypted: Bool
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
    /// The entry is encrypted (general-purpose bit 0) and no password was given.
    /// A password is asked for by the main app, which is the only process that
    /// extracts; it never travels over the extension's IPC.
    case passwordRequired(String)
    /// A password was given, but it did not decrypt this entry.
    case badPassword(String)
    case corruptEntry(String)
    case crcMismatch(String)
    case inflateFailed(String)
    /// The DEFLATE output grew past the limit. Since `contents(of:)` later
    /// requires the output to equal the entry's declared size exactly, exceeding
    /// it proves the header lied — the signature of a zip bomb, not corruption.
    case inflateExceedsLimit(String)
}

/// Minimal ZIP **reader** for the extraction path.
///
/// Scope mirrors `ZipWriter`: the shapes this app creates plus what ordinary
/// tools produce for them (STORED + DEFLATE, no ZIP64, PKWARE traditional
/// encryption when a password is supplied). Anything else fails with a typed
/// error instead of guessing.
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
                // General-purpose bit 0: the entry is encrypted. The header is
                // still parsed — the sizes, the CRC and the name are all in the
                // clear — so the extractor can ask for a password instead of
                // refusing the whole archive up front.
                let isEncrypted = flags & 0x0001 != 0
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
                let name = ZipNameDecoder.decode(
                    bytes[(cursor + 46)..<(cursor + 46 + nameLength)],
                    utf8Flag: flags & 0x0800 != 0
                )

                let localOffset = Int(rawLocalOffset)
                guard localOffset + 30 <= count else { throw ZipReaderError.truncated }

                // High 16 bits of the external attributes hold the POSIX mode.
                let mode = UInt16((externalAttributes >> 16) & 0xFFFF)
                let fileType = mode & 0xF000
                parsed.append(ZipEntryRecord(
                    name: name,
                    compressionMethod: method,
                    isEncrypted: isEncrypted,
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

    /// True when at least one entry needs a password: encrypted **and** carrying a
    /// method this reader can inflate. A WinZip-AES entry (method 99) is
    /// encrypted too, but no password would ever help, so it must not make the
    /// app ask for one — the planner refuses it with a method error instead.
    var needsPassword: Bool {
        entries.contains { entry in
            entry.isEncrypted
                && !entry.isDirectory
                && (entry.compressionMethod == 0 || entry.compressionMethod == 8)
        }
    }

    /// The entry a password is checked against. Verifying on the smallest entry
    /// keeps a wrong-password guess cheap.
    private var passwordProbe: ZipEntryRecord? {
        entries
            .filter { $0.isEncrypted && !$0.isDirectory && ($0.compressionMethod == 0 || $0.compressionMethod == 8) }
            .min { $0.compressedSize < $1.compressedSize }
    }

    /// Whether `password` decrypts this archive. Non-encrypted archives accept any
    /// password (there is nothing to unlock).
    func validates(password: String) -> Bool {
        guard let probe = passwordProbe else { return true }
        return (try? contents(of: probe, password: password)) != nil
    }

    /// Inflates (or copies) one entry and verifies its CRC and size.
    ///
    /// - Parameter password: the ZipCrypto password for an encrypted entry. It is
    ///   ignored for plain ones; an encrypted entry without it fails with
    ///   `passwordRequired` rather than the confusing CRC/inflate error the raw
    ///   bytes would produce.
    /// - Parameter maximumOutputBytes: the caller's (extractor's) hard cap on the
    ///   inflated payload. The entry's own declared size is also an absolute cap
    ///   here: the size check below demands an exact match, so a stream that
    ///   grows past it has already been disqualified.
    func contents(of entry: ZipEntryRecord, password: String? = nil, maximumOutputBytes: Int64 = .max) throws -> Data {
        let stored: Data = try data.withUnsafeBytes { raw in
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

        // An encrypted entry stores its 12-byte ZipCrypto header in front of the
        // (encrypted) compressed bytes, and `compressedSize` counts both.
        let payload: Data
        if entry.isEncrypted {
            guard let password, !password.isEmpty else {
                throw ZipReaderError.passwordRequired(entry.name)
            }
            do {
                // The check byte the header carries is a fast "yes" but not a
                // reliable "no": a streaming writer (general-purpose bit 3) puts a
                // timestamp there instead of the CRC's top byte. So the verdict is
                // the plaintext CRC check at the end of this method.
                payload = try ZipCrypto.decrypt(stored, password: password).payload
            } catch {
                throw ZipReaderError.badPassword(entry.name)
            }
        } else {
            payload = stored
        }

        let contents: Data
        switch entry.compressionMethod {
        case 0:
            contents = payload
        case 8:
            let inflated: Data?
            do {
                inflated = try Self.rawInflate(
                    payload,
                    expectedSize: entry.uncompressedSize,
                    maximumBytes: maximumOutputBytes
                )
            } catch let error as ZipReaderError {
                // 对加密条目来说，「解出来超过了声明长度」和「长度不对」一样，
                // 绝大多数时候是密码错了，而不是归档在说谎——只有明文条目
                // 才把超限当 zip bomb 报上去（带上条目名与两边的大小）。
                if case .inflateExceedsLimit(let detail) = error {
                    if entry.isEncrypted { throw ZipReaderError.badPassword(entry.name) }
                    throw ZipReaderError.inflateExceedsLimit(
                        "\(entry.name) (declared \(entry.uncompressedSize), \(detail))"
                    )
                }
                throw error
            }
            guard let inflated else {
                // Garbage from the wrong password almost always dies here.
                throw entry.isEncrypted
                    ? ZipReaderError.badPassword(entry.name)
                    : ZipReaderError.inflateFailed(entry.name)
            }
            contents = inflated
        default:
            throw ZipReaderError.unsupportedCompression(entry.compressionMethod)
        }

        guard contents.count == entry.uncompressedSize else {
            // For an encrypted entry both of these mean "that password was wrong"
            // far more often than they mean "the archive is damaged": a STORED
            // entry decrypts to the right *length* and the wrong *bytes*.
            throw entry.isEncrypted
                ? ZipReaderError.badPassword(entry.name)
                : ZipReaderError.corruptEntry("\(entry.name) (size \(contents.count) ≠ \(entry.uncompressedSize))")
        }
        guard ZipWriter.crc32(contents) == entry.crc32 else {
            throw entry.isEncrypted
                ? ZipReaderError.badPassword(entry.name)
                : ZipReaderError.crcMismatch(entry.name)
        }
        return contents
    }

    /// Raw (header-less) DEFLATE, the stream shape a ZIP entry stores.
    ///
    /// `maximumBytes` 是调用方（解压限额）给的上限；条目自己声明的
    /// `expectedSize` 也是硬上限——`contents(of:)` 最后要求两者精确相等，
    /// 所以过程中一旦超过它，就已经证明这个头部在说谎，不必再解完。
    ///
    /// `expectedSize` 是攻击者可控的声明值，绝不能只拿它做预分配：压缩炸弹
    /// 正是靠伪造一个 4 GiB 的声明让 `reserveCapacity` 先把内存吃掉。
    static func rawInflate(
        _ payload: Data,
        expectedSize: Int,
        maximumBytes: Int64 = .max
    ) throws -> Data? {
        let limit = min(Int64(clamping: expectedSize), maximumBytes)
        guard !payload.isEmpty else { return expectedSize == 0 ? Data() : nil }

        var stream = z_stream()
        let initResult = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var output = Data()
        output.reserveCapacity(min(max(expectedSize, 0), 16 * 1024 * 1024))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let chunkSize = buffer.count
        var status: Int32 = Z_OK

        try payload.withUnsafeBytes { raw in
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
                if produced > 0 {
                    // 先判上限再 append：超出的那一块连进 output 的机会都没有。
                    guard Int64(output.count) + Int64(produced) <= limit else {
                        throw ZipReaderError.inflateExceedsLimit(
                            "produced \(output.count + produced) bytes, limit \(limit)"
                        )
                    }
                    output.append(contentsOf: buffer[0..<produced])
                }
            } while status == Z_OK
        }

        guard status == Z_STREAM_END else { return nil }
        return output
    }
}

/// Decodes a ZIP entry name.
///
/// The spec is unambiguous: general-purpose bit 11 set means the name is UTF-8,
/// clear means "the original ZIP character encoding" — CP437. Real archives
/// ignore that in both directions, and the failure mode is the mojibake every
/// Chinese user has met: a zip made by Windows' own「压缩」carries GBK names with
/// bit 11 **clear**, and reading those as CP437 turns `新建文件夹` into
/// `ÐÂ½¨ÎÄ¼þ¼Ð` — in the menu, and in the file names actually written to disk.
///
/// So the cascade is:
///   1. bit 11 set → UTF-8 (lossy only if the writer lied);
///   2. pure ASCII → read as ASCII, which every candidate encoding agrees on;
///   3. valid UTF-8 → UTF-8, which covers the many tools that write UTF-8
///      without setting the flag (Info-ZIP, older macOS, our own early builds);
///   4. *mostly non-ASCII* bytes that decode as valid GB18030 into CJK →
///      GB18030, which subsumes GBK/GB2312 — the Windows case above;
///   5. otherwise CP437, which is what the spec says.
///
/// Steps 2–5 need no lookup tables: Foundation already ships all three
/// encodings. Step 4's two guards exist because GB18030 accepts a large fraction
/// of all byte pairs: without them, a genuinely CP437 Western name (`Übersicht`)
/// would be turned into Chinese characters. The byte-ratio guard is what
/// separates the two in practice — a Chinese name is mostly multi-byte, a
/// Western one is ASCII letters plus an accent or two. A *contrived* mixed-script
/// name that is both mostly non-ASCII and valid GB18030 is still read as Chinese;
/// that residual is deliberate, documented by a test, and much rarer than the
/// Windows case it buys.
///
/// The archive comment is deliberately *not* routed through this: it has no
/// per-entry flag of its own, and nothing but our own round-trip test reads it.
enum ZipNameDecoder {
    /// Generic over the collection so the reader can hand over its raw
    /// `UnsafeBufferPointer` slice without a copy, and tests can hand over an
    /// `ArraySlice`.
    static func decode<C: Collection>(_ bytes: C, utf8Flag: Bool) -> String where C.Element == UInt8 {
        let raw = Array(bytes)
        if utf8Flag {
            return String(data: Data(raw), encoding: .utf8) ?? String(decoding: raw, as: UTF8.self)
        }
        if raw.allSatisfy({ $0 < 0x80 }) {
            return String(decoding: raw, as: UTF8.self)
        }
        let data = Data(raw)
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if looksLikeLegacyChinese(raw), let gb = String(data: data, encoding: gb18030), containsCJK(gb) {
            return gb
        }
        if let legacy = String(data: data, encoding: cp437) { return legacy }
        // Nothing fits: keep the bytes visible rather than dropping the entry.
        return String(decoding: raw, as: UTF8.self)
    }

    /// At least a third of the bytes are non-ASCII — the shape of a legacy
    /// Chinese name (`文档.txt` = 4 of 8) rather than of a Western one
    /// (`Übersicht.txt` = 1 of 13).
    static func looksLikeLegacyChinese(_ raw: [UInt8]) -> Bool {
        guard !raw.isEmpty else { return false }
        let high = raw.filter { $0 >= 0x80 }.count
        return high * 3 >= raw.count
    }

    /// CP437 — `kCFStringEncodingDOSLatinUS`.
    static let cp437 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))
    )

    /// GB18030 — a superset of GBK and GB2312.
    static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    /// True when the text contains a CJK ideograph or CJK/fullwidth punctuation.
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x303F,      // CJK symbols and punctuation
                 0x3400...0x4DBF,      // CJK Unified Ideographs Extension A
                 0x4E00...0x9FFF,      // CJK Unified Ideographs
                 0xF900...0xFAFF,      // CJK Compatibility Ideographs
                 0xFF00...0xFFEF:      // Halfwidth and fullwidth forms
                return true
            default:
                return false
            }
        }
    }
}
