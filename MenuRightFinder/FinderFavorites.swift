import Foundation

/// One favorite as the Finder submenu needs it: what to show and what to open.
///
/// Deliberately a separate, tiny model. This file is compiled into the sandboxed
/// FinderSync extension, which must not drag the app's settings tree (and its
/// `decodeOr` helper, SwiftUI-era types, …) into the appex. It decodes the same
/// App-Group JSON the app writes and keeps only the fields a menu item and an
/// open request need.
struct FinderFavoriteEntry: Equatable {
    enum Kind: String, Equatable {
        case folder
        case application
        case website
    }

    let kind: Kind
    /// The menu title. Finder replays an action through a reconstructed
    /// `NSMenuItem` that does not carry `representedObject`, so **the title is
    /// the only key** the extension gets back — duplicates are therefore
    /// disambiguated when the list is built (see `FinderFavorites.entries`).
    let menuTitle: String
    /// Folder path, application path or bundle identifier, or an http(s) URL.
    /// `FileOperationDispatcher` decides how to open it by shape.
    let target: String
}

/// The three favorite lists in the language-free form the menu needs.
enum FinderFavorites {
    /// Mirrors the key in `SettingsStore`; a unit test asserts the two stay
    /// equal so a renamed key cannot silently empty every favorites submenu.
    static let storageKey = "xin.ljhsu.MenuRight.settings"

    static var appGroupDefaults: UserDefaults {
        UserDefaults(suiteName: MenuRightIPC.appGroupIdentifier) ?? .standard
    }

    /// Only the branches this side needs. Every field is optional: a payload
    /// written by an older or newer build must still yield a usable list rather
    /// than an empty menu.
    private struct Envelope: Decodable {
        struct Folder: Decodable {
            let displayName: String?
            let path: String?
            let isEnabled: Bool?
        }

        struct Application: Decodable {
            let displayName: String?
            let path: String?
            let bundleIdentifier: String?
            let isEnabled: Bool?
        }

        struct Website: Decodable {
            let displayName: String?
            let urlString: String?
            let isEnabled: Bool?
        }

        let favoriteFolders: [Folder]?
        let favoriteApps: [Application]?
        let favoriteWebsites: [Website]?
    }

    /// Everything the menu may offer, in settings order, disabled rows dropped,
    /// every title unique.
    ///
    /// `UserDefaults` reads are `cfprefsd` lookups, not filesystem scans, so the
    /// "no IO while building the menu" rule holds. Nothing is cached: a change
    /// in the settings pane must be visible on the very next right-click.
    static func entries(from defaults: UserDefaults = appGroupDefaults) -> [FinderFavoriteEntry] {
        guard let data = defaults.data(forKey: storageKey),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return [] }

        var raw: [(kind: FinderFavoriteEntry.Kind, name: String, target: String)] = []

        for folder in envelope.favoriteFolders ?? [] where folder.isEnabled ?? true {
            let path = trimmed(folder.path)
            guard !path.isEmpty else { continue }
            raw.append((.folder, name(folder.displayName, fallback: URL(fileURLWithPath: path).lastPathComponent), path))
        }

        for app in envelope.favoriteApps ?? [] where app.isEnabled ?? true {
            let path = trimmed(app.path)
            let identifier = trimmed(app.bundleIdentifier)
            guard let target = path.isEmpty ? (identifier.isEmpty ? nil : identifier) : path else { continue }
            let fallback = URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent
            raw.append((.application, name(app.displayName, fallback: fallback), target))
        }

        for website in envelope.favoriteWebsites ?? [] where website.isEnabled ?? true {
            let rawURL = trimmed(website.urlString)
            guard let target = webURLString(rawURL) else { continue }
            let host = URL(string: target)?.host ?? target
            raw.append((.website, name(website.displayName, fallback: host), target))
        }

        return titled(raw)
    }

    /// The three groups in menu order: applications, websites, folders — the
    /// order the product spec lists them in the background menu.
    static func groups(from defaults: UserDefaults = appGroupDefaults)
        -> (applications: [FinderFavoriteEntry], websites: [FinderFavoriteEntry], folders: [FinderFavoriteEntry]) {
        let all = entries(from: defaults)
        return (
            all.filter { $0.kind == .application },
            all.filter { $0.kind == .website },
            all.filter { $0.kind == .folder }
        )
    }

    // MARK: - Helpers

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func name(_ displayName: String?, fallback: String) -> String {
        let trimmedName = trimmed(displayName)
        return trimmedName.isEmpty ? fallback : trimmedName
    }

    /// Accepts only http(s) with a host — the same rule the settings pane
    /// enforces. A `file:` or custom scheme must never become a menu item.
    static func webURLString(_ raw: String) -> String? {
        var candidate = raw
        guard !candidate.isEmpty, !candidate.contains(" ") else { return nil }
        if !candidate.contains("://") { candidate = "https://\(candidate)" }
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty
        else { return nil }
        return components.url?.absoluteString
    }

    /// Gives every entry a unique title.
    ///
    /// Two favorites sharing a name is normal ("GitHub" as an app and as a
    /// website), and a duplicate title would make a click ambiguous, so repeated
    /// names get a target-derived suffix, with a numeric suffix as the last
    /// resort. The result is a pure function of the payload, so action dispatch
    /// re-deriving the list reaches the same titles.
    private static func titled(
        _ raw: [(kind: FinderFavoriteEntry.Kind, name: String, target: String)]
    ) -> [FinderFavoriteEntry] {
        var counts: [String: Int] = [:]
        for item in raw { counts[item.name, default: 0] += 1 }

        var used = Set<String>()
        return raw.map { item in
            var title = item.name
            if (counts[item.name] ?? 0) > 1 {
                title += " — " + disambiguator(kind: item.kind, target: item.target)
            }
            let base = title
            var index = 2
            while used.contains(title) {
                title = "\(base) (\(index))"
                index += 1
            }
            used.insert(title)
            return FinderFavoriteEntry(kind: item.kind, menuTitle: title, target: item.target)
        }
    }

    private static func disambiguator(kind: FinderFavoriteEntry.Kind, target: String) -> String {
        switch kind {
        case .website:
            return URL(string: target)?.host ?? target
        case .application:
            // The enclosing folder separates "Preview" in /Applications from a
            // copy in ~/Applications.
            let url = URL(fileURLWithPath: target)
            return url.deletingLastPathComponent().lastPathComponent
        case .folder:
            let url = URL(fileURLWithPath: target)
            let parent = url.deletingLastPathComponent().lastPathComponent
            return parent.isEmpty ? target : "\(parent)/\(url.lastPathComponent)"
        }
    }
}
