import XCTest
import AppKit

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

    // MARK: - Favorite icons (extension side)

    /// The main app renders one PNG per entry; the file name travels in the same
    /// payload the menu is built from.
    func testIconFileNameFlowsThroughTheDecoder() throws {
        var settings = MenuRightSettings.default
        settings.favoriteFolders = [FavoriteFolder(displayName: "Docs", path: "/tmp/docs", iconFile: "folder-abc.png")]
        settings.favoriteApps = [
            FavoriteApp(displayName: "Safari", path: "/Applications/Safari.app", iconFile: "application-abc.png"),
        ]
        settings.favoriteWebsites = [
            FavoriteWebsite(displayName: "GitHub", urlString: "https://github.com", iconFile: "website-abc.png"),
        ]
        try write(settings)

        XCTAssertEqual(
            FinderFavorites.entries(from: defaults).map(\.iconFile),
            ["folder-abc.png", "application-abc.png", "website-abc.png"]
        )
    }

    /// A payload from a build without icons must still produce a menu — with
    /// titles only, exactly as before the feature existed.
    func testEntriesWithoutIconsDecodeWithNoIconFile() throws {
        var settings = MenuRightSettings.default
        settings.favoriteFolders = [FavoriteFolder(displayName: "Docs", path: "/tmp/docs")]
        try write(settings)
        XCTAssertNil(FinderFavorites.entries(from: defaults).first?.iconFile)
    }

    private func makeIconDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-icons-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func pngData(_ color: NSColor = .systemBlue) throws -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        return try XCTUnwrap(FavoriteIconProvider.pngData(from: image))
    }

    func testMenuIconIsLoadedFromTheIconFolder() throws {
        let directory = try makeIconDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try pngData().write(to: directory.appendingPathComponent("folder-x.png"))

        let image = try XCTUnwrap(FinderFavoriteIcons.image(named: "folder-x.png", in: directory))
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16), "menu icons render at 16 pt")
    }

    func testMenuIconIsNilWhenThereIsNoFile() throws {
        let directory = try makeIconDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(FinderFavoriteIcons.image(named: nil, in: directory))
        XCTAssertNil(FinderFavoriteIcons.image(named: "", in: directory))
        XCTAssertNil(FinderFavoriteIcons.image(named: "missing.png", in: directory))
    }

    /// The name round-trips through a JSON payload, so it must not be able to
    /// reach a file outside the icon folder.
    func testMenuIconRefusesAPathOutsideTheFolder() throws {
        let directory = try makeIconDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outside = directory.deletingLastPathComponent()
            .appendingPathComponent("escape-\(UUID().uuidString).png")
        try pngData().write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertNil(FinderFavoriteIcons.image(named: "../\(outside.lastPathComponent)", in: directory))
        XCTAssertNil(FinderFavoriteIcons.image(named: outside.path, in: directory))
    }

    // MARK: - Favorite icons (app side)

    func testIconFileNamesCarryTheKindAndStayStable() {
        let id = UUID()
        XCTAssertEqual(FavoriteIconProvider.fileName(for: id, kind: .folder), "folder-\(id.uuidString.lowercased()).png")
        XCTAssertEqual(
            FavoriteIconProvider.fileName(for: id, kind: .application),
            "application-\(id.uuidString.lowercased()).png"
        )
        XCTAssertEqual(
            FavoriteIconProvider.fileName(for: id, kind: .website),
            "website-\(id.uuidString.lowercased()).png"
        )
        XCTAssertEqual(FavoriteIconProvider.fileName(for: id, kind: .folder), FavoriteIconProvider.fileName(for: id, kind: .folder))
    }

    func testIconFileNamesAreCheckedBeforeTheyReachTheFilesystem() {
        for name in ["folder-x.png", "a b.png", "…"] {
            XCTAssertTrue(FavoriteIconProvider.isSafeFileName(name), name)
        }
        for name in ["", "../x.png", "a/b.png", "a\\b.png", "..", "."] {
            XCTAssertFalse(FavoriteIconProvider.isSafeFileName(name), name)
        }
    }

    /// Everything stored is a fixed-size PNG, whatever the source icon's size —
    /// a menu row must not inherit a 512 px app icon's scale.
    func testStoredIconIsAPngAtTheFixedSize() throws {
        let source = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let data = try XCTUnwrap(FavoriteIconProvider.pngData(from: source))
        XCTAssertTrue(FaviconLoader.isImage(data), "the stored bytes must still be a recognisable image")

        let decoded = try XCTUnwrap(NSImage(data: data))
        let side = CGFloat(FavoriteIconProvider.pixelSize)
        XCTAssertEqual(decoded.size, NSSize(width: side, height: side))
    }

    // MARK: - Favicon loading

    func testFaviconURLKeepsTheSchemeAndAnswersAtTheRoot() {
        XCTAssertEqual(
            FaviconLoader.faviconURL(for: URL(string: "https://github.com/foo/bar?x=1")!)?.absoluteString,
            "https://github.com/favicon.ico"
        )
        XCTAssertEqual(
            FaviconLoader.faviconURL(for: URL(string: "http://example.com")!)?.absoluteString,
            "http://example.com/favicon.ico"
        )
    }

    func testDeclaredIconIsReadFromEitherAttributeOrder() {
        let page = URL(string: "https://example.com/a/b")!
        XCTAssertEqual(
            FaviconLoader.declaredIconURL(inHTML: #"<link rel="icon" href="/i.png">"#, pageURL: page)?.absoluteString,
            "https://example.com/i.png"
        )
        XCTAssertEqual(
            FaviconLoader.declaredIconURL(inHTML: #"<link href="fav.ico" rel="shortcut icon">"#, pageURL: page)?.absoluteString,
            "https://example.com/a/fav.ico"
        )
        XCTAssertEqual(
            FaviconLoader.declaredIconURL(inHTML: "<link rel='apple-touch-icon' href='t.png'>", pageURL: page)?.absoluteString,
            "https://example.com/a/t.png"
        )
        XCTAssertNil(FaviconLoader.declaredIconURL(inHTML: #"<link rel="stylesheet" href="a.css">"#, pageURL: page))
        XCTAssertNil(FaviconLoader.declaredIconURL(inHTML: "<html><head></head></html>", pageURL: page))
    }

    func testImageSniffingAcceptsFaviconFormatsAndRejectsMarkup() {
        XCTAssertTrue(FaviconLoader.isImage(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), "PNG")
        XCTAssertTrue(FaviconLoader.isImage(Data([0xFF, 0xD8, 0xFF, 0xE0])), "JPEG")
        XCTAssertTrue(FaviconLoader.isImage(Data([0x00, 0x00, 0x01, 0x00, 0x01])), "ICO")
        XCTAssertTrue(FaviconLoader.isImage(Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])), "GIF")
        XCTAssertFalse(FaviconLoader.isImage(Data("<!DOCTYPE html><html>".utf8)), "an HTML error page is not an icon")
        // NSImage cannot decode SVG, so those sites fall back to the plain title.
        XCTAssertFalse(FaviconLoader.isImage(Data("<svg xmlns=\"http://www.w3.org/2000/svg\">".utf8)))
    }
}
