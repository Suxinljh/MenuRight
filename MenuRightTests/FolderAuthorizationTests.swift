import XCTest

final class FolderAuthorizationTests: XCTestCase {
    private var tempURL: URL!
    private var store: FolderAuthorizationStore!

    override func setUpWithError() throws {
        tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mr-a25-" + UUID().uuidString + ".json")
        store = FolderAuthorizationStore(fileURL: tempURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL)
    }

    private func folder(path: String, bookmark: String = "bookmark") -> AuthorizedFolder {
        AuthorizedFolder(
            displayName: (path as NSString).lastPathComponent,
            originalPath: path,
            bookmarkData: Data(bookmark.utf8)
        )
    }

    func testAddAndLoadRoundTrip() throws {
        let folder = folder(path: "/Users/foo/Projects", bookmark: "bm-1")
        try store.add(folder)
        let loaded = store.loadFolders()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, folder.id)
        XCTAssertEqual(loaded[0].originalPath, "/Users/foo/Projects")
        XCTAssertEqual(loaded[0].bookmarkData, Data("bm-1".utf8))
    }

    func testRemove() throws {
        let folder = folder(path: "/Users/foo/Projects")
        try store.add(folder)
        try store.remove(id: folder.id)
        XCTAssertTrue(store.loadFolders().isEmpty)
    }

    func testDeduplicateSameNormalizedPath() throws {
        try store.add(folder(path: "/tmp/x"))
        try store.add(folder(path: "/tmp/x/"))     // trailing slash, same dir
        XCTAssertEqual(store.loadFolders().count, 1)
    }

    func testReauthorizeReplacesBookmarkDataKeepsID() throws {
        let first = folder(path: "/Users/foo/Projects", bookmark: "old")
        try store.add(first)
        let second = folder(path: "/Users/foo/Projects", bookmark: "new")
        try store.add(second)

        let loaded = store.loadFolders()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, first.id, "reauthorization must keep the row id")
        XCTAssertEqual(loaded[0].bookmarkData, Data("new".utf8), "bookmark data must be refreshed")
    }

    func testCorruptPayloadLoadsEmpty() throws {
        try Data("not json at all".utf8).write(to: tempURL)
        XCTAssertTrue(store.loadFolders().isEmpty)
    }

    func testUnknownVersionLoadsEmpty() throws {
        let payload = FolderAuthorizationPayload(version: 99, folders: [folder(path: "/x")])
        // JSONEncoder cannot encode an unknown defined version into the type,
        // so craft the payload manually.
        let json = "{\"version\":99,\"folders\":[]}"
        try json.data(using: .utf8)!.write(to: tempURL)
        XCTAssertTrue(store.loadFolders().isEmpty)
    }

    func testUpdateRefreshesBookmarkData() throws {
        let folder = folder(path: "/Users/foo/Projects", bookmark: "old")
        try store.add(folder)

        var refreshed = folder
        refreshed.bookmarkData = Data("fresh".utf8)
        try store.update(refreshed)

        let loaded = store.loadFolders()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].bookmarkData, Data("fresh".utf8))
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertTrue(store.loadFolders().isEmpty)
    }

    func testMultipleFoldersOrderPreserved() throws {
        try store.add(folder(path: "/Users/foo/Projects", bookmark: "1"))
        try store.add(folder(path: "/Users/foo/Desktop", bookmark: "2"))
        let loaded = store.loadFolders()
        XCTAssertEqual(loaded.map { $0.originalPath }, ["/Users/foo/Projects", "/Users/foo/Desktop"])
    }
}
