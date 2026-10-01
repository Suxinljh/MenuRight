import Foundation

/// Live progress and control for one in-flight archive operation.
///
/// The Main App runs the work and the Finder extension owns the window, and the
/// two only talk over the App-Group socket. So an operation needs a place to hold
/// "where am I" and "did the user press 暂停/取消" that both sides can touch:
///
///   * the **worker** (Main App) calls `checkpoint()` between entries and
///     `report(_:)` as bytes and entries are consumed;
///   * the **server** forwards `report` values down the connection as progress
///     frames;
///   * the **extension** flips `pause()`/`resume()`/`cancel()` through a control
///     message, which lands here and is seen by the next `checkpoint()`.
///
/// Granularity is one entry, because the ZIP writer consumes each entry in one
/// deflate call. Pause and cancel therefore take effect *between* files: a single
/// multi-gigabyte file will not react until it is done. Saying that out loud
/// matters more than pretending otherwise.
///
/// `@unchecked Sendable`: every mutable field is read and written under `lock`,
/// and `progressHandler` is only ever installed before the work starts.
final class ArchiveOperationControl: @unchecked Sendable {
    enum State: Equatable {
        case running
        case paused
        case cancelled
    }

    private let lock = NSLock()
    private var state: State
    private var progressHandler: ((Double) -> Void)?

    init(cancelled: Bool = false) {
        state = cancelled ? .cancelled : .running
    }

    var currentState: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    var isCancelled: Bool { currentState == .cancelled }
    var isPaused: Bool { currentState == .paused }

    /// Set once, before the work starts.
    func onProgress(_ handler: @escaping (Double) -> Void) {
        lock.lock(); defer { lock.unlock() }
        progressHandler = handler
    }

    func pause() {
        lock.lock(); defer { lock.unlock() }
        if state == .running { state = .paused }
    }

    func resume() {
        lock.lock(); defer { lock.unlock() }
        if state == .paused { state = .running }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        state = .cancelled
    }

    /// `0...1`; clamped, and a no-op when nobody is listening.
    func report(_ fraction: Double) {
        lock.lock()
        let handler = progressHandler
        lock.unlock()
        handler?(min(max(fraction, 0), 1))
    }

    /// Called by the worker between entries: throws when cancelled, and blocks
    /// cheaply while paused.
    func checkpoint() throws {
        while true {
            switch currentState {
            case .cancelled:
                throw ArchiveError.cancelled
            case .running:
                return
            case .paused:
                // 50 ms: responsive to a 继续 click without spinning a core.
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
}

/// The set of in-flight archive operations, so a control message arriving on its
/// own connection can find the operation it is about.
///
/// Keyed by the extension's `clientRequestId`: that is the only identifier both
/// sides already agree on, and it is generated per request by the side that owns
/// the window.
final class ArchiveOperationRegistry: @unchecked Sendable {
    static let shared = ArchiveOperationRegistry()

    private let lock = NSLock()
    private var operations: [String: ArchiveOperationControl] = [:]

    func register(_ control: ArchiveOperationControl, as id: String) {
        guard !id.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        operations[id] = control
    }

    func unregister(id: String) {
        lock.lock(); defer { lock.unlock() }
        operations[id] = nil
    }

    func control(for id: String) -> ArchiveOperationControl? {
        lock.lock(); defer { lock.unlock() }
        return operations[id]
    }

    /// Applies a control action. Returns false when no such operation is running,
    /// which the server reports back rather than pretending it worked — a stale
    /// window must not look like a working one.
    @discardableResult
    func apply(_ action: ArchiveControlAction, to id: String) -> Bool {
        guard let control = control(for: id) else { return false }
        switch action {
        case .pause: control.pause()
        case .resume: control.resume()
        case .cancel: control.cancel()
        }
        return true
    }

    /// Test seam.
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        operations.removeAll()
    }
}
