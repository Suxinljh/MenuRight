import XCTest

/// P6 menu-plan coverage (kept separate from the A1/A2 regression file).
final class FinderMenuPlanTests: XCTestCase {
    private func actions(_ plan: [FinderMenuPlanItem]) -> [FinderMenuAction] {
        plan.compactMap { item in
            if case .action(let action) = item { return action }
            return nil
        }
    }

    func testItemSelectionHasCopyTrioAndCut() {
        let items = [URL(fileURLWithPath: "/Users/foo/example.png")]
        let selection = FinderSelectionContext(itemURLs: items, targetedURL: nil)
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false)

        // 3 per-item actions + 3 copies + cut = 7, with no separator items:
        // Finder reserves a separator's slot but draws no rule in an extension menu.
        XCTAssertEqual(plan.count, 7)
        XCTAssertEqual(plan[0], .action(.createAlias(items: items)))
        XCTAssertEqual(plan[1], .action(.setLocked(items: items, locked: true)))
        XCTAssertEqual(plan[2], .action(.setLocked(items: items, locked: false)))
        XCTAssertEqual(plan[3], .action(.copyName(payload: "example.png")))
        XCTAssertEqual(plan[4], .action(.copyPath(payload: "/Users/foo/example.png")))
        XCTAssertEqual(plan[5], .action(.copyFileURL(payload: "file:///Users/foo/example.png")))
        XCTAssertEqual(plan[6], .action(.cut(items: items)))
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

