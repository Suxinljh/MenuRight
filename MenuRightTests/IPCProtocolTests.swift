import XCTest

/// The IPC envelope is the wire contract between two independently built
/// binaries, so its JSON shape is pinned here.
final class IPCProtocolTests: XCTestCase {
    func testRequestRoundTrip() throws {
        let request = IPCProtocol.Request(id: "abc-123", method: "ping", payload: "hello")
        let data = try XCTUnwrap(IPCProtocol.encode(request))
        let decoded = try XCTUnwrap(IPCProtocol.decode(IPCProtocol.Request.self, from: data))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.id, "abc-123")
        XCTAssertEqual(decoded.method, "ping")
        XCTAssertEqual(decoded.payload, "hello")
    }

    func testRequestDefaultsToVersionOneAndFreshId() {
        let a = IPCProtocol.Request(method: "ping")
        let b = IPCProtocol.Request(method: "ping")
        XCTAssertEqual(a.version, 1)
        XCTAssertNil(a.payload)
        XCTAssertNotEqual(a.id, b.id)
    }

    func testResponseFactories() throws {
        let ok = IPCProtocol.Response.ok(id: "1", result: "pong")
        XCTAssertEqual(ok.result, "pong")
        XCTAssertNil(ok.error)

        let fail = IPCProtocol.Response.fail(id: "2", error: "boom")
        XCTAssertNil(fail.result)
        XCTAssertEqual(fail.error, "boom")

        let data = try XCTUnwrap(IPCProtocol.encode(fail))
        XCTAssertEqual(try XCTUnwrap(IPCProtocol.decode(IPCProtocol.Response.self, from: data)).error, "boom")
    }

    // MARK: - Containing-app derivation (the extension's only usable peer check)

    func testContainingAppBundleIsDerivedWithAndWithoutTrailingSlash() {
        // `Bundle.main.bundleURL` really does end with a slash for an appex;
        // the earlier implementation tripped over exactly that.
        for path in [
            "/Applications/MenuRight.app/Contents/PlugIns/MenuRightFinder.appex",
            "/Applications/MenuRight.app/Contents/PlugIns/MenuRightFinder.appex/",
        ] {
            let derived = MenuRightIPC.containingAppBundleURL(forExtensionBundleAt: URL(fileURLWithPath: path))
            XCTAssertEqual(derived?.path, "/Applications/MenuRight.app", "failed for \(path)")
        }
    }

    func testContainingAppBundleRejectsNonExtensionPaths() {
        XCTAssertNil(MenuRightIPC.containingAppBundleURL(
            forExtensionBundleAt: URL(fileURLWithPath: "/Applications/MenuRight.app")
        ))
        XCTAssertNil(MenuRightIPC.containingAppBundleURL(
            forExtensionBundleAt: URL(fileURLWithPath: "/tmp/not-an-appex.appex/Contents")
        ))
    }

    func testConventionalExecutablePathMatchesTheStandardLayout() {
        XCTAssertEqual(
            MenuRightIPC.conventionalExecutablePath(forAppBundleAt: URL(fileURLWithPath: "/Applications/MenuRight.app")),
            "/Applications/MenuRight.app/Contents/MacOS/MenuRight"
        )
        // And it matches the real derivation chain for an appex.
        let appBundle = MenuRightIPC.containingAppBundleURL(
            forExtensionBundleAt: URL(fileURLWithPath: "/Applications/MenuRight.app/Contents/PlugIns/MenuRightFinder.appex/")
        )
        XCTAssertEqual(
            appBundle.map(MenuRightIPC.conventionalExecutablePath(forAppBundleAt:)),
            "/Applications/MenuRight.app/Contents/MacOS/MenuRight"
        )
    }

    func testMalformedJSONDecodesToNil() {
        XCTAssertNil(IPCProtocol.decode(IPCProtocol.Request.self, from: Data("not json".utf8)))
        XCTAssertNil(IPCProtocol.decode(IPCProtocol.Request.self, from: Data()))
    }

    // MARK: - Wire-version gate (item 5)

    func testEveryConstructorWritesTheCurrentVersion() {
        // Guards the other half of the version gate: if a constructor stopped
        // writing `currentVersion`, this side would reject its own traffic.
        XCTAssertEqual(IPCProtocol.currentVersion, 1, "bumping the wire version is deliberate, not a silent change")
        XCTAssertEqual(IPCProtocol.Request(method: "ping").version, IPCProtocol.currentVersion)
        XCTAssertEqual(IPCProtocol.Response.ok(id: "1", result: "pong").version, IPCProtocol.currentVersion)
        XCTAssertEqual(IPCProtocol.Response.fail(id: "1", error: "e").version, IPCProtocol.currentVersion)
        XCTAssertEqual(IPCProtocol.Response.progress(id: "1", fraction: 0.5).version, IPCProtocol.currentVersion)
    }

    func testRequestFromAnotherVersionIsRejected() throws {
        // Hand-built JSON: the decoded value must carry version 2 so `decode`
        // sees the mismatch. A request from an incompatible peer is not
        // interpretable and must not be handed to the dispatcher.
        let foreign = Data(#"{"version":2,"id":"x","method":"ping"}"#.utf8)
        XCTAssertNil(IPCProtocol.decode(IPCProtocol.Request.self, from: foreign))
        // The same shape at the current version still decodes.
        let current = Data(#"{"version":1,"id":"x","method":"ping"}"#.utf8)
        XCTAssertEqual(IPCProtocol.decode(IPCProtocol.Request.self, from: current)?.method, "ping")
    }

    func testResponseFromAnotherVersionIsRejected() {
        let foreign = Data(#"{"version":3,"id":"x","result":"pong"}"#.utf8)
        XCTAssertNil(IPCProtocol.decode(IPCProtocol.Response.self, from: foreign))
        let current = Data(#"{"version":1,"id":"x","result":"pong"}"#.utf8)
        XCTAssertEqual(IPCProtocol.decode(IPCProtocol.Response.self, from: current)?.result, "pong")
    }

    func testVersionMismatchMessageNamesBothVersions() {
        let message = IPCProtocol.versionMismatchMessage(received: 2, expected: 1)
        XCTAssertTrue(message.contains("2"), "must name the peer's version: \(message)")
        XCTAssertTrue(message.contains("1"), "must name this build's version: \(message)")
        XCTAssertTrue(message.lowercased().contains("version"))
    }
}
