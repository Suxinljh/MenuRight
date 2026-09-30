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
}
