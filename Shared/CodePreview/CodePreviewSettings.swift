import Foundation

/// The slice of app settings the Quick Look preview needs.
///
/// Decoded straight from the App Group payload instead of through
/// `SettingsStore`, so the extension does not have to compile the whole settings
/// model (favourites, archives, new-file types…). Anything missing, unknown or
/// corrupt resolves to defaults: a preview must never fail — or refuse to open —
/// because settings are absent.
struct CodePreviewSettings: Equatable, Sendable {
    var theme: CodeThemeSettings
    var language: AppLanguage

    init(theme: CodeThemeSettings = CodeThemeSettings(), language: AppLanguage = .system) {
        self.theme = theme
        self.language = language
    }

    static let `default` = CodePreviewSettings()

    /// Concrete catalog language for the current selection.
    var resolvedLanguage: AppLanguage { AppLanguage.resolve(language) }

    /// Reads the payload the main app wrote into the App Group. The defaults
    /// parameter is injectable so the behaviour is unit-testable.
    static func load(
        from defaults: UserDefaults? = UserDefaults(suiteName: MenuRightAppGroup.identifier)
    ) -> CodePreviewSettings {
        guard let defaults,
              let data = defaults.data(forKey: MenuRightAppGroup.settingsStorageKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return .default
        }

        return CodePreviewSettings(
            theme: (payload.codeTheme ?? CodeThemeSettings()).normalized(),
            // Mirrors `GeneralSettings`: an unknown language string must not
            // invalidate the rest of the payload.
            language: payload.general?.language.flatMap(AppLanguage.init(rawValue:)) ?? .system
        )
    }

    /// Only the two sub-trees the preview reads. `Payload` decodes nothing else,
    /// so a payload written by a newer app version still loads here.
    private struct Payload: Decodable {
        var codeTheme: CodeThemeSettings?
        var general: General?

        struct General: Decodable {
            var language: String?
        }
    }
}
