import Foundation

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
    /// closed while the user expected it to keep running. The status menu's 退出
    /// (or ⌘Q) is the way out.
    static let terminatesAfterLastWindowClosed = false
}
