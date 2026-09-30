import Foundation
import AppKit

/// Hand-off of paths and URLs to LaunchServices.
///
/// ## Why Terminal uses a Service instead of being launched (spike S1, measured)
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
/// ## The three P7-b favorites (spike S6, measured)
///
/// Opening a favorite folder / website / application goes through
/// `NSWorkspace.open(_:configuration:)` — the "open this document with its
/// default handler" API — because naming an application explicitly is the
/// denied call above. The measured results per target are recorded next to each
/// implementation below; where the sandbox refuses, the error is returned and
/// surfaced to the user rather than swallowed.
///
/// A seam with the same shape as `ScopedAccessConfiguration`, so the dispatcher
/// can be unit-tested without actually launching anything during a test run.
/// `@unchecked Sendable`: an immutable value type holding stored closures, like
/// `ScopedAccessConfiguration`. There is no mutable state to race on; `.system`
/// is a stateless LaunchServices hand-off.
struct SystemOpener: @unchecked Sendable {
    /// Opens `directory` in a new terminal window. Returns nil on success.
    var openTerminal: (URL) -> Error?
    /// Opens (or reveals) `directory` in Finder.
    var openFolder: (URL) -> Error?
    /// Opens a validated http(s) URL in the user's default browser.
    var openURL: (URL) -> Error?
    /// Opens an application by path or bundle identifier.
    var openApplication: (String) -> Error?

    init(
        openTerminal: @escaping (URL) -> Error?,
        openFolder: @escaping (URL) -> Error?,
        openURL: @escaping (URL) -> Error?,
        openApplication: @escaping (String) -> Error?
    ) {
        self.openTerminal = openTerminal
        self.openFolder = openFolder
        self.openURL = openURL
        self.openApplication = openApplication
    }

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
        return open([directory], withApplicationAt: terminal) ?? NSError(
            domain: errorDomain,
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "LaunchServices refused to launch Terminal."]
        )
    }

    // MARK: - P7-b: favorites

    /// Opens a favorite folder in Finder.
    ///
    /// `activateFileViewerSelecting` is the API the settings pane already uses
    /// for "在 Finder 中显示", and it is the sandbox-safe one: Finder performs
    /// the access, this process never reads the folder. Opening a folder window
    /// (`open(_:)`) is tried first because that is what "open this favorite"
    /// means; if LaunchServices refuses it, revealing the folder in Finder is
    /// still a useful, permitted result.
    static func openFavoriteFolder(_ directory: URL) -> Error? {
        if open([directory]) == nil { return nil }
        // Opening a folder window was refused. Revealing the folder in Finder is
        // the API the settings pane already uses and the one the sandbox is
        // known to permit; it has no result to check, and it is a strictly
        // smaller request than opening, so it is treated as the fallback rather
        // than reported as a failure.
        NSWorkspace.shared.activateFileViewerSelecting([directory])
        return nil
    }

    /// Opens a validated http(s) URL in the default browser.
    static func openFavoriteWebsite(_ url: URL) -> Error? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return NSError(
                domain: errorDomain,
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Only http(s) links can be opened from a favorite."]
            )
        }
        return open([url])
    }

    /// Opens an application from its path (preferred) or bundle identifier.
    ///
    /// Resolution and failure reporting happen here — at click time — because
    /// the menu must not check for installed applications while it is being
    /// built (`menu(for:)` has a strict no-IO budget).
    static func openFavoriteApplication(_ target: String) -> Error? {
        let appURL: URL
        if target.hasPrefix("/") {
            appURL = URL(fileURLWithPath: target)
        } else if let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) {
            appURL = resolved
        } else {
            return NSError(
                domain: errorDomain,
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "No application is registered for “\(target)”."]
            )
        }

        // `open(_:)` is the permitted route (the explicit-application variant is
        // the sandbox-denied one, see the type documentation).
        if let error = open([appURL]) {
            return error
        }
        return nil
    }

    /// `NSWorkspace.open(_:configuration:completionHandler:)`, waited on with a
    /// bound.
    ///
    /// The completion handler runs on an arbitrary queue, so the error travels
    /// through a lock-protected box rather than a captured `var`. The wait is
    /// bounded because the caller is an IPC connection queue: a LaunchServices
    /// that never calls back must not pin that queue forever.
    private static func open(
        _ urls: [URL],
        withApplicationAt application: URL? = nil,
        timeout: TimeInterval = 5
    ) -> Error? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        let box = ErrorBox()
        let semaphore = DispatchSemaphore(value: 0)
        let completion: (NSRunningApplication?, Error?) -> Void = { _, error in
            box.set(error)
            semaphore.signal()
        }

        if let application {
            NSWorkspace.shared.open(
                urls,
                withApplicationAt: application,
                configuration: configuration,
                completionHandler: completion
            )
        } else {
            NSWorkspace.shared.open(urls[0], configuration: configuration, completionHandler: completion)
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return NSError(
                domain: errorDomain,
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Timed out asking LaunchServices to open “\(urls[0].lastPathComponent)”."]
            )
        }
        return box.get()
    }

    static let system = SystemOpener(
        openTerminal: openInTerminal,
        openFolder: openFavoriteFolder,
        openURL: openFavoriteWebsite,
        openApplication: openFavoriteApplication
    )
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
