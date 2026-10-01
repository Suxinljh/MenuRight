import AppKit

/// Lightweight user-visible failure reporting for Finder operations.
///
/// Successful normal operations stay silent; failures get one concise,
/// actionable alert. **P5-1 responsibility split**: the Main App is the only
/// writer, so the extension renders no local `FileOperationError` /
/// `FileOperationItemResult` failures — only the delegated bridges below.
///
/// Two hard-won constraints shape everything here. Both were measured on
/// 2026-10-01, and both were reported by a user before they were understood.
///
/// **1. Never `runModal()`.** This code runs inside the Finder Sync extension,
/// and the extension's main thread is the very thread Finder calls `menu(for:)`
/// on. A modal alert parks that thread until the user clicks OK — and an alert
/// that ends up behind another window is parked potentially forever, during
/// which Finder gets no menu items at all and the MenuRight entries silently
/// vanish from the context menu. It is the same bug class `FinderSync.ipcQueue`
/// was introduced to fix; this was the last blocking call in the extension.
///
/// **2. An `NSAlert` shown without a modal session needs `layout()`.** AppKit
/// hides the parts of `NSAlertPanel.nib` an alert does not use only during its
/// own layout pass, which `runModal()`/`beginSheetModal(for:)` trigger. Ordering
/// the window front directly left AppKit's spare slots on screen — a
/// 「Do not show this message again」 checkbox, a help button, and two empty
/// button pills under OK. `layout()` is the public entry point to that pass.
///
/// Text is localized from the same App Group payload the menu is rendered from,
/// so switching language in 通用设置 changes the prompts too.
enum OperationPresenter {
    /// The language to render prompts in.
    ///
    /// Resolved per call rather than cached: a language change must be visible
    /// without relaunching Finder, and this is one `cfprefsd` read.
    private static var language: AppLanguage { FinderMenuLanguage.resolve() }

    private static func text(_ key: StringKey) -> String {
        Localization.text(key, language: language)
    }

    static func presentTitle(_ title: String, message: String, offersOpenApp: Bool = false) {
        // AppKit must be touched on the main thread. Callers today already hop
        // there, but an API whose correctness depends on every future caller
        // remembering to do so is a trap: marshal here instead.
        if Thread.isMainThread {
            presentTitleOnMain(title: title, message: message, offersOpenApp: offersOpenApp)
        } else {
            DispatchQueue.main.async {
                presentTitleOnMain(title: title, message: message, offersOpenApp: offersOpenApp)
            }
        }
    }

    /// Alerts currently on screen. Main thread only.
    private static var visibleAlerts: [NSAlert] = []

    /// How long an un-clicked warning stays up before it closes itself.
    private static let alertAutoDismissSeconds: TimeInterval = 20

    private static func presentTitleOnMain(title: String, message: String, offersOpenApp: Bool) {
        // One warning at a time: a stack of stale ones helps nobody, and the
        // newest failure is the interesting one.
        dismissAllAlerts()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        let ok = alert.addButton(withTitle: text(.presenterOK))
        // An NSAlert only closes itself from a modal session, and this one is
        // deliberately not modal, so each button needs an action of its own.
        ok.target = AlertButtons.shared
        ok.action = #selector(AlertButtons.dismiss(_:))
        if offersOpenApp {
            let open = alert.addButton(withTitle: text(.presenterOpenApp))
            open.target = AlertButtons.shared
            open.action = #selector(AlertButtons.openApp(_:))
        }

        // See constraint 2 in the type comment.
        alert.showsSuppressionButton = false
        alert.showsHelp = false
        alert.layout()
        alert.suppressionButton?.isHidden = true
        hideUntitledButtons(in: alert.window.contentView)

        visibleAlerts.append(alert)
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alert.window.center()
        NSApp?.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)

