import SwiftUI
import AppKit
import os

/// Folder Access settings section (Phase A2.5).
///
/// Authorized folders are turned into app-scope security-scoped bookmarks
/// created from the NSOpenPanel user selection, then persisted in the shared
/// App Group store so the Finder Sync extension can resolve them.
struct FolderAccessView: View {
    /// Low-frequency diagnostics for the authorization entry point.
    private static let diag = Logger(subsystem: "xin.ljhsu.MenuRight", category: "main-app")

    @State private var folders: [AuthorizedFolder] = []
    @State private var store: FolderAuthorizationStore? = FolderAuthorizationStore.appGroupDefault()
    /// Cached authorization status per folder id.
    ///
    /// `AuthorizedURLResolver.status(for:)` resolves a bookmark and starts/stops
    /// scoped access, so it must never run inside `body` (it would repeat on
    /// every render, scroll, or window activation). It is computed on explicit
    /// reloads instead.
    @State private var statuses: [UUID: AuthorizationStatus] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Folder Access")
                .font(.headline)
            Text("Authorize folders where Menu Right can create, move, and modify files.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            if store == nil {
                Text("Authorized-folder storage is unavailable (App Group not configured).")
                    .foregroundColor(.orange)
            }
            List {
                ForEach(folders) { folder in
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.displayName)
                            Text(folder.originalPath)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        statusBadge(for: folder)
                        Button("Remove") {
                            remove(folder)
                        }
                    }
                }
            }
            .frame(minHeight: 150)
            Button("Add Folder…") {
                addFolder()
            }
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reload()
        }
    }

    // MARK: - Actions

    private func addFolder() {
        guard let store else {
            Self.diag.log("APP addFolder: store is nil, aborting")
            return
        }
        Self.diag.log("APP addFolder: store ok, presenting NSOpenPanel")

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Authorize"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        // Ensure the modal panel actually comes to front.
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)

        let response = panel.runModal()
        Self.diag.log("APP addFolder: runModal returned \(response.rawValue, privacy: .public)")
        guard response == .OK, let url = panel.url else {
            Self.diag.log("APP addFolder: no selection (cancelled or empty), url=\(String(describing: panel.url?.path), privacy: .public)")
            return
        }
        Self.diag.log("APP addFolder: selected \(url.path, privacy: .public), creating bookmark")

        do {
            let bookmarkData = try SecurityScopedBookmark.create(for: url)
            let displayName = displayName(for: url)
            let folder = AuthorizedFolder(
                displayName: displayName,
                originalPath: url.path,
                bookmarkData: bookmarkData
            )
            try store.add(folder)
            reload()
        } catch {
            let message = (error as NSError).localizedDescription
            presentAlert(title: "Couldn’t authorize folder", message: message)
        }
    }

    private func remove(_ folder: AuthorizedFolder) {
        guard let store else { return }
        do {
            try store.remove(id: folder.id)
            reload()
        } catch {
            presentAlert(title: "Couldn’t remove folder", message: (error as NSError).localizedDescription)
        }
    }

    // MARK: - State

    private func reload() {
        let loaded = store?.loadFolders() ?? []
        folders = loaded
        var resolved: [UUID: AuthorizationStatus] = [:]
        resolved.reserveCapacity(loaded.count)
        for folder in loaded {
            resolved[folder.id] = AuthorizedURLResolver.status(for: folder)
        }
        statuses = resolved
    }

    private func displayName(for url: URL) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if url.standardizedFileURL.path == homePath {
            return "Home"
        }
        return url.lastPathComponent
    }

    @ViewBuilder
    private func statusBadge(for folder: AuthorizedFolder) -> some View {
        // Read-only: the badge renders the value computed by `reload()`.
        switch statuses[folder.id] ?? .needsReauthorization {
        case .authorized:
            Text("Authorized").foregroundColor(.green)
        case .needsReauthorization:
            Text("Needs Reauthorization").foregroundColor(.orange)
        case .unavailable:
            Text("Unavailable").foregroundColor(.red)
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
