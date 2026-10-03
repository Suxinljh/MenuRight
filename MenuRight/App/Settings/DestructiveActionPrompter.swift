import AppKit
import Foundation

/// The main app's answer to `DestructiveActionConfirming` (**P7** 二次确认).
///
/// `FilePermissionSettings.confirmDestructiveActions` asks the user before a
/// sensitive action (锁定 / 解锁 / 剪切) runs. The dispatcher runs on the IPC
/// connection queue, so the alert is presented on the main thread and the
/// background thread waits for the answer — the same hand-off
/// `ArchivePasswordPrompter` performs for the archive password prompt.
///
/// The dispatcher turns a refusal into `.cancelledByUser`, which every extension
/// handler treats as a silent no-op: cancelling leaves no trace in the UI.
///
/// `@unchecked Sendable`: the protocol requires `Sendable` because the dispatcher
/// stores it, but `text` is a main-actor closure that `onMain` only ever calls on
/// the main thread — the same shape the test stub uses.
final class DestructiveActionPrompter: DestructiveActionConfirming, @unchecked Sendable {
    static let shared = DestructiveActionPrompter()

    /// Injectable so tests can replace the wording source.
    private let text: @MainActor () -> (StringKey) -> String

    init(text: @escaping @MainActor () -> (StringKey) -> String = { SettingsStore.shared.text }) {
        self.text = text
    }

    // MARK: - DestructiveActionConfirming

    func confirm(_ action: DestructiveAction) -> Bool {
        onMain {
            let text = self.text()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = text(.confirmDestructiveTitle)
            alert.informativeText = String(
                format: text(.confirmDestructiveMessage),
                Self.describe(action, text: text)
            )
            alert.addButton(withTitle: text(.commonConfirm))
            alert.addButton(withTitle: text(.commonCancel))
            NSApp?.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    /// "锁定所选项目 (3)" — the count only when more than one item is affected.
    static func describe(_ action: DestructiveAction, text: (StringKey) -> String) -> String {
        let name = text(action.titleKey)
        guard action.itemCount > 1 else { return name }
        return "\(name) (\(action.itemCount))"
    }

    // MARK: - Main-thread hop

    private func onMain<T>(_ body: @escaping @MainActor () -> T) -> T {
        let run = { MainActor.assumeIsolated(body) }
        if Thread.isMainThread {
            return run()
        }
        // `DispatchQueue.main.sync` is safe here: this queue is the IPC
        // connection queue, never the main queue (a sync to main from main
        // would deadlock, hence the branch above).
        return DispatchQueue.main.sync(execute: run)
    }
}
