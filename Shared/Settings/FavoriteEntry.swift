import Foundation

/// Common shape of the three "favorites" lists (folders, apps, websites).
///
/// `identityKey` is the deduplication key: adding an entry whose key already
/// exists refreshes that row instead of appending a duplicate, which matches
/// how authorized folders behave.
protocol FavoriteEntry: Codable, Identifiable, Equatable {
    var id: UUID { get set }
    var displayName: String { get set }
    var isEnabled: Bool { get set }
    var identityKey: String { get }
}

// MARK: - Folder

struct FavoriteFolder: FavoriteEntry {
    var id: UUID
    var displayName: String
    var path: String
    var isEnabled: Bool

    init(id: UUID = UUID(), displayName: String, path: String, isEnabled: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, path, isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeOr(UUID.self, .id, UUID())
        displayName = try container.decodeOr(String.self, .displayName, "")
        path = try container.decodeOr(String.self, .path, "")
        isEnabled = try container.decodeOr(Bool.self, .isEnabled, true)
    }

    /// Standardized path, so "/Users/me/Docs/" and "/Users/me/Docs" dedupe.
    var identityKey: String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Name shown in the list; falls back to the last path component.
    var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - Application

struct FavoriteApp: FavoriteEntry {
    var id: UUID
    var displayName: String
    var path: String
    var bundleIdentifier: String?
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        displayName: String,
        path: String,
        bundleIdentifier: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, path, bundleIdentifier, isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeOr(UUID.self, .id, UUID())
        displayName = try container.decodeOr(String.self, .displayName, "")
        path = try container.decodeOr(String.self, .path, "")
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        isEnabled = try container.decodeOr(Bool.self, .isEnabled, true)
    }

    /// Bundle identifier when known, otherwise the standardized bundle path —
    /// the same app dragged in from two locations still dedupes.
    var identityKey: String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty { return "id:\(bundleIdentifier)" }
        return "path:\(URL(fileURLWithPath: path).standardizedFileURL.path)"
    }

    var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
}

// MARK: - Website

struct FavoriteWebsite: FavoriteEntry {
    var id: UUID
    var displayName: String
    var urlString: String
    var isEnabled: Bool

    init(id: UUID = UUID(), displayName: String, urlString: String, isEnabled: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.urlString = urlString
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, urlString, isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeOr(UUID.self, .id, UUID())
        displayName = try container.decodeOr(String.self, .displayName, "")
        urlString = try container.decodeOr(String.self, .urlString, "")
        isEnabled = try container.decodeOr(Bool.self, .isEnabled, true)
    }

    var identityKey: String { urlString.lowercased() }

    var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return URL(string: urlString)?.host ?? urlString
    }

    /// Accepts what a user actually types ("example.com") and returns a URL
    /// string with an explicit scheme, or nil when there is no usable host.
    /// Only http(s) is accepted: `open` on a `file:` or custom scheme from a
    /// menu entry is not something this feature should enable.
    static func normalizedURLString(from raw: String) -> String? {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !candidate.contains(" ") else { return nil }
        if !candidate.contains("://") {
            candidate = "https://\(candidate)"
        }
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              host.contains(".") || host == "localhost"
        else { return nil }
        return components.url?.absoluteString
    }
}

// MARK: - Collection editing

extension Array where Element: FavoriteEntry {
    /// Inserts the entry, or refreshes the existing row with the same
    /// `identityKey` while keeping its id and position. Returns true when a new
    /// row was appended.
    @discardableResult
    mutating func upsert(_ entry: Element) -> Bool {
        if let index = firstIndex(where: { $0.identityKey == entry.identityKey }) {
            var replacement = entry
            replacement.id = self[index].id
            self[index] = replacement
            return false
        }
        append(entry)
        return true
    }

    mutating func removeFavorite(id: UUID) {
        removeAll { $0.id == id }
    }

    mutating func setFavoriteEnabled(_ isEnabled: Bool, id: UUID) {
        guard let index = firstIndex(where: { $0.id == id }) else { return }
        self[index].isEnabled = isEnabled
    }

    /// Reorders rows using the offsets SwiftUI's `onMove` hands over. Both the
    /// array form and the single-row form are supported because the panes use
    /// `onMove` while tests exercise the same rule directly.
    mutating func moveFavorites(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty else { return }
        guard source.allSatisfy({ indices.contains($0) }) else { return }
        let moving = source.sorted().map { self[$0] }
        // Remove from the back so earlier removals do not shift later indices.
        for index in source.sorted(by: >) {
            remove(at: index)
        }
        // `destination` is expressed against the pre-removal array, so rows
        // removed before it shift the effective insertion point forward.
        let removedBeforeDestination = source.filter { $0 < destination }.count
        let insertionIndex = Swift.min(Swift.max(destination - removedBeforeDestination, 0), count)
        insert(contentsOf: moving, at: insertionIndex)
    }

    mutating func moveFavorite(from index: Int, by offset: Int) {
        let destination = index + offset
        guard indices.contains(index), destination >= 0, destination < count else { return }
        let entry = remove(at: index)
        insert(entry, at: destination)
    }
}
