import AppKit
import SwiftUI

/// The custom-compression dialog, as a window owned by the **process**.
///
/// It used to be a `.sheet` on `SettingsRootView`, which broke the one flow the
/// dialog exists for: MenuRight keeps running as a menu bar item after the
/// settings window is closed (`AppLifecycle.terminatesAfterLastWindowClosed` is
/// `false`), and a sheet whose view is not in the hierarchy cannot be presented.
/// A Finder 「自定义压缩…」 arriving in that state parked the request and drew
/// nothing at all — 点了没反应 (2026-10-03). The dialog therefore no longer
/// belongs to a window the user can close: it is created on demand here, from
/// the app process itself, so it appears whether or not the settings window
/// exists.
///
/// A plain `.titled` window whose title bar shows 自定义压缩 and whose content is
/// the form, laid out below the bar (the FastZip arrangement). `.closable` is
/// deliberately absent — 取消 and 保存 are the only exits, and both do the right
/// thing to a running compression (取消 aborts it, 保存 finishes it).
final class CustomCompressionDialogWindow: NSObject, ArchiveDialogPresenting {
    static let shared = CustomCompressionDialogWindow()

    /// Lets a self-test (or a future test host) find *this* window instead of
    /// guessing which visible window is the dialog.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("archive-dialog")

    private var window: NSWindow?
    private var host: NSViewController?
    private var sizeObservation: NSKeyValueObservation?

    /// Supplies the password book the form renders.
    ///
    /// It is a closure so that building this window does not read the real
    /// keychain: the book lives there, and a *test* process reading it can block
    /// on a keychain authorization prompt with nothing to answer it (observed
    /// 2026-10-03 — the whole suite hung in `SecItemCopyMatching`). Tests hand in
    /// an `ArchivePasswordBook(storage: InMemoryArchivePasswordBookStorage())`.
    var passwordBookProvider: () -> ArchivePasswordBook = {
        MainActor.assumeIsolated { ArchivePasswordBook.shared }
    }

    private override init() {
        super.init()
    }

    /// Whether the dialog is on screen — the DEBUG self-test asserts on this.
    var isShowing: Bool { window?.isVisible ?? false }

    // MARK: - ArchiveDialogPresenting

    func show(_ request: PendingArchiveRequest) {
        close()

        let content = CustomCompressionSheet(request: request, center: .shared) {}
            .environmentObject(SettingsStore.shared)
            .environmentObject(passwordBookProvider())
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        self.host = host

        let window = NSWindow(contentViewController: host)
        // A form gets a real title bar (FastZip's 自定义压缩 lives there too):
        // the title is the one place this dialog's name belongs, and with the
        // content laid out *below* the bar there is no empty strip above the
        // form — the old `.fullSizeContentView` + hidden title left ~28pt of
        // blank window over 保存为. `.closable` is still absent: 取消 and 保存
        // are the only exits, and both do the right thing to a running
        // compression.
        window.styleMask = [.titled]
        // No need to aim at a title bar when dragging.
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.identifier = Self.windowIdentifier
        window.title = SettingsStore.shared.text(.archiveCustomTitle)
        self.window = window
        // A refused 退出 closes the settings window; this form floats above it and
        // would otherwise be left behind with nothing under it. Registering it is
        // what makes it go down too — the delegate no longer sweeps
        // `NSApp.windows` (that sweep closed the menu bar item's own window).
        registerWithDelegate(window)

        sizeWindowToContent()
        window.center()
        NSApp?.activate()
        window.makeKeyAndOrderFront(nil)

        // The error line only appears after a failed 保存, which makes the content
        // taller; a dialog that clips its own error message is worse than one that
        // grows by a line.
        sizeObservation = host.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            self?.sizeWindowToContent()
        }
    }

    func close() {
        sizeObservation = nil
        registerWithDelegate(nil)
        guard let window else { return }
        self.window = nil
        host = nil
        // `close()` is usually reached from the dialog's own 取消/保存 action;
        // ordering the window out on the next main-loop pass keeps it alive until
        // that action has finished running.
        DispatchQueue.main.async {
            window.orderOut(nil)
        }
    }

    // MARK: - Quit handling

    /// Tells the app delegate which window to close when a 退出 is refused (Dock
    /// icon, ⌘Q). `MainAppGate` rather than `AppDelegate` so this file keeps
    /// compiling in the test target, and the registry rather than
    /// `NSApp.delegate` because SwiftUI's own delegate sits there (see
    /// `MainAppGate`).
    private func registerWithDelegate(_ window: NSWindow?) {
        MainAppGateRegistry.gate?.register(auxiliaryWindow: window)
    }

    // MARK: - Test seams
    /// The window itself, so the layout and the "取消/保存 are the only exits" rule
    /// can be asserted without Finder (the same seam as `ArchiveProgressWindow`).
    var dialogWindow: NSWindow? { window }

    // MARK: - Sizing

    /// Sizes the window so the whole form fits: with a normal (non-overlaying)
    /// title bar the content size *is* the form size, no inset arithmetic.
    private func sizeWindowToContent() {
        guard let window, let view = host?.view else { return }
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }
        window.setContentSize(fitting)
    }
}
