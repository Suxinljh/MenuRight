import XCTest
import Darwin

/// End-to-end coverage for the App-Group IPC wiring: a real listener in a
/// temporary directory, a real client socket, the real framing, and the real
/// dispatcher. Only the peer-identity gate is stubbed (a unit-test process
/// cannot present the extension's code signature) — which is why
/// `MainAppIPCServer` takes the verifier as an injected dependency.
final class IPCIntegrationTests: XCTestCase {
    private var dir: URL!
    private var socketURL: URL!
    private var store: FolderAuthorizationStore!
    private var servers: [MainAppIPCServer] = []

    override func setUpWithError() throws {
        dir = try makeShortTempDir("mr-ipc")
        socketURL = dir.appendingPathComponent("ipc.sock")
        store = FolderAuthorizationStore(fileURL: dir.appendingPathComponent("FolderAuthorization.json"))
        servers = []
    }

    override func tearDownWithError() throws {
        for server in servers { server.stop() }
        try? FileManager.default.removeItem(at: dir)
    }

    /// AF_UNIX `sun_path` is only 104 bytes on macOS; keep test socket paths short.
    private func makeShortTempDir(_ prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Fixtures

    private func scopedConfiguration() -> ScopedAccessConfiguration {
        ScopedAccessConfiguration(
            resolveBookmark: { data in
                (URL(fileURLWithPath: String(data: data, encoding: .utf8) ?? "/"), false)
            },
            startAccess: { _ in true },
            stopAccess: { _ in },
            makeFreshBookmark: { url in Data(url.path.utf8) }
        )
    }

    private func verifiedPeer() -> PeerIdentity.Result {
        .verified(PeerIdentity.Verified(
            pid: 4242,
            uid: getuid(),
            gid: getgid(),
            bundleIdentifier: "test.stub",
            teamIdentifier: "TESTTEAM42",
            executablePath: "/test/stub"
        ))
    }

    @discardableResult
    private func makeServer(acceptingPeer: Bool = true) -> MainAppIPCServer {
        let server = MainAppIPCServer(
            socketURL: socketURL,
            fileOpDispatcher: FileOperationDispatcher(store: store, scopedConfig: scopedConfiguration()),
            peerVerifier: { _ in
                acceptingPeer ? self.verifiedPeer() : .rejected(reason: "stub rejection")
            }
        )
        servers.append(server)
        return server
    }

    /// One request/response round trip over a fresh connection.
    private func roundTrip(method: String, payload: String? = nil) -> IPCProtocol.Response? {
        let conn = UnixSocketTransport.connect(to: socketURL)
        guard conn.fd >= 0 else { return nil }
        defer { Darwin.close(conn.fd) }

        let request = IPCProtocol.Request(method: method, payload: payload)
        guard let requestData = IPCProtocol.encode(request),
              UnixSocketTransport.writeFrame(conn.fd, payload: requestData),
              let responseData = UnixSocketTransport.readFrame(conn.fd) else { return nil }
        return IPCProtocol.decode(IPCProtocol.Response.self, from: responseData)
    }

    private func payload(
        _ kind: FileOperationContract.OperationKind,
        _ args: FileOperationContract.OperationArgs
    ) -> String {
        FileOperationContract.Request(kind: kind, args: args, clientRequestId: "integration").encodedForIPC()!
    }

    // MARK: - Tests

    func testPingRoundTrip() throws {
        let server = makeServer()
        server.start()
        XCTAssertTrue(server.isRunning)

        let response = try XCTUnwrap(roundTrip(method: "ping", payload: "integration"))
        XCTAssertNil(response.error)
        XCTAssertTrue(try XCTUnwrap(response.result).contains("pong"))
    }

    func testFileOperationIsDispatchedAndWritesInsideTheAuthorizedFolder() throws {
        let authorized = dir.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(at: authorized, withIntermediateDirectories: true)
        try store.add(AuthorizedFolder(
            displayName: "Authorized",
            originalPath: authorized.path,
            bookmarkData: Data(authorized.path.utf8)
        ))

        let server = makeServer()
        server.start()

        let request = payload(.createFile, FileOperationContract.OperationArgs(
            directory: authorized.path,
            name: "Untitled.txt"
        ))
        let response = try XCTUnwrap(roundTrip(method: "fileOperation", payload: request))
        XCTAssertNil(response.error)

        let outcome = try XCTUnwrap(FileOperationContract.Response.decode(fromIPC: response.result))
        guard case .success(let path) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(path, authorized.appendingPathComponent("Untitled.txt").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(path)))
    }

    func testFileOperationFailureTravelsInTheErrorFieldWithAStableCode() throws {
        // No authorization registered at all.
        let server = makeServer()
        server.start()

        let request = payload(.createFile, FileOperationContract.OperationArgs(
            directory: dir.path,
            name: "Untitled.txt"
        ))
        let response = try XCTUnwrap(roundTrip(method: "fileOperation", payload: request))
        XCTAssertNil(response.result)
        let outcome = try XCTUnwrap(FileOperationContract.Response.decode(fromIPC: response.error))
        guard case .failure(let code, _) = outcome else {
            return XCTFail("expected failure, got \(outcome)")
        }
        XCTAssertEqual(code, .notAuthorized)
    }

    func testUnknownMethodIsRejected() throws {
        let server = makeServer()
        server.start()

        let response = try XCTUnwrap(roundTrip(method: "deleteEverything"))
        XCTAssertEqual(response.error, "unknown method: deleteEverything")
    }

    /// H2 regression: a rejected peer must not receive any response, so an
    /// impostor cannot even learn whether it reached a real MenuRight socket.
    func testRejectedPeerGetsNoResponse() throws {
        let server = makeServer(acceptingPeer: false)
        server.start()

        XCTAssertNil(roundTrip(method: "ping", payload: "impostor"))
    }

    /// L4 regression: stop()/start() on the same path must leave a working
    /// listener and must not close the new fd from a stale cancel handler.
    func testStartStopStartReusesTheSameSocketPath() throws {
        let server = makeServer()
        server.start()
        XCTAssertNotNil(roundTrip(method: "ping"))

        server.stop()
        XCTAssertFalse(server.isRunning)

        server.start()
        XCTAssertTrue(server.isRunning)
        XCTAssertNotNil(roundTrip(method: "ping"), "the listener must be usable after a stop/start cycle")
    }

    /// H2 regression: a second instance must never clobber a live socket.
    func testSecondServerCannotStealTheLiveSocket() throws {
        let first = makeServer()
        first.start()
        XCTAssertTrue(first.isRunning)

        let second = makeServer()
        second.start()
        XCTAssertFalse(second.isRunning, "the second listener must refuse to bind over a live socket")

        let response = try XCTUnwrap(roundTrip(method: "ping"), "the original listener must still be serving")
        XCTAssertTrue(try XCTUnwrap(response.result).contains("pong"))
    }
}
