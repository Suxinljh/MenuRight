import Foundation

/// A folder the user explicitly authorized, persisted as an app-scope
/// security-scoped bookmark. The bookmark data is the authoritative capability;
/// originalPath is informational/matching metadata only.
struct AuthorizedFolder: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var originalPath: String
    var bookmarkData: Data
    var createdAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        originalPath: String,
        bookmarkData: Data,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.originalPath = originalPath
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
    }

    /// Normalized path used for ancestor matching and deduplication.
    var normalizedPath: String {
        URL(fileURLWithPath: originalPath).standardizedFileURL.path
    }
}
