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
        // The `customize` path can build the real dialog, which renders the 密码本.
        // That book lives in the keychain, and a test process reading it can block
        // forever on an authorization prompt nobody answers (2026-10-03), so hand
        // the dialog an in-memory book.
        CustomCompressionDialogWindow.shared.passwordBookProvider = {
            MainActor.assumeIsolated { ArchivePasswordBook(storage: InMemoryArchivePasswordBookStorage()) }
        }
    }

    override func tearDownWithError() throws {
        // The `customize` path parks its request on the process-wide center, and
        // with no presenter injected that center builds the real dialog window —
        // neither may leak into the next test.
        ArchiveRequestCenter.shared.presenter = nil
        ArchiveRequestCenter.shared.dismiss()
        CustomCompressionDialogWindow.shared.passwordBookProvider = {
            MainActor.assumeIsolated { ArchivePasswordBook.shared }
        }
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
    /// P7-b: what the favorites path handed to LaunchServices.
    private var openedFolders: [String] = []
    private var openedURLs: [String] = []
    private var openedApplications: [String] = []

    private func dispatcher(
        store injectedStore: FolderAuthorizationStore? = nil,
        openTerminalError: Error? = nil,
        openFolderError: Error? = nil,
        openURLError: Error? = nil,
        openApplicationError: Error? = nil,
        templateDirectory: URL? = nil,
        archiveSettings: ArchiveSettings = ArchiveSettings(),
        folderChooser: (() -> URL?)? = nil,
        passwordPrompting: (any ArchivePasswordPrompting)? = nil,
        filePermissions: FilePermissionSettings = FilePermissionSettings(),
        generalSettings: GeneralSettings = GeneralSettings(),
        newFileSettings: NewFileSettings = NewFileSettings(),
        destructiveConfirmation: (any DestructiveActionConfirming)? = nil
    ) -> FileOperationDispatcher {
        FileOperationDispatcher(
            store: injectedStore ?? store,
            scopedConfig: configuration(),
            opener: SystemOpener(
                openTerminal: { url in
                    self.openedDirectories.append(url.path)
                    return openTerminalError
                },
                openFolder: { url in
                    self.openedFolders.append(url.path)
                    return openFolderError
                },
                openURL: { url in
                    self.openedURLs.append(url.absoluteString)
                    return openURLError
                },
                openApplication: { target in
                    self.openedApplications.append(target)
                    return openApplicationError
                }
            ),
            templateDirectory: templateDirectory,
            archiveSettings: { archiveSettings },
            filePermissions: { filePermissions },
            generalSettings: { generalSettings },
            newFileSettings: { newFileSettings },
            folderChooser: folderChooser ?? { nil },
            archivePasswordPrompting: passwordPrompting,
            destructiveConfirmation: destructiveConfirmation
        )
    }

    /// Records what it was asked and answers with a fixed verdict.
    final class StubConfirmer: DestructiveActionConfirming, @unchecked Sendable {
        let answer: Bool
        private let lock = NSLock()
        private var seen: [DestructiveAction] = []

        init(answer: Bool) { self.answer = answer }

        var actions: [DestructiveAction] {
            lock.lock(); defer { lock.unlock() }
            return seen
        }

        func confirm(_ action: DestructiveAction) -> Bool {
            lock.lock(); defer { lock.unlock() }
            seen.append(action)
            return answer
        }
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

    /// P6-b: `createDocument` / `createFromTemplate` carry a kind instead of
    /// bytes — the main app decides what those bytes are.
    private func documentPayload(
        _ kind: FileOperationContract.OperationKind,
        directory: URL,
        name: String,
        kind documentKind: String
    ) -> String {
        payload(kind, FileOperationContract.OperationArgs(
            directory: directory.path,
            name: name,
            documentKind: documentKind
        ))
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

    /// Open operations succeed with no created path, so success has to be
    /// checked by shape rather than by `successPath`.
    private func isSuccess(_ response: FileOperationContract.Response) -> Bool {
        if case .success = response { return true }
        return false
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

    // MARK: - P6-b: generated documents

    func testCreateDocumentWritesAnOpenablePackageIntoTheAuthorizedFolder() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)

        let response = dispatcher().dispatch(payload: documentPayload(
            .createDocument, directory: authorized, name: "Untitled.docx", kind: "docx"
        ))
        let path = try XCTUnwrap(successPath(response))
        XCTAssertEqual(path, authorized.appendingPathComponent("Untitled.docx").path)

        let archive = try ZipTestReader(try Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(archive.entries.first?.name, "[Content_Types].xml")
        XCTAssertNotNil(archive.entry(named: "word/document.xml"))
        XCTAssertEqual(started, stopped, "scoped access must be balanced")
    }

    func testCreateDocumentOnlyAcceptsOfficeKinds() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let d = dispatcher()

        XCTAssertEqual(
            failureCode(d.dispatch(payload: documentPayload(.createDocument, directory: authorized, name: "a.pages", kind: "pages"))),
            .unsupportedDocumentKind,
            "template kinds must not travel as generated documents"
        )
        XCTAssertEqual(
            failureCode(d.dispatch(payload: documentPayload(.createDocument, directory: authorized, name: "a.docx", kind: "exe"))),
            .invalidRequest
        )
        XCTAssertEqual(
            failureCode(d.dispatch(payload: payload(.createDocument, .init(directory: authorized.path, name: "a.docx")))),
            .invalidRequest,
            "the kind is required"
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: authorized.path).isEmpty)
    }

    func testCreateDocumentOutsideAuthorizationIsRejected() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try authorize(authorized)

        let response = dispatcher().dispatch(payload: documentPayload(
            .createDocument, directory: other, name: "Untitled.xlsx", kind: "xlsx"
        ))
        XCTAssertEqual(failureCode(response), .notAuthorized)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
        XCTAssertTrue(started.isEmpty)
    }

    func testCreateDocumentCollisionGetsAUniqueName() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let d = dispatcher()

        XCTAssertNotNil(successPath(d.dispatch(payload: documentPayload(
            .createDocument, directory: authorized, name: "Deck.pptx", kind: "pptx"
        ))))
        let second = d.dispatch(payload: documentPayload(
            .createDocument, directory: authorized, name: "Deck.pptx", kind: "pptx"
        ))
        XCTAssertEqual(successPath(second), authorized.appendingPathComponent("Deck 2.pptx").path)
    }

    // MARK: - P6-b: template-backed documents

    func testCreateFromTemplateCopiesTheBlankPackage() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)

        // An iWork document is normally a package directory; the copy must
        // preserve that rather than flatten it.
        let templates = root.appendingPathComponent("Templates", isDirectory: true)
        let blankKey = templates.appendingPathComponent("blank.key", isDirectory: true)
        try FileManager.default.createDirectory(at: blankKey, withIntermediateDirectories: true)
        try Data("index".utf8).write(to: blankKey.appendingPathComponent("Index.zip"))

        let response = dispatcher(templateDirectory: templates).dispatch(payload: documentPayload(
            .createFromTemplate, directory: authorized, name: "Untitled.key", kind: "keynote"
        ))
        let path = try XCTUnwrap(successPath(response))
        XCTAssertEqual(path, authorized.appendingPathComponent("Untitled.key").path)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "the template package shape must survive the copy")
        XCTAssertEqual(
            try String(contentsOfFile: path + "/Index.zip", encoding: .utf8),
            "index"
        )
        XCTAssertEqual(started, stopped, "scoped access must be balanced")
    }

    func testCreateFromTemplateWithoutATemplateReportsTemplateMissing() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)

        let response = dispatcher(templateDirectory: root.appendingPathComponent("Empty", isDirectory: true))
            .dispatch(payload: documentPayload(
                .createFromTemplate, directory: authorized, name: "Untitled.pages", kind: "pages"
            ))
        XCTAssertEqual(failureCode(response), .templateMissing)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: authorized.path).isEmpty)
    }

    func testCreateFromTemplateOnlyAcceptsTemplateBackedKinds() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)

        XCTAssertEqual(
            failureCode(dispatcher().dispatch(payload: documentPayload(
                .createFromTemplate, directory: authorized, name: "a.docx", kind: "docx"
            ))),
            .unsupportedDocumentKind
        )
    }

    func testCreateFromTemplateRejectsATraversalNameBeforeTouchingTheDisk() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)

        let templates = root.appendingPathComponent("Templates", isDirectory: true)
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        try Data("blank".utf8).write(to: templates.appendingPathComponent("blank.numbers"))

        let response = dispatcher(templateDirectory: templates).dispatch(payload: documentPayload(
            .createFromTemplate, directory: authorized, name: "../escaped.numbers", kind: "numbers"
        ))
        XCTAssertEqual(failureCode(response), .invalidRequest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.numbers").path))
        XCTAssertTrue(started.isEmpty, "rejected before any scoped access")
    }

    // MARK: - P7-b: favorites

    /// Opening is a read-only hand-off to Finder/LaunchServices, exactly like
    /// `openTerminal`: it must work in folders the user never authorized, and it
    /// must not start security-scoped access for them either.
    func testOpenFolderIsNotGatedOnTheAuthorizationStore() throws {
        let folder = root.appendingPathComponent("NeverAuthorized", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let response = dispatcher().dispatch(payload: payload(.openFolder, .init(directory: folder.path)))
        XCTAssertTrue(isSuccess(response))
        XCTAssertEqual(openedFolders, [folder.path])
        XCTAssertTrue(started.isEmpty, "opening a folder must not start security-scoped access")
    }

    func testOpenFolderRejectsAMissingFolder() throws {
        let missing = root.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(
            failureCode(dispatcher().dispatch(payload: payload(.openFolder, .init(directory: missing.path)))),
            .invalidDestination
        )
        XCTAssertEqual(
            failureCode(dispatcher().dispatch(payload: payload(.openFolder, .init()))),
            .invalidRequest
        )
        XCTAssertTrue(openedFolders.isEmpty)
    }

    func testOpenFolderRejectsAFileEvenThoughThePathExists() throws {
        let file = root.appendingPathComponent("plain.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(
            failureCode(dispatcher().dispatch(payload: payload(.openFolder, .init(directory: file.path)))),
            .invalidDestination
        )
    }

    func testOpenApplicationPassesPathAndBundleIdentifierTargets() {
        let d = dispatcher()
        XCTAssertTrue(isSuccess(d.dispatch(payload: payload(.openApplication, .init(target: "/Applications/Calculator.app")))))
        XCTAssertTrue(isSuccess(d.dispatch(payload: payload(.openApplication, .init(target: "com.apple.TextEdit")))))
        XCTAssertEqual(openedApplications, ["/Applications/Calculator.app", "com.apple.TextEdit"])
    }

    func testOpenApplicationRejectsRelativePathsAndEmptyTargets() {
        let d = dispatcher()
        for target in ["./evil.app", "../evil.app", "some/relative.app"] {
            XCTAssertEqual(
                failureCode(d.dispatch(payload: payload(.openApplication, .init(target: target)))),
                .invalidRequest,
                "“\(target)” must not reach LaunchServices"
            )
        }
        XCTAssertEqual(failureCode(d.dispatch(payload: payload(.openApplication, .init()))), .invalidRequest)
        XCTAssertTrue(openedApplications.isEmpty)
    }

    func testOpenURLOnlyAcceptsHTTPWithAHost() {
        let d = dispatcher()
        for target in ["file:///etc/passwd", "javascript:alert(1)", "ftp://example.com", "https://", "", "not a url", "https://a b.com"] {
            XCTAssertEqual(
                failureCode(d.dispatch(payload: payload(.openURL, .init(target: target)))),
                .invalidRequest,
                "“\(target)” must be rejected"
            )
        }
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testOpenURLHandsTheValidatedURLToTheOpener() {
        XCTAssertTrue(isSuccess(dispatcher().dispatch(payload: payload(.openURL, .init(target: "https://example.com/a?b=1")))))
        XCTAssertEqual(openedURLs, ["https://example.com/a?b=1"])
    }

    func testOpenerFailuresAreReportedAsOpenFailed() throws {
        let folder = root.appendingPathComponent("Existing", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "refused"])

        XCTAssertEqual(
            failureCode(dispatcher(openFolderError: error).dispatch(payload: payload(.openFolder, .init(directory: folder.path)))),
            .openFailed
        )
        XCTAssertEqual(
            failureCode(dispatcher(openURLError: error).dispatch(payload: payload(.openURL, .init(target: "https://example.com")))),
            .openFailed
        )
        XCTAssertEqual(
            failureCode(dispatcher(openApplicationError: error).dispatch(payload: payload(.openApplication, .init(target: "com.apple.TextEdit")))),
            .openFailed
        )
    }

    // MARK: - P9: compression and extraction

    private func compressPayload(sources: [URL], destination: URL, format: String? = "zip", name: String? = nil) -> String {
        payload(.compressItems, FileOperationContract.OperationArgs(
            name: name,
            sourcePaths: sources.map(\.path),
            destinationDirectory: destination.path,
            archiveFormat: format
        ))
    }

    private func extractPayload(archives: [URL], destination: URL? = nil) -> String {
        payload(.extractArchive, FileOperationContract.OperationArgs(
            sourcePaths: archives.map(\.path),
            destinationDirectory: destination?.path
        ))
    }

    func testCompressItemsCreatesAnArchiveNextToTheSelection() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let first = authorized.appendingPathComponent("a.txt")
        let second = authorized.appendingPathComponent("b.txt")
        try Data("A".utf8).write(to: first)
        try Data("B".utf8).write(to: second)

        let response = dispatcher().dispatch(payload: compressPayload(sources: [first, second], destination: authorized))
        let path = try XCTUnwrap(successPath(response))

        let reader = try ZipReader(fileURL: URL(fileURLWithPath: path))
        XCTAssertEqual(reader.entries.map(\.name), ["a.txt", "b.txt"])
        XCTAssertEqual(started, stopped, "scoped access must be balanced")
    }

    func testCompressItemsHonoursAnExplicitName() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let file = authorized.appendingPathComponent("a.txt")
        try Data("A".utf8).write(to: file)

        let response = dispatcher().dispatch(payload: compressPayload(
            sources: [file], destination: authorized, name: "Bundle.zip"
        ))
        XCTAssertEqual(successPath(response), authorized.appendingPathComponent("Bundle.zip").path)
    }

    func testCompressItemsRejectsFormatsItCannotWrite() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let file = authorized.appendingPathComponent("a.txt")
        try Data("A".utf8).write(to: file)

        for format in ["7z", "xz", "rar", "nonsense"] {
            XCTAssertEqual(
                failureCode(dispatcher().dispatch(payload: compressPayload(
                    sources: [file], destination: authorized, format: format
                ))),
                .archiveUnsupported,
                "\(format) must be refused explicitly"
            )
        }
    }

    /// Stage 2: every writable format really produces its file.
    func testCompressItemsWritesEveryWritableFormat() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let file = authorized.appendingPathComponent("a.txt")
        try Data("A".utf8).write(to: file)

        let expected = ["zip": "a.txt.zip", "tar": "a.txt.tar", "gzip": "a.txt.tar.gz", "bzip2": "a.txt.tar.bz2"]
        for (format, name) in expected {
            let response = dispatcher().dispatch(payload: compressPayload(
                sources: [file], destination: authorized, format: format, name: name
            ))
            XCTAssertEqual(successPath(response), authorized.appendingPathComponent(name).path, "\(format)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: authorized.appendingPathComponent(name).path))
        }
    }

    /// P9 stage 3: the dialog's 标签 and 压缩模式 travel over the wire.
    func testCompressItemsCarriesTheLabelAndMode() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let file = authorized.appendingPathComponent("a.txt")
        try Data(String(repeating: "x", count: 100_000).utf8).write(to: file)

        let payload = self.payload(.compressItems, FileOperationContract.OperationArgs(
            name: "labelled.zip",
            sourcePaths: [file.path],
            destinationDirectory: authorized.path,
            archiveFormat: "zip",
            archiveLabel: "发布包",
            archiveMode: "maximum"
        ))
        let path = try XCTUnwrap(successPath(dispatcher().dispatch(payload: payload)))
        XCTAssertEqual(try ZipReader(fileURL: URL(fileURLWithPath: path)).comment, "发布包")
    }

    func testCompressItemsOutsideAuthorizationIsRejected() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try authorize(authorized)
        let file = other.appendingPathComponent("a.txt")
        try Data("A".utf8).write(to: file)

        XCTAssertEqual(
            failureCode(dispatcher().dispatch(payload: compressPayload(sources: [file], destination: other))),
            .pathOutsideAuthorizedScope
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty == false)
    }

    func testCompressItemsFollowsTheConfiguredConflictPolicy() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let file = authorized.appendingPathComponent("a.txt")
        try Data("A".utf8).write(to: file)

        let keepBoth = dispatcher(archiveSettings: ArchiveSettings(conflictPolicy: .keepBoth))
        XCTAssertEqual(
            successPath(keepBoth.dispatch(payload: compressPayload(sources: [file], destination: authorized, name: "x.zip"))),
            authorized.appendingPathComponent("x.zip").path
        )
        XCTAssertEqual(
            successPath(keepBoth.dispatch(payload: compressPayload(sources: [file], destination: authorized, name: "x.zip"))),
            authorized.appendingPathComponent("x 2.zip").path
        )
        XCTAssertEqual(
            failureCode(dispatcher(archiveSettings: ArchiveSettings(conflictPolicy: .skip))
                .dispatch(payload: compressPayload(sources: [file], destination: authorized, name: "x.zip"))),
            .nameCollision
        )
    }

    /// 允许的压缩格式 filters the 压缩 ▸ menu; this is the app-side re-check that
    /// catches a menu built before the setting changed.
    func testCompressItemsRefusesAFormatTheSettingsTurnedOff() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let file = authorized.appendingPathComponent("a.txt")
        try Data("A".utf8).write(to: file)

        var settings = ArchiveSettings()
        settings.enabledFormats = [.zip]
        let scoped = dispatcher(archiveSettings: settings)

        XCTAssertEqual(
            failureCode(scoped.dispatch(payload: compressPayload(
                sources: [file], destination: authorized, format: "tar", name: "a.tar"
            ))),
            .archiveUnsupported
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: authorized.appendingPathComponent("a.tar").path),
            "a refused format must not leave an archive behind"
        )
        XCTAssertEqual(
            successPath(scoped.dispatch(payload: compressPayload(
                sources: [file], destination: authorized, format: "zip", name: "a.zip"
            ))),
            authorized.appendingPathComponent("a.zip").path
        )
    }

    /// The custom-compression dialog names its own format, so the setting must
    /// not turn that button into a failure.
    func testCustomCompressionIsExemptFromTheFormatSetting() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let file = authorized.appendingPathComponent("a.txt")
        try Data("A".utf8).write(to: file)

        var settings = ArchiveSettings()
        settings.enabledFormats = [.zip]
        let response = dispatcher(archiveSettings: settings).dispatch(payload: payload(
            .compressItems,
            FileOperationContract.OperationArgs(
                sourcePaths: [file.path],
                destinationDirectory: authorized.path,
                archiveFormat: "tar",
                customize: true
            )
        ))
        XCTAssertTrue(isSuccess(response), "the dialog owns the format choice")
    }

    /// The dialog writes long after `dispatch` returned, so the parked request's
    /// security-scoped access is already gone: the write has to take its own.
    ///
    /// Without that, every dialog write failed with “you don't have permission to
    /// view it” for sources inside a folder the user had authorized, which is the
    /// 2026-10-03 report (it looked like an encryption bug; it was not).
    func testTheDialogWriteTakesItsOwnScopedAccess() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let file = authorized.appendingPathComponent("a.txt")
        try Data("A".utf8).write(to: file)
        let dispatcher = dispatcher()

        // Park the request exactly the way 自定义压缩… does …
        XCTAssertTrue(isSuccess(dispatcher.dispatch(payload: payload(
            .compressItems,
            FileOperationContract.OperationArgs(
                name: "dialog.zip",
                sourcePaths: [file.path],
                destinationDirectory: authorized.path,
                archiveFormat: "zip",
                customize: true
            )
        ))))
        let pending = try XCTUnwrap(ArchiveRequestCenter.shared.pending)

        // … then let 确定 do the write, with no scope left over from the dispatch.
        started = []
        stopped = []
        let report = try dispatcher.performCustomCompression(
            sources: pending.sources,
            into: pending.directory,
            preferredName: pending.name,
            format: pending.format,
            mode: pending.mode,
            label: pending.label,
            password: nil,
            settings: ArchiveSettings(),
            control: nil
        )

        XCTAssertEqual(report.archiveURL.path, authorized.appendingPathComponent("dialog.zip").path)
        XCTAssertEqual(started, [authorized.path], "the dialog write must start its own scoped access")
        XCTAssertEqual(stopped, [authorized.path], "… and stop it again")
    }

    func testTheDialogWriteRefusesAPathOutsideAnyAuthorizedFolder() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try authorize(authorized)
        let file = other.appendingPathComponent("a.txt")
        try Data("A".utf8).write(to: file)

        started = []
        XCTAssertThrowsError(try dispatcher().performCustomCompression(
            sources: [file],
            into: other,
            preferredName: "dialog.zip",
            format: .zip,
            mode: .standard,
            label: nil,
            password: nil,
            settings: ArchiveSettings(),
            control: nil
        )) { error in
            guard let failure = error as? FileOperationDispatcher.CustomCompressionFailure else {
                return XCTFail("expected a dialog failure, got \(error)")
            }
            XCTAssertTrue(
                failure.message.contains("Path outside any authorized folder"),
                "the dialog shows this verbatim: \(failure.message)"
            )
        }
        XCTAssertTrue(started.isEmpty, "no scoped access may be started for an unauthorized path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("dialog.zip").path))
    }

    /// 取消 must stay `ArchiveError.cancelled`: the sheet treats that as “the
    /// user asked for this”, not as something to show in red.
    func testTheDialogWriteKeepsTheCancellationIdentity() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let file = authorized.appendingPathComponent("a.txt")
        try Data("A".utf8).write(to: file)
        let control = ArchiveOperationControl()
        control.cancel()

        XCTAssertThrowsError(try dispatcher().performCustomCompression(
            sources: [file],
            into: authorized,
            preferredName: "dialog.zip",
            format: .zip,
            mode: .standard,
            label: nil,
            password: nil,
            settings: ArchiveSettings(),
            control: control
        )) { error in
            guard case ArchiveError.cancelled = error else {
                return XCTFail("a cancelled dialog write must keep its identity, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: authorized.appendingPathComponent("dialog.zip").path))
    }

    func testExtractArchiveExtractsIntoTheArchivesOwnFolderByDefault() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let archive = authorized.appendingPathComponent("sample.zip")
        try RawZipBuilder.archive([("folder/a.txt", "hello")]).write(to: archive)

        let response = dispatcher().dispatch(payload: extractPayload(archives: [archive]))
        guard case .batchSuccess(let items) = response else {
            return XCTFail("expected a batch response, got \(response)")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].success)
        XCTAssertEqual(items[0].destinationPath, authorized.path)
        XCTAssertEqual(
            try String(contentsOf: authorized.appendingPathComponent("folder/a.txt"), encoding: .utf8),
            "hello"
        )
    }

    func testExtractArchiveToAnExplicitDestination() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let output = authorized.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try authorize(authorized)
        let archive = authorized.appendingPathComponent("sample.zip")
        try RawZipBuilder.archive([("a.txt", "hello")]).write(to: archive)

        let response = dispatcher().dispatch(payload: extractPayload(archives: [archive], destination: output))
        guard case .batchSuccess(let items) = response else { return XCTFail("expected a batch response") }
        XCTAssertTrue(items[0].success)
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("a.txt"), encoding: .utf8), "hello")
    }

    /// The end-to-end security path: a `../` entry must be reported, and nothing
    /// may appear outside the destination.
    func testExtractArchiveReportsZipSlipEntries() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let archive = authorized.appendingPathComponent("evil.zip")
        try RawZipBuilder.archive([("good.txt", "safe"), ("../escaped.txt", "pwned")]).write(to: archive)

        let response = dispatcher().dispatch(payload: extractPayload(archives: [archive]))
        guard case .batchSuccess(let items) = response else { return XCTFail("expected a batch response") }
        // The archive extracted, but one entry was refused: reported as a skip,
        // never as a silent success of the traversal.
        XCTAssertTrue(items[0].success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: authorized.appendingPathComponent("good.txt").path))
    }

    /// P9 stage 4: 「解压到指定位置…」 — the destination comes from the picker,
    /// and cancelling must not extract anywhere.
    func testExtractArchiveUsesTheChosenDestination() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let chosen = authorized.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try authorize(authorized)
        let archive = authorized.appendingPathComponent("sample.zip")
        try RawZipBuilder.archive([("a.txt", "hello")]).write(to: archive)

        let response = dispatcher(folderChooser: { chosen }).dispatch(payload: payload(
            .extractArchive,
            FileOperationContract.OperationArgs(sourcePaths: [archive.path], customize: true)
        ))
        guard case .batchSuccess(let items) = response else { return XCTFail("expected a batch response") }
        XCTAssertTrue(items[0].success)
        XCTAssertEqual(items[0].destinationPath, chosen.path)
        XCTAssertEqual(try String(contentsOf: chosen.appendingPathComponent("a.txt"), encoding: .utf8), "hello")
        XCTAssertFalse(FileManager.default.fileExists(atPath: authorized.appendingPathComponent("a.txt").path))
    }

    func testExtractArchiveCancelledPickerExtractsNowhere() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let archive = authorized.appendingPathComponent("sample.zip")
        try RawZipBuilder.archive([("a.txt", "hello")]).write(to: archive)

        let response = dispatcher(folderChooser: { nil }).dispatch(payload: payload(
            .extractArchive,
            FileOperationContract.OperationArgs(sourcePaths: [archive.path], customize: true)
        ))
        XCTAssertNotNil(failureCode(response))
        XCTAssertFalse(FileManager.default.fileExists(atPath: authorized.appendingPathComponent("a.txt").path))
    }

    func testExtractArchiveRejectsANonArchive() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let fake = authorized.appendingPathComponent("fake.zip")
        try Data("not a zip".utf8).write(to: fake)

        let response = dispatcher().dispatch(payload: extractPayload(archives: [fake]))
        guard case .batchSuccess(let items) = response else { return XCTFail("expected a batch response") }
        XCTAssertFalse(items[0].success)
        XCTAssertEqual(items[0].errorCode, .archiveUnsupported)
    }

    func testExtractArchiveRefusesToRunAboveTheSizeLimit() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let archive = authorized.appendingPathComponent("big.zip")
        try RawZipBuilder.archive([("big.txt", String(repeating: "x", count: 2_000_000))]).write(to: archive)

        let response = dispatcher(archiveSettings: ArchiveSettings(sizeLimitMB: 1))
            .dispatch(payload: extractPayload(archives: [archive]))
        guard case .batchSuccess(let items) = response else { return XCTFail("expected a batch response") }
        XCTAssertFalse(items[0].success)
        XCTAssertEqual(items[0].errorCode, .archiveTooLarge)
        XCTAssertFalse(FileManager.default.fileExists(atPath: authorized.appendingPathComponent("big.txt").path))
    }

    func testExtractArchiveOutsideAuthorizationIsRejected() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try authorize(authorized)
        let archive = other.appendingPathComponent("sample.zip")
        try RawZipBuilder.archive([("a.txt", "hello")]).write(to: archive)

        XCTAssertEqual(
            failureCode(dispatcher().dispatch(payload: extractPayload(archives: [archive]))),
            .pathOutsideAuthorizedScope
        )
    }

    // MARK: - Encrypted archives (the password never leaves the main app)

    /// The password book already knows the password: extraction just works, and
    /// nobody is asked anything.
    func testExtractArchiveUsesThePasswordFromThePasswordBook() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let archive = authorized.appendingPathComponent("secret.zip")
        try EncryptedZipFixture.archive(contents: "top secret\n", password: "hunter2").write(to: archive)
        let prompt = ScriptedPasswordPrompt(automatic: ["hunter2"])

        let response = dispatcher(passwordPrompting: prompt)
            .dispatch(payload: extractPayload(archives: [archive]))

        guard case .batchSuccess(let items) = response else { return XCTFail("expected a batch response, got \(response)") }
        XCTAssertTrue(items[0].success, items[0].message ?? "")
        XCTAssertEqual(prompt.askCount, 0)
        XCTAssertEqual(
            try String(contentsOf: authorized.appendingPathComponent("secret.txt"), encoding: .utf8),
            "top secret\n"
        )
        XCTAssertEqual(started, stopped, "scoped access must be balanced")
    }

    /// A password the user cancels is a quiet no-op: the extension reports the
    /// user's cancel, so nothing is written and no error dialog appears.
    func testExtractArchiveCancelsQuietlyWhenThePasswordPromptIsDismissed() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let archive = authorized.appendingPathComponent("secret.zip")
        try EncryptedZipFixture.archive(contents: "top secret\n", password: "hunter2").write(to: archive)
        let prompt = ScriptedPasswordPrompt(automatic: ["wrong"], answers: [nil])

        let response = dispatcher(passwordPrompting: prompt)
            .dispatch(payload: extractPayload(archives: [archive]))

        XCTAssertEqual(failureCode(response), .cancelledByUser)
        XCTAssertEqual(prompt.askCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: authorized.appendingPathComponent("secret.txt").path),
            "nothing may be written before the password is settled"
        )
    }

    /// With no prompter wired up (a build without the UI, or a test), the archive
    /// is reported honestly instead of pretending it is corrupt.
    func testExtractArchiveWithoutAPasswordPromptReportsTheProtection() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let archive = authorized.appendingPathComponent("secret.zip")
        try EncryptedZipFixture.archive(contents: "top secret\n", password: "hunter2").write(to: archive)

        let response = dispatcher().dispatch(payload: extractPayload(archives: [archive]))

        guard case .batchSuccess(let items) = response else { return XCTFail("expected a batch response, got \(response)") }
        XCTAssertFalse(items[0].success)
        XCTAssertEqual(items[0].errorCode, .archiveFailed)
        XCTAssertTrue(items[0].message?.contains("password-protected") == true, items[0].message ?? "no message")
        XCTAssertFalse(FileManager.default.fileExists(atPath: authorized.appendingPathComponent("secret.txt").path))
    }

    /// The password is resolved for every archive **before** the first byte is
    /// written, so cancelling the second prompt does not leave the first archive
    /// half-extracted.
    func testExtractArchiveSettlesEveryPasswordBeforeWritingAnything() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let first = authorized.appendingPathComponent("first.zip")
        let second = authorized.appendingPathComponent("second.zip")
        try RawZipBuilder.archive([("one.txt", "one")]).write(to: first)
        try EncryptedZipFixture.archive(name: "two.txt", contents: "two", password: "hunter2").write(to: second)
        let prompt = ScriptedPasswordPrompt(automatic: [], answers: [nil])

        let response = dispatcher(passwordPrompting: prompt)
            .dispatch(payload: extractPayload(archives: [first, second]))

        XCTAssertEqual(failureCode(response), .cancelledByUser)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: authorized.appendingPathComponent("one.txt").path),
            "the first archive must not have been extracted while the second was still locked"
        )
    }


    // MARK: - 7z and tar.gz through the menu, not only ZIP

    /// Before 2026-10-03 the password resolver probed **every** archive with the
    /// ZIP reader, so a 7z, tar or tar.gz picked in Finder came back as
    /// “Not a readable archive”. The test corpus was all ZIP, so nothing caught it.
    func testExtractArchiveReadsASevenZipThroughTheMenu() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let source = authorized.appendingPathComponent("notes.txt")
        try Data("seven zip contents\n".utf8).write(to: source)
        let archive = try ArchiveCompressor.compress(
            [source],
            into: authorized,
            preferredName: "notes.7z",
            format: .sevenZip,
            conflictPolicy: .keepBoth,
            sizeLimitMB: 64
        ).archiveURL
        try FileManager.default.removeItem(at: source)

        let response = dispatcher().dispatch(payload: extractPayload(archives: [archive]))

        guard case .batchSuccess(let items) = response else { return XCTFail("expected a batch response, got \(response)") }
        XCTAssertTrue(items[0].success, items[0].message ?? "")
        XCTAssertEqual(
            try String(contentsOf: authorized.appendingPathComponent("notes.txt"), encoding: .utf8),
            "seven zip contents\n"
        )
    }

    func testExtractArchiveReadsATarGzThroughTheMenu() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let source = authorized.appendingPathComponent("notes.txt")
        try Data("tarball contents\n".utf8).write(to: source)
        let archive = try ArchiveCompressor.compress(
            [source],
            into: authorized,
            preferredName: "notes.tar.gz",
            format: .gzip,
            conflictPolicy: .keepBoth,
            sizeLimitMB: 64
        ).archiveURL
        try FileManager.default.removeItem(at: source)

        let response = dispatcher().dispatch(payload: extractPayload(archives: [archive]))

        guard case .batchSuccess(let items) = response else { return XCTFail("expected a batch response, got \(response)") }
        XCTAssertTrue(items[0].success, items[0].message ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: authorized.appendingPathComponent("notes.txt").path))
    }

    /// The 密码本 path for 7z: the password is checked against a real AES
    /// archive, so nothing is written before the key is proven.
    func testExtractArchiveUnlocksAnEncryptedSevenZipFromThePasswordBook() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let source = authorized.appendingPathComponent("secret.txt")
        try Data("top secret\n".utf8).write(to: source)
        let archive = try ArchiveCompressor.compress(
            [source],
            into: authorized,
            preferredName: "locked.7z",
            format: .sevenZip,
            conflictPolicy: .keepBoth,
            sizeLimitMB: 64,
            password: "hunter2"
        ).archiveURL
        try FileManager.default.removeItem(at: source)
        let prompt = ScriptedPasswordPrompt(automatic: ["hunter2"])

        let response = dispatcher(passwordPrompting: prompt).dispatch(payload: extractPayload(archives: [archive]))

        guard case .batchSuccess(let items) = response else { return XCTFail("expected a batch response, got \(response)") }
        XCTAssertTrue(items[0].success, items[0].message ?? "")
        XCTAssertEqual(prompt.askCount, 0, "a remembered password must not open a dialog")
        XCTAssertEqual(
            try String(contentsOf: authorized.appendingPathComponent("secret.txt"), encoding: .utf8),
            "top secret\n"
        )
    }

    func testExtractArchiveAsksForAnUnknownSevenZipPassword() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let source = authorized.appendingPathComponent("secret.txt")
        try Data("top secret\n".utf8).write(to: source)
        let archive = try ArchiveCompressor.compress(
            [source],
            into: authorized,
            preferredName: "locked.7z",
            format: .sevenZip,
            conflictPolicy: .keepBoth,
            sizeLimitMB: 64,
            password: "hunter2"
        ).archiveURL
        try FileManager.default.removeItem(at: source)
        let prompt = ScriptedPasswordPrompt(answers: ["hunter2"])

        let response = dispatcher(passwordPrompting: prompt).dispatch(payload: extractPayload(archives: [archive]))

        guard case .batchSuccess(let items) = response else { return XCTFail("expected a batch response, got \(response)") }
        XCTAssertTrue(items[0].success, items[0].message ?? "")
        XCTAssertEqual(prompt.askCount, 1)
        XCTAssertEqual(prompt.askedAbout, ["locked.7z"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: authorized.appendingPathComponent("secret.txt").path))
    }

    func testExtractArchiveCancelsQuietlyWhenTheSevenZipPromptIsDismissed() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let source = authorized.appendingPathComponent("secret.txt")
        try Data("top secret\n".utf8).write(to: source)
        let archive = try ArchiveCompressor.compress(
            [source],
            into: authorized,
            preferredName: "locked.7z",
            format: .sevenZip,
            conflictPolicy: .keepBoth,
            sizeLimitMB: 64,
            password: "hunter2"
        ).archiveURL
        try FileManager.default.removeItem(at: source)
        let prompt = ScriptedPasswordPrompt(answers: [nil])

        let response = dispatcher(passwordPrompting: prompt).dispatch(payload: extractPayload(archives: [archive]))

        XCTAssertEqual(failureCode(response), .cancelledByUser)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: authorized.appendingPathComponent("secret.txt").path),
            "a cancelled password writes nothing, not even a partial file"
        )
    }

    // MARK: - The dialog's three new options, through the dispatcher it calls

    func testTheDialogCanWriteASplitArchive() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let source = authorized.appendingPathComponent("bytes.bin")
        try Data((0..<1_200_000).map { _ in UInt8.random(in: 0...255) }).write(to: source)

        let report = try dispatcher().performCustomCompression(
            sources: [source],
            into: authorized,
            preferredName: "split.zip",
            format: .zip,
            mode: .standard,
            label: nil,
            password: nil,
            solid: true,
            encryptsFileNames: false,
            volumeSizeMB: 1,
            settings: ArchiveSettings(),
            control: nil
        )

        XCTAssertEqual(report.archiveURL.lastPathComponent, "split.zip.001")
        let parts = ArchiveVolumeSet.existingParts(firstPart: report.archiveURL)
        XCTAssertGreaterThan(parts.count, 1, "1.2 MB at 1 MB per part has to produce more than one part")
        XCTAssertEqual(started, stopped, "scoped access must be balanced")
    }

    func testTheDialogCanWriteAnEncryptedSevenZipAndTheMenuCanReadItBack() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let source = authorized.appendingPathComponent("secret.txt")
        try Data("top secret\n".utf8).write(to: source)

        let report = try dispatcher().performCustomCompression(
            sources: [source],
            into: authorized,
            preferredName: "locked.7z",
            format: .sevenZip,
            mode: .maximum,
            label: nil,
            password: "hunter2",
            solid: false,
            encryptsFileNames: true,
            volumeSizeMB: nil,
            settings: ArchiveSettings(),
            control: nil
        )

        XCTAssertEqual(report.archiveURL.lastPathComponent, "locked.7z")
        // The archive is what the user keeps; the source goes the way it would
        // after a real 压缩 (the dialog does not delete it, the test does).
        try FileManager.default.removeItem(at: source)
        // No password anywhere: the menu path must refuse, not write a broken file.
        let withoutPassword = dispatcher().dispatch(payload: extractPayload(archives: [report.archiveURL]))
        guard case .batchSuccess(let refused) = withoutPassword else {
            return XCTFail("expected a batch response, got \(withoutPassword)")
        }
        XCTAssertFalse(refused[0].success)
        XCTAssertEqual(refused[0].errorCode, .archiveFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: authorized.appendingPathComponent("secret.txt").path))

        // With the right password the same archive extracts.
        let prompt = ScriptedPasswordPrompt(automatic: ["hunter2"])
        let unlocked = dispatcher(passwordPrompting: prompt).dispatch(payload: extractPayload(archives: [report.archiveURL]))
        guard case .batchSuccess(let items) = unlocked else {
            return XCTFail("expected a batch response, got \(unlocked)")
        }
        XCTAssertTrue(items[0].success, items[0].message ?? "")
        XCTAssertEqual(
            try String(contentsOf: authorized.appendingPathComponent("secret.txt"), encoding: .utf8),
            "top secret\n"
        )
    }

    func testTheDialogRefusesToEncryptAFormatThatCannotCarryAPassword() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let source = authorized.appendingPathComponent("a.txt")
        try Data("A".utf8).write(to: source)

        XCTAssertThrowsError(try dispatcher().performCustomCompression(
            sources: [source],
            into: authorized,
            preferredName: "a.tar",
            format: .tar,
            mode: .standard,
            label: nil,
            password: "hunter2",
            settings: ArchiveSettings(),
            control: nil
        )) { error in
            guard case ArchiveError.encryptionUnsupported = error else {
                return XCTFail("expected encryptionUnsupported, got \(error)")
            }
        }
    }

    // MARK: - P6 helpers

    func testAliasNameConvention() {
        XCTAssertEqual(FileOperationService.aliasName(for: URL(fileURLWithPath: "/a/notes.txt")), "notes.txt alias")
        XCTAssertEqual(FileOperationService.aliasName(for: URL(fileURLWithPath: "/a/Photos")), "Photos alias")
    }

    func testIsLockedIsFalseForAMissingPath() {
        XCTAssertFalse(FileOperationService.isLocked(root.appendingPathComponent("nope.txt")))
    }

    // MARK: - P7: 文件权限 switches that used to be inert

    private func permissivePermissions(confirm: Bool = false) -> FilePermissionSettings {
        FilePermissionSettings(
            allowedActions: Set(FileAction.allCases),
            restrictToAuthorizedFolders: false,
            confirmDestructiveActions: confirm
        )
    }

    /// 关闭「仅在已授权的文件夹内创建或修改文件」后，MenuRight 自己的预检放行；
    /// 沙盒仍然是最终裁判，但在测试进程里写入会成功。
    func testRestrictOffLetsACreateIntoAnUnauthorizedFolderThrough() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try authorize(authorized)

        let response = dispatcher(filePermissions: permissivePermissions())
            .dispatch(payload: createFilePayload(directory: other, name: "loose.txt", contents: "x"))

        XCTAssertNil(failureCode(response), "expected success, got \(response)")
        XCTAssertEqual(
            try String(contentsOf: other.appendingPathComponent("loose.txt"), encoding: .utf8),
            "x"
        )
    }

    /// 同样的请求在开关打开（默认）时仍被拒绝 —— 证明这个开关真的在起作用。
    func testRestrictOnStillRejectsACreateIntoAnUnauthorizedFolder() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try authorize(authorized)

        let response = dispatcher().dispatch(payload: createFilePayload(directory: other, name: "loose.txt", contents: "x"))

        // Creates never had a scope pre-check: they run inside
        // `withAuthorization`, which reports `notAuthorized` when no bookmark
        // covers the target. Restrict-on therefore keeps exactly the old code.
        XCTAssertEqual(failureCode(response), .notAuthorized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("loose.txt").path))
    }

    /// 关闭后移动也不再被预检拦截（目标仍在已授权目录内，只是多目标场景）。
    func testRestrictOffLetsAnUnauthorizedMoveThrough() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let other = root.appendingPathComponent("Authorized/Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try authorize(authorized)
        let source = root.appendingPathComponent("Outside/Source.txt")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("s".utf8).write(to: source)

        let response = dispatcher(filePermissions: permissivePermissions())
            .dispatch(payload: movePayload(sources: [source], destination: other))

        guard case .batchSuccess(let items) = response else {
            return XCTFail("expected batchSuccess, got \(response)")
        }
        XCTAssertTrue(items[0].success, "move failed: \(items[0].message ?? "")")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("Source.txt").path))
    }

    /// 二次确认被拒绝：锁定不生效，返回 cancelledByUser（扩展把这一码当作静默取消）。
    func testRefusedLockConfirmationLeavesTheItemUnlocked() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let item = authorized.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: item)
        let confirmer = StubConfirmer(answer: false)

        let response = dispatcher(destructiveConfirmation: confirmer)
            .dispatch(payload: payload(.setLocked, .init(sourcePaths: [item.path], locked: true)))

        XCTAssertEqual(failureCode(response), .cancelledByUser)
        XCTAssertFalse(FileOperationService.isLocked(item))
        XCTAssertEqual(confirmer.actions, [.lock(count: 1)])
    }

    /// 确认后照常执行。
    func testAcceptedLockConfirmationLocksTheItem() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let item = authorized.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: item)
        let confirmer = StubConfirmer(answer: true)

        let response = dispatcher(destructiveConfirmation: confirmer)
            .dispatch(payload: payload(.setLocked, .init(sourcePaths: [item.path], locked: true)))

        guard case .batchSuccess(let items) = response else {
            return XCTFail("expected batchSuccess, got \(response)")
        }
        XCTAssertTrue(items[0].success)
        XCTAssertTrue(FileOperationService.isLocked(item))
        XCTAssertEqual(confirmer.actions, [.lock(count: 1)])
    }

    /// 关闭「敏感操作前二次确认」后，即使注入了确认器也不会被询问。
    func testConfirmSwitchOffSkipsTheInjectedConfirmer() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let item = authorized.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: item)
        let confirmer = StubConfirmer(answer: false)

        let response = dispatcher(
            filePermissions: permissivePermissions(confirm: false),
            destructiveConfirmation: confirmer
        ).dispatch(payload: payload(.setLocked, .init(sourcePaths: [item.path], locked: true)))

        guard case .batchSuccess(let items) = response else {
            return XCTFail("expected batchSuccess, got \(response)")
        }
        XCTAssertTrue(items[0].success)
        XCTAssertTrue(FileOperationService.isLocked(item))
        XCTAssertTrue(confirmer.actions.isEmpty, "the switch is off, so nobody may ask")
    }

    /// 剪切（移动）也走二次确认；拒绝时文件原地不动。
    func testRefusedCutConfirmationLeavesTheSourcesInPlace() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        let destination = root.appendingPathComponent("Authorized/Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try authorize(authorized)
        let source = authorized.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: source)
        let confirmer = StubConfirmer(answer: false)

        let response = dispatcher(destructiveConfirmation: confirmer)
            .dispatch(payload: movePayload(sources: [source], destination: destination))

        XCTAssertEqual(failureCode(response), .cancelledByUser)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(confirmer.actions, [.cutMove(count: 1)])
    }

    /// 配置的终端 App 不存在时回退到内置 opener，而不是让「打开终端」失败。
    func testMissingConfiguredTerminalFallsBackToTheBuiltInOpener() throws {
        let directory = root.appendingPathComponent("AnyFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var general = GeneralSettings()
        general.terminalApplicationPath = "/Applications/Definitely-Not-Installed-\(UUID().uuidString).app"

        let response = dispatcher(generalSettings: general)
            .dispatch(payload: payload(.openTerminal, .init(directory: directory.path)))

        XCTAssertNil(failureCode(response))
        XCTAssertEqual(openedDirectories, [directory.path])
    }

    // MARK: - P7: 模板目录覆盖

    /// 覆盖目录优先于注入的内置目录，并且真的从覆盖目录复制。
    func testTemplateOverrideDirectoryIsPreferredOverTheInjectedDirectory() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let override = root.appendingPathComponent("CustomTemplates", isDirectory: true)
        try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
        try Data("custom-key".utf8).write(to: override.appendingPathComponent("blank.key"))
        var newFile = NewFileSettings()
        newFile.templateDirectoryPath = override.path

        let response = dispatcher(newFileSettings: newFile).dispatch(payload: documentPayload(
            .createFromTemplate, directory: authorized, name: "Deck.key", kind: "keynote"
        ))

        let path = try XCTUnwrap(successPath(response))
        XCTAssertEqual(path, authorized.appendingPathComponent("Deck.key").path)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "custom-key")
    }

    /// 覆盖目录里缺少的那种模板报 templateMissing，而不是偷偷回退到内置目录。
    func testTemplateOverrideMissingKindReportsTemplateMissing() throws {
        let authorized = root.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try authorize(authorized)
        let override = root.appendingPathComponent("CustomTemplates", isDirectory: true)
        try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
        try Data("custom-key".utf8).write(to: override.appendingPathComponent("blank.key"))
        var newFile = NewFileSettings()
        newFile.templateDirectoryPath = override.path

        let response = dispatcher(newFileSettings: newFile).dispatch(payload: documentPayload(
            .createFromTemplate, directory: authorized, name: "Budget.numbers", kind: "numbers"
        ))

        XCTAssertEqual(failureCode(response), .templateMissing)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: authorized.path).isEmpty)
    }

    // MARK: - P7: 确认话术

    func testDestructiveActionLabelsCarryTheirCountOnlyWhenPlural() {
        let text: (StringKey) -> String = { key in
            switch key {
            case .confirmDestructiveLock: return "LOCK"
            case .confirmDestructiveUnlock: return "UNLOCK"
            case .confirmDestructiveCut: return "CUT"
            default: return "?"
            }
        }
        XCTAssertEqual(DestructiveActionPrompter.describe(.lock(count: 1), text: text), "LOCK")
        XCTAssertEqual(DestructiveActionPrompter.describe(.cutMove(count: 4), text: text), "CUT (4)")
        XCTAssertEqual(DestructiveActionPrompter.describe(.unlock(count: 2), text: text), "UNLOCK (2)")
        XCTAssertEqual(DestructiveAction.lock(count: 3).itemCount, 3)
    }
}
