import XCTest
import zlib

/// Hermetic ZIP reader used **only** by tests.
///
/// `ZipWriter` is the thing under test, so reading the archive back with an
/// independent parser is the point — if the local header, the central directory
/// and the end-of-central-directory record did not agree, the round trip here
/// would fail even though the bytes "look like" a ZIP. zlib does the inflating
/// because that part is not ours either.
///
/// Deliberately strict: unknown signatures, unreadable names and inflate
/// failures all throw rather than returning partial data.
struct ZipTestReader {
    struct Entry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let data: Data
    }

    enum Failure: Error, Equatable {
        case endOfCentralDirectoryMissing
        case badSignature(offset: Int)
        case unreadableName(offset: Int)
        case truncated(offset: Int)
        case unsupportedMethod(UInt16)
        case inflateFailed
        case crcMismatch(name: String)
        case sizeMismatch(name: String)
    }

    let entries: [Entry]

    init(_ archive: Data) throws {
        let bytes = [UInt8](archive)

        func u16(_ offset: Int) throws -> UInt16 {
            guard offset + 2 <= bytes.count else { throw Failure.truncated(offset: offset) }
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        func u32(_ offset: Int) throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw Failure.truncated(offset: offset) }
            return UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
        func name(_ offset: Int, _ length: Int) throws -> String {
            guard offset + length <= bytes.count else { throw Failure.unreadableName(offset: offset) }
            return String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
        }

        // End of central directory: scan backwards, allowing for a comment we
        // never write but a reader still has to tolerate.
        let signature: UInt32 = 0x0605_4b50
        var endOffset: Int?
        var candidate = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while candidate >= lowest {
            if try u32(candidate) == signature {
                endOffset = candidate
                break
            }
            candidate -= 1
        }
        guard let eocd = endOffset else { throw Failure.endOfCentralDirectoryMissing }

        let entryCount = Int(try u16(eocd + 10))
        var cursor = Int(try u32(eocd + 16))
        var parsed: [Entry] = []
        parsed.reserveCapacity(entryCount)

        for _ in 0..<entryCount {
            guard try u32(cursor) == 0x0201_4b50 else { throw Failure.badSignature(offset: cursor) }
            let method = try u16(cursor + 10)
            let crc = try u32(cursor + 16)
            let compressedSize = Int(try u32(cursor + 20))
            let uncompressedSize = Int(try u32(cursor + 24))
            let nameLength = Int(try u16(cursor + 28))
            let extraLength = Int(try u16(cursor + 30))
            let commentLength = Int(try u16(cursor + 32))
            let localOffset = Int(try u32(cursor + 42))
            let entryName = try name(cursor + 46, nameLength)

            guard try u32(localOffset) == 0x0403_4b50 else { throw Failure.badSignature(offset: localOffset) }
            let localNameLength = Int(try u16(localOffset + 26))
            let localExtraLength = Int(try u16(localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + compressedSize <= bytes.count else { throw Failure.truncated(offset: dataStart) }
            let payload = Data(bytes[dataStart..<(dataStart + compressedSize)])

            let contents: Data
            switch method {
            case 0:
                contents = payload
            case 8:
                contents = try ZipTestReader.inflate(payload, expectedSize: uncompressedSize)
            default:
                throw Failure.unsupportedMethod(method)
            }

            guard contents.count == uncompressedSize else { throw Failure.sizeMismatch(name: entryName) }
            guard ZipWriter.crc32(contents) == crc else { throw Failure.crcMismatch(name: entryName) }

            parsed.append(Entry(
                name: entryName,
                method: method,
                crc: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                data: contents
            ))
            cursor += 46 + nameLength + extraLength + commentLength
        }

        entries = parsed
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    func text(named name: String) -> String? {
        guard let entry = entry(named: name) else { return nil }
        return String(data: entry.data, encoding: .utf8)
    }

    /// Raw (header-less) DEFLATE, the same stream shape a ZIP entry stores.
    private static func inflate(_ payload: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        let initResult = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else { throw Failure.inflateFailed }
        defer { inflateEnd(&stream) }

        var output = Data()
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

        guard status == Z_STREAM_END || (status == Z_BUF_ERROR && output.count == expectedSize) else {
            throw Failure.inflateFailed
        }
        return output
    }
}

/// P6-b: the hand-rolled ZIP container that carries the generated OOXML.
final class ZipWriterTests: XCTestCase {

    private func makeArchive(_ entries: [(String, String)]) throws -> Data {
        try ZipWriter.archive(entries.map { ZipArchiveEntry(name: $0.0, contents: Data($0.1.utf8)) })
    }

    func testRoundTripsNamesAndContents() throws {
        let archive = try makeArchive([
            ("[Content_Types].xml", "<Types/>"),
            ("word/document.xml", String(repeating: "<w:p/>", count: 500)),
            ("media/empty.bin", ""),
        ])
        let reader = try ZipTestReader(archive)

        XCTAssertEqual(reader.entries.map(\.name), ["[Content_Types].xml", "word/document.xml", "media/empty.bin"])
        XCTAssertEqual(reader.text(named: "[Content_Types].xml"), "<Types/>")
        XCTAssertEqual(reader.text(named: "word/document.xml"), String(repeating: "<w:p/>", count: 500))
        XCTAssertEqual(reader.entry(named: "media/empty.bin")?.data, Data())
        XCTAssertEqual(reader.entry(named: "media/empty.bin")?.uncompressedSize, 0)
    }

    /// Entry order is part of the contract: OOXML readers expect
    /// `[Content_Types].xml` first.
    func testPreservesEntryOrder() throws {
        let names = ["[Content_Types].xml", "_rels/.rels", "word/document.xml"]
        let reader = try ZipTestReader(try makeArchive(names.map { ($0, "<x/>") }))
        XCTAssertEqual(reader.entries.map(\.name), names)
    }

    func testDeflatesCompressibleContentAndStoresIncompressibleContent() throws {
        let compressible = String(repeating: "A", count: 4096)
        let incompressible = String(decoding: (0..<64).map { UInt8($0) }, as: UTF8.self)
        let reader = try ZipTestReader(try makeArchive([
            ("big.xml", compressible),
            ("random.bin", incompressible),
        ]))

        XCTAssertEqual(reader.entry(named: "big.xml")?.method, 8, "repetitive XML must be deflated")
        XCTAssertLessThan(reader.entry(named: "big.xml")?.compressedSize ?? .max, 4096)
        XCTAssertEqual(reader.entry(named: "random.bin")?.method, 0, "storing beats deflating 64 random bytes")
        XCTAssertEqual(reader.entry(named: "random.bin")?.data, Data(incompressible.utf8))
    }

    func testEmptyPayloadIsStoredWithACorrectCRC() throws {
        let reader = try ZipTestReader(try ZipWriter.archive([ZipArchiveEntry(name: "empty", contents: Data())]))
        XCTAssertEqual(reader.entry(named: "empty")?.method, 0)
        XCTAssertEqual(reader.entry(named: "empty")?.crc, 0)
    }

    /// Fixed MS-DOS timestamps: identical input must produce identical bytes, so
    /// a regression shows up as a diff instead of as "probably fine".
    func testOutputIsDeterministic() throws {
        let entries = [ZipArchiveEntry(name: "a.xml", contents: Data("<a/>".utf8))]
        XCTAssertEqual(try ZipWriter.archive(entries), try ZipWriter.archive(entries))
    }

    func testCRC32MatchesTheStandardCheckVector() {
        XCTAssertEqual(ZipWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(ZipWriter.crc32(Data()), 0)
    }

    func testRejectsTraversalShapedEntryNames() {
        let bad = ["", "/absolute.xml", "../escape.xml", "a/../../b.xml", "back\\slash.xml"]
        for name in bad {
            XCTAssertThrowsError(
                try ZipWriter.archive([ZipArchiveEntry(name: name, contents: Data("<x/>".utf8))]),
                "“\(name)” must be rejected"
            ) { error in
                guard case ZipWriterError.invalidEntryName = error else {
                    return XCTFail("expected invalidEntryName for “\(name)”, got \(error)")
                }
            }
        }
    }

    func testRejectsMoreEntriesThanTheFormatCanDescribe() {
        let entries = (0...0xFFFF).map { ZipArchiveEntry(name: "e\($0)", contents: Data()) }
        XCTAssertThrowsError(try ZipWriter.archive(entries)) { error in
            guard case ZipWriterError.zip64Required = error else {
                return XCTFail("expected zip64Required, got \(error)")
            }
        }
    }

    /// An EOCD count of exactly 0xFFFF is the ZIP64 sentinel — readers treat it
    /// as "the real count lives in a ZIP64 record", and `ZipReader` rejects the
    /// archive for it. Stopping one short is what keeps our own output readable.
    /// 65535 one-byte entries are cheap; a 65534-entry archive would not be.
    func testRejectsTheEntryCountThatMeansZip64() {
        let entries = (0..<0xFFFF).map { ZipArchiveEntry(name: "e\($0)", contents: Data([0])) }
        XCTAssertThrowsError(try ZipWriter.archive(entries)) { error in
            guard case ZipWriterError.zip64Required = error else {
                return XCTFail("expected zip64Required, got \(error)")
            }
        }
    }

    func testAcceptsASingleEntryAtTheLowEnd() throws {
        let reader = try ZipTestReader(try ZipWriter.archive([ZipArchiveEntry(name: "a", contents: Data([0]))]))
        XCTAssertEqual(reader.entries.map(\.name), ["a"])
    }

    /// The extractor's `safeRelativePath` refuses NUL, so a name carrying one
    /// would describe an archive this app can write but not unpack.
    func testRejectsAnEntryNameWithAnEmbeddedNUL() {
        for name in ["nul\u{0}.xml", "a\u{0}b"] {
            XCTAssertThrowsError(
                try ZipWriter.archive([ZipArchiveEntry(name: name, contents: Data())]),
                "“\(name)” must be rejected"
            ) { error in
                guard case ZipWriterError.invalidEntryName = error else {
                    return XCTFail("expected invalidEntryName for “\(name)”, got \(error)")
                }
            }
        }
    }

    /// The EOCD's offset/size fields are the only ones the per-entry guards do
    /// not cover, so the boundary is checked directly: 0xFFFF_FFFF is the last
    /// representable value, anything past it has to throw instead of trapping.
    /// The values are synthetic — a real 4 GiB archive in a unit test would be
    /// absurd.
    func testCentralDirectoryOffsetAcceptsTheLargestRepresentableArchive() throws {
        XCTAssertEqual(
            try ZipWriter.centralDirectoryOffset(archiveSize: 0xFFFF_FFFF, centralDirectorySize: 0, trailerSize: 0),
            0xFFFF_FFFF
        )
    }

    func testCentralDirectoryOffsetRejectsAnythingPastThe32BitFields() {
        let oversized: [(archiveSize: Int, centralDirectorySize: Int, trailerSize: Int)] = [
            (0x1_0000_0000, 0, 0),        // offset itself past 32 bits
            (0, 0x1_0000_0000, 0),        // central directory past 32 bits
            (0xFFFF_FFFF, 1, 0),          // each field fits, the archive does not
            (0xFFFF_FFFF, 0, 22 + 1),     // the EOCD trailer tips it over
        ]
        for value in oversized {
            XCTAssertThrowsError(
                try ZipWriter.centralDirectoryOffset(
                    archiveSize: value.archiveSize,
                    centralDirectorySize: value.centralDirectorySize,
                    trailerSize: value.trailerSize
                ),
                "\(value.archiveSize)/\(value.centralDirectorySize)/\(value.trailerSize) must not fit"
            ) { error in
                guard case ZipWriterError.zip64Required = error else {
                    return XCTFail("expected zip64Required, got \(error)")
                }
            }
        }
    }
}
