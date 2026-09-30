import SwiftUI

/// Folder permissions pane: the authorized folders the main app may write into,
/// with their live bookmark status.
struct FolderPermissionSettingsView: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        SettingsPane(
            title: store.text(.categoryFolderPermissions),
            subtitle: store.text(.folderPermissionIntro)
        ) {
            SettingsGroup(
                title: store.text(.folderPermissionAuthorized),
                footer: store.text(.folderPermissionFavoritesHint)
            ) {
                FolderAccessView()
            }
        }
    }
}
