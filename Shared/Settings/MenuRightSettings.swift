import Foundation

/// Root of the persisted settings tree.
///
/// One JSON snapshot lives in the shared App Group `UserDefaults` under
/// `SettingsStore.storageKey`. Everything the Finder menu needs later (allowed
/// actions, new-file types, favorites, archive policy) hangs off this value, so
/// the extension can read one payload instead of many keys.
///
/// Decoding is deliberately forgiving: every field falls back to its default
/// when absent, so a payload written by an older build never invalidates the
/// whole tree.
struct MenuRightSettings: Codable, Equatable, Sendable {
    /// Bumped only for breaking payload changes; additive fields do not bump it
    /// because decoding fills missing fields with defaults.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var general: GeneralSettings
    var filePermissions: FilePermissionSettings
    var newFile: NewFileSettings
    var favoriteFolders: [FavoriteFolder]
    var favoriteApps: [FavoriteApp]
    var favoriteWebsites: [FavoriteWebsite]
    var codeTheme: CodeThemeSettings
    var archives: ArchiveSettings

    init(
        schemaVersion: Int = MenuRightSettings.currentSchemaVersion,
        general: GeneralSettings = GeneralSettings(),
        filePermissions: FilePermissionSettings = FilePermissionSettings(),
        newFile: NewFileSettings = NewFileSettings(),
        favoriteFolders: [FavoriteFolder] = [],
        favoriteApps: [FavoriteApp] = [],
        favoriteWebsites: [FavoriteWebsite] = [],
        codeTheme: CodeThemeSettings = CodeThemeSettings(),
        archives: ArchiveSettings = ArchiveSettings()
    ) {
        self.schemaVersion = schemaVersion
        self.general = general
        self.filePermissions = filePermissions
        self.newFile = newFile
        self.favoriteFolders = favoriteFolders
        self.favoriteApps = favoriteApps
        self.favoriteWebsites = favoriteWebsites
        self.codeTheme = codeTheme
        self.archives = archives
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case general
        case filePermissions
        case newFile
        case favoriteFolders
        case favoriteApps
        case favoriteWebsites
        case codeTheme
        case archives
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeOr(Int.self, .schemaVersion, MenuRightSettings.currentSchemaVersion)
        general = try container.decodeOr(GeneralSettings.self, .general, GeneralSettings())
        filePermissions = try container.decodeOr(FilePermissionSettings.self, .filePermissions, FilePermissionSettings())
        newFile = try container.decodeOr(NewFileSettings.self, .newFile, NewFileSettings())
        favoriteFolders = try container.decodeOr([FavoriteFolder].self, .favoriteFolders, [])
        favoriteApps = try container.decodeOr([FavoriteApp].self, .favoriteApps, [])
        favoriteWebsites = try container.decodeOr([FavoriteWebsite].self, .favoriteWebsites, [])
        codeTheme = try container.decodeOr(CodeThemeSettings.self, .codeTheme, CodeThemeSettings())
        archives = try container.decodeOr(ArchiveSettings.self, .archives, ArchiveSettings())
    }

    /// Defaults, normalized for the current catalog.
    static let `default` = MenuRightSettings().normalized()

    /// Repairs values that can drift when the catalogs change between builds:
    /// a stored `types` list is extended with newly added kinds, and selections
    /// that are no longer valid are dropped. Called on load and before every
    /// save, so the persisted tree is always self-consistent.
    func normalized() -> MenuRightSettings {
        var copy = self
        copy.schemaVersion = MenuRightSettings.currentSchemaVersion
        copy.newFile = newFile.normalized()
        copy.codeTheme = codeTheme.normalized()
        copy.archives = archives.normalized()
        return copy
    }
}

// MARK: - General

struct GeneralSettings: Codable, Equatable, Sendable {
    var language: AppLanguage
    var launchAtLogin: Bool

    init(language: AppLanguage = .system, launchAtLogin: Bool = false) {
        self.language = language
        self.launchAtLogin = launchAtLogin
    }

    enum CodingKeys: String, CodingKey {
        case language
        case launchAtLogin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A language added by a newer build (or removed by an older one) must
        // not invalidate the whole payload.
        let rawLanguage = try container.decodeOr(String.self, .language, AppLanguage.system.rawValue)
        language = AppLanguage(rawValue: rawLanguage) ?? .system
        launchAtLogin = try container.decodeOr(Bool.self, .launchAtLogin, false)
    }
}

// MARK: - File permissions

/// A Finder-menu capability the user can switch off.
///
/// Raw values are stable identifiers. The set is used as a menu filter later;
/// nothing here performs the operation itself.
enum FileAction: String, Codable, CaseIterable, Sendable {
    case createFile
    case createFolder
    case createAlias
    case cutPaste
    case copyName
    case copyPath
    case copyFileURL
    case lockUnlock
    case openTerminal
    case extractArchive
    case openFavorite

