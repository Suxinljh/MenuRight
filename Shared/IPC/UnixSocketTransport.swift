import Foundation
import Darwin
import os

/// Public, App-Group, AF_UNIX, SOCK_STREAM transport. Used by both the main
/// app (listener) and the FinderSync extension (client). No Mach service, no
/// LaunchAgent, no private API.
///
/// Framing: 4-byte big-endian length prefix + UTF-8 JSON payload.
///   - max frame size: 64 KiB (enough for ping/pong; oversized frames are
///     rejected without blocking)
///   - read/write loop: handles partial reads/writes, EINTR, EOF, timeouts
///
/// **Timeouts are enforced before every read/write, not after.** Each loop
/// iteration waits with `poll()` against a wall-clock deadline, so a peer that
/// connects and then stops sending can never block the calling thread inside
/// `read()`. Checking the deadline only *after* `read()` returned — the original
/// H1 defect — cannot bound a call that is blocked in the kernel.
///
/// `SO_RCVTIMEO`, `SO_SNDTIMEO` and `SO_NOSIGPIPE` are still applied as defence
/// in depth (see `setSocketTimeouts`). `SO_NOSIGPIPE` is load-bearing: a peer
/// that closes its end while we are writing must make `write()` fail with
/// `EPIPE`, never deliver SIGPIPE and kill the process.
///
/// Concurrency: each accepted connection runs on a dedicated serial dispatch
/// queue. The main listener thread is non-blocking (`O_NONBLOCK` is set
/// explicitly); `accept()` is wrapped in a `DispatchSourceRead` so it never
/// blocks the main app's run loop.
public enum UnixSocketTransport {
    /// 64 KiB hard cap on a single frame. Anything larger is rejected.
    public static let maxFrameSize = 64 * 1024

    /// Address family constant for AF_UNIX, computed from Darwin so we don't
    /// depend on a private header.
    public static let AF_UNIX: Int32 = Darwin.AF_UNIX

    /// Listen backlog. Small because we only have two peers (main app +
    /// FinderSync).
    public static let listenBacklog: Int32 = 8

    /// Default per-call budget. `poll()` enforces it, so no single
    /// `read()`/`write()` or frame transfer can block longer than this.
    public static let defaultTimeoutSeconds: TimeInterval = 5

    /// Connect budget for the client: the extension must not stall a Finder
    /// menu action.
    public static let connectTimeoutSeconds: TimeInterval = 2

    /// Default per-syscall socket timeout (defence in depth; see
    /// `setSocketTimeouts`).
    public static let defaultTimeout = timeval(tv_sec: 5, tv_usec: 0)

    /// Connect-time socket timeout (defence in depth).
    public static let connectTimeout = timeval(tv_sec: 2, tv_usec: 0)

    private static let log = Logger(subsystem: MenuRightIPC.subsystem, category: "ipc-transport")

    /// File type / ownership of an existing socket path.
    private enum ExistingPathState {
        case absent
        case notASocket
        case wrongOwner(uid_t)
        case liveListener
        case staleSocket
        case unstattable
    }

    // MARK: - Socket options

