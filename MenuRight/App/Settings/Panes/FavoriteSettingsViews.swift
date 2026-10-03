import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The three favorites panes (folders, apps, websites).
///
/// They share one row layout and one editing model, so they live together:
/// each pane is a `SettingsGroup` of rows plus an "add" action, and the
/// existence/validity check runs on demand (never during `body`), which keeps
/// menu-time I/O rules intact — the Finder side must not scan the disk.
struct FavoriteFoldersSettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var missingIDs: Set<UUID> = []
    @State private var icons: [UUID: NSImage] = [:]
    @State private var lastCheck: Date?

    private var folders: [FavoriteFolder] { store.settings.favoriteFolders }

    var body: some View {
        SettingsPane(
            title: store.text(.categoryFavoriteFolders),
            subtitle: store.text(.favoriteFoldersIntro)
        ) {
            SettingsGroup(
                title: store.text(.categoryFavoriteFolders),
                footer: FavoriteCheckStatus.footer(store: store, lastCheck: lastCheck)
            ) {
                if folders.isEmpty {
                    SettingsEmptyHint(text: store.text(.favoriteFoldersEmpty))
                } else {
                    ForEach(folders) { folder in
                        FavoriteRowView(
                            title: folder.resolvedDisplayName,
                            subtitle: folder.path,
                            systemImage: "folder",
                            icon: icons[folder.id],
                            isMissing: missingIDs.contains(folder.id),
                            missingText: store.text(.commonMissingOnDisk),
                            missingHelp: store.text(.favoriteFoldersMissing),
                            isEnabled: favoriteEnabledBinding(folder),
                            editHelp: store.text(.commonEdit),
                            revealHelp: store.text(.commonRevealInFinder),
                            removeHelp: store.text(.commonRemove),
                            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)]) },
                            moveUpHelp: store.text(.commonMoveUp),
                            moveDownHelp: store.text(.commonMoveDown),
                            canMoveUp: folder.id != folders.first?.id,
                            canMoveDown: folder.id != folders.last?.id,
                            onMoveUp: { move(folder.id, by: -1) },
                            onMoveDown: { move(folder.id, by: 1) },
                            onRemove: { remove(folder.id) }
                        )
                        if folder.id != folders.last?.id {
                            SettingsRowDivider()
                        }
                    }
                    .onMove { source, destination in
                        store.mutate { $0.favoriteFolders.moveFavorites(fromOffsets: source, toOffset: destination) }
                    }
                }
                SettingsRowDivider()
                checkBar
            }
        }
        .onAppear { check(); refreshIcons() }
    }

    private var checkBar: some View {
        HStack {
            Button(store.text(.favoriteFoldersAdd)) { addFolder() }
            Spacer()
            Button(store.text(.commonRefresh)) { check(); refreshIcons(force: true) }
                .buttonStyle(.link)
        }
    }

    private func favoriteEnabledBinding(_ folder: FavoriteFolder) -> Binding<Bool> {
        Binding(
            get: { store.settings.favoriteFolders.first { $0.id == folder.id }?.isEnabled ?? false },
            set: { isOn in store.mutate { $0.favoriteFolders.setFavoriteEnabled(isOn, id: folder.id) } }
        )
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = store.text(.commonAdd)
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }

        let selected = panel.urls
        store.mutate { settings in
            for url in selected {
                let folder = FavoriteFolder(displayName: url.lastPathComponent, path: url.path)
                settings.favoriteFolders.upsert(folder)
            }
        }
        check()
        refreshIcons()
    }

    private func remove(_ id: UUID) {
        let iconFile = folders.first { $0.id == id }?.iconFile
        store.mutate { $0.favoriteFolders.removeFavorite(id: id) }
        FavoriteIconProvider.delete(fileName: iconFile)
        icons[id] = nil
        check()
    }

    /// 上移/下移：走 SettingsStore 的写入口，再交给 `FavoriteEntry` 里那套已有
    /// 测试覆盖的 `moveFavorite(from:by:)`（越界时它是 no-op）。
    private func move(_ id: UUID, by offset: Int) {
        store.mutate { settings in
            guard let index = settings.favoriteFolders.firstIndex(where: { $0.id == id }) else { return }
            settings.favoriteFolders.moveFavorite(from: index, by: offset)
        }
    }

    /// Renders each row's real folder icon into the App Group so the Finder
    /// submenu can show the same picture, then loads it back for the list.
    ///
    /// Runs off the render path (and off the menu-build path): this is the only
    /// side that may touch `NSWorkspace`.
    private func refreshIcons(force: Bool = false) {
        var resolved: [UUID: NSImage] = [:]
        var updates: [UUID: String] = [:]
        for folder in folders {
            let expected = FavoriteIconProvider.fileName(for: folder.id, kind: .folder)
            var name = folder.iconFile
            let cached = FavoriteIconProvider.image(named: name)
            if force || name != expected || cached == nil {
                name = FavoriteIconProvider.refresh(folder: folder) ?? name
                if let name, name != folder.iconFile { updates[folder.id] = name }
            }
            if let name, let image = FavoriteIconProvider.image(named: name) { resolved[folder.id] = image }
        }
        if !updates.isEmpty {
            store.mutate { settings in
                for (id, name) in updates {
                    guard let index = settings.favoriteFolders.firstIndex(where: { $0.id == id }) else { continue }
                    settings.favoriteFolders[index].iconFile = name
                }
            }
        }
        icons = resolved
    }

    private func check() {
        var missing: Set<UUID> = []
        for folder in folders where !FileManager.default.fileExists(atPath: folder.path) {
            missing.insert(folder.id)
        }
        missingIDs = missing
        lastCheck = Date()
    }
}

