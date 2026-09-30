import XCTest

/// Localization coverage: every key exists in both languages, placeholders
/// agree, and language resolution follows the system preference.
final class LocalizationTests: XCTestCase {

    func testEveryKeyHasBothLanguages() {
        for key in StringKey.allCases {
            let entry = Localization.table[key]
            XCTAssertNotNil(entry, "missing catalog entry for \(key.rawValue)")
            XCTAssertFalse(
                entry?.zh.isEmpty ?? true,
                "empty Chinese text for \(key.rawValue)"
            )
            XCTAssertFalse(
                entry?.en.isEmpty ?? true,
                "empty English text for \(key.rawValue)"
            )
        }
    }

    func testCatalogHasNoUnknownOrDuplicateKeys() {
        // A dictionary cannot hold duplicates, so the count check catches a
        // table entry whose case was deleted from `StringKey`.
        XCTAssertEqual(Localization.table.count, StringKey.allCases.count)
    }

    func testPlaceholdersMatchBetweenLanguages() {
        for key in StringKey.allCases {
            guard let entry = Localization.table[key] else { continue }
            XCTAssertEqual(
                entry.zh.components(separatedBy: "%d").count,
                entry.en.components(separatedBy: "%d").count,
                "placeholder mismatch for \(key.rawValue): \(entry.zh) / \(entry.en)"
            )
        }
    }

    func testTextReturnsTheRequestedLanguage() {
        XCTAssertEqual(Localization.text(.categoryGeneral, language: .simplifiedChinese), "通用设置")
        XCTAssertEqual(Localization.text(.categoryGeneral, language: .english), "General")
        // `.system` is resolved before lookup; if it ever reaches here it must
        // not return a half-translated value.
        XCTAssertEqual(Localization.text(.categoryGeneral, language: .system), "General")
    }

    func testEnabledCountFormattingMatchesThePlaceholderCount() {
        for language in [AppLanguage.simplifiedChinese, .english] {
            let format = Localization.text(.commonEnabledCount, language: language)
            let rendered = String(format: format, 3, 7)
            XCTAssertTrue(rendered.contains("3"), "\(language) lost the first value: \(rendered)")
            XCTAssertTrue(rendered.contains("7"), "\(language) lost the second value: \(rendered)")
        }
    }

    func testEverySettingsPaneTitleIsTranslatedDifferently() {
        // Titles are the most visible strings; a copy-paste of the English text
        // into the Chinese column would show up here.
        let titleKeys: [StringKey] = [
            .categoryGeneral,
            .categoryFilePermissions,
            .categoryFolderPermissions,
            .categoryNewFile,
            .categoryFavoriteFolders,
            .categoryFavoriteApps,
            .categoryFavoriteWebsites,
            .categoryCodeTheme,
            .categoryArchives,
        ]
        for key in titleKeys {
            let zh = Localization.text(key, language: .simplifiedChinese)
            let en = Localization.text(key, language: .english)
            XCTAssertNotEqual(zh, en, "\(key.rawValue) is not actually translated")
            XCTAssertTrue(zh.contains(where: { $0.unicodeScalars.first.map { $0.value > 0x2E80 } ?? false }), "\(key.rawValue) Chinese text looks untranslated: \(zh)")
        }
    }

    // MARK: - Language resolution

    func testExplicitSelectionWinsOverTheSystemPreference() {
        XCTAssertEqual(AppLanguage.resolve(.english, preferred: ["zh-Hans-CN"]), .english)
        XCTAssertEqual(AppLanguage.resolve(.simplifiedChinese, preferred: ["en-US"]), .simplifiedChinese)
    }

    func testSystemSelectionFollowsThePreferredLanguages() {
        XCTAssertEqual(AppLanguage.resolve(.system, preferred: ["zh-Hans-CN", "en-US"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(.system, preferred: ["zh-Hant-TW"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(.system, preferred: ["en-GB"]), .english)
        XCTAssertEqual(AppLanguage.resolve(.system, preferred: ["de-DE", "en-US"]), .english)
        XCTAssertEqual(AppLanguage.resolve(.system, preferred: []), .english)
        XCTAssertEqual(AppLanguage.resolve(.system, preferred: [""]), .english)
    }

    func testEveryLanguageHasARawValueUsableAsAPersistedValue() {
        for language in AppLanguage.allCases {
            XCTAssertEqual(AppLanguage(rawValue: language.rawValue), language)
            XCTAssertFalse(language.rawValue.isEmpty)
        }
    }
}
