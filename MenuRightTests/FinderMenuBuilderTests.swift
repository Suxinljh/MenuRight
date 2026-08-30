import XCTest

final class FinderMenuBuilderTests: XCTestCase {
    func testItemSelectionProducesThreeCopyActions() {
        let selection = FinderSelectionContext(
            itemURLs: [URL(fileURLWithPath: "/Users/foo/example.png")],
            targetedURL: nil
        )
        let actions = FinderMenuBuilder.copyActions(for: selection)

        XCTAssertEqual(actions.count, 3)
        XCTAssertEqual(actions.map { $0.title }, ["Copy Name", "Copy Path", "Copy File URL"])
        XCTAssertEqual(actions[0].payload, "example.png")
        XCTAssertEqual(actions[1].payload, "/Users/foo/example.png")
        XCTAssertEqual(actions[2].payload, "file:///Users/foo/example.png")
    }

    func testContainerBackgroundSelectionProducesCopyFolderPath() {
        let selection = FinderSelectionContext(
            itemURLs: [],
            targetedURL: URL(fileURLWithPath: "/Users/foo/My Project", isDirectory: true)
        )
        let actions = FinderMenuBuilder.copyActions(for: selection)

        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].title, "Copy Folder Path")
        XCTAssertEqual(actions[0].payload, "/Users/foo/My Project")
    }

    func testEmptySelectionWithoutTargetProducesNoActions() {
        let selection = FinderSelectionContext(itemURLs: [], targetedURL: nil)
        XCTAssertTrue(FinderMenuBuilder.copyActions(for: selection).isEmpty)
    }

    func testNilTargetedURLWithSelectionStillUsesParentContainer() {
        let selection = FinderSelectionContext(
            itemURLs: [URL(fileURLWithPath: "/Users/foo/notes/readme.txt")],
            targetedURL: nil
        )
        let actions = FinderMenuBuilder.copyActions(for: selection)
        XCTAssertEqual(actions.count, 3)
        // The copy actions come from the selection, not the container.
        XCTAssertEqual(actions[0].payload, "readme.txt")
    }
}
