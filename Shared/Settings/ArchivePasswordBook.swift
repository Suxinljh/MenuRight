import Foundation
import Security

/// One named password of the 密码本 (password book).
///
/// The name is what the user sees in the picker; the password is what gets fed
/// to the archive writer. Two entries may share a name — the list is a list,
/// not a dictionary — because people reuse labels like "工作".
struct ArchivePassword: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var password: String

    init(id: UUID = UUID(), name: String, password: String) {
        self.id = id
        self.name = name
        self.password = password
    }
}

enum ArchivePasswordBookError: Error, Equatable {
    /// The Keychain refused (missing entitlement, locked keychain, …).
    case keychain(OSStatus)
    /// 批量导入 read something that is not a password document.
    case unreadableDocument

    var status: OSStatus? {
        if case .keychain(let status) = self { return status }
        return nil
    }
}

/// Where the book is kept. The app uses the Keychain; tests inject memory.
protocol ArchivePasswordBookStorage: AnyObject {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// Keychain-backed storage: one generic-password item whose data is the encoded book.
///
/// Deliberately **not** the settings file. `MenuRightSettings` is plaintext JSON
/// in the App Group container, readable by the Finder extension and by anything
/// that can read the container; a password must not live there. The extension
/// never sees the book at all — encryption happens in the main app, and the
/// extension only ever asks for a dialog.
final class KeychainArchivePasswordBookStorage: ArchivePasswordBookStorage {
    static let defaultService = "xin.ljhsu.MenuRight.password-book"

    private let service: String
    private let account: String

    init(service: String = KeychainArchivePasswordBookStorage.defaultService, account: String = "compression") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ArchivePasswordBookError.keychain(status)
        }
        return data
    }

    func save(_ data: Data) throws {
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ArchivePasswordBookError.keychain(status) }
        var insert = query
        insert[kSecValueData as String] = data
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw ArchivePasswordBookError.keychain(added) }
    }

    /// Removes the item. Used by tests and by "清空密码本".
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ArchivePasswordBookError.keychain(status)
        }
    }
}

/// Storage that keeps the bytes in memory: unit tests, and a store that must not
/// touch the user's real keychain.
final class InMemoryArchivePasswordBookStorage: ArchivePasswordBookStorage {
    private(set) var data: Data?

    init(data: Data? = nil) {
        self.data = data
    }

    func load() throws -> Data? { data }

    func save(_ data: Data) throws { self.data = data }
}

/// The 密码本: an ordered list of named passwords, persisted as one JSON blob.
///
/// Import/export use a small versioned document (`{"version": 1, "passwords":
/// […]}`); import also accepts a bare array and drops entries without a name or
/// a password, so hand-edited files do not silently import empty rows.
@MainActor
final class ArchivePasswordBook: ObservableObject {
    static let shared = ArchivePasswordBook()

    @Published private(set) var entries: [ArchivePassword] = []
    /// Set when the last write to the Keychain failed; the UI shows it and the
    /// in-memory list stays usable.
    @Published private(set) var storageError: String?

    private let storage: ArchivePasswordBookStorage

    init(storage: ArchivePasswordBookStorage = KeychainArchivePasswordBookStorage()) {
        self.storage = storage
        do {
            entries = try Self.decode(storage.load())
        } catch {
            entries = []
            storageError = String(describing: error)
        }
    }

    var isEmpty: Bool { entries.isEmpty }

    func entry(id: UUID) -> ArchivePassword? {
        entries.first { $0.id == id }
    }

    /// 自动保存压缩时输入的加密密码: reuse the row with the same name when there
    /// is one, so repeatedly compressing "备份.zip" does not grow the book.
    func remember(name: String, password: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else { return }
        if let index = entries.firstIndex(where: { $0.name == trimmed }) {
            entries[index].password = password
        } else {
            entries.append(ArchivePassword(name: trimmed, password: password))
        }
        persist()
    }

    func add(name: String, password: String) {
        entries.append(ArchivePassword(name: name, password: password))
        persist()
    }

    func update(id: UUID, name: String, password: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].name = name
        entries[index].password = password
        persist()
    }

    func remove(ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        persist()
    }

    func removeAll() {
        entries = []
        persist()
    }

    /// 批量导入. Returns how many entries were added.
    @discardableResult
    func importEntries(from url: URL) throws -> Int {
        let imported = try Self.decode(try Data(contentsOf: url))
        guard !imported.isEmpty else { throw ArchivePasswordBookError.unreadableDocument }
        entries.append(contentsOf: imported)
        persist()
        return imported.count
    }

    /// 批量导出.
    func exportEntries(to url: URL) throws {
        try Self.encode(entries).write(to: url, options: .atomic)
    }

    func replaceAll(_ newEntries: [ArchivePassword]) {
        entries = newEntries
        persist()
    }

    // MARK: - Document

    private struct Document: Codable {
        var version: Int
        var passwords: [ArchivePassword]
    }

    static func encode(_ entries: [ArchivePassword]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Document(version: 1, passwords: entries))
    }

    /// Reads both the versioned document and a bare array, and refuses rows that
    /// could not be used (empty name implies an unnamed picker row; empty
    /// password is a no-op for the writer).
    static func decode(_ data: Data?) throws -> [ArchivePassword] {
        guard let data, !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        let decoded: [ArchivePassword]
        if let document = try? decoder.decode(Document.self, from: data) {
            decoded = document.passwords
        } else {
            decoded = try decoder.decode([ArchivePassword].self, from: data)
        }
        return decoded.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.password.isEmpty
        }
    }

    private func persist() {
        do {
            try storage.save(Self.encode(entries))
            storageError = nil
        } catch {
            storageError = String(describing: error)
        }
    }
}