    /// Applies the per-syscall timeouts and `SO_NOSIGPIPE` to `fd`.
    ///
    /// Returns false when the kernel rejected a timeout (the socket still works,
    /// but the caller must not assume the deadline is enforced).
    @discardableResult
    public static func setSocketTimeouts(
        fd: Int32,
        read: timeval = UnixSocketTransport.defaultTimeout,
        write: timeval = UnixSocketTransport.defaultTimeout
    ) -> Bool {
        var readTimeout = read
        var writeTimeout = write
        var noSigPipe: Int32 = 1
        let tvSize = socklen_t(MemoryLayout<timeval>.size)

        // errno must be captured eagerly: os_log interpolation is evaluated
        // lazily (at emit time), by which point another syscall has reset errno.
        errno = 0
        let readOK = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, tvSize) == 0
        let readErrno = errno
        errno = 0
        let writeOK = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, tvSize) == 0
        let writeErrno = errno
        // Without this, writing to a peer that already closed kills the process
        // with SIGPIPE instead of returning EPIPE.
        errno = 0
        let sigOK = setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE,
            &noSigPipe, socklen_t(MemoryLayout<Int32>.size)
        ) == 0
        let sigErrno = errno

        if !readOK {
            log.notice("SO_RCVTIMEO not applied fd=\(fd) errno=\(readErrno) \(String(cString: strerror(readErrno)), privacy: .public); poll() still enforces the deadline")
        }
        if !writeOK {
            log.notice("SO_SNDTIMEO not applied fd=\(fd) errno=\(writeErrno) \(String(cString: strerror(writeErrno)), privacy: .public); poll() still enforces the deadline")
        }
        if !sigOK {
            // Worth knowing about: without it a write to a closed peer raises SIGPIPE.
            log.error("SO_NOSIGPIPE failed fd=\(fd) errno=\(sigErrno) \(String(cString: strerror(sigErrno)), privacy: .public)")
        }
        return readOK && writeOK
    }

    /// Clears `O_NONBLOCK`. Accepted sockets must be blocking so that
    /// `SO_RCVTIMEO`/`SO_SNDTIMEO` apply (a non-blocking read would return
    /// `EAGAIN` immediately and look like a timeout).
    @discardableResult
    public static func setBlocking(fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0
    }

    /// Sets `O_NONBLOCK` on the listener so `accept()` returns `EAGAIN` instead
    /// of blocking the dispatch queue that drives the read source.
    @discardableResult
    public static func setNonBlocking(fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    // MARK: - Connect / listen

    /// Connect to the App-Group socket. Returns the connected file descriptor
    /// or `nil` (with a reason) on every failure mode. Never throws, never
    /// crashes.
    public static func connect(to url: URL) -> (fd: Int32, error: String?) {
        let path = url.path
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            return (-1, "socket() failed: \(String(cString: strerror(errno)))")
        }
        // Bound both directions before connecting: a peer that accepts and then
        // stops responding must not pin the caller.
        _ = setSocketTimeouts(fd: fd, read: connectTimeout, write: connectTimeout)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            return (-1, "socket path too long: \(pathBytes.count)")
        }
        pathBytes.withUnsafeBufferPointer { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { d in
                    _ = strncpy(d, src.baseAddress, pathBytes.count)
                }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, addrLen)
            }
        }
        if connectResult != 0 {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            return (-1, "connect() failed: \(err)")
        }
        return (fd, nil)
    }

    /// Bind and listen on the App-Group socket. Returns the listening fd or
    /// `nil` (with a reason) on every failure mode.
    ///
    /// Safety properties (H2):
    ///   - a pre-existing path is only removed when it is a socket owned by the
    ///     current user *and* nothing is listening on it (probe connect);
    ///   - the socket file mode is set with `chmod(path, 0o600)` **after**
    ///     `bind()`, because before `bind()` the fd has no filesystem node at
    ///     all (`fchmod` on a pre-bind socket fd is a no-op for the file mode);
    ///   - the listener is non-blocking so the read source's `accept()` loop is
    ///     driven by real `EAGAIN` semantics.
    public static func listen(on url: URL) -> (fd: Int32, error: String?) {
        let path = url.path

        switch inspectExistingPath(at: url) {
        case .notASocket:
            return (-1, "refusing to remove non-socket file at \(path)")
        case .wrongOwner(let owner):
            return (-1, "refusing to remove socket owned by uid \(owner) at \(path)")
        case .liveListener:
            return (-1, "another listener is already running at \(path)")
        case .staleSocket:
            // A crashed previous instance left the file behind; safe to rebind.
            try? FileManager.default.removeItem(at: url)
        case .absent, .unstattable:
            break
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            return (-1, "socket() failed: \(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            return (-1, "socket path too long: \(pathBytes.count)")
        }
        pathBytes.withUnsafeBufferPointer { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { d in
                    _ = strncpy(d, src.baseAddress, pathBytes.count)
                }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, addrLen)
            }
        }
        if bindResult != 0 {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            return (-1, "bind() failed: \(err)")
        }

        // The socket file now exists — this is the first moment chmod can have
        // any effect on its mode. Do not fail the listener when the container
        // refuses the mode change; the peer check on both sides is the primary
        // defence, 0600 is defence in depth.
        if chmod(path, 0o600) != 0 {
            log.error("chmod(0600) on \(path, privacy: .public) failed: \(String(cString: strerror(errno)), privacy: .public)")
        } else if let mode = currentFileMode(at: url), mode != 0o600 {
            log.error("socket mode is \(String(mode, radix: 8), privacy: .public), expected 600")
        }

        if Darwin.listen(fd, listenBacklog) != 0 {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            try? FileManager.default.removeItem(at: url)
            return (-1, "listen() failed: \(err)")
        }
        _ = setSocketTimeouts(fd: fd)
        if !setNonBlocking(fd: fd) {
            log.error("could not set O_NONBLOCK on the listener: \(String(cString: strerror(errno)), privacy: .public)")
        }
        return (fd, nil)
    }

    /// Tear down a listening socket: close the fd and remove the socket file.
    public static func closeListener(fd: Int32, socketURL: URL) {
        Darwin.close(fd)
        try? FileManager.default.removeItem(at: socketURL)
    }

    // MARK: - Framing

    /// Read exactly `n` bytes from `fd`, looping over partial reads and EINTR.
    /// Returns nil on EOF before n bytes arrived, on timeout, or on any
    /// non-recoverable error.
    ///
    /// The deadline is enforced **before** each `read()` with `poll()`, so it
    /// holds even if `SO_RCVTIMEO` could not be applied (e.g. the peer
    /// disconnected in the instant between `accept()` and `setsockopt()`).
    /// Checking only after `read()` returned — the original H1 defect — cannot
    /// bound a call that blocks inside the kernel.
    public static func readExactly(
        _ fd: Int32,
        count: Int,
        timeout: TimeInterval = defaultTimeoutSeconds
    ) -> Data? {
        readExactly(fd, count: count, deadline: Date().addingTimeInterval(timeout))
    }

    private static func readExactly(_ fd: Int32, count: Int, deadline: Date) -> Data? {
        guard count > 0 else { return Data() }
        var buffer = Data(count: count)
        var got = 0
        while got < count {
            guard wait(fd, for: Int16(POLLIN), deadline: deadline) else { return nil }
            let n = buffer.withUnsafeMutableBytes { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress! + got, count - got)
            }
            if n > 0 {
                got += n
            } else if n == 0 {
                return nil  // EOF
            } else {
                if errno == EINTR { continue }
                // EAGAIN from SO_RCVTIMEO, or a non-recoverable error: both are
                // a failed read from the caller's point of view.
                return nil
            }
        }
        return buffer
    }

    /// Write exactly `n` bytes from `data` to `fd`, looping over partial
    /// writes and EINTR. Returns true on success. Bounded by the same deadline
    /// mechanism as `readExactly` (`poll(POLLOUT)`).
    public static func writeExactly(
        _ fd: Int32,
        data: Data,
        timeout: TimeInterval = defaultTimeoutSeconds
    ) -> Bool {
        var sent = 0
        let total = data.count
        let deadline = Date().addingTimeInterval(timeout)
        while sent < total {
            guard wait(fd, for: Int16(POLLOUT), deadline: deadline) else { return false }
            let n = data.withUnsafeBytes { ptr -> Int in
                Darwin.write(fd, ptr.baseAddress! + sent, total - sent)
            }
            if n > 0 {
                sent += n
            } else if n < 0 {
                if errno == EINTR { continue }
                // EAGAIN: send timeout. EPIPE/ECONNRESET: peer went away.
                // SO_NOSIGPIPE guarantees we get here instead of dying.
                return false
            } else {
                return false
            }
        }
        return true
    }

    /// Waits until `fd` is ready for `events` or `deadline` passes.
    /// Returns false on timeout, hangup, or error.
    private static func wait(_ fd: Int32, for events: Int16, deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(min(remaining * 1000, Double(Int32.max)))
            let rc = poll(&pfd, 1, milliseconds)
            if rc > 0 { return true }
            if rc == 0 { return false }  // timeout
            if errno == EINTR { continue }
            return false
        }
    }

    /// Read one length-prefixed frame from `fd`. Returns the payload Data or
    /// nil on EOF, oversized frame, or timeout. The whole frame (prefix + body)
    /// shares one deadline, so a peer that drips bytes cannot extend the budget
    /// indefinitely.
    public static func readFrame(_ fd: Int32, timeout: TimeInterval = defaultTimeoutSeconds) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        guard let lenBytes = readExactly(fd, count: 4, deadline: deadline) else { return nil }
        let len: Int = lenBytes.withUnsafeBytes { ptr -> Int in
            let b = ptr.bindMemory(to: UInt8.self).baseAddress!
            return (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
        }
        if len <= 0 || len > maxFrameSize {
            return nil  // reject oversized or non-positive
        }
        return readExactly(fd, count: len, deadline: deadline)
    }

    /// Write one length-prefixed frame to `fd`. Returns true on success.
    public static func writeFrame(_ fd: Int32, payload: Data, timeout: TimeInterval = defaultTimeoutSeconds) -> Bool {
        if payload.count > maxFrameSize { return false }
        var len = UInt32(payload.count).bigEndian
        let lenData = Data(bytes: &len, count: 4)
        return writeExactly(fd, data: lenData, timeout: timeout)
            && writeExactly(fd, data: payload, timeout: timeout)
    }

    // MARK: - Existing-path inspection

    private static func inspectExistingPath(at url: URL) -> ExistingPathState {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            return errno == ENOENT ? .absent : .unstattable
        }
        let fileType = st.st_mode & mode_t(S_IFMT)
        guard fileType == mode_t(S_IFSOCK) else { return .notASocket }
        guard st.st_uid == geteuid() else { return .wrongOwner(st.st_uid) }

        // A successful connect proves somebody is still listening: never unlink
        // a live socket (that is exactly the hijack primitive we must remove).
        let probe = connect(to: url)
        if probe.fd >= 0 {
            Darwin.close(probe.fd)
            return .liveListener
        }
        return .staleSocket
    }

    private static func currentFileMode(at url: URL) -> mode_t? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return st.st_mode & 0o777
    }
}
