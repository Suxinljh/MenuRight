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

    // MARK: - Quit semantics

    func testOnlyAnIntentionalQuitMayEndTheApp() {
        // The Dock icon's 退出 and ⌘Q arrive as terminate requests without the
        // mark, and they must not end the process: it is the IPC peer every
        // Finder menu item talks to.
        XCTAssertFalse(
            AppLifecycle.shouldTerminate(
                intentionalQuitRequested: false,
                systemIsPoweringOff: false
            ),
            "a terminate request that did not come from the menu bar item would stop the service"
        )
        XCTAssertTrue(
            AppLifecycle.shouldTerminate(
                intentionalQuitRequested: true,
                systemIsPoweringOff: false
            ),
            "退出 in the menu bar item must be able to end the app"
        )
        // Logging out / restarting / shutting down must never be refused.
        XCTAssertTrue(
            AppLifecycle.shouldTerminate(
                intentionalQuitRequested: false,
                systemIsPoweringOff: true
            ),
            "refusing the system's power-off request would stall the shutdown"
        )
    }

    func testTheDelegateGuardsAgainstEveryQuitButTheMenuBars() throws {
        let code = try sourceCode(at: "MenuRight/App/MenuRightApp.swift")

        XCTAssertTrue(
            code.contains("func applicationShouldTerminate("),
            "without applicationShouldTerminate the Dock's 退出 ends the whole app again"
        )
        XCTAssertTrue(
            code.contains("AppLifecycle.shouldTerminate("),
            "the delegate no longer forwards to the tested rule"
        )
        XCTAssertTrue(
            code.contains("return .terminateCancel"),
            """
            a refused terminate request must be answered with .terminateCancel; \
            anything else quits the app the rule just decided to keep
            """
        )
        XCTAssertTrue(
            code.contains("willPowerOffNotification"),
            "logout/shutdown must be let through, otherwise the system is told the app refused to quit"
        )
        XCTAssertTrue(
            code.contains("MainAppGateRegistry.gate = self"),
            """
            the delegate no longer publishes itself on MainAppGateRegistry; \
            NSApp.delegate holds SwiftUI's own SwiftUI.AppDelegate, so nothing \
            else can reach it — that silent nil cast is what disabled 退出 once \
            already (2026-10-03)
            """
        )
    }

    func testTheGateEndsTheAppWithoutAppKit() throws {
        let code = try sourceCode(at: "MenuRight/App/MenuRightApp.swift")

        // `NSApp.terminate(nil)` does not reach this app's delegate (SwiftUI
        // installs its own), so `quit()` has to finish the exit by hand. Without
        // that, 退出 would leave a background app that cannot be quit at all.
        XCTAssertTrue(code.contains("func quit()"), "the menu bar item's quit entry point is gone")
        XCTAssertTrue(
            code.contains("quitRequested = true"),
            "a quit that is not marked as intentional is cancelled by the gate itself"
        )
        XCTAssertTrue(code.contains("NSApp.terminate(nil)"), "quit no longer asks AppKit first")
        XCTAssertTrue(
            code.contains("finishQuitDirectly()"),
            "quit no longer has a path that works when AppKit does not answer"
        )
        XCTAssertTrue(
            code.contains("ipcServer.stop()"),
            """
            the fallback must stop the IPC listener the way applicationWillTerminate \
            does, otherwise the extension keeps talking to a dead socket file
            """
        )
        XCTAssertTrue(code.contains("exit(0)"), "the fallback no longer leaves the process")
    }

    func testNothingReachesTheDelegateThroughNSAppDelegate() throws {
        // The bug this guards against: `SwiftUI.AppDelegate` is what sits in
        // `NSApp.delegate`, so every `as? AppDelegate` on it answers nil and the
        // caller silently does nothing (measured 2026-10-03: the settings window
        // was never registered, so a refused 退出 closed nothing).
        let files = [
            "MenuRight/App/MenuRightApp.swift",
            "MenuRight/App/StatusMenu/StatusMenuView.swift",
            "MenuRight/App/Settings/SettingsRootView.swift",
            "MenuRight/App/Settings/CustomCompressionDialogWindow.swift",
        ]
        for file in files {
            let code = try sourceCode(at: file)
            XCTAssertFalse(
                code.contains("NSApp.delegate as? AppDelegate"),
                "\(file) casts NSApp.delegate to AppDelegate again — use MainAppGateRegistry"
            )
        }
    }

    func testTheStatusMenuItemQuitsThroughTheGate() throws {
        let code = try sourceCode(at: "MenuRight/App/StatusMenu/StatusMenuView.swift")

        XCTAssertTrue(
            code.contains("MainAppGateRegistry.gate?.quit()"),
            """
            退出 in the menu bar item must go through the gate: the mark makes the \
            request intentional, and `quit()` is the only path that really ends \
            this app
            """
        )
    }

    func testTheRelaunchPathAlsoQuitsThroughTheGate() throws {
        let code = try sourceCode(at: "MenuRight/App/Settings/SettingsRootView.swift")

        // 重启应用 starts the replacement first and then quits this process: with
        // the request cancelled the old instance would stay alive and both would
        // fight over the IPC socket.
        XCTAssertTrue(
            code.contains("MainAppGateRegistry.gate?.quit()"),
            "重启应用 no longer quits through the gate"
        )
    }

    // MARK: - The refused-quit rule

    func testARefusedQuitKeepsTheMenuBarItemAndClosesTheOtherWindows() {
        let statusBar = NSWindow.Level.statusBar.rawValue

        // The regression this rule exists for: the menu bar item's window sits at
        // `.statusBar`, is a plain NSWindow, and closing it leaves the icon visible
        // but deaf.
        XCTAssertFalse(AppLifecycle.mayDismiss(windowLevel: statusBar, isVisible: true, isPanel: false))
        XCTAssertFalse(
            AppLifecycle.mayDismiss(windowLevel: statusBar - 1, isVisible: true, isPanel: false),
            "level 24 is .mainMenu — a menu window, which the app must never close"
        )
        XCTAssertFalse(
            AppLifecycle.mayDismiss(windowLevel: NSWindow.Level.popUpMenu.rawValue, isVisible: true, isPanel: false)
        )

        // The windows a refused 退出 does dismiss.
        XCTAssertTrue(
            AppLifecycle.mayDismiss(windowLevel: NSWindow.Level.normal.rawValue, isVisible: true, isPanel: false),
            "the settings window is the window a refused 退出 closes"
        )
        XCTAssertTrue(
            AppLifecycle.mayDismiss(windowLevel: NSWindow.Level.floating.rawValue, isVisible: true, isPanel: false),
            "the custom-compression dialog floats above the settings window and goes down with it"
        )

        // Windows that must not be touched.
        XCTAssertFalse(
            AppLifecycle.mayDismiss(windowLevel: NSWindow.Level.normal.rawValue, isVisible: false, isPanel: false),
            "an invisible window has nothing to dismiss"
        )
        XCTAssertFalse(
            AppLifecycle.mayDismiss(windowLevel: NSWindow.Level.normal.rawValue, isVisible: true, isPanel: true),
            "an alert or password prompt is a decision in flight, not UI to dismiss"
        )
    }

    func testDelegateAndSceneActuallyUseThoseRules() throws {
        let code = try sourceCode(at: "MenuRight/App/MenuRightApp.swift")

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

    /// One repository file's source with its `//` comments dropped.
    ///
    /// Comments must go first: these files document the very API names the guards
    /// below look for (this file's own doc comment names the delegate method, and
    /// `MenuRightApp.swift` names `MenuBarExtra`), and a guard a comment can
    /// satisfy is no guard at all.
    private func sourceCode(at path: String) throws -> String {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
        return strippingComments(from: source)
    }
}