        // No separators in the plan: Finder gives a separator its slot but draws
        // no rule, leaving a blank row. 6 items: terminal, 2 copies, New File ▸,
        // new folder, paste.
        XCTAssertEqual(plan.count, 6)
        guard case .submenu(let titleKey, let submenuActions) = plan[3] else {
            return XCTFail("expected New File submenu at index 3")
        }
        XCTAssertEqual(titleKey, .categoryNewFile)
        XCTAssertEqual(submenuActions.count, NewFileKind.allCases.count)
        XCTAssertEqual(submenuActions.first, .newFile(kind: .text, directory: container))
        XCTAssertEqual(plan[0], .action(.openTerminal(directory: container)))
        XCTAssertEqual(plan[5], .action(.pasteHere(destination: container, enabled: true)))
    }

    func testEmptySelectionWithoutTargetProducesNoPlan() {
        let selection = FinderSelectionContext(itemURLs: [], targetedURL: nil)
        XCTAssertTrue(FinderMenuBuilder.plan(for: selection, hasCutPayload: false).isEmpty)
    }

    // MARK: - New file kinds

    func testNewFileKindMetadata() {
        // Titles come from the shared catalog, so the submenu follows the
        // language selected in 通用设置.
        XCTAssertEqual(NewFileKind.text.title(in: .english), "Text File")
        XCTAssertEqual(NewFileKind.markdown.title(in: .english), "Markdown File")
        XCTAssertEqual(NewFileKind.html.title(in: .english), "HTML File")
        XCTAssertEqual(NewFileKind.css.title(in: .english), "CSS File")
        XCTAssertEqual(NewFileKind.javascript.title(in: .english), "JavaScript File")
        XCTAssertEqual(NewFileKind.json.title(in: .english), "JSON File")
        XCTAssertEqual(NewFileKind.text.title(in: .simplifiedChinese), "文本文件")
        XCTAssertEqual(NewFileKind.json.title(in: .simplifiedChinese), "JSON 文件")

        XCTAssertEqual(NewFileKind.text.defaultName, "Untitled.txt")
        XCTAssertEqual(NewFileKind.markdown.defaultName, "Untitled.md")
        XCTAssertEqual(NewFileKind.html.defaultName, "Untitled.html")
        XCTAssertEqual(NewFileKind.css.defaultName, "Untitled.css")
        XCTAssertEqual(NewFileKind.javascript.defaultName, "Untitled.js")
        XCTAssertEqual(NewFileKind.json.defaultName, "Untitled.json")
        // P6-b document kinds.
        XCTAssertEqual(NewFileKind.docx.defaultName, "Untitled.docx")
        XCTAssertEqual(NewFileKind.xlsx.defaultName, "Untitled.xlsx")
        XCTAssertEqual(NewFileKind.pptx.defaultName, "Untitled.pptx")
        XCTAssertEqual(NewFileKind.pages.defaultName, "Untitled.pages")
        XCTAssertEqual(NewFileKind.numbers.defaultName, "Untitled.numbers")
        XCTAssertEqual(NewFileKind.keynote.defaultName, "Untitled.key")
        XCTAssertEqual(NewFileKind.keynote.title(in: .simplifiedChinese), "Keynote 演示")
        XCTAssertEqual(NewFileKind.docx.title(in: .english), "Word Document")

        XCTAssertNil(NewFileKind.text.contents)
        XCTAssertNil(NewFileKind.markdown.contents)
        XCTAssertEqual(NewFileKind.json.contents, Data("{}".utf8))
        // Document kinds carry no bytes: the main app generates or copies them.
        for kind in [NewFileKind.docx, .xlsx, .pptx, .pages, .numbers, .keynote] {
            XCTAssertNil(kind.contents, "\(kind.rawValue) must be produced by the main app")
        }
    }

    // MARK: - P6-b availability

    func testTheSubmenuOffersOnlyKindsTheMainAppCanCreate() {
        let container = URL(fileURLWithPath: "/Users/foo/Projects", isDirectory: true)
        let selection = FinderSelectionContext(itemURLs: [], targetedURL: container)

        // Only Keynote has a template in this build.
        let availability = NewFileAvailability(creatableTypes: ["text", "markdown", "html", "css", "javascript",
                                                               "json", "docx", "xlsx", "pptx", "keynote"])
        let kinds = NewFileKind.available(from: availability)
        XCTAssertEqual(kinds, [.text, .markdown, .html, .css, .javascript, .json, .docx, .xlsx, .pptx, .keynote])

        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false, newFileKinds: kinds)
        guard case .submenu(_, let actions) = plan[3] else {
            return XCTFail("expected the New File submenu")
        }
        XCTAssertFalse(actions.contains(.newFile(kind: .pages, directory: container)))
        XCTAssertTrue(actions.contains(.newFile(kind: .keynote, directory: container)))
    }

    /// No payload yet (fresh install, or the app has not run since an update)
    /// must not produce a submenu whose items are guaranteed to fail.
    func testWithoutAPublishedPayloadOnlyTextKindsAreOffered() {
        XCTAssertEqual(NewFileKind.available(from: nil), NewFileKind.textKinds)

        let allText = Set(NewFileKind.textKinds)
        for kind in NewFileKind.available(from: nil) {
            XCTAssertTrue(allText.contains(kind), "\(kind.rawValue) should not be offered before the app publishes")
        }
    }

    /// Text kinds need nothing from the main app beyond a name, so they must
    /// survive even a payload that only lists document kinds.
    func testTextKindsStayAvailableEvenWithAnIncompletePayload() {
        let kinds = NewFileKind.available(from: NewFileAvailability(creatableTypes: ["docx"]))
        XCTAssertEqual(kinds, NewFileKind.textKinds + [.docx])
    }

    func testKindCategoriesMatchTheWireContract() {
        XCTAssertEqual(NewFileKind.text.category, .text)
        XCTAssertEqual(NewFileKind.docx.category, .office)
        XCTAssertEqual(NewFileKind.keynote.category, .iWork)
    }

    // MARK: - P7-b favorites

    private func submenus(_ plan: [FinderMenuPlanItem]) -> [(StringKey, [FinderMenuAction])] {
        plan.compactMap { item in
            if case .submenu(let key, let actions) = item { return (key, actions) }
            return nil
        }
    }

    func testFavoriteSubmenusFollowTheSpecOrderAndSkipEmptyLists() {
        let container = URL(fileURLWithPath: "/Users/foo/Projects", isDirectory: true)
        let selection = FinderSelectionContext(itemURLs: [], targetedURL: container)
        let favorites = [
            FinderFavoriteEntry(kind: .folder, menuTitle: "项目", target: "/Users/foo/Projects"),
            FinderFavoriteEntry(kind: .website, menuTitle: "GitHub", target: "https://github.com"),
            FinderFavoriteEntry(kind: .application, menuTitle: "Safari", target: "/Applications/Safari.app"),
        ]
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: true, favorites: favorites)
        let menus = submenus(plan)

        // New File first, then apps ▸ websites ▸ folders — the product spec order.
        XCTAssertEqual(menus.map(\.0), [
            .categoryNewFile,
            .categoryFavoriteApps,
            .categoryFavoriteWebsites,
            .categoryFavoriteFolders,
        ])
        XCTAssertEqual(menus[1].1, [.openFavorite(entry: favorites[2])])
        XCTAssertEqual(menus[2].1, [.openFavorite(entry: favorites[1])])
        XCTAssertEqual(menus[3].1, [.openFavorite(entry: favorites[0])])
        XCTAssertEqual(plan.count, 6 + 3, "the three favorites submenus come after Paste Here")
    }

    func testOnlyNonEmptyFavoriteListsGetASubmenu() {
        let container = URL(fileURLWithPath: "/Users/foo/Projects", isDirectory: true)
        let selection = FinderSelectionContext(itemURLs: [], targetedURL: container)
        let favorites = [FinderFavoriteEntry(kind: .website, menuTitle: "GitHub", target: "https://github.com")]
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false, favorites: favorites)

        XCTAssertEqual(submenus(plan).map(\.0), [.categoryNewFile, .categoryFavoriteWebsites])
    }

    /// An empty submenu is a dead end; the spec asks for it to be hidden.
    func testNoFavoritesMeansNoFavoriteSubmenus() {
        let container = URL(fileURLWithPath: "/Users/foo/Projects", isDirectory: true)
        let selection = FinderSelectionContext(itemURLs: [], targetedURL: container)
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false, favorites: [])

        XCTAssertEqual(submenus(plan).map(\.0), [.categoryNewFile])
        XCTAssertFalse(actions(plan).contains { action in
            if case .openFavorite = action { return true }
            return false
        })
    }

    /// The item-selection menu stays flat: favorites live in the background menu.
    func testSelectedItemsNeverOfferFavorites() {
        let items = [URL(fileURLWithPath: "/Users/foo/a.txt")]
        let selection = FinderSelectionContext(itemURLs: items, targetedURL: nil)
        let favorites = [FinderFavoriteEntry(kind: .folder, menuTitle: "项目", target: "/Users/foo/Projects")]
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: false, favorites: favorites)

        XCTAssertTrue(submenus(plan).isEmpty)
        XCTAssertFalse(actions(plan).contains { action in
            if case .openFavorite = action { return true }
            return false
        })
    }

    /// The title is the only key Finder replays, so the plan must render exactly
    /// the entries' (already unique) titles.
    func testFavoriteTitlesComeFromTheEntryItself() {
        let entry = FinderFavoriteEntry(kind: .website, menuTitle: "GitHub — github.com", target: "https://github.com")
        for language in [AppLanguage.simplifiedChinese, .english] {
            XCTAssertEqual(FinderMenuTitles.title(for: .openFavorite(entry: entry), language: language), entry.menuTitle)
        }
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
        let titles = NewFileKind.allCases.map { $0.title(in: .english) }
        let chineseTitles = NewFileKind.allCases.map { $0.title(in: .simplifiedChinese) }
        XCTAssertEqual(Set(names).count, names.count, "default names must be unique: \(names)")
        XCTAssertEqual(Set(titles).count, titles.count, "titles must be unique: \(titles)")
        // Title-based replay means duplicates would make a click ambiguous.
        XCTAssertEqual(Set(chineseTitles).count, chineseTitles.count, "中文标题必须唯一: \(chineseTitles)")
    }

    // MARK: - P9 解压/压缩 submenus

    private func submenu(_ key: StringKey, in plan: [FinderMenuPlanItem]) -> [FinderMenuAction]? {
        for item in plan {
            if case .submenu(let titleKey, let actions) = item, titleKey == key { return actions }
        }
        return nil
    }

    private func archiveSelection(_ urls: [URL]) -> FinderArchiveSelection {
        FinderArchiveSelection(archives: urls, compressible: urls)
    }

    private func plan(
        selecting urls: [URL],
        archives: FinderArchiveSelection? = nil,
        destination: FinderArchives.Destination = .ask,
        compressionFormats: [String] = FinderArchives.compressionFormats
    ) -> [FinderMenuPlanItem] {
        FinderMenuBuilder.plan(
            for: FinderSelectionContext(itemURLs: urls, targetedURL: nil),
            hasCutPayload: false,
            archives: archives ?? archiveSelection(urls),
            archiveDestination: destination,
            compressionFormats: compressionFormats
        )
    }

    func testExtractSubmenuAsksForADestinationByDefault() {
        let archives = [URL(fileURLWithPath: "/Users/foo/a.zip")]
        XCTAssertEqual(submenu(.finderMenuExtract, in: plan(selecting: archives)), [
            .extractArchives(archives: archives, destination: nil),
            .extractArchivesCustomize(archives: archives),
        ])
    }

    /// 解压位置 == 指定文件夹…: the second item goes straight there and its title
    /// names the folder, so no panel is needed.
    func testExtractSubmenuGoesStraightToTheChosenFolder() {
        let archives = [URL(fileURLWithPath: "/Users/foo/a.zip")]
        let folder = URL(fileURLWithPath: "/Users/foo/Downloads", isDirectory: true)
        XCTAssertEqual(submenu(.finderMenuExtract, in: plan(selecting: archives, destination: .folder(folder))), [
            .extractArchives(archives: archives, destination: nil),
            .extractArchivesToFolder(archives: archives, destination: folder),
        ])
    }

    /// 解压位置 == 压缩包所在文件夹 repeats the first item, so the menu offers one
    /// extraction item rather than two identical ones.
    func testExtractSubmenuDropsTheItemThatWouldDuplicateExtractHere() {
        let archives = [URL(fileURLWithPath: "/Users/foo/a.zip")]
        let items = submenu(.finderMenuExtract, in: plan(selecting: archives, destination: .duplicatesFirstItem))
        XCTAssertEqual(items, [.extractArchives(archives: archives, destination: nil)])
    }

    /// 解压到当前文件夹 is a literal promise: no setting may change what it does.
    func testExtractHereIsUnaffectedByTheDestinationSetting() {
        let archives = [URL(fileURLWithPath: "/Users/foo/a.zip")]
        for destination in [FinderArchives.Destination.ask,
                            .duplicatesFirstItem,
                            .folder(URL(fileURLWithPath: "/Users/foo/Downloads", isDirectory: true))] {
            let items = submenu(.finderMenuExtract, in: plan(selecting: archives, destination: destination))
            XCTAssertEqual(items?.first, .extractArchives(archives: archives, destination: nil), "\(destination)")
        }
    }

    func testCompressionSubmenuFollowsTheAllowedFormats() {
        let files = [URL(fileURLWithPath: "/Users/foo/report.pdf")]
        XCTAssertEqual(
            submenu(.finderMenuCompress, in: plan(
                selecting: files,
                archives: FinderArchiveSelection(archives: [], compressible: files),
                compressionFormats: ["zip", "bzip2"]
            )),
            [
                .compressItems(items: files, format: "zip"),
                .compressItems(items: files, format: "bzip2"),
                .compressItemsCustomize(items: files),
            ]
        )
    }

    /// No writable format left enabled: 自定义压缩… is still the way in, so the
    /// submenu must not vanish.
    func testCompressionSubmenuKeepsTheDialogWhenNoFormatIsAllowed() {
        let files = [URL(fileURLWithPath: "/Users/foo/report.pdf")]
        XCTAssertEqual(
            submenu(.finderMenuCompress, in: plan(
                selecting: files,
                archives: FinderArchiveSelection(archives: [], compressible: files),
                compressionFormats: []
            )),
            [.compressItemsCustomize(items: files)]
        )
    }

    // MARK: - Title round-trip for the configured folder

    func testConfiguredFolderTitleNamesTheFolderAndRoundTrips() {
        for language in [AppLanguage.simplifiedChinese, .english] {
            let title = FinderMenuTitles.extractToFolderTitle(folderName: "下载", language: language)
            XCTAssertTrue(title.contains("下载"), "\(language): \(title)")
            XCTAssertTrue(
                FinderMenuTitles.isConfiguredFolderExtractionTitle(title, folderName: "下载"),
                "\(language): the click must be recognised again"
            )
            XCTAssertFalse(
                FinderMenuTitles.isConfiguredFolderExtractionTitle(title, folderName: "文稿"),
                "\(language): a different folder must not match"
            )
        }
    }

    /// The configured-folder title must never be mistaken for the panel item.
    func testConfiguredFolderTitleIsNotThePanelTitle() {
        let title = FinderMenuTitles.extractToFolderTitle(folderName: "下载", language: .simplifiedChinese)
        XCTAssertFalse(FinderMenuTitles.isCustomExtractionTitle(title))
        XCTAssertFalse(FinderMenuTitles.isExtractHereTitle(title))
    }

    func testExtractHereTitleRoundTrips() {
        for language in [AppLanguage.simplifiedChinese, .english] {
            let title = Localization.text(.finderMenuExtractHere, language: language)
            XCTAssertTrue(FinderMenuTitles.isExtractHereTitle(title), "\(language)")
            XCTAssertFalse(FinderMenuTitles.isCustomExtractionTitle(title), "\(language)")
        }
    }
}
