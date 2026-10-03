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
    ///
    /// v2 added `FileAction.compressArchive`. A v1 payload *can* encode an
    /// `allowedActions` array, so "missing = default" does not apply to it: the
    /// new action would silently read as switched off for every existing user.
    /// `normalized()` therefore migrates the decoded v1 set (see
    /// `FilePermissionSettings.migrateAddingCompressArchive()`).
    static let currentSchemaVersion = 2

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
        // A payload without the key predates versioning, i.e. it is a v1 (or
        // older) tree: assume the oldest version so the v1 → v2 migration below
        // gets a chance to run. It only ever touches a set that matches exactly
        // what a v1 build wrote, so this cannot invent a choice for the user.
        schemaVersion = try container.decodeOr(Int.self, .schemaVersion, 1)
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
        // Read the *decoded* version before stamping the current one: the
        // migrations below are the only place that needs to know where the
        // payload came from.
        let storedVersion = schemaVersion
        copy.schemaVersion = MenuRightSettings.currentSchemaVersion
        if storedVersion < 2 {
            copy.filePermissions.migrateAddingCompressArchive()
        }
        copy.newFile = newFile.normalized()
        copy.general = general.normalized()
        copy.codeTheme = codeTheme.normalized()
        copy.archives = archives.normalized()
        return copy
    }
}

// MARK: - General

struct GeneralSettings: Codable, Equatable, Sendable {
    var language: AppLanguage
    var launchAtLogin: Bool
    /// Automatic update checks against GitHub Releases. On by default: one HTTPS
    /// request a day, and nothing is ever downloaded or installed automatically.
    var automaticallyChecksForUpdates: Bool
    /// Version the user chose to skip, so the prompt does not come back.
    var skippedUpdateVersion: String?
    /// When the last check finished, used to throttle the automatic one.
    var lastUpdateCheck: Date?
    /// **P6** Path of the terminal application 打开终端 should use. Empty means
    /// the built-in default (`SystemOpener.defaultTerminalURL()`), which is the
    /// only terminal this build installs: `/System/Applications/Utilities/Terminal.app`.
    ///
    /// A third-party terminal is launched the same way Terminal is — through its
    /// Finder service — so the service name is part of the configuration too.
    var terminalApplicationPath: String
    /// Name of the Finder service that opens a terminal at a folder
    /// (`"New Terminal at Folder"` for Terminal.app).
    var terminalServiceName: String

    static let defaultTerminalServiceName = "New Terminal at Folder"

    init(
        language: AppLanguage = .system,
        launchAtLogin: Bool = false,
        automaticallyChecksForUpdates: Bool = true,
        skippedUpdateVersion: String? = nil,
        lastUpdateCheck: Date? = nil,
        terminalApplicationPath: String = "",
        terminalServiceName: String = GeneralSettings.defaultTerminalServiceName
    ) {
        self.language = language
        self.launchAtLogin = launchAtLogin
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.skippedUpdateVersion = skippedUpdateVersion
        self.lastUpdateCheck = lastUpdateCheck
        self.terminalApplicationPath = terminalApplicationPath
        self.terminalServiceName = terminalServiceName
    }

    enum CodingKeys: String, CodingKey {
        case language
        case launchAtLogin
        case automaticallyChecksForUpdates
        case skippedUpdateVersion
        case lastUpdateCheck
        case terminalApplicationPath
        case terminalServiceName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A language added by a newer build (or removed by an older one) must
        // not invalidate the whole payload.
        let rawLanguage = try container.decodeOr(String.self, .language, AppLanguage.system.rawValue)
        language = AppLanguage(rawValue: rawLanguage) ?? .system
        launchAtLogin = try container.decodeOr(Bool.self, .launchAtLogin, false)
        // Defaults are `true` / nil, so a payload written by an older build
        // keeps checking for updates instead of silently opting out.
        automaticallyChecksForUpdates = try container.decodeOr(Bool.self, .automaticallyChecksForUpdates, true)
        skippedUpdateVersion = try container.decodeIfPresent(String.self, forKey: .skippedUpdateVersion)
        lastUpdateCheck = try container.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        terminalApplicationPath = try container.decodeOr(String.self, .terminalApplicationPath, "")
        terminalServiceName = try container.decodeOr(String.self, .terminalServiceName, GeneralSettings.defaultTerminalServiceName)
    }

