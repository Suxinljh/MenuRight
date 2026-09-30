import XCTest

/// Persistence behaviour of `SettingsStore`: defaults, round-trip, recovery
/// from a corrupt payload, and normalization drift.
final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // `mutate` applies in place on the main thread; XCTest runs synchronous
        // tests there. Assert it so an unexpected execution context shows up as
        // a clear failure instead of a mysteriously stale value.
        XCTAssertTrue(Thread.isMainThread, "SettingsStoreTests must run on the main thread")
        suiteName = "MenuRightTests.settings.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: defaults, storageKey: "test.settings")
    }

    // MARK: - Defaults

    func testEmptyDefaultsLoadTheDefaultTree() {
        let store = makeStore()
        XCTAssertEqual(store.settings, MenuRightSettings.default)
        XCTAssertEqual(store.settings.filePermissions.allowedActions, Set(FileAction.allCases))
        XCTAssertTrue(store.settings.newFile.enabledTypes.contains(.markdown))
        XCTAssertFalse(store.settings.archives.enabledFormats.contains(.rar))
    }

    // MARK: - Round trip

    func testMutationPersistsAndIsVisibleToANewStore() throws {
        let store = makeStore()
        store.mutate { settings in
            settings.general.language = .english
            settings.archives.conflictPolicy = .skip
            settings.favoriteWebsites.upsert(
                FavoriteWebsite(displayName: "Apple", urlString: "https://apple.com")
            )
        }

        // The in-memory tree updates synchronously.
        XCTAssertEqual(store.settings.general.language, .english)

        // A fresh store over the same defaults reads the same payload.
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.settings.general.language, .english)
        XCTAssertEqual(reloaded.settings.archives.conflictPolicy, .skip)
        XCTAssertEqual(reloaded.settings.favoriteWebsites.count, 1)
        XCTAssertEqual(reloaded.settings.favoriteWebsites.first?.urlString, "https://apple.com")
    }

    func testSettingsRoundTripThroughJSONIsStable() throws {
        var settings = MenuRightSettings.default
        settings.newFile.baseName = "Draft"
        settings.codeTheme.themeID = "monokai"
        settings.favoriteFolders = [FavoriteFolder(displayName: "Docs", path: "/tmp/docs")]
        settings.archives.sizeLimitMB = 256

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(settings)
        let decoded = try JSONDecoder().decode(MenuRightSettings.self, from: data)

        XCTAssertEqual(decoded, settings)
    }

    // MARK: - Recovery

    func testCorruptPayloadFallsBackToDefaults() {
        defaults.set(Data("this is not json".utf8), forKey: "test.settings")
        let store = makeStore()
        XCTAssertEqual(store.settings, MenuRightSettings.default)
    }

    func testPayloadWithWrongTypesFallsBackToDefaults() {
        // `general` is an object in the schema; a string must not crash the app.
        let json = #"{"general": "english", "archives": {"sizeLimitMB": 128}}"#
        defaults.set(Data(json.utf8), forKey: "test.settings")
        let store = makeStore()
        XCTAssertEqual(store.settings, MenuRightSettings.default)
    }

    func testMissingFieldsAreFilledWithDefaults() throws {
        // An older build stored only a subset of the keys.
        let json = #"{"general": {"language": "en"}, "archives": {"sizeLimitMB": 64}}"#
        defaults.set(Data(json.utf8), forKey: "test.settings")

        let store = makeStore()
        XCTAssertEqual(store.settings.general.language, .english)
        XCTAssertFalse(store.settings.general.launchAtLogin)
        XCTAssertEqual(store.settings.archives.sizeLimitMB, 64)
        XCTAssertEqual(store.settings.archives.conflictPolicy, .keepBoth)
        XCTAssertEqual(store.settings.newFile.types, NewFileType.allCases)
        XCTAssertEqual(store.settings.schemaVersion, MenuRightSettings.currentSchemaVersion)
    }

    func testUnknownFieldsAreIgnored() {
        let json = #"{"schemaVersion": 1, "somethingFromTheFuture": true}"#
        defaults.set(Data(json.utf8), forKey: "test.settings")
        let store = makeStore()
        XCTAssertEqual(store.settings, MenuRightSettings.default)
    }

    // MARK: - Normalization

    func testNormalizationRepairsDriftOnLoad() throws {
        // Unknown theme id, a size limit out of range, and a new-file order that
        // is missing kinds added by a newer build.
        let json = """
        {
          "newFile": {"baseName": "   ", "types": ["json", "html"], "enabledTypes": ["json", "notAKind"]},
          "codeTheme": {"themeID": "no-such-theme", "fontSize": 400},
          "archives": {"enabledFormats": ["zip", "rar"], "sizeLimitMB": 999999}
        }
        """
        defaults.set(Data(json.utf8), forKey: "test.settings")

        let store = makeStore()
        XCTAssertEqual(store.settings.newFile.baseName, NewFileSettings.defaultBaseName)
        XCTAssertEqual(store.settings.newFile.types.prefix(2), [.json, .html])
        // Every catalog kind is present exactly once.
        XCTAssertEqual(Set(store.settings.newFile.types), Set(NewFileType.allCases))
        XCTAssertEqual(store.settings.newFile.types.count, NewFileType.allCases.count)
        XCTAssertEqual(store.settings.newFile.enabledTypes, [.json])
        XCTAssertEqual(store.settings.codeTheme.themeID, CodeThemeCatalog.systemID)
        XCTAssertEqual(store.settings.codeTheme.fontSize, CodeThemeSettings.fontSizeRange.upperBound)
        XCTAssertEqual(store.settings.archives.enabledFormats, [.zip])
        XCTAssertEqual(store.settings.archives.sizeLimitMB, ArchiveSettings.sizeLimitRange.upperBound)
    }

    func testNormalizationRunsOnEveryMutation() {
        let store = makeStore()
        store.mutate { settings in
            settings.newFile.baseName = "  "
            settings.codeTheme.fontSize = 100
            settings.archives.enabledFormats.insert(.rar)
        }
        XCTAssertEqual(store.settings.newFile.baseName, NewFileSettings.defaultBaseName)
        XCTAssertEqual(store.settings.codeTheme.fontSize, CodeThemeSettings.fontSizeRange.upperBound)
        XCTAssertFalse(store.settings.archives.enabledFormats.contains(.rar))
    }

    // MARK: - Reset and reload

    func testResetAllRestoresDefaultsAndPersistsThem() {
        let store = makeStore()
        store.mutate { $0.general.language = .simplifiedChinese }
        store.resetAll()

        XCTAssertEqual(store.settings, MenuRightSettings.default)
        XCTAssertEqual(makeStore().settings, MenuRightSettings.default)
    }

    func testReloadPicksUpChangesWrittenByAnotherStore() {
        let store = makeStore()
        let other = makeStore()
        other.mutate { $0.codeTheme.themeID = "dracula" }

        XCTAssertNotEqual(store.settings.codeTheme.themeID, "dracula")
        store.reload()
        XCTAssertEqual(store.settings.codeTheme.themeID, "dracula")
    }

    func testNoOpMutationDoesNotChangeSettings() {
        let store = makeStore()
        let before = store.settings
        store.mutate { settings in
            settings.general.language = settings.general.language
        }
        XCTAssertEqual(store.settings, before)
    }

    // MARK: - Language helpers

    func testTextFollowsTheSelectedLanguage() {
        let store = makeStore()
        store.mutate { $0.general.language = .simplifiedChinese }
        XCTAssertEqual(store.language, .simplifiedChinese)
        XCTAssertEqual(store.text(.categoryGeneral), "通用设置")

        store.mutate { $0.general.language = .english }
        XCTAssertEqual(store.language, .english)
        XCTAssertEqual(store.text(.categoryGeneral), "General")
    }

    // MARK: - Permission helper

    func testIsAllowedReflectsTheAllowedActionSet() {
        let store = makeStore()
        XCTAssertTrue(store.isAllowed(.createFile))
        store.mutate { $0.filePermissions.allowedActions.remove(.createFile) }
        XCTAssertFalse(store.isAllowed(.createFile))
        XCTAssertTrue(store.isAllowed(.copyPath))
    }
}
