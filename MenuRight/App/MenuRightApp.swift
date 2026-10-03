import SwiftUI
import AppKit
import os

/// P5-0.5: AppDelegate is the stable, process-lifetime owner of the IPC
/// server. It is created by `@NSApplicationDelegateAdaptor` BEFORE `body` is
/// ever evaluated, and it survives until the process exits. The IPC server is
/// a strong instance variable; it cannot be deallocated mid-life because no
/// SwiftUI view evaluation participates in its lifetime.
final class AppDelegate: NSObject, NSApplicationDelegate, MainAppGate {
    static let log = Logger(subsystem: MenuRightIPC.subsystem, category: "app-delegate")

    /// Strong, process-lifetime owner. Started in `applicationWillFinishLaunching`
    /// (not `didFinishLaunching`) so the listener is up before SwiftUI starts
    /// evaluating any views — guarantees the endpoint file is written before
    /// the extension's first `connect()` probe after the next Finder respawn.
    let ipcServer = MainAppIPCServer()

    /// Keeps the published new-file availability in step with 设置 → 新建文件
    /// (the template folder is configurable, P7).
    private var newFileSettingsObserver: NSObjectProtocol?

    /// Set when something *inside* the app asks to quit for real: 退出 in the menu
    /// bar item, 重启应用, or a DEBUG self-test hook. `AppLifecycle.shouldTerminate`
    /// needs it to tell those apart from the Dock icon's 退出 and ⌘Q, which must
    /// only dismiss the settings window.
    private var quitRequested = false

    /// Set from `NSWorkspace.willPowerOffNotification`. Logout, restart and
    /// shutdown also arrive as terminate requests, and refusing one would stall
    /// the shutdown — so they are never refused.
    private var systemIsPoweringOff = false

    private var powerOffObserver: NSObjectProtocol?

    /// The window the settings scene built, as reported by `SettingsWindowReader`.
    ///
    /// Weak because AppKit owns it. This is the only window a refused 退出 closes
    /// besides `auxiliaryWindow`: sweeping `NSApp.windows` would include the menu
    /// bar item's window and leave the status item deaf (see
    /// `dismissRegularWindows` and `AppLifecycle.mayDismiss`).
    private weak var settingsWindow: NSWindow?

    /// A window the app opened above the settings window, such as the
    /// custom-compression dialog, registered so it goes down with it.
    private weak var auxiliaryWindow: NSWindow?

    /// The live delegate, published through `MainAppGateRegistry` at init.
    ///
    /// `NSApp.delegate as? AppDelegate` does not work: SwiftUI puts its own
    /// `SwiftUI.AppDelegate` there (measured 2026-10-03), so that cast always
    /// answered nil. See `MainAppGate`.
    override init() {
        super.init()
        MainAppGateRegistry.gate = self
        LifecycleDiagnostics.record("AppDelegate.init", from: "main-app")
    }

    /// Remembers the settings window. Called by the settings scene through
    /// `SettingsWindowReader` whenever SwiftUI moves that view into a window, and
    /// with `nil` when it leaves one.
    func register(settingsWindow window: NSWindow?) {
        settingsWindow = window
        #if DEBUG
        if ProcessInfo.processInfo.environment["MENURIGHT_SELFTEST_REFUSED_QUIT"] == "1" {
            print(
                "SELFTEST register(settingsWindow:) self=\(ObjectIdentifier(self))"
                    + " window=\(window != nil) stored=\(settingsWindow != nil)"
                    + " isDelegate=\((NSApp.delegate as AnyObject?) === self)"
            )
        }
        #endif
    }

    /// Remembers a window the app opened above the settings window, so the refused
    /// 退出 path closes it too. The dialog presenter calls this.
    func register(auxiliaryWindow window: NSWindow?) {
        auxiliaryWindow = window
    }

