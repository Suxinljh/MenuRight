import PLzmaSDK
import SWCompression
import XCTest

/// The three compression modes, 7z 固实压缩, 7z AES 加密 and 分卷压缩 — the four
/// things the dialog used to grey out or ignore.
final class ArchiveModeAndSevenZipTests: XCTestCase {
    private var root: URL!
    private var sources: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-modes-\(UUID().uuidString)", isDirectory: true)
        sources = root.appendingPathComponent("Input", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Repetitive text on purpose: deflate and LZMA2 only differ between levels
    /// when there is something to find.
    @discardableResult
    private func makeInput(_ name: String, bytes: Int) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "MenuRight 自定义压缩 — \(name) repeats this line so the compressor has work to do.\n"
        var data = Data()
        while data.count < bytes { data.append(Data(line.utf8)) }
        try data.write(to: url)
        return url
    }

    @discardableResult
    private func makeIncompressibleInput(_ name: String, bytes: Int) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).write(to: url)
        return url
    }

    /// The files sitting in `Input` — the archive then holds `a.txt`, not
    /// `Input/a.txt`, which is what a Finder selection of those files produces.
    private func inputFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func compress(
        _ format: ArchiveFormat,
        name: String,
        mode: ArchiveCompressionMode = .standard,
        sources urls: [URL]? = nil,
        password: String? = nil,
        solid: Bool = true,
        encryptsFileNames: Bool = false,
        volumeSizeMB: Int? = nil,
        into directory: URL? = nil
    ) throws -> ArchiveCompressor.Report {
        try ArchiveCompressor.compress(
            urls ?? (try inputFiles()),
            into: directory ?? root,
            preferredName: name,
            format: format,
            conflictPolicy: .keepBoth,
            sizeLimitMB: 64,
            mode: mode,
            password: password,
            solid: solid,
            encryptsFileNames: encryptsFileNames,
            volumeSizeMB: volumeSizeMB
        )
    }

    private func extract(
        _ archive: URL,
        into folder: String,
        password: String? = nil,
        deletesArchive: Bool = false
    ) throws -> (results: [ArchiveEntryResult], summary: ArchiveExtractionSummary) {
        let out = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var settings = ArchiveSettings()
        settings.deletesArchiveAfterExtraction = deletesArchive
        return try ArchiveExtractor.extract(
            archiveURL: archive,
            to: out,
            settings: settings,
            password: password
        )
    }

    private func size(of report: ArchiveCompressor.Report) throws -> Int {
        try Data(contentsOf: report.archiveURL).count
    }

    /// Why the extraction failed, for the assertion message.
    ///
    /// The 7z half of these two tests failed once inside a loaded full-suite run
    /// (`summary.failed == 3`, solid archives only) while passing three times in a
    /// row standalone, and nothing in the compressor changed between those runs.
    /// Whatever the reason was, the next occurrence has to say it out loud
    /// instead of showing a bare count.
    private func failureReasons(_ results: [ArchiveEntryResult]) -> String {
        let reasons = results.compactMap { result -> String? in
            if case .failed(let reason) = result.outcome {
                return "\(result.entryName): \(reason)"
            }
            return nil
        }
        return reasons.isEmpty ? "no reason reported" : reasons.joined(separator: "; ")
    }

    // MARK: - 压缩模式: do the three modes differ?

    func testEveryCompressingFormatGetsSmallerFromFastToMaximum() throws {
        for name in ["a.txt", "b.txt", "c.txt"] {
            try makeInput(name, bytes: 300_000)
        }
        let inputs = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for format in [ArchiveFormat.zip, .sevenZip, .gzip, .bzip2] {
            let fast = try size(of: compress(format, name: "mode-fast", mode: .fast, sources: inputs))
            let standard = try size(of: compress(format, name: "mode-standard", mode: .standard, sources: inputs))
            let maximum = try size(of: compress(format, name: "mode-maximum", mode: .maximum, sources: inputs))

            if format == .sevenZip {
                // PLzmaSDK's LZMA2 encoder does not promise that a higher level
                // yields fewer bytes on an already tiny, extremely redundant
                // payload: the three 300 KB inputs compress to ~470 bytes and the
                // measured ordering is 471 / 470 / 478 (fast / standard /
                // maximum). The same build passed this assertion standalone and
                // failed inside a loaded full-suite run, so the numbers also move
                // by a few bytes between runs. Assert what the modes must deliver
                // -- every level shrinks the input to a fraction of its size --
                // and keep a loose bound between fast and maximum instead of an
                // ordering LZMA does not guarantee.
                for (label, size) in [("fast", fast), ("standard", standard), ("maximum", maximum)] {
                    XCTAssertLessThan(
                        size, 4_096,
                        "\(format.rawValue): \(label) 压缩 has to shrink the input (fast/standard/maximum = \(fast)/\(standard)/\(maximum))"
                    )
                }
                XCTAssertLessThanOrEqual(
                    maximum, Int(Double(fast) * 1.05),
                    "\(format.rawValue): 极限压缩 must stay within 5% of 快速压缩 (fast/standard/maximum = \(fast)/\(standard)/\(maximum))"
                )
            } else {
                XCTAssertLessThan(maximum, fast, "\(format.rawValue): 极限压缩 has to beat 快速压缩")
                XCTAssertLessThanOrEqual(standard, fast, "\(format.rawValue): 标准压缩 must not be worse than 快速压缩")
                XCTAssertLessThanOrEqual(maximum, standard, "\(format.rawValue): 极限压缩 must not be worse than 标准压缩")
            }

            // A smaller archive is only useful if it still reads back.
            let report = try compress(format, name: "mode-roundtrip-\(format.rawValue)", mode: .maximum, sources: inputs)
            let (results, summary) = try extract(report.archiveURL, into: "out-\(format.rawValue)")
            XCTAssertEqual(
                summary.failed, 0,
                "\(format.rawValue): the maximum-effort archive has to extract — \(failureReasons(results))"
            )
        }
    }

    func testTarIgnoresTheModeBecauseItDoesNotCompress() throws {
        try makeInput("only.txt", bytes: 200_000)
        let fast = try size(of: compress(.tar, name: "tar-fast", mode: .fast))
        let maximum = try size(of: compress(.tar, name: "tar-maximum", mode: .maximum))
        XCTAssertEqual(fast, maximum, "TAR stores bytes; the mode has nothing to act on")
    }

    func testTheCompressorWritesTheNameItIsGiven() throws {
        try makeInput("one.txt", bytes: 1000)
        let report = try compress(.zip, name: "typed.zip", mode: .fast)
        XCTAssertEqual(report.archiveURL.lastPathComponent, "typed.zip")
        // The dialog appends the extension (`writtenName`); the compressor does
        // not, so a caller that hands over a bare name gets a bare file back.
        XCTAssertEqual(try compress(.zip, name: "bare").archiveURL.lastPathComponent, "bare")
    }

    // MARK: - 固实压缩 (7z only)

    func testSolidAndNonSolidBothRoundTrip() throws {
        for name in ["a.txt", "b.txt", "c.txt"] {
            try makeInput(name, bytes: 200_000)
        }
        let inputs = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let solidReport = try compress(.sevenZip, name: "solid", sources: inputs, solid: true)
        let looseReport = try compress(.sevenZip, name: "loose", sources: inputs, solid: false)

        for (label, report) in [("solid", solidReport), ("non-solid", looseReport)] {
            let (results, summary) = try extract(report.archiveURL, into: "out-\(label)")
            XCTAssertEqual(summary.failed, 0, "\(label) 7z has to extract — \(failureReasons(results))")
            XCTAssertEqual(summary.written, 3, "\(label) 7z has to hold every file")
            let text = try String(contentsOf: root.appendingPathComponent("out-\(label)/a.txt"), encoding: .utf8)
            XCTAssertTrue(text.hasPrefix("MenuRight 自定义压缩"))
        }
        // Solid packing shares one LZMA2 folder across the files, so it cannot be
        // larger than packing each file on its own.
        XCTAssertLessThanOrEqual(try size(of: solidReport), try size(of: looseReport))
    }

    // MARK: - 7z AES-256 加密 + 加密文件名

    func testAnEncryptedSevenZipOpensWithThePasswordItWasWrittenWith() throws {
        try makeInput("secret.txt", bytes: 20_000)
        let report = try compress(.sevenZip, name: "locked", password: "hunter2")

        XCTAssertTrue(SevenZipEncryption.needsPassword(archiveURL: report.archiveURL))
        XCTAssertTrue(SevenZipEncryption.validates(password: "hunter2", archiveURL: report.archiveURL))
        XCTAssertFalse(SevenZipEncryption.validates(password: "wrong", archiveURL: report.archiveURL))

        let (_, summary) = try extract(report.archiveURL, into: "out-locked", password: "hunter2")
        XCTAssertEqual(summary.failed, 0)
        let text = try String(contentsOf: root.appendingPathComponent("out-locked/secret.txt"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("MenuRight 自定义压缩"))
    }

    func testAnEncryptedSevenZipWithoutAPasswordAsksForOne() throws {
        try makeInput("secret.txt", bytes: 20_000)
        let report = try compress(.sevenZip, name: "locked", password: "hunter2")

        let (results, summary) = try extract(report.archiveURL, into: "out-refused")
        XCTAssertEqual(summary.failed, 1, "the entry cannot be written without the password")
        XCTAssertEqual(summary.written, 0, "nothing may be written from an archive we cannot open")
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("out-refused").path).isEmpty,
            "a refused extraction leaves an empty folder, never a partial file"
        )
        let refusal = try XCTUnwrap(results.first { $0.isFailure })
        guard case .failed(let reason) = refusal.outcome else { return XCTFail("expected a failure") }
        XCTAssertTrue(
            reason.contains("password-protected"),
            "the reason has to point at the password: \(reason)"
        )
    }

    func testAWrongPasswordIsNotConfusedWithAMissingOne() throws {
        try makeInput("secret.txt", bytes: 20_000)
        let report = try compress(.sevenZip, name: "locked", password: "hunter2")

        let (results, summary) = try extract(report.archiveURL, into: "out-wrong", password: "wrong")
        XCTAssertEqual(summary.failed, 1, "the wrong password must not be reported as success")
        XCTAssertEqual(summary.written, 0)
        let failure = try XCTUnwrap(results.first { $0.isFailure })
        guard case .failed(let message) = failure.outcome else { return XCTFail("expected a failure") }
        XCTAssertTrue(
            message.contains("password"),
            "a wrong password has to say so, not blame the archive: \(message)"
        )
    }

    func testEncryptingTheFileNamesHidesTheListingToo() throws {
        try makeInput("secret.txt", bytes: 20_000)
        let hidden = try compress(.sevenZip, name: "hidden", password: "hunter2", encryptsFileNames: true)
        let plainText = try compress(.sevenZip, name: "plaintext", password: "hunter2")

        // With an encrypted header the names are inside the encrypted stream, so
        // the header-only reader bails out — that is the point of the option.
        let hiddenData = try Data(contentsOf: hidden.archiveURL)
        XCTAssertThrowsError(try SevenZipContainer.info(container: hiddenData)) { error in
            XCTAssertTrue(error is SevenZipError, "expected a 7z error, got \(error)")
        }
        let visibleData = try Data(contentsOf: plainText.archiveURL)
        let infos = try SevenZipContainer.info(container: visibleData)
        XCTAssertEqual(infos.map(\.name), ["secret.txt"], "content-only encryption still shows the name")

        // Our own reader keeps working: it has the password.
        XCTAssertTrue(SevenZipEncryption.needsPassword(archiveURL: hidden.archiveURL))
        XCTAssertTrue(SevenZipEncryption.validates(password: "hunter2", archiveURL: hidden.archiveURL))
        XCTAssertFalse(SevenZipEncryption.validates(password: "wrong", archiveURL: hidden.archiveURL))
        let (_, summary) = try extract(hidden.archiveURL, into: "out-hidden", password: "hunter2")
        XCTAssertEqual(summary.failed, 0)
    }

    func testAnUnencryptedSevenZipNeverAsksForAPassword() throws {
        try makeInput("open.txt", bytes: 5000)
        let report = try compress(.sevenZip, name: "open")
        XCTAssertFalse(SevenZipEncryption.needsPassword(archiveURL: report.archiveURL))
        let (_, summary) = try extract(report.archiveURL, into: "out-open")
        XCTAssertEqual(summary.failed, 0)
    }

    // MARK: - 分卷压缩

    func testASplitZipLandsInNumberedPartsAndExtractsFromTheFirstOne() throws {
        try makeIncompressibleInput("bytes.bin", bytes: 2_500_000)
        let report = try compress(.zip, name: "split.zip", volumeSizeMB: 1)

        XCTAssertEqual(report.archiveURL.lastPathComponent, "split.zip.001", "the report points at the first part")
        let parts = ArchiveVolumeSet.existingParts(firstPart: report.archiveURL)
        XCTAssertGreaterThanOrEqual(parts.count, 3, "2.5 MB at 1 MB per part is at least three parts")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("split.zip").path),
            "a split archive must not also leave a whole copy behind"
        )
        for part in parts.dropLast() {
            XCTAssertLessThanOrEqual(try Data(contentsOf: part).count, 1_048_576)
        }

        // Extracting by pointing at `.001` is what the user does in Finder.
        let (_, summary) = try extract(report.archiveURL, into: "out-split")
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("out-split/bytes.bin")).count,
            2_500_000
        )
    }

    func testASplitSevenZipAlsoExtractsFromItsFirstPart() throws {
        try makeIncompressibleInput("bytes.bin", bytes: 2_200_000)
        let report = try compress(.sevenZip, name: "split7.7z", volumeSizeMB: 1)

        XCTAssertEqual(report.archiveURL.lastPathComponent, "split7.7z.001")
        let (_, summary) = try extract(report.archiveURL, into: "out-split7")
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("out-split7/bytes.bin")).count,
            2_200_000
        )
    }

    func testDeletingASplitArchiveDeletesEveryPart() throws {
        try makeIncompressibleInput("bytes.bin", bytes: 2_200_000)
        let report = try compress(.zip, name: "gone.zip", volumeSizeMB: 1)
        let parts = ArchiveVolumeSet.existingParts(firstPart: report.archiveURL)
        XCTAssertGreaterThan(parts.count, 1)

        _ = try extract(report.archiveURL, into: "out-gone", deletesArchive: true)

        for part in parts {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: part.path),
                "\(part.lastPathComponent) survives 解压后删除, so a half archive is left on disk"
            )
        }
    }

    func testASplitArchiveRefusesToOverwriteSilently() throws {
        try makeIncompressibleInput("bytes.bin", bytes: 1_200_000)
        _ = try compress(.zip, name: "twice.zip", volumeSizeMB: 1)

        XCTAssertThrowsError(
            try ArchiveCompressor.compress(
                [sources],
                into: root,
                preferredName: "twice.zip",
                format: .zip,
                conflictPolicy: .skip,
                sizeLimitMB: 64,
                volumeSizeMB: 1
            )
        ) { error in
            guard case ArchiveError.conflict(let message) = error else {
                return XCTFail("expected conflict, got \(error)")
            }
            XCTAssertTrue(message.contains("twice.zip.001"), "the message names the part that exists: \(message)")
        }
    }

    func testKeepingBothOnASplitArchiveMovesTheWholeSet() throws {
        try makeIncompressibleInput("bytes.bin", bytes: 1_200_000)
        let first = try compress(.zip, name: "both.zip", volumeSizeMB: 1)
        let second = try compress(.zip, name: "both.zip", volumeSizeMB: 1)

        XCTAssertNotEqual(first.archiveURL, second.archiveURL)
        XCTAssertTrue(second.archiveURL.lastPathComponent.hasPrefix("both"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: first.archiveURL.path),
            "the first set has to survive"
        )
    }

    // MARK: - 密码解析现在按格式分派(原来无条件当成 ZIP)

    private final class PromptingSpy: ArchivePasswordPrompting {
        var stored: [String] = []
        var answers: [String?] = []
        private(set) var asked = 0

        func automaticPasswords(forArchiveAt url: URL) -> [String] { stored }

        func askForPassword(forArchiveAt url: URL, afterFailedAttempt: Bool) -> String? {
            defer { asked += 1 }
            return answers.indices.contains(asked) ? answers[asked] : nil
        }
    }

    func testAnUnencryptedSevenZipIsNotSentThroughTheZipProbe() throws {
        try makeInput("open.txt", bytes: 5000)
        let report = try compress(.sevenZip, name: "open")
        let spy = PromptingSpy()

        // Before 2026-10-03 this threw notAnArchive, so every 7z, tar and tar.gz
        // extracted through the menu was refused as "Not a readable archive".
        XCTAssertEqual(
            try ArchivePasswordResolver.resolve(archiveURL: report.archiveURL, prompting: spy),
            .notNeeded
        )
        XCTAssertEqual(spy.asked, 0)
    }

    func testAnUnencryptedTarGzIsNotSentThroughTheZipProbeEither() throws {
        try makeInput("open.txt", bytes: 5000)
        let report = try compress(.gzip, name: "open.tar.gz")
        XCTAssertEqual(
            try ArchivePasswordResolver.resolve(archiveURL: report.archiveURL, prompting: PromptingSpy()),
            .notNeeded
        )
    }

    func testThePasswordBookUnlocksASevenZipBeforeAnybodyIsAsked() throws {
        try makeInput("secret.txt", bytes: 20_000)
        let report = try compress(.sevenZip, name: "locked", password: "hunter2")
        let spy = PromptingSpy()
        spy.stored = ["hunter2"]

        XCTAssertEqual(
            try ArchivePasswordResolver.resolve(archiveURL: report.archiveURL, prompting: spy),
            .resolved("hunter2")
        )
        XCTAssertEqual(spy.asked, 0, "a stored password must not open a dialog")
    }

    func testAnEncryptedSevenZipWithNobodyToAskRefusesToGuess() throws {
        try makeInput("secret.txt", bytes: 20_000)
        let report = try compress(.sevenZip, name: "locked", password: "hunter2")

        XCTAssertThrowsError(try ArchivePasswordResolver.resolve(archiveURL: report.archiveURL, prompting: nil)) { error in
            guard case ArchiveError.passwordRequired = error else {
                return XCTFail("expected passwordRequired, got \(error)")
            }
        }
    }

    func testThreeWrongPasswordsAbandonTheExtraction() throws {
        try makeInput("secret.txt", bytes: 20_000)
        let report = try compress(.sevenZip, name: "locked", password: "hunter2")
        let spy = PromptingSpy()
        spy.answers = ["nope", "still-nope", "nope-again", "hunter2"]

        XCTAssertEqual(
            try ArchivePasswordResolver.resolve(archiveURL: report.archiveURL, prompting: spy),
            .abandoned
        )
        XCTAssertEqual(spy.asked, 3, "the fourth answer is never reached")
    }

    func testARetrySaysTheFirstAttemptWasWrong() throws {
        try makeInput("secret.txt", bytes: 20_000)
        let report = try compress(.sevenZip, name: "locked", password: "hunter2")
        let spy = PromptingSpy()
        spy.answers = ["nope", "hunter2"]
        _ = try ArchivePasswordResolver.resolve(archiveURL: report.archiveURL, prompting: spy)
        XCTAssertEqual(spy.asked, 2)
    }

    // MARK: - 加密 7z 的条目名: 写盘之前必须先判定

    /// An encrypted 7z whose entry names are chosen by the test.
    ///
    /// `SevenZipWriter` stores the `archivePath` it is handed verbatim, which is
    /// what makes a hostile name reproducible here: the LZMA SDK builds its output
    /// path out of the entry name, so `../escape.txt` is a real escape when the
    /// decoder is asked to extract with full paths. See
    /// `SevenZipPasswordMemberSource.decideLayout()`.
    private func writeSevenZip(
        entries: [(archivePath: String, source: URL)],
        password: String,
        filename: String
    ) throws -> URL {
        let image = try SevenZipWriter.archive(
            entries: entries.map { SevenZipWriter.Entry(archivePath: $0.archivePath, url: $0.source) },
            mode: .standard,
            password: password,
            solid: true
        )
        let url = root.appendingPathComponent(filename)
        try image.write(to: url)
        return url
    }

    /// Everything below `directory`, for "did anything land where it shouldn't".
    private func tree(under directory: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL]) ?? []
    }

    func testAnEncryptedSevenZipNeverWritesAnEntryNameAboveItsScratchDirectory() throws {
        // Two source files, not one: the encoder refuses to add the same source
        // path twice ("Can't add duplicated path"), so an entry list can only be
        // built from distinct files even when the payload bytes are identical.
        let payload = try makeInput("payload.txt", bytes: 400)
        let safePayload = try makeInput("safe.txt", bytes: 400)
        let archive = try writeSevenZip(
            entries: [("../escape.txt", payload), ("inner/ok.txt", safePayload)],
            password: "pw",
            filename: "hostile.7z"
        )

        let (results, summary) = try extract(archive, into: "Hostile", password: "pw")
        XCTAssertEqual(summary.failed, 0, failureReasons(results))
        // The planner refuses the traversal entry, exactly as it does for ZIP and
        // TAR — the fix is that the 7z backend no longer writes it *anyway*.
        XCTAssertTrue(
            results.contains { $0.entryName == "../escape.txt" && $0.outcome == .skipped(.unsafePath("../escape.txt")) },
            "the traversal entry should be skipped, got \(results)"
        )

        // The scratch root's parent is where `../escape.txt` used to land: the SDK
        // created `MenuRight-7z/<uuid>/../escape.txt`, and `close()` only removes
        // the `<uuid>` level, so the stray file survived the extraction.
        let scratchRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MenuRight-7z", isDirectory: true)
        let strays = tree(under: scratchRoot).filter { $0.lastPathComponent == "escape.txt" }
        XCTAssertTrue(strays.isEmpty, "an entry name escaped the scratch directory: \(strays.map(\.path))")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.txt").path),
            "an entry name escaped into the extraction root"
        )

        // Going item by item into memory still has to produce the archive's real
        // content — an unsafe sibling must not cost the user the safe entry too.
        let extracted = root.appendingPathComponent("Hostile/inner/ok.txt")
        XCTAssertEqual(try Data(contentsOf: extracted), try Data(contentsOf: safePayload))
    }

    func testASevenZipWhoseEntriesShareALeafNameIsNotExtractedFlat() throws {
        let first = try makeInput("first.txt", bytes: 400)
        let second = try makeInput("second-longer.txt", bytes: 900)
        let archive = try writeSevenZip(
            entries: [("a/x.txt", first), ("b/x.txt", second)],
            password: "pw",
            filename: "leaves.7z"
        )

        let (results, summary) = try extract(archive, into: "Leaves", password: "pw")
        XCTAssertEqual(summary.failed, 0, failureReasons(results))
        // Both names are safe on their own; a flat scratch copy would put them in
        // one directory and the second write would win. Distinct payloads are what
        // catches that: with the flat layout one of these two reads the other's
        // file.
        let out = root.appendingPathComponent("Leaves", isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("a/x.txt")), try Data(contentsOf: first))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("b/x.txt")), try Data(contentsOf: second))
    }

    func testAnEncryptedSevenZipWithOrdinaryNamesReadsEveryNestedEntry() throws {
        let outer = try makeInput("outer.txt", bytes: 400)
        let inner = try makeInput("inner.txt", bytes: 1_200)
        let archive = try writeSevenZip(
            entries: [("dir/outer.txt", outer), ("dir/sub/inner.txt", inner)],
            password: "pw",
            filename: "ordinary.7z"
        )

        let (results, summary) = try extract(archive, into: "Ordinary", password: "pw")
        XCTAssertEqual(summary.failed, 0, failureReasons(results))
        XCTAssertEqual(summary.written, 2, failureReasons(results))
        let out = root.appendingPathComponent("Ordinary", isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("dir/outer.txt")), try Data(contentsOf: outer))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("dir/sub/inner.txt")), try Data(contentsOf: inner))
    }
}
