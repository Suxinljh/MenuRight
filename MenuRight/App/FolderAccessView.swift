import SwiftUI
import AppKit
import os

/// Folder Access content (Phase A2.5, now hosted by the Folder Permissions
/// pane).
///
/// Authorized folders are turned into app-scope security-scoped bookmarks
/// created from the NSOpenPanel user selection, then persisted in the shared
/// App Group store so the Finder Sync extension can resolve them.
///
/// The view renders plain rows (not a `List`) because the settings pane already
/// scrolls; nesting scroll views would fight the pane's own scrolling.
struct FolderAccessView: View {
    /// Low-frequency diagnostics for the authorization entry point.
    private static let diag = Logger(subsystem: "xin.ljhsu.MenuRight", category: "main-app")

    @EnvironmentObject private var settings: SettingsStore
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
        VStack(alignment: .leading, spacing: 0) {
            if store == nil {
                Text(settings.text(.folderPermissionStorageUnavailable))
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if folders.isEmpty {
                SettingsEmptyHint(text: settings.text(.folderPermissionEmpty))
            } else {
                ForEach(folders) { folder in
                    row(for: folder)
                    if folder.id != folders.last?.id {
                        SettingsRowDivider()
                    }
                }
            }

            SettingsRowDivider()

            HStack {
                Button(settings.text(.folderPermissionAdd)) {
                    addFolder()
                }
                .disabled(store == nil)
                Spacer()
            }
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reload()
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for folder: AuthorizedFolder) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.blue)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.displayName)
                Text(folder.originalPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            statusBadge(for: folder)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.originalPath)])
            } label: {
                Image(systemName: "arrow.forward.circle")
            }
            .buttonStyle(.borderless)
            .help(settings.text(.commonRevealInFinder))
            Button {
                remove(folder)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(settings.text(.commonRemove))
        }
    }

    @ViewBuilder
    private func statusBadge(for folder: AuthorizedFolder) -> some View {
        // Read-only: the badge renders the value computed by `reload()`.
        switch statuses[folder.id] ?? .needsReauthorization {
        case .authorized:
            SettingsBadge(text: settings.text(.folderPermissionStatusAuthorized), color: .green)
        case .needsReauthorization:
            SettingsBadge(text: settings.text(.folderPermissionStatusNeedsReauth), color: .orange)
        case .unavailable:
            SettingsBadge(text: settings.text(.folderPermissionStatusUnavailable), color: .red)
        }
    }

    // MARK: - Actions

    private func addFolder() {
        guard let store else {
            Self.diag.log("APP addFolder: store is nil, aborting")
            return
        }
        // Same code path as the first-run guide, so both create identical
        // authorizations.
        let outcome = FolderAuthorizationAction.present(
            store: store,
            prompt: settings.text(.folderPermissionAdd),
            log: { Self.diag.log("\($0, privacy: .public)") }
        )
        switch outcome {
        case .cancelled:
            break
        case .added(let folder):
            Self.diag.log("APP addFolder: stored \(folder.originalPath, privacy: .public)")
            reload()
        case .failed(let message):
            SettingsAlert.present(
                title: settings.text(.errorAlertTitle),
                message: message,
                buttonTitle: settings.text(.commonConfirm)
            )
        }
    }

    private func remove(_ folder: AuthorizedFolder) {
        guard let store else { return }
        let confirmed = SettingsAlert.confirm(
            title: settings.text(.folderPermissionRemoveTitle),
            message: settings.text(.folderPermissionRemoveMessage),
            confirmTitle: settings.text(.commonRemove),
            cancelTitle: settings.text(.commonCancel)
        )
        guard confirmed else { return }
        do {
            try store.remove(id: folder.id)
            reload()
        } catch {
            SettingsAlert.present(
                title: settings.text(.errorAlertTitle),
                message: (error as NSError).localizedDescription,
                buttonTitle: settings.text(.commonConfirm)
            )
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

}
