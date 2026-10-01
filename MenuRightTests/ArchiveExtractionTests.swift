import XCTest

/// A test-only ZIP builder that accepts entry names `ZipWriter` refuses.
///
/// The zip-slip rules have to be tested against **real archives**: a planner fed
/// hand-made `ZipEntryRecord` values would not prove that the reader, the
/// central-directory walk and the extractor agree on what a malicious archive
/// looks like.
enum RawZipBuilder {
    static func archive(_ entries: [(name: String, contents: String)]) -> Data {
        build(entries.map { (name: $0.name, contents: Data($0.contents.utf8), externalAttributes: 0) })
    }

    /// Entry marked as a symbolic link (`S_IFLNK`) with `target` as its payload.
    static func symlinkArchive(name: String, target: String) -> Data {
        build([(name: name, contents: Data(target.utf8), externalAttributes: 0xA1FF_0000)])
    }

    /// Full control over the raw name bytes and the general-purpose flags.
    ///
    /// The encoding tests need archives whose names are *not* UTF-8, and those
    /// cannot be spelled as a Swift `String` — the whole point is the byte
    /// sequence, not the text.
    static func buildRaw(
        _ entries: [(nameBytes: [UInt8], contents: Data, externalAttributes: UInt32, flags: UInt16)]
    ) -> Data {
        func append16(_ value: UInt16, _ data: inout Data) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func append32(_ value: UInt32, _ data: inout Data) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        var output = Data()
        var central = Data()
        for entry in entries {
            let nameBytes = entry.nameBytes
            let payload = entry.contents
            let crc = ZipWriter.crc32(payload)
            let offset = UInt32(output.count)

            append32(0x0403_4b50, &output)
            append16(20, &output)
            append16(entry.flags, &output)
            append16(0, &output)            // STORED
            append16(0, &output)            // time
            append16(0x0021, &output)       // date
            append32(crc, &output)
            append32(UInt32(payload.count), &output)
            append32(UInt32(payload.count), &output)
            append16(UInt16(nameBytes.count), &output)
            append16(0, &output)
            output.append(contentsOf: nameBytes)
            output.append(payload)

            append32(0x0201_4b50, &central)
            append16(20, &central)
            append16(20, &central)
            append16(entry.flags, &central)
            append16(0, &central)
            append16(0, &central)
            append16(0x0021, &central)
            append32(crc, &central)
            append32(UInt32(payload.count), &central)
            append32(UInt32(payload.count), &central)
            append16(UInt16(nameBytes.count), &central)
            append16(0, &central)
            append16(0, &central)
            append16(0, &central)
            append16(0, &central)
            append32(entry.externalAttributes, &central)
            append32(offset, &central)
            central.append(contentsOf: nameBytes)
        }

        let directoryOffset = UInt32(output.count)
        output.append(central)
        append32(0x0605_4b50, &output)
        append16(0, &output)
        append16(0, &output)
        append16(UInt16(entries.count), &output)
        append16(UInt16(entries.count), &output)
        append32(UInt32(central.count), &output)
        append32(directoryOffset, &output)
        append16(0, &output)
        return output
    }

    /// The common case: a UTF-8 name, no flags set — what our own `ZipWriter`
    /// produces for ASCII names, and what most fixtures need.
    static func build(_ entries: [(name: String, contents: Data, externalAttributes: UInt32)]) -> Data {
        buildRaw(entries.map {
            (
                nameBytes: Array($0.name.utf8),
                contents: $0.contents,
                externalAttributes: $0.externalAttributes,
                flags: 0
            )
        })
    }
}