    /// Lucide asset for the row in 文件权限.
    ///
    /// Settings UI only: the Finder context menu deliberately shows no icons,
    /// because Finder draws extension menu item images without the highlighted
    /// or disabled text tint (and a menu with icons also reserves an icon
    /// column). See README "Settings and right-click icons".
    ///
    /// Every action has its own icon. The five that had none assigned
    /// (`createAlias`, `copyFileURL`, `lockUnlock`, `extractArchive`,
    /// `openFavorite`) use semantically matching Lucide icons so the list does
    /// not look half-finished.
    var iconAsset: String {
        switch self {
        case .openTerminal: return "lucide-square-chevron-right"
        case .copyName: return "lucide-copy"
        case .copyPath: return "lucide-spline-pointer"
        case .createFile: return "lucide-file-plus-corner"
        case .createFolder: return "lucide-folder-closed"
        case .cutPaste: return "lucide-clipboard"
        case .createAlias: return "lucide-square-arrow-out-up-right"
        case .copyFileURL: return "lucide-link"
        case .lockUnlock: return "lucide-lock-keyhole"
        case .extractArchive: return "lucide-file-archive"
        case .openFavorite: return "lucide-star"
        }
    }

    var titleKey: StringKey {
        switch self {
        case .createFile: return .filePermissionActionCreateFile
        case .createFolder: return .filePermissionActionCreateFolder
        case .createAlias: return .filePermissionActionCreateAlias
        case .cutPaste: return .filePermissionActionCutPaste
        case .copyName: return .filePermissionActionCopyName
        case .copyPath: return .filePermissionActionCopyPath
        case .copyFileURL: return .filePermissionActionCopyFileURL
        case .lockUnlock: return .filePermissionActionLockUnlock
        case .openTerminal: return .filePermissionActionOpenTerminal
        case .extractArchive: return .filePermissionActionExtractArchive
        case .openFavorite: return .filePermissionActionOpenFavorite
        }
    }
}

struct FilePermissionSettings: Codable, Equatable, Sendable {
    var allowedActions: Set<FileAction>
    var restrictToAuthorizedFolders: Bool
    var confirmDestructiveActions: Bool

    init(
        allowedActions: Set<FileAction> = Set(FileAction.allCases),
        restrictToAuthorizedFolders: Bool = true,
        confirmDestructiveActions: Bool = true
    ) {
        self.allowedActions = allowedActions
        self.restrictToAuthorizedFolders = restrictToAuthorizedFolders
        self.confirmDestructiveActions = confirmDestructiveActions
    }

    enum CodingKeys: String, CodingKey {
        case allowedActions
        case restrictToAuthorizedFolders
        case confirmDestructiveActions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decoded as strings: an action this build does not know is dropped
        // rather than failing the entire settings payload.
        let rawActions = try container.decodeOr([String].self, .allowedActions, FileAction.allCases.map(\.rawValue))
        allowedActions = Set(rawActions.compactMap(FileAction.init(rawValue:)))
        restrictToAuthorizedFolders = try container.decodeOr(Bool.self, .restrictToAuthorizedFolders, true)
        confirmDestructiveActions = try container.decodeOr(Bool.self, .confirmDestructiveActions, true)
    }

    func isAllowed(_ action: FileAction) -> Bool {
        allowedActions.contains(action)
    }
}

// MARK: - New file

struct NewFileSettings: Codable, Equatable, Sendable {
    /// Base name, without extension. The extension appends the kind's extension
    /// and `FileNameResolver` appends a numeric suffix on collision.
    var baseName: String
    /// Menu order. `normalized()` keeps it in sync with `NewFileType.allCases`.
    var types: [NewFileType]
    var enabledTypes: Set<NewFileType>

    static let defaultBaseName = "Untitled"

    init(
        baseName: String = NewFileSettings.defaultBaseName,
        types: [NewFileType] = NewFileType.allCases,
        enabledTypes: Set<NewFileType> = Set(NewFileType.allCases)
    ) {
        self.baseName = baseName
        self.types = types
        self.enabledTypes = enabledTypes
    }

    enum CodingKeys: String, CodingKey {
        case baseName
        case types
        case enabledTypes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseName = try container.decodeOr(String.self, .baseName, NewFileSettings.defaultBaseName)
        let rawTypes = try container.decodeOr([String].self, .types, NewFileType.allCases.map(\.rawValue))
        types = rawTypes.compactMap(NewFileType.init(rawValue:))
        let rawEnabled = try container.decodeOr([String].self, .enabledTypes, NewFileType.allCases.map(\.rawValue))
        enabledTypes = Set(rawEnabled.compactMap(NewFileType.init(rawValue:)))
    }

    func normalized() -> NewFileSettings {
        var copy = self
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.baseName = trimmed.isEmpty ? NewFileSettings.defaultBaseName : trimmed

        // Keep the stored order, drop duplicates/unknowns, then append kinds
        // added by a newer build so they are never silently invisible.
        var seen = Set<NewFileType>()
        var ordered: [NewFileType] = []
        for type in types where !seen.contains(type) {
            seen.insert(type)
            ordered.append(type)
        }
        for type in NewFileType.allCases where !seen.contains(type) {
            seen.insert(type)
            ordered.append(type)
        }
        copy.types = ordered
        copy.enabledTypes = enabledTypes.intersection(Set(NewFileType.allCases))
        return copy
    }
}

// MARK: - Decoding helper

extension KeyedDecodingContainer {
    /// Decodes `key`, falling back to `fallback` when it is missing or null.
    /// Type mismatches still throw: that means the payload is corrupt, and the
    /// store treats a corrupt payload as "no settings" rather than guessing.
    func decodeOr<T: Decodable>(_ type: T.Type, _ key: Key, _ fallback: T) throws -> T {
        try decodeIfPresent(type, forKey: key) ?? fallback
    }
}
