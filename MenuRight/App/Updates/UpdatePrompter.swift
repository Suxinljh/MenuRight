import AppKit
import Foundation

/// The launch-time "a newer version exists" prompt.
///
/// An `NSAlert` rather than a user notification: the app has no notification
/// permission, and the alert is only raised once per version (the check itself
/// is throttled to one per day and honours "skip this version").
@MainActor
enum UpdatePrompter {
    static func present(_ release: UpdateRelease, store: SettingsStore = .shared) {
        let language = store.settings.general.language
        let running = UpdateChecker.bundleVersion()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            format: Localization.text(.generalUpdateAvailable, language: language),
            release.version
        )

        var details = [
            String(
                format: Localization.text(.generalUpdateRunningVersion, language: language),
                running,
                release.version
            )
        ]
        let notes = UpdatePolicy.summarizedNotes(release.notes)
        if !notes.isEmpty { details.append(notes) }
        alert.informativeText = details.joined(separator: "\n\n")

        alert.addButton(withTitle: Localization.text(.generalUpdateOpenReleasePage, language: language))
        alert.addButton(withTitle: Localization.text(.generalUpdateSkip, language: language))
        alert.addButton(withTitle: Localization.text(.commonCancel, language: language))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.pageURL)
        case .alertSecondButtonReturn:
            store.mutate { $0.general.skippedUpdateVersion = release.version }
        default:
            break   // "Later": the daily throttle keeps this quiet until tomorrow
        }
    }
}
