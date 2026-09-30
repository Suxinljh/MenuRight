import XCTest

/// Sidebar structure and icon mapping.
///
/// This is plain data, so it is testable without an app host — the asset
/// catalog itself cannot be reached from this (host-less) test bundle, which is
/// why `Scripts/check-sidebar-icons.sh` exists for the on-disk half.
final class SettingsCategoryTests: XCTestCase {

    func testEveryCategoryHasAUniqueLucideIconAsset() {
        var seen = Set<String>()
        for category in SettingsCategory.allCases {
            let asset = category.iconAsset
            XCTAssertFalse(asset.isEmpty, "\(category.rawValue) has no icon asset")
            XCTAssertTrue(
                asset.hasPrefix("lucide-"),
                "\(category.rawValue) points at something that is not a Lucide asset: \(asset)"
            )
            XCTAssertTrue(
                seen.insert(asset).inserted,
                "two categories share the icon asset \(asset)"
            )
        }
    }

    func testEveryCategoryHasBothLanguageTitles() {
        for category in SettingsCategory.allCases {
            XCTAssertFalse(
                Localization.text(category.titleKey, language: .simplifiedChinese).isEmpty,
                "\(category.rawValue) is missing its Chinese title"
            )
            XCTAssertFalse(
                Localization.text(category.titleKey, language: .english).isEmpty,
                "\(category.rawValue) is missing its English title"
            )
        }
    }

    func testSidebarSectionsCoverEveryCategoryExactlyOnce() {
        let listed = SettingsCategory.sections.flatMap(\.categories)
        XCTAssertEqual(listed.count, SettingsCategory.allCases.count)
        XCTAssertEqual(Set(listed), Set(SettingsCategory.allCases), "a category is missing from the sidebar")
    }

    func testSectionIdentifiersAndTitlesAreDistinct() {
        let ids = SettingsCategory.sections.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate section id")
        XCTAssertEqual(
            Set(SettingsCategory.sections.map(\.titleKey)).count,
            SettingsCategory.sections.count,
            "two sections share a title key"
        )
    }

    func testDefaultCategoryIsReachableFromTheSidebar() {
        let listed = SettingsCategory.sections.flatMap(\.categories)
        XCTAssertTrue(
            listed.contains(SettingsCategory.default),
            "the pane shown on launch is not in the sidebar"
        )
    }

    func testCategoryRawValuesAreStablePersistedIdentifiers() {
        // `MENURIGHT_SETTINGS_PANE` and any future persisted selection use these
        // raw values, so they must round-trip.
        for category in SettingsCategory.allCases {
            XCTAssertEqual(SettingsCategory(rawValue: category.rawValue), category)
        }
    }
}