        // Belt and braces: a warning nobody clicks must not outlive its point.
        DispatchQueue.main.asyncAfter(deadline: .now() + alertAutoDismissSeconds) {
            dismiss(alert)
        }
    }

    /// AppKit's alert panel carries more buttons than any one alert uses; with
    /// no modal engagement the unused ones can stay on screen as empty pills.
    private static func hideUntitledButtons(in view: NSView?) {
        guard let view else { return }
        for subview in view.subviews {
            if let button = subview as? NSButton, button.title.isEmpty {
                button.isHidden = true
            }
            hideUntitledButtons(in: subview)
        }
    }

    /// Closes every warning on screen. Safe to call when there is none.
    fileprivate static func dismissAllAlerts() {
        let alerts = visibleAlerts
        visibleAlerts.removeAll()
        for alert in alerts {
            alert.window.orderOut(nil)
        }
    }

    private static func dismiss(_ alert: NSAlert) {
        alert.window.orderOut(nil)
        visibleAlerts.removeAll { $0 === alert }
    }

    /// Brings the main app up — the only useful thing the sandboxed extension
    /// can do when the app is not running, and what the prompt offers.
    fileprivate static func openMainApp() {
        let containing = MenuRightIPC.containingAppBundleURL(forExtensionBundleAt: Bundle.main.bundleURL)
        guard let appURL = containing else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                NSLog("[MenuRight] could not open the main app: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Prompts

    static func presentFolderAccessRequired() {
        presentTitle(text(.presenterFolderAccessTitle), message: presentFolderAccessRequiredMessage())
    }

    /// **P5-1** UI bridge for delegated move results coming back from the Main App.
    static func presentDelegatedPasteResults(_ items: [FileOperationContract.ItemResult]) {
        let failures = items.filter { !$0.success }
        guard !failures.isEmpty else { return }
        let count = failures.count
        let conflictNames = failures.compactMap { item -> String? in
            if item.errorCode == .nameCollision {
                return (item.sourcePath as NSString).lastPathComponent
            }
            return nil
        }

        let message: String
        if !conflictNames.isEmpty {
            let joined = conflictNames.joined(separator: ", ")
            message = count == conflictNames.count
                ? String(format: text(.presenterMoveConflictAll), joined)
                : text(.presenterMoveConflictSome)
        } else if let first = failures.first, let m = first.message, !m.isEmpty {
            message = m
        } else {
            message = text(.presenterMoveFailed)
        }

        let title = count == 1
            ? text(.presenterCouldNotMoveOne)
            : String(format: text(.presenterCouldNotMoveMany), count)
        presentTitle(title, message: message)

        for failure in failures {
            NSLog("[MenuRight] move failed: source=%@ code=%@ message=%@",
                  failure.sourcePath,
                  failure.errorCode?.rawValue ?? "<nil>",
                  failure.message ?? "")
        }
    }

    /// **P6** UI bridge for per-item delegated actions (alias creation, locking,
    /// unlocking). Silent on full success; on failure reports the first message
    /// plus how many items failed.
    static func presentDelegatedItemFailures(
        _ items: [FileOperationContract.ItemResult],
        action: StringKey
    ) {
        let failures = items.filter { !$0.success }
        guard !failures.isEmpty else { return }

        let actionText = text(action)
        let firstMessage = failures.first?.message.flatMap { $0.isEmpty ? nil : $0 }
            ?? text(.presenterOperationFailed)
        let detail: String
        if failures.count == 1 {
            detail = firstMessage
        } else if failures.count == items.count {
            detail = String(format: text(.presenterAllItemsFailed), failures.count) + " " + firstMessage
        } else {
            detail = String(format: text(.presenterSomeItemsFailed), failures.count, items.count) + " " + firstMessage
        }
        presentTitle(String(format: text(.presenterCouldNotAction), actionText), message: detail)

        for failure in failures {
            NSLog("[MenuRight] %@ failed: source=%@ code=%@ message=%@",
                  actionText,
                  failure.sourcePath,
                  failure.errorCode?.rawValue ?? "<nil>",
                  failure.message ?? "")
        }
    }

    /// **P5-1** UI bridge for a single-target delegated create operation.
    /// Shows nothing on success; on failure, displays a concise alert whose
    /// message comes from the Main App's structured response.
    static func presentDelegatedCreateFailure(name: String, code: FileOperationContract.ErrorCode, message: String) {
        let title: String
        switch code {
        case .notAuthorized, .pathOutsideAuthorizedScope:
            title = text(.presenterFolderAccessTitle)
        default:
            title = String(format: text(.presenterCouldNotCreate), name)
        }
        let displayed = (code == .notAuthorized || code == .pathOutsideAuthorizedScope)
            ? presentFolderAccessRequiredMessage()
            : message
        presentTitle(title, message: displayed)
    }

    /// **P7-b** UI bridge for a favorite that could not be opened. The main app
    /// has already resolved the target (path, bundle identifier or URL) and
    /// returns a message that names the actual problem, so the alert shows it
    /// instead of a generic failure.
    static func presentDelegatedOpenFailure(name: String, code: FileOperationContract.ErrorCode, message: String) {
        NSLog("[MenuRight] open failed: name=%@ code=%@ message=%@", name, code.rawValue, message)
        let displayed = message.isEmpty ? text(.presenterOpenFailed) : message
        presentTitle(String(format: text(.presenterCouldNotOpen), name), message: displayed)
    }

    /// **P9** UI bridge for a compression/extraction failure.
    static func presentDelegatedArchiveFailure(action: StringKey, code: FileOperationContract.ErrorCode, message: String) {
        let actionText = text(action)
        NSLog("[MenuRight] archive %@ failed: code=%@ message=%@", actionText, code.rawValue, message)
        let displayed = message.isEmpty ? text(.presenterOperationFailed) : message
        presentTitle(String(format: text(.presenterCouldNotAction), actionText), message: displayed)
    }

    /// **P5-1** Main App unavailable — the extension can't write locally
    /// anymore. We display one consistent message instead of attempting a
    /// fallback that would silently bypass the security gate.
    ///
    /// This is the one prompt with a second button: the app is installed, so the
    /// user can just be taken to it.
    static func presentMainAppUnavailable(context: String) {
        var message = text(.presenterAppNotRunningBody)
            + String(UnicodeScalar(10)) + String(UnicodeScalar(10))
            + text(.presenterAppNotRunningHint)
        if !context.isEmpty {
            message += String(UnicodeScalar(10)) + String(UnicodeScalar(10))
                + String(format: text(.presenterDetails), context)
        }
        presentTitle(text(.presenterAppNotRunningTitle), message: message, offersOpenApp: true)
    }

    // MARK: - Progress

    /// The progress notice on screen, if any. Main thread only.
    private static var busyAlert: NSAlert?

    /// How long an un-answered notice stays up on its own. The caller takes it
    /// down when the outcome arrives; this only covers a reply that never comes
    /// (which the operation budget bounds at ten minutes, so leave headroom).
    private static let busyNoticeLifetimeSeconds: TimeInterval =
        MenuRightIPC.fileOperationTimeoutSeconds + 60

    /// Shows a spinner notice while a delegated operation runs.
    ///
    /// Deliberately indeterminate: the extension gets exactly one reply, at the
    /// end, so there is no percentage it could honestly show. What it *can* say
    /// is that the work is still going — and "nothing happened at all for two
    /// minutes" is what a folder compression used to look like.
    static func presentBusy(for kind: FileOperationContract.OperationKind) {
        let title: String
        switch kind {
        case .compressItems: title = text(.presenterBusyCompress)
        case .extractArchive: title = text(.presenterBusyExtract)
        default: title = text(.presenterBusyGeneric)
        }

        let present = {
            dismissBusy()

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = title
            alert.informativeText = text(.presenterBusyBody)
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            // Without an explicit frame the accessory view is laid out at zero
            // size and the spinner is invisible (measured).
            spinner.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
            spinner.startAnimation(nil)
            alert.accessoryView = spinner
            // One button, and it only hides the notice — the work carries on.
            // `NSAlert` silently adds an English "OK" when no button is added at
            // all, which is both wrong-language and meaningless here.
            let hide = alert.addButton(withTitle: text(.presenterBusyHide))
            hide.target = AlertButtons.shared
            hide.action = #selector(AlertButtons.dismissBusy(_:))
            // `layout()` collapses the nib's unused slots; without it the panel
            // shows a「不再显示此信息」checkbox and empty button pills.
            alert.showsSuppressionButton = false
            alert.showsHelp = false
            alert.layout()
            hideUntitledButtons(in: alert.window.contentView)

            busyAlert = alert
            alert.window.level = .floating
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            alert.window.center()
            NSApp?.activate(ignoringOtherApps: true)
            alert.window.makeKeyAndOrderFront(nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + busyNoticeLifetimeSeconds) {
                dismissBusyAlert(alert)
            }
        }

        if Thread.isMainThread { present() } else { DispatchQueue.main.async(execute: present) }
    }

    /// Takes the progress notice down. Safe to call when there is none.
    static func dismissBusy() {
        let dismiss = { dismissBusyAlert(busyAlert) }
        if Thread.isMainThread { dismiss() } else { DispatchQueue.main.async(execute: dismiss) }
    }

    private static func dismissBusyAlert(_ alert: NSAlert?) {
        guard let alert, busyAlert === alert else { return }
        alert.window.orderOut(nil)
        busyAlert = nil
    }

    /// **P9** The main app took the request but had not answered within the
    /// file-operation budget.    ///
    /// Deliberately NOT `presentMainAppUnavailable`: the app is running and is
    /// most likely still working, and telling the user to open it (or to retry)
    /// is both wrong and harmful — a retry starts a second compression.
    static func presentOperationStillRunning() {
        let waited = Duration.seconds(MenuRightIPC.fileOperationTimeoutSeconds)
            .formatted(.units(allowed: [.minutes], width: .wide))
        presentTitle(
            text(.presenterStillRunningTitle),
            message: String(format: text(.presenterStillRunningBody), waited)
        )
    }

    /// Same wording as the per-item bridge above, for a single delegated action
    /// that failed as a whole (alias creation, locking, …).
    static func presentDelegatedActionFailure(action: StringKey, message: String) {
        let displayed = message.isEmpty ? text(.presenterOperationFailed) : message
        presentTitle(String(format: text(.presenterCouldNotAction), text(action)), message: displayed)
    }

    /// The Main App answered, but refused for a reason that is not one of the
    /// structured codes — used by the cut/paste/terminal paths.
    static func presentOperationFailure(title: StringKey, message: String) {
        presentTitle(text(title), message: message)
    }

    /// Cut could not be written to the pasteboard.
    static func presentCutFailure() {
        presentTitle(text(.presenterCutFailedTitle), message: text(.presenterCutFailedBody))
    }

    /// Internal helper: builds the standard "Folder Access Required" body.
    static func presentFolderAccessRequiredMessage() -> String {
        text(.presenterFolderAccessBody)
            + String(UnicodeScalar(10)) + String(UnicodeScalar(10))
            + text(.presenterFolderAccessHint)
    }
}

/// Target of the non-modal alert's buttons.
///
/// Exists only because the alert must not run a modal session — see
/// `OperationPresenter`. `NSAlert` wires its buttons to `stopModal` internally,
/// which does nothing outside a modal session, so each button gets this action
/// instead.
final class AlertButtons: NSObject {
    static let shared = AlertButtons()

    @objc func dismiss(_ sender: Any?) {
        OperationPresenter.dismissAllAlerts()
    }

    @objc func openApp(_ sender: Any?) {
        OperationPresenter.dismissAllAlerts()
        OperationPresenter.openMainApp()
    }

    /// Hides the progress notice; the operation it describes keeps running.
    @objc func dismissBusy(_ sender: Any?) {
        OperationPresenter.dismissBusy()
    }
}