struct FavoriteAppsSettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var missingIDs: Set<UUID> = []
    @State private var icons: [UUID: NSImage] = [:]
    @State private var lastCheck: Date?

    private var apps: [FavoriteApp] { store.settings.favoriteApps }

    var body: some View {
        SettingsPane(
            title: store.text(.categoryFavoriteApps),
            subtitle: store.text(.favoriteAppsIntro)
        ) {
            SettingsGroup(
                title: store.text(.categoryFavoriteApps),
                footer: FavoriteCheckStatus.footer(store: store, lastCheck: lastCheck)
            ) {
                if apps.isEmpty {
                    SettingsEmptyHint(text: store.text(.favoriteAppsEmpty))
                } else {
                    ForEach(apps) { app in
                        FavoriteRowView(
                            title: app.resolvedDisplayName,
                            subtitle: app.path,
                            systemImage: "app",
                            icon: icons[app.id],
                            isMissing: missingIDs.contains(app.id),
                            missingText: store.text(.commonMissingOnDisk),
                            missingHelp: store.text(.favoriteAppsMissing),
                            isEnabled: appEnabledBinding(app),
                            editHelp: store.text(.commonEdit),
                            revealHelp: store.text(.commonRevealInFinder),
                            removeHelp: store.text(.commonRemove),
                            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) },
                            moveUpHelp: store.text(.commonMoveUp),
                            moveDownHelp: store.text(.commonMoveDown),
                            canMoveUp: app.id != apps.first?.id,
                            canMoveDown: app.id != apps.last?.id,
                            onMoveUp: { move(app.id, by: -1) },
                            onMoveDown: { move(app.id, by: 1) },
                            onRemove: { remove(app.id) }
                        )
                        if app.id != apps.last?.id {
                            SettingsRowDivider()
                        }
                    }
                    .onMove { source, destination in
                        store.mutate { $0.favoriteApps.moveFavorites(fromOffsets: source, toOffset: destination) }
                    }
                }
                SettingsRowDivider()
                checkBar
            }
        }
        .onAppear { check(); refreshIcons() }
    }

    private var checkBar: some View {
        HStack {
            Button(store.text(.favoriteAppsAdd)) { addApps() }
            Spacer()
            Button(store.text(.commonRefresh)) { check(); refreshIcons(force: true) }
                .buttonStyle(.link)
        }
    }

    private func appEnabledBinding(_ app: FavoriteApp) -> Binding<Bool> {
        Binding(
            get: { store.settings.favoriteApps.first { $0.id == app.id }?.isEnabled ?? false },
            set: { isOn in store.mutate { $0.favoriteApps.setFavoriteEnabled(isOn, id: app.id) } }
        )
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = store.text(.commonAdd)
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }

        let selected = panel.urls
        store.mutate { settings in
            for url in selected {
                let bundle = Bundle(url: url)
                let name = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let app = FavoriteApp(
                    displayName: name,
                    path: url.path,
                    bundleIdentifier: bundle?.bundleIdentifier
                )
                settings.favoriteApps.upsert(app)
            }
        }
        check()
        refreshIcons()
    }

    private func remove(_ id: UUID) {
        let iconFile = apps.first { $0.id == id }?.iconFile
        store.mutate { $0.favoriteApps.removeFavorite(id: id) }
        FavoriteIconProvider.delete(fileName: iconFile)
        icons[id] = nil
        check()
    }

    /// 上移/下移，语义同收藏文件夹。
    private func move(_ id: UUID, by offset: Int) {
        store.mutate { settings in
            guard let index = settings.favoriteApps.firstIndex(where: { $0.id == id }) else { return }
            settings.favoriteApps.moveFavorite(from: index, by: offset)
        }
    }

    /// Existence and icons are resolved off the render path: menu building must
    /// stay I/O-free, and so must `body`.
    private func check() {
        var missing: Set<UUID> = []
        for app in apps where !FileManager.default.fileExists(atPath: app.path) {
            missing.insert(app.id)
        }
        missingIDs = missing
        lastCheck = Date()
    }

    /// Renders the real app icon into the App Group (so the Finder submenu can
    /// show it) and loads it back for the row.
    private func refreshIcons(force: Bool = false) {
        var resolved: [UUID: NSImage] = [:]
        var updates: [UUID: String] = [:]
        for app in apps {
            let expected = FavoriteIconProvider.fileName(for: app.id, kind: .application)
            var name = app.iconFile
            if force || name != expected || FavoriteIconProvider.image(named: name) == nil {
                name = FavoriteIconProvider.refresh(app: app) ?? name
                if let name, name != app.iconFile { updates[app.id] = name }
            }
            if let name, let image = FavoriteIconProvider.image(named: name) { resolved[app.id] = image }
        }
        if !updates.isEmpty {
            store.mutate { settings in
                for (id, name) in updates {
                    guard let index = settings.favoriteApps.firstIndex(where: { $0.id == id }) else { continue }
                    settings.favoriteApps[index].iconFile = name
                }
            }
        }
        icons = resolved
    }
}

