import XCTest

/// Interoperability net for PKWARE traditional ZIP encryption ("ZipCrypto").
///
/// A round trip through our own writer and our own reader would pass for any
/// self-consistent cipher, so it proves nothing: the scheme is only as good as
/// its agreement with everybody else's implementation. Every test below ends in
/// a foreign implementation instead — `/usr/bin/unzip` has to accept and decode
/// the bytes we write, and `/usr/bin/zip -e` supplies the bytes we read. Those
/// two tools ship with macOS, so the checks are hermetic.
final class ZipCryptoTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-zipcrypto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The header Info-ZIP and 7-Zip agree on

    func testTheEncryptedHeaderHasTheInfoZipShape() {
        let crc: UInt32 = 0x1234_5678
        let random = Data(repeating: 0xAB, count: 10)

        let header = ZipCrypto.header(crc: crc, random: random)

        XCTAssertEqual(header.count, ZipCrypto.encryptedHeaderLength)
        XCTAssertEqual(Data(header.prefix(10)), random, "the first 10 bytes are whatever the RNG produced")
        XCTAssertEqual(header[header.startIndex + 10], 0x34, "byte 10 is the high byte of the CRC's low half")
        XCTAssertEqual(header[header.startIndex + 11], 0x12, "byte 11 is the CRC's top byte, the password check byte")
        XCTAssertEqual(header[header.startIndex + 11], ZipCrypto.checkByte(forCRC: crc))
    }

    func testTheWriterRefusesAnEmptyPassword() {
        let entries = [ZipArchiveEntry(name: "a.txt", contents: Data("a".utf8))]

        XCTAssertThrowsError(try ZipWriter.archive(entries, encryption: ZipEncryption(password: ""))) { error in
            XCTAssertEqual(error as? ZipWriterError, .encryptionFailed("the password is empty"))
        }
    }

    func testTheWriterRefusesToEncryptWithoutRandomness() {
        let entries = [ZipArchiveEntry(name: "a.txt", contents: Data("a".utf8))]
        let encryption = ZipEncryption(password: "p", randomSource: UnavailableRandomSource())

        XCTAssertThrowsError(try ZipWriter.archive(entries, encryption: encryption)) { error in
            XCTAssertEqual(
                error as? ZipWriterError,
                .encryptionFailed("the system random number generator is unavailable")
            )
        }
    }

    func testTheSystemSourceProducesFreshRandomBytes() throws {
        let source = SystemRandomSource()

        let first = try XCTUnwrap(source.bytes(12))
        let second = try XCTUnwrap(source.bytes(12))

        XCTAssertEqual(first.count, 12)
        XCTAssertNotEqual(first, second, "12 random bytes repeating means the source is stubbed or broken")
    }

    func testATruncatedCiphertextIsRefused() {
        // An entry payload is a 12-byte header plus the compressed body, so
        // anything shorter than the header cannot be a valid entry.
        XCTAssertThrowsError(try ZipCrypto.decrypt(Data(repeating: 0, count: 11), password: "p")) { error in
            XCTAssertEqual(error as? ZipCryptoError, .truncated)
        }
    }

    // MARK: - What we write, Info-ZIP has to unlock

    func testEncryptedEntriesCarryTheFlagTheHeaderAndThePlaintextCRC() throws {
        let contents = Data("menu right zipcrypto\n".utf8)
        let password = "s3cret"
        let entries = [ZipArchiveEntry(name: "note.txt", contents: contents)]

        let encrypted = try ZipWriter.archive(
            entries,
            encryption: ZipEncryption(password: password, randomSource: FixedRandomSource(0x5A))
        )
        let plain = try ZipWriter.archive(entries)

        let encryptedEntry = try localEntry(in: encrypted)
        let plainEntry = try localEntry(in: plain)

        XCTAssertEqual(encryptedEntry.flags & 0x0001, 0x0001, "general-purpose bit 0 marks the entry as encrypted")
        XCTAssertEqual(encryptedEntry.name, "note.txt")
        XCTAssertEqual(encryptedEntry.versionNeeded, 20, "2.0 is what PKZIP 2.x-era encryption needs, same as DEFLATE")
        XCTAssertEqual(encryptedEntry.extraLength, 0, "traditional encryption needs no extra field")
        XCTAssertEqual(encryptedEntry.crc, ZipWriter.crc32(contents), "the CRC stays the plaintext's: it seeds the check byte")
        XCTAssertEqual(encryptedEntry.uncompressedSize, contents.count)
        XCTAssertEqual(encryptedEntry.method, plainEntry.method, "the compression method is unchanged; only the payload is wrapped")
        XCTAssertEqual(encryptedEntry.compressedSize, plainEntry.compressedSize + ZipCrypto.encryptedHeaderLength)

        let unlocked = try ZipCrypto.decrypt(encryptedEntry.payload, password: password)
        XCTAssertEqual(unlocked.checkByte, ZipCrypto.checkByte(forCRC: encryptedEntry.crc))
        XCTAssertEqual(unlocked.payload.count, plainEntry.compressedSize)
    }

    func testInfoZipOpensAnArchiveWeEncrypted() throws {
        let contents = Data((0..<4096).map { UInt8($0 % 251) })
        let password = "correct horse battery"
        let archive = try ZipWriter.archive(
            [ZipArchiveEntry(name: "payload.bin", contents: contents)],
            encryption: ZipEncryption(password: password)
        )
        let url = root.appendingPathComponent("ours.zip")
        try archive.write(to: url)

        let verified = try run("/usr/bin/unzip", ["-P", password, "-t", url.path])
        XCTAssertEqual(verified.status, 0, "Info-ZIP must accept our archive: \(verified.output)")
        XCTAssertTrue(verified.output.contains("No errors detected"), verified.output)

        let wrongPassword = try run("/usr/bin/unzip", ["-P", "not the password", "-t", url.path])
        XCTAssertNotEqual(wrongPassword.status, 0, "the password check byte must reject a wrong password")

        let destination = root.appendingPathComponent("extracted", isDirectory: true)
        let extracted = try run("/usr/bin/unzip", ["-P", password, "-d", destination.path, url.path])
        XCTAssertEqual(extracted.status, 0, extracted.output)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("payload.bin")), contents)
    }

    func testInjectedRandomnessMakesTheOutputDeterministic() throws {
        let entries = [ZipArchiveEntry(name: "a.txt", contents: Data("a".utf8))]
        func make() throws -> Data {
            try ZipWriter.archive(entries, encryption: ZipEncryption(password: "p", randomSource: FixedRandomSource(0x11)))
        }

        XCTAssertEqual(try make(), try make(), "the only source of variation is the injected header")
    }

    func testInfoZipAcceptsOurCheckByteAndRejectsATamperedOne() throws {
        // `unzip` judges the password from the header's check byte *before* it
        // looks at the payload, so flipping that one byte while leaving the
        // payload intact is a precise probe: if a foreign reader still accepted
        // the archive, our check byte would not be carrying the value PKWARE
        // specifies.
        let contents = Data("check byte probe\n".utf8)
        let password = "probe"
        let archive = try ZipWriter.archive(
            [ZipArchiveEntry(name: "probe.txt", contents: contents)],
            encryption: ZipEncryption(password: password, randomSource: FixedRandomSource(0x33))
        )
        let url = root.appendingPathComponent("probe.zip")
        try archive.write(to: url)
        let accepted = try run("/usr/bin/unzip", ["-P", password, "-t", url.path])
        XCTAssertEqual(accepted.status, 0, accepted.output)

        let entry = try localEntry(in: archive)
        XCTAssertEqual(entry.flags & 0x0008, 0, "the local header carries the real CRC, so no streaming marker")

        var tampered = archive
        tampered[tampered.startIndex + entry.payloadOffset + 11] ^= 0xFF
        let tamperedURL = root.appendingPathComponent("tampered.zip")
        try tampered.write(to: tamperedURL)

        let rejected = try run("/usr/bin/unzip", ["-P", password, "-t", tamperedURL.path])
        XCTAssertNotEqual(rejected.status, 0, "an intact payload with a wrong check byte must still be rejected")
        XCTAssertTrue(rejected.output.contains("incorrect password"), rejected.output)
    }

    // MARK: - What Info-ZIP writes, we have to unlock

    func testWeDecryptAnArchiveInfoZipEncrypted() throws {
        let contents = Data("zipcrypto, written by the other side\n".utf8)
        let source = root.appendingPathComponent("plain.txt")
        try contents.write(to: source)
        let password = "hunter2"
        let archiveURL = root.appendingPathComponent("infozip.zip")

        // -0 keeps the entry STORED, so the decrypted payload is the file itself.
        let created = try run("/usr/bin/zip", ["-0", "-j", "-P", password, archiveURL.path, source.path])
        XCTAssertEqual(created.status, 0, created.output)

        let entry = try localEntry(in: Data(contentsOf: archiveURL))
        XCTAssertEqual(entry.flags & 0x0001, 0x0001)
        XCTAssertEqual(entry.method, 0)

        let unlocked = try ZipCrypto.decrypt(entry.payload, password: password)
        XCTAssertEqual(unlocked.payload, contents, "our keystream has to match Info-ZIP's byte for byte")

        // The check byte is *not* comparable in this direction, and that is not
        // our bug: Info-ZIP streams encrypted entries (general-purpose bit 3),
        // so it does not know the CRC when it writes the header and stores the
        // entry's DOS timestamp in the last two header bytes instead — `unzip`
        // compares against that same value, which is exactly why
        // `testInfoZipAcceptsOurCheckByteAndRejectsATamperedOne` has to corrupt
        // ours to prove it is read at all. Our writer always knows the CRC
        // first, so it gets to write the documented PKWARE value.
        XCTAssertEqual(entry.flags & 0x0008, 0x0008, "Info-ZIP's encrypted entries are streamed")
    }

    // MARK: - Helpers

    private struct UnavailableRandomSource: ZipRandomSource {
        func bytes(_ count: Int) -> Data? { nil }
    }

    private struct LocalEntry {
        let name: String
        let versionNeeded: UInt16
        let flags: UInt16
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let extraLength: Int
        let payloadOffset: Int
        let payload: Data
    }

    private enum ParseFailure: Error {
        case truncated
        case signatureMissing
    }

    /// Reads the single local file header every archive in this suite starts with.
    ///
    /// Deliberately hand-rolled rather than reusing `ZipTestReader`: that reader
    /// inflates payloads and verifies CRCs, which is exactly what cannot happen
    /// for ciphertext.
    private func localEntry(in archive: Data) throws -> LocalEntry {
        let bytes = [UInt8](archive)
        func u16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }

        guard bytes.count >= 30 else { throw ParseFailure.truncated }
        guard u32(0) == 0x0403_4b50 else { throw ParseFailure.signatureMissing }
        let nameLength = Int(u16(26))
        let extraLength = Int(u16(28))
        guard bytes.count >= 30 + nameLength + extraLength else { throw ParseFailure.truncated }
        let compressedSize = Int(u32(18))
        let payloadStart = 30 + nameLength + extraLength
        guard bytes.count >= payloadStart + compressedSize else { throw ParseFailure.truncated }

        return LocalEntry(
            name: String(decoding: bytes[30..<(30 + nameLength)], as: UTF8.self),
            versionNeeded: u16(4),
            flags: u16(6),
            method: u16(8),
            crc: u32(14),
            compressedSize: compressedSize,
            uncompressedSize: Int(u32(22)),
            extraLength: extraLength,
            payloadOffset: payloadStart,
            payload: Data(bytes[payloadStart..<(payloadStart + compressedSize)])
        )
    }

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("\(executable) is missing on this machine")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
    }
}
