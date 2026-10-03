import Foundation
import os

/// **Phase P5-0.6 + P5-1** — App-Group Unix domain socket IPC client running
/// in the FinderSync extension.
///
/// Two entry points:
///
/// - `sendPing()` — P5-0.6 diagnostic, unchanged. Echoes the payload with
///   the main app's PID.
/// - `sendFileOperation(_:)` — **P5-1** real delegation. Sends a structured
///   `FileOperationContract.Request` to the Main App. Returns a structured
///   `FileOperationOutcome` that the extension can map directly to user
///   alerts.
///
/// Blocking budget: the connect/handshake socket options use a 2s timeout and
/// every frame transfer is bounded by a `poll()` deadline (5s default), so a
/// stalled or absent peer cannot pin the caller. **File operations are the one
/// exception**: their reply is written only when the work is finished, so they
/// get `MenuRightIPC.fileOperationTimeoutSeconds` instead. A deadline that
/// passes there means "still running", never "the app is gone" — a distinction
/// this type used to lose, and which the UI then reported as the wrong thing.
/// Because *every* progress frame restarts that per-frame deadline, a request
/// additionally carries an overall wall-clock cap (`overallDeadlineSeconds`):
/// without it a peer could stream progress forever and never let the extension
/// return. Callers must still invoke these off the main thread — `FinderSync`
/// does so through its own serial queue — and must return to the main queue
/// before presenting any alert.
///
/// **Peer verification (H2)**: a same-user process can unlink the App-Group
/// socket file and bind its own path. Immediately after `connect()` we verify
/// the connected peer's code signature against the main app's designated
/// requirement (bundle id + team OU) and refuse to send anything if it does not
/// match.
///
/// Failure modes are unified: every transport / protocol / dispatch failure
/// surfaces as `Outcome.unavailable(reason)` so the extension can show a
/// single "Please open MenuRight" message instead of branching on
/// transport details.
final class ExtensionIPCClient {
    private static let log = Logger(subsystem: MenuRightIPC.subsystem, category: "finder-sync-ipc")

    /// Legacy P5-0.6 ping result.
    public enum PingOutcome: Sendable {
        case pong(reply: String)
        case unavailable(reason: String)
    }

    /// **P5-1** file-operation outcome. `success` carries the created path
    /// (for single-target ops) or per-item results (for batch ops). `failure`
    /// carries a stable error code. `unavailable` covers every transport /
    /// protocol failure with a human-readable reason.
    public enum FileOperationOutcome: Sendable {
        case success(createdPath: String?)
        case batchSuccess(items: [FileOperationContract.ItemResult])
        case failure(code: FileOperationContract.ErrorCode, message: String)
        /// The main app took the request and had not answered when our deadline
        /// passed. **Not a failure**: it is normally still working on it. On
        /// 2026-10-01 this was mis-reported as "Menu Right not running" while the
        /// app finished and wrote the archive seconds later.
        case stillRunning
        case unavailable(reason: String)
    }

    /// Path of the main app's executable, derived from our own bundle
    /// (`…/MenuRight.app/Contents/PlugIns/MenuRightFinder.appex` -> `…/MenuRight.app`).
    ///
    /// The extension's sandbox denies the code-signing APIs, so
    /// `PeerIdentity.verify` cannot check the peer's signature from here (it
    /// falls back and logs). The kernel-reported peer path is the check that
    /// *does* work in this sandbox, so we pass the expected path explicitly: an
    /// impostor that binds its own socket must also be running this exact
    /// executable, which requires replacing our installed app bundle.
    private static let expectedMainAppExecutablePath: String? = {
        guard let appBundle = MenuRightIPC.containingAppBundleURL(forExtensionBundleAt: Bundle.main.bundleURL) else {
            log.error("could not derive the containing app bundle from \(Bundle.main.bundleURL.path, privacy: .public)")
            return nil
        }
        // Preferred: ask the bundle. Inside the extension sandbox this can fail
        // (the containing app's Info.plist may be unreadable), so fall back to
        // the standard layout rather than silently disabling the check - which
        // is exactly what happened once and made every request fail.
        if let executable = Bundle(url: appBundle)?.executableURL?.path {
            log.info("expected main-app executable (from bundle): \(executable, privacy: .public)")
            return executable
        }
        let conventional = MenuRightIPC.conventionalExecutablePath(forAppBundleAt: appBundle)
        log.notice("expected main-app executable (bundle unreadable, using layout): \(conventional, privacy: .public)")
        return conventional
    }()

