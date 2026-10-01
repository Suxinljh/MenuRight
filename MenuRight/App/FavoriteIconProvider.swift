import AppKit
import Foundation
import os

/// Renders and stores the icon of every favorite entry.
///
/// **Why the main app is the only producer.** The Finder extension is sandboxed
/// with no `NSWorkspace` reach for the user's folders and no network access, so
/// it cannot draw an app icon, a folder icon or a favicon. Instead the app writes
/// one PNG per entry into `<App Group>/FavoritesIcons/` and stores that file name
/// on the entry (`FavoriteFolder.iconFile`); the extension reads it back through
/// `FinderFavoriteIcons`. Nothing else crosses the process boundary — the
/// extension never learns a path, only a file name.
///
/// This is *not* the first attempt at menu icons in this project: an earlier
/// build shipped **template** images, and Finder blitted them untinted, so a
/// highlighted row showed a black glyph. Full-colour PNGs have nothing to tint,
/// which is what makes them safe here. See README "Finder 右键菜单的图标".
enum FavoriteIconProvider {
    /// Entry kinds. Also the file-name prefix, so icons can never collide.
    enum Kind: String {
        case folder
        case application
        case website
    }

    private static let log = Logger(subsystem: MenuRightIPC.subsystem, category: "favorite-icons")

    /// Longest edge of a stored icon: enough for a 32 pt Retina menu row, small
    /// enough that each file stays in the low kilobytes.
    static let pixelSize = 64

    /// Stable per-entry file name. The entry's own id is the key, so editing an
    /// entry refreshes its own file instead of leaving one behind.
    static func fileName(for id: UUID, kind: Kind) -> String {
        "\(kind.rawValue)-\(id.uuidString.lowercased()).png"
    }

