import XCTest
import AppKit

/// The custom-compression dialog belongs to the app **process**, not to the
/// settings window.
///
/// This is the regression net for the 2026-10-03 bug: the dialog used to be a
/// `.sheet` on `SettingsRootView`, and MenuRight keeps running after the settings
/// window is closed (it is a menu bar item — see `AppLifecycle`). A Finder
/// 「自定义压缩…」 arriving in that state parked its request and drew nothing,
/// while the log still claimed `ARCHIVE dialog presented`.
///
/// The bundle is host-less, so there is no run loop and nothing on screen: the
/// routing is checked through an injected presenter, and the real window is
/// checked through its own properties.
final class CustomCompressionDialogTests: XCTestCase {

    /// Records what the center asked its UI to do.
    private final class SpyPresenter: ArchiveDialogPresenting {
        var shownRequests: [PendingArchiveRequest] = []
        var closeCount = 0

        func show(_ request: PendingArchiveRequest) {
            shownRequests.append(request)
        }

        func close() {
            closeCount += 1
        }
    }

    private func makeRequest(name: String = "Archive") -> PendingArchiveRequest {
        PendingArchiveRequest(
            sources: [URL(fileURLWithPath: "/tmp/one.txt")],
            directory: URL(fileURLWithPath: "/tmp"),
            name: name,
            label: "",
            format: .zip,
            mode: .standard
        )
    }

    override func setUp() {
        super.setUp()
        // Never read the user's real keychain from a test. The 密码本 lives in the
        // keychain, and a test process reading it can block forever on an
        // authorization prompt nobody can answer (2026-10-03: the whole suite sat
        // in `SecItemCopyMatching` until it was killed).
        CustomCompressionDialogWindow.shared.passwordBookProvider = {
            // `ArchivePasswordBook` is main-actor isolated; `show` runs on the main
            // thread, so assume that isolation instead of hopping.
            MainActor.assumeIsolated { ArchivePasswordBook(storage: InMemoryArchivePasswordBookStorage()) }
        }
    }

    override func tearDown() {
        // The center is a singleton shared with the whole test bundle.
        ArchiveRequestCenter.shared.presenter = nil
        ArchiveRequestCenter.shared.pending = nil
        CustomCompressionDialogWindow.shared.close()
        CustomCompressionDialogWindow.shared.passwordBookProvider = {
            MainActor.assumeIsolated { ArchivePasswordBook.shared }
        }
        super.tearDown()
    }

    // MARK: - Routing

    func testPresentParksTheRequestAndHandsItToThePresenter() {
        let center = ArchiveRequestCenter.shared
        let spy = SpyPresenter()
        center.presenter = spy

        let request = makeRequest()
        center.present(request)

        XCTAssertEqual(spy.shownRequests.count, 1, "the parked request has to reach the UI")
        XCTAssertEqual(spy.closeCount, 0)
        // The dialog edits the very request that was parked, not a copy of it.
        XCTAssertEqual(center.pending?.id, spy.shownRequests.first?.id)
        XCTAssertEqual(center.pending?.sources, request.sources)
        XCTAssertEqual(center.pending?.name, "Archive")
    }

    func testDismissClearsTheRequestAndClosesTheDialog() {
        let center = ArchiveRequestCenter.shared
        let spy = SpyPresenter()
        center.presenter = spy
        center.present(makeRequest())

        center.dismiss()

        XCTAssertNil(center.pending, "取消/保存 must not leave a parked request behind")
        XCTAssertEqual(spy.closeCount, 1, "and they must take the dialog off screen")
    }

    func testASecondRequestReplacesTheFirstOne() {
        let center = ArchiveRequestCenter.shared
        let spy = SpyPresenter()
        center.presenter = spy

        center.present(makeRequest(name: "First"))
        center.present(makeRequest(name: "Second"))

        XCTAssertEqual(center.pending?.name, "Second")
        XCTAssertEqual(spy.shownRequests.map(\.name), ["First", "Second"])
        // Replacing an open dialog is the presenter's job (`show` closes first).
        XCTAssertEqual(spy.closeCount, 0)
    }