struct FavoriteWebsitesSettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var invalidIDs: Set<UUID> = []
    @State private var icons: [UUID: NSImage] = [:]
    @State private var lastCheck: Date?
    @State private var editor: WebsiteEditorMode?

    private var websites: [FavoriteWebsite] { store.settings.favoriteWebsites }

    var body: some View {
        SettingsPane(
            title: store.text(.categoryFavoriteWebsites),
            subtitle: store.text(.favoriteWebsitesIntro)
        ) {
            SettingsGroup(
                title: store.text(.categoryFavoriteWebsites),
                footer: FavoriteCheckStatus.footer(store: store, lastCheck: lastCheck)
            ) {
                if websites.isEmpty {
                    SettingsEmptyHint(text: store.text(.favoriteWebsitesEmpty))
                } else {
                    ForEach(websites) { website in
                        FavoriteRowView(
                            title: website.resolvedDisplayName,
                            subtitle: website.urlString,
                            systemImage: "globe",
                            icon: icons[website.id],
                            isMissing: invalidIDs.contains(website.id),
                            missingText: store.text(.favoriteWebsitesInvalidURL),
                            missingHelp: store.text(.favoriteWebsitesInvalidURL),
                            isEnabled: websiteEnabledBinding(website),
                            editHelp: store.text(.commonEdit),
                            revealHelp: store.text(.commonRevealInFinder),
                            removeHelp: store.text(.commonRemove),
                            onEdit: { editor = .edit(website) },
                            onReveal: nil,
                            moveUpHelp: store.text(.commonMoveUp),
                            moveDownHelp: store.text(.commonMoveDown),
                            canMoveUp: website.id != websites.first?.id,
                            canMoveDown: website.id != websites.last?.id,
                            onMoveUp: { move(website.id, by: -1) },
                            onMoveDown: { move(website.id, by: 1) },
                            onRemove: { remove(website.id) }
                        )
                        if website.id != websites.last?.id {
                            SettingsRowDivider()
                        }
                    }
                    .onMove { source, destination in
                        store.mutate { $0.favoriteWebsites.moveFavorites(fromOffsets: source, toOffset: destination) }
                    }
                }
                SettingsRowDivider()
                HStack {
                    Button(store.text(.favoriteWebsitesAdd)) { editor = .add }
                    Spacer()
                    Button(store.text(.commonRefresh)) { check(); refreshIcons(force: true) }
                        .buttonStyle(.link)
                }
            }
        }
        .onAppear { check(); refreshIcons() }
        .sheet(item: $editor) { mode in
            WebsiteEditorSheet(mode: mode) { name, urlString in
                apply(name: name, urlString: urlString, mode: mode)
                editor = nil
            } onCancel: {
                editor = nil
            }
        }
    }

    private func websiteEnabledBinding(_ website: FavoriteWebsite) -> Binding<Bool> {
        Binding(
            get: { store.settings.favoriteWebsites.first { $0.id == website.id }?.isEnabled ?? false },
            set: { isOn in store.mutate { $0.favoriteWebsites.setFavoriteEnabled(isOn, id: website.id) } }
        )
    }

    private func apply(name: String, urlString: String, mode: WebsiteEditorMode) {
        store.mutate { settings in
            switch mode {
            case .add:
                settings.favoriteWebsites.upsert(
                    FavoriteWebsite(displayName: name, urlString: urlString)
                )
            case .edit(let existing):
                var updated = existing
                updated.displayName = name
                updated.urlString = urlString
                settings.favoriteWebsites.upsert(updated)
            }
        }
        check()
        refreshIcons()
    }

    private func remove(_ id: UUID) {
        let iconFile = websites.first { $0.id == id }?.iconFile
        store.mutate { $0.favoriteWebsites.removeFavorite(id: id) }
        FavoriteIconProvider.delete(fileName: iconFile)
        icons[id] = nil
        check()
    }

    /// 上移/下移，语义同收藏文件夹。
    private func move(_ id: UUID, by offset: Int) {
        store.mutate { settings in
            guard let index = settings.favoriteWebsites.firstIndex(where: { $0.id == id }) else { return }
            settings.favoriteWebsites.moveFavorite(from: index, by: offset)
        }
    }

    private func check() {
        var invalid: Set<UUID> = []
        for website in websites where FavoriteWebsite.normalizedURLString(from: website.urlString) == nil {
            invalid.insert(website.id)
        }
        invalidIDs = invalid
        lastCheck = Date()
    }

    /// Fetches each site's favicon — the only network access in the app — and
    /// stores it in the App Group for the Finder submenu to read.
    ///
    /// A site with no reachable favicon keeps no file and the menu shows the
    /// plain title, so a failed fetch never blocks adding a favorite.
    private func refreshIcons(force: Bool = false) {
        Task { @MainActor in
            var resolved: [UUID: NSImage] = [:]
            var updates: [UUID: String] = [:]
            for website in websites {
                let expected = FavoriteIconProvider.fileName(for: website.id, kind: .website)
                var name = website.iconFile
                if force || name != expected || FavoriteIconProvider.image(named: name) == nil {
                    name = await FavoriteIconProvider.refresh(website: website) ?? name
                    if let name, name != website.iconFile { updates[website.id] = name }
                }
                if let name, let image = FavoriteIconProvider.image(named: name) { resolved[website.id] = image }
            }
            if !updates.isEmpty {
                store.mutate { settings in
                    for (id, name) in updates {
                        guard let index = settings.favoriteWebsites.firstIndex(where: { $0.id == id }) else { continue }
                        settings.favoriteWebsites[index].iconFile = name
                    }
                }
            }
            icons = resolved
        }
    }
}

