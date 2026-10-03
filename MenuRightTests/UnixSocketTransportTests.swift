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

    /// A slow peer and a dead peer are different situations, and only one of
    /// them is an error. This distinction is what stops a still-working main app
    /// from being reported as "not running" (measured 2026-10-01: a folder
    /// compression outlived the shared 5 s frame budget).
    func testTimedOutIsDistinctFromAClosedPeer() throws {
        let (a, b) = try makePair()
        defer { closeAll(a, b) }

        // Nothing written at all: our deadline passes while the peer is healthy.
        XCTAssertEqual(
            UnixSocketTransport.readFrameResult(b, timeout: 0.2),
            .timedOut,
            "a silent but connected peer is a timeout, not a failure"
        )
    }

    func testPeerThatClosesMidFrameReportsClosed() throws {
        let (a, b) = try makePair()
        defer { closeAll(a, b) }

        var len = UInt32(64).bigEndian
        let prefix = Data(bytes: &len, count: 4)
        _ = prefix.withUnsafeBytes { Darwin.write(a, $0.baseAddress, $0.count) }
        _ = Data("partial".utf8).withUnsafeBytes { Darwin.write(a, $0.baseAddress, $0.count) }
        Darwin.close(a)

        XCTAssertEqual(
            UnixSocketTransport.readFrameResult(b, timeout: 1),
            .closed,
            "EOF before the frame is complete is a closed peer, not a timeout"
        )
    }

    func testCompleteFrameIsReadRegardlessOfTheTimeoutValue() throws {
        let (a, b) = try makePair()
        defer { closeAll(a, b) }

        let payload = Data("payload".utf8)
        var len = UInt32(payload.count).bigEndian
        _ = Data(bytes: &len, count: 4).withUnsafeBytes { Darwin.write(a, $0.baseAddress, $0.count) }
        _ = payload.withUnsafeBytes { Darwin.write(a, $0.baseAddress, $0.count) }

        XCTAssertEqual(UnixSocketTransport.readFrameResult(b, timeout: 1), .frame(payload))
    }

    /// The kernel's `SO_RCVTIMEO` is 5 s and the caller's deadline for a file
    /// operation is ten minutes: a quiet-but-alive peer must keep waiting for the
    /// caller's deadline, not fail when the socket option fires.
    func testQuietPeerIsWaitedOutPastTheSocketReceiveTimeout() throws {
        let (a, b) = try makePair()
        defer { closeAll(a, b) }

        // Shrink the kernel receive timeout so the test does not need 5 s.
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(b, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let payload = Data("late".utf8)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
            var len = UInt32(payload.count).bigEndian
            _ = Data(bytes: &len, count: 4).withUnsafeBytes { Darwin.write(a, $0.baseAddress, $0.count) }
            _ = payload.withUnsafeBytes { Darwin.write(a, $0.baseAddress, $0.count) }
        }

        XCTAssertEqual(
            UnixSocketTransport.readFrameResult(b, timeout: 5),
            .frame(payload),
            "a peer that answers later than SO_RCVTIMEO is slow, not broken"
        )
    }

    /// The budget for a file operation has to stay clear of the generic 5 s frame
    /// default: the reply only arrives once the compression or extraction has
    /// finished. This is the regression guard for the bug measured on 2026-10-01.
    func testFileOperationBudgetIsFarLongerThanTheFrameDefault() {
        XCTAssertGreaterThanOrEqual(
            MenuRightIPC.fileOperationTimeoutSeconds, 300,
            "a file operation cannot be answered within the generic frame budget"
        )
        XCTAssertGreaterThan(
            MenuRightIPC.fileOperationTimeoutSeconds,
            UnixSocketTransport.defaultTimeoutSeconds * 10
        )
    }

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

    // MARK: - Overall read deadline (item 3)

    func testNextFrameTimeoutUsesTheShortFrameBudgetWhileThereIsTime() {
        // A 600 s frame budget inside a 1800 s total: the per-frame timeout is
        // unchanged early on (it still guards a half-written frame).
        XCTAssertEqual(
            UnixSocketTransport.nextFrameTimeout(readTimeout: 600, overallDeadline: 1800, elapsed: 0),
            600
        )
        XCTAssertEqual(
            UnixSocketTransport.nextFrameTimeout(readTimeout: 600, overallDeadline: 1800, elapsed: 1700),
            100,
            "near the total deadline the frame wait must shrink to what is left"
        )
    }

    func testNextFrameTimeoutEndsAtTheOverallDeadline() {
        XCTAssertNil(
            UnixSocketTransport.nextFrameTimeout(readTimeout: 600, overallDeadline: 1800, elapsed: 1800),
            "at the total deadline there is no time left to wait"
        )
        XCTAssertNil(
            UnixSocketTransport.nextFrameTimeout(readTimeout: 600, overallDeadline: 1800, elapsed: 1800.001)
        )
    }

    func testContinuousProgressFramesCannotExtendTheOverallDeadline() {
        // A live peer that keeps sending progress frames restarts the *per-frame*
        // wait every time; the overall cap is recomputed from the wall clock and
        // must therefore fire no matter how many frames arrive. Simulated here
        // rather than with a real socket because peer verification rejects any
        // non-MenuRight peer, so the loop's arithmetic is what can be pinned.
        let readTimeout: TimeInterval = 600
        let overall: TimeInterval = 1800
        var elapsed: TimeInterval = 0
        var frames = 0
        while let timeout = UnixSocketTransport.nextFrameTimeout(
            readTimeout: readTimeout, overallDeadline: overall, elapsed: elapsed
        ) {
            // 每次收到帧只重置「单帧等待」，总预算仍在按墙钟消耗：所以等待时间
            // 只会被总预算压缩，绝不会被后续帧拉回 600s（这正是要防的漏洞）。
            XCTAssertLessThanOrEqual(timeout, readTimeout, "单帧等待不得超过单帧预算")
            XCTAssertGreaterThan(timeout, 0, "总预算未耗尽时总还剩一点可等")
            elapsed += 1
            frames += 1
            if frames > 100_000 {
                XCTFail("the overall deadline never fired")
                break
            }
        }
        XCTAssertEqual(frames, 1800, "the cap must be a hard wall-clock limit, not a frame count")
        XCTAssertGreaterThanOrEqual(elapsed, overall)
    }

    // MARK: - Unverified-connection cap (item 2)

    func testUnverifiedConnectionGateRejectsBeyondTheLimitWithoutDisturbingReservations() {
        let gate = UnverifiedConnectionGate(limit: 3)
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertEqual(gate.current, 3)

        // The fourth connection is refused immediately, and — the point of the
        // test — the three already admitted are untouched.
        XCTAssertFalse(gate.tryAcquire())
        XCTAssertEqual(gate.current, 3)

        // Releasing one frees exactly one slot.
        gate.release()
        XCTAssertEqual(gate.current, 2)
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertFalse(gate.tryAcquire())
    }

    func testUnverifiedConnectionGateReleaseCannotWidenTheCap() {
        let gate = UnverifiedConnectionGate(limit: 1)
        gate.release() // spurious release before any acquire
        XCTAssertEqual(gate.current, 0)
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertFalse(gate.tryAcquire())
        gate.release()
        gate.release() // extra release must not drive the count negative
        XCTAssertEqual(gate.current, 0)
        XCTAssertTrue(gate.tryAcquire(), "the cap must still hold after extra releases")
    }

    func testUnverifiedConnectionGateClampsAZeroLimitToOne() {
        let gate = UnverifiedConnectionGate(limit: 0)
        XCTAssertEqual(gate.limit, 1)
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertFalse(gate.tryAcquire())
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
