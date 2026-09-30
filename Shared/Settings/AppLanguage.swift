import Foundation

/// Language the settings UI is rendered in.
///
/// The app ships no `.lproj` resources: the settings UI is one SwiftUI scene,
/// so an in-memory catalog (`Localization`, keyed by `StringKey`) is used
/// instead. That keeps switching deterministic and immediate — no relaunch —
/// which is what the "Language" row in General promises.
///
/// The catalog covers Simplified Chinese and English. `.system` resolves to
/// Simplified Chinese for any `zh*` preferred language, otherwise English.
enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    /// Resolves a user selection (possibly `.system`) into a concrete language.
    ///
    /// `preferred` is injectable so the resolution is testable without touching
    /// the process-wide locale.
    static func resolve(
        _ selection: AppLanguage,
        preferred: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        switch selection {
        case .simplifiedChinese, .english:
            return selection
        case .system:
            guard let first = preferred.first?.lowercased(), !first.isEmpty else {
                return .english
            }
            // Any Chinese variant falls back to Simplified: it is the only
            // Chinese catalog that exists today.
            return first.hasPrefix("zh") ? .simplifiedChinese : .english
        }
    }
}
