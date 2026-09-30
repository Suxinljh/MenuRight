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
        #if DEBUG
        // Diagnostic hook for operations that depend on LaunchServices rather
        // than the file system (spike S1: can a sandboxed app hand a directory
        // to Terminal?). It runs the *real* dispatcher under the *real* sandbox
        // and then exits, so the answer does not require a signed extension:
        //
        //   MENURIGHT_SELFTEST_OPEN_TERMINAL=/some/dir \
        //     .../MenuRight.app/Contents/MacOS/MenuRight
        if runOpenTerminalSelfTestIfRequested() {
            NSApp.terminate(nil)
            return
        }
        #endif
        // Bring up the listener EARLY so the endpoint is on disk before any
        // window/scene work begins.
        ipcServer.start()
    }

    #if DEBUG
    /// Runs the real `openTerminal` dispatch path once and reports the outcome.
    /// Returns true when the self-test was requested (caller should exit).
    private func runOpenTerminalSelfTestIfRequested() -> Bool {
        guard let directory = ProcessInfo.processInfo.environment["MENURIGHT_SELFTEST_OPEN_TERMINAL"],
              !directory.isEmpty else { return false }
        let request = FileOperationContract.Request(
            kind: .openTerminal,
            args: FileOperationContract.OperationArgs(directory: directory),
            clientRequestId: UUID().uuidString
        )
        guard let data = try? JSONEncoder().encode(request),
              let payload = String(data: data, encoding: .utf8) else {
            Self.log.error("SELFTEST openTerminal: request encoding failed")
            return true
        }
        let response = FileOperationDispatcher().dispatch(payload: payload)
        let described: String
        switch response {
        case .success(let createdPath): described = "SUCCESS createdPath=\(createdPath ?? "<none>")"
        case .batchSuccess(let items): described = "BATCH items=\(items.count)"
        case .failure(let code, let message): described = "FAILURE code=\(code.rawValue) message=\(message)"
        }
        Self.log.notice("SELFTEST openTerminal dir=\(directory, privacy: .public) -> \(described, privacy: .public)")
        LifecycleDiagnostics.record("SELFTEST openTerminal dir=\(directory) -> \(described)", from: "main-app")
        return true
    }
    #endif

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
        // Self-heal: if a leftover instance owned the socket when we launched and
        // the retry budget ran out, try again now. `start()` is a no-op while
        // running or while a retry is pending, so this is cheap.
        ipcServer.start()
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