/// P9 stage 1: the ZIP reader, the extraction planner (the security rules) and
/// the extractor's behaviour on disk.
final class ArchiveExtractionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func policy(
        conflict: ArchiveConflictPolicy = .keepBoth,
        skipsMetadata: Bool = true,
        limitMB: Int = ArchiveSettings.defaultSizeLimitMB,
        deletesArchive: Bool = false
    ) -> ArchiveSettings {
        ArchiveSettings(
            conflictPolicy: conflict,
            deletesArchiveAfterExtraction: deletesArchive,
            skipsMetadataEntries: skipsMetadata,
            sizeLimitMB: limitMB
        )
    }

    private func write(_ data: Data, as name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func destination(_ name: String = "out") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Name rules (pure)

    func testSafeRelativePathAcceptsOrdinaryNames() {
        for name in ["a.txt", "folder/a.txt", "./folder/a.txt", "folder//a.txt", "folder/", "a b/c d.txt"] {
            XCTAssertNoThrow(try ArchiveExtractionPlanner.safeRelativePath(name).get(), "\(name) should be safe")
        }
        XCTAssertEqual(try? ArchiveExtractionPlanner.safeRelativePath("./folder/a.txt").get(), "folder/a.txt")
        XCTAssertEqual(try? ArchiveExtractionPlanner.safeRelativePath("folder/").get(), "folder/")
    }

    func testSafeRelativePathRejectsEveryTraversalShape() {
        let unsafe = [
            "../escape.txt",
            "a/../../escape.txt",
            "a/../b.txt",          // even when it stays inside
            "/etc/passwd",
            "C:/Windows/system32",
            "a\\..\\b.txt",
            "..",
            "",
            "folder/..",
        ]
        for name in unsafe {
            switch ArchiveExtractionPlanner.safeRelativePath(name) {
            case .success(let value):
                XCTFail("“\(name)” must not be accepted (got “\(value)”)")
            case .failure(let reason):
                guard case .unsafePath = reason else {
                    return XCTFail("expected unsafePath for “\(name)”, got \(reason)")
                }
            }
        }
    }

    func testMetadataDetection() {
        for name in ["__MACOSX/._a.txt", "__MACOSX/x", "folder/.DS_Store", ".DS_Store", "sub/._resource", "Thumbs.db"] {
            XCTAssertTrue(ArchiveExtractionPlanner.isMetadata(name), "\(name) should count as metadata")
        }
        for name in ["a.txt", "folder/a.txt", "notes.md"] {
            XCTAssertFalse(ArchiveExtractionPlanner.isMetadata(name), "\(name) should not count as metadata")
        }
    }

    // MARK: - Planning

    private func record(_ name: String, size: Int = 4, method: UInt16 = 0, symlink: Bool = false) -> ArchiveMember {
        ArchiveMember(
            index: abs(name.hashValue % 10_000),
            name: name,
            isDirectory: name.hasSuffix("/"),
            isSymbolicLink: symlink,
            uncompressedSize: Int64(size),
            isDecompressible: method == 0 || method == 8
        )
    }

    func testPlanSkipsTraversalSymlinkAndMetadata() throws {
        let steps = try ArchiveExtractionPlanner.plan(
            members: [
                record("ok.txt"),
                record("../escape.txt"),
                record("link", symlink: true),
                record("__MACOSX/._ok.txt"),
                record("folder/"),
            ],
            conflictPolicy: .keepBoth,
            skipsMetadataEntries: true,
            maximumUncompressedBytes: 1024
        )

        XCTAssertEqual(steps.count, 5)
        XCTAssertEqual(steps[0], .file(member: record("ok.txt"), relativePath: "ok.txt"))
        guard case .skipped(_, _, let traversal) = steps[1] else { return XCTFail("traversal must be skipped") }
        XCTAssertEqual(traversal, .unsafePath("../escape.txt"))
        guard case .skipped(_, _, let link) = steps[2] else { return XCTFail("symlink must be skipped") }
        XCTAssertEqual(link, .symbolicLink)
        guard case .skipped(_, _, let metadata) = steps[3] else { return XCTFail("metadata must be skipped") }
        XCTAssertEqual(metadata, .metadata)
        XCTAssertEqual(steps[4], .directory(relativePath: "folder/"))
    }

    func testPlanKeepsMetadataWhenTheSettingIsOff() throws {
        let steps = try ArchiveExtractionPlanner.plan(
            members: [record("__MACOSX/._ok.txt")],
            conflictPolicy: .keepBoth,
            skipsMetadataEntries: false,
            maximumUncompressedBytes: 1024
        )
        XCTAssertEqual(steps, [.file(member: record("__MACOSX/._ok.txt"), relativePath: "__MACOSX/._ok.txt")])
    }

    /// The zip-bomb guard: the declared payload is checked before any write.
    func testPlanRefusesAnArchiveWhoseDeclaredPayloadExceedsTheLimit() {
        XCTAssertThrowsError(try ArchiveExtractionPlanner.plan(
            members: [record("big.bin", size: 4096), record("big2.bin", size: 4096)],
            conflictPolicy: .keepBoth,
            skipsMetadataEntries: true,
            maximumUncompressedBytes: 4096
        )) { error in
            guard case ArchiveError.tooLarge = error else { return XCTFail("expected tooLarge, got \(error)") }
        }
    }

    func testPlanRefusesAnEntryWithAnUnsupportedCompressionMethod() {
        XCTAssertThrowsError(try ArchiveExtractionPlanner.plan(
            members: [record("a.txt", method: 12)],
            conflictPolicy: .keepBoth,
            skipsMetadataEntries: true,
            maximumUncompressedBytes: 1024
        )) { error in
            guard case ArchiveError.unsupportedFormat = error else { return XCTFail("expected unsupportedFormat, got \(error)") }
        }
    }

    func testDuplicateEntriesFollowTheConflictPolicy() throws {
        let entries = [record("same.txt"), record("same.txt")]

        let keepBoth = try ArchiveExtractionPlanner.plan(
            members: entries, conflictPolicy: .keepBoth, skipsMetadataEntries: true, maximumUncompressedBytes: 1024
        )
        XCTAssertEqual(keepBoth.filter { if case .file = $0 { return true } else { return false } }.count, 2)

        let skip = try ArchiveExtractionPlanner.plan(
            members: entries, conflictPolicy: .skip, skipsMetadataEntries: true, maximumUncompressedBytes: 1024
        )
        XCTAssertEqual(skip.count, 2)
        guard case .skipped(_, _, let reason) = skip[1] else { return XCTFail("the second entry must be skipped") }
        XCTAssertEqual(reason, .conflict)

        let overwrite = try ArchiveExtractionPlanner.plan(
            members: entries, conflictPolicy: .overwrite, skipsMetadataEntries: true, maximumUncompressedBytes: 1024
        )
        XCTAssertEqual(overwrite.count, 2)
    }

    // MARK: - Extraction on disk

    func testExtractsNestedEntriesAndEmptyFolders() throws {
        let archive = try write(RawZipBuilder.build([
            (name: "folder/", contents: Data(), externalAttributes: 0x41ED_0000),
            (name: "folder/a.txt", contents: Data("hello".utf8), externalAttributes: 0),
            (name: "folder/sub/b.txt", contents: Data("world".utf8), externalAttributes: 0),
        ]), as: "sample.zip")
        let out = try destination()

        let (results, summary) = try ArchiveExtractor.extract(archiveURL: archive, to: out, settings: policy())

        XCTAssertEqual(summary, ArchiveExtractionSummary(written: 3, skipped: 0, failed: 0))
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("folder/a.txt"), encoding: .utf8), "hello")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("folder/sub/b.txt"), encoding: .utf8), "world")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("folder").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// The headline security test: a `../` entry must not appear outside the
    /// destination, and the archive must not be half-extracted either.
    func testZipSlipEntryNeverEscapesTheDestination() throws {
        let archive = try write(RawZipBuilder.archive([
            ("good.txt", "safe"),
            ("../escaped.txt", "pwned"),
            ("nested/../../escaped2.txt", "pwned"),
        ]), as: "evil.zip")
        let out = try destination()

        let (results, summary) = try ArchiveExtractor.extract(archiveURL: archive, to: out, settings: policy())

        XCTAssertEqual(summary.written, 1)
        XCTAssertEqual(summary.skipped, 2)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("good.txt"), encoding: .utf8), "safe")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped2.txt").path))
        for result in results where result.isSkip {
            guard case .skipped(.unsafePath) = result.outcome else {
                return XCTFail("expected an unsafePath skip, got \(result.outcome)")
            }
        }
    }

    func testSymlinkEntryIsNotCreated() throws {
        let archive = try write(RawZipBuilder.symlinkArchive(name: "link", target: "/etc/passwd"), as: "link.zip")
        let out = try destination()

        let (results, summary) = try ArchiveExtractor.extract(archiveURL: archive, to: out, settings: policy())

        XCTAssertEqual(summary, ArchiveExtractionSummary(written: 0, skipped: 1, failed: 0))
        XCTAssertEqual(results.first?.outcome, .skipped(.symbolicLink))
        let attributes = try? FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("link").path)
        XCTAssertNil(attributes, "a symlink entry must not produce anything")
    }

    func testCorruptEntryIsReportedAndDoesNotStopTheOthers() throws {
        var data = RawZipBuilder.archive([("a.txt", "hello"), ("b.txt", "world")])
        // Flip a byte inside the first entry's payload: its CRC no longer matches.
        let needle = Array("hello".utf8)
        if let range = data.range(of: Data(needle)) {
            data[range.lowerBound] = UInt8(ascii: "H")
        }
        let archive = try write(data, as: "corrupt.zip")
        let out = try destination()

        let (results, summary) = try ArchiveExtractor.extract(archiveURL: archive, to: out, settings: policy())

        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.written, 1)
        XCTAssertTrue(results.contains { result in
            if case .failed(let message) = result.outcome { return message.contains("CRC") }
            return false
        })
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("b.txt"), encoding: .utf8), "world")
    }

    func testConflictPoliciesOnExistingFiles() throws {
        let archive = try write(RawZipBuilder.archive([("a.txt", "new")]), as: "conflict.zip")
        let out = try destination()
        try Data("old".utf8).write(to: out.appendingPathComponent("a.txt"))

        // keepBoth (default): the existing file survives, the new one is numbered.
        _ = try ArchiveExtractor.extract(archiveURL: archive, to: out, settings: policy(conflict: .keepBoth))
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("a.txt"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("a 2.txt"), encoding: .utf8), "new")

        // skip: nothing changes.
        let (skipResults, _) = try ArchiveExtractor.extract(archiveURL: archive, to: out, settings: policy(conflict: .skip))
        XCTAssertEqual(skipResults.first?.outcome, .skipped(.conflict))

        // overwrite: the existing file is replaced.
        _ = try ArchiveExtractor.extract(archiveURL: archive, to: out, settings: policy(conflict: .overwrite))
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("a.txt"), encoding: .utf8), "new")
    }

    /// An entry named like the archive itself must never replace the file being
    /// read, whatever the policy says.
    func testEntryNamedLikeTheArchiveIsRefusedUnderOverwrite() throws {
        let archive = try write(RawZipBuilder.archive([("self.zip", "boom")]), as: "self.zip")
        let (results, summary) = try ArchiveExtractor.extract(
            archiveURL: archive,
            to: root,
            settings: policy(conflict: .overwrite)
        )
        XCTAssertEqual(summary.written, 0)
        XCTAssertEqual(results.first?.outcome, .skipped(.wouldReplaceArchive))
        XCTAssertNotNil(try? ZipReader(fileURL: archive), "the archive must still be readable")
    }

    func testTooLargeArchiveIsRefusedBeforeAnythingIsWritten() throws {
        let big = String(repeating: "x", count: 2_000_000)
        let archive = try write(RawZipBuilder.archive([("big.txt", big)]), as: "big.zip")
        let out = try destination()

        XCTAssertThrowsError(try ArchiveExtractor.extract(
            archiveURL: archive,
            to: out,
            settings: policy(limitMB: 1)
        )) { error in
            guard case ArchiveError.tooLarge = error else { return XCTFail("expected tooLarge, got \(error)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    func testNotAnArchiveIsReportedAsUnsupported() throws {
        let fake = try write(Data("definitely not a zip".utf8), as: "fake.zip")
        let out = try destination()
        XCTAssertThrowsError(try ArchiveExtractor.extract(archiveURL: fake, to: out, settings: policy())) { error in
            guard case ArchiveError.notAnArchive = error else { return XCTFail("expected notAnArchive, got \(error)") }
        }
    }

    func testDeletesArchiveAfterExtractionWhenConfigured() throws {
        let archive = try write(RawZipBuilder.archive([("a.txt", "hello")]), as: "gone.zip")
        let out = try destination()

        _ = try ArchiveExtractor.extract(
            archiveURL: archive,
            to: out,
            settings: policy(deletesArchive: true)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("a.txt").path))
    }

    /// 解压后删除原包 must not fire when the run deliberately left content
    /// behind — the archive is the only copy of what was skipped.
    func testKeepsTheArchiveWhenAnEntryWasSkippedForAConflict() throws {
        let archive = try write(RawZipBuilder.archive([("a.txt", "hello")]), as: "kept.zip")
        let out = try destination()
        try Data("already here".utf8).write(to: out.appendingPathComponent("a.txt"))

        let (_, summary) = try ArchiveExtractor.extract(
            archiveURL: archive,
            to: out,
            settings: policy(conflict: .skip, deletesArchive: true)
        )

        XCTAssertEqual(summary.written, 0)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: archive.path),
            "a skipped run must keep the archive so the skipped content still exists"
        )
    }

    /// A traversal entry is skipped, not extracted; deleting the archive would
    /// destroy the only copy of it.
    func testKeepsTheArchiveWhenAnEntryWasSkippedAsUnsafe() throws {
        let archive = try write(RawZipBuilder.archive([("../escape.txt", "payload")]), as: "evil-kept.zip")
        let out = try destination()

        let (_, summary) = try ArchiveExtractor.extract(
            archiveURL: archive,
            to: out,
            settings: policy(deletesArchive: true)
        )

        XCTAssertEqual(summary.skipped, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    /// Metadata noise (`__MACOSX/`, `._*`, `.DS_Store`) is not content, so a run
    /// that only dropped those still counts as clean.
    func testStillDeletesTheArchiveWhenOnlyMetadataWasSkipped() throws {
        let archive = try write(
            RawZipBuilder.archive([("__MACOSX/junk.txt", "junk"), ("a.txt", "hello")]),
            as: "metadata.zip"
        )
        let out = try destination()

        let (_, summary) = try ArchiveExtractor.extract(
            archiveURL: archive,
            to: out,
            settings: policy(deletesArchive: true)
        )

        XCTAssertEqual(summary.written, 1)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }

    // MARK: - Entry-name encodings

    /// `ZipNameDecoder` takes the reader's own slice type.
    private func nameBytes(_ bytes: [UInt8]) -> ArraySlice<UInt8> { bytes[...] }

    /// Windows' own「压缩」writes GBK names with general-purpose bit 11 **clear**.
    /// Decoding those as CP437 — which is what the spec literally says — is the
    /// mojibake every Chinese user has met (`新建文件夹` → `ÐÂ½¨ÎÄ¼þ¼Ð`), and it
    /// lands in the file names on disk too, not just in a log line.
    func testGBKEntryNameWithoutTheUTF8FlagIsDecodedAsChinese() throws {
        // "新建文件夹" in GBK.
        let gbk: [UInt8] = [208, 194, 189, 168, 206, 196, 188, 254, 188, 208]
        let archive = try write(RawZipBuilder.buildRaw([
            (nameBytes: gbk, contents: Data("x".utf8), externalAttributes: 0, flags: 0),
        ]), as: "gbk.zip")
        let out = try destination()

        let (results, summary) = try ArchiveExtractor.extract(archiveURL: archive, to: out, settings: policy())

        XCTAssertEqual(summary.written, 1)
        XCTAssertEqual(results.first?.entryName, "新建文件夹")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: out.appendingPathComponent("新建文件夹").path),
            "the decoded name is what gets written to disk"
        )
    }

    /// The same for a name with an ASCII part, which is the usual shape
    /// (`中文 文档.txt`).
    func testMixedGBKNameKeepsItsASCIIParts() {
        // "中文 文档.txt" in GBK.
        let gbk: [UInt8] = [214, 208, 206, 196, 32, 206, 196, 181, 181, 46, 116, 120, 116]
        XCTAssertEqual(ZipNameDecoder.decode(nameBytes(gbk), utf8Flag: false), "中文 文档.txt")
    }

    /// Plenty of tools write UTF-8 **without** setting the flag (Info-ZIP, older
    /// macOS, our own early builds). Those must not fall through to a legacy
    /// decoder.
    func testUTF8EntryNameWithoutTheFlagIsStillUTF8() throws {
        let archive = try write(RawZipBuilder.buildRaw([
            (nameBytes: Array("中文.txt".utf8), contents: Data("x".utf8), externalAttributes: 0, flags: 0),
        ]), as: "flagless-utf8.zip")
        let out = try destination()

        let (results, _) = try ArchiveExtractor.extract(archiveURL: archive, to: out, settings: policy())
        XCTAssertEqual(results.first?.entryName, "中文.txt")
    }

    /// A genuine CP437 name is what the spec calls "the original encoding", and
    /// it must stay Western. The byte-ratio guard on the GB18030 attempt is what
    /// keeps `Übersicht` from being turned into Chinese: GB18030 accepts `9A 62`
    /// as a two-byte sequence, so without the guard it would win.
    func testLegacyCP437EntryNameStaysLatin() {
        // "café.txt" — 0x82 is é.
        XCTAssertEqual(ZipNameDecoder.decode(nameBytes([99, 97, 102, 130, 46, 116, 120, 116]), utf8Flag: false), "café.txt")
        // "Übersicht.txt" — 0x9A is Ü, and 9A 62 is a legal GB18030 pair.
        let ubersicht: [UInt8] = [154, 98, 101, 114, 115, 105, 99, 104, 116, 46, 116, 120, 116]
        XCTAssertEqual(ZipNameDecoder.decode(nameBytes(ubersicht), utf8Flag: false), "Übersicht.txt")
        XCTAssertFalse(ZipNameDecoder.looksLikeLegacyChinese(ubersicht))
    }

    /// The ratio guard's boundary: a short Chinese name is still mostly high
    /// bytes, so a one-character name must not fall through to CP437.
    func testShortChineseNameStillTakesTheChineseBranch() {
        XCTAssertTrue(ZipNameDecoder.looksLikeLegacyChinese([214, 208, 46, 116, 120, 116]))   // 中.txt
        XCTAssertEqual(ZipNameDecoder.decode(nameBytes([214, 208, 46, 116, 120, 116]), utf8Flag: false), "中.txt")
    }

    /// The documented cost of the heuristic: a *contrived* mixed-script CP437
    /// name whose bytes are both mostly non-ASCII and valid GB18030 reads as
    /// Chinese. Pinned here on purpose — the alternative (trying CP437 first)
    /// would break every Windows-made Chinese zip, which is far more common.
    func testMixedScriptCP437NameIsTheKnownCostOfPreferringChinese() {
        let mixed: [UInt8] = [154, 110, 139, 99]   // "Ünïc" in CP437
        XCTAssertTrue(ZipNameDecoder.looksLikeLegacyChinese(mixed))
        XCTAssertNotEqual(ZipNameDecoder.decode(nameBytes(mixed), utf8Flag: false), "Ünïc")
    }

    /// Bit 11 is authoritative: a writer that set it but wrote garbage must still
    /// yield *something* rather than throwing the entry away.
    func testUTF8FlaggedNameThatIsNotUTF8StillDecodes() {
        let decoded = ZipNameDecoder.decode(nameBytes([0xFF, 0xFE, 0x41]), utf8Flag: true)
        XCTAssertFalse(decoded.isEmpty)
        XCTAssertTrue(decoded.contains("A"))
    }

    func testASCIIEntryNameIsUnaffectedByTheFlag() {
        XCTAssertEqual(ZipNameDecoder.decode(nameBytes(Array("folder/a.txt".utf8)), utf8Flag: false), "folder/a.txt")
        XCTAssertEqual(ZipNameDecoder.decode(nameBytes(Array("folder/a.txt".utf8)), utf8Flag: true), "folder/a.txt")
    }

    func testTheCJKGuardRecognisesIdeographsAndPunctuation() {
        XCTAssertTrue(ZipNameDecoder.containsCJK("新建文件夹"))
        XCTAssertTrue(ZipNameDecoder.containsCJK("a（b）"))
        XCTAssertFalse(ZipNameDecoder.containsCJK("café.txt"))
        XCTAssertFalse(ZipNameDecoder.containsCJK("Проект"))
        XCTAssertFalse(ZipNameDecoder.containsCJK(""))
    }

    // MARK: - Reader

    func testReaderRoundTripsDeflatedContent() throws {
        let entries = [
            ZipArchiveEntry(name: "a.txt", contents: Data(String(repeating: "A", count: 5000).utf8)),
            ZipArchiveEntry(name: "b.txt", contents: Data()),
        ]
        let archive = try write(try ZipWriter.archive(entries), as: "round.zip")

        let reader = try ZipReader(fileURL: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["a.txt", "b.txt"])
        XCTAssertEqual(try reader.contents(of: reader.entries[0]).count, 5000)
        XCTAssertEqual(reader.entries[0].compressionMethod, 8)
        XCTAssertEqual(try reader.contents(of: reader.entries[1]), Data())
    }

    func testReaderRejectsGarbageAndTruncatedInput() throws {
        XCTAssertThrowsError(try ZipReader(data: Data("not a zip".utf8)))
        var archive = RawZipBuilder.archive([("a.txt", "hello")])
        archive.removeLast(10)
        XCTAssertThrowsError(try ZipReader(data: archive))
    }

    // MARK: - Progress and control (the 暂停/取消 window's other half)

    private func multiEntryArchive(named name: String) throws -> URL {
        let entries = (0..<6).map { index in
            ZipArchiveEntry(name: "f\(index).txt", contents: Data(String(repeating: "x", count: 64).utf8))
        }
        return try write(try ZipWriter.archive(entries), as: name)
    }

    func testExtractionReportsProgressUpToOne() throws {
        let archive = try multiEntryArchive(named: "progress.zip")
        let out = try destination("progress-out")

        var seen: [Double] = []
        let control = ArchiveOperationControl()
        control.onProgress { seen.append($0) }

        _ = try ArchiveExtractor.extract(
            archiveURL: archive,
            to: out,
            settings: ArchiveSettings(),
            control: control
        )

        XCTAssertFalse(seen.isEmpty, "an extraction must report progress")
        XCTAssertEqual(seen.last, 1, "the bar must finish full")
        XCTAssertEqual(seen, seen.sorted(), "progress must not go backwards: \(seen)")
    }

    /// One request can extract several archives; each reports into its own slice
    /// of the single bar the request owns.
    func testExtractionProgressStaysInsideItsSliceOfTheRequest() throws {
        let archive = try multiEntryArchive(named: "slice.zip")
        let out = try destination("slice-out")

        var seen: [Double] = []
        let control = ArchiveOperationControl()
        control.onProgress { seen.append($0) }

        _ = try ArchiveExtractor.extract(
            archiveURL: archive,
            to: out,
            settings: ArchiveSettings(),
            control: control,
            progressRange: 0.5...1.0
        )

        XCTAssertEqual(seen.first, 0.5)
        XCTAssertEqual(seen.last, 1)
        XCTAssertTrue(seen.allSatisfy { $0 >= 0.5 && $0 <= 1.0 }, "escaped its slice: \(seen)")
    }

    func testPausedExtractionWaitsAndThenFinishes() throws {
        let archive = try multiEntryArchive(named: "paused.zip")
        let out = try destination("paused-out")

        let control = ArchiveOperationControl()
        var finished = false
        let done = expectation(description: "extraction finished after resume")

        DispatchQueue.global().async {
            _ = try? ArchiveExtractor.extract(
                archiveURL: archive,
                to: out,
                settings: ArchiveSettings(),
                control: control
            )
            finished = true
            done.fulfill()
        }

        control.pause()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(finished, "a paused extraction must not complete")
        XCTAssertTrue(control.isPaused)

        control.resume()
        wait(for: [done], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("f0.txt").path))
    }

    func testCancelledExtractionStopsAndWritesNothingMore() throws {
        let archive = try multiEntryArchive(named: "cancelled.zip")
        let out = try destination("cancelled-out")

        let control = ArchiveOperationControl(cancelled: true)
        XCTAssertThrowsError(try ArchiveExtractor.extract(
            archiveURL: archive,
            to: out,
            settings: ArchiveSettings(),
            control: control
        )) { error in
            XCTAssertEqual(error as? ArchiveError, .cancelled)
        }
    }
}
