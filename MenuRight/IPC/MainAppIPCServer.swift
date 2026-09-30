import Foundation
import os

/// **Phase P5-0.6 + P5-1** — App-Group Unix domain socket IPC server running
/// in the main app process.
///
/// Lifecycle: instantiable. Owned strongly by `AppDelegate` for the lifetime
/// of the main app process. Started in `applicationWillFinishLaunching` so
/// the socket is up before SwiftUI's scene graph begins evaluation.
///
/// On `start`:
///   1. Inspect/clean any stale socket file from a previous run (never
///      clobbering a live listener or a file we do not own).
///   2. Bind + listen on the App-Group Unix socket, then `chmod 0600`.
///   3. Hand the non-blocking listener fd to a `DispatchSourceRead`.
///   4. For each accepted connection: apply socket timeouts, verify peer
///      identity against the designated requirement (bundle id + Apple-anchored
///      team), then exchange length-prefixed JSON frames.
///
/// On `stop`:
///   1. Cancel the dispatch source (its cancel handler closes the fd).
///   2. Remove the socket file.
///
/// All lifecycle state below is confined to `acceptQueue`; `start()`/`stop()`
/// are synchronous with respect to that queue, so state written by them is
/// safely visible to the caller once they return. `isRunning` must therefore
/// only be read by the thread that just called `start()`/`stop()`.
///
/// **P5-1** file-operation dispatch:
///   - method `ping` — diagnostic, unchanged.
///   - method `fileOperation` — payload decoded as
///     `FileOperationContract.Request`; dispatched to a
///     `FileOperationDispatcher`. Response is wrapped in
///     `IPCProtocol.Response.result` (or `.error`).
final class MainAppIPCServer: NSObject {
    private static let log = Logger(subsystem: MenuRightIPC.subsystem, category: "main-app-ipc")

    private let socketURL: URL?
    private let fileOpDispatcher: FileOperationDispatcher
    /// Injectable peer gate: production uses `PeerIdentity.verify(fd:)`; tests
    /// inject a stub so the transport/dispatch wiring can be exercised without
    /// a signed FinderSync extension on the other end of the socket.
    private let peerVerifier: (Int32) -> PeerIdentity.Result

    private let acceptQueue = DispatchQueue(label: "MenuRight.IPC.accept")
    private let connectionQueue = DispatchQueue(label: "MenuRight.IPC.connection", attributes: .concurrent)

    /// Confined to `acceptQueue`.
    private var listenSource: DispatchSourceRead?
    /// Confined to `acceptQueue`.
    private var listenFD: Int32 = -1

    private(set) var isRunning: Bool = false

    /// Public initializer. The default dispatcher reads the App-Group
    /// `FolderAuthorizationStore`; tests can inject their own store/config, a
    /// temporary socket path, and a stub peer verifier.
    init(
        socketURL: URL? = MenuRightIPC.socketFileURL(),
        fileOpDispatcher: FileOperationDispatcher = FileOperationDispatcher(),
        peerVerifier: @escaping (Int32) -> PeerIdentity.Result = { PeerIdentity.verify(fd: $0) }
    ) {
        self.socketURL = socketURL
        self.fileOpDispatcher = fileOpDispatcher
        self.peerVerifier = peerVerifier
        super.init()
        Self.log.info("MAIN-IPC server instance created socketURL=\(self.socketURL?.path ?? "<nil>", privacy: .public)")
    }

    /// Bring the listener up. Idempotent — second call is a no-op.
    func start() {
        acceptQueue.sync { self.startLocked() }
    }

    /// Tear down the listener and remove the socket file.
    func stop() {
        acceptQueue.sync { self.stopLocked() }
    }

    // MARK: - Lifecycle (acceptQueue-confined)

    private func startLocked() {
        guard !isRunning else {
            Self.log.info("MAIN-IPC start(): already running; no-op")
            return
        }
        guard let socketURL else {
            Self.log.error("MAIN-IPC start(): no socket URL; App Group unavailable")
            LifecycleDiagnostics.record("MainAppIPCServer.start: SKIP (no socket URL)", from: "main-app")
            return
        }

        let r = UnixSocketTransport.listen(on: socketURL)
        guard r.fd >= 0 else {
            Self.log.error("MAIN-IPC start(): \(r.error ?? "unknown", privacy: .public)")
            LifecycleDiagnostics.record("MainAppIPCServer.start: FAIL (\(r.error ?? "unknown"))", from: "main-app")
            return
        }
        let fd = r.fd

        // Wrap the listener in a DispatchSourceRead so accept() is non-blocking.
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        src.setEventHandler { [weak self] in
            self?.acceptLoop()
        }
        // Capture the fd by value: reading self.listenFD here would close a fd
        // belonging to a *newer* listener after a stop()/start() cycle.
        src.setCancelHandler {
            Darwin.close(fd)
        }
        src.resume()
        listenSource = src
        listenFD = fd
        isRunning = true
        Self.log.info("MAIN-IPC listening on \(socketURL.path, privacy: .public)")
        LifecycleDiagnostics.record("MainAppIPCServer.start OK fd=\(fd) path=\(socketURL.path)", from: "main-app")
    }

    private func stopLocked() {
        guard isRunning else { return }
        listenSource?.cancel()
        listenSource = nil
        listenFD = -1
        if let socketURL {
            try? FileManager.default.removeItem(at: socketURL)
        }
        isRunning = false
        Self.log.info("MAIN-IPC listener stopped")
        LifecycleDiagnostics.record("MainAppIPCServer.stop", from: "main-app")
    }

