import SwiftUI
import AppKit
import os

/// P5-0.5: AppDelegate is the stable, process-lifetime owner of the IPC
/// server. It is created by `@NSApplicationDelegateAdaptor` BEFORE `body` is
/// ever evaluated, and it survives until the process exits. The IPC server is
/// a strong instance variable; it cannot be deallocated mid-life because no
/// SwiftUI view evaluation participates in its lifetime.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let log = Logger(subsystem: MenuRightIPC.subsystem, category: "app-delegate")

    /// Strong, process-lifetime owner. Started in `applicationWillFinishLaunching`
    /// (not `didFinishLaunching`) so the listener is up before SwiftUI starts
    /// evaluating any views — guarantees the endpoint file is written before
    /// the extension's first `connect()` probe after the next Finder respawn.
    let ipcServer = MainAppIPCServer()

    override init() {
        super.init()
        LifecycleDiagnostics.record("AppDelegate.init", from: "main-app")
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        LifecycleDiagnostics.record("applicationWillFinishLaunching", from: "main-app")
        Self.log.info("MAIN-APP applicationWillFinishLaunching entered")
        // Bring up the listener EARLY so the endpoint is on disk before any
        // window/scene work begins.
        ipcServer.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LifecycleDiagnostics.record("applicationDidFinishLaunching", from: "main-app")
        Self.log.info("MAIN-APP applicationDidFinishLaunching entered")
        // Fallback if the earlier willFinishLaunching start failed for any
        // reason (e.g. App Group not yet available in the very first call).
        // start() is idempotent and serialized internally, so we never read its
        // lifecycle state from this thread.
        ipcServer.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        LifecycleDiagnostics.record("applicationDidBecomeActive", from: "main-app")
        Self.log.info("MAIN-APP applicationDidBecomeActive")
    }

    func applicationWillTerminate(_ notification: Notification) {
        LifecycleDiagnostics.record("applicationWillTerminate", from: "main-app")
        ipcServer.stop()
    }
}

@main
struct MenuRightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate: AppDelegate

    init() {
        LifecycleDiagnostics.record("MenuRightApp.init", from: "main-app")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    LifecycleDiagnostics.record("ContentView.onAppear", from: "main-app")
                }
        }
        .onChange(of: ScenePhase.background) { _, _ in }
    }
}