    /// The dispatcher calls `present` from a connection queue; the UI must still
    /// be reached on the main thread.
    func testPresentFromABackgroundQueueStillReachesThePresenter() {
        let center = ArchiveRequestCenter.shared
        let spy = SpyPresenter()
        center.presenter = spy

        let presented = expectation(description: "presented on the main thread")
        DispatchQueue.global().async {
            center.present(self.makeRequest())
            DispatchQueue.main.async { presented.fulfill() }
        }
        wait(for: [presented], timeout: 5)

        XCTAssertEqual(spy.shownRequests.count, 1)
        XCTAssertNotNil(center.pending)
    }

    /// No presenter injected must still mean a real dialog, not an invisibly
    /// parked request: that fallback *is* the fix for 点了没反应.
    ///
    /// It is asserted rather than skipped because this bundle does have an
    /// `NSApplication` (AppKit creates one as soon as a test makes a window),
    /// which is exactly the state the old code mishandled.
    func testWithoutAnInjectedPresenterTheProcessLevelDialogIsUsed() throws {
        _ = NSApplication.shared
        let center = ArchiveRequestCenter.shared
        center.presenter = nil
        defer { center.dismiss() }

        center.present(makeRequest())

        XCTAssertEqual(center.pending?.name, "Archive")
        XCTAssertNotNil(CustomCompressionDialogWindow.shared.dialogWindow,
                        "no presenter, no window ⇒ the request is parked but never shown")
    }

    // MARK: - The window itself

