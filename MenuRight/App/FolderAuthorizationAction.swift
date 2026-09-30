import AppKit

/// Presents the folder picker and stores the chosen folder as an app-scope
/// security-scoped bookmark.
///
/// Shared by the 文件夹权限 pane and the first-run guide: the guide has to create
/// exactly the same kind of authorization, not a second, subtly different one.
/// The caller owns presentation of errors and reloading, because the two call
/// sites report differently (an alert vs. inline text in the sheet).
@MainActor
enum FolderAuthorizationAction {
    enum Outcome {
        case cancelled
        case added(AuthorizedFolder)
        case failed(String)
    }

    /// Runs the modal panel and, on a successful selection, adds the bookmark.
    ///
    /// - Parameter log: diagnostics sink; the pane feeds its `Logger`, the guide
    ///   stays silent.
    static func present(
        store: FolderAuthorizationStore,
        prompt: String,
        log: (String) -> Void = { _ in }
    ) -> Outcome {
        log("APP authorization: presenting NSOpenPanel")

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = prompt
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        // Ensure the modal panel actually comes to front.
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)

        let response = panel.runModal()
        log("APP authorization: runModal returned \(response.rawValue)")
        guard response == .OK, let url = panel.url else {
            log("APP authorization: no selection (cancelled or empty)")
            return .cancelled
        }
        log("APP authorization: selected \(url.path), creating bookmark")

        do {
            let bookmarkData = try SecurityScopedBookmark.create(for: url)
            let folder = AuthorizedFolder(
                displayName: displayName(for: url),
                originalPath: url.path,
                bookmarkData: bookmarkData
            )
            try store.add(folder)
            return .added(folder)
        } catch {
            return .failed((error as NSError).localizedDescription)
        }
    }

    /// `Home` reads better than the account's short name in the folder list.
    static func displayName(for url: URL) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if url.standardizedFileURL.path == homePath {
            return "Home"
        }
        return url.lastPathComponent
    }
}
