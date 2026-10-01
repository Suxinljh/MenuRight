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

    /// The sidebar row must style its icon **on the icon**, not only on the label.
    ///
    /// `.listStyle(.sidebar)` re-applies a foreground style to a label's icon slot
    /// from the outside, so a row-level style reaches the text but never the
    /// glyph: the selected row drew white text next to a black icon on the accent
    /// pill (reported 2026-10-01, measured by offscreen-rendering the row inside a
    /// sidebar `List`).
    ///
    /// A rendering test cannot be written honestly here: the icon is an
    /// asset-catalog image, this test bundle is host-less and carries no
    /// `Assets.car`, and the row view is not compiled into the test target — so
    /// such a test would only re-test a copy of the row. Hence a source check,
    /// the same approach `ExtensionMainThreadTests` takes.
    func testSidebarRowStylesItsIconDirectlyNotJustTheLabel() throws {
        let root = URL(fileURLWithPath: #filePath)      // …/MenuRightTests/SettingsCategoryTests.swift
            .deletingLastPathComponent()                 // …/MenuRightTests
            .deletingLastPathComponent()                 // repository root
        let source = try String(
            contentsOf: root.appendingPathComponent("MenuRight/App/Settings/SettingsRootView.swift"),
            encoding: .utf8
        )

        let body = try XCTUnwrap(iconClosureBody(in: source), "the sidebar row has no `} icon: {` closure")
        // Strip comments first: the closure's own explanatory comment mentions
        // `foregroundStyle`, and a guard that a comment can satisfy is no guard.
        let code = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
        XCTAssertTrue(
            code.contains("foregroundStyle"),
            """
            The sidebar row's icon closure must set `foregroundStyle` on the icon \
            itself: a sidebar List overrides the label-level style for the icon \
            slot, which leaves a black glyph on the selected accent pill.
            """
        )
    }

    /// Text between `} icon: {` and its matching `}`, braces counted.
    private func iconClosureBody(in source: String) -> String? {
        guard let start = source.range(of: "} icon: {")?.upperBound else { return nil }
        var depth = 1
        var index = start
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[start..<index]) }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }
}