// MARK: - Shared favorites UI

/// One favorites row: icon (app icon when available), name, path/URL, an enable
/// switch, and reveal/edit/remove actions.
struct FavoriteRowView: View {
    let title: String
    let subtitle: String
    var systemImage: String?
    var icon: NSImage?
    let isMissing: Bool
    let missingText: String
    let missingHelp: String
    let isEnabled: Binding<Bool>
    let editHelp: String
    let revealHelp: String
    let removeHelp: String
    var onEdit: (() -> Void)?
    var onReveal: (() -> Void)?
    /// 排序。macOS 的设置卡片不是 `List`，`.onMove` 的拖动在卡片里不生效，所以每
    /// 行额外提供上移/下移；`.onMove` 也接在 ForEach 上，列表化后即可拖动排序。
    var moveUpHelp: String?
    var moveDownHelp: String?
    var canMoveUp = true
    var canMoveDown = true
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if isMissing {
                        SettingsBadge(text: missingText, color: .red)
                            .help(missingHelp)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if let onEdit {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help(editHelp)
            }
            if let onReveal {
                Button(action: onReveal) {
                    Image(systemName: "arrow.forward.circle")
                }
                .buttonStyle(.borderless)
                .help(revealHelp)
            }
            if let onMoveUp, let onMoveDown {
                VStack(spacing: -2) {
                    Button(action: onMoveUp) {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(!canMoveUp)
                    .help(moveUpHelp ?? "")
                    Button(action: onMoveDown) {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(!canMoveDown)
                    .help(moveDownHelp ?? "")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
            }
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(removeHelp)
            Toggle("", isOn: isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 18, height: 18)
        } else if let systemImage {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
    }
}

/// "Last checked" footer shared by the favorites panes.
enum FavoriteCheckStatus {
    static func footer(store: SettingsStore, lastCheck: Date?) -> String {
        guard let lastCheck else { return store.text(.commonNeverChecked) }
        let time = DateFormatter.localizedString(from: lastCheck, dateStyle: .none, timeStyle: .medium)
        return "\(store.text(.commonLastChecked)): \(time)"
    }
}

/// Add/edit sheet for a favorite website.
enum WebsiteEditorMode: Identifiable {
    case add
    case edit(FavoriteWebsite)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let website): return website.id.uuidString
        }
    }
}

private struct WebsiteEditorSheet: View {
    @EnvironmentObject private var store: SettingsStore
    let mode: WebsiteEditorMode
    let onSubmit: (String, String) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var urlString = ""
    @State private var showsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.text(.favoriteWebsitesSheetTitle))
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(store.text(.favoriteWebsitesName))
                        .gridColumnAlignment(.trailing)
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                GridRow {
                    Text(store.text(.favoriteWebsitesURL))
                        .gridColumnAlignment(.trailing)
                    TextField("", text: $urlString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
            }

            if showsError {
                Text(store.text(.favoriteWebsitesInvalidURL))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(store.text(.commonCancel), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(store.text(.commonConfirm)) {
                    guard let normalized = FavoriteWebsite.normalizedURLString(from: urlString) else {
                        showsError = true
                        return
                    }
                    let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? (URL(string: normalized)?.host ?? normalized)
                        : name
                    onSubmit(resolvedName, normalized)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if case .edit(let website) = mode {
                name = website.displayName
                urlString = website.urlString
            }
        }
    }
}
