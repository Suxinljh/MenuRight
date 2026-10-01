import AppKit
import SwiftUI

/// The menu bar item: 打开设置 / 检查更新 / 退出。
///
/// **Why the app has a menu bar item at all.** The Finder extension is started
/// by Finder when it needs a context menu and stopped by Finder on its own — no
/// app can start it, keep it alive, or end it. What the *main app* must do is
/// stay reachable: every MenuRight menu item delegates its file operation to
/// this process over the App-Group socket, so if the app died with its window
/// the user would see menu items that all answer "主应用未运行". Closing the
/// window therefore no longer ends the app (see
/// `AppDelegate.applicationShouldTerminateAfterLastWindowClosed`), and 退出 here
/// is the only place that really stops it.
struct StatusMenuView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var store = SettingsStore.shared

    var body: some View {
        // Rendered from the plan rather than written out button by button, so
        // the order and the separator have exactly one definition.
        ForEach(Array(StatusMenuPlan.entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .separator:
                Divider()
            case .command(let command):
                button(for: command)
            }
        }
    }

    @ViewBuilder
    private func button(for command: StatusMenuCommand) -> some View {
        switch command {
        case .openSettings:
            // ⌘, is the Mac shortcut for Settings; it works while the menu is
            // open, and closing the window only hides it — the shortcut opens it
            // again.
            Button(store.text(command.titleKey)) { openSettings() }
                .keyboardShortcut(",", modifiers: .command)
        case .checkForUpdates:
            Button(store.text(command.titleKey)) { checkForUpdates() }
        case .quit:
            // The one place that ends the main app for real. The extension is
            // not ours to stop: Finder owns that process.
            Button(store.text(command.titleKey)) { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    /// Brings the settings window back — `openWindow` on the WindowGroup's id
    /// recreates it after the user closed it, which is what makes "close the
    /// window, keep the app running" a usable state instead of a dead end.
    private func openSettings() {
        openWindow(id: MenuRightApp.mainWindowID)
        NSApp.activate()
    }

    /// Manual check: ignores the daily throttle and reports *every* outcome.
    private func checkForUpdates() {
        Task { @MainActor in
            await UpdateChecker.shared.checkNow()
            switch StatusMenuUpdateOutcome.make(from: UpdateChecker.shared.state) {
            case .nothing:
                break
            case .upToDate(let running):
                StatusMenuAlert.presentUpToDate(running: running)
            case .failed(let message):
                StatusMenuAlert.presentFailure(message: message)
            }
            // The "a newer version exists" case keeps the launch prompt, so the
            // buttons are the same wherever the check was started from.
            if case .updateAvailable(let release) = UpdateChecker.shared.state {
                UpdatePrompter.present(release)
            }
        }
    }
}

/// The status item's artwork: the brand mark, tinted by the system.
///
/// It reads the catalog image directly instead of going through
/// `Image(systemName:)` because the icon is the product's own mark. If the asset
/// is missing the fallback SF Symbol keeps the item clickable — an empty status
/// slot has no visible hit target.
struct StatusMenuLabel: View {
    var body: some View {
        if let image = StatusMenuIcon.statusItemImage() {
            Image(nsImage: image)
                .accessibilityLabel(Text("MenuRight"))
        } else {
            Image(systemName: StatusMenuIcon.fallbackSymbolName)
                .accessibilityLabel(Text("MenuRight"))
        }
    }
}

extension StatusMenuIcon {
    /// The brand mark at menu bar size.
    ///
    /// Measured 2026-10-01: the artwork's intrinsic size is not honoured here —
    /// a `MenuBarExtra` label draws the image it is given, and a
    /// `.resizable().frame(width:height:)` around it was ignored, so the mark
    /// covered 100+ pt of the menu bar and was clipped by its height. Handing
    /// over a copy that is already sized is what actually works.
    ///
    /// `isTemplate` is re-asserted on the copy: the system tints status items
    /// with the menu bar's own colour, and an untinted white glyph would vanish
    /// on a light menu bar.
    static func statusItemImage() -> NSImage? {
        guard let image = NSImage(named: assetName)?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: pointSize, height: pointSize)
        image.isTemplate = true
        return image
    }
}

/// The two alerts a manual check from the menu bar can raise.
@MainActor
enum StatusMenuAlert {
    static func presentUpToDate(running: String, store: SettingsStore = .shared) {
        let language = store.settings.general.language
        inform(
            title: Localization.text(.statusMenuUpToDateTitle, language: language),
            body: String(format: Localization.text(.statusMenuUpToDateBody, language: language), running),
            language: language
        )
    }

    static func presentFailure(message: String, store: SettingsStore = .shared) {
        let language = store.settings.general.language
        inform(
            title: Localization.text(.statusMenuCheckFailedTitle, language: language),
            body: message,
            language: language
        )
    }

    private static func inform(title: String, body: String, language: AppLanguage) {
        // The menu bar can be clicked while another app is frontmost; without
        // activating first the alert would open behind someone else's window.
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: Localization.text(.commonConfirm, language: language))
        alert.runModal()
    }
}
