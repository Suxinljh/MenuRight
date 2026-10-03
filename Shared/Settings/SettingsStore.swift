import Foundation
import Combine

/// Single owner of the persisted settings tree, shared by every pane.
///
/// Storage is one JSON value in the App Group `UserDefaults` (the same group
/// that carries authorized folders and the IPC socket), so the Finder extension
/// can read the same payload later without a second storage location.
///
/// Threading contract: the tree is read from **any** thread and written from the
/// main thread. `mutate(_:)` applies changes synchronously when called on the
/// main thread (the normal path from SwiftUI) and hops to the main thread
/// otherwise. The whole value lives behind a lock, so a reader on the IPC
/// connection queue (the dispatcher's settings closures) can never observe a
/// half-replaced tree; `objectWillChange` is sent by hand, because `@Published`
/// publishes a *willSet* that a lock-protected read would no longer be able to
/// keep in step. `@unchecked Sendable` alone would only have silenced the
/// diagnostic, not removed the race.
///
/// A corrupt payload loads as defaults: the app must always be able to open its
/// settings window and rewrite the value.
final class SettingsStore: ObservableObject, @unchecked Sendable {
    static let storageKey = MenuRightAppGroup.settingsStorageKey

    /// Posted (on the main thread) after a change is applied and persisted, so
    /// the app can republish derived state (see `MenuRightApp`) and a future
    /// extension-side cache can invalidate itself.
    static let didChangeNotification = Notification.Name("xin.ljhsu.MenuRight.settingsDidChange")

    /// Process-wide store used by the app UI.
    static let shared = SettingsStore(defaults: SettingsStore.defaultUserDefaults())

    /// Manual publisher: every mutation of `storage` goes through `apply`, which
    /// sends this first so SwiftUI re-reads the store.
    let objectWillChange = ObservableObjectPublisher()

    private let lock = NSLock()
    private var storage: MenuRightSettings

    /// The current tree. Safe to call from any thread.
    var settings: MenuRightSettings {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

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
        self.storage = SettingsStore.read(from: defaults, storageKey: storageKey)
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

    /// Main thread only: both `objectWillChange` and the change notification are
    /// consumed on the main thread, and `mutate` is what funnels callers here.
    private func apply(_ body: (inout MenuRightSettings) -> Void) {
        var copy = settings
        body(&copy)
        copy = copy.normalized()
        guard copy != settings else { return }
        objectWillChange.send()
        lock.lock()
        storage = copy
        lock.unlock()
        persist(copy)
        NotificationCenter.default.post(name: SettingsStore.didChangeNotification, object: self)
    }

    /// Restores every pane to its initial value. Authorized folders are stored
    /// separately (`FolderAuthorizationStore`) and are deliberately untouched.
    func resetAll() {
        mutate { $0 = MenuRightSettings.default }
    }

    /// Re-reads the persisted payload, e.g. after another process wrote it.
    ///
    /// Behaves like a mutation for observers — main thread, `objectWillChange`,
    /// and the change notification — because a value that changed on disk is a
    /// value the UI has to redraw. It does **not** write back: reading must not
    /// modify what is stored.
    func reload() {
        let performReload = { [weak self] in
            guard let self else { return }
            let loaded = SettingsStore.read(from: self.defaults, storageKey: self.storageKey)
            guard loaded != self.settings else { return }
            self.objectWillChange.send()
            self.lock.lock()
            self.storage = loaded
            self.lock.unlock()
            NotificationCenter.default.post(name: SettingsStore.didChangeNotification, object: self)
        }
        if Thread.isMainThread {
            performReload()
        } else {
            DispatchQueue.main.async(execute: performReload)
        }
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
