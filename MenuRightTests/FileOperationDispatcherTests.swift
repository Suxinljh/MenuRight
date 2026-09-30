import XCTest
import Darwin

/// Regression net for the Main-App-side IPC dispatcher.
///
/// These are the first tests to cover the dispatcher at all (M4). They exercise
/// the real authorization + filesystem code paths against a temporary directory,
/// with only the security-scoped bookmark layer replaced by an injected
/// `ScopedAccessConfiguration` (the seam that already exists for exactly this).
final class FileOperationDispatcherTests: XCTestCase {
    private var root: URL!
    private var store: FolderAuthorizationStore!
    private var started: [String] = []
    private var stopped: [String] = []
    private var stale = false
    private var startOK = true

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-dispatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = FolderAuthorizationStore(fileURL: root.appendingPathComponent("FolderAuthorization.json"))
        started = []
        stopped = []
        stale = false
        startOK = true
    }

    override func tearDownWithError() throws {
        // Undo any permission tightening done by a test.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        // A locked (UF_IMMUTABLE) item cannot be deleted, so clear the flag
        // before removing the fixture tree.
        clearImmutableFlags(in: root)
        try? FileManager.default.removeItem(at: root)
    }

    private func clearImmutableFlags(in directory: URL) {
        let manager = FileManager.default
        try? manager.setAttributes([.immutable: false], ofItemAtPath: directory.path)
        guard let enumerator = manager.enumerator(atPath: directory.path) else { return }
        for case let entry as String in enumerator {
            try? manager.setAttributes([.immutable: false], ofItemAtPath: directory.appendingPathComponent(entry).path)
        }
    }

    // MARK: - Fixtures

    private func authorize(_ url: URL, bookmark: Data? = nil) throws {
        try store.add(AuthorizedFolder(
            displayName: url.lastPathComponent,
            originalPath: url.path,
            bookmarkData: bookmark ?? Data(url.path.utf8)
        ))
    }

    private func configuration() -> ScopedAccessConfiguration {
        ScopedAccessConfiguration(
            resolveBookmark: { data in
                let path = String(data: data, encoding: .utf8) ?? "/unknown"
                return (URL(fileURLWithPath: path), self.stale)
            },
            startAccess: { url in
                self.started.append(url.path)
                return self.startOK
            },
            stopAccess: { url in
                self.stopped.append(url.path)
            },
            makeFreshBookmark: { url in Data(("fresh:" + url.path).utf8) }
        )
    }

    /// Records the directories handed to "open terminal" instead of launching
    /// Terminal, so tests stay headless.
    private var openedDirectories: [String] = []

    private func dispatcher(
        store injectedStore: FolderAuthorizationStore? = nil,
        openTerminalError: Error? = nil
    ) -> FileOperationDispatcher {
        FileOperationDispatcher(
            store: injectedStore ?? store,
            scopedConfig: configuration(),
            opener: SystemOpener { url in
                self.openedDirectories.append(url.path)
                return openTerminalError
            }
        )
    }

    private func payload(
        _ kind: FileOperationContract.OperationKind,
        _ args: FileOperationContract.OperationArgs
    ) -> String {
        FileOperationContract.Request(kind: kind, args: args, clientRequestId: "test-cid").encodedForIPC()!
    }

    private func createFilePayload(directory: URL, name: String, contents: String? = nil) -> String {
        payload(.createFile, FileOperationContract.OperationArgs(
            directory: directory.path,
            name: name,
            contentsBase64: contents.map { Data($0.utf8).base64EncodedString() }
        ))
    }

    private func createDirectoryPayload(directory: URL, name: String) -> String {
        payload(.createDirectory, FileOperationContract.OperationArgs(directory: directory.path, name: name))
    }

    private func movePayload(sources: [URL], destination: URL) -> String {
        payload(.moveItems, FileOperationContract.OperationArgs(
            sourcePaths: sources.map(\.path),
            destinationDirectory: destination.path
        ))
    }

    private func failureCode(_ response: FileOperationContract.Response) -> FileOperationContract.ErrorCode? {
        if case .failure(let code, _) = response { return code }
        return nil
    }

    private func successPath(_ response: FileOperationContract.Response) -> String? {
        if case .success(let path) = response { return path }
        return nil
    }

    // MARK: - Request validation

    func testMalformedPayloadIsRejected() {
        XCTAssertEqual(failureCode(dispatcher().dispatch(payload: "not-json")), .invalidRequest)
        XCTAssertEqual(failureCode(dispatcher().dispatch(payload: nil)), .invalidRequest)
    }

    func testCanonicalizeRejectsEmptyAndResolvesDotDot() {
        let d = dispatcher()
        XCTAssertNil(d.canonicalize(""))
        XCTAssertEqual(d.canonicalize("/tmp/a/../b")?.path, "/tmp/b")
        XCTAssertEqual(d.canonicalize("/tmp//c/")?.pathComponents, ["/", "tmp", "c"])
        // `URL(fileURLWithPath:)` resolves a relative path against the process
        // working directory, so the result is always absolute — the guarantee
        // that matters is that no unstandardized `..` survives.
        XCTAssertTrue(d.canonicalize("relative/path.txt")?.path.hasPrefix("/") ?? false)
    }

    func testValidateNameRejectsEscapesAndEmpty() {
        XCTAssertNil(FileOperationDispatcher.validateName("Untitled.txt"))
        XCTAssertNil(FileOperationDispatcher.validateName("New Folder"))
        XCTAssertNil(FileOperationDispatcher.validateName(".hidden"))
        XCTAssertNotNil(FileOperationDispatcher.validateName(""))
        XCTAssertNotNil(FileOperationDispatcher.validateName("."))
        XCTAssertNotNil(FileOperationDispatcher.validateName(".."))
        XCTAssertNotNil(FileOperationDispatcher.validateName("../escape.txt"))
        XCTAssertNotNil(FileOperationDispatcher.validateName("sub/x.txt"))
        XCTAssertNotNil(FileOperationDispatcher.validateName("a:b.txt"))
        XCTAssertNotNil(FileOperationDispatcher.validateName(String(repeating: "a", count: 256)))
    }

    // MARK: - Authorization gate (M1)

    func testCreateFileOutsideAuthorizationIsRejected() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try authorize(authorized)

        let response = dispatcher().dispatch(payload: createFilePayload(directory: other, name: "x.txt"))
        XCTAssertEqual(failureCode(response), .notAuthorized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("x.txt").path))
        XCTAssertTrue(started.isEmpty, "no scoped access may be started for an unauthorized path")
    }

    func testMissingDirectoryOrNameIsInvalidRequest() {
        XCTAssertEqual(failureCode(dispatcher().dispatch(payload: payload(.createFile, .init()))), .invalidRequest)
        XCTAssertEqual(
            failureCode(dispatcher().dispatch(payload: createFilePayload(directory: root, name: ""))),
            .invalidRequest
        )
    }

    // MARK: - name validation reaches the filesystem boundary (M1)

    func testNameWithParentTraversalIsRejectedAndNothingIsWritten() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)

        let response = dispatcher().dispatch(payload: createFilePayload(directory: authorized, name: "../escaped.txt"))
        XCTAssertEqual(failureCode(response), .invalidRequest)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path),
            "a traversal name must never create a file outside the authorized directory"
        )
        XCTAssertTrue(started.isEmpty, "rejected before any scoped access")
    }

    func testNameWithSlashIsRejected() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)

        let response = dispatcher().dispatch(payload: createFilePayload(directory: authorized, name: "sub/x.txt"))
        XCTAssertEqual(failureCode(response), .invalidRequest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: authorized.appendingPathComponent("sub").path))
    }

    func testNameWithDotDotAsDirectoryCreationIsRejected() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)

        let response = dispatcher().dispatch(payload: createDirectoryPayload(directory: authorized, name: ".."))
        XCTAssertEqual(failureCode(response), .invalidRequest)
    }

    // MARK: - Successful single-target operations

    func testCreateFileSucceedsWithContentsAndBalancesScopedAccess() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)

        let response = dispatcher().dispatch(payload: createFilePayload(directory: authorized, name: "Untitled.txt", contents: "hello"))
        let path = try XCTUnwrap(successPath(response))
        XCTAssertEqual(path, authorized.appendingPathComponent("Untitled.txt").path)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "hello")
        XCTAssertEqual(started, stopped, "scoped access must be balanced")
    }

    func testCreateFileCollisionGetsAUniqueName() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)

        let d = dispatcher()
        XCTAssertNotNil(successPath(d.dispatch(payload: createFilePayload(directory: authorized, name: "Untitled.txt"))))
        let second = d.dispatch(payload: createFilePayload(directory: authorized, name: "Untitled.txt"))
        XCTAssertEqual(successPath(second), authorized.appendingPathComponent("Untitled 2.txt").path)
    }

    func testCreateDirectorySucceeds() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)

        let response = dispatcher().dispatch(payload: createDirectoryPayload(directory: authorized, name: "New Folder"))
        let path = try XCTUnwrap(successPath(response))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testCreateInsideANonDirectoryIsInvalidDestination() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        try Data("file".utf8).write(to: authorized.appendingPathComponent("plain.txt"))

        let response = dispatcher().dispatch(payload: createFilePayload(
            directory: authorized.appendingPathComponent("plain.txt"),
            name: "x.txt"
        ))
        XCTAssertEqual(failureCode(response), .invalidDestination)
    }

    // MARK: - Multi-target move

    func testMoveItemsOutsideAuthorizedScopeIsRejected() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try authorize(authorized)
        let source = authorized.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: source)

        let response = dispatcher().dispatch(payload: movePayload(sources: [source], destination: other))
        XCTAssertEqual(failureCode(response), .pathOutsideAuthorizedScope)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMoveItemsSucceedsAndReportsPerItemResults() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let destination = root.appendingPathComponent("Authorized/Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try authorize(authorized)
        let source = authorized.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: source)

        let response = dispatcher().dispatch(payload: movePayload(sources: [source], destination: destination))
        guard case .batchSuccess(let items) = response else {
            return XCTFail("expected batchSuccess, got \(response)")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].success)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(started.sorted(), stopped.sorted(), "every started scope must be stopped")
    }

    func testMoveItemsCollisionIsReportedAsNameCollisionWithoutOverwriting() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let destination = root.appendingPathComponent("Authorized/Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try authorize(authorized)
        let source = authorized.appendingPathComponent("a.txt")
        try Data("source".utf8).write(to: source)
        try Data("destination".utf8).write(to: destination.appendingPathComponent("a.txt"))

        let response = dispatcher().dispatch(payload: movePayload(sources: [source], destination: destination))
        guard case .batchSuccess(let items) = response else {
            return XCTFail("expected batchSuccess, got \(response)")
        }
        XCTAssertFalse(items[0].success)
        XCTAssertEqual(items[0].errorCode, .nameCollision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the source must not be moved")
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8),
            "destination",
            "an existing file must never be overwritten"
        )
    }

    func testMoveItemsMissingSourceReportsPerItemFailure() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let destination = root.appendingPathComponent("Authorized/Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try authorize(authorized)
        let missing = authorized.appendingPathComponent("gone.txt")

        let response = dispatcher().dispatch(payload: movePayload(sources: [missing], destination: destination))
        guard case .batchSuccess(let items) = response else {
            return XCTFail("expected batchSuccess, got \(response)")
        }
        XCTAssertFalse(items[0].success)
        XCTAssertEqual(items[0].errorCode, .sourceDoesNotExist)
    }

    // MARK: - H3: stale bookmark transparency

    func testStaleBookmarkIsRefreshedPersistedAndTheOperationProceeds() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        let originalBookmark = Data(authorized.path.utf8)
        try authorize(authorized, bookmark: originalBookmark)
        stale = true

        let response = dispatcher().dispatch(payload: createFilePayload(directory: authorized, name: "renewed.txt"))
        XCTAssertNotNil(successPath(response), "H3: a stale bookmark must be renewed transparently, not rejected")
        XCTAssertTrue(FileManager.default.fileExists(atPath: authorized.appendingPathComponent("renewed.txt").path))

        // The refreshed bookmark data must have been written back to the store.
        let reloaded = try XCTUnwrap(store.loadFolders().first)
        XCTAssertEqual(String(data: reloaded.bookmarkData, encoding: .utf8), "fresh:\(authorized.path)")
        XCTAssertEqual(started.count, stopped.count, "scoped access must be balanced after a refresh")
    }

    func testStaleBookmarkInMultiTargetMoveIsAlsoRefreshed() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let destination = root.appendingPathComponent("Authorized/Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try authorize(authorized)
        let source = authorized.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: source)
        stale = true

        let response = dispatcher().dispatch(payload: movePayload(sources: [source], destination: destination))
        guard case .batchSuccess(let items) = response else {
            return XCTFail("expected batchSuccess, got \(response)")
        }
        XCTAssertTrue(items[0].success, "M3: the multi-target path must use the same stale policy as the single-target path")
        let reloaded = try XCTUnwrap(store.loadFolders().first)
        XCTAssertEqual(String(data: reloaded.bookmarkData, encoding: .utf8), "fresh:\(authorized.path)")
    }

    func testStartAccessFailureIsReportedAsAccessStartFailed() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        startOK = false

        let response = dispatcher().dispatch(payload: createFilePayload(directory: authorized, name: "x.txt"))
        XCTAssertEqual(failureCode(response), .accessStartFailed)
    }

    func testStaleBookmarkWhoseRefreshCannotBePersistedIsReported() throws {
        try XCTSkipIf(geteuid() == 0, "permission tightening does not block root")

        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let storeDir = root.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let readOnlyStore = FolderAuthorizationStore(fileURL: storeDir.appendingPathComponent("FolderAuthorization.json"))
        try readOnlyStore.add(AuthorizedFolder(
            displayName: "Authorized",
            originalPath: authorized.path,
            bookmarkData: Data(authorized.path.utf8)
        ))
        stale = true
        // The store can still read, but every write now fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: storeDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeDir.path) }

        let response = dispatcher(store: readOnlyStore)
            .dispatch(payload: createFilePayload(directory: authorized, name: "x.txt"))
        XCTAssertEqual(failureCode(response), .staleBookmarkNeedsReauthorization)
        XCTAssertFalse(FileManager.default.fileExists(atPath: authorized.appendingPathComponent("x.txt").path))
    }

    // MARK: - Error-code mapping table

    func testMapErrorCoversEveryFileOperationError() {
        XCTAssertEqual(FileOperationDispatcher.mapError(.destinationExists(URL(fileURLWithPath: "/a"))), .nameCollision)
        XCTAssertEqual(FileOperationDispatcher.mapError(.invalidMove("x")), .operationFailed)
        XCTAssertEqual(FileOperationDispatcher.mapError(.invalidDestination("/a")), .invalidDestination)
        XCTAssertEqual(FileOperationDispatcher.mapError(.sourceDoesNotExist(URL(fileURLWithPath: "/a"))), .sourceDoesNotExist)
        XCTAssertEqual(
            FileOperationDispatcher.mapError(.fileSystem(domain: NSPOSIXErrorDomain, code: Int(EPERM), description: "denied", underlyingPOSIXCode: EPERM)),
            .filesystemPermissionDenied
        )
        XCTAssertEqual(
            FileOperationDispatcher.mapError(.fileSystem(domain: NSPOSIXErrorDomain, code: Int(EIO), description: "io", underlyingPOSIXCode: EIO)),
            .filesystemError
        )
        XCTAssertEqual(
            FileOperationDispatcher.mapError(.fileSystem(domain: NSCocoaErrorDomain, code: 513, description: "denied", underlyingPOSIXCode: nil)),
            .filesystemError
        )
        XCTAssertEqual(FileOperationDispatcher.mapError(.unknown("x")), .operationFailed)
    }

    func testMapAuthErrorCoversEveryAuthorizationError() {
        let url = URL(fileURLWithPath: "/a")
        XCTAssertEqual(FileOperationDispatcher.mapAuthError(.authorizationRequired(url)), .notAuthorized)
        XCTAssertEqual(FileOperationDispatcher.mapAuthError(.bookmarkResolveFailed(url)), .bookmarkResolveFailed)
        XCTAssertEqual(FileOperationDispatcher.mapAuthError(.staleBookmarkNeedsReauthorization(url)), .staleBookmarkNeedsReauthorization)
        XCTAssertEqual(FileOperationDispatcher.mapAuthError(.accessStartFailed(url)), .accessStartFailed)
    }

    // MARK: - P6: create alias

    func testCreateAliasCreatesANamedAliasNextToTheSource() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let source = authorized.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: source)

        let response = dispatcher().dispatch(payload: payload(.createAlias, .init(sourcePaths: [source.path])))
        guard case .batchSuccess(let items) = response else {
            return XCTFail("expected batchSuccess, got \(response)")
        }
        XCTAssertEqual(items.count, 1)
        let aliasPath = try XCTUnwrap(items[0].destinationPath)
        XCTAssertTrue(items[0].success, "alias creation failed: \(items[0].message ?? "")")
        XCTAssertEqual(aliasPath, authorized.appendingPathComponent("notes.txt alias").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: aliasPath))
        XCTAssertFalse(FileOperationService.isLocked(URL(fileURLWithPath: aliasPath)), "a fresh alias must not be locked")
        // The alias is a bookmark file, so Finder can resolve it.
        XCTAssertNoThrow(try URL(resolvingAliasFileAt: URL(fileURLWithPath: aliasPath)))
    }

    func testCreateAliasNameCollisionGetsAUniqueName() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let source = authorized.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: source)

        let d = dispatcher()
        _ = d.dispatch(payload: payload(.createAlias, .init(sourcePaths: [source.path])))
        let second = d.dispatch(payload: payload(.createAlias, .init(sourcePaths: [source.path])))
        guard case .batchSuccess(let items) = second else {
            return XCTFail("expected batchSuccess, got \(second)")
        }
        XCTAssertEqual(items[0].destinationPath, authorized.appendingPathComponent("a.txt alias 2").path)
    }

    func testCreateAliasOutsideAuthorizedScopeIsRejected() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try authorize(authorized)
        let source = other.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: source)

        let response = dispatcher().dispatch(payload: payload(.createAlias, .init(sourcePaths: [source.path])))
        XCTAssertEqual(failureCode(response), .pathOutsideAuthorizedScope)
        XCTAssertTrue(started.isEmpty, "no scoped access for an unauthorized location")
    }

    func testCreateAliasOfAMissingSourceReportsAliasFailed() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)

        let response = dispatcher().dispatch(payload: payload(
            .createAlias,
            .init(sourcePaths: [authorized.appendingPathComponent("gone.txt").path])
        ))
        guard case .batchSuccess(let items) = response else {
            return XCTFail("expected batchSuccess, got \(response)")
        }
        XCTAssertFalse(items[0].success)
        XCTAssertEqual(items[0].errorCode, .aliasFailed)
    }

    func testCreateAliasWithoutSourcesIsInvalidRequest() {
        XCTAssertEqual(
            failureCode(dispatcher().dispatch(payload: payload(.createAlias, .init()))),
            .invalidRequest
        )
    }

    // MARK: - P6: lock / unlock

    func testSetLockedAndUnlockRoundTrip() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let item = authorized.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: item)
        XCTAssertFalse(FileOperationService.isLocked(item))

        let locked = dispatcher().dispatch(payload: payload(.setLocked, .init(sourcePaths: [item.path], locked: true)))
        guard case .batchSuccess(let lockedItems) = locked else {
            return XCTFail("expected batchSuccess, got \(locked)")
        }
        XCTAssertTrue(lockedItems[0].success, "lock failed: \(lockedItems[0].message ?? "")")
        XCTAssertTrue(FileOperationService.isLocked(item), "the immutable flag must be set")

        let unlocked = dispatcher().dispatch(payload: payload(.setLocked, .init(sourcePaths: [item.path], locked: false)))
        guard case .batchSuccess(let unlockedItems) = unlocked else {
            return XCTFail("expected batchSuccess, got \(unlocked)")
        }
        XCTAssertTrue(unlockedItems[0].success, "unlock failed: \(unlockedItems[0].message ?? "")")
        XCTAssertFalse(FileOperationService.isLocked(item))
    }

    func testSetLockedHandlesMultipleItemsIndependently() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let a = authorized.appendingPathComponent("a.txt")
        let b = authorized.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)

        let response = dispatcher().dispatch(payload: payload(
            .setLocked,
            .init(sourcePaths: [a.path, b.path, authorized.appendingPathComponent("missing.txt").path], locked: true)
        ))
        guard case .batchSuccess(let items) = response else {
            return XCTFail("expected batchSuccess, got \(response)")
        }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.filter { $0.success }.count, 2)
        XCTAssertEqual(items.last?.errorCode, .lockFailed)
        XCTAssertTrue(FileOperationService.isLocked(a))
        XCTAssertTrue(FileOperationService.isLocked(b))
    }

    func testSetLockedOutsideAuthorizedScopeIsRejected() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try authorize(authorized)
        let outside = other.appendingPathComponent("x.txt")
        try Data("x".utf8).write(to: outside)

        let response = dispatcher().dispatch(payload: payload(.setLocked, .init(sourcePaths: [outside.path], locked: true)))
        XCTAssertEqual(failureCode(response), .pathOutsideAuthorizedScope)
        XCTAssertFalse(FileOperationService.isLocked(outside))
    }

    func testSetLockedWithoutTheFlagIsInvalidRequest() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let item = authorized.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: item)

        XCTAssertEqual(
            failureCode(dispatcher().dispatch(payload: payload(.setLocked, .init(sourcePaths: [item.path])))),
            .invalidRequest
        )
    }

    // MARK: - P6: open terminal

    func testOpenTerminalHandsTheDirectoryToTheSystemOpener() throws {
        let directory = root.appendingPathComponent("AnyFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let response = dispatcher().dispatch(payload: payload(.openTerminal, .init(directory: directory.path)))
        XCTAssertNil(failureCode(response))
        XCTAssertEqual(openedDirectories, [directory.path])
    }

    func testOpenTerminalIsDeliberatelyNotGatedOnAuthorization() throws {
        // Documented decision: the app performs no filesystem work here, it only
        // hands the path to LaunchServices, so no bookmark is required. Without
        // this, "Open Terminal" would fail in every un-authorized folder.
        let directory = root.appendingPathComponent("NotAuthorized", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(store.loadFolders().isEmpty, "fixture must have no authorizations")

        let response = dispatcher().dispatch(payload: payload(.openTerminal, .init(directory: directory.path)))
        XCTAssertNil(failureCode(response))
        XCTAssertEqual(openedDirectories, [directory.path])
    }

    func testOpenTerminalRejectsANonDirectory() throws {
        let file = root.appendingPathComponent("plain.txt")
        try Data("x".utf8).write(to: file)

        let response = dispatcher().dispatch(payload: payload(.openTerminal, .init(directory: file.path)))
        XCTAssertEqual(failureCode(response), .invalidDestination)
        XCTAssertTrue(openedDirectories.isEmpty)
    }

    func testOpenTerminalPropagatesOpenerFailure() throws {
        let directory = root.appendingPathComponent("AnyFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let error = NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "no terminal"])

        let response = dispatcher(openTerminalError: error)
            .dispatch(payload: payload(.openTerminal, .init(directory: directory.path)))
        XCTAssertEqual(failureCode(response), .openFailed)
    }

    func testOpenTerminalRequiresADirectory() {
        XCTAssertEqual(
            failureCode(dispatcher().dispatch(payload: payload(.openTerminal, .init()))),
            .invalidRequest
        )
    }

    // MARK: - P6 helpers

    func testAliasNameConvention() {
        XCTAssertEqual(FileOperationService.aliasName(for: URL(fileURLWithPath: "/a/notes.txt")), "notes.txt alias")
        XCTAssertEqual(FileOperationService.aliasName(for: URL(fileURLWithPath: "/a/Photos")), "Photos alias")
    }

    func testIsLockedIsFalseForAMissingPath() {
        XCTAssertFalse(FileOperationService.isLocked(root.appendingPathComponent("nope.txt")))
    }
}
