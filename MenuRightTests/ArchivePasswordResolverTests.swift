import XCTest

/// A one-entry ZIP protected with PKWARE traditional encryption (ZipCrypto).
///
/// Hand-built rather than produced by `zip -e` so a test can pin the two details
/// that make the read path interesting:
///
/// * `compressedSize` counts the 12-byte encryption header plus the ciphertext;
/// * `streaming` sets general-purpose bit 3, which is what Info-ZIP writes — the
///   header's last two bytes then hold the DOS time instead of the CRC check
///   bytes, so a reader must confirm a password against the plaintext, not there.
enum EncryptedZipFixture {
    static func archive(
        name: String = "secret.txt",
        contents: String,
        password: String,
        streaming: Bool = false
    ) -> Data {
        let plaintext = Data(contents.utf8)
        let crc = ZipWriter.crc32(plaintext)
        let nameBytes = Array(name.utf8)
        var header = ZipCrypto.header(crc: crc, random: Data((0..<10).map { UInt8($0) }))
        if streaming {
            header[10] = 0x21
            header[11] = 0x00
        }
        let stored = ZipCrypto.encrypt(plaintext, header: header, password: password)
        let flags: UInt16 = 0x0001 | (streaming ? 0x0008 : 0)

        func append16(_ value: UInt16, _ data: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append32(_ value: UInt32, _ data: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        var output = Data()
        append32(0x0403_4b50, &output)
        append16(20, &output)
        append16(flags, &output)
        append16(0, &output)              // STORED: the payload is the ciphertext
        append16(0, &output)              // time
        append16(0x0021, &output)         // date
        // A streaming writer cannot know the CRC yet, so it leaves these zero and
        // repeats them in the data descriptor below.
        append32(streaming ? 0 : crc, &output)
        append32(streaming ? 0 : UInt32(stored.count), &output)
        append32(streaming ? 0 : UInt32(plaintext.count), &output)
        append16(UInt16(nameBytes.count), &output)
        append16(0, &output)
        output.append(contentsOf: nameBytes)
        output.append(stored)
        if streaming {
            append32(0x0807_4b50, &output)
            append32(crc, &output)
            append32(UInt32(stored.count), &output)
            append32(UInt32(plaintext.count), &output)
        }

        var central = Data()
        append32(0x0201_4b50, &central)
        append16(20, &central)
        append16(20, &central)
        append16(flags, &central)
        append16(0, &central)
        append16(0, &central)
        append16(0x0021, &central)
        append32(crc, &central)
        append32(UInt32(stored.count), &central)
        append32(UInt32(plaintext.count), &central)
        append16(UInt16(nameBytes.count), &central)
        append16(0, &central)
        append16(0, &central)
        append16(0, &central)
        append16(0, &central)
        append32(0, &central)
        append32(0, &central)
        central.append(contentsOf: nameBytes)

        let directoryOffset = UInt32(output.count)
        output.append(central)
        append32(0x0605_4b50, &output)
        append16(0, &output)
        append16(0, &output)
        append16(1, &output)
        append16(1, &output)
        append32(UInt32(central.count), &output)
        append32(directoryOffset, &output)
        append16(0, &output)
        return output
    }
}

/// A `ArchivePasswordPrompting` driven by a script, shared by the resolver and
/// dispatcher tests.
final class ScriptedPasswordPrompt: ArchivePasswordPrompting {
    /// What the password book would offer, in order.
    var automatic: [String]
    /// One entry per `askForPassword` call; `nil` means "the user cancelled".
    var answers: [String?]
    private(set) var askedAfterFailedAttempt: [Bool] = []
    private(set) var askedAbout: [String] = []

    init(automatic: [String] = [], answers: [String?] = []) {
        self.automatic = automatic
        self.answers = answers
    }

    func automaticPasswords(forArchiveAt url: URL) -> [String] { automatic }

    func askForPassword(forArchiveAt url: URL, afterFailedAttempt: Bool) -> String? {
        askedAfterFailedAttempt.append(afterFailedAttempt)
        askedAbout.append(url.lastPathComponent)
        guard !answers.isEmpty else { return nil }
        return answers.removeFirst()
    }

    var askCount: Int { askedAfterFailedAttempt.count }
}

/// Unlocking an encrypted archive before it is extracted.
///
/// The password never crosses the IPC socket: the main app resolves it here (the
/// password book first, then the user) and hands the plaintext password to the
/// extractor. These tests cover that policy, and that the reader really opens what
/// our own writer encrypted.
final class ArchivePasswordResolverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-unlock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ data: Data, as name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func encryptedArchive(
        password: String = "hunter2",
        contents: String = "top secret\n",
        streaming: Bool = false
    ) throws -> URL {
        try write(
            EncryptedZipFixture.archive(contents: contents, password: password, streaming: streaming),
            as: "secret.zip"
        )
    }

    private func resolve(
        _ archive: URL,
        prompting: (any ArchivePasswordPrompting)? = nil
    ) throws -> ArchivePasswordResolver.Resolution {
        try ArchivePasswordResolver.resolve(archiveURL: archive, prompting: prompting)
    }

    // MARK: - Which password, from where

    func testAPlainArchiveNeedsNoPassword() throws {
        let archive = try write(RawZipBuilder.archive([("a.txt", "hi")]), as: "plain.zip")
        let prompt = ScriptedPasswordPrompt(automatic: ["irrelevant"])
        XCTAssertEqual(try resolve(archive, prompting: prompt), .notNeeded)
        XCTAssertEqual(prompt.askCount, 0, "a plain archive must not make the user type anything")
    }

    func testThePasswordBookIsTriedBeforeAnythingIsAsked() throws {
        let archive = try encryptedArchive()
        let prompt = ScriptedPasswordPrompt(automatic: ["wrong", "hunter2"])
        XCTAssertEqual(try resolve(archive, prompting: prompt), .resolved("hunter2"))
        XCTAssertEqual(prompt.askCount, 0)
    }

    func testAGuessedPasswordIsCheckedAgainstTheEntryItself() throws {
        let archive = try encryptedArchive()
        let prompt = ScriptedPasswordPrompt(automatic: ["wrong"], answers: ["hunter2"])
        XCTAssertEqual(try resolve(archive, prompting: prompt), .resolved("hunter2"))
        XCTAssertEqual(prompt.askCount, 1)
        XCTAssertEqual(prompt.askedAfterFailedAttempt, [false], "the first try is not a retry")
        XCTAssertEqual(prompt.askedAbout, ["secret.zip"], "the prompt names the archive")
    }

    func testTheSecondAttemptIsToldTheFirstOneWasWrong() throws {
        let archive = try encryptedArchive()
        let prompt = ScriptedPasswordPrompt(answers: ["nope", "hunter2"])
        XCTAssertEqual(try resolve(archive, prompting: prompt), .resolved("hunter2"))
        XCTAssertEqual(prompt.askedAfterFailedAttempt, [false, true])
    }

    func testThreeWrongAnswersAbandonTheExtraction() throws {
        let archive = try encryptedArchive()
        let prompt = ScriptedPasswordPrompt(answers: ["a", "b", "c", "d"])
        XCTAssertEqual(try resolve(archive, prompting: prompt), .abandoned)
        XCTAssertEqual(prompt.askCount, ArchivePasswordResolver.attempts)
        XCTAssertEqual(prompt.askCount, 3)
    }

    func testTheFirstCancelAbandonsImmediately() throws {
        let archive = try encryptedArchive()
        let prompt = ScriptedPasswordPrompt(answers: [nil])
        XCTAssertEqual(try resolve(archive, prompting: prompt), .abandoned)
        XCTAssertEqual(prompt.askCount, 1, "cancelling must not re-ask")
    }

    func testAnEmptyAnswerCountsAsGivingUp() throws {
        let archive = try encryptedArchive()
        let prompt = ScriptedPasswordPrompt(answers: ["   "])
        XCTAssertEqual(try resolve(archive, prompting: prompt), .abandoned)
    }

    func testEmptyBookEntriesAreSkippedRatherThanTried() throws {
        let archive = try encryptedArchive()
        let prompt = ScriptedPasswordPrompt(automatic: ["", "hunter2"])
        XCTAssertEqual(try resolve(archive, prompting: prompt), .resolved("hunter2"))
        XCTAssertEqual(prompt.askCount, 0)
    }

    func testWithoutAnythingToAskAnEncryptedArchiveSaysItNeedsAPassword() throws {
        let archive = try encryptedArchive()
        XCTAssertThrowsError(try resolve(archive)) { error in
            guard case .passwordRequired(let name) = error as? ArchiveError else {
                return XCTFail("expected passwordRequired, got \(error)")
            }
            XCTAssertEqual(name, "secret.zip")
        }
    }

    func testSomethingThatIsNotAnArchiveIsLeftToTheExtractorWithoutAPrompt() throws {
        // The resolver only answers "does this need a password". It no longer
        // insists on a ZIP here, so a file that is not an archive at all goes
        // straight through to the reader, which reports the real reason — and
        // nobody is asked for a password on the way.
        let file = try write(Data("not a zip at all".utf8), as: "notes.txt")
        let prompt = ScriptedPasswordPrompt(answers: ["hunter2"])
        XCTAssertEqual(try resolve(file, prompting: prompt), .notNeeded)
        XCTAssertEqual(prompt.askCount, 0)

        XCTAssertThrowsError(try ArchiveMemberSourceFactory.make(url: file, format: nil)) { error in
            guard case .unsupportedFormat = error as? ArchiveError else {
                return XCTFail("expected unsupportedFormat, got \(error)")
            }
        }
    }

    func testAStreamingWriterIsUnlockedWithoutTrustingItsCheckByte() throws {
        // Info-ZIP streams encrypted entries, so the header carries the DOS time
        // where PKWARE says the CRC check bytes go: a reader that trusted them
        // would reject the correct password.
        let archive = try encryptedArchive(streaming: true)
        let prompt = ScriptedPasswordPrompt(automatic: ["hunter2"])
        XCTAssertEqual(try resolve(archive, prompting: prompt), .resolved("hunter2"))
    }

    // MARK: - Extraction with the resolved password

    private func destination(_ name: String = "out") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testExtractionUnlocksAnEncryptedArchive() throws {
        let archive = try encryptedArchive(contents: "top secret\n")
        let out = try destination()
        let (results, summary) = try ArchiveExtractor.extract(
            archiveURL: archive,
            to: out,
            settings: ArchiveSettings(),
            password: "hunter2"
        )
        XCTAssertEqual(summary.failed, 0, "\(results.map(\.outcome))")
        XCTAssertEqual(summary.written, 1)
        XCTAssertEqual(
            try String(contentsOf: out.appendingPathComponent("secret.txt"), encoding: .utf8),
            "top secret\n"
        )
    }

    func testExtractionWithTheWrongPasswordWritesNothingAndSaysWhy() throws {
        let archive = try encryptedArchive(contents: "top secret\n")
        let out = try destination()
        let (results, summary) = try ArchiveExtractor.extract(
            archiveURL: archive,
            to: out,
            settings: ArchiveSettings(),
            password: "not-it"
        )
        XCTAssertEqual(summary.written, 0)
        XCTAssertEqual(summary.failed, 1)
        guard case .failed(let reason) = results[0].outcome else {
            return XCTFail("expected a failed entry, got \(results[0].outcome)")
        }
        XCTAssertTrue(reason.contains("secret.txt"), reason)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: out.appendingPathComponent("secret.txt").path),
            "a wrong password must not leave a file behind"
        )
    }

    func testExtractionWithoutAnyPasswordReportsTheProtection() throws {
        let archive = try encryptedArchive()
        let out = try destination()
        let (results, summary) = try ArchiveExtractor.extract(
            archiveURL: archive,
            to: out,
            settings: ArchiveSettings()
        )
        XCTAssertEqual(summary.written, 0)
        guard case .failed(let reason) = results[0].outcome else {
            return XCTFail("expected a failed entry, got \(results[0].outcome)")
        }
        XCTAssertTrue(reason.contains("password-protected"), reason)
    }

    func testAPlainArchiveStillExtractsWithNoPasswordAsked() throws {
        let archive = try write(RawZipBuilder.archive([("a.txt", "hi")]), as: "plain.zip")
        let out = try destination()
        let (_, summary) = try ArchiveExtractor.extract(
            archiveURL: archive,
            to: out,
            settings: ArchiveSettings()
        )
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.written, 1)
    }

    /// The user's report, end to end: what this app encrypts, it has to open again.
    func testWhatWeEncryptWeCanExtractAgain() throws {
        let source = root.appendingPathComponent("original.txt")
        try Data("round trip\n".utf8).write(to: source)
        let report = try ArchiveCompressor.compress(
            [source],
            into: root,
            preferredName: "round-trip.zip",
            format: .zip,
            conflictPolicy: .keepBoth,
            sizeLimitMB: 64,
            password: "hunter2"
        )

        // Without the password the archive is reported as protected...
        let prompt = ScriptedPasswordPrompt(automatic: ["hunter2"])
        XCTAssertEqual(
            try resolve(report.archiveURL, prompting: prompt),
            .resolved("hunter2"),
            "our own encrypted archive must be recognised as encrypted"
        )

        // ...and with it the contents come back byte for byte.
        let out = try destination()
        let (_, summary) = try ArchiveExtractor.extract(
            archiveURL: report.archiveURL,
            to: out,
            settings: ArchiveSettings(),
            password: "hunter2"
        )
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(
            try Data(contentsOf: out.appendingPathComponent("original.txt")),
            Data("round trip\n".utf8)
        )
    }

    /// The mirror image, with a tool that is not us: an archive `/usr/bin/zip -e`
    /// wrote. Info-ZIP streams its entries (general-purpose bit 3), so a reader that
    /// trusted the encryption header's check bytes instead of the plaintext would
    /// call the right password wrong here.
    func testAnArchiveInfoZipEncryptedIsUnlockedAndExtracted() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/zip"))

        try Data("third party secret\n".utf8).write(to: root.appendingPathComponent("inside.txt"))
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-e", "-P", "hunter2", "infozip.zip", "inside.txt"]
        zip.standardOutput = Pipe()
        zip.standardError = Pipe()
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0, "zip -e did not produce an archive")
        let archive = root.appendingPathComponent("infozip.zip")

        let prompt = ScriptedPasswordPrompt(automatic: ["hunter2"])
        XCTAssertEqual(try resolve(archive, prompting: prompt), .resolved("hunter2"))
        XCTAssertEqual(prompt.askCount, 0, "the book had it, so nobody should be asked")

        let out = try destination()
        let (_, summary) = try ArchiveExtractor.extract(
            archiveURL: archive,
            to: out,
            settings: ArchiveSettings(),
            password: "hunter2"
        )
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(
            try Data(contentsOf: out.appendingPathComponent("inside.txt")),
            Data("third party secret\n".utf8)
        )
    }
}