    /// The configured terminal as a URL, or nil when the default should be used.
    var terminalApplicationURL: URL? {
        let path = terminalApplicationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// True when either terminal knob differs from the built-in default, i.e.
    /// when `SystemOpener` has to be reconfigured for this request.
    var usesCustomTerminal: Bool {
        terminalApplicationURL != nil || effectiveTerminalServiceName != GeneralSettings.defaultTerminalServiceName
    }

    var effectiveTerminalServiceName: String {
        let name = terminalServiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? GeneralSettings.defaultTerminalServiceName : name
    }

    func normalized() -> GeneralSettings {
        var copy = self
        copy.terminalApplicationPath = terminalApplicationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.terminalServiceName = effectiveTerminalServiceName
        return copy
    }
}

// MARK: - File permissions

/// A Finder-menu capability the user can switch off.
///
/// Raw values are stable identifiers. The set is the menu filter: the Finder
/// extension decodes `allowedActions` from the App Group settings payload and
/// drops any item whose action is switched off (`FinderMenuBuilder.plan`), so a
/// disabled action never appears in the context menu. Nothing here performs the
/// operation itself.
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
    case compressArchive
    case openFavorite

    /// Lucide asset for the row in 文件权限.
    ///
    /// Settings UI only. The Finder context menu does now draw icons, but only
    /// for the 常用文件夹/软件/网页 entries, and those come from the PNGs the app
    /// renders into the App Group (`FavoriteIconProvider`) — not from this
    /// catalog, which the sandboxed appex cannot read, and whose **template**
    /// images are exactly what Finder blits untinted. See README "常用项图标".
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
        case .compressArchive: return "lucide-archive"
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
        case .compressArchive: return .filePermissionActionCompressArchive
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

    /// v1 → v2 migration (see `MenuRightSettings.currentSchemaVersion`).
    ///
    /// A v1 payload stored an explicit `allowedActions` list that cannot mention
    /// the action added in v2, so the new one would decode as switched off for
    /// every existing user. When the stored set is exactly the set a v1 build
    /// knew — the user had everything on — the new action inherits that state.
    /// Any other set is a deliberate choice and is left untouched.
    mutating func migrateAddingCompressArchive() {
        let actionsKnownInV1 = FileAction.allCases.filter { $0 != .compressArchive }
        guard allowedActions == Set(actionsKnownInV1) else { return }
        allowedActions.insert(.compressArchive)
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
    /// **P7** Optional override for the folder the iWork templates are read
    /// from. Empty means the copies shipped inside the app bundle
    /// (`DocumentTemplateCatalog.bundledDirectory`).
    var templateDirectoryPath: String
    /// Security-scoped bookmark for `templateDirectoryPath`, created by the
    /// "选择…" button over an `NSOpenPanel` URL. The bookmark — not the path —
    /// is what lets the sandboxed app read a folder the user picked outside its
    /// container (`SecurityScopedBookmark`).
    var templateDirectoryBookmark: Data?

    static let defaultBaseName = "Untitled"

    init(
        baseName: String = NewFileSettings.defaultBaseName,
        types: [NewFileType] = NewFileType.allCases,
        enabledTypes: Set<NewFileType> = Set(NewFileType.allCases),
        templateDirectoryPath: String = "",
        templateDirectoryBookmark: Data? = nil
    ) {
        self.baseName = baseName
        self.types = types
        self.enabledTypes = enabledTypes
        self.templateDirectoryPath = templateDirectoryPath
        self.templateDirectoryBookmark = templateDirectoryBookmark
    }

    enum CodingKeys: String, CodingKey {
        case baseName
        case types
        case enabledTypes
        case templateDirectoryPath
        case templateDirectoryBookmark
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseName = try container.decodeOr(String.self, .baseName, NewFileSettings.defaultBaseName)
        let rawTypes = try container.decodeOr([String].self, .types, NewFileType.allCases.map(\.rawValue))
        types = rawTypes.compactMap(NewFileType.init(rawValue:))
        let rawEnabled = try container.decodeOr([String].self, .enabledTypes, NewFileType.allCases.map(\.rawValue))
        enabledTypes = Set(rawEnabled.compactMap(NewFileType.init(rawValue:)))
        templateDirectoryPath = try container.decodeOr(String.self, .templateDirectoryPath, "")
        templateDirectoryBookmark = try container.decodeIfPresent(Data.self, forKey: .templateDirectoryBookmark)
    }

    /// True when the user pointed the templates at their own folder.
    var hasCustomTemplateDirectory: Bool {
        !templateDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

        // Path and bookmark travel together: clearing the path (back to the
        // bundled templates) must not leave a stale bookmark behind.
        let trimmedPath = templateDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.templateDirectoryPath = trimmedPath
        if trimmedPath.isEmpty { copy.templateDirectoryBookmark = nil }
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
