import Foundation
import AppKit

/// Hand-off of paths to Terminal.
///
/// ## Why this uses a Service instead of launching Terminal (spike S1, measured)
///
/// `NSWorkspace.open(_:withApplicationAt:configuration:)` is **denied inside the
/// App Sandbox**: LaunchServices returns
/// `NSCocoaErrorDomain 256` / `NSOSStatusErrorDomain -54 (permErr)`, with
/// `_LSOpenStuffCallLocal` in the backtrace. That is a sandbox restriction on
/// launching an explicit application, not a permissions problem with the folder.
///
/// Terminal's Finder service "New Terminal at Folder" is. It runs inside
/// Terminal itself, which is not sandboxed, so the app only has to put the
/// folder on a pasteboard and ask the Services infrastructure to run the
/// service (`NSPerformService`). Verified end-to-end on macOS 26.6.1: the
/// resulting shell's working directory is the requested folder.
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

    /// Terminal's Finder service. `NSPerformService` matches the service's
    /// default (English) title even on a localized system: measured on a
    /// zh-Hans-CN machine, where this returned true and the localized variant
    /// returned false.
    static let terminalFolderServiceName = "New Terminal at Folder"

    /// Production implementation.
    ///
    /// Primary: Terminal's "New Terminal at Folder" service, which is the only
    /// route the sandbox permits (see the type documentation). Fallback: ask
    /// LaunchServices to launch Terminal directly — allowed outside the sandbox
    /// (e.g. a future non-sandboxed build or an unsandboxed test host), denied
    /// inside it.
    static func openInTerminal(_ directory: URL) -> Error? {
        if performTerminalFolderService(directory) == nil {
            return nil
        }
        // The service is missing or refused. A non-sandboxed context can still
        // launch Terminal directly, so try that before reporting failure.
        let directError = launchTerminalDirectly(directory)
        if directError == nil {
            return nil
        }
        // Both routes failed. Report the actionable one (the missing/refused
        // service) and append the direct-route reason, which inside the sandbox
        // is always the `permErr -54` denial - useful in a log, confusing on its
        // own as a user-facing message.
        return NSError(
            domain: errorDomain,
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: "Terminal's \"New Terminal at Folder\" service is not available. "
                    + "Enable it in System Settings > Keyboard > Keyboard Shortcuts > Services. "
                    + "(Direct launch also failed: \(directError?.localizedDescription ?? "unknown"))"
            ]
        )
    }

    /// Puts `directory` on a **private** pasteboard and runs Terminal's service.
    ///
    /// `NSPerformService` touches AppKit/Services state, so it is performed on
    /// the main thread. The caller is an IPC connection queue, so this hops
    /// there and waits (bounded) rather than blocking the main thread or
    /// assuming the caller's thread. A private pasteboard is used so the user's
    /// clipboard is never clobbered.
    static func performTerminalFolderService(_ directory: URL) -> Error? {
        let box = ErrorBox()
        let semaphore = DispatchSemaphore(value: 0)
        let run = {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("xin.ljhsu.MenuRight.openTerminal"))
            pasteboard.clearContents()
            guard pasteboard.writeObjects([directory as NSURL]) else {
                box.set(NSError(
                    domain: errorDomain,
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Could not hand the folder to the Services infrastructure."]
                ))
                semaphore.signal()
                return
            }
            guard NSPerformService(terminalFolderServiceName, pasteboard) else {
                box.set(NSError(
                    domain: errorDomain,
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Terminal's \"New Terminal at Folder\" service is not available."]
                ))
                semaphore.signal()
                return
            }
            box.set(nil)
            semaphore.signal()
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
            if semaphore.wait(timeout: .now() + 5) == .timedOut {
                return NSError(
                    domain: errorDomain,
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out asking Terminal to open a window."]
                )
            }
        }
        return box.get()
    }

    /// Direct LaunchServices hand-off. Denied by the App Sandbox (permErr -54),
    /// kept as a fallback for non-sandboxed contexts.
    private static func launchTerminalDirectly(_ directory: URL) -> Error? {
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
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Timed out asking LaunchServices to open Terminal."]
            )
        }
        return box.get()
    }

    static let system = SystemOpener(openTerminal: openInTerminal)
}

/// Lock-protected error hand-off from the LaunchServices completion handler and
/// from the main-thread service hop.
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
