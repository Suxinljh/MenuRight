import XCTest

/// A1 regression coverage through the Phase A2 menu plan API.
final class FinderMenuBuilderTests: XCTestCase {
    private func actions(_ plan: [FinderMenuPlanItem]) -> [FinderMenuAction] {
        plan.compactMap { item in
            if case .action(let action) = item { return action }
            return nil
        }
    }

    func testItemSelectionProducesCopyActionsAndCut() {
        let selection = FinderSelectionContext(
            itemURLs: [URL(fileURLWithPath: "/Users/foo/example.png")],
            targetedURL: nil
        )
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false)

        let copyActions = actions(plan).prefix(3)
        XCTAssertEqual(
            copyActions,
            [
                .copyName(payload: "example.png"),
                .copyPath(payload: "/Users/foo/example.png"),
                .copyFileURL(payload: "file:///Users/foo/example.png"),
            ]
        )
        XCTAssertNotNil(plan.first(where: { $0 == .separator }))
    }

    func testContainerBackgroundStillOffersCopyFolderPath() {
        let selection = FinderSelectionContext(
            itemURLs: [],
            targetedURL: URL(fileURLWithPath: "/Users/foo/My Project", isDirectory: true)
        )
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false)
        XCTAssertEqual(actions(plan).last, .copyFolderPath(payload: "/Users/foo/My Project"))
    }

    func testContainerMenuWithStaleSelectionStillBuildsContainerActions() {
        // A container right-click may report a stale selectedItemURLs() from the
        // window; the menu must follow the menu *kind*, not selection.hasSelection.
        let selection = FinderSelectionContext(
            itemURLs: [URL(fileURLWithPath: "/Users/suxin/Suxin")],
            targetedURL: URL(fileURLWithPath: "/Users/suxin/Suxin/code", isDirectory: true)
        )
        let plan = FinderMenuBuilder.plan(for: selection, containerMenu: true, hasCutPayload: false)

        XCTAssertFalse(
            actions(plan).contains(.cut(items: selection.itemURLs)),
            "container menu must not offer the item-cut action even with a stale selection"
        )
        XCTAssertEqual(actions(plan).last, .copyFolderPath(payload: "/Users/suxin/Suxin/code"))
        XCTAssertNotNil(plan.first(where: { item in
            if case .submenu(let title, _) = item { return title == "New File" }
            return false
        }))
    }

    func testEmptySelectionWithoutTargetProducesNoActions() {
        let selection = FinderSelectionContext(itemURLs: [], targetedURL: nil)
        XCTAssertTrue(FinderMenuBuilder.plan(for: selection, hasCutPayload: false).isEmpty)
    }

    func testNilTargetedURLWithSelectionStillUsesItemNames() {
        let selection = FinderSelectionContext(
            itemURLs: [URL(fileURLWithPath: "/Users/foo/notes/readme.txt")],
            targetedURL: nil
        )
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false)
        XCTAssertEqual(actions(plan).first, .copyName(payload: "readme.txt"))
    }
}