    /// Connect timeout and per-frame deadline shared by all calls.
    private static let connectTimeoutSeconds: timeval = timeval(tv_sec: 2, tv_usec: 0)

    /// Absolute wall-clock cap for one `fileOperation` exchange, progress
    /// frames included.
    ///
    /// The per-frame `readTimeout` only catches a peer that goes *silent*: a
    /// live peer that keeps streaming `progress` frames resets it forever, so a
    /// stuck or hostile main app could hold a Finder Sync call open
    /// indefinitely. 3 × the frame budget (30 min) is far beyond any real
    /// archive — the frame budget alone already tolerates ten minutes of total
    /// silence — yet finite, so the extension always returns to Finder. It is
    /// deliberately larger than the frame budget so ordinary long operations
    /// still end via the normal "still running" path, not this cap.
    private static let overallDeadlineSeconds: TimeInterval = MenuRightIPC.fileOperationTimeoutSeconds * 3

    // MARK: - Public API

    /// P5-0.6 ping.
    static func sendPing(socketURL: URL? = MenuRightIPC.socketFileURL()) -> PingOutcome {
        let payload = "hello-from-ext PID=\(getpid()) ts=\(Date().timeIntervalSince1970)"
        return sendRequest(method: "ping", payload: payload, socketURL: socketURL) { result, error -> PingOutcome in
            if let error { return .unavailable(reason: error) }
            if let result { return .pong(reply: result) }
            return .unavailable(reason: "empty response")
        }
    }

    /// P5-1 file operation. The Main App is the sole writer; if it cannot be
    /// reached the extension shows a clear "Please open MenuRight" error
    /// and does NOT attempt any local write fallback.
    static func sendFileOperation(
        _ request: FileOperationContract.Request,
        socketURL: URL? = MenuRightIPC.socketFileURL(),
        onProgress: ((Double) -> Void)? = nil
    ) -> FileOperationOutcome {
        guard let payload = request.encodedForIPC() else {
            Self.log.error("FINDER-IPC fileOperation encode failed")
            return .unavailable(reason: "encode failed")
        }
        Self.log.info("FINDER-IPC file operation request cid=\(request.clientRequestId ?? "<none>", privacy: .public) kind=\(request.kind.rawValue, privacy: .public)")
        LifecycleDiagnostics.record("file operation request cid=\(request.clientRequestId ?? "<none>") kind=\(request.kind.rawValue)", from: "finder-sync")

        return sendRequest(
            method: "fileOperation",
            payload: payload,
            socketURL: socketURL,
            // File work is answered only when it is done, so it gets the long
            // budget rather than the 5 s frame default (see the constant).
            readTimeout: MenuRightIPC.fileOperationTimeoutSeconds,
            // …and an absolute cap, so continuous progress frames cannot extend
            // the wait forever (see `overallDeadlineSeconds`).
            overallDeadline: Self.overallDeadlineSeconds,
            onTimeout: {
                Self.log.notice("FINDER-IPC file operation still running after \(MenuRightIPC.fileOperationTimeoutSeconds, privacy: .public)s")
                LifecycleDiagnostics.record("file operation still running after \(Int(MenuRightIPC.fileOperationTimeoutSeconds))s", from: "finder-sync")
                return .stillRunning
            },
            onProgress: onProgress
        ) { result, error -> FileOperationOutcome in
            if let error {
                // Server returned an encoded `Response.failure` in the .error field.
                if let response = FileOperationContract.Response.decode(fromIPC: error) {
                    if case .failure(let code, let message) = response {
                        Self.log.info("FINDER-IPC file operation failure code=\(code.rawValue, privacy: .public) message=\(message, privacy: .public)")
                        LifecycleDiagnostics.record("file operation failure code=\(code.rawValue)", from: "finder-sync")
                        return .failure(code: code, message: message)
                    }
                }
                Self.log.notice("FINDER-IPC file operation unavailable: \(error, privacy: .public)")
                LifecycleDiagnostics.record("file operation unavailable: \(error)", from: "finder-sync")
                return .unavailable(reason: error)
            }
            if let result,
               let response = FileOperationContract.Response.decode(fromIPC: result) {
                switch response {
                case .success(let path):
                    Self.log.info("FINDER-IPC file operation success path=\(path ?? "<none>", privacy: .public)")
                    LifecycleDiagnostics.record("file operation success path=\(path ?? "<none>")", from: "finder-sync")
                    return .success(createdPath: path)
                case .batchSuccess(let items):
                    Self.log.info("FINDER-IPC file operation batch-success count=\(items.count, privacy: .public)")
                    LifecycleDiagnostics.record("file operation batch success count=\(items.count)", from: "finder-sync")
                    return .batchSuccess(items: items)
                case .failure(let code, let message):
                    Self.log.info("FINDER-IPC file operation failure code=\(code.rawValue, privacy: .public) message=\(message, privacy: .public)")
                    return .failure(code: code, message: message)
                }
            }
            Self.log.notice("FINDER-IPC file operation: malformed response")
            return .unavailable(reason: "malformed response")
        }
    }

