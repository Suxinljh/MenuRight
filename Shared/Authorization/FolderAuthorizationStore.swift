import Foundation

/// Versioned on-disk payload (JSON file inside the App Group container).
/// Only folder-authorization data lives here in A2.5.
struct FolderAuthorizationPayload: Codable, Equatable {
    static let currentVersion = 1
    var version: Int
    var folders: [AuthorizedFolder]
}

/// App-Group-backed persistence for authorized folders.
///
/// Storage is a single small JSON file at
/// <App Group container>/FolderAuthorization.json, written atomically.
/// Corrupt or unknown-version payloads load as an empty list rather than
/// crashing or migrating.
final class FolderAuthorizationStore {
    /// Single source of truth for the App Group identifier (shared with the IPC
    /// layer, which places the socket in the same container).
    static let appGroupIdentifier = MenuRightIPC.appGroupIdentifier
    static let fileName = "FolderAuthorization.json"

    private let fileURL: URL

    /// Serializes read-modify-write cycles. The dispatcher runs on a concurrent
    /// connection queue, so two concurrent `update`/`add` calls would otherwise
    /// drop one another's changes. Cross-process atomicity is provided by the
    /// atomic write plus the architecture rule that the Main App is the only
    /// writer (the extension no longer resolves or writes bookmarks).
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default location shared by the app and its Finder Sync extension.
    static func appGroupDefault() -> FolderAuthorizationStore? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        return FolderAuthorizationStore(fileURL: container.appendingPathComponent(fileName))
    }

    func loadFolders() -> [AuthorizedFolder] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    /// Adds a folder, replacing an existing row with the same normalized path
    /// (reauthorization) instead of creating a duplicate. The original row id
    /// is kept; bookmark data and metadata are refreshed.
    func add(_ folder: AuthorizedFolder) throws {
        lock.lock()
        defer { lock.unlock() }
        var folders = loadUnlocked()
        let normalized = folder.normalizedPath
        if let index = folders.firstIndex(where: { $0.normalizedPath == normalized }) {
            let existing = folders[index]
            folders[index] = AuthorizedFolder(
                id: existing.id,
                displayName: folder.displayName,
                originalPath: folder.originalPath,
                bookmarkData: folder.bookmarkData
            )
        } else {
            folders.append(folder)
        }
        try save(folders)
    }

    func remove(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        var folders = loadUnlocked()
        folders.removeAll { $0.id == id }
        try save(folders)
    }

    func update(_ folder: AuthorizedFolder) throws {
        lock.lock()
        defer { lock.unlock() }
        var folders = loadUnlocked()
        if let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index] = folder
        }
        try save(folders)
    }

    private func loadUnlocked() -> [AuthorizedFolder] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let payload = try? JSONDecoder().decode(FolderAuthorizationPayload.self, from: data) else {
            return []
        }
        guard payload.version == FolderAuthorizationPayload.currentVersion else { return [] }
        return payload.folders
    }

    private func save(_ folders: [AuthorizedFolder]) throws {
        let payload = FolderAuthorizationPayload(
            version: FolderAuthorizationPayload.currentVersion,
            folders: folders
        )
        let data = try JSONEncoder().encode(payload)
        try data.write(to: fileURL, options: [.atomic])
    }
}
