import AppKit
import XCTest

/// The menu bar item: what is in it, the lifecycle rule behind 退出, and how a
/// manual update check reports back.
///
/// Two of the three pieces live in `MenuRightApp.swift`, which this target cannot
/// compile (it owns `@main`): the `MenuBarExtra` scene and the
/// `applicationShouldTerminateAfterLastWindowClosed` forwarder. Those are guarded
/// by reading the source — the same technique `SettingsCategoryTests` uses for
/// the sidebar row's icon styling — while everything else is asserted directly.
final class StatusMenuTests: XCTestCase {

    // MARK: - Contents

    func testMenuIsSettingsThenCheckThenSeparatorThenQuit() {
        XCTAssertEqual(StatusMenuPlan.entries, [
            .command(.openSettings),
            .command(.checkForUpdates),
            .separator,
            .command(.quit),
        ])
    }

    func testQuitIsTheOnlyItemBelowTheSeparator() throws {
        let separator = try XCTUnwrap(StatusMenuPlan.entries.firstIndex(of: .separator))
        let below = StatusMenuPlan.entries[StatusMenuPlan.entries.index(after: separator)...]
        XCTAssertEqual(Array(below), [.command(.quit)])
    }

    func testEveryCommandIsListedExactlyOnce() {
        let listed = StatusMenuPlan.commands
        XCTAssertEqual(Set(listed).count, listed.count, "a command is listed twice")
        XCTAssertEqual(
            Set(listed),
            Set(StatusMenuCommand.allCases),
            "a StatusMenuCommand case is missing from the plan"
        )
    }

    func testEveryCommandHasItsOwnTitleInBothLanguages() {
        var chineseTitles: Set<String> = []
        for command in StatusMenuCommand.allCases {
            let zh = Localization.text(command.titleKey, language: .simplifiedChinese)
            let en = Localization.text(command.titleKey, language: .english)
            XCTAssertFalse(zh.isEmpty, "\(command.rawValue) has no Chinese title")
            XCTAssertFalse(en.isEmpty, "\(command.rawValue) has no English title")
            XCTAssertNotEqual(zh, en, "\(command.rawValue) was not translated")
            XCTAssertTrue(
                chineseTitles.insert(zh).inserted,
                "two commands share the Chinese title \(zh)"
            )
        }
    }

    func testQuitTitleNamesTheApp() {
        // "Quit MenuRight", not a bare "Quit": that is how a Mac app's quit
        // command reads, and it says *what* is being quit — the main app, whose
        // exit is what stops the Finder menu from working.
        XCTAssertTrue(Localization.text(.statusMenuQuit, language: .simplifiedChinese).contains("MenuRight"))
        XCTAssertTrue(Localization.text(.statusMenuQuit, language: .english).contains("MenuRight"))
    }

    func testFallbackSymbolResolvesThroughAppKit() throws {
        // The catalog artwork itself cannot be checked from here: this is a
        // host-less logic bundle with no access to the app's asset catalog
        // (that is why `Scripts/check-icons.sh` exists). What *can* be checked
        // here is the fallback, so the two failure modes stay distinguishable:
        // a missing asset shows the symbol, a bad symbol shows nothing at all.
        let image = try XCTUnwrap(
            NSImage(systemSymbolName: StatusMenuIcon.fallbackSymbolName, accessibilityDescription: nil),
            "neither the catalog asset nor the fallback symbol would draw: \(StatusMenuIcon.fallbackSymbolName)"
        )
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testStatusBarIconHonoursTheMenuBarSize() {
        // A 120×120 SVG left at its intrinsic size stretches the whole menu bar.
        XCTAssertEqual(StatusMenuIcon.pointSize, 16)
        XCTAssertFalse(StatusMenuIcon.assetName.isEmpty)
    }

    // MARK: - Lifecycle

    func testTheAppKeepsRunningWhenTheLastWindowCloses() {
        XCTAssertFalse(
            AppLifecycle.terminatesAfterLastWindowClosed,
            """
            The app must outlive its window: the Finder extension delegates every \
            operation to this process, so quitting with the window leaves a menu \
            whose every item answers 主应用未运行.
            """
        )
    }

    func testDelegateAndSceneActuallyUseThoseRules() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("MenuRight/App/MenuRightApp.swift"),
            encoding: .utf8
        )
        // Comments must go first: this file's own documentation names both the
        // delegate method and MenuBarExtra, and a guard a comment can satisfy is
        // no guard at all.
        let code = strippingComments(from: source)

        XCTAssertTrue(
            code.contains("func applicationShouldTerminateAfterLastWindowClosed"),
            "AppDelegate no longer implements the last-window rule, so AppKit's default applies"
        )
        XCTAssertTrue(
            code.contains("AppLifecycle.terminatesAfterLastWindowClosed"),
            "the delegate no longer forwards to AppLifecycle, so the tested value is not the one in use"
        )
        XCTAssertTrue(code.contains("MenuBarExtra"), "the menu bar item's scene is gone")
        XCTAssertTrue(
            code.contains(".menuBarExtraStyle(.menu)"),
            "without .menu the status item would open a popover instead of a dropdown"
        )
        XCTAssertTrue(code.contains("StatusMenuView()"), "the status item no longer shows StatusMenuView")
        XCTAssertTrue(
            code.contains("StatusMenuLabel()"),
            "the status item's artwork moved out of the tested constant (StatusMenuIcon)"
        )
        XCTAssertTrue(
            code.contains("WindowGroup(\"MenuRight\", id: Self.mainWindowID)"),
            """
            打开设置 reopens the window through openWindow(id:); without an id on \
            the WindowGroup the button would do nothing after the user closed it.
            """
        )
    }

    // MARK: - Manual update check

    func testManualCheckOutcomeMapping() {
        XCTAssertEqual(StatusMenuUpdateOutcome.make(from: .idle), .nothing)
        XCTAssertEqual(StatusMenuUpdateOutcome.make(from: .checking), .nothing)
        XCTAssertEqual(
            StatusMenuUpdateOutcome.make(from: .upToDate(version: "1.0")),
            .upToDate(running: "1.0")
        )
        XCTAssertEqual(
            StatusMenuUpdateOutcome.make(from: .failed("HTTP 403")),
            .failed(message: "HTTP 403")
        )
        // "a newer version exists" is presented by UpdatePrompter, with its own
        // buttons, so the menu must not also raise an alert for it.
        let release = UpdateRelease(
            version: "1.1",
            tagName: "v1.1",
            title: "MenuRight 1.1",
            notes: "",
            pageURL: URL(string: "https://example.com/v1.1")!,
            downloadURL: nil
        )
        XCTAssertEqual(StatusMenuUpdateOutcome.make(from: .updateAvailable(release)), .nothing)
    }

    func testUpToDateBodyCarriesTheRunningVersionInBothLanguages() {
        for language in [AppLanguage.simplifiedChinese, .english] {
            let format = Localization.text(.statusMenuUpToDateBody, language: language)
            let rendered = String(format: format, "1.0 (1)")
            XCTAssertTrue(rendered.contains("1.0 (1)"), "\(language) lost the version: \(rendered)")
        }
    }

    // MARK: - Helpers

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/MenuRightTests/StatusMenuTests.swift
            .deletingLastPathComponent()         // …/MenuRightTests
            .deletingLastPathComponent()         // repository root
    }

    /// Everything after a `//` on each line, dropped.
    private func strippingComments(from source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }
}
