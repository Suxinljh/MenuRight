import XCTest
import Darwin

/// Regression net for the App-Group IPC framing and, most importantly, for the
/// H1 defect: a peer that connects and then stops sending must NOT be able to
/// block the caller indefinitely.
///
/// Everything here runs on a local `socketpair`, so no App Group, no signing,
/// and no Finder are involved.
final class UnixSocketTransportTests: XCTestCase {

    /// Connected pair of AF_UNIX stream sockets.
    ///
    /// Both ends get production-style socket timeouts: without them a test that
    /// writes more than the socket buffer before anyone reads (see the 64 KiB
    /// frame test) would block in the kernel forever instead of failing.
    private func makePair() throws -> (a: Int32, b: Int32) {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { buf in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        XCTAssertEqual(rc, 0, "socketpair() failed: \(String(cString: strerror(errno)))")
        guard rc == 0 else { throw XCTSkip("socketpair unavailable") }
        for fd in fds {
            _ = UnixSocketTransport.setSocketTimeouts(
                fd: fd,
                read: timeval(tv_sec: 10, tv_usec: 0),
                write: timeval(tv_sec: 10, tv_usec: 0)
            )
        }
        return (fds[0], fds[1])
    }

    private func closeAll(_ fds: Int32...) {
        for fd in fds where fd >= 0 { Darwin.close(fd) }
    }

    // MARK: - Framing

    func testFrameRoundTripForSmallPayload() throws {
        let (a, b) = try makePair()
        defer { closeAll(a, b) }

        let payload = Data("hello-menuright".utf8)
        XCTAssertTrue(UnixSocketTransport.writeFrame(a, payload: payload))
        XCTAssertEqual(UnixSocketTransport.readFrame(b), payload)
    }

    func testFrameRoundTripAtMaxFrameSize() throws {
        let (a, b) = try makePair()
        defer { closeAll(a, b) }

        // 64 KiB + prefix exceeds the socketpair buffer, so the writer must be
        // allowed to block while the reader drains it — that is exactly the
        // partial-write loop under test.
        let payload = Data(repeating: 0xAB, count: UnixSocketTransport.maxFrameSize)
        let writeResult = Locked(false)
        let done = expectation(description: "writer finished")
        DispatchQueue.global(qos: .userInitiated).async {
            writeResult.value = UnixSocketTransport.writeFrame(a, payload: payload)
            done.fulfill()
        }

        XCTAssertEqual(UnixSocketTransport.readFrame(b), payload)
        wait(for: [done], timeout: 10)
        XCTAssertTrue(writeResult.value)
    }

    func testOversizedFrameIsRejectedWithoutBlocking() throws {
        // A 4-byte length prefix above the cap must be rejected before any body
        // read (otherwise a hostile peer could ask us to allocate/await 4 GiB).
        let (a, b) = try makePair()
        defer { closeAll(a, b) }

        var len = UInt32(UnixSocketTransport.maxFrameSize + 1).bigEndian
        let prefix = Data(bytes: &len, count: 4)
        _ = prefix.withUnsafeBytes { Darwin.write(a, $0.baseAddress, $0.count) }

        let start = Date()
        XCTAssertNil(UnixSocketTransport.readFrame(b))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "oversized frames must fail fast")
    }

    func testPartialWritesAreReassembled() throws {
        let (a, b) = try makePair()
        defer { closeAll(a, b) }

        let payload = Data("split-across-writes".utf8)
        var len = UInt32(payload.count).bigEndian
        let prefix = Data(bytes: &len, count: 4)
        // Two separate syscalls = a half frame on the wire.
        _ = prefix.withUnsafeBytes { Darwin.write(a, $0.baseAddress, 2) }
        _ = prefix.withUnsafeBytes { Darwin.write(a, $0.baseAddress! + 2, 2) }
        _ = payload.withUnsafeBytes { Darwin.write(a, $0.baseAddress, 3) }
        _ = payload.withUnsafeBytes { Darwin.write(a, $0.baseAddress! + 3, payload.count - 3) }

        XCTAssertEqual(UnixSocketTransport.readFrame(b), payload)
    }

    func testEOFBeforeFullFrameReturnsNil() throws {
        let (a, b) = try makePair()
        defer { closeAll(a, b) }

        var len = UInt32(64).bigEndian
        let prefix = Data(bytes: &len, count: 4)
        _ = prefix.withUnsafeBytes { Darwin.write(a, $0.baseAddress, $0.count) }
        _ = Data("only-a-few-bytes".utf8).withUnsafeBytes { Darwin.write(a, $0.baseAddress, $0.count) }
        Darwin.close(a)  // EOF mid-frame

        XCTAssertNil(UnixSocketTransport.readFrame(b))
    }

    // MARK: - H1: real deadlines

