import AppKit
import Foundation

/// The main app's answer to `ArchivePasswordPrompting`: try the password book
/// silently, then ask the user in a modal alert.
///
/// Two rules shape this file:
///
/// 1. **The password never leaves this process.** The Finder extension only sends
///    "extract this archive"; the app resolves the password here, so no secret
///    ever crosses the IPC socket.
/// 2. **The dispatcher runs on a background queue** (`MainAppIPCServer`'s
///    connection queue), so every AppKit touch hops to the main thread — the same
///    dance `FolderChooser` performs for `NSOpenPanel`.
///
/// `url.lastPathComponent` is what gets remembered when the user ticks the
/// checkbox, matching the name the compression dialog stores (`mr-all.zip`).
final class ArchivePasswordPrompter: ArchivePasswordPrompting {
    static let shared = ArchivePasswordPrompter()

    /// Injectable for tests; production uses the app-wide book.
    private let book: @MainActor () -> ArchivePasswordBook

    init(book: @escaping @MainActor () -> ArchivePasswordBook = { ArchivePasswordBook.shared }) {
        self.book = book
    }

    // MARK: - ArchivePasswordPrompting

    func automaticPasswords(forArchiveAt url: URL) -> [String] {
        onMain { self.book().entries.map(\.password) }
    }

    func askForPassword(forArchiveAt url: URL, afterFailedAttempt: Bool) -> String? {
        onMain {
            let prompt = Self.makePrompt(
                text: SettingsStore.shared.text,
                archiveName: url.lastPathComponent,
                afterFailedAttempt: afterFailedAttempt
            )
            // The app may be in the background (the extension asked for this):
            // put the alert in front instead of letting it flash under Finder.
            NSApp?.activate(ignoringOtherApps: true)
            guard prompt.alert.runModal() == .alertFirstButtonReturn else { return nil }

            let answer = prompt.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { return nil }
            if prompt.remember.state == .on {
                self.book().remember(name: url.lastPathComponent, password: answer)
            }
            return answer
        }
    }

    // MARK: - The alert

    /// The pieces of the prompt, so a test can measure the layout without opening a
    /// modal session.
    struct Prompt {
        let alert: NSAlert
        let field: NSSecureTextField
        let remember: NSButton
    }

    static func makePrompt(
        text: (StringKey) -> String,
        archiveName: String,
        afterFailedAttempt: Bool
    ) -> Prompt {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text(.archiveUnlockTitle)
        let template = afterFailedAttempt ? text(.archiveUnlockWrongMessage) : text(.archiveUnlockMessage)
        alert.informativeText = String(format: template, archiveName)
        alert.addButton(withTitle: text(.archiveUnlockExtract))
        alert.addButton(withTitle: text(.commonCancel))

        // The field has to span the dialog's content width. A vertical
        // `NSStackView` sizes its arranged subviews to their *intrinsic* width
        // (for a text field that is just its placeholder), which left the
        // password box half the dialog wide. Lay the two controls out by frame
        // instead — `NSAlert` then sizes the dialog around this accessory, so
        // the field spans it.
        let accessoryWidth: CGFloat = 320
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: 58))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 34, width: accessoryWidth, height: 24))
        field.placeholderString = text(.archivePasswordPlaceholder)
        field.autoresizingMask = [.width]
        let remember = NSButton(
            checkboxWithTitle: text(.archiveUnlockRemember),
            target: nil,
            action: nil
        )
        remember.frame = NSRect(x: 0, y: 4, width: remember.fittingSize.width, height: 22)
        accessory.addSubview(field)
        accessory.addSubview(remember)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field
        return Prompt(alert: alert, field: field, remember: remember)
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
