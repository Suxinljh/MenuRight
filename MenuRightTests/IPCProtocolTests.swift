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

    func testMalformedJSONDecodesToNil() {
        XCTAssertNil(IPCProtocol.decode(IPCProtocol.Request.self, from: Data("not json".utf8)))
        XCTAssertNil(IPCProtocol.decode(IPCProtocol.Request.self, from: Data()))
    }
}