    /// The icon folder, created on demand. nil when the App Group container is
    /// unavailable (running unsigned outside the app, as some tests do).
    static func directory(create: Bool = true) -> URL? {
        guard let url = MenuRightIPC.favoriteIconsDirectoryURL() else { return nil }
        if create {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Reads a stored icon back. The panes use this so the settings list and the
    /// Finder menu show the very same image.
    static func image(named fileName: String?) -> NSImage? {
        guard let fileName, !fileName.isEmpty, let directory = directory(create: false) else { return nil }
        // The name round-trips through a JSON payload; keep it inside the folder.
        guard isSafeFileName(fileName) else { return nil }
        return NSImage(contentsOf: directory.appendingPathComponent(fileName))
    }

    /// Writes `image` as PNG and returns the file name, or nil when it could not
    /// be stored — the entry then simply has no icon.
    @discardableResult
    static func store(_ image: NSImage, named fileName: String) -> String? {
        guard isSafeFileName(fileName), let directory = directory() else { return nil }
        guard let data = pngData(from: image) else {
            log.error("favorite icon encode failed name=\(fileName, privacy: .public)")
            return nil
        }
        do {
            try data.write(to: directory.appendingPathComponent(fileName), options: [.atomic])
            return fileName
        } catch {
            log.error("favorite icon write failed name=\(fileName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Deletes a stored icon. Called when the entry is removed so the container
    /// does not accumulate orphans.
    static func delete(fileName: String?) {
        guard let fileName, isSafeFileName(fileName), let directory = directory(create: false) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    static func isSafeFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty
            && !fileName.contains("/")
            && !fileName.contains("\\")
            && fileName != ".."
            && fileName != "."
    }

    /// Renders `image` into a square `pixelSize` PNG.
    ///
    /// The fixed size matters: menu items and list rows must not each pick a
    /// different scale out of a 512×512 source.
    static func pngData(from image: NSImage) -> Data? {
        let side = pixelSize
        guard side > 0, image.size.width > 0, image.size.height > 0 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let box = NSRect(x: 0, y: 0, width: side, height: side)
        image.draw(in: box, from: NSRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current?.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Per-kind icons

    /// Folder icon — which honours a custom icon the user set on that folder in
    /// Finder, because `NSWorkspace` resolves the real one.
    @discardableResult
    static func refresh(folder: FavoriteFolder) -> String? {
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        return store(
            NSWorkspace.shared.icon(forFile: folder.path),
            named: fileName(for: folder.id, kind: .folder)
        )
    }

    @discardableResult
    static func refresh(app: FavoriteApp) -> String? {
        guard FileManager.default.fileExists(atPath: app.path) else { return nil }
        return store(
            NSWorkspace.shared.icon(forFile: app.path),
            named: fileName(for: app.id, kind: .application)
        )
    }

    /// Website favicon. A network round trip, so it is async and may legitimately
    /// come back nil: the menu then shows the title alone.
    @discardableResult
    static func refresh(website: FavoriteWebsite) async -> String? {
        guard let urlString = FavoriteWebsite.normalizedURLString(from: website.urlString),
              let pageURL = URL(string: urlString)
        else { return nil }
        guard let data = await FaviconLoader.fetch(from: pageURL), let image = NSImage(data: data) else {
            log.info("favorite icon no favicon host=\(pageURL.host ?? "", privacy: .public)")
            return nil
        }
        return store(image, named: fileName(for: website.id, kind: .website))
    }
}

/// Fills in the icons a build has not rendered yet.
///
/// The settings panes render icons too, but they only run when the user visits
/// them. Without this, a freshly installed build would show plain titles in the
/// Finder submenu until the user happened to open each favorites pane — so the
/// app tops the App Group up once per launch instead.
///
/// Cheap when everything is already there: one file check per entry, no
/// rendering, no network.
@MainActor
enum FavoriteIconBootstrap {
    static func run(store: SettingsStore) {
        var folderUpdates: [UUID: String] = [:]
        for folder in store.settings.favoriteFolders where needsRefresh(folder.iconFile, kind: .folder, id: folder.id) {
            if let name = FavoriteIconProvider.refresh(folder: folder) { folderUpdates[folder.id] = name }
        }

        var appUpdates: [UUID: String] = [:]
        for app in store.settings.favoriteApps where needsRefresh(app.iconFile, kind: .application, id: app.id) {
            if let name = FavoriteIconProvider.refresh(app: app) { appUpdates[app.id] = name }
        }

        if !folderUpdates.isEmpty || !appUpdates.isEmpty {
            store.mutate { settings in
                for (id, name) in folderUpdates {
                    guard let index = settings.favoriteFolders.firstIndex(where: { $0.id == id }) else { continue }
                    settings.favoriteFolders[index].iconFile = name
                }
                for (id, name) in appUpdates {
                    guard let index = settings.favoriteApps.firstIndex(where: { $0.id == id }) else { continue }
                    settings.favoriteApps[index].iconFile = name
                }
            }
        }

        // Favicons are network round trips, so they run detached and every
        // failure is simply "this site has no icon".
        let websites = store.settings.favoriteWebsites
            .filter { needsRefresh($0.iconFile, kind: .website, id: $0.id) }
        guard !websites.isEmpty else { return }
        Task {
            var updates: [UUID: String] = [:]
            for website in websites {
                if let name = await FavoriteIconProvider.refresh(website: website) { updates[website.id] = name }
            }
            guard !updates.isEmpty else { return }
            store.mutate { settings in
                for (id, name) in updates {
                    guard let index = settings.favoriteWebsites.firstIndex(where: { $0.id == id }) else { continue }
                    settings.favoriteWebsites[index].iconFile = name
                }
            }
        }
    }

    /// An entry needs rendering when it has no file name yet, when the name is
    /// not the one this build would use, or when the file went missing.
    private static func needsRefresh(_ stored: String?, kind: FavoriteIconProvider.Kind, id: UUID) -> Bool {
        let expected = FavoriteIconProvider.fileName(for: id, kind: kind)
        return stored != expected || FavoriteIconProvider.image(named: expected) == nil
    }
}

/// The smallest favicon fetcher that gets a real icon for most sites.
///
/// `https://host/favicon.ico` is tried first because it is what the overwhelming
/// majority of sites still serve; when that is missing or is not an image, the
/// page's own `<link rel="…icon…" href="…">` is followed. Anything more (SVG
/// icons, `.ico` frame extraction, HTML heuristics) is deliberately out of scope:
/// a site we cannot resolve simply has no icon.
///
/// The main app is the only side allowed to do this — the Finder extension has
/// no `com.apple.security.network.client` entitlement.
enum FaviconLoader {
    /// Refuse anything larger: a "favicon" this size is a mis-served page, not
    /// an icon, and downloading it would only be wasted bandwidth.
    static let maximumBytes = 512 * 1024

    /// Best-effort favicon bytes for a page URL.
    static func fetch(from pageURL: URL) async -> Data? {
        if let data = await download(faviconURL(for: pageURL)), isImage(data) { return data }
        guard let page = await download(pageURL),
              let html = String(data: page, encoding: .utf8) ?? String(data: page, encoding: .isoLatin1),
              let declared = declaredIconURL(inHTML: html, pageURL: pageURL),
              let data = await download(declared),
              isImage(data)
        else { return nil }
        return data
    }

    /// The conventional location on the same host: `https://host/favicon.ico`.
    /// The scheme is kept, so an `http://` favorite is not silently upgraded.
    static func faviconURL(for pageURL: URL) -> URL? {
        guard var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// First `<link rel="…icon…" href="…">` in the document, resolved against
    /// the page. Pure, so the parsing rule is unit-tested without a network.
    static func declaredIconURL(inHTML html: String, pageURL: URL) -> URL? {
        for fragment in html.components(separatedBy: "<link").dropFirst() {
            let end = fragment.firstIndex(of: ">") ?? fragment.endIndex
            let tag = String(fragment[fragment.startIndex..<end])
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon") else { continue }
            guard let href = attribute("href", in: tag)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !href.isEmpty
            else { continue }
            if let url = URL(string: href, relativeTo: pageURL)?.absoluteURL {
                return url
            }
        }
        return nil
    }

    /// Value of `name` inside one tag's attribute text, quoted or bare.
    static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.lowercased().range(of: "\(name)=") else { return nil }
        let rest = tag[range.upperBound...].drop { $0 == " " }
        guard let first = rest.first else { return nil }
        if first == "\"" || first == "'" {
            let value = rest.dropFirst().prefix { $0 != first }
            return value.isEmpty ? nil : String(value)
        }
        let value = rest.prefix { !$0.isWhitespace && $0 != ">" }
        return value.isEmpty ? nil : String(value)
    }

    /// Recognises the image containers a favicon actually arrives in. SVG is
    /// not one of them: `NSImage` cannot decode it, so those sites fall back.
    static func isImage(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }   // PNG
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return true }         // JPEG
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }   // GIF8
        if head.starts(with: [0x42, 0x4D]) { return true }               // BMP
        if head.starts(with: [0x00, 0x00, 0x01, 0x00]) { return true }   // ICO
        if head.count >= 12, head[8..<12].elementsEqual([0x57, 0x45, 0x42, 0x50]) { return true }   // WEBP
        return false
    }

    /// One short-timeout request. Every failure is "no icon", never an error the
    /// user has to see: adding a favorite must not depend on the network.
    private static func download(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            guard data.count <= maximumBytes else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