    /// Ends the app for real. The menu bar item's 退出 and 重启应用 reach this
    /// through `MainAppGateRegistry`.
    ///
    /// **`NSApp.terminate(nil)` does not end this app on its own.** SwiftUI installs
    /// its own `SwiftUI.AppDelegate` as `NSApp.delegate` and forwards only the
    /// callbacks it chooses; a direct terminate request never reaches
    /// `applicationShouldTerminate` and the process keeps running (measured
    /// 2026-10-03 on a real `open`-launched instance, with the intent already
    /// marked; `NSRunningApplication.current.terminate()` behaves the same). A
    /// background app whose 退出 does nothing has no way out at all, so the request
    /// is made the normal way and then finished by hand.
    func quit() {
        quitRequested = true
        LifecycleDiagnostics.record("quit requested from inside the app", from: "main-app")
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitGracePeriod) { [weak self] in
            self?.finishQuitDirectly()
        }
    }

    /// How long AppKit gets to honour the terminate request before `quit()` stops
    /// waiting for it.
    private static let quitGracePeriod: TimeInterval = 0.75

    /// The half of `quit()` that does not depend on AppKit: stop the IPC listener
    /// exactly as `applicationWillTerminate` does, then leave. Reached only when the
    /// terminate request in `quit()` had no effect.
    private func finishQuitDirectly() {
        Self.log.notice("MAIN-APP AppKit did not terminate the app; finishing the quit directly")
        LifecycleDiagnostics.record(
            "AppKit did not terminate the app; finishing the quit directly",
            from: "main-app"
        )
        ipcServer.stop()
        exit(0)
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
        DocumentTemplateCatalog.publishAvailability(settings: SettingsStore.shared.settings.newFile)
        // P7: the template folder is configurable, so the answer *can* change
        // while the app runs. Republish on every settings change; the extension
        // reads the payload on its next menu build, which hides the kinds the
        // new folder cannot supply.
        //
        // 但这条通知对「无关写入」也会发（更新检查时间戳、TextField 的每次击键），
        // 而 `publishAvailability` 每次都会做磁盘 IO，所以只在 新建文件 段真正
        // 变化时才发布。缓存用局部类包一层：@Sendable 的观察者闭包不能捕获可变
        // 局部变量，而引用类型可以。
        final class LastPublishedNewFile: @unchecked Sendable {
            var value: NewFileSettings?
        }
        let lastPublishedNewFile = LastPublishedNewFile()
        // :128 刚刚发布过同一个值，先记下来，免得第一条无关通知再发一次。
        lastPublishedNewFile.value = SettingsStore.shared.settings.newFile
        newFileSettingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            let newFile = SettingsStore.shared.settings.newFile
            guard lastPublishedNewFile.value != newFile else { return }
            lastPublishedNewFile.value = newFile
            DocumentTemplateCatalog.publishAvailability(settings: newFile)
        }

        // Logout / restart / shutdown: the system asks the app to quit as well,
        // and `applicationShouldTerminate` must let those through (see there).
        // `willPowerOff` is posted before the terminate request arrives.
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.systemIsPoweringOff = true
        }

        #if DEBUG
        // The self-test hooks below end the app themselves, so they must mark the
        // quit as intentional — otherwise `applicationShouldTerminate` would
        // cancel their own terminate request and the app would never exit. They set
        // the flag directly and keep using `NSApp.terminate(nil)`: they are DEBUG
        // probes, and each one has an `exit` behind it.
        // Spike S6: can a sandboxed MenuRight open a favorite folder / website /
        // application? Runs the real opener once and reports the outcome, so the
        // answer is measured rather than assumed.
        if runOpenTargetSelfTestIfRequested() {
            quitRequested = true
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
            quitRequested = true
            NSApp.terminate(nil)
            return
        }
        // Diagnostic hook for the settings store (see runSettingsSelfTest).
        if runSettingsSelfTestIfRequested() {
            quitRequested = true
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

    /// Reproduces a Finder 「自定义压缩…」 in the state that used to fail: the app
    /// is running with **no window open**, which is where the user is left by
    /// 关窗口 (`applicationShouldTerminateAfterLastWindowClosed` is false, so the
    /// app stays up as a menu bar item).
    ///
    ///   MENURIGHT_SELFTEST_ARCHIVE_DIALOG=~/Desktop \
    ///     .../MenuRight.app/Contents/MacOS/MenuRight
    ///
    /// Optional `MENURIGHT_SELFTEST_ARCHIVE_DIALOG_KEEP=1` leaves the dialog on
    /// screen instead of quitting — that is how it gets screenshotted.
    /// Optional `MENURIGHT_SELFTEST_ARCHIVE_DIALOG_PNG=/tmp/dialog.png` renders
    /// the dialog to a PNG (no screen-recording permission needed).
    ///
    /// The directory has to be one the user authorized (the dispatcher refuses
    /// anything else as `pathOutsideAuthorizedScope`). Nothing has to be written
    /// for this check — the run stops at the dialog, never at 保存 — so a sandbox
    /// denial while preparing the little fixture is reported and ignored.
    ///
    /// It closes every window, runs the *real* dispatcher with `customize: true`,
    /// and reports `dialogVisible`. Until 2026-10-03 the dialog was a sheet on the
    /// settings window, so this printed `dialogVisible=false` while the log still
    /// claimed `ARCHIVE dialog presented` — the false positive that made the
    /// feature look verified. Returns true when the self-test was requested; the
    /// caller must not terminate, because this hook exits by itself once the
    /// dialog has been checked.
    private func runArchiveDialogSelfTestIfRequested() -> Bool {
        guard let directoryPath = ProcessInfo.processInfo.environment["MENURIGHT_SELFTEST_ARCHIVE_DIALOG"],
              !directoryPath.isEmpty else { return false }
        let keep = ProcessInfo.processInfo.environment["MENURIGHT_SELFTEST_ARCHIVE_DIALOG_KEEP"] == "1"

        // `~` is not expanded by the kernel on an env value.
        let root = URL(fileURLWithPath: (directoryPath as NSString).expandingTildeInPath, isDirectory: true)
        let folder = root.appendingPathComponent("MenuRight-Selftest", isDirectory: true)
        let source = folder.appendingPathComponent("selftest-source.txt")
        let fixture: String
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: source.path) {
                try Data("MenuRight archive-dialog self-test\n".utf8).write(to: source)
            }
            fixture = "written"
        } catch {
            // A sandboxed app cannot write into ~/Desktop without a scoped
            // bookmark, and the check does not need the file to exist.
            fixture = "skipped(\(error.localizedDescription))"
        }

        // Optional: an in-memory 密码本 with one entry, so the dialog's 密码本 button
        // is on screen in the PNG. Never the real Keychain.
        if ProcessInfo.processInfo.environment["MENURIGHT_SELFTEST_ARCHIVE_DIALOG_PASSWORD_BOOK"] == "1" {
            let book = MainActor.assumeIsolated {
                let book = ArchivePasswordBook(storage: InMemoryArchivePasswordBookStorage())
                book.add(name: "webp_images.zip", password: "hunter2")
                return book
            }
            CustomCompressionDialogWindow.shared.passwordBookProvider = { book }
        }

        // SwiftUI brings its window up some time after didFinishLaunching, and
        // "close every window" only means something once one exists.
        var attempts = 0
        func closeEveryWindowAndDispatch() {
            attempts += 1
            if !NSApp.windows.contains(where: { $0.isVisible }), attempts < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: closeEveryWindowAndDispatch)
                return
            }
            let visibleBefore = NSApp.windows.filter { $0.isVisible }.count
            NSApp.windows.forEach { $0.close() }
            let visibleAfterClose = NSApp.windows.filter { $0.isVisible }.count

            let request = FileOperationContract.Request(
                kind: .compressItems,
                args: FileOperationContract.OperationArgs(
                    sourcePaths: [source.path],
                    destinationDirectory: folder.path,
                    // `_FORMAT=7z` opens the dialog on a format that can carry all
                    // three options, which is what the PNG is for.
                    archiveFormat: ProcessInfo.processInfo.environment["MENURIGHT_SELFTEST_ARCHIVE_DIALOG_FORMAT"] ?? "zip",
                    customize: true
                ),
                clientRequestId: UUID().uuidString
            )
            guard let data = try? JSONEncoder().encode(request),
                  let payload = String(data: data, encoding: .utf8) else {
                self.reportSelfTest("archiveDialog ENCODING-FAILURE", keep: keep)
                return
            }
            let described: String
            switch FileOperationDispatcher().dispatch(payload: payload) {
            case .success(let createdPath): described = "SUCCESS createdPath=\(createdPath ?? "<none>")"
            case .batchSuccess(let items): described = "BATCH items=\(items.count)"
            case .failure(let code, let message): described = "FAILURE code=\(code.rawValue) message=\(message)"
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let dialog = NSApp.windows.first {
                    $0.identifier == CustomCompressionDialogWindow.windowIdentifier
                }
                var fields = [
                    "dir=\(folder.path)",
                    "fixture=\(fixture)",
                    "visibleBefore=\(visibleBefore)",
                    "visibleAfterClose=\(visibleAfterClose)",
                    "dispatch=\(described)",
                    "pending=\(ArchiveRequestCenter.shared.pending != nil)",
                    "dialogWindow=\(dialog != nil)",
                    "dialogVisible=\(dialog?.isVisible == true)",
                ]
                // Renders the dialog to a PNG so its layout can be eyeballed
                // without a Finder click and without screen-recording rights.
                // The form has no background of its own, so it is composited over
                // the window colour — otherwise the PNG is mostly transparent.
                if let pngPath = ProcessInfo.processInfo.environment["MENURIGHT_SELFTEST_ARCHIVE_DIALOG_PNG"],
                   !pngPath.isEmpty,
                   let view = dialog?.contentView {
                    fields.append(self.writePNG(of: view, over: dialog?.backgroundColor, to: pngPath))
                }

                // 确定 does its write long after `dispatch` returned, so it has to
                // take its own security-scoped access. This drives the exact path
                // the sheet's button uses, and then reads the same source once
                // more *without* that wrapper as a negative control: the sandbox
                // denies it, which is the “you don't have permission to view it”
                // the user reported.
                if ProcessInfo.processInfo.environment["MENURIGHT_SELFTEST_ARCHIVE_DIALOG_CONFIRM"] == "1",
                   let pending = ArchiveRequestCenter.shared.pending {
                    let confirmEnv = ProcessInfo.processInfo.environment
                    let confirmFormat = confirmEnv["MENURIGHT_SELFTEST_ARCHIVE_DIALOG_CONFIRM_FORMAT"]
                        .flatMap { ArchiveFormat(rawValue: $0) } ?? pending.format
                    let confirmName = "selftest-confirm.\(ArchiveCompressor.fileNameExtension(for: confirmFormat) ?? "zip")"
                    let confirmSolid = confirmEnv["MENURIGHT_SELFTEST_ARCHIVE_DIALOG_CONFIRM_SOLID"] != "0"
                    let confirmFileNames = confirmEnv["MENURIGHT_SELFTEST_ARCHIVE_DIALOG_CONFIRM_FILE_NAMES"] == "1"
                    let confirmSplit = confirmEnv["MENURIGHT_SELFTEST_ARCHIVE_DIALOG_CONFIRM_SPLIT"].flatMap { Int($0) }
                    // Set this to reproduce the user's 加密压缩 flow: the password
                    // travels the same road as the sheet's does.
                    let confirmPassword = confirmEnv["MENURIGHT_SELFTEST_ARCHIVE_DIALOG_CONFIRM_PASSWORD"]
                        .flatMap { $0.isEmpty ? nil : $0 }
                    let outcome: String
                    var written: URL?
                    do {
                        let report = try FileOperationDispatcher().performCustomCompression(
                            sources: pending.sources,
                            into: pending.directory,
                            preferredName: confirmName,
                            format: confirmFormat,
                            mode: pending.mode,
                            label: nil,
                            password: confirmPassword,
                            solid: confirmSolid,
                            encryptsFileNames: confirmFileNames,
                            volumeSizeMB: confirmSplit,
                            settings: SettingsStore.shared.settings.archives,
                            control: nil
                        )
                        written = report.archiveURL
                        outcome = "SUCCESS path=\(report.archiveURL.path)"
                    } catch {
                        outcome = "FAILURE \(error)"
                    }
                    fields.append("confirm=\(outcome)")

                    // What was written has to read back: a split set through its
                    // `.001`, an encrypted 7z with the password just typed. (This
                    // is a direct extract, so it takes the scoped access by hand,
                    // exactly like the fixture above.)
                    if let written {
                        do {
                            fields.append("confirmParts=\(ArchiveVolumeSet.existingParts(firstPart: written).count)")
                            let out = pending.directory.appendingPathComponent("selftest-confirm-out", isDirectory: true)
                            let folders = FolderAuthorizationStore.appGroupDefault()?.loadFolders() ?? []
                            try FolderAuthorizationAccess.withAccesses(to: [pending.directory], folders: folders) {
                                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                                // A 7z keeps its header at the *end*, so an
                                // encrypted, split set can only be judged after
                                // the parts are stitched back together — which is
                                // exactly what the extractor does too.
                                let volumes = try ArchiveVolumeSet.resolve(written)
                                defer { volumes.discard() }
                                // Same probe the extraction path uses, so the
                                // field means "would this ask for a password"
                                // for zip and 7z alike.
                                fields.append("confirmEncrypted=\((try? ArchivePasswordResolver.probe(for: volumes.url))?.needsPassword == true)")
                                let (results, summary) = try ArchiveExtractor.extract(
                                    archiveURL: written,
                                    to: out,
                                    settings: SettingsStore.shared.settings.archives,
                                    password: confirmPassword
                                )
                                let names = results.filter { $0.outcome == .written }.map(\.entryName).joined(separator: ",")
                                fields.append("confirmExtract=written:\(summary.written) failed:\(summary.failed) names:\(names)")
                            }
                        } catch {
                            fields.append("confirmExtract=FAILURE \(error)")
                        }
                    }
                    let unscoped: String
                    do {
                        _ = try Data(contentsOf: pending.sources[0])
                        unscoped = "READABLE"
                    } catch {
                        unscoped = "DENIED(\(error.localizedDescription))"
                    }
                    fields.append("unscopedRead=\(unscoped)")
                }

                guard !keep, dialog?.isVisible == true else {
                    self.reportSelfTest(fields.joined(separator: " "), keep: keep)
                    return
                }
                // 取消 has to take the window away again: that is the other half
                // of "the dialog owns itself" rather than the settings window.
                ArchiveRequestCenter.shared.dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    fields.append("dismissedVisible=\(dialog?.isVisible == true)")
                    self.reportSelfTest(fields.joined(separator: " "), keep: false)
                }
            }
        }
        closeEveryWindowAndDispatch()
        return true
    }

    /// Renders one view to a PNG at `path`, and returns a short status line.
    ///
    /// The SwiftUI forms have no background of their own, so a raw
    /// `cacheDisplay` dump is transparent wherever the window shows through — and
    /// its light text then reads as white-on-white. The window colour is painted
    /// underneath, and the dump is drawn as an image with an explicit
    /// source-over blend (`NSBitmapImageRep.draw(in:)` would copy, punching the
    /// background back out).
    private func writePNG(of view: NSView, over background: NSColor?, to path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        view.layoutSubtreeIfNeeded()
        let bounds = NSRect(origin: .zero, size: view.bounds.size)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return "png=REP-FAILED"
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let width = rep.pixelsWide, height = rep.pixelsHigh
        guard let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: canvas) else {
            return "png=ENCODE-FAILED"
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let full = NSRect(x: 0, y: 0, width: width, height: height)
        (background ?? NSColor.windowBackgroundColor).setFill()
        NSBezierPath(rect: full).fill()
        let image = NSImage(size: full.size)
        image.addRepresentation(rep)
        image.draw(in: full, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = canvas.representation(using: .png, properties: [:]) else {
            return "png=ENCODE-FAILED"
        }
        do {
            try data.write(to: URL(fileURLWithPath: expanded))
            return "png=\(expanded) size=\(bounds.size)"
        } catch {
            return "png=WRITE-FAILED \(error.localizedDescription)"
        }
    }

    /// Renders one settings pane to a PNG, off-screen, under the real sandbox.
    ///
    ///   MENURIGHT_SELFTEST_SETTINGS_PNG=<pane>:/abs/path.png
    ///   pane ∈ general | filePermissions | archives | codeTheme
    ///
    /// Added for the round that took the explanatory captions out of the front
    /// end: a pane's *whole* column (and the absence of a paragraph) is only
    /// checkable by looking at it, and the settings window cannot be scrolled
    /// from a script. Same rendering path as the password-book hook below.
    private func runSettingsPanePNGSelfTestIfRequested() -> Bool {
        guard let spec = ProcessInfo.processInfo.environment["MENURIGHT_SELFTEST_SETTINGS_PNG"],
              !spec.isEmpty,
              let separator = spec.firstIndex(of: ":") else { return false }
        let paneName = String(spec[spec.startIndex..<separator])
        let pngPath = String(spec[spec.index(after: separator)...])
        guard !pngPath.isEmpty else { return false }

        let store = SettingsStore.shared
        // A real Keychain read would block on an authorization prompt in a
        // self-test, so the archives pane gets the in-memory book.
        let book = MainActor.assumeIsolated {
            ArchivePasswordBook(storage: InMemoryArchivePasswordBookStorage())
        }
        let pane: AnyView
        switch paneName {
        case "general":
            pane = AnyView(GeneralSettingsView().environmentObject(store))
        case "filePermissions":
            pane = AnyView(FilePermissionSettingsView().environmentObject(store))
        case "archives":
            pane = AnyView(
                ArchiveSettingsView()
                    .environmentObject(store)
                    .environmentObject(book)
            )
        case "codeTheme":
            pane = AnyView(CodeThemeSettingsView().environmentObject(store))
        default:
            return false
        }

        let host = NSHostingView(rootView: pane)
        // Tall: several panes put their last card below the fold at the app's
        // default window size, and a clipped dump would hide exactly the part
        // these hooks exist for.
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 1_600)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.title = "Settings"
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let status = self.writePNG(of: host, over: window.backgroundColor, to: pngPath)
            self.reportSelfTest("settingsPane \(paneName) \(status)", keep: false)
        }
        return true
    }

    /// Renders 设置 → 解压缩管理 (where the 密码本 lives) to a PNG.
    ///
    ///   MENURIGHT_SELFTEST_PASSWORD_BOOK_PNG=~/…/password-book.png
    ///
    /// The rows come from an **in-memory** book, so a self-test run never writes a
    /// sample password into the real Keychain.
    private func runPasswordBookSelfTestIfRequested() -> Bool {
        guard let pngPath = ProcessInfo.processInfo.environment["MENURIGHT_SELFTEST_PASSWORD_BOOK_PNG"],
              !pngPath.isEmpty else { return false }
        // `ArchivePasswordBook` is main-actor isolated, and this hook runs from
        // `applicationDidFinishLaunching`, i.e. already on the main thread.
        let book = MainActor.assumeIsolated {
            let book = ArchivePasswordBook(storage: InMemoryArchivePasswordBookStorage())
            book.add(name: "工作邮箱", password: "s3cret")
            book.add(name: "备份盘", password: "hunter2")
            return book
        }
        let pane = ArchiveSettingsView()
            .environmentObject(SettingsStore.shared)
            .environmentObject(book)
        let host = NSHostingView(rootView: pane)
        // Tall enough for the whole pane: the 密码本 section is the last one, and
        // a shorter window would clip exactly the part this hook exists for.
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 1_500)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.title = "Archive"
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let status = self.writePNG(of: host, over: window.backgroundColor, to: pngPath)
            self.reportSelfTest("passwordBook \(status)", keep: false)
        }
        return true
    }

    /// Reproduces the report «通过软件加密压缩的文件，自己解压的时候发现无法解压»
    /// against the real sandbox, without a Finder click:
    ///
    ///   MENURIGHT_SELFTEST_ARCHIVE_UNLOCK=~/MenuRight-ScopeProbe \
    ///   [MENURIGHT_SELFTEST_ARCHIVE_UNLOCK_PASSWORD=hunter2] \
    ///   [MENURIGHT_SELFTEST_ARCHIVE_UNLOCK_ALERT=1] \
    ///   [MENURIGHT_SELFTEST_ARCHIVE_UNLOCK_PNG=~/…/unlock-alert.png]
    ///
    /// It compresses a file *with a password*, then extracts that archive again
    /// through the very dispatcher the IPC server uses, in up to three shapes:
    ///
    ///   * no prompter at all  → the archive is reported as protected (the state
    ///     the user hit: nothing asked, nothing written),
    ///   * `_PASSWORD` set     → a scripted prompter supplies the password (the
    ///     password book's road) and the file has to come back byte for byte,
    ///   * `_ALERT=1`          → the app's **real** prompt is raised, dumped to a
    ///     PNG and then cancelled, which must leave the destination empty.
    private func runArchiveUnlockSelfTestIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let directoryPath = env["MENURIGHT_SELFTEST_ARCHIVE_UNLOCK"],
              !directoryPath.isEmpty else { return false }
        let keep = env["MENURIGHT_SELFTEST_ARCHIVE_UNLOCK_KEEP"] == "1"
        let password = env["MENURIGHT_SELFTEST_ARCHIVE_UNLOCK_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 ?? nil } ?? "hunter2"
        let usesAlert = env["MENURIGHT_SELFTEST_ARCHIVE_UNLOCK_ALERT"] == "1"
        let root = URL(fileURLWithPath: (directoryPath as NSString).expandingTildeInPath)
            .appendingPathComponent("MenuRight-Unlock-Selftest", isDirectory: true)
        var fields = ["dir=\(root.path)"]

        func destination(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func dispatchExtract(
            archive: URL,
            into destination: URL,
            prompting: (any ArchivePasswordPrompting)?
        ) -> String {
            guard let payload = FileOperationContract.Request(
                kind: .extractArchive,
                args: FileOperationContract.OperationArgs(
                    sourcePaths: [archive.path],
                    destinationDirectory: destination.path
                ),
                clientRequestId: UUID().uuidString
            ).encodedForIPC() else { return "encode-failed" }
            // The same construction the IPC server uses, minus the socket.
            let dispatcher = FileOperationDispatcher(archivePasswordPrompting: prompting)
            let response = dispatcher.dispatch(payload: payload)
            switch response {
            case .batchSuccess(let items):
                let failed = items.filter { !$0.success }
                let message = failed.first?.message ?? items.first?.message ?? "-"
                return "batch(items=\(items.count) failed=\(failed.count) msg=\(message))"
            case .failure(let code, let message):
                return "failure(code=\(code) msg=\(message))"
            case .success(let createdPath):
                return "success(path=\(createdPath ?? "-"))"
            }
        }

        func extracted(_ destination: URL) -> Bool {
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("selftest-plain.txt").path)
        }

        do {
            // Fixture preparation touches the disk *outside* any dispatch, so it
            // needs the same security-scoped access the dispatcher takes later —
            // otherwise the sandbox answers "you don't have permission to save".
            let folders = FolderAuthorizationStore.appGroupDefault()?.loadFolders() ?? []
            var archive: URL!
            var lockedDestination: URL!
            var bookDestination: URL!
            var alertDestination: URL!
            try FolderAuthorizationAccess.withAccesses(to: [root], folders: folders) {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let source = root.appendingPathComponent("selftest-plain.txt")
                try Data("unlock me\n".utf8).write(to: source)
                let report = try ArchiveCompressor.compress(
                    [source],
                    into: root,
                    preferredName: "selftest-encrypted.zip",
                    format: .zip,
                    conflictPolicy: .keepBoth,
                    sizeLimitMB: 64,
                    password: password
                )
                archive = report.archiveURL
                lockedDestination = try destination("locked-out")
                bookDestination = try destination("book-out")
                alertDestination = try destination("alert-out")
            }
            fields.append("encrypted=\(archive.lastPathComponent)")

            // 1. Nothing can ask → the failure has to say why.
            fields.append("noPrompt=\(dispatchExtract(archive: archive, into: lockedDestination, prompting: nil))")
            fields.append("lockedExtracted=\(extracted(lockedDestination))")

            // 2. The password book's road: an automatic answer, no UI.
            fields.append("book=\(dispatchExtract(archive: archive, into: bookDestination, prompting: SelfTestPasswordPrompt(password: password)))")
            fields.append("bookExtracted=\(extracted(bookDestination))")

            guard usesAlert else {
                reportSelfTest(fields.joined(separator: " "), keep: keep)
                return true
            }

            // 3. The real prompt. It runs a modal session on the main thread while
            //    the dispatcher waits on a background queue. During that session the
            //    main *queue* is not drained (an `asyncAfter` would never fire), so
            //    both the inspection and the cancel have to come from run-loop
            //    timers registered in the modal mode.
            var alertResponse = "no-response"
            let done = DispatchSemaphore(value: 0)
            var finish: (() -> Void)!
            let inspect = Timer(timeInterval: 1.5, repeats: false) { _ in
                let modal = NSApp.modalWindow
                    ?? NSApp.windows.first { $0.isVisible && $0.level == .modalPanel }
                fields.append("alertVisible=\(modal?.isVisible ?? false)")
                // The alert's vibrancy material renders opaque white off-window,
                // which makes a PNG of it unreadable — so what the prompt *says*
                // is asserted from the view tree instead.
                var controls: [String] = []
                var labels: [String] = []
                var fieldWidths: [CGFloat] = []
                func walk(_ view: NSView) {
                    if let button = view as? NSButton {
                        controls.append("button(\(button.title)|\(button.state == .on ? "on" : "off"))")
                    } else if let secure = view as? NSSecureTextField {
                        controls.append("secureField(\(secure.placeholderString ?? ""))")
                        fieldWidths.append(secure.frame.width)
                    } else if let field = view as? NSTextField {
                        if !field.stringValue.isEmpty { labels.append(field.stringValue) }
                    }
                    view.subviews.forEach(walk)
                }
                if let content = modal?.contentView { walk(content) }
                fields.append("alertControls=[\(controls.joined(separator: " "))]")
                fields.append("alertLabels=[\(labels.joined(separator: " / "))]")
                // The password field must span the dialog's content width, not shrink
                // to its placeholder (see ArchivePasswordPrompter).
                fields.append("alertFieldWidth=\(fieldWidths.map { String(format: "%.0f", $0) }.joined(separator: ","))")
                fields.append("alertContentWidth=\(String(format: "%.0f", modal?.contentView?.frame.width ?? 0))")
                fields.append("windows=\(NSApp.windows.map { "\(type(of: $0)):\($0.isVisible)" }.joined(separator: ","))")
                if let pngPath = env["MENURIGHT_SELFTEST_ARCHIVE_UNLOCK_PNG"],
                   !pngPath.isEmpty,
                   let view = modal?.contentView {
                    fields.append(self.writePNG(of: view, over: modal?.backgroundColor, to: pngPath))
                }
                // The user's 取消: end the modal session and let the prompter
                // answer nil.
                NSApp.stopModal()
                finish()
            }
            finish = {
                let settle = Timer(timeInterval: 0.6, repeats: false) { _ in
                    _ = done.wait(timeout: .now() + 3)
                    fields.append("alertResult=\(alertResponse)")
                    fields.append("alertExtracted=\(extracted(alertDestination))")
                    self.reportSelfTest(fields.joined(separator: " "), keep: keep)
                }
                for mode in [RunLoop.Mode.default, .common] {
                    RunLoop.main.add(settle, forMode: mode)
                }
            }
            // Watchdog: a modal session must never strand an automated run.
            let watchdog = Timer(timeInterval: 20, repeats: false) { _ in
                print("SELFTEST archiveUnlock TIMEOUT")
                exit(2)
            }
            for timer in [inspect, watchdog] {
                RunLoop.main.add(timer, forMode: .default)
                RunLoop.main.add(timer, forMode: .common)
                RunLoop.main.add(timer, forMode: .modalPanel)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                alertResponse = dispatchExtract(
                    archive: archive,
                    into: alertDestination,
                    prompting: ArchivePasswordPrompter.shared
                )
                done.signal()
            }
        } catch {
            fields.append("FAILURE \(error)")
            reportSelfTest(fields.joined(separator: " "), keep: false)
        }
        return true
    }

    /// A prompter that answers from the environment: a self-test cannot type into
    /// the app's real alert, but the extraction path below it is the real one.
    private final class SelfTestPasswordPrompt: ArchivePasswordPrompting {
        private let password: String
        init(password: String) { self.password = password }
        func automaticPasswords(forArchiveAt url: URL) -> [String] { [password] }
        func askForPassword(forArchiveAt url: URL, afterFailedAttempt: Bool) -> String? { password }
    }

    /// Prints and records one self-test line, then quits — unless the caller asked
    /// to keep the UI on screen for a screenshot.
    private func reportSelfTest(_ summary: String, keep: Bool) {
        print("SELFTEST \(summary)")
        Self.log.notice("SELFTEST \(summary, privacy: .public)")
        LifecycleDiagnostics.record("SELFTEST \(summary)", from: "main-app")
        guard !keep else { return }
        // Intentional: this hook exists to end the app, so the terminate request
        // must not be cancelled by `applicationShouldTerminate`.
        quitRequested = true
        NSApp.terminate(nil)
        // `terminate` is a request, and a run loop that is busy presenting a
        // window can ignore it. A self-test must always end, so fall back to a
        // hard exit one second later (DEBUG-only path).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exit(0) }
    }
    /// Spike: what a *refused* terminate request does to the app's windows.
    ///
    ///     MENURIGHT_SELFTEST_REFUSED_QUIT=1 \
    ///       build/DerivedData-fix/Build/Products/Debug/MenuRight.app/Contents/MacOS/MenuRight
    ///
    /// It prints the window inventory, drives the refusal path the way the Dock's
    /// 退出 and ⌘Q do — no `requestQuit()` — and then checks the two properties this
    /// feature lives on: the menu bar item's window must survive, the settings
    /// window must go. The first version of `dismissRegularWindows()` swept
    /// `NSApp.windows` and failed the first check, which is how the "icon visible
    /// but deaf" regression was found on 2026-10-03.
    ///
    /// `applicationShouldTerminate` is called directly rather than through
    /// `NSApp.terminate(nil)`: a headless run never reaches the delegate that way
    /// (measured — no delegate call at all), and the code under test is the
    /// dismissal, not AppKit's request plumbing.
    private func runRefusedQuitSelfTestIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let runsRefusal = environment["MENURIGHT_SELFTEST_REFUSED_QUIT"] == "1"
        let runsIntentional = environment["MENURIGHT_SELFTEST_INTENTIONAL_QUIT"] == "1"
        guard runsRefusal || runsIntentional else {
            return false
        }
        if runsIntentional {
            // The other half of the gate: 退出 in the menu bar item must really end
            // the process. Reaching the FAIL line means the app survived its own
            // quit — the state that would leave the user with no way out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                print("SELFTEST intentional-quit gate=\(MainAppGateRegistry.gate != nil)")
                MainAppGateRegistry.gate?.quit()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    print("SELFTEST FAIL an intentional quit was refused")
                    exit(2)
                }
            }
            return true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            print(
                "SELFTEST selftest-self=\(ObjectIdentifier(self)) registered-settings-window=\(self.settingsWindow != nil)"
            )
            self.reportWindowInventory(stage: "before-refusal")
            let statusItemBefore = self.anyStatusBarWindowVisible()
            let settingsBefore = self.settingsWindow?.isVisible ?? false
            let reply = self.applicationShouldTerminate(NSApp)
            print("SELFTEST direct-reply rawValue=\(reply.rawValue)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.reportWindowInventory(stage: "after-refusal")
                let statusItemAfter = self.anyStatusBarWindowVisible()
                let settingsAfter = self.settingsWindow?.isVisible ?? false
                print(
                    "SELFTEST verdict status-item-window-visible \(statusItemBefore)->\(statusItemAfter)"
                        + " settings-window-visible \(settingsBefore)->\(settingsAfter)"
                )
                let ok = statusItemBefore && statusItemAfter && settingsBefore && !settingsAfter
                print(
                    "SELFTEST \(ok ? "PASS" : "FAIL") a refused quit keeps the status item and dismisses the settings window"
                )
                exit(0)
            }
        }
        return true
    }

    /// Whether the menu bar item's own window is on screen. It is the app-level
    /// symptom of the 2026-10-03 regression: visible means the item can still be
    /// clicked.
    private func anyStatusBarWindowVisible() -> Bool {
        let statusBarLevel = NSWindow.Level.statusBar.rawValue
        return NSApp.windows.contains { $0.level.rawValue >= statusBarLevel && $0.isVisible }
    }

    /// One line per window in the order AppKit lists them, with the properties
    /// that decide whether `dismissRegularWindows()` closes it. A menu bar item's
    /// window sits at level `.statusBar` (25), the settings window at `.normal` (0).
    private func reportWindowInventory(stage: String) {
        let windows = NSApp.windows
        print("SELFTEST windows-\(stage) count=\(windows.count)")
        for window in windows {
            let title = window.title.isEmpty ? "<none>" : window.title
            print(
                "SELFTEST windows-\(stage) class=\(type(of: window)) level=\(window.level.rawValue)"
                    + " visible=\(window.isVisible) panel=\(window is NSPanel) title=\(title)"
            )
        }
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

        #if DEBUG
        // Must run here, not in willFinishLaunching: it needs SwiftUI's window to
        // already exist so it can close it (see the method).
        _ = runArchiveDialogSelfTestIfRequested()
            || runPasswordBookSelfTestIfRequested()
            || runArchiveUnlockSelfTestIfRequested()
            || runSettingsPanePNGSelfTestIfRequested()
            || runRefusedQuitSelfTestIfRequested()
        #endif
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

    /// The app does **not** quit when the settings window is closed.
    ///
    /// The Finder extension is started and stopped by Finder; all it needs from
    /// us is a live IPC peer. If this went back to `true`, closing the window
    /// would silently break every Finder menu action with "主应用未运行". The rule
    /// itself lives in `AppLifecycle`, which the test target can compile;
    /// `StatusMenuTests` guards both the value and this forwarding method.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppLifecycle.terminatesAfterLastWindowClosed
    }

    /// Dock 退出 / ⌘Q / the app menu's 退出 only dismiss the settings window.
    ///
    /// macOS offers 退出 for any app with a Dock icon, and ⌘Q reaches the app as a
    /// terminate request too — neither is the user asking for the *background
    /// service* to stop, which is what 退出 in the menu bar item means. Ending the
    /// process there would take the IPC listener down and turn every Finder menu
    /// entry into 主应用未运行. So: cancel, close the settings window (打开设置
    /// recreates it through `openWindow(id:)`) and keep serving the extension.
    ///
    /// The rule itself lives in `AppLifecycle`, which the test target can
    /// compile; `StatusMenuTests` guards the rule, this forwarding, and the menu
    /// bar item that is the only intentional caller.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MENURIGHT_SELFTEST_REFUSED_QUIT"] == "1" {
            print(
                "SELFTEST delegate-applicationShouldTerminate quitRequested=\(quitRequested)"
                    + " poweringOff=\(systemIsPoweringOff)"
            )
        }
        #endif
        guard AppLifecycle.shouldTerminate(
            intentionalQuitRequested: quitRequested,
            systemIsPoweringOff: systemIsPoweringOff
        ) else {
            Self.log.notice(
                "MAIN-APP terminate request without 退出 refused: settings window dismissed, service stays up"
            )
            LifecycleDiagnostics.record(
                "terminate refused (Dock/⌘Q): settings window dismissed, service stays up",
                from: "main-app"
            )
            dismissRegularWindows()
            return .terminateCancel
        }
        Self.log.info("MAIN-APP terminating on an intentional quit request")
        return .terminateNow
    }

    /// Takes the app's own windows down — the settings window and anything opened
    /// from it, such as the custom-compression dialog — while the process keeps
    /// running. 打开设置 recreates the settings window.
    ///
    /// Only **registered** windows are considered. `NSApp.windows` also holds the
    /// menu bar item's own window, and an earlier version of this method closed
    /// every visible non-panel window in that list: that took the status item down
    /// with it, leaving the icon on screen but deaf. The settings scene hands its
    /// window over through `SettingsWindowReader`; the dialog presenter does the
    /// same for the windows it opens. `AppLifecycle.mayDismiss` still guards the
    /// level, so a `NSStatusBarWindow` could never be dismissed even by mistake.
    ///
    /// Panels are left alone on purpose: an `NSAlert` (update prompt, password
    /// prompt, confirmation, operation failure) is a decision in flight, not UI to
    /// dismiss, and closing it here would drop that decision.
    private func dismissRegularWindows() {
        for window in [settingsWindow, auxiliaryWindow].compactMap({ $0 }) {
            let dismissable = AppLifecycle.mayDismiss(
                windowLevel: window.level.rawValue,
                isVisible: window.isVisible,
                isPanel: window is NSPanel
            )
            #if DEBUG
            if ProcessInfo.processInfo.environment["MENURIGHT_SELFTEST_REFUSED_QUIT"] == "1" {
                print(
                    "SELFTEST \(dismissable ? "dismissing" : "keeping") class=\(type(of: window))"
                        + " level=\(window.level.rawValue) visible=\(window.isVisible)"
                        + " title=\(window.title.isEmpty ? "<none>" : window.title)"
                )
            }
            #endif
            guard dismissable else { continue }
            window.close()
        }
    }
}

