import XCTest

/// P9: creating archives from a Finder selection, in every format this build can
/// write (ZIP, TAR, TAR.GZ, TAR.BZ2).
final class ArchiveCompressorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ relative: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeDirectory(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func compress(
        _ sources: [URL],
        format: ArchiveFormat,
        name: String,
        conflictPolicy: ArchiveConflictPolicy = .keepBoth,
        sizeLimitMB: Int = 64
    ) throws -> ArchiveCompressor.Report {
        try ArchiveCompressor.compress(
            sources,
            into: root,
            preferredName: name,
            format: format,
            conflictPolicy: conflictPolicy,
            sizeLimitMB: sizeLimitMB
        )
    }

    private func extract(_ archive: URL, into name: String) throws -> ArchiveExtractionSummary {
        let out = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let (_, summary) = try ArchiveExtractor.extract(archiveURL: archive, to: out, settings: ArchiveSettings())
        return summary
    }

    // MARK: - Format table

    func testWritableFormatsAndTheirExtensions() {
        XCTAssertEqual(ArchiveCompressor.writableFormats, [.zip, .tar, .gzip, .bzip2])
        XCTAssertEqual(ArchiveCompressor.fileNameExtension(for: .zip), "zip")
        XCTAssertEqual(ArchiveCompressor.fileNameExtension(for: .tar), "tar")
        XCTAssertEqual(ArchiveCompressor.fileNameExtension(for: .gzip), "tar.gz")
        XCTAssertEqual(ArchiveCompressor.fileNameExtension(for: .bzip2), "tar.bz2")
        for format in [ArchiveFormat.sevenZip, .xz, .rar] {
            XCTAssertFalse(ArchiveCompressor.canWrite(format), "\(format.rawValue) must stay read-only")
        }
    }

    func testUnsupportedFormatsAreRefusedExplicitly() throws {
        let file = try makeFile("a.txt", "A")
        for format in [ArchiveFormat.sevenZip, .xz, .rar] {
            XCTAssertThrowsError(try compress([file], format: format, name: "a.out")) { error in
                guard case ArchiveError.unsupportedFormat = error else {
                    return XCTFail("expected unsupportedFormat for \(format.rawValue), got \(error)")
                }
            }
        }
    }

    func testPreferredNamesCarryTheFormatExtension() throws {
        let one = try makeFile("report.pdf", "pdf")
        XCTAssertEqual(ArchiveCompressor.preferredArchiveName(for: [one], format: .zip), "report.pdf.zip")
        XCTAssertEqual(ArchiveCompressor.preferredArchiveName(for: [one], format: .gzip), "report.pdf.tar.gz")

        let second = try makeFile("b.txt", "B")
        XCTAssertEqual(
            ArchiveCompressor.preferredArchiveName(for: [one, second], format: .tar),
            root.lastPathComponent + ".tar"
        )
    }

    // MARK: - ZIP

    func testZipCompressesAFolderTreeIncludingEmptyDirectories() throws {
        let folder = try makeDirectory("Project")
        _ = try makeFile("Project/a.txt", "A")
        _ = try makeFile("Project/sub/b.txt", "B")
        _ = try makeDirectory("Project/empty")

        let report = try compress([folder], format: .zip, name: "Project.zip")
        XCTAssertEqual(report.archiveURL.lastPathComponent, "Project.zip")
        XCTAssertTrue(report.skippedSymbolicLinks.isEmpty)
        XCTAssertEqual(report.entryCount, 5)

        let reader = try ZipReader(fileURL: report.archiveURL)
        XCTAssertEqual(reader.entries.map(\.name), [
            "Project/",
            "Project/a.txt",
            "Project/empty/",
            "Project/sub/",
            "Project/sub/b.txt",
        ])
    }

    // MARK: - TAR family

    func testTarRoundTripsThroughExtraction() throws {
        let folder = try makeDirectory("Round")
        _ = try makeFile("Round/one.txt", "1")
        _ = try makeFile("Round/deep/two.txt", "2")
        _ = try makeDirectory("Round/empty")

        let report = try compress([folder], format: .tar, name: "Round.tar")
        XCTAssertEqual(try Data(contentsOf: report.archiveURL).prefix(5).map { $0 }, Array("Round".utf8).prefix(5).map { $0 })

        let summary = try extract(report.archiveURL, into: "tar-out")
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("tar-out/Round/one.txt"), encoding: .utf8),
            "1"
        )
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("tar-out/Round/deep/two.txt"), encoding: .utf8),
            "2"
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("tar-out/Round/empty").path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testTarGzRoundTripsAndLooksLikeGzip() throws {
        let folder = try makeDirectory("Gz")
        _ = try makeFile("Gz/a.txt", "hello gz")

        let report = try compress([folder], format: .gzip, name: "Gz.tar.gz")
        XCTAssertEqual(report.archiveURL.pathExtension, "gz")
        let magic = try Data(contentsOf: report.archiveURL).prefix(2).map { $0 }
        XCTAssertEqual(magic, [0x1f, 0x8b], "a .tar.gz must start with the gzip magic")

        let summary = try extract(report.archiveURL, into: "gz-out")
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("gz-out/Gz/a.txt"), encoding: .utf8),
            "hello gz"
        )
    }

    func testTarBz2RoundTripsAndLooksLikeBzip2() throws {
        let folder = try makeDirectory("Bz")
        _ = try makeFile("Bz/a.txt", "hello bz")

        let report = try compress([folder], format: .bzip2, name: "Bz.tar.bz2")
        XCTAssertEqual([report.archiveURL.lastPathComponent], ["Bz.tar.bz2"])
        let magic = try Data(contentsOf: report.archiveURL).prefix(3).map { $0 }
        XCTAssertEqual(magic, Array("BZh".utf8), "a .tar.bz2 must start with the bzip2 magic")

        let summary = try extract(report.archiveURL, into: "bz-out")
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("bz-out/Bz/a.txt"), encoding: .utf8),
            "hello bz"
        )
    }

    // MARK: - Shared behaviour

    /// Following a symlink would package files the user did not select, and
    /// storing one would write it back on extraction.
    func testSymbolicLinksAreSkippedAndReportedInEveryFormat() throws {
        _ = try makeFile("real.txt", "real")
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("real.txt"))
        let folder = try makeDirectory("Tree")
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("nested-link"),
            withDestinationURL: root.appendingPathComponent("real.txt")
        )
        _ = try makeFile("Tree/keep.txt", "keep")

        for format in ArchiveCompressor.writableFormats {
            let extensionName = ArchiveCompressor.fileNameExtension(for: format)!
            let report = try compress([link, folder], format: format, name: "Tree-\(extensionName).\(extensionName)")
            XCTAssertEqual(
                report.skippedSymbolicLinks.sorted(),
                ["Tree/nested-link", "link.txt"],
                "\(format.rawValue) must skip symlinks"
            )
        }
    }

    func testExistingArchiveGetsANumberedNameUnderKeepBoth() throws {
        let file = try makeFile("a.txt", "A")
        let first = try compress([file], format: .zip, name: "a.txt.zip")
        let second = try compress([file], format: .zip, name: "a.txt.zip")
        XCTAssertEqual(first.archiveURL.lastPathComponent, "a.txt.zip")
        XCTAssertEqual(second.archiveURL.lastPathComponent, "a.txt 2.zip")
    }

    func testSkipPolicyRefusesToReplaceAnExistingArchive() throws {
        let file = try makeFile("a.txt", "A")
        _ = try compress([file], format: .zip, name: "a.txt.zip")
        XCTAssertThrowsError(try compress([file], format: .zip, name: "a.txt.zip", conflictPolicy: .skip)) { error in
            guard case ArchiveError.conflict = error else { return XCTFail("expected conflict, got \(error)") }
        }
    }

    func testOverwritePolicyReplacesTheArchive() throws {
        let file = try makeFile("a.txt", "A")
        _ = try compress([file], format: .zip, name: "a.txt.zip")
        _ = try makeFile("a.txt", "AB")
        let report = try compress([file], format: .zip, name: "a.txt.zip", conflictPolicy: .overwrite)
        let reader = try ZipReader(fileURL: report.archiveURL)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(String(data: try reader.contents(of: entry), encoding: .utf8), "AB")
    }

    /// The archive is built in memory, so the configured limit is enforced on the
    /// input total instead of being killed by the memory watchdog.
    func testSelectionAboveTheSizeLimitIsRefused() throws {
        let big = try makeFile("big.bin", String(repeating: "x", count: 2_000_000))
        XCTAssertThrowsError(try compress([big], format: .zip, name: "big.zip", sizeLimitMB: 1)) { error in
            guard case ArchiveError.tooLarge = error else { return XCTFail("expected tooLarge, got \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("big.zip").path))
    }

    // MARK: - Compression options (the dialog's knobs)

    func testZipLabelRoundTripsAsTheArchiveComment() throws {
        let file = try makeFile("a.txt", "A")
        let report = try ArchiveCompressor.compress(
            [file], into: root, preferredName: "labelled.zip", format: .zip,
            conflictPolicy: .keepBoth, sizeLimitMB: 64, label: "发布包 · 2026-09"
        )
        let reader = try ZipReader(fileURL: report.archiveURL)
        XCTAssertEqual(reader.comment, "发布包 · 2026-09")
    }

    func testZipWithoutALabelCarriesNoComment() throws {
        let file = try makeFile("a.txt", "A")
        let report = try compress([file], format: .zip, name: "plain.zip")
        XCTAssertNil(try ZipReader(fileURL: report.archiveURL).comment)
    }

    /// The mode must actually change the bytes, otherwise the dialog would be
    /// lying about what it does.
    func testCompressionModeChangesTheZipSize() throws {
        let file = try makeFile("repetitive.txt", String(repeating: "menu-right ", count: 20_000))
        let fast = try ArchiveCompressor.compress(
            [file], into: root, preferredName: "fast.zip", format: .zip,
            conflictPolicy: .keepBoth, sizeLimitMB: 64, mode: .fast
        )
        let maximum = try ArchiveCompressor.compress(
            [file], into: root, preferredName: "max.zip", format: .zip,
            conflictPolicy: .keepBoth, sizeLimitMB: 64, mode: .maximum
        )
        XCTAssertLessThan(
            try Data(contentsOf: maximum.archiveURL).count,
            try Data(contentsOf: fast.archiveURL).count,
            "maximum compression must not be larger than fast"
        )
        // Both must still be readable archives.
        XCTAssertEqual(try ZipReader(fileURL: fast.archiveURL).entries.count, 1)
        XCTAssertEqual(try ZipReader(fileURL: maximum.archiveURL).entries.count, 1)
    }

    /// Label and mode are accepted by every writable format; only ZIP has
    /// somewhere to put a comment, and the UI says so.
    func testLabelIsIgnoredByFormatsWithoutAComment() throws {
        let file = try makeFile("a.txt", "A")
        for format in [ArchiveFormat.tar, .gzip, .bzip2] {
            let extensionName = ArchiveCompressor.fileNameExtension(for: format)!
            let report = try ArchiveCompressor.compress(
                [file], into: root, preferredName: "labelled.\(extensionName)", format: format,
                conflictPolicy: .keepBoth, sizeLimitMB: 64, mode: .maximum, label: "ignored"
            )
            let out = root.appendingPathComponent("mode-out-\(format.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let (_, summary) = try ArchiveExtractor.extract(archiveURL: report.archiveURL, to: out, settings: ArchiveSettings())
            XCTAssertEqual(summary.failed, 0, "\(format.rawValue) must still extract")
        }
    }

    func testModeNamesAreLocalized() {
        for mode in ArchiveCompressionMode.allCases {
            for language in [AppLanguage.simplifiedChinese, .english] {
                XCTAssertFalse(Localization.text(mode.titleKey, language: language).isEmpty)
            }
        }
    }

    func testMissingSourceIsReported() {
        XCTAssertThrowsError(try compress([root.appendingPathComponent("nope.txt")], format: .zip, name: "nope.zip")) { error in
            guard case ArchiveError.readFailed = error else { return XCTFail("expected readFailed, got \(error)") }
        }
    }
}
