import XCTest

/// 密码本: the Keychain-backed list of named passwords behind 加密压缩.
///
/// The interesting parts are the document format (import must survive files a
/// human edited), the same-name 自动保存 rule, and that the book *persists*
/// through storage — the Keychain itself is exercised last, and skipped when the
/// test host has no Keychain access rather than pretending it passed.
@MainActor
final class ArchivePasswordBookTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-pwbook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBook() -> (ArchivePasswordBook, InMemoryArchivePasswordBookStorage) {
        let storage = InMemoryArchivePasswordBookStorage()
        return (ArchivePasswordBook(storage: storage), storage)
    }

    // MARK: - Document

    func testTheDocumentRoundTripsAndAcceptsABareArray() throws {
        let entries = [
            ArchivePassword(name: "工作", password: "s3cret"),
            ArchivePassword(name: "备份", password: "hunter2"),
        ]
        let encoded = try ArchivePasswordBook.encode(entries)
        XCTAssertEqual(try ArchivePasswordBook.decode(encoded), entries)

        // A hand-written file may be a bare array: importing must not require the
        // envelope our own exporter happens to write.
        let bare = try JSONEncoder().encode(entries)
        XCTAssertEqual(try ArchivePasswordBook.decode(bare), entries)
        XCTAssertEqual(try ArchivePasswordBook.decode(nil), [])
        XCTAssertEqual(try ArchivePasswordBook.decode(Data()), [])
    }

    func testDecodingDropsRowsThatCouldNotBeUsed() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","name":"","password":"x"},
         {"id":"\(UUID().uuidString)","name":"ok","password":""},
         {"id":"\(UUID().uuidString)","name":"  ","password":"x"},
         {"id":"\(UUID().uuidString)","name":"kept","password":"p"}]
        """
        let decoded = try ArchivePasswordBook.decode(Data(json.utf8))
        XCTAssertEqual(decoded.map(\.name), ["kept"], "an unnamed row cannot be picked and an empty password cannot encrypt")
    }

    func testAnEmptyDocumentIsAnUnreadableImportRatherThanZeroRows() throws {
        // `[]` decodes fine but has nothing to add; callers treat that as a
        // failed import so the UI cannot say "已导入 0 条密码".
        let storage = InMemoryArchivePasswordBookStorage()
        let book = ArchivePasswordBook(storage: storage)
        let url = root.appendingPathComponent("empty.json")
        try Data("[]".utf8).write(to: url)
        XCTAssertThrowsError(try book.importEntries(from: url)) { error in
            XCTAssertEqual(error as? ArchivePasswordBookError, .unreadableDocument)
        }
    }

    // MARK: - Editing

    func testRememberReplacesTheRowWithTheSameNameInsteadOfGrowingTheBook() throws {
        let (book, _) = makeBook()
        book.remember(name: "工作", password: "first")
        book.remember(name: "工作", password: "second")
        XCTAssertEqual(book.entries.count, 1, "re-compressing the same archive must not add a row every time")
        XCTAssertEqual(book.entries.first?.password, "second")
        XCTAssertEqual(book.entries.first?.name, "工作")
    }

    func testRememberIgnoresEmptyNamesAndPasswords() throws {
        let (book, _) = makeBook()
        book.remember(name: "   ", password: "x")
        book.remember(name: "work", password: "")
        XCTAssertTrue(book.isEmpty)
    }

    func testAddUpdateRemoveAndRemoveAll() throws {
        let (book, _) = makeBook()
        book.add(name: "a", password: "1")
        book.add(name: "b", password: "2")
        let first = try XCTUnwrap(book.entries.first)

        book.update(id: first.id, name: "a2", password: "1b")
        XCTAssertEqual(book.entry(id: first.id)?.name, "a2")
        XCTAssertEqual(book.entry(id: first.id)?.password, "1b")

        let second = try XCTUnwrap(book.entries.last)
        book.remove(ids: [second.id])
        XCTAssertEqual(book.entries.map(\.name), ["a2"])

        book.removeAll()
        XCTAssertTrue(book.isEmpty)
    }

    func testTheBookSurvivesANewInstanceOverTheSameStorage() throws {
        let storage = InMemoryArchivePasswordBookStorage()
        let first = ArchivePasswordBook(storage: storage)
        first.add(name: "工作", password: "s3cret")

        let second = ArchivePasswordBook(storage: storage)
        XCTAssertEqual(second.entries.map(\.name), ["工作"])
        XCTAssertEqual(second.entries.map(\.password), ["s3cret"])
    }

    func testImportAddsToTheBookAndExportWritesTheDocumentBack() throws {
        let (book, _) = makeBook()
        book.add(name: "existing", password: "1")

        let incoming = try ArchivePasswordBook.encode([ArchivePassword(name: "工作", password: "s3cret")])
        let importURL = root.appendingPathComponent("in.json")
        try incoming.write(to: importURL)
        XCTAssertEqual(try book.importEntries(from: importURL), 1)
        XCTAssertEqual(book.entries.map(\.name), ["existing", "工作"])

        let exportURL = root.appendingPathComponent("out.json")
        try book.exportEntries(to: exportURL)
        XCTAssertEqual(try ArchivePasswordBook.decode(try Data(contentsOf: exportURL)), book.entries)
    }

    func testAnUnreadableDocumentThrowsInsteadOfEmptyingTheBook() throws {
        let (book, _) = makeBook()
        book.add(name: "keep", password: "1")
        let url = root.appendingPathComponent("garbage.json")
        try Data("not json at all".utf8).write(to: url)
        XCTAssertThrowsError(try book.importEntries(from: url))
        XCTAssertEqual(book.entries.map(\.name), ["keep"])
    }

    // MARK: - Storage

    func testAStorageFailureIsReportedAndKeepsTheListUsable() throws {
        final class RefusingStorage: ArchivePasswordBookStorage {
            func load() throws -> Data? { nil }
            func save(_ data: Data) throws { throw ArchivePasswordBookError.keychain(errSecNotAvailable) }
        }
        let book = ArchivePasswordBook(storage: RefusingStorage())
        book.add(name: "工作", password: "s3cret")
        XCTAssertEqual(book.entries.count, 1, "an in-memory row the user just typed must not vanish")
        XCTAssertNotNil(book.storageError)
        XCTAssertEqual(book.storageError?.contains("-25291"), true, "errSecNotAvailable is surfaced verbatim")
    }

    /// The real thing: one throwaway Keychain item, written, read back, deleted.
    ///
    /// Skipped when the host has no Keychain access (no UI session) — the test
    /// says so instead of passing on an empty read.
    func testTheKeychainStorageSavesLoadsAndDeletes() throws {
        let service = "xin.ljhsu.MenuRight.tests.\(UUID().uuidString)"
        let storage = KeychainArchivePasswordBookStorage(service: service)
        defer { try? storage.delete() }

        let payload = try ArchivePasswordBook.encode([ArchivePassword(name: "工作", password: "s3cret")])
        do {
            try storage.save(payload)
        } catch let error as ArchivePasswordBookError {
            throw XCTSkip("no Keychain access in this host: \(error)")
        }
        XCTAssertEqual(try storage.load(), payload)

        try storage.save(try ArchivePasswordBook.encode([]))
        XCTAssertEqual(try ArchivePasswordBook.decode(try storage.load()), [])

        try storage.delete()
        XCTAssertNil(try storage.load())
    }
}

/// The 自动保存 switch itself: off unless the user turns it on, and old settings
/// payloads (written before the field existed) must still decode.
@MainActor
final class ArchivePasswordSettingTests: XCTestCase {
    func testRememberingIsOffByDefault() {
        XCTAssertFalse(ArchiveSettings().remembersCompressionPassword)
    }

    func testOlderSettingsPayloadsDefaultToOff() throws {
        let json = """
        {"enabledFormats":["zip"],"destination":"askEachTime","conflictPolicy":"keepBoth",
         "deletesArchiveAfterExtraction":false,"skipsMetadataEntries":true,"sizeLimitMB":1024}
        """
        let settings = try JSONDecoder().decode(ArchiveSettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.remembersCompressionPassword)
    }

    func testTheFlagRoundTripsThroughJSON() throws {
        var settings = ArchiveSettings()
        settings.remembersCompressionPassword = true
        let data = try JSONEncoder().encode(settings)
        XCTAssertTrue(try JSONDecoder().decode(ArchiveSettings.self, from: data).remembersCompressionPassword)
    }

}
