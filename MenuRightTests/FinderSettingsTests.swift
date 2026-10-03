import XCTest

/// **P7** App-Group coverage for the extension-side settings view: the payload
/// the main app publishes must turn into menu filtering (文件权限), ordering and
/// naming (新建文件) — and a missing payload must never empty the menu.
final class FinderSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "xin.ljhsu.MenuRight.tests.FinderSettings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func write(_ json: String) {
        defaults.set(Data(json.utf8), forKey: FinderSettings.storageKey)
    }

    // MARK: - Reading

    /// An extension that starts before the app ever wrote settings must offer the
    /// full menu, not an empty one.
    func testMissingPayloadIsPermissive() {
        let read = FinderSettings.read(from: defaults)
        XCTAssertEqual(read.permissions, .permissive)
        XCTAssertEqual(read.newFile, .default)
        XCTAssertTrue(read.permissions.allows("createAlias"))
        XCTAssertTrue(read.permissions.allows("compressArchive"))
        XCTAssertNil(read.permissions.allowedActions)
    }

    func testGarbagePayloadIsPermissive() {
        defaults.set(Data("not json".utf8), forKey: FinderSettings.storageKey)
        XCTAssertEqual(FinderSettings.read(from: defaults).permissions, .permissive)
        XCTAssertEqual(FinderSettings.read(from: defaults).newFile, .default)
    }

    func testFilePermissionsAndNewFileFieldsDecode() {
        write(
            """
            {
              "filePermissions": {
                "allowedActions": ["createFile", "copyName"],
                "restrictToAuthorizedFolders": false,
                "confirmDestructiveActions": false
              },
              "newFile": {
                "baseName": "  Note  ",
                "types": ["markdown", "text"],
                "enabledTypes": ["markdown"]
              }
            }
            """
        )

        let read = FinderSettings.read(from: defaults)
        XCTAssertEqual(read.permissions.allowedActions, ["createFile", "copyName"])
        XCTAssertFalse(read.permissions.restrictToAuthorizedFolders)
        XCTAssertFalse(read.permissions.confirmDestructiveActions)
        XCTAssertTrue(read.permissions.allows("createFile"))
        XCTAssertFalse(read.permissions.allows("createAlias"))

        XCTAssertEqual(read.newFile.orderedTypes, ["markdown", "text"])
        XCTAssertEqual(read.newFile.enabledTypes, ["markdown"])
        XCTAssertTrue(read.newFile.isEnabled("markdown"))
        XCTAssertFalse(read.newFile.isEnabled("text"))
        XCTAssertEqual(read.newFile.effectiveBaseName, "Note")
    }

    /// A payload from a build that did not know a field yet keeps the safe
    /// defaults instead of switching everything off.
    func testPartialPayloadKeepsSafeDefaults() {
        write(
            """
            { "filePermissions": { "allowedActions": ["createFolder"] } }
            """
        )
        let read = FinderSettings.read(from: defaults)
        XCTAssertTrue(read.permissions.restrictToAuthorizedFolders)
        XCTAssertTrue(read.permissions.confirmDestructiveActions)
        XCTAssertEqual(read.newFile, .default)
    }

    func testBlankBaseNameFallsBackToUntitled() {
        XCTAssertEqual(FinderSettings.NewFileMenu.default.effectiveBaseName, "Untitled")

        var menu = FinderSettings.NewFileMenu.default
        menu.baseName = "   \n "
        XCTAssertEqual(menu.effectiveBaseName, "Untitled")
    }

    // MARK: - Naming

    func testDefaultNameUsesTheConfiguredBaseName() {
        XCTAssertEqual(NewFileKind.markdown.defaultName(baseName: "Note"), "Note.md")
        XCTAssertEqual(NewFileKind.keynote.defaultName(baseName: "Deck"), "Deck.key")
        XCTAssertEqual(NewFileKind.text.defaultName(baseName: "  "), "Untitled.txt")
        XCTAssertEqual(NewFileKind.text.defaultName, "Untitled.txt")
        XCTAssertEqual(NewFileKind.text.defaultName, NewFileKind.text.defaultName(baseName: "Untitled"))
    }

    // MARK: - 新建文件 ▸ ordering and filtering

    func testMenuKindsFiltersSwitchedOffTypesAndFollowsTheConfiguredOrder() {
        let availability = NewFileAvailability(creatableTypes: ["docx", "pages"])
        var settings = FinderSettings.NewFileMenu.default
        settings.enabledTypes = ["text", "markdown", "docx", "pages"]
        settings.orderedTypes = ["pages", "markdown"]

        let kinds = FinderMenuBuilder.menuKinds(availability: availability, settings: settings)

        // Ordered types first (in the user's order), then the rest in catalog order.
        XCTAssertEqual(kinds, [.pages, .markdown, .text, .docx])
    }

    func testMenuKindsIgnoresUnknownAndDuplicateOrderEntries() {
        let availability = NewFileAvailability(creatableTypes: [])
        var settings = FinderSettings.NewFileMenu.default
        settings.orderedTypes = ["docx", "markdown", "markdown", "nosuchkind"]

        let kinds = FinderMenuBuilder.menuKinds(availability: availability, settings: settings)

        // docx is not creatable here, so it drops out; markdown keeps one slot.
        XCTAssertEqual(kinds.first, .markdown)
        XCTAssertEqual(Set(kinds), Set(NewFileKind.textKinds))
        XCTAssertEqual(kinds.count, NewFileKind.textKinds.count)
    }

    func testMenuKindsWithoutAvailabilityKeepsTheTextKinds() {
        let kinds = FinderMenuBuilder.menuKinds(
            availability: nil,
            settings: FinderSettings.NewFileMenu.default
        )
        XCTAssertEqual(kinds, NewFileKind.textKinds)
    }

    // MARK: - 文件权限 filtering

    private func permissions(_ allowed: [String]) -> FinderSettings.Permissions {
        FinderSettings.Permissions(
            allowedActions: Set(allowed),
            restrictToAuthorizedFolders: true,
            confirmDestructiveActions: true
        )
    }

    private func selection(_ paths: [String]) -> FinderSelectionContext {
        FinderSelectionContext(
            itemURLs: paths.map { URL(fileURLWithPath: $0) },
            targetedURL: nil
        )
    }

    private func container(_ path: String) -> FinderSelectionContext {
        FinderSelectionContext(
            itemURLs: [],
            targetedURL: URL(fileURLWithPath: path, isDirectory: true)
        )
    }

    func testSelectionPlanKeepsOnlyTheAllowedActions() {
        let items = selection(["/Users/foo/a.txt"])
        let plan = FinderMenuBuilder.plan(
            for: items,
            hasCutPayload: false,
            permissions: permissions(["copyName", "copyPath"])
        )

        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0], .action(.copyName(payload: "a.txt")))
        XCTAssertEqual(plan[1], .action(.copyPath(payload: "/Users/foo/a.txt")))
    }

    func testSwitchingEveryActionOffLeavesNoSelectionMenu() {
        let plan = FinderMenuBuilder.plan(
            for: selection(["/Users/foo/a.txt"]),
            hasCutPayload: false,
            permissions: permissions([])
        )
        XCTAssertTrue(plan.isEmpty)
    }

    /// The archive submenus are filtered through the same switch as the flat
    /// items, so 解压 ▸ / 压缩 ▸ disappear when their action is off.
    func testArchiveSubmenusRespectTheirSwitches() {
        let archives = FinderArchiveSelection(
            archives: [URL(fileURLWithPath: "/Users/foo/a.zip")],
            compressible: [URL(fileURLWithPath: "/Users/foo/a.zip")]
        )
        let withoutExtract = FinderMenuBuilder.plan(
            for: selection(["/Users/foo/a.zip"]),
            hasCutPayload: false,
            archives: archives,
            permissions: permissions(["compressArchive"])
        )
        XCTAssertFalse(withoutExtract.contains { if case .submenu(.finderMenuExtract, _) = $0 { return true } else { return false } })
        XCTAssertTrue(withoutExtract.contains { if case .submenu(.finderMenuCompress, _) = $0 { return true } else { return false } })

        let withoutCompress = FinderMenuBuilder.plan(
            for: selection(["/Users/foo/a.zip"]),
            hasCutPayload: false,
            archives: archives,
            permissions: permissions(["extractArchive"])
        )
        XCTAssertFalse(withoutCompress.contains { if case .submenu(.finderMenuCompress, _) = $0 { return true } else { return false } })
        XCTAssertTrue(withoutCompress.contains { if case .submenu(.finderMenuExtract, _) = $0 { return true } else { return false } })
    }

    func testContainerPlanDropsTerminalAndHidesEmptyNewFileSubmenu() {
        let plan = FinderMenuBuilder.plan(
            for: container("/Users/foo/Projects"),
            containerMenu: true,
            hasCutPayload: true,
            permissions: permissions(["copyName", "copyPath", "createFolder", "cutPaste", "openFavorite"])
        )

        // A directory URL carries `hasDirectoryPath`, which is part of URL
        // equality — compare against the same shape `container(_:)` builds.
        let projects = URL(fileURLWithPath: "/Users/foo/Projects", isDirectory: true)
        XCTAssertFalse(plan.contains(.action(.openTerminal(directory: projects))))
        XCTAssertFalse(plan.contains { if case .submenu(.categoryNewFile, _) = $0 { return true } else { return false } })
        XCTAssertTrue(plan.contains(.action(.newFolder(directory: projects))))
    }

    func testContainerPlanHidesFavoritesSubmenusWhenOpenFavoriteIsOff() {
        let favorites = [
            FinderFavoriteEntry(kind: .application, menuTitle: "Terminal", target: "/Applications/Utilities/Terminal.app"),
            FinderFavoriteEntry(kind: .website, menuTitle: "Apple", target: "https://apple.com"),
        ]
        let plan = FinderMenuBuilder.plan(
            for: container("/Users/foo/Projects"),
            containerMenu: true,
            hasCutPayload: false,
            favorites: favorites,
            permissions: permissions(["createFile"])
        )

        XCTAssertFalse(plan.contains { if case .submenu(.categoryFavoriteApps, _) = $0 { return true } else { return false } })
        XCTAssertFalse(plan.contains { if case .submenu(.categoryFavoriteWebsites, _) = $0 { return true } else { return false } })
    }

    func testDefaultPermissionsKeepTheWholeMenu() {
        let all = Set(FileAction.allCases.map(\.rawValue))
        let filtered = FinderMenuBuilder.plan(
            for: selection(["/Users/foo/a.txt"]),
            hasCutPayload: false,
            permissions: permissions(Array(all))
        )
        let unfiltered = FinderMenuBuilder.plan(for: selection(["/Users/foo/a.txt"]), hasCutPayload: false)
        XCTAssertEqual(filtered, unfiltered)
        XCTAssertEqual(FinderMenuBuilder.plan(for: selection(["/Users/foo/a.txt"]), hasCutPayload: false, permissions: .permissive), unfiltered)
    }

    // MARK: - The raw strings the extension hard-codes

    /// The extension cannot see `FileAction`, so `permissionKey(for:)` spells the
    /// raw values out by hand. This pins every one of them against the app-side
    /// enum: adding a `FileAction` case breaks this test instead of silently
    /// producing a switch that nothing can turn off.
    func testPermissionKeysCoverEveryFileActionRawValue() {
        let probe: [FinderMenuAction] = [
            .createAlias(items: []),
            .setLocked(items: [], locked: true),
            .copyName(payload: ""),
            .copyPath(payload: ""),
            .copyFileURL(payload: ""),
            .cut(items: []),
            .pasteHere(destination: URL(fileURLWithPath: "/"), enabled: false),
            .newFile(kind: .text, directory: URL(fileURLWithPath: "/")),
            .newFolder(directory: URL(fileURLWithPath: "/")),
            .openTerminal(directory: URL(fileURLWithPath: "/")),
            .openFavorite(entry: FinderFavoriteEntry(kind: .website, menuTitle: "x", target: "https://example.com")),
            .extractArchives(archives: [], destination: nil),
            .extractArchivesCustomize(archives: []),
            .extractArchivesToFolder(archives: [], destination: URL(fileURLWithPath: "/")),
            .compressItems(items: [], format: "zip"),
            .compressItemsCustomize(items: []),
        ]

        let keys = Set(probe.compactMap { FinderMenuBuilder.permissionKey(for: $0) })
        let actions = Set(FileAction.allCases.map(\.rawValue))

        XCTAssertEqual(keys, actions)
        XCTAssertEqual(probe.count, 16, "a new FinderMenuAction case needs a mapping here")
    }
}
