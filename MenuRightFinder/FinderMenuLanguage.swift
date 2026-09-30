import Foundation

/// Resolves the language the Finder context menu is rendered in.
///
/// The main app is the only writer. It stores the whole settings tree as one JSON
/// value in the App Group `UserDefaults` (`SettingsStore.storageKey`), so the
/// extension reads that same payload and picks out the single field it needs —
/// no second copy of the setting to keep in sync, and changing the language in
/// 通用设置 is picked up by the next menu build.
///
/// Decoding is deliberately tolerant, matching `SettingsStore.read`: a missing
/// payload, unreadable data, or an unknown language value all fall back to
/// `.system`, which `AppLanguage.resolve` turns into a concrete language from the
/// system's preferred languages.
///
/// Reading `UserDefaults` is a `cfprefsd` lookup, not a filesystem scan, so the
/// "no file I/O while building the menu" rule still holds. The suite object is
/// reused, and nothing is cached in-process: an app-side language change must be
/// visible on the very next right-click.
enum FinderMenuLanguage {
    /// Mirrors the payload key in `SettingsStore`; a unit test asserts the two
    /// stay equal so a renamed key cannot silently stop the sync.
    static let storageKey = "xin.ljhsu.MenuRight.settings"

    private static let defaults: UserDefaults =
        UserDefaults(suiteName: MenuRightIPC.appGroupIdentifier) ?? .standard

    /// Only the branch this side needs. The app encodes
    /// `MenuRightSettings.general.language`; anything unknown decodes to `nil`.
    private struct Envelope: Decodable {
        struct General: Decodable {
            let language: AppLanguage?
        }

        let general: General?
    }

    /// What the user selected, `.system` when the payload says nothing usable.
    static func selection(from defaults: UserDefaults = FinderMenuLanguage.defaults) -> AppLanguage {
        guard let data = defaults.data(forKey: storageKey),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return .system }
        return envelope.general?.language ?? .system
    }

    /// The concrete language to render menu titles in.
    ///
    /// `preferred` is injectable so the `.system` resolution is testable without
    /// touching the process-wide locale.
    static func resolve(
        from defaults: UserDefaults = FinderMenuLanguage.defaults,
        preferred: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        AppLanguage.resolve(selection(from: defaults), preferred: preferred)
    }
}