@main
struct MenuRightApp: App {
    /// Identifier of the settings window. The menu bar item needs it to bring
    /// the window back after the user closed it (`openWindow(id:)`).
    static let mainWindowID = "settings"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate: AppDelegate

    init() {
        LifecycleDiagnostics.record("MenuRightApp.init", from: "main-app")
    }

    var body: some Scene {
        WindowGroup("MenuRight", id: Self.mainWindowID) {
            ContentView()
                .background(
                    // Names the settings window for the quit path. Without this the
                    // delegate could only guess which window in `NSApp.windows` is
                    // the settings UI — and guessing is what closed the menu bar
                    // item's window (see `dismissRegularWindows`).
                    SettingsWindowReader { window in
                        #if DEBUG
                        if ProcessInfo.processInfo.environment["MENURIGHT_SELFTEST_REFUSED_QUIT"] == "1" {
                            print(
                                "SELFTEST settings-window-report \(window.map { "class=\(type(of: $0)) level=\($0.level.rawValue)" } ?? "nil")"
                                    + " delegate=\(NSApp.delegate.map { String(reflecting: type(of: $0)) } ?? "nil")"
                                    + " isAppDelegate=\(NSApp.delegate.map { ($0 as AnyObject) is AppDelegate } ?? false)"
                                    + " gate=\(MainAppGateRegistry.gate != nil)"
                            )
                        }
                        #endif
                        MainAppGateRegistry.gate?.register(settingsWindow: window)
                    }
                    .frame(width: 0, height: 0)
                )
                .onAppear {
                    LifecycleDiagnostics.record("ContentView.onAppear", from: "main-app")
                }
        }
        // The settings UI is the app's main window; open it at a size where the
        // sidebar and a pane are both comfortable.
        .defaultSize(width: 1080, height: 720)
        .onChange(of: ScenePhase.background) { _, _ in }

        // The always-available entry point. `.menu` style is the plain dropdown
        // a status item is expected to have: one click, then 打开设置 / 检查更新 /
        // 退出.
        MenuBarExtra {
            StatusMenuView()
        } label: {
            StatusMenuLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Reports the `NSWindow` that hosts the settings UI back to the app delegate.
///
/// A refused 退出 has to close the settings window — and *only* that window. The
/// app's window list also contains the menu bar item's `NSStatusBarWindow`, which
/// is a plain `NSWindow`, so there is no way to tell the two apart by shape alone.
/// The settings scene therefore names its window explicitly, through here, instead
/// of letting the delegate sweep `NSApp.windows`.
private struct SettingsWindowReader: NSViewRepresentable {
    /// Called with the hosting window whenever SwiftUI puts the view into one, and
    /// with `nil` when it leaves one.
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ view: WindowReportingView, context: Context) {
        view.onWindowChange = onWindowChange
    }
}

/// An invisible view whose only job is to notice which window it lives in, and to
/// say so. It never draws, so a zero-sized frame is enough.
final class WindowReportingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        #if DEBUG
        if ProcessInfo.processInfo.environment["MENURIGHT_SELFTEST_REFUSED_QUIT"] == "1" {
            print("SELFTEST window-reporting-view moved-to-window=\(window != nil)")
        }
        #endif
        onWindowChange?(window)
    }
}
