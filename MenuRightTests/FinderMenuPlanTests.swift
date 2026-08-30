import XCTest

final class FinderMenuPlanTests: XCTestCase {
    private func actions(_ plan: [FinderMenuPlanItem]) -> [FinderMenuAction] {
        plan.compactMap { item in
            if case .action(let action) = item { return action }
            return nil
        }
    }

    // MARK: - Item selection menu

    func testItemSelectionHasCopyTrioSeparatorAndCut() {
        let selection = FinderSelectionContext(
            itemURLs: [URL(fileURLWithPath: "/Users/foo/example.png")],
            targetedURL: nil
        )
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false)

        XCTAssertEqual(plan.count, 5)
        XCTAssertEqual(plan[0], .action(.copyName(payload: "example.png")))
        XCTAssertEqual(plan[1], .action(.copyPath(payload: "/Users/foo/example.png")))
        XCTAssertEqual(plan[2], .action(.copyFileURL(payload: "file:///Users/foo/example.png")))
        XCTAssertEqual(plan[3], .separator)
        XCTAssertEqual(plan[4], .action(.cut(items: [URL(fileURLWithPath: "/Users/foo/example.png")])))
    }

    func testCutCarriesAllSelectedItems() {
        let urls = [
            URL(fileURLWithPath: "/Users/foo/a.txt"),
            URL(fileURLWithPath: "/Users/foo/报告.pdf"),
            URL(fileURLWithPath: "/Users/foo/😀.txt"),
        ]
        let selection = FinderSelectionContext(itemURLs: urls, targetedURL: nil)
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false)
        XCTAssertEqual(actions(plan).last, .cut(items: urls))
    }

    // MARK: - Container menu

    func testContainerMenuStructure() {
        let container = URL(fileURLWithPath: "/Users/foo/Projects", isDirectory: true)
        let selection = FinderSelectionContext(itemURLs: [], targetedURL: container)
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: true)

        XCTAssertEqual(plan.count, 6)
        guard case .submenu(let title, let submenuActions) = plan[0] else {
            return XCTFail("expected New File submenu")
        }
        XCTAssertEqual(title, "New File")
        XCTAssertEqual(
            submenuActions,
            [
                .newFile(kind: .text, directory: container),
                .newFile(kind: .markdown, directory: container),
                .newFile(kind: .json, directory: container),
            ]
        )
        XCTAssertEqual(plan[1], .action(.newFolder(directory: container)))
        XCTAssertEqual(plan[2], .separator)
        XCTAssertEqual(plan[3], .action(.pasteHere(destination: container, enabled: true)))
        XCTAssertEqual(plan[4], .separator)
        XCTAssertEqual(plan[5], .action(.copyFolderPath(payload: container.path)))
    }

    func testPasteHereDisabledWithoutCutPayload() {
        let container = URL(fileURLWithPath: "/Users/foo/Projects", isDirectory: true)
        let selection = FinderSelectionContext(itemURLs: [], targetedURL: container)
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false)
        XCTAssertEqual(plan[3], .action(.pasteHere(destination: container, enabled: false)))
    }

    func testEmptySelectionWithoutTargetProducesNoPlan() {
        let selection = FinderSelectionContext(itemURLs: [], targetedURL: nil)
        XCTAssertTrue(FinderMenuBuilder.plan(for: selection, hasCutPayload: false).isEmpty)
    }

    // MARK: - New file kinds

    func testNewFileKindMetadata() {
        XCTAssertEqual(NewFileKind.text.title, "Text File")
        XCTAssertEqual(NewFileKind.markdown.title, "Markdown File")
        XCTAssertEqual(NewFileKind.json.title, "JSON File")

        XCTAssertEqual(NewFileKind.text.defaultName, "Untitled.txt")
        XCTAssertEqual(NewFileKind.markdown.defaultName, "Untitled.md")
        XCTAssertEqual(NewFileKind.json.defaultName, "Untitled.json")

        XCTAssertNil(NewFileKind.text.contents)
        XCTAssertNil(NewFileKind.markdown.contents)
        XCTAssertEqual(NewFileKind.json.contents, Data("{}".utf8))
    }
}