    func testStalledPeerHitsSocketTimeoutInsteadOfHanging() throws {
        let (a, b) = try makePair()
        defer { closeAll(a, b) }

        // Only part of the length prefix is written, then the peer goes quiet.
        var len = UInt32(16).bigEndian
        let prefix = Data(bytes: &len, count: 4)
        _ = prefix.withUnsafeBytes { Darwin.write(a, $0.baseAddress, 2) }

        let start = Date()
        XCTAssertNil(UnixSocketTransport.readFrame(b, timeout: 0.3), "a stalled peer must time out")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 3.0, "read must return within the deadline (elapsed \(elapsed)s)")
    }

    func testStalledHandshakeBodyTimesOut() throws {
        let (a, b) = try makePair()
        defer { closeAll(a, b) }

        // Complete length prefix claiming 32 bytes, then send none of them.
        var len = UInt32(32).bigEndian
        let prefix = Data(bytes: &len, count: 4)
        _ = prefix.withUnsafeBytes { Darwin.write(a, $0.baseAddress, $0.count) }

        let start = Date()
        XCTAssertNil(UnixSocketTransport.readFrame(b, timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.0)
    }

    /// The deadline must hold even when no socket option was applied at all —
    /// this is exactly the state the code was in before H1 was fixed.
    func testDeadlineHoldsWithoutAnySocketOptions() throws {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress) }
        XCTAssertEqual(rc, 0)
        let (a, b) = (fds[0], fds[1])
        defer { closeAll(a, b) }

        var len = UInt32(16).bigEndian
        let prefix = Data(bytes: &len, count: 4)
        _ = prefix.withUnsafeBytes { Darwin.write(a, $0.baseAddress, 1) }

        let start = Date()
        XCTAssertNil(UnixSocketTransport.readFrame(b, timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.0, "poll() — not setsockopt — must enforce the deadline")
    }

    /// Writing to a peer that already closed must fail, not kill the process
    /// with SIGPIPE (the test process surviving IS the assertion).
    func testWriteToClosedPeerFailsInsteadOfCrashing() throws {
        let (a, b) = try makePair()
        defer { closeAll(a, b) }

        Darwin.close(b)

        // A closed socketpair end may surface as EPIPE (or ECONNRESET); either
        // way the call must return false and we must still be running.
        XCTAssertFalse(UnixSocketTransport.writeFrame(a, payload: Data(repeating: 0x7F, count: 4096)))
    }

    func testSetSocketTimeoutsReturnsTrueOnARealSocket() throws {
        let (a, b) = try makePair()
        defer { closeAll(a, b) }
        XCTAssertTrue(UnixSocketTransport.setSocketTimeouts(fd: a))
    }

    // MARK: - Listener hygiene (H2)

    func testListenRefusesToRemoveANonSocketFile() throws {
        let dir = try makeShortTempDir("mr-t")
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("ipc.sock")
        try Data("not a socket".utf8).write(to: path)

        let result = UnixSocketTransport.listen(on: path)
        XCTAssertLessThan(result.fd, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "the unrelated file must be left alone")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "not a socket")
    }

    func testListenCleansAStaleSocketAndChmodsIt() throws {
        let dir = try makeShortTempDir("mr-t")
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("ipc.sock")

        // A crashed instance: bind + listen + close, leaving the file behind.
        let stale = UnixSocketTransport.listen(on: path)
        XCTAssertGreaterThanOrEqual(stale.fd, 0)
        UnixSocketTransport.closeListener(fd: stale.fd, socketURL: URL(fileURLWithPath: "/nonexistent")) // close fd, keep file
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))

        let fresh = UnixSocketTransport.listen(on: path)
        XCTAssertGreaterThanOrEqual(fresh.fd, 0, "a stale socket file must be replaceable: \(fresh.error ?? "")")
        XCTAssertEqual(try socketMode(at: path), 0o600, "the socket file must be 0600")
        UnixSocketTransport.closeListener(fd: fresh.fd, socketURL: path)
    }

    func testListenRefusesWhenAnotherListenerIsLive() throws {
        let dir = try makeShortTempDir("mr-t")
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("ipc.sock")
        let first = UnixSocketTransport.listen(on: path)
        XCTAssertGreaterThanOrEqual(first.fd, 0)
        defer { UnixSocketTransport.closeListener(fd: first.fd, socketURL: path) }

        let second = UnixSocketTransport.listen(on: path)
        XCTAssertLessThan(second.fd, 0, "a live listener must never be clobbered")
        XCTAssertTrue((second.error ?? "").contains("already running"))
    }

    /// AF_UNIX `sun_path` is only 104 bytes on macOS, and the App Group path in
    /// production is short — so tests must not use the long per-user temp path.
    private func makeShortTempDir(_ prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func socketMode(at url: URL) throws -> mode_t {
        var st = stat()
        XCTAssertEqual(lstat(url.path, &st), 0)
        return st.st_mode & 0o777
    }
}

/// Minimal thread-safe box for a value produced on a background queue.
private final class Locked<T> {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}
