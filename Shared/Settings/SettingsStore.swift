import Foundation
import Combine

/// Single owner of the persisted settings tree, shared by every pane.
///
/// Storage is one JSON value in the App Group `UserDefaults` (the same group
/// that carries authorized folders and the IPC socket), so the Finder extension
/// can read the same payload later without a second storage location.
///
/// Threading contract: `settings` is a main-thread value. `mutate(_:)` applies
/// changes synchronously when called on the main thread (the normal path from
/// SwiftUI) and hops to the main thread otherwise, so a call from a background
/// context can never publish a half-applied state. `@unchecked Sendable` is the
/// same trade-off `IPCStatusCenter` already makes: the mutation is funnelled to
/// one thread rather than protected by a lock.
///
/// A corrupt payload loads as defaults: the app must always be able to open its
/// settings window and rewrite the value.
final class SettingsStore: ObservableObject, @unchecked Sendable {
    static let storageKey = MenuRightAppGroup.settingsStorageKey

    /// Posted (on the main thread) after a change is applied and persisted, so
    /// a future extension-side cache can invalidate itself.
    static let didChangeNotification = Notification.Name("xin.ljhsu.MenuRight.settingsDidChange")

    /// Process-wide store used by the app UI.
    static let shared = SettingsStore(defaults: SettingsStore.defaultUserDefaults())

    @Published private(set) var settings: MenuRightSettings

    private let defaults: UserDefaults
    private let storageKey: String

    /// App Group defaults, falling back to `.standard` when the group container
    /// is unavailable (for example an unsigned build) so the UI still works and
    /// merely stops sharing with the extension.
    static func defaultUserDefaults() -> UserDefaults {
        UserDefaults(suiteName: MenuRightIPC.appGroupIdentifier) ?? .standard
    }

    init(defaults: UserDefaults, storageKey: String = SettingsStore.storageKey) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.settings = SettingsStore.read(from: defaults, storageKey: storageKey)
    }

    /// Reads and repairs a persisted payload. Never throws: any failure means
    /// "no usable settings yet", not "refuse to start".
    static func read(from defaults: UserDefaults, storageKey: String = SettingsStore.storageKey) -> MenuRightSettings {
        guard let data = defaults.data(forKey: storageKey) else { return .default }
        guard let decoded = try? JSONDecoder().decode(MenuRightSettings.self, from: data) else {
            return .default
        }
        return decoded.normalized()
    }

    // MARK: - Mutation

    /// Applies `body` to the current tree, persists the result, and republishes.
    ///
    /// `body` is `@escaping` because the off-main path re-invokes it on the main
    /// thread rather than applying a half-visible change from a background
    /// context.
    func mutate(_ body: @escaping (inout MenuRightSettings) -> Void) {
        if Thread.isMainThread {
            apply(body)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.apply(body)
            }
        }
    }

    private func apply(_ body: (inout MenuRightSettings) -> Void) {
        var copy = settings
        body(&copy)
        copy = copy.normalized()
        guard copy != settings else { return }
        settings = copy
        persist(copy)
        NotificationCenter.default.post(name: SettingsStore.didChangeNotification, object: self)
    }

    /// Restores every pane to its initial value. Authorized folders are stored
    /// separately (`FolderAuthorizationStore`) and are deliberately untouched.
    func resetAll() {
        mutate { $0 = MenuRightSettings.default }
    }

    /// Re-reads the persisted payload, e.g. after another process wrote it.
    func reload() {
        let loaded = SettingsStore.read(from: defaults, storageKey: storageKey)
        guard loaded != settings else { return }
        settings = loaded
    }

    private func persist(_ value: MenuRightSettings) {
        let encoder = JSONEncoder()
        // Stable key order keeps the stored payload diffable and makes the
        // round-trip tests deterministic.
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: storageKey)
    }

    // MARK: - Read helpers

    /// Concrete language, after resolving `.system`.
    var language: AppLanguage {
        AppLanguage.resolve(settings.general.language)
    }

    /// Localized settings-UI string for the current language.
    func text(_ key: StringKey) -> String {
        Localization.text(key, language: language)
    }

    /// Whether the Finder menu may offer `action`.
    func isAllowed(_ action: FileAction) -> Bool {
        settings.filePermissions.isAllowed(action)
    }
}
