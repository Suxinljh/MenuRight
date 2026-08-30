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
