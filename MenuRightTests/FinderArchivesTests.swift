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

    // MARK: - 解压位置 → the second 解压 item

    /// No payload at all (fresh install) keeps the pre-setting behaviour: ask.
    func testMissingPayloadAsksForADestination() {
        XCTAssertEqual(FinderArchives.destination(from: defaults), .ask)
    }

    func testAskEveryTimeAsksForADestination() throws {
        var settings = MenuRightSettings.default
        settings.archives.destination = .askEachTime
        try write(settings: settings)
        XCTAssertEqual(FinderArchives.destination(from: defaults), .ask)
    }

    /// 压缩包所在文件夹 is exactly what 解压到当前文件夹 already does, so the
    /// second item is dropped instead of duplicating it.
    func testArchiveFolderDropsTheSecondExtractItem() throws {
        var settings = MenuRightSettings.default
        settings.archives.destination = .sameFolder
        try write(settings: settings)
        XCTAssertEqual(FinderArchives.destination(from: defaults), .duplicatesFirstItem)
    }

    func testChosenFolderIsUsedDirectly() throws {
        var settings = MenuRightSettings.default
        settings.archives.destination = .customFolder
        settings.archives.customDestinationPath = "/tmp/MenuRight Downloads"
        try write(settings: settings)
        XCTAssertEqual(
            FinderArchives.destination(from: defaults),
            .folder(URL(fileURLWithPath: "/tmp/MenuRight Downloads"))
        )
    }

    /// 指定文件夹 with nothing chosen yet cannot be honoured: asking beats
    /// extracting next to the archive while the pane says otherwise.
    func testChosenFolderWithoutAPathAsks() throws {
        var settings = MenuRightSettings.default
        settings.archives.destination = .customFolder
        settings.archives.customDestinationPath = "   "
        try write(settings: settings)
        XCTAssertEqual(FinderArchives.destination(from: defaults), .ask)
    }

    /// A payload written by another build must never redirect an extraction.
    func testUnknownDestinationValueAsks() {
        defaults.set(
            Data(#"{"archives":{"destination":"somewhereElse"}}"#.utf8),
            forKey: FinderArchives.storageKey
        )
        XCTAssertEqual(FinderArchives.destination(from: defaults), .ask)
    }

    // MARK: - 允许的压缩格式 → 压缩 ▸

    func testCompressionFormatsFallBackToEverythingWithoutAPayload() {
        XCTAssertEqual(FinderArchives.enabledCompressionFormats(from: defaults), FinderArchives.compressionFormats)
    }

    func testCompressionFormatsFollowTheSetting() throws {
        var settings = MenuRightSettings.default
        settings.archives.enabledFormats = [.zip, .bzip2]
        try write(settings: settings)
        XCTAssertEqual(FinderArchives.enabledCompressionFormats(from: defaults), ["zip", "bzip2"])
    }

    /// Only read-only formats enabled: no format item survives, and 压缩 ▸ still
    /// offers 自定义压缩… (that pairing is asserted in the menu-plan tests).
    func testReadOnlyFormatsLeaveNoCompressionItems() throws {
        var settings = MenuRightSettings.default
        settings.archives.enabledFormats = [.sevenZip, .xz]
        try write(settings: settings)
        XCTAssertEqual(FinderArchives.enabledCompressionFormats(from: defaults), [])
    }

    /// An empty set means "everything", matching the extraction side: a payload
    /// with every box unticked must not look like a build that cannot compress.
    func testEmptyFormatSetKeepsEveryCompressionFormat() throws {
        var settings = MenuRightSettings.default
        settings.archives.enabledFormats = []
        try write(settings: settings)
        XCTAssertEqual(FinderArchives.enabledCompressionFormats(from: defaults), FinderArchives.compressionFormats)
    }
}
