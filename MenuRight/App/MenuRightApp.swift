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

        // P6-b: publish which new-file kinds this build can actually create
        // (does the bundle carry Templates/blank.pages?), so the extension's
        // submenu never offers an action that is guaranteed to fail. A handful
        // of `fileExists` calls on our own bundle, once per launch — the answer
        // cannot change while the app runs. Runs before the DEBUG self-test
        // hooks so those can report what was published.
        DocumentTemplateCatalog.publishAvailability()

        #if DEBUG
        // Spike S6: can a sandboxed MenuRight open a favorite folder / website /
        // application? Runs the real opener once and reports the outcome, so the
        // answer is measured rather than assumed.
        if runOpenTargetSelfTestIfRequested() {
            NSApp.terminate(nil)
            return
        }
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
        // Diagnostic hook for the settings store (see runSettingsSelfTest).
        if runSettingsSelfTestIfRequested() {
            NSApp.terminate(nil)
            return
        }
        // Review hooks: pin the window appearance, and optionally resize the
        // window so a long pane fits in one screenshot (see below).
        applyForcedAppearanceIfRequested()
        applyForcedWindowSizeIfRequested()
        #endif
        // Bring up the listener EARLY so the endpoint is on disk before any
        // window/scene work begins.
        ipcServer.start()
    }

    #if DEBUG
    /// Pins the app-wide appearance for review:
    ///
    ///   MENURIGHT_FORCE_APPEARANCE=dark   (or `light`)
    ///
    /// A command-line `-AppleInterfaceStyle Dark` does not switch this app, and
    /// changing the system appearance in System Settings just to take a
    /// screenshot is not acceptable, so the override lives here.
    private func applyForcedAppearanceIfRequested() {
        switch ProcessInfo.processInfo.environment["MENURIGHT_FORCE_APPEARANCE"]?.lowercased() {
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        default:
            break
        }
    }

    /// Resizes the main window for review screenshots:
    ///
    ///   MENURIGHT_REVIEW_WINDOW=1000x1180
    ///
    /// Several panes (and the reset button in General) sit below the fold at the
    /// default 1080x720, and this pane cannot be scrolled from a script.
    private func applyForcedWindowSizeIfRequested() {
        guard let spec = ProcessInfo.processInfo.environment["MENURIGHT_REVIEW_WINDOW"] else { return }
        let parts = spec.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 200, parts[1] > 200 else { return }
        let size = NSSize(width: parts[0], height: parts[1])
        // SwiftUI creates its window some time after didFinishLaunching, and how
        // long that takes is not fixed. The original two-shot retry (0 and 0.4 s)
        // could miss the window entirely and leave this a silent no-op: measured
        // 2026-10-01, a 1100x1200 request left the 960x692 default in place.
        // Keep insisting rather than resizing once — SwiftUI also re-applies its
        // own default size while the scene settles, so a single set is not enough.
        var attempts = 0
        func resize() {
            attempts += 1
            // Prefer the visible window, but do not require it: a SwiftUI window
            // can still report `isVisible == false` while it is being brought up,
            // and filtering on it was enough to make this hook a silent no-op.
            let windows = NSApp.windows
            if let window = windows.first(where: { $0.isVisible }) ?? windows.first {
                window.setContentSize(size)
                window.center()
                NSLog("[MenuRight] review window sized to %@ after %d attempt(s)",
                      NSStringFromSize(size), attempts)
                return
            }
            guard attempts < 50 else { return }     // ~5 s, then leave the user alone
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: resize)
        }
        resize()
    }

    /// Exercises the App-Group settings path under the real sandbox, without the
    /// UI. Unit tests use a scratch `UserDefaults` suite, so this is the only way
    /// to prove the group suite actually writes and survives a relaunch:
    ///
    ///   MENURIGHT_SELFTEST_SETTINGS=read   → print what this process sees
    ///   MENURIGHT_SELFTEST_SETTINGS=write  → change one value and print it back
    ///   MENURIGHT_SELFTEST_SETTINGS=reset  → restore that value to its default
    ///
    /// The sequence read → write → read (new process) → reset is the check.
    private func runSettingsSelfTestIfRequested() -> Bool {
        guard let mode = ProcessInfo.processInfo.environment["MENURIGHT_SELFTEST_SETTINGS"],
              !mode.isEmpty else { return false }

        let defaults = SettingsStore.defaultUserDefaults()
        let store = SettingsStore.shared
        let sizeLimit = store.settings.archives.sizeLimitMB
        // P6-b: what this process published for the Finder submenu. `read` after
        // a `write` therefore proves the payload survives a process boundary,
        // exactly like the settings tree above it.
        let availability = NewFileAvailability.read(from: defaults)
        let creatable = availability?.creatableTypes.joined(separator: ",") ?? "<none>"
        let missingTemplates = DocumentTemplateCatalog
            .missingTemplateTypes(in: DocumentTemplateCatalog.bundledDirectory)
            .map(\.rawValue)
            .joined(separator: ",")
        var fields = [
            "mode=\(mode)",
            "appGroupSuite=\(defaults !== UserDefaults.standard)",
            "sizeLimitMB=\(sizeLimit)",
            "language=\(store.settings.general.language.rawValue)",
            "theme=\(store.settings.codeTheme.themeID)",
            "favoriteFolders=\(store.settings.favoriteFolders.count)",
            "licenceNotices=\(ThirdPartyNotices.load().count)",
            "newFileCreatable=\(creatable)",
            "newFileMissingTemplates=\(missingTemplates)",
        ]

        switch mode {
        case "write":
            let marker = Int(Date().timeIntervalSince1970) % 8000 + 1
            store.mutate { $0.archives.sizeLimitMB = marker }
            let inMemory = store.settings.archives.sizeLimitMB
            let readBack = SettingsStore.read(from: defaults).archives.sizeLimitMB
            fields.append("wrote=\(marker) inMemory=\(inMemory) freshRead=\(readBack)")
        case "reset":
            store.mutate { $0.archives.sizeLimitMB = ArchiveSettings.defaultSizeLimitMB }
            fields.append("resetTo=\(store.settings.archives.sizeLimitMB)")
        default:
            break
        }

        let summary = fields.joined(separator: " ")
        print("SELFTEST settings \(summary)")
        Self.log.notice("SELFTEST settings \(summary, privacy: .public)")
        LifecycleDiagnostics.record("SELFTEST settings \(summary)", from: "main-app")
        return true
    }

    /// Runs the real favorites opener once and reports the outcome.
    ///
    ///   MENURIGHT_SELFTEST_OPEN_TARGET=folder:/tmp \
    ///     .../MenuRight.app/Contents/MacOS/MenuRight
    ///   MENURIGHT_SELFTEST_OPEN_TARGET=url:https://example.com ...
    ///   MENURIGHT_SELFTEST_OPEN_TARGET=app:/System/Applications/Calculator.app ...
    ///   MENURIGHT_SELFTEST_OPEN_TARGET=bundle:com.apple.TextEdit ...
    ///
    /// The point is spike S6: `NSWorkspace.open(_:withApplicationAt:)` is denied
    /// inside the App Sandbox (measured for Terminal, see `SystemOpener`), so
    /// "常用软件" needs to know whether the default-handler route is permitted
    /// before the feature is described as working.
    /// Returns true when the self-test was requested (caller should exit).
    private func runOpenTargetSelfTestIfRequested() -> Bool {
        guard let spec = ProcessInfo.processInfo.environment["MENURIGHT_SELFTEST_OPEN_TARGET"],
              let separator = spec.firstIndex(of: ":"),
              separator != spec.startIndex
        else { return false }
        let kind = String(spec[spec.startIndex..<separator])
        let target = String(spec[spec.index(after: separator)...])
        guard !target.isEmpty else { return false }

        let opener = SystemOpener.system
        let error: Error?
        switch kind {
        case "folder":
            error = opener.openFolder(URL(fileURLWithPath: target))
        case "url":
            if let url = URL(string: target) {
                error = opener.openURL(url)
            } else {
                error = NSError(domain: "xin.ljhsu.MenuRight.selftest", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "not a URL: \(target)"])
            }
        case "app", "bundle":
            error = opener.openApplication(target)
        default:
            return false
        }

        let described = error.map { "FAILURE error=\($0.localizedDescription)" } ?? "SUCCESS"
        let summary = "openTarget kind=\(kind) target=\(target) -> \(described)"
        print("SELFTEST \(summary)")
        Self.log.notice("SELFTEST \(summary, privacy: .public)")
        LifecycleDiagnostics.record("SELFTEST \(summary)", from: "main-app")
        return true
    }

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
        // Make sure every favorite has its PNG in the App Group. The Finder
        // submenu reads those files, and without this the icons would be missing
        // until the user happened to open each favorites pane. A no-op (one file
        // check per entry) once the icons are in place.
        FavoriteIconBootstrap.run(store: SettingsStore.shared)

        // Update check: one HTTPS request, throttled to once a day, silent on
        // failure. Raised from the delegate rather than a view so a new version
        // is announced even when the user never opens the settings window.
        Task { @MainActor in
            if let release = await UpdateChecker.shared.checkAutomaticallyIfNeeded() {
                UpdatePrompter.present(release)
            }
        }
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
        WindowGroup("MenuRight") {
            ContentView()
                .onAppear {
                    LifecycleDiagnostics.record("ContentView.onAppear", from: "main-app")
                }
        }
        // The settings UI is the app's main window; open it at a size where the
        // sidebar and a pane are both comfortable.
        .defaultSize(width: 1080, height: 720)
        .onChange(of: ScenePhase.background) { _, _ in }
    }
}
