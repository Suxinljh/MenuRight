import XCTest

final class FinderSelectionContextTests: XCTestCase {
    private let nl = String(UnicodeScalar(10))

    // MARK: - Names

    func testSingleFileName() {
        let context = FinderSelectionContext(
            itemURLs: [URL(fileURLWithPath: "/Users/foo/Projects/MenuRight/example.png")],
            targetedURL: nil
        )
        XCTAssertEqual(context.formattedNames, "example.png")
    }

    func testMultipleFileNamesOnePerLine() {
        let context = FinderSelectionContext(
            itemURLs: [
                URL(fileURLWithPath: "/Users/foo/example.png"),
                URL(fileURLWithPath: "/Users/foo/README.md"),
                URL(fileURLWithPath: "/Users/foo/MenuRight.xcodeproj"),
            ],
            targetedURL: nil
        )
        XCTAssertEqual(
            context.formattedNames,
            "example.png" + nl + "README.md" + nl + "MenuRight.xcodeproj"
        )
    }

    func testNamesWithUnicodeChineseSpacesEmoji() {
        let context = FinderSelectionContext(
            itemURLs: [
                URL(fileURLWithPath: "/Users/foo/报告 2025.pdf"),
                URL(fileURLWithPath: "/Users/foo/😀 照片.JPG"),
            ],
            targetedURL: nil
        )
        XCTAssertEqual(context.formattedNames, "报告 2025.pdf" + nl + "😀 照片.JPG")
    }

    // MARK: - Paths

    func testSingleFilePathAbsoluteNoScheme() {
        let context = FinderSelectionContext(
            itemURLs: [URL(fileURLWithPath: "/Users/foo/Projects/MenuRight/README.md")],
            targetedURL: nil
        )
        XCTAssertEqual(context.formattedPaths, "/Users/foo/Projects/MenuRight/README.md")
        XCTAssertFalse(context.formattedPaths.contains("file://"))
        XCTAssertTrue(context.formattedPaths.hasPrefix("/"))
    }

    func testMultipleFilePathsOnePerLine() {
        let context = FinderSelectionContext(
            itemURLs: [
                URL(fileURLWithPath: "/Users/foo/a.txt"),
                URL(fileURLWithPath: "/Users/foo/b.txt"),
            ],
            targetedURL: nil
        )
        XCTAssertEqual(context.formattedPaths, "/Users/foo/a.txt" + nl + "/Users/foo/b.txt")
    }

    // MARK: - File URLs

    func testSingleFileURL() {
        let context = FinderSelectionContext(
            itemURLs: [URL(fileURLWithPath: "/Users/foo/Projects/MenuRight/README.md")],
            targetedURL: nil
        )
        XCTAssertEqual(
            context.formattedFileURLs,
            "file:///Users/foo/Projects/MenuRight/README.md"
        )
    }

    func testFileURLPercentEncodingForSpaces() {
        let context = FinderSelectionContext(
            itemURLs: [URL(fileURLWithPath: "/Users/foo/My Project/notes.txt")],
            targetedURL: nil
        )
        XCTAssertEqual(context.formattedFileURLs, "file:///Users/foo/My%20Project/notes.txt")
    }

    func testFileURLPercentEncodingForChineseAndEmoji() {
        let context = FinderSelectionContext(
            itemURLs: [
                URL(fileURLWithPath: "/Users/foo/中文 文件.pdf"),
                URL(fileURLWithPath: "/Users/foo/emoji-😀.txt"),
            ],
            targetedURL: nil
        )
        XCTAssertEqual(
            context.formattedFileURLs,
            "file:///Users/foo/%E4%B8%AD%E6%96%87%20%E6%96%87%E4%BB%B6.pdf"
                + nl
                + "file:///Users/foo/emoji-%F0%9F%98%80.txt"
        )
    }

    // MARK: - Selection shape

    func testCountAndHasSelection() {
        let empty = FinderSelectionContext(itemURLs: [], targetedURL: nil)
        XCTAssertFalse(empty.hasSelection)
        XCTAssertEqual(empty.selectionCount, 0)

        let one = FinderSelectionContext(
            itemURLs: [URL(fileURLWithPath: "/Users/foo/a.txt")],
            targetedURL: nil
        )
        XCTAssertTrue(one.hasSelection)
        XCTAssertEqual(one.selectionCount, 1)
    }

    func testFormattingWorksForURLThatNoLongerExists() {
        // Formatting only uses URL metadata; a stale/nonexistent URL must not crash.
        let stale = FinderSelectionContext(
            itemURLs: [URL(fileURLWithPath: "/Users/foo/deleted-file.txt")],
            targetedURL: nil
        )
        XCTAssertEqual(stale.formattedNames, "deleted-file.txt")
        XCTAssertEqual(stale.formattedPaths, "/Users/foo/deleted-file.txt")
        XCTAssertEqual(stale.formattedFileURLs, "file:///Users/foo/deleted-file.txt")
    }

    // MARK: - Container

    func testContainerDirectoryFromTargetedURL() {
        let context = FinderSelectionContext(
            itemURLs: [],
            targetedURL: URL(fileURLWithPath: "/Users/foo/Projects", isDirectory: true)
        )
        XCTAssertEqual(context.containerDirectory?.path, "/Users/foo/Projects")
    }

    func testContainerDirectoryFallsBackToParentOfFirstItem() {
        let context = FinderSelectionContext(
            itemURLs: [URL(fileURLWithPath: "/Users/foo/Projects/a.txt")],
            targetedURL: nil
        )
        XCTAssertEqual(context.containerDirectory?.path, "/Users/foo/Projects")
    }

    func testContainerDirectoryIsNilWhenNothingAvailable() {
        let context = FinderSelectionContext(itemURLs: [], targetedURL: nil)
        XCTAssertNil(context.containerDirectory)
    }
}
