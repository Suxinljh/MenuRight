import XCTest

/// P9: which selected items the extension offers 解压/压缩 for.
final class FinderArchivesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "xin.ljhsu.MenuRight.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func write(settings: MenuRightSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(settings), forKey: FinderArchives.storageKey)
    }

    /// The suffix tables are a hand-copied subset of the app's catalog; this is
    /// the guard against them drifting apart.
    ///
    /// Extraction must match the catalog exactly (the extension decides whether
    /// the menu offers 解压). Compression is allowed to write a *compound* name
    /// — `.tar.gz`, `.tar.bz2` — so it is checked by suffix instead.
    func testSuffixTablesAgreeWithTheSettingsCatalog() {
        for (rawFormat, suffixes) in FinderArchives.extractionSuffixesByFormat {
            let format = ArchiveFormat(rawValue: rawFormat)
            XCTAssertNotNil(format, "\(rawFormat) is not an ArchiveFormat")
            XCTAssertEqual(suffixes, format?.pathExtensions, "extraction suffixes drifted for \(rawFormat)")
            XCTAssertTrue(format?.isSupported ?? false, "RAR must never be offered")
        }
        for (rawFormat, suffixes) in FinderArchives.compressionSuffixesByFormat {
            let format = ArchiveFormat(rawValue: rawFormat)
            XCTAssertNotNil(format, "\(rawFormat) is not an ArchiveFormat")
            XCTAssertTrue(format?.isSupported ?? false, "\(rawFormat) is not a supported format")
            for suffix in suffixes {
                XCTAssertTrue(
                    format?.pathExtensions.contains(where: { suffix.hasSuffix($0) }) ?? false,
                    "compression suffix \(suffix) does not end in a catalog suffix of \(rawFormat)"
                )
            }
        }
        XCTAssertEqual(FinderArchives.compressionFormats, ["zip", "tar", "gzip", "bzip2"])
    }

    func testClassifiesAMixedSelection() {
        let zip = URL(fileURLWithPath: "/tmp/a.zip")
        let pdf = URL(fileURLWithPath: "/tmp/b.pdf")
        let selection = FinderArchives.classify([zip, pdf], defaults: defaults)

        XCTAssertEqual(selection.archives, [zip])
        XCTAssertEqual(selection.compressible, [zip, pdf])
        XCTAssertFalse(selection.canExtract, "a mixed selection must not offer 解压")
        XCTAssertTrue(selection.canCompress)
    }

    func testExtractIsOfferedWhenEverySelectedItemIsAnArchive() {
        let archives = [URL(fileURLWithPath: "/tmp/a.zip"), URL(fileURLWithPath: "/tmp/b.ZIP")]
        let selection = FinderArchives.classify(archives, defaults: defaults)
        XCTAssertEqual(selection.archives.count, 2, "the extension match must be case-insensitive")
        XCTAssertTrue(selection.canExtract)
    }

    func testEmptySelectionOffersNothing() {
        let selection = FinderArchives.classify([], defaults: defaults)
        XCTAssertFalse(selection.canExtract)
        XCTAssertFalse(selection.canCompress)
    }

    /// A fresh install has no payload: the conservative answer is "everything
    /// this build can read", not "nothing".
    func testMissingPayloadFallsBackToTheBuildCapabilities() {
        let all = Set(ArchiveFormat.allCases.filter(\.isSupported).flatMap(\.pathExtensions))
        XCTAssertEqual(FinderArchives.enabledExtractionSuffixes(from: defaults), all)
    }

    func testDisabledFormatsAreNotOffered() throws {
        var settings = MenuRightSettings.default
        settings.archives.enabledFormats = []
        try write(settings: settings)
        XCTAssertEqual(FinderArchives.enabledExtractionSuffixes(from: defaults), [])
        XCTAssertFalse(FinderArchives.classify([URL(fileURLWithPath: "/tmp/a.zip")], defaults: defaults).canExtract)
    }

    /// Stage 2 added the library backends, so the formats the user enabled are
    /// now the only filter.
    func testEveryEnabledBackedFormatIsOffered() throws {
        var settings = MenuRightSettings.default
        settings.archives.enabledFormats = [.sevenZip, .tar, .xz]
        try write(settings: settings)
        XCTAssertEqual(FinderArchives.enabledExtractionSuffixes(from: defaults), Set(["7z", "tar", "xz", "txz"]))
    }

    func testArchivesEnabledInTheSettingsPayloadAreOffered() throws {
        var settings = MenuRightSettings.default
        settings.archives.enabledFormats = [.zip, .tar, .bzip2]
        try write(settings: settings)
        XCTAssertEqual(FinderArchives.enabledExtractionSuffixes(from: defaults), Set(["zip", "tar", "bz2", "tbz2"]))
    }

    func testCorruptPayloadFallsBackInsteadOfHidingEverything() {
        defaults.set(Data("not json".utf8), forKey: FinderArchives.storageKey)
        let all = Set(ArchiveFormat.allCases.filter(\.isSupported).flatMap(\.pathExtensions))
        XCTAssertEqual(FinderArchives.enabledExtractionSuffixes(from: defaults), all)
    }

    func testCompressionSuffixLookup() {
        XCTAssertEqual(FinderArchives.compressionSuffix(forFormat: "zip"), "zip")
        XCTAssertEqual(FinderArchives.compressionSuffix(forFormat: "gzip"), "tar.gz")
        XCTAssertEqual(FinderArchives.compressionSuffix(forFormat: "bzip2"), "tar.bz2")
        XCTAssertNil(FinderArchives.compressionSuffix(forFormat: "rar"))
    }
}
