import XCTest

/// P7-b: the extension-side reader for the three favorite lists.
///
/// The FinderSync appex must not link the app's settings tree, so this decoder
/// is a separate, tiny type. These tests therefore check both directions: the
/// JSON the app's models write is what this reader consumes, and what the reader
/// produces is what the menu needs (order, enabled filtering, unique titles).
final class FinderFavoritesTests: XCTestCase {
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

    private func write(_ settings: MenuRightSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(settings), forKey: FinderFavorites.storageKey)
    }

    /// The extension reads the payload the app writes, so the key must not drift.
    func testStorageKeyMatchesTheAppStore() {
        XCTAssertEqual(FinderFavorites.storageKey, SettingsStore.storageKey)
    }

    func testReadsTheThreeListsInSettingsOrder() throws {
        var settings = MenuRightSettings.default
        settings.favoriteFolders = [
            FavoriteFolder(displayName: "项目", path: "/Users/foo/Projects"),
            FavoriteFolder(displayName: "", path: "/Users/foo/Downloads"),
        ]
        settings.favoriteApps = [
            FavoriteApp(displayName: "Safari", path: "/Applications/Safari.app", bundleIdentifier: "com.apple.Safari"),
        ]
        settings.favoriteWebsites = [
            FavoriteWebsite(displayName: "GitHub", urlString: "https://github.com"),
        ]
        try write(settings)

        let groups = FinderFavorites.groups(from: defaults)
        XCTAssertEqual(groups.folders.map(\.menuTitle), ["项目", "Downloads"])
        XCTAssertEqual(groups.folders.map(\.target), ["/Users/foo/Projects", "/Users/foo/Downloads"])
        XCTAssertEqual(groups.applications.map(\.menuTitle), ["Safari"])
        XCTAssertEqual(groups.applications.map(\.target), ["/Applications/Safari.app"])
        XCTAssertEqual(groups.websites.map(\.menuTitle), ["GitHub"])
        XCTAssertEqual(groups.websites.map(\.target), ["https://github.com"])
    }

    func testDisabledEntriesAreNotOffered() throws {
        var settings = MenuRightSettings.default
        settings.favoriteFolders = [FavoriteFolder(displayName: "Hidden", path: "/tmp/x", isEnabled: false)]
        settings.favoriteApps = [FavoriteApp(displayName: "Hidden", path: "/Applications/X.app", isEnabled: false)]
        settings.favoriteWebsites = [FavoriteWebsite(displayName: "Hidden", urlString: "https://x.com", isEnabled: false)]
        try write(settings)

        XCTAssertTrue(FinderFavorites.entries(from: defaults).isEmpty)
    }

    func testEmptyRowsAreSkipped() throws {
        var settings = MenuRightSettings.default
        settings.favoriteFolders = [FavoriteFolder(displayName: "No path", path: "  ")]
        settings.favoriteApps = [FavoriteApp(displayName: "No target", path: "", bundleIdentifier: nil)]
        settings.favoriteWebsites = [FavoriteWebsite(displayName: "No URL", urlString: "")]
        try write(settings)

        XCTAssertTrue(FinderFavorites.entries(from: defaults).isEmpty)
    }

    /// An app added by bundle identifier only (no readable path) still opens.
    func testApplicationFallsBackToItsBundleIdentifier() throws {
        var settings = MenuRightSettings.default
        settings.favoriteApps = [FavoriteApp(displayName: "Notes", path: "", bundleIdentifier: "com.apple.Notes")]
        try write(settings)

        let entry = try XCTUnwrap(FinderFavorites.entries(from: defaults).first)
        XCTAssertEqual(entry.kind, .application)
        XCTAssertEqual(entry.target, "com.apple.Notes")
    }

    /// "example.com" is what users type; the settings pane normalizes it, and
    /// the reader must not silently drop a value that lacks a scheme.
    func testWebsiteWithoutASchemeGetsHTTPS() throws {
        var settings = MenuRightSettings.default
        settings.favoriteWebsites = [FavoriteWebsite(displayName: "Example", urlString: "example.com")]
        try write(settings)

        XCTAssertEqual(FinderFavorites.entries(from: defaults).first?.target, "https://example.com")
    }

    /// Only http(s) may ever reach LaunchServices from a menu entry.
    func testNonHTTPWebsitesAreIgnored() {
        XCTAssertNil(FinderFavorites.webURLString("file:///etc/passwd"))
        XCTAssertNil(FinderFavorites.webURLString("javascript:alert(1)"))
        XCTAssertNil(FinderFavorites.webURLString("ftp://example.com"))
        XCTAssertNil(FinderFavorites.webURLString("https://"))
        XCTAssertNil(FinderFavorites.webURLString("has space.com"))
        XCTAssertEqual(FinderFavorites.webURLString("https://example.com/a?b=1"), "https://example.com/a?b=1")
    }

    /// The menu title is the only key Finder hands back, so two entries sharing
    /// a name must still produce two distinct titles — otherwise a click is
    /// ambiguous and the wrong favorite opens.
    func testDuplicateNamesGetDistinctTitles() throws {
        var settings = MenuRightSettings.default
        settings.favoriteWebsites = [
            FavoriteWebsite(displayName: "GitHub", urlString: "https://github.com"),
            FavoriteWebsite(displayName: "GitHub", urlString: "https://github.com/enterprise"),
        ]
        settings.favoriteApps = [FavoriteApp(displayName: "GitHub", path: "/Applications/GitHub.app")]
        try write(settings)

        let entries = FinderFavorites.entries(from: defaults)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(Set(entries.map(\.menuTitle)).count, 3, "titles must be unique: \(entries.map(\.menuTitle))")
        XCTAssertTrue(entries.allSatisfy { $0.menuTitle.hasPrefix("GitHub — ") })
    }

    /// Same folder name under two parents: the parent is part of the title.
    func testSameFolderNameInTwoParentsIsDisambiguated() throws {
        var settings = MenuRightSettings.default
        settings.favoriteFolders = [
            FavoriteFolder(displayName: "Docs", path: "/Users/foo/Work/Docs"),
            FavoriteFolder(displayName: "Docs", path: "/Users/foo/Home/Docs"),
        ]
        try write(settings)

        let titles = FinderFavorites.entries(from: defaults).map(\.menuTitle)
        XCTAssertEqual(Set(titles).count, 2, "titles must be unique: \(titles)")
    }

    func testMissingCorruptOrForeignPayloadYieldsNoEntries() {
        XCTAssertTrue(FinderFavorites.entries(from: defaults).isEmpty, "no payload")

        defaults.set(Data("not json".utf8), forKey: FinderFavorites.storageKey)
        XCTAssertTrue(FinderFavorites.entries(from: defaults).isEmpty, "corrupt payload")

        // A realistic payload from a build without the favorites field.
        defaults.set(Data(#"{"schemaVersion":1,"general":{"language":"en"}}"#.utf8), forKey: FinderFavorites.storageKey)
        XCTAssertTrue(FinderFavorites.entries(from: defaults).isEmpty, "absent field")
    }

    /// The reader must not depend on field order or on unknown fields surviving.
    func testUnknownFieldsInThePayloadAreIgnored() throws {
        let payload = #"""
        {"schemaVersion":9,"favoriteFolders":[{"id":"11111111-1111-1111-1111-111111111111","displayName":"Docs","path":"/tmp","isEnabled":true,"somethingNew":42}],"futureSection":{"x":1}}
        """#
        defaults.set(Data(payload.utf8), forKey: FinderFavorites.storageKey)

        let entries = FinderFavorites.entries(from: defaults)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.menuTitle, "Docs")
        XCTAssertEqual(entries.first?.kind, .folder)
    }
}
