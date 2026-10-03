import AppKit
import Foundation

/// The main app's termination gate: the handle `AppDelegate` publishes at init so
/// the rest of the app can reach it.
///
/// **Why not `NSApp.delegate`?** `AppDelegate` is the `@NSApplicationDelegateAdaptor`
/// delegate, and SwiftUI does *not* install it as `NSApp.delegate` — it installs its
/// own `SwiftUI.AppDelegate` and forwards the callbacks to ours. Measured on
/// 2026-10-03 in a self-test run:
///
///     SELFTEST settings-window-report class=AppKitWindow level=0 \
///         delegate=SwiftUI.AppDelegate cast=false isAppDelegate=false
///
/// So every `(NSApp.delegate as? AppDelegate)` in this app silently did nothing:
/// the settings window was never registered (the refused 退出 closed nothing) and
/// 退出 / 重启应用 never marked their request as intentional — which the terminate
/// gate then refused, leaving no way out of the app. Everything that needs the
/// delegate goes through this registry instead.
///
/// A protocol rather than a direct `AppDelegate` reference because the files that
/// open those windows (`CustomCompressionDialogWindow.swift`) are compiled into the
/// test target as well, and `AppDelegate` lives in `MenuRightApp.swift`, which owns
/// `@main` and cannot be.
protocol MainAppGate: AnyObject {
    /// Ends the app for real: 退出 in the menu bar item, 重启应用 in settings.
    ///
    /// Marking the request as intentional is not enough on its own — see
    /// `AppDelegate.quit()` for why the terminate has to be finished by hand.
    func quit()

    /// Registers (or, with `nil`, forgets) the settings window, so the refused-quit
    /// path closes exactly that window instead of guessing from `NSApp.windows`.
    func register(settingsWindow window: NSWindow?)

    /// Registers (or, with `nil`, forgets) a window the app opened above the
    /// settings window, so it goes down together with it.
    func register(auxiliaryWindow window: NSWindow?)
}

/// Where `AppDelegate` publishes itself (in `init`) and where everyone else picks
/// it up — including code compiled into the test target, which cannot name
/// `AppDelegate`.
enum MainAppGateRegistry {
    static weak var gate: (any MainAppGate)?
}

/// The app-lifecycle rule the menu bar item depends on.
///
/// It lives in its own type rather than inside `AppDelegate` because the test
/// target cannot compile `MenuRightApp.swift` (it owns `@main`): the rule would
/// then only be assertable by reading the source. `StatusMenuTests` checks the
/// value here *and* guards that the delegate actually forwards to it.
enum AppLifecycle {
    /// `applicationShouldTerminateAfterLastWindowClosed`.
    ///
    /// **`false` is the whole point of the menu bar item.** The Finder extension
    /// is started and stopped by Finder, and every MenuRight menu item delegates
    /// its real work to this process over the App-Group socket. If the app ended
    /// with its window, right-clicking a file would show a menu whose every entry
    /// answers "主应用未运行" — which is exactly what happened when the app was
    /// closed while the user expected it to keep running. 退出 in the menu bar
    /// item is the way out (see `shouldTerminate` for why ⌘Q is not).
    static let terminatesAfterLastWindowClosed = false

    /// `applicationShouldTerminate` — may a terminate request really end the app?
    ///
    /// **Only a request that came from inside the app may.** macOS also offers
    /// 退出 on the Dock icon and ⌘Q in the app menu; neither is the user asking
    /// for the *background service* to stop, and ending the process there takes
    /// the IPC listener down — after which every Finder menu entry answers
    /// 主应用未运行. Those requests therefore only dismiss the settings window
    /// (the menu bar item's 打开设置 recreates it).
    ///
    /// Shutdown, restart and logout must never be refused, which is what
    /// `systemIsPoweringOff` carries in from `NSWorkspace.willPowerOffNotification`.
    static func shouldTerminate(
        intentionalQuitRequested: Bool,
        systemIsPoweringOff: Bool
    ) -> Bool {
        intentionalQuitRequested || systemIsPoweringOff
    }

    /// May the refused-quit path close this window?
    ///
    /// Closing the app's own windows is all a refused 退出 may do — and the app's
    /// window list contains more than those. The menu bar item has a window of its
    /// own (`NSStatusBarWindow`), it sits at level `.statusBar` (25), and it is a
    /// plain `NSWindow`, so a sweep over `NSApp.windows` that only excludes
    /// `NSPanel` closes it too: the icon stays on screen but stops answering clicks
    /// (regression found on 2026-10-03, minutes after the first version of this
    /// feature shipped). Everything a menu bar item or a popup owns lives at or
    /// above `.mainMenu` (24), so refusing everything from `.mainMenu` up is what
    /// keeps the menu bar item alive — `.statusBar` (25) alone would still let a
    /// main-menu window through. Panels (alerts, password prompts) stay because they
    /// are a decision in flight, not UI to dismiss.
    static func mayDismiss(windowLevel: Int, isVisible: Bool, isPanel: Bool) -> Bool {
        isVisible && !isPanel && windowLevel < NSWindow.Level.mainMenu.rawValue
    }
}