    /// Accept loop: pull all available connections off the listener fd, hand
    /// each one to a dedicated queue.
    private func acceptLoop() {
        while true {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                Self.log.error("MAIN-IPC accept failed: \(String(cString: strerror(errno)), privacy: .public)")
                return
            }
            // Accepted sockets do not reliably inherit the fd flags, and a
            // non-blocking fd would make SO_RCVTIMEO meaningless. Force
            // blocking mode and install the kernel timeouts before any read.
            _ = UnixSocketTransport.setBlocking(fd: clientFD)
            _ = UnixSocketTransport.setSocketTimeouts(fd: clientFD)

            // Each connection gets its own queue so a slow client doesn't block
            // other clients.
            connectionQueue.async { [weak self] in
                self?.handleConnection(clientFD)
            }
        }
    }

    /// Handle one connection: verify peer identity, read one frame, dispatch
    /// by method, write one response frame, close.
    private func handleConnection(_ fd: Int32) {
        defer { Darwin.close(fd) }

        // Peer identity verification. If rejected, close without replying.
        let peer = peerVerifier(fd)
        switch peer {
        case .rejected(let reason):
            Self.log.notice("MAIN-IPC peer REJECTED: \(reason, privacy: .public)")
            LifecycleDiagnostics.record("connection rejected: \(reason)", from: "main-app")
            return
        case .verified(let v):
            Self.log.info("MAIN-IPC peer OK pid=\(v.pid) uid=\(v.uid) bundleId=\(v.bundleIdentifier, privacy: .public) team=\(v.teamIdentifier, privacy: .public)")
            LifecycleDiagnostics.record("peer verified pid=\(v.pid) uid=\(v.uid) bundleId=\(v.bundleIdentifier) team=\(v.teamIdentifier)", from: "main-app")
        }

        // Read one request frame (bounded by SO_RCVTIMEO).
        guard let reqData = UnixSocketTransport.readFrame(fd) else {
            Self.log.notice("MAIN-IPC no frame received (EOF / timeout / oversized)")
            return
        }
        guard let req = IPCProtocol.decode(IPCProtocol.Request.self, from: reqData) else {
            Self.log.error("MAIN-IPC malformed JSON request (\(reqData.count) bytes)")
            return
        }
        LifecycleDiagnostics.record("request method=\(req.method) id=\(req.id)", from: "main-app")

        // Dispatch by method.
        let response: IPCProtocol.Response
        switch req.method {
        case "ping":
            response = handlePing(req: req)
        case "fileOperation":
            response = handleFileOperation(req: req)
        default:
            response = .fail(id: req.id, error: "unknown method: \(req.method)")
        }

        // Write response.
        if let respData = IPCProtocol.encode(response) {
            _ = UnixSocketTransport.writeFrame(fd, payload: respData)
        }
    }

    /// P5-0.6 ping handler — echoes the payload with main-app metadata.
    private func handlePing(req: IPCProtocol.Request) -> IPCProtocol.Response {
        let payload = req.payload ?? ""
        let result = "pong(=\(payload), from main-app PID=\(getpid()) main-thread=\(Thread.isMainThread))"
        Self.log.info("MAIN-IPC ping received id=\(req.id, privacy: .public) payload=\(payload, privacy: .public); replying \(result, privacy: .public)")
        LifecycleDiagnostics.record("ping received id=\(req.id) payload=\(payload)", from: "main-app")
        return .ok(id: req.id, result: result)
    }

    /// P5-1 file-operation handler. The dispatcher encodes every outcome
    /// (success, partial, authorization error, validation error) into a
    /// `FileOperationContract.Response`. We wrap that in the IPC envelope
    /// — `.result` for success, `.error` for failure — and rely on the
    /// stable error codes for the extension to render UI.
    private func handleFileOperation(req: IPCProtocol.Request) -> IPCProtocol.Response {
        Self.log.info("MAIN-IPC file operation request id=\(req.id, privacy: .public)")
        LifecycleDiagnostics.record("file operation request id=\(req.id)", from: "main-app")
        let response = fileOpDispatcher.dispatch(payload: req.payload)
        switch response {
        case .success(let path):
            Self.log.info("MAIN-FILE-OP success id=\(req.id, privacy: .public) path=\(path ?? "<none>", privacy: .public)")
            LifecycleDiagnostics.record("file operation success id=\(req.id) path=\(path ?? "<none>")", from: "main-app")
            return .ok(id: req.id, result: response.encodedForIPC() ?? "")
        case .batchSuccess(let items):
            Self.log.info("MAIN-FILE-OP batch-success id=\(req.id, privacy: .public) count=\(items.count, privacy: .public)")
            LifecycleDiagnostics.record("file operation batch success id=\(req.id) count=\(items.count)", from: "main-app")
            return .ok(id: req.id, result: response.encodedForIPC() ?? "")
        case .failure(let code, let message):
            Self.log.info("MAIN-FILE-OP failure id=\(req.id, privacy: .public) code=\(code.rawValue, privacy: .public) message=\(message, privacy: .public)")
            LifecycleDiagnostics.record("file operation failure id=\(req.id) code=\(code.rawValue)", from: "main-app")
            // Encode the structured failure inside `.error` so the extension
            // can decode both code and message without parsing strings.
            return .fail(id: req.id, error: response.encodedForIPC() ?? message)
        }
    }
}
