import XCTest

/// Menu-contract coverage for the P6 layout.
///
/// The item-selection menu is deliberately flat (no submenus): macOS renders it
/// inside MenuRight's own Finder entry, and a flat menu is the only way to avoid
/// showing a cascade once items are selected.
final class FinderMenuBuilderTests: XCTestCase {
    private func actions(_ plan: [FinderMenuPlanItem]) -> [FinderMenuAction] {
        plan.compactMap { item in
            if case .action(let action) = item { return action }
            return nil
        }
    }

    private func submenuTitles(_ plan: [FinderMenuPlanItem]) -> [String] {
        plan.compactMap { item in
            if case .submenu(let title, _) = item { return title }
            return nil
        }
    }

    // MARK: - Item selection

    func testItemSelectionStartsWithAliasAndLockThenCopyTrioThenCut() {
        let items = [URL(fileURLWithPath: "/Users/foo/example.png")]
        let selection = FinderSelectionContext(itemURLs: items, targetedURL: nil)
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false)

        XCTAssertEqual(actions(plan), [
            .createAlias(items: items),
            .setLocked(items: items, locked: true),
            .setLocked(items: items, locked: false),
            .copyName(payload: "example.png"),
            .copyPath(payload: "/Users/foo/example.png"),
            .copyFileURL(payload: "file:///Users/foo/example.png"),
            .cut(items: items),
        ])
    }

    func testItemSelectionMenuIsCompletelyFlat() {
        // No submenus at all in the selection case: "no cascade once selected".
        let selection = FinderSelectionContext(
            itemURLs: [URL(fileURLWithPath: "/Users/foo/a.txt")],
            targetedURL: nil
        )
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false)
        XCTAssertTrue(submenuTitles(plan).isEmpty)
    }

    func testItemSelectionDoesNotOfferContainerActions() {
        let selection = FinderSelectionContext(
            itemURLs: [URL(fileURLWithPath: "/Users/foo/a.txt")],
            targetedURL: URL(fileURLWithPath: "/Users/foo", isDirectory: true)
        )
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false)
        XCTAssertFalse(actions(plan).contains { action in
            if case .openTerminal = action { return true }
            return false
        })
        XCTAssertFalse(actions(plan).contains { action in
            if case .newFile = action { return true }
            return false
        })
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
        XCTAssertEqual(
            actions(plan).first,
            .createAlias(items: urls),
            "per-item actions must carry the whole selection"
        )
    }

    func testNilTargetedURLWithSelectionStillUsesItemNames() {
        let selection = FinderSelectionContext(
            itemURLs: [URL(fileURLWithPath: "/Users/foo/notes/readme.txt")],
            targetedURL: nil
        )
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false)
        XCTAssertTrue(actions(plan).contains(.copyName(payload: "readme.txt")))
    }

    // MARK: - Container

    func testContainerMenuOrderAndContents() {
        let container = URL(fileURLWithPath: "/Users/foo/My Project", isDirectory: true)
        let selection = FinderSelectionContext(itemURLs: [], targetedURL: container)
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: true)

        XCTAssertEqual(plan.count, 8)
        XCTAssertEqual(plan[0], .action(.openTerminal(directory: container)))
        XCTAssertEqual(plan[1], .action(.copyFolderName(payload: "My Project")))
        XCTAssertEqual(plan[2], .action(.copyFolderPath(payload: "/Users/foo/My Project")))
        XCTAssertEqual(plan[3], .separator)

        guard case .submenu(let title, let submenuActions) = plan[4] else {
            return XCTFail("expected the New File submenu")
        }
        XCTAssertEqual(title, "New File")
        XCTAssertEqual(submenuActions, NewFileKind.allCases.map { .newFile(kind: $0, directory: container) })

        XCTAssertEqual(plan[5], .action(.newFolder(directory: container)))
        XCTAssertEqual(plan[6], .separator)
        XCTAssertEqual(plan[7], .action(.pasteHere(destination: container, enabled: true)))
    }

    func testContainerMenuOffersNoItemActions() {
        let container = URL(fileURLWithPath: "/Users/foo/Projects", isDirectory: true)
        let selection = FinderSelectionContext(itemURLs: [], targetedURL: container)
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false)
        XCTAssertFalse(actions(plan).contains { action in
            if case .createAlias = action { return true }
            if case .setLocked = action { return true }
            if case .cut = action { return true }
            return false
        })
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
            "container menu must not offer item actions even with a stale selection"
        )
        XCTAssertEqual(actions(plan).last, .pasteHere(destination: URL(fileURLWithPath: "/Users/suxin/Suxin/code", isDirectory: true), enabled: false))
        XCTAssertTrue(submenuTitles(plan).contains("New File"))
    }

    func testPasteHereDisabledWithoutCutPayload() {
        let container = URL(fileURLWithPath: "/Users/foo/Projects", isDirectory: true)
        let selection = FinderSelectionContext(itemURLs: [], targetedURL: container)
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false)
        XCTAssertTrue(actions(plan).contains(.pasteHere(destination: container, enabled: false)))
    }

    func testEmptySelectionWithoutTargetProducesNoActions() {
        let selection = FinderSelectionContext(itemURLs: [], targetedURL: nil)
        XCTAssertTrue(FinderMenuBuilder.plan(for: selection, hasCutPayload: false).isEmpty)
    }

    // MARK: - Titles shared with the action dispatch

    func testActionTitlesAreStableBecauseFinderSyncDispatchesOnThem() {
        XCTAssertEqual(FinderMenuTitles.createAlias, "Create Alias")
        XCTAssertEqual(FinderMenuTitles.lock, "Lock")
        XCTAssertEqual(FinderMenuTitles.unlock, "Unlock")
        XCTAssertEqual(FinderMenuTitles.openTerminal, "Open Terminal")
        XCTAssertNotEqual(FinderMenuTitles.lock, FinderMenuTitles.unlock)
    }
}
