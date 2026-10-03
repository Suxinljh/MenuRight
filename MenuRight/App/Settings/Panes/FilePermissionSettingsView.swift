import SwiftUI

/// File permissions: which Finder-menu actions MenuRight is allowed to offer,
/// plus the safety switches that govern them.
///
/// This pane is a filter over capabilities, not a permission grant: the sandbox
/// decides what is actually possible. It deliberately does not carry a paragraph
/// explaining that architecture — prose like that is not a setting.
struct FilePermissionSettingsView: View {
    @EnvironmentObject private var store: SettingsStore

    private let createActions: [FileAction] = [.createFile, .createFolder, .createAlias, .cutPaste]
    private let copyActions: [FileAction] = [.copyName, .copyPath, .copyFileURL]
    private let otherActions: [FileAction] = [.lockUnlock, .openTerminal, .extractArchive, .compressArchive, .openFavorite]

    var body: some View {
        SettingsPane(
            title: store.text(.categoryFilePermissions),
            subtitle: store.text(.filePermissionIntro)
        ) {
            allowedActionsCard(store.text(.filePermissionGroupCreate), createActions)
            allowedActionsCard(store.text(.filePermissionGroupCopy), copyActions)
            allowedActionsCard(
                store.text(.filePermissionGroupOther),
                otherActions,
                footer: store.enabledCountText(
                    store.settings.filePermissions.allowedActions.count,
                    FileAction.allCases.count
                )
            )
            safetyGroup
        }
    }

    /// One card per group. The groups used to be three captions stacked inside a
    /// single card, which made 允许的操作 look like one long list with headings
    /// jammed between the rows; separate cards give each group its own title and
    /// its own visual boundary.
    private func allowedActionsCard(_ title: String, _ actions: [FileAction], footer: String? = nil) -> some View {
        SettingsGroup(title: title, footer: footer) {
            ForEach(actions, id: \.self) { action in
                SettingsToggleRow(
                    title: store.text(action.titleKey),
                    iconAsset: action.iconAsset,
                    isOn: store.containsBinding(\.filePermissions.allowedActions, action)
                )
                if action != actions.last {
                    SettingsRowDivider()
                }
            }
        }
    }

    private var safetyGroup: some View {
        SettingsGroup(title: store.text(.filePermissionSafety)) {
            SettingsToggleRow(
                title: store.text(.filePermissionRestrict),
                subtitle: store.text(.filePermissionRestrictFooter),
                isOn: store.binding(\.filePermissions.restrictToAuthorizedFolders)
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title: store.text(.filePermissionConfirm),
                isOn: store.binding(\.filePermissions.confirmDestructiveActions)
            )
        }
    }
}