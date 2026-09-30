import Foundation
import AppKit

/// Hand-off of paths/URLs to other applications through LaunchServices.
///
/// A seam with the same shape as `ScopedAccessConfiguration`, so the dispatcher
/// can be unit-tested without actually launching Terminal during a test run.
/// `@unchecked Sendable`: an immutable value type holding a single stored
/// closure, exactly like `ScopedAccessConfiguration`. There is no mutable state
/// to race on; `.system` is a stateless LaunchServices hand-off.
struct SystemOpener: @unchecked Sendable {
    /// Opens `directory` in a new terminal window. Returns nil on success.
    var openTerminal: (URL) -> Error?

    /// Terminal.app locations across macOS versions.
    static let terminalCandidates = [
        "/System/Applications/Utilities/Terminal.app",
        "/Applications/Utilities/Terminal.app",
    ]

    static func defaultTerminalURL() -> URL? {
        terminalCandidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static let errorDomain = "xin.ljhsu.MenuRight.SystemOpener"

    /// Production implementation.
    ///
    /// Blocking on purpose: the IPC dispatcher answers synchronously, so we wait
    /// for LaunchServices with a bounded timeout. This runs on a connection
    /// queue, never on the main thread.
    ///
    /// Sandbox note: the app does not open the directory itself — it hands the
    /// URL to LaunchServices, and Terminal (which is not sandboxed) applies its
    /// own access rules. This is why the operation is not gated on a
    /// security-scoped bookmark; every *mutating* operation still is.
    static func openInTerminal(_ directory: URL) -> Error? {
        guard let terminal = defaultTerminalURL() else {
            return NSError(
                domain: errorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Terminal.app was not found."]
            )
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        // The completion handler runs on an arbitrary queue, so hand the error
        // back through a lock-protected box rather than a captured `var`.
        let box = ErrorBox()
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.open(
            [directory],
            withApplicationAt: terminal,
            configuration: configuration
        ) { _, error in
            box.set(error)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            return NSError(
                domain: errorDomain,
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Timed out asking LaunchServices to open Terminal."]
            )
        }
        return box.get()
    }

    static let system = SystemOpener(openTerminal: openInTerminal)
}

/// Lock-protected error hand-off from the LaunchServices completion handler.
private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        self.error = error
    }

    func get() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}
