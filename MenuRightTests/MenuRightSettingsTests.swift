import XCTest

/// Pure-model coverage for the settings tree: defaults, catalogs, favorite
/// editing rules, and the normalization that keeps stored payloads valid.
final class MenuRightSettingsTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultSettingsAreSelfConsistent() {
        let settings = MenuRightSettings.default
        XCTAssertEqual(settings.schemaVersion, MenuRightSettings.currentSchemaVersion)
        XCTAssertEqual(settings.newFile.types, NewFileType.allCases)
        XCTAssertEqual(settings.newFile.enabledTypes, Set(NewFileType.allCases))
        XCTAssertEqual(settings.filePermissions.allowedActions, Set(FileAction.allCases))
        XCTAssertTrue(settings.filePermissions.restrictToAuthorizedFolders)
        XCTAssertTrue(settings.filePermissions.confirmDestructiveActions)
        XCTAssertEqual(settings.codeTheme.themeID, CodeThemeCatalog.systemID)
        XCTAssertEqual(settings.archives.sizeLimitMB, ArchiveSettings.defaultSizeLimitMB)
    }

    func testDefaultIsAlreadyNormalized() {
        XCTAssertEqual(MenuRightSettings().normalized(), MenuRightSettings.default)
    }

    // MARK: - New file catalog

    func testNewFileExtensionsAreUniqueAndNonEmpty() {
        var seen = Set<String>()
        for type in NewFileType.allCases {
            XCTAssertFalse(type.fileExtension.isEmpty, "\(type) has no extension")
            XCTAssertTrue(
                seen.insert(type.fileExtension).inserted,
                "duplicate extension \(type.fileExtension)"
            )
        }
    }

    func testEveryNewFileTypeBelongsToACategory() {
        let grouped = NewFileCategory.allCases.flatMap { category in
            NewFileType.allCases.filter { $0.category == category }
        }
        XCTAssertEqual(Set(grouped), Set(NewFileType.allCases))
    }

    func testDefaultFileNameUsesTheBaseNameAndExtension() {
        XCTAssertEqual(NewFileType.markdown.defaultFileName(baseName: "Notes"), "Notes.md")
        XCTAssertEqual(NewFileType.text.defaultFileName(baseName: "  "), "Untitled.txt")
        XCTAssertEqual(NewFileType.pages.defaultFileName(baseName: "Report"), "Report.pages")
    }

    /// The settings catalog and the shipped Finder menu must agree, otherwise a
    /// stored "enabled type" would not map onto a real menu item.
    func testCatalogMatchesTheFinderMenuBuilderKinds() {
        // P6-b: every kind is now offered by both sides.
        for type in NewFileType.allCases {
            let kind = NewFileKind(rawValue: type.rawValue)
            XCTAssertNotNil(kind, "\(type.rawValue) has no FinderMenuBuilder.NewFileKind counterpart")
            XCTAssertEqual(kind?.fileExtension, type.fileExtension)
            XCTAssertEqual(kind?.titleKey, type.titleKey)
            // The default name the menu builds must match what the pane previews.
            XCTAssertEqual(kind?.defaultName, type.defaultFileName(baseName: "Untitled"))
        }
        // And the other direction: a kind added to the menu must be settable.
        for kind in NewFileKind.allCases {
            XCTAssertNotNil(NewFileType(rawValue: kind.rawValue), "\(kind.rawValue) is missing from the settings catalog")
        }
    }

    /// P6-b: only Pages/Numbers/Keynote depend on a bundled blank document;
    /// everything else is generated and therefore always available.
    func testTemplateBackedKindsAreExactlyTheiWorkOnes() {
        XCTAssertEqual(NewFileType.allCases.filter(\.requiresTemplate), [.pages, .numbers, .keynote])
        XCTAssertTrue(NewFileType.docx.isGenerated)
        XCTAssertFalse(NewFileType.docx.requiresTemplate)
    }

    func testNewFileNormalizationRestoresMissingAndDropsUnknown() {
        let settings = NewFileSettings(
            baseName: "\n",
            types: [.json, .json, .html],
            enabledTypes: [.json]
        ).normalized()

        XCTAssertEqual(settings.baseName, NewFileSettings.defaultBaseName)
        XCTAssertEqual(settings.types.prefix(2), [.json, .html])
        XCTAssertEqual(settings.types.count, NewFileType.allCases.count)
        XCTAssertEqual(Set(settings.types), Set(NewFileType.allCases))
        XCTAssertEqual(settings.enabledTypes, [.json])
    }

    // MARK: - File permissions

    func testFilePermissionsDefaultAllowsEverything() {
        let permissions = FilePermissionSettings()
        for action in FileAction.allCases {
            XCTAssertTrue(permissions.isAllowed(action), "\(action) should be allowed by default")
        }
    }

    func testFilePermissionsIsAllowedReflectsTheSet() {
        let permissions = FilePermissionSettings(allowedActions: [.createFile, .copyPath])
        XCTAssertTrue(permissions.isAllowed(.createFile))
        XCTAssertTrue(permissions.isAllowed(.copyPath))
        XCTAssertFalse(permissions.isAllowed(.lockUnlock))
    }

    // MARK: - Favorites

    func testAddingTheSameFolderPathRefreshesInsteadOfDuplicating() {
        var folders: [FavoriteFolder] = []
        let first = FavoriteFolder(displayName: "Docs", path: "/Users/me/Docs")
        XCTAssertTrue(folders.upsert(first))
        XCTAssertEqual(folders.count, 1)

        // Trailing separator and a different display name: same folder.
        let again = FavoriteFolder(displayName: "Documents", path: "/Users/me/Docs/")
        XCTAssertFalse(folders.upsert(again))
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders[0].displayName, "Documents")
        // The row id is preserved so SwiftUI keeps its identity.
        XCTAssertEqual(folders[0].id, first.id)
    }

    func testAddingTheSameAppRefreshesInsteadOfDuplicating() {
        var apps: [FavoriteApp] = []
        let safari = FavoriteApp(displayName: "Safari", path: "/Applications/Safari.app", bundleIdentifier: "com.apple.Safari")
        XCTAssertTrue(apps.upsert(safari))
        // Same bundle moved elsewhere: still the same logical entry.
        let moved = FavoriteApp(displayName: "Safari", path: "/Users/me/Applications/Safari.app", bundleIdentifier: "com.apple.Safari")
        XCTAssertFalse(apps.upsert(moved))
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].id, safari.id)
    }

    func testAppsWithoutABundleIdentifierDedupeByPath() {
        var apps: [FavoriteApp] = []
        apps.upsert(FavoriteApp(displayName: "Tool", path: "/tmp/Tool.app"))
        apps.upsert(FavoriteApp(displayName: "Tool", path: "/tmp/Tool.app"))
        XCTAssertEqual(apps.count, 1)
        apps.upsert(FavoriteApp(displayName: "Tool", path: "/tmp/Other.app"))
        XCTAssertEqual(apps.count, 2)
    }

    func testFavoriteWebsiteIdentityIgnoresCase() {
        var sites: [FavoriteWebsite] = []
        sites.upsert(FavoriteWebsite(displayName: "Apple", urlString: "https://Apple.com"))
        sites.upsert(FavoriteWebsite(displayName: "Apple Inc", urlString: "https://apple.com"))
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].displayName, "Apple Inc")
    }

    func testFavoriteURLNormalization() {
        XCTAssertEqual(
            FavoriteWebsite.normalizedURLString(from: " example.com "),
            "https://example.com"
        )
        XCTAssertEqual(
            FavoriteWebsite.normalizedURLString(from: "http://example.com/path?q=1"),
            "http://example.com/path?q=1"
        )
        XCTAssertEqual(
            FavoriteWebsite.normalizedURLString(from: "https://sub.example.com:8443/x"),
            "https://sub.example.com:8443/x"
        )
        XCTAssertEqual(FavoriteWebsite.normalizedURLString(from: "localhost"), "https://localhost")
        XCTAssertEqual(
            FavoriteWebsite.normalizedURLString(from: "example.com"),
            "https://example.com"
        )

        // Rejected: empty, not a URL, no host, no dot, and non-http schemes.
        XCTAssertNil(FavoriteWebsite.normalizedURLString(from: ""))
        XCTAssertNil(FavoriteWebsite.normalizedURLString(from: "   "))
        XCTAssertNil(FavoriteWebsite.normalizedURLString(from: "not a url"))
        XCTAssertNil(FavoriteWebsite.normalizedURLString(from: "https://"))
        XCTAssertNil(FavoriteWebsite.normalizedURLString(from: "file:///etc/passwd"))
        XCTAssertNil(FavoriteWebsite.normalizedURLString(from: "javascript:alert(1)"))
    }

    func testResolvedDisplayNamesFallBackToThePathOrHost() {
        XCTAssertEqual(FavoriteFolder(displayName: "  ", path: "/tmp/work").resolvedDisplayName, "work")
        XCTAssertEqual(FavoriteApp(displayName: "", path: "/Applications/Xcode.app").resolvedDisplayName, "Xcode")
        XCTAssertEqual(FavoriteWebsite(displayName: " ", urlString: "https://example.com/a").resolvedDisplayName, "example.com")
    }

    func testEnableAndRemoveFavorites() {
        var folders = [
            FavoriteFolder(displayName: "A", path: "/tmp/a"),
            FavoriteFolder(displayName: "B", path: "/tmp/b"),
        ]
        folders.setFavoriteEnabled(false, id: folders[0].id)
        XCTAssertFalse(folders[0].isEnabled)
        XCTAssertTrue(folders[1].isEnabled)

        folders.removeFavorite(id: folders[0].id)
        XCTAssertEqual(folders.map(\.displayName), ["B"])
    }

    func testMoveFavoritesAppliesSwiftUIOnMoveOffsets() {
        func folders(_ names: [String]) -> [FavoriteFolder] {
            names.map { FavoriteFolder(displayName: $0, path: "/tmp/\($0)") }
        }
        // Move the first row to the end.
        var list = folders(["A", "B", "C"])
        list.moveFavorites(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(list.map(\.displayName), ["B", "C", "A"])

        // Move the last row to the front.
        list = folders(["A", "B", "C"])
        list.moveFavorites(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(list.map(\.displayName), ["C", "A", "B"])

        // Out-of-range offsets are ignored rather than crashing.
        list = folders(["A", "B"])
        list.moveFavorites(fromOffsets: IndexSet(integer: 9), toOffset: 0)
        XCTAssertEqual(list.map(\.displayName), ["A", "B"])
        list.moveFavorites(fromOffsets: IndexSet(), toOffset: 0)
        XCTAssertEqual(list.map(\.displayName), ["A", "B"])
    }

    // MARK: - Code theme

    func testCatalogShipsSixFixedThemesPlusSystem() {
        let fixed = CodeThemeCatalog.all.filter { $0.appearance != .dynamic }
        XCTAssertGreaterThanOrEqual(fixed.count, 6)
        XCTAssertEqual(CodeThemeCatalog.all.filter { $0.appearance == .dynamic }.count, 1)
    }

    func testThemeIdentifiersAreUniqueAndLookupFallsBack() {
        let ids = CodeThemeCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(CodeThemeCatalog.theme(id: "monokai").name, "Monokai")
        XCTAssertEqual(CodeThemeCatalog.theme(id: "nope").id, CodeThemeCatalog.systemID)
        XCTAssertEqual(CodeThemeCatalog.theme(id: "").id, CodeThemeCatalog.systemID)
    }

    func testEveryThemeTokenIsAValidHexColour() {
        for theme in CodeThemeCatalog.all {
            for token in CodeThemeToken.allCases {
                XCTAssertNotNil(
                    RGBColor(hex: theme.hex(for: token)),
                    "\(theme.id) has an invalid \(token.rawValue) colour: \(theme.hex(for: token))"
                )
            }
        }
    }

    func testSystemThemeResolvesByAppearance() {
        XCTAssertEqual(
            CodeThemeCatalog.resolvedTheme(id: CodeThemeCatalog.systemID, prefersDark: false).id,
            CodeThemeCatalog.xcodeLight.id
        )
        XCTAssertEqual(
            CodeThemeCatalog.resolvedTheme(id: CodeThemeCatalog.systemID, prefersDark: true).id,
            CodeThemeCatalog.xcodeDark.id
        )
        // A fixed theme ignores the appearance.
        XCTAssertEqual(
            CodeThemeCatalog.resolvedTheme(id: "dracula", prefersDark: false).id,
            "dracula"
        )
    }

    func testCodeThemeNormalizationRepairsUnknownThemeAndFontSize() {
        var settings = CodeThemeSettings(themeID: "gone", fontSize: 2, fontName: "  ")
        settings = settings.normalized()
        XCTAssertEqual(settings.themeID, CodeThemeCatalog.systemID)
        XCTAssertEqual(settings.fontSize, CodeThemeSettings.fontSizeRange.lowerBound)
        XCTAssertNil(settings.fontName)

        settings = CodeThemeSettings(themeID: "monokai", fontSize: 99, fontName: "Menlo").normalized()
        XCTAssertEqual(settings.themeID, "monokai")
        XCTAssertEqual(settings.fontSize, CodeThemeSettings.fontSizeRange.upperBound)
        XCTAssertEqual(settings.fontName, "Menlo")
    }

    func testRGBColorHexParsing() {
        XCTAssertEqual(RGBColor(hex: "#FFFFFF"), RGBColor(red: 1, green: 1, blue: 1))
        XCTAssertEqual(RGBColor(hex: "000000"), RGBColor(red: 0, green: 0, blue: 0))
        let mid = RGBColor(hex: "#808080")
        XCTAssertEqual(mid?.red ?? 0, 128.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(mid?.blue ?? 0, 128.0 / 255.0, accuracy: 0.0001)
        XCTAssertNil(RGBColor(hex: "#FFF"))
        XCTAssertNil(RGBColor(hex: "#GGGGGG"))
        XCTAssertNil(RGBColor(hex: "0x1234567"))
    }

    // MARK: - Archives

    func testArchiveDefaultsEnableSixFormatsAndExcludeRAR() {
        let settings = ArchiveSettings()
        XCTAssertEqual(settings.activeFormats.count, 6)
        XCTAssertFalse(settings.enabledFormats.contains(.rar))
        XCTAssertFalse(settings.isEnabled(.rar))
        XCTAssertEqual(settings.conflictPolicy, .keepBoth)
        XCTAssertFalse(settings.deletesArchiveAfterExtraction)
        XCTAssertTrue(settings.skipsMetadataEntries)
    }

    func testArchiveNormalizationClampsAndFilters() {
        let settings = ArchiveSettings(
            enabledFormats: [.zip, .rar],
            customDestinationPath: "   ",
            sizeLimitMB: 0
        ).normalized()
        XCTAssertEqual(settings.enabledFormats, [.zip])
        XCTAssertNil(settings.customDestinationPath)
        XCTAssertEqual(settings.sizeLimitMB, ArchiveSettings.sizeLimitRange.lowerBound)
    }

    /// The 体积上限 field takes typed input now, so the rule that decides what
    /// gets stored is the interesting part: the user must be told the maximum
    /// instead of having a too-large number silently clamped (which is what the
    /// stepper-only row did — the arrow simply did nothing).
    func testSizeLimitEntryAcceptsValuesInsideTheRange() {
        XCTAssertEqual(
            ArchiveSettings.interpretSizeLimit("\(ArchiveSettings.defaultSizeLimitMB)"),
            .accepted(ArchiveSettings.defaultSizeLimitMB)
        )
        XCTAssertEqual(
            ArchiveSettings.interpretSizeLimit("\(ArchiveSettings.sizeLimitRange.lowerBound)"),
            .accepted(ArchiveSettings.sizeLimitRange.lowerBound)
        )
        XCTAssertEqual(
            ArchiveSettings.interpretSizeLimit("\(ArchiveSettings.sizeLimitRange.upperBound)"),
            .accepted(ArchiveSettings.sizeLimitRange.upperBound)
        )
    }

    func testSizeLimitEntryReportsTheMaximumInsteadOfStoringTooLargeAValue() {
        let above = ArchiveSettings.sizeLimitRange.upperBound + 1
        XCTAssertEqual(
            ArchiveSettings.interpretSizeLimit("\(above)"),
            .aboveMaximum(stored: ArchiveSettings.sizeLimitRange.upperBound)
        )
        // The user's example: 10000 is past this build's ceiling.
        if ArchiveSettings.sizeLimitRange.upperBound < 10_000 {
            XCTAssertEqual(
                ArchiveSettings.interpretSizeLimit("10000"),
                .aboveMaximum(stored: ArchiveSettings.sizeLimitRange.upperBound)
            )
        }
        // Digits that overflow `Int` are above the maximum too, not "not a number".
        XCTAssertEqual(
            ArchiveSettings.interpretSizeLimit("999999999999999999999999"),
            .aboveMaximum(stored: ArchiveSettings.sizeLimitRange.upperBound)
        )
    }

    func testSizeLimitEntryReportsTheMinimum() {
        XCTAssertEqual(
            ArchiveSettings.interpretSizeLimit("0"),
            .belowMinimum(stored: ArchiveSettings.sizeLimitRange.lowerBound)
        )
        XCTAssertEqual(
            ArchiveSettings.interpretSizeLimit("-5"),
            .unusable
        )
    }

    func testSizeLimitEntryRejectsWhatIsNotANumber() {
        for text in ["", "   ", "abc", "12abc", "MB", "1.5", "١٢"] {
            XCTAssertEqual(ArchiveSettings.interpretSizeLimit(text), .unusable, "unexpectedly accepted \(text.debugDescription)")
        }
    }

    /// The row displays the grouped form ("1,024 MB") while unfocused, so what is
    /// on screen has to survive being selected, retyped over, or pasted back in.
    func testSizeLimitEntryToleratesGroupedAndUnitSuffixedInput() {
        XCTAssertEqual(ArchiveSettings.interpretSizeLimit("1,024"), .accepted(1024))
        XCTAssertEqual(ArchiveSettings.interpretSizeLimit("1,024 MB"), .accepted(1024))
        XCTAssertEqual(ArchiveSettings.interpretSizeLimit(" 1024 mb "), .accepted(1024))
        XCTAssertEqual(ArchiveSettings.interpretSizeLimit("1，024"), .accepted(1024))
    }

    func testArchiveFormatSuffixes() {        XCTAssertEqual(ArchiveFormat.zip.pathExtensions, ["zip"])
        XCTAssertEqual(ArchiveFormat.sevenZip.pathExtensions, ["7z"])
        XCTAssertEqual(ArchiveFormat.gzip.pathExtensions, ["gz", "tgz"])
        XCTAssertEqual(ArchiveFormat.xz.pathExtensions, ["xz", "txz"])
        XCTAssertTrue(ArchiveFormat.allCases.filter(\.isSupported).count == 6)
        XCTAssertFalse(ArchiveFormat.rar.isSupported)
    }

    // MARK: - Codable

    func testFavoriteDecodingToleratesMissingFields() throws {
        let json = #"{"favoriteFolders": [{"path": "/tmp/x"}], "favoriteWebsites": [{"urlString": "https://a.com"}]}"#
        let settings = try JSONDecoder().decode(MenuRightSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.favoriteFolders.count, 1)
        XCTAssertEqual(settings.favoriteFolders[0].path, "/tmp/x")
        XCTAssertTrue(settings.favoriteFolders[0].isEnabled)
        XCTAssertEqual(settings.favoriteFolders[0].resolvedDisplayName, "x")
        XCTAssertEqual(settings.favoriteWebsites[0].displayName, "")
    }

    func testDecodingDropsMembersThisBuildDoesNotKnow() throws {
        let json = """
        {
          "filePermissions": {"allowedActions": ["createFile", "teleport"]},
          "newFile": {"types": ["markdown", "hologram"], "enabledTypes": ["markdown"]},
          "archives": {"enabledFormats": ["zip", "rar"]},
          "general": {"language": "klingon"}
        }
        """
        let settings = try JSONDecoder().decode(MenuRightSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.filePermissions.allowedActions, [.createFile])
        XCTAssertEqual(settings.newFile.enabledTypes, [.markdown])
        // Unknown values are dropped; known ones survive. Decoding leaves the
        // list short here, and normalization (applied by the store on load) is
        // what restores kinds this build knows about.
        XCTAssertEqual(settings.newFile.types, [.markdown])
        XCTAssertEqual(settings.newFile.normalized().types.count, NewFileType.allCases.count)
        XCTAssertEqual(settings.archives.enabledFormats, [.zip, .rar])
        XCTAssertEqual(settings.general.language, .system)
        // RAR is filtered when the value is used, and by normalization.
        XCTAssertFalse(settings.archives.normalized().enabledFormats.contains(.rar))
    }

    // MARK: - Icons

    func testEveryNewFileTypeHasADistinctVendoredIcon() {
        var seen = Set<String>()
        for type in NewFileType.allCases {
            let asset = type.iconAsset
            XCTAssertFalse(asset.isEmpty, "\(type.rawValue) has no icon")
            XCTAssertTrue(
                asset.hasPrefix("phosphor-") || asset.hasPrefix("lucide-"),
                "\(asset) does not come from a vendored icon set"
            )
            XCTAssertTrue(seen.insert(asset).inserted, "duplicate file-type icon \(asset)")
        }
    }

    /// JSON is the one file type whose icon comes from Lucide rather than
    /// Phosphor (Phosphor has no braces-file icon in the specification).
    func testJSONIsTheOnlyLucideFileTypeIcon() {
        let lucide = NewFileType.allCases.filter { $0.iconAsset.hasPrefix("lucide-") }
        XCTAssertEqual(lucide, [.json])
    }

    func testEveryFileActionHasAnIcon() {
        for action in FileAction.allCases {
            XCTAssertTrue(
                action.iconAsset.hasPrefix("lucide-"),
                "\(action) icon is not a Lucide asset: \(action.iconAsset)"
            )
        }

        // "Open Terminal" and "Copy Name" used to share one icon (a slip in the
        // specification); every action now has its own.
        let duplicated = Dictionary(grouping: FileAction.allCases, by: \.iconAsset)
            .filter { $0.value.count > 1 }
        XCTAssertTrue(duplicated.isEmpty, "duplicate action icons: \(duplicated.keys.sorted())")
        XCTAssertEqual(FileAction.openTerminal.iconAsset, "lucide-square-chevron-right")
        XCTAssertEqual(FileAction.copyName.iconAsset, "lucide-copy")
    }
}
