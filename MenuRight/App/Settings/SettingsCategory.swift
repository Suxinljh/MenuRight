import Foundation

/// One entry in the settings sidebar.
///
/// Raw values are stable identifiers (never shown); the visible text comes from
/// `StringKey`, so a category is fully localized.
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case filePermissions
    case folderPermissions
    case general
    case newFile
    case favoriteFolders
    case favoriteApps
    case favoriteWebsites
    case codeTheme
    case archives

    var id: String { rawValue }

    var titleKey: StringKey {
        switch self {
        case .filePermissions: return .categoryFilePermissions
        case .folderPermissions: return .categoryFolderPermissions
        case .general: return .categoryGeneral
        case .newFile: return .categoryNewFile
        case .favoriteFolders: return .categoryFavoriteFolders
        case .favoriteApps: return .categoryFavoriteApps
        case .favoriteWebsites: return .categoryFavoriteWebsites
        case .codeTheme: return .categoryCodeTheme
        case .archives: return .categoryArchives
        }
    }

    /// Lucide icon rendered in the sidebar, from
    /// `MenuRight/Resources/SidebarIcons.xcassets`.
    ///
    /// Lucide is the icon set of record for the sidebar (ISC licensed; the
    /// upstream licence ships in `Resources/Third-Party-Notices/`). Pane-internal
    /// rows still use SF Symbols, which is why no SF Symbol name appears here.
    ///
    /// These are Lucide's own names, pinned by `Scripts/fetch-sidebar-icons.sh`
    /// (currently 1.49.0); `Scripts/check-sidebar-icons.sh` fails if a name drifts
    /// from the committed catalog. Lucide renames icons between releases, so bump
    /// the pin and re-run both scripts rather than editing a name by hand.
    var iconAsset: String {
        switch self {
        case .filePermissions: return "lucide-file-key"
        case .folderPermissions: return "lucide-folder-key"
        case .general: return "lucide-bolt"
        case .newFile: return "lucide-file-plus-corner"
        case .favoriteFolders: return "lucide-folders"
        case .favoriteApps: return "lucide-app-window-mac"
        case .favoriteWebsites: return "lucide-globe-code"
        case .codeTheme: return "lucide-palette"
        case .archives: return "lucide-file-archive"
        }
    }

    /// Sidebar sections, in display order. Categories keep the order the
    /// product spec lists them in.
    struct Section: Identifiable {
        let id: String
        let titleKey: StringKey
        let categories: [SettingsCategory]
    }

    static let sections: [Section] = [
        Section(
            id: "permissions",
            titleKey: .sidebarSectionPermissions,
            categories: [.filePermissions, .folderPermissions]
        ),
        Section(
            id: "general",
            titleKey: .sidebarSectionGeneral,
            categories: [
                .general,
                .newFile,
                .favoriteFolders,
                .favoriteApps,
                .favoriteWebsites,
                .codeTheme,
                .archives,
            ]
        ),
    ]

    /// Pane shown when the window opens. General carries app info and the
    /// extension/IPC status, so it is the most useful landing page.
    static let `default`: SettingsCategory = .general
}
