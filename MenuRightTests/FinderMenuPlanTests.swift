import XCTest

/// P6 menu-plan coverage (kept separate from the A1/A2 regression file).
final class FinderMenuPlanTests: XCTestCase {
    private func actions(_ plan: [FinderMenuPlanItem]) -> [FinderMenuAction] {
        plan.compactMap { item in
            if case .action(let action) = item { return action }
            return nil
        }
    }

    func testItemSelectionHasCopyTrioSeparatorAndCut() {
        let items = [URL(fileURLWithPath: "/Users/foo/example.png")]
        let selection = FinderSelectionContext(itemURLs: items, targetedURL: nil)
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false)

        // 3 per-item actions + separator + 3 copies + separator + cut = 9
        XCTAssertEqual(plan.count, 9)
        XCTAssertEqual(plan[3], .separator)
        XCTAssertEqual(plan[4], .action(.copyName(payload: "example.png")))
        XCTAssertEqual(plan[5], .action(.copyPath(payload: "/Users/foo/example.png")))
        XCTAssertEqual(plan[6], .action(.copyFileURL(payload: "file:///Users/foo/example.png")))
        XCTAssertEqual(plan[7], .separator)
        XCTAssertEqual(plan[8], .action(.cut(items: items)))
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

    func testContainerMenuStructure() {
        let container = URL(fileURLWithPath: "/Users/foo/Projects", isDirectory: true)
        let selection = FinderSelectionContext(itemURLs: [], targetedURL: container)
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: true)

        guard case .submenu(let title, let submenuActions) = plan[4] else {
            return XCTFail("expected New File submenu at index 4")
        }
        XCTAssertEqual(title, "New File")
        XCTAssertEqual(submenuActions.count, NewFileKind.allCases.count)
        XCTAssertEqual(submenuActions.first, .newFile(kind: .text, directory: container))
        XCTAssertEqual(plan[0], .action(.openTerminal(directory: container)))
        XCTAssertEqual(plan[7], .action(.pasteHere(destination: container, enabled: true)))
    }

    func testEmptySelectionWithoutTargetProducesNoPlan() {
        let selection = FinderSelectionContext(itemURLs: [], targetedURL: nil)
        XCTAssertTrue(FinderMenuBuilder.plan(for: selection, hasCutPayload: false).isEmpty)
    }

    // MARK: - New file kinds

    func testNewFileKindMetadata() {
        XCTAssertEqual(NewFileKind.text.title, "Text File")
        XCTAssertEqual(NewFileKind.markdown.title, "Markdown File")
        XCTAssertEqual(NewFileKind.html.title, "HTML File")
        XCTAssertEqual(NewFileKind.css.title, "CSS File")
        XCTAssertEqual(NewFileKind.javascript.title, "JavaScript File")
        XCTAssertEqual(NewFileKind.json.title, "JSON File")

        XCTAssertEqual(NewFileKind.text.defaultName, "Untitled.txt")
        XCTAssertEqual(NewFileKind.markdown.defaultName, "Untitled.md")
        XCTAssertEqual(NewFileKind.html.defaultName, "Untitled.html")
        XCTAssertEqual(NewFileKind.css.defaultName, "Untitled.css")
        XCTAssertEqual(NewFileKind.javascript.defaultName, "Untitled.js")
        XCTAssertEqual(NewFileKind.json.defaultName, "Untitled.json")

        XCTAssertNil(NewFileKind.text.contents)
        XCTAssertNil(NewFileKind.markdown.contents)
        XCTAssertEqual(NewFileKind.json.contents, Data("{}".utf8))
    }

    func testCodeFormatsGetUsableSkeletonsNotEmptyFiles() throws {
        let html = try XCTUnwrap(NewFileKind.html.contents)
        let htmlText = try XCTUnwrap(String(data: html, encoding: .utf8))
        XCTAssertTrue(htmlText.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(htmlText.contains("<body>"))

        let css = try XCTUnwrap(String(data: try XCTUnwrap(NewFileKind.css.contents), encoding: .utf8))
        XCTAssertTrue(css.contains("{"))

        let js = try XCTUnwrap(String(data: try XCTUnwrap(NewFileKind.javascript.contents), encoding: .utf8))
        XCTAssertTrue(js.contains("use strict"))
    }

    func testNewFileKindsAreUniquelyNamedAndTitled() {
        let names = NewFileKind.allCases.map(\.defaultName)
        let titles = NewFileKind.allCases.map(\.title)
        XCTAssertEqual(Set(names).count, names.count, "default names must be unique: \(names)")
        XCTAssertEqual(Set(titles).count, titles.count, "titles must be unique: \(titles)")
    }
}