    /// A plain titled window sized to the SwiftUI form, and — like the progress
    /// window — not closable: 取消 and 保存 are the two exits that know what to do
    /// with a running compression.
    func testDialogIsItsOwnWindowWithoutACloseButton() throws {
        let dialog = CustomCompressionDialogWindow.shared
        dialog.show(makeRequest())
        defer { dialog.close() }

        let window = try XCTUnwrap(dialog.dialogWindow, "the dialog has to exist as a window")
        XCTAssertEqual(window.identifier, CustomCompressionDialogWindow.windowIdentifier,
                       "the DEBUG self-test finds the dialog by this identifier")
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertFalse(window.styleMask.contains(.closable),
                       "a closable dialog reads as 'cancel my compression'")
        XCTAssertFalse(window.styleMask.contains(.miniaturizable))
        XCTAssertFalse(window.styleMask.contains(.resizable), "the form is a fixed size")
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView),
                       "the form sits *below* the title bar; overlaying it left blank window above 保存为")
        XCTAssertNotEqual(window.titleVisibility, .hidden, "the title bar carries 自定义压缩")
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertFalse(window.isReleasedWhenClosed, "a released window cannot be shown a second time")
        XCTAssertEqual(window.level, .floating, "a Finder action can arrive while other apps are in front")
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertEqual(window.title, SettingsStore.shared.text(.archiveCustomTitle))
    }

    /// The window must never be smaller than the form asks for: too little height
    /// would clip the 取消/确定 row, and the form itself fixes its own width.
    /// It must not be *taller* either — that extra strip is the blank space the
    /// user saw above 保存为 (2026-10-03), and this is the regression guard.
    func testTheWindowIsNeverSmallerThanTheFormItHosts() throws {
        let dialog = CustomCompressionDialogWindow.shared
        dialog.show(makeRequest())
        defer { dialog.close() }

        let window = try XCTUnwrap(dialog.dialogWindow)
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        XCTAssertGreaterThan(fitting.width, 0)
        XCTAssertGreaterThan(fitting.height, 0)
        let content = window.contentRect(forFrameRect: window.frame).size
        XCTAssertGreaterThanOrEqual(content.width, fitting.width - 0.5)
        XCTAssertGreaterThanOrEqual(content.height, fitting.height - 0.5)
        XCTAssertLessThanOrEqual(content.height, fitting.height + 0.5,
                                 "extra height here is the blank strip above the form")
        XCTAssertEqual(content.width, 520, accuracy: 1, "the form fixes its own width")
    }

    func testShowingASecondRequestReusesTheProcessRatherThanStackingWindows() throws {
        let dialog = CustomCompressionDialogWindow.shared
        dialog.show(makeRequest(name: "First"))
        let first = try XCTUnwrap(dialog.dialogWindow)
        dialog.show(makeRequest(name: "Second"))
        let second = try XCTUnwrap(dialog.dialogWindow)
        defer { dialog.close() }

        XCTAssertFalse(first === second, "the old window is replaced, not reused with stale content")
    }

    func testCloseTakesTheWindowAwayAndLeavesNoDialog() {
        let dialog = CustomCompressionDialogWindow.shared
        dialog.show(makeRequest())
        dialog.close()

        XCTAssertNil(dialog.dialogWindow)
        XCTAssertFalse(dialog.isShowing)
    }

    /// Renders the dialog to a PNG when asked, so its layout can be eyeballed
    /// without a Finder click (the same technique as the progress window):
    ///
    ///     TEST_RUNNER_MENURIGHT_DUMP_ARCHIVE_DIALOG=/tmp/dialog.png xcodebuild test …
    ///
    /// The bundle has no appearance of its own, so colours in that dump are not
    /// trustworthy; `MENURIGHT_SELFTEST_ARCHIVE_DIALOG_PNG` renders from inside
    /// the running app instead and is the one to look at.
    func testDialogRendersToAnImageWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["MENURIGHT_DUMP_ARCHIVE_DIALOG"] else {
            throw XCTSkip("set MENURIGHT_DUMP_ARCHIVE_DIALOG to render the dialog")
        }
        let dialog = CustomCompressionDialogWindow.shared
        dialog.show(makeRequest())
        defer { dialog.close() }

        // The window is off screen in a host-less bundle, so lay its content out
        // and draw that directly.
        let view = try XCTUnwrap(dialog.dialogWindow?.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) size=\(view.bounds.size)")
    }

    /// 位置 shows the folder it writes into first, so the native popup can carry
    /// its name (用户要求:位置的样式做成原生的).
    func testTheLocationPopupLeadsWithTheChosenFolder() {
        let entries = NativeFolderPicker.menu(
            directory: URL(fileURLWithPath: "/tmp/one"),
            recent: [],
            chooseTitle: "选择…"
        )
        XCTAssertEqual(entries.map(\.title), ["one", "", "选择…"])
        XCTAssertEqual(entries.map(\.isSeparator), [false, true, false])
        XCTAssertEqual(entries.first?.url, URL(fileURLWithPath: "/tmp/one"))
    }

    /// 「选择…」 is the way back to the system panel, so it must not look like a
    /// folder: no URL on that entry.
    func testTheLocationPopupEndsWithTheSystemChooser() {
        let entries = NativeFolderPicker.menu(
            directory: URL(fileURLWithPath: "/tmp/one"),
            recent: [],
            chooseTitle: "选择…"
        )
        XCTAssertNil(entries.last?.url)
        XCTAssertFalse(entries.last?.isSeparator ?? true)
    }

    /// Folders visited earlier stay in the menu, but the current one is never
    /// listed twice.
    func testTheLocationPopupKeepsVisitedFoldersWithoutRepeatingTheCurrentOne() {
        let entries = NativeFolderPicker.menu(
            directory: URL(fileURLWithPath: "/tmp/two"),
            recent: [URL(fileURLWithPath: "/tmp/one"), URL(fileURLWithPath: "/tmp/two")],
            chooseTitle: "选择…"
        )
        XCTAssertEqual(entries.filter { !$0.isSeparator }.map(\.title), ["two", "one", "选择…"])
    }
}
