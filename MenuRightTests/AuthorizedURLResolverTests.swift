import XCTest

final class AuthorizedURLResolverTests: XCTestCase {
    private func folder(_ path: String) -> AuthorizedFolder {
        AuthorizedFolder(
            displayName: (path as NSString).lastPathComponent,
            originalPath: path,
            bookmarkData: Data(path.utf8)
        )
    }

    private func match(_ folders: [AuthorizedFolder], _ target: String) -> AuthorizedFolder? {
        AuthorizedURLResolver.folderMatching(URL(fileURLWithPath: target), folders: folders)
    }

    func testHomeCoversDesktopDescendant() {
        let result = match([folder("/Users/foo")], "/Users/foo/Desktop/a.txt")
        XCTAssertEqual(result?.originalPath, "/Users/foo")
    }

    func testProjectsCoversDeepDescendant() {
        let result = match([folder("/Users/foo/Projects")], "/Users/foo/Projects/MenuRight/a.txt")
        XCTAssertEqual(result?.originalPath, "/Users/foo/Projects")
    }

    func testMostSpecificAuthorizationWins() {
        let result = match(
            [folder("/Users/foo"), folder("/Users/foo/Projects")],
            "/Users/foo/Projects/MenuRight/a.txt"
        )
        XCTAssertEqual(result?.originalPath, "/Users/foo/Projects")
    }

    func testGenericAuthorizationStillMatchesWhenSpecificExistsForOtherRegion() {
        // Projects target should prefer Projects; Desktop target falls back to Home.
        let folders = [folder("/Users/foo"), folder("/Users/foo/Projects")]
        XCTAssertEqual(match(folders, "/Users/foo/Projects/x.txt")?.originalPath, "/Users/foo/Projects")
        XCTAssertEqual(match(folders, "/Users/foo/Desktop/x.txt")?.originalPath, "/Users/foo")
    }

    func testNearPrefixDoesNotMatch() {
        let result = match([folder("/Users/foo/Project")], "/Users/foo/ProjectBackup/notes.txt")
        XCTAssertNil(result)
    }

    func testOutsideAuthorizationNoMatch() {
        let result = match([folder("/Users/foo")], "/Users/other/a.txt")
        XCTAssertNil(result)
    }

    func testExactContainerItselfMatches() {
        // Authorizing /Users/foo also covers operations in /Users/foo itself.
        let result = match([folder("/Users/foo")], "/Users/foo")
        XCTAssertEqual(result?.originalPath, "/Users/foo")
    }

    func testTrailingSlashIsInsensitive() {
        XCTAssertEqual(match([folder("/Users/foo/")], "/Users/foo/Desktop/a.txt")?.originalPath, "/Users/foo/")
    }

    func testSiblingOfSameNamePrefixNotMatched() {
        // /Users/foo/Desktop must not cover /Users/foo/Desktop2.
        XCTAssertNil(match([folder("/Users/foo/Desktop")], "/Users/foo/Desktop2/a.txt"))
    }

    // MARK: - contains / isDirectChild (M1 + M6 shared containment)

    func testContainsIsComponentWise() {
        let home = URL(fileURLWithPath: "/Users/foo")
        XCTAssertTrue(AuthorizedURLResolver.contains(home, URL(fileURLWithPath: "/Users/foo/barista")))
        XCTAssertTrue(AuthorizedURLResolver.contains(home, home), "a root contains itself")
        XCTAssertFalse(AuthorizedURLResolver.contains(URL(fileURLWithPath: "/Users/foo/bar"), URL(fileURLWithPath: "/Users/foo/barista/x")))
        XCTAssertFalse(AuthorizedURLResolver.contains(home, URL(fileURLWithPath: "/Users/foobar/x")))
    }

    func testContainsNormalizesTrailingSlashAndDotDot() {
        XCTAssertTrue(AuthorizedURLResolver.contains(
            URL(fileURLWithPath: "/Users/foo/"),
            URL(fileURLWithPath: "/Users/foo/Desktop/../Desktop/a.txt")
        ))
    }

    func testIsDirectChildAcceptsOnlyOneComponentBelow() {
        let dir = URL(fileURLWithPath: "/tmp/menuright-dir")
        XCTAssertTrue(AuthorizedURLResolver.isDirectChild(URL(fileURLWithPath: "/tmp/menuright-dir/Untitled.txt"), of: dir))
        XCTAssertTrue(AuthorizedURLResolver.isDirectChild(URL(fileURLWithPath: "/tmp/menuright-dir/sub/deep.txt"), of: URL(fileURLWithPath: "/tmp/menuright-dir/sub")))

        // Escape attempts must be rejected.
        XCTAssertFalse(AuthorizedURLResolver.isDirectChild(URL(fileURLWithPath: "/tmp/elsewhere.txt"), of: dir))
        XCTAssertFalse(AuthorizedURLResolver.isDirectChild(dir, of: dir), "the directory is not its own child")
        XCTAssertFalse(AuthorizedURLResolver.isDirectChild(URL(fileURLWithPath: "/tmp/menuright-dir2/x.txt"), of: dir))
    }

    func testIsDirectChildIsInsensitiveToTrailingSlash() {
        XCTAssertTrue(AuthorizedURLResolver.isDirectChild(
            URL(fileURLWithPath: "/tmp/menuright-dir/x.txt"),
            of: URL(fileURLWithPath: "/tmp/menuright-dir/")
        ))
    }
}
