import Foundation

/// App-Group views of the two settings blocks the Finder extension needs in
/// order to build its menu (**P7** 菜单可见性 / 文件权限 · 新建文件).
///
/// The appex target does not compile `MenuRightSettings.swift`, so it cannot use
/// `FileAction` or `NewFileType`. Like `FinderFavorites` and `FinderArchives` it
/// decodes the raw strings out of the payload the main app publishes under
/// `xin.ljhsu.MenuRight.settings`.
///
/// **Missing payload = permissive.** An extension that starts before the main
/// app has ever written settings must still offer its full menu, never an empty
/// one, so every field falls back to "allow".
enum FinderSettings {
    /// Same key `FinderFavorites` / `FinderArchives` already read.
    static let storageKey = "xin.ljhsu.MenuRight.settings"

    /// The base name used when the user has not chosen one.
    static let defaultBaseName = "Untitled"

    // MARK: - filePermissions

    /// `filePermissions` in menu terms. Raw values are `FileAction` raw values
    /// (`createFile`, `lockUnlock`, `compressArchive`, …).
    struct Permissions: Equatable {
        /// nil = the payload does not say → allow everything.
        var allowedActions: Set<String>?
        var restrictToAuthorizedFolders: Bool
        var confirmDestructiveActions: Bool

        static let permissive = Permissions(
            allowedActions: nil,
            restrictToAuthorizedFolders: true,
            confirmDestructiveActions: true
        )

        /// True when the action may appear in the menu.
        func allows(_ action: String) -> Bool {
            allowedActions?.contains(action) ?? true
        }
    }

    // MARK: - newFile

    /// `newFile` in menu terms: how 新建文件 ▸ is ordered, filtered and named.
    struct NewFileMenu: Equatable {
        var baseName: String
        /// Raw values in the user's drag-to-reorder order; unknown entries and
        /// duplicates are ignored.
        var orderedTypes: [String]
        /// Raw values switched on in 设置 → 新建文件; nil = all enabled.
        var enabledTypes: Set<String>?

        static let `default` = NewFileMenu(
            baseName: defaultBaseName,
            orderedTypes: [],
            enabledTypes: nil
        )

        func isEnabled(_ rawValue: String) -> Bool {
            enabledTypes?.contains(rawValue) ?? true
        }

        /// Never empty: a blank base name falls back to "Untitled".
        var effectiveBaseName: String {
            let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? FinderSettings.defaultBaseName : trimmed
        }
    }

    // MARK: - reading

    static var appGroupDefaults: UserDefaults {
        FinderFavorites.appGroupDefaults
    }

    private struct Envelope: Decodable {
        struct FilePermissions: Decodable {
            var allowedActions: [String]?
            var restrictToAuthorizedFolders: Bool?
            var confirmDestructiveActions: Bool?
        }

        struct NewFile: Decodable {
            var baseName: String?
            var types: [String]?
            var enabledTypes: [String]?
        }

        var filePermissions: FilePermissions?
        var newFile: NewFile?
    }

    /// One decode per menu build, like `FinderFavorites.entries()`.
    static func read(
        from defaults: UserDefaults = appGroupDefaults
    ) -> (permissions: Permissions, newFile: NewFileMenu) {
        guard let data = defaults.data(forKey: storageKey),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return (.permissive, .default)
        }

        let permissions: Permissions
        if let raw = envelope.filePermissions {
            permissions = Permissions(
                allowedActions: raw.allowedActions.map(Set.init),
                restrictToAuthorizedFolders: raw.restrictToAuthorizedFolders ?? true,
                confirmDestructiveActions: raw.confirmDestructiveActions ?? true
            )
        } else {
            permissions = .permissive
        }

        let newFile: NewFileMenu
        if let raw = envelope.newFile {
            newFile = NewFileMenu(
                baseName: raw.baseName ?? defaultBaseName,
                orderedTypes: raw.types ?? [],
                enabledTypes: raw.enabledTypes.map(Set.init)
            )
        } else {
            newFile = .default
        }

        return (permissions, newFile)
    }
}