    // MARK: - Transport helper

    /// Generic send/recv for one request/response pair. Returns
    /// `(success: result, failure: error)` from the IPC envelope.
    /// - Parameter overallDeadline: absolute wall-clock cap for the whole read
    ///   loop, progress frames included. Defaults to `readTimeout` because a
    ///   single-frame exchange has no loop to bound; the streaming file
    ///   operation passes its own, longer value.
    private static func sendRequest<T>(
        method: String,
        payload: String?,
        socketURL: URL?,
        readTimeout: TimeInterval = UnixSocketTransport.defaultTimeoutSeconds,
        overallDeadline: TimeInterval = UnixSocketTransport.defaultTimeoutSeconds,
        onTimeout: (() -> T)? = nil,
        onProgress: ((Double) -> Void)? = nil,
        interpret: (_ result: String?, _ error: String?) -> T
    ) -> T {
        guard let socketURL else {
            Self.log.notice("FINDER-IPC App Group container unavailable")
            LifecycleDiagnostics.record("extension: App Group unavailable", from: "finder-sync")
            return interpret(nil, "App Group container unavailable")
        }

        let conn = UnixSocketTransport.connect(to: socketURL)
        guard conn.fd >= 0 else {
            Self.log.notice("FINDER-IPC connect failed: \(conn.error ?? "unknown", privacy: .public)")
            LifecycleDiagnostics.record("extension: connect failed: \(conn.error ?? "unknown")", from: "finder-sync")
            return interpret(nil, conn.error ?? "connect failed")
        }
        defer { Darwin.close(conn.fd) }

        Self.log.info("FINDER-IPC connected to \(socketURL.path, privacy: .public)")

        // Verify the peer BEFORE sending anything. Anyone running as the same
        // user can unlink the socket file and bind their own listener, so a
        // successful connect proves nothing about who is on the other end.
        switch PeerIdentity.verify(
            fd: conn.fd,
            requirement: PeerIdentity.mainAppRequirementString,
            expectedExecutablePath: Self.expectedMainAppExecutablePath
        ) {
        case .rejected(let reason):
            Self.log.notice("FINDER-IPC peer REJECTED: \(reason, privacy: .public)")
            LifecycleDiagnostics.record("extension: peer REJECTED \(reason)", from: "finder-sync")
            return interpret(nil, "peer verification failed")
        case .verified(let peer):
            Self.log.info("FINDER-IPC peer OK pid=\(peer.pid) bundleId=\(peer.bundleIdentifier, privacy: .public) team=\(peer.teamIdentifier, privacy: .public) level=\(peer.verificationLevel.rawValue, privacy: .public)")
            if peer.verificationLevel == .executablePathOnly {
                // Deliberate, bounded downgrade: the appex sandbox denies the
                // code-signing APIs (measured OSStatus 100001), so this is the
                // strongest check available here, not a silent skip. Limits are
                // documented on PeerIdentity.VerificationLevel.
                Self.log.notice("FINDER-IPC peer accepted on executable path only (no signature/team check possible in the appex sandbox); path is exact and same-uid")
                LifecycleDiagnostics.record("extension: peer verified by executable path only (sandbox denies code-signing APIs)", from: "finder-sync")
            } else {
                LifecycleDiagnostics.record("extension: peer verified pid=\(peer.pid)", from: "finder-sync")
            }
        }

        let req = IPCProtocol.Request(method: method, payload: payload)
        guard let reqData = IPCProtocol.encode(req) else {
            return interpret(nil, "encode failed")
        }

        if !UnixSocketTransport.writeFrame(conn.fd, payload: reqData) {
            Self.log.notice("FINDER-IPC write failed")
            LifecycleDiagnostics.record("extension: write failed", from: "finder-sync")
            return interpret(nil, "write failed")
        }

        // Frames keep arriving until the answer does: one carrying `progress` is
        // an interim status ping from a long operation (compression), anything
        // else is the reply. Each read gets the full per-frame budget again —
        // the point of the loop is that a *working* peer is never mistaken for a
        // dead one. `overallDeadline` still caps the whole loop, so a peer that
        // only ever sends progress cannot keep us here forever.
        let readLoopStart = Date()
        while true {
            let elapsed = Date().timeIntervalSince(readLoopStart)
            guard let frameTimeout = UnixSocketTransport.nextFrameTimeout(
                readTimeout: readTimeout, overallDeadline: overallDeadline, elapsed: elapsed
            ) else {
                Self.log.notice("FINDER-IPC overall deadline \(overallDeadline, privacy: .public)s exceeded; giving up on a peer that kept streaming progress")
                LifecycleDiagnostics.record("extension: overall deadline \(Int(overallDeadline))s exceeded", from: "finder-sync")
                return interpret(nil, "overall deadline exceeded")
            }
            switch UnixSocketTransport.readFrameResult(conn.fd, timeout: frameTimeout) {
            case .frame(let respData):
                guard let resp = IPCProtocol.decode(IPCProtocol.Response.self, from: respData) else {
                    Self.log.notice("FINDER-IPC decode failed")
                    LifecycleDiagnostics.record("extension: decode failed", from: "finder-sync")
                    return interpret(nil, "decode failed")
                }
                if let fraction = resp.progress {
                    onProgress?(fraction)
                    continue
                }
                if let err = resp.error {
                    return interpret(nil, err)
                }
                guard let result = resp.result else {
                    return interpret(nil, "empty result")
                }
                return interpret(result, nil)
            case .timedOut:
                // Distinguish "spent the overall cap" from the ordinary per-frame
                // deadline: only the latter means "still running".
                if Date().timeIntervalSince(readLoopStart) >= overallDeadline {
                    Self.log.notice("FINDER-IPC overall deadline \(overallDeadline, privacy: .public)s exceeded")
                    LifecycleDiagnostics.record("extension: overall deadline \(Int(overallDeadline))s exceeded", from: "finder-sync")
                    return interpret(nil, "overall deadline exceeded")
                }
                // The deadline is ours, not the peer's failure: say so, and let the
                // caller decide what a still-running operation means for its UI.
                Self.log.notice("FINDER-IPC read timed out after \(readTimeout, privacy: .public)s")
                LifecycleDiagnostics.record("extension: read timed out after \(Int(readTimeout))s", from: "finder-sync")
                return onTimeout?() ?? interpret(nil, "timed out")
            case .closed, .failed:
                Self.log.notice("FINDER-IPC read failed")
                LifecycleDiagnostics.record("extension: read failed", from: "finder-sync")
                return interpret(nil, "read failed")
            }
        }
    }

    /// Sends 暂停/继续/取消 for an operation that is running right now.
    ///
    /// Its **own** connection on purpose. The data connection is parked waiting
    /// for the answer, so a control frame sent there would not be read until the
    /// work it is meant to interrupt had already finished — a pause button that
    /// does nothing. The Main App serves this concurrently; the reply is a plain
    /// ok/fail, and `false` means no such operation is in flight any more.
    @discardableResult
    static func sendFileOperationControl(
        clientRequestId: String,
        action: ArchiveControlAction,
        socketURL: URL? = MenuRightIPC.socketFileURL()
    ) -> Bool {
        let command = ArchiveControlRequest(clientRequestId: clientRequestId, action: action)
        guard let data = try? JSONEncoder().encode(command),
              let payload = String(data: data, encoding: .utf8) else { return false }
        Self.log.info("FINDER-IPC control \(action.rawValue, privacy: .public) cid=\(clientRequestId, privacy: .public)")
        return sendRequest(method: "fileOperationControl", payload: payload, socketURL: socketURL) { _, error in
            error == nil
        }
    }
}
