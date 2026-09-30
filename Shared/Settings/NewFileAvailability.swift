import Foundation

/// What the **main app** can actually create right now, published to the App
/// Group so the Finder extension can hide menu items that would fail.
///
/// Why this is not a field of `MenuRightSettings`: availability is derived state
/// (does this build's bundle carry `Templates/blank.pages`?), not a user
/// preference. Mixing it into the settings tree would make a user-visible
/// payload depend on which build happens to be running, and the settings pane
/// would have to keep re-deriving it.
///
/// Raw strings instead of `NewFileType` on purpose: this file is compiled into
/// the Finder extension, which does not carry the settings type catalog. The
/// extension maps the strings onto its own `NewFileKind`.
struct NewFileAvailability: Codable, Equatable, Sendable {
    /// Mirrors `SettingsStore.storageKey` conventions: one JSON value under one
    /// App Group key, written only by the main app.
    static let storageKey = "xin.ljhsu.MenuRight.newFileAvailability"
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// `NewFileType` raw values (for example `text`, `docx`, `pages`).
    var creatableTypes: [String]

    init(schemaVersion: Int = NewFileAvailability.currentSchemaVersion, creatableTypes: [String]) {
        self.schemaVersion = schemaVersion
        self.creatableTypes = creatableTypes
    }

    func canCreate(_ rawValue: String) -> Bool {
        creatableTypes.contains(rawValue)
    }

    /// The App Group suite both processes share, falling back to `.standard` the
    /// same way `SettingsStore` does when the group container is unavailable
    /// (for example an unsigned build).
    static var appGroupDefaults: UserDefaults {
        UserDefaults(suiteName: MenuRightIPC.appGroupIdentifier) ?? .standard
    }

    /// Convenience for the extension's `menu(for:)`: read the payload the main
    /// app published.
    static func readFromAppGroup() -> NewFileAvailability? {
        read(from: appGroupDefaults)
    }

    /// Reads the published payload. `nil` means "the main app has not published
    /// anything yet" (fresh install, first launch after an update), which the
    /// extension must treat as the conservative text-only menu rather than as
    /// "nothing can be created".
    ///
    /// `UserDefaults` reads are `cfprefsd` lookups, not filesystem scans, so the
    /// "no IO while building the menu" rule still holds.
    static func read(from defaults: UserDefaults) -> NewFileAvailability? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(NewFileAvailability.self, from: data)
    }

    /// Publishes the payload. `sortedKeys` keeps the stored bytes diffable and
    /// the read-back test deterministic.
    func write(to defaults: UserDefaults) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
