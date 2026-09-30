import Foundation
import Darwin
import os

/// Shared constants and the diagnostic channel for the FinderSync extension ↔
/// main app IPC.
///
/// Transport: App-Group Unix domain socket (P5-0.6). The retired
/// `NSXPCListenerEndpoint` bootstrap (P5-0 / P5-0.5) is gone because
/// `NSXPCListenerEndpoint.encodeWithCoder:` hard-throws on macOS 26 outside an
/// `NSXPCCoder`. Both `ping` (diagnostic) and `fileOperation` (**P5-1**, real
/// delegation) are implemented over this transport.
///
/// Protection model for the socket (no longer "the sandbox boundary is
/// enough"):
///   1. the socket file is created inside the App Group container and
///      `chmod`ed to 0600 after `bind()`;
///   2. the main app verifies the connecting peer's code signature against the
///      extension's designated requirement;
///   3. the extension verifies the listening peer's code signature against the
///      main app's designated requirement before sending anything, because any
///      same-user process can unlink the socket file and bind its own path.
public enum MenuRightIPC {
    /// Subsystem name used by all IPC-related log lines.
    public static let subsystem = "xin.ljhsu.MenuRight"

    /// App Group shared by the app and its Finder Sync extension. Single source
    /// of truth for the container identifier — the socket and the
    /// folder-authorization store must always live in the same container.
    public static let appGroupIdentifier = "group.xin.ljhsu.MenuRight"

    /// App-Group Unix domain socket filename. The main app binds and listens
    /// here; the extension connects to it.
    public static let socketFilename = "ipc.sock"

    /// Diagnostic log filename inside the App Group container. BOTH the main
    /// app and the extension append lifecycle events here. Survives process
    /// death and is readable from the shell (sandbox-safe).
    public static let diagnosticsFilename = "bootstrap-diagnostics.log"

    /// Returns the URL of the App-Group Unix socket, or nil if the App Group
    /// container is unavailable.
    public static func socketFileURL() -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        else { return nil }
        return container.appendingPathComponent(socketFilename)
    }

    /// The `.app` bundle that contains an app extension, derived from the
    /// extension's own bundle URL.
    ///
    /// Used by the extension to learn the **exact path of the main app's
    /// executable**: inside the extension's sandbox the code-signing APIs are
    /// unavailable (measured: OSStatus 100001 for both the live and the static
    /// API), so the peer is checked by comparing the kernel-reported executable
    /// path against this value instead.
    ///
    /// Note the trailing slash: `Bundle.main.bundleURL` ends with one, and
    /// `deletingLastPathComponent()` on `…/X.appex/` yields `…/PlugIns/`, so the
    /// URL is normalized first. (That trailing slash is not theoretical - it
    /// silently produced `nil` here and disabled the check.)
    public static func containingAppBundleURL(forExtensionBundleAt extensionBundle: URL) -> URL? {
        var url = URL(fileURLWithPath: extensionBundle.path)   // drops any trailing slash
        guard url.pathExtension == "appex" else { return nil }
        // …/MenuRight.app/Contents/PlugIns/MenuRightFinder.appex -> …/MenuRight.app
        url = url.deletingLastPathComponent()   // …/PlugIns
        url = url.deletingLastPathComponent()   // …/Contents
        url = url.deletingLastPathComponent()   // …/MenuRight.app
        guard url.pathExtension == "app" else { return nil }
        return url
    }

    /// The main executable path implied by the standard bundle layout
    /// (`<App>.app/Contents/MacOS/<App>`).
    ///
    /// Needed because an extension's sandbox may deny reading the *containing
    /// app's* Info.plist, which makes `Bundle(url:)?.executableURL` nil even
    /// though the bundle path itself is derivable. Our products follow the
    /// standard layout (`PRODUCT_NAME = MenuRight`).
    public static func conventionalExecutablePath(forAppBundleAt appBundle: URL) -> String {
        let executableName = appBundle.deletingPathExtension().lastPathComponent
        return appBundle.appendingPathComponent("Contents/MacOS/\(executableName)").path
    }

    /// Returns the file URL of the diagnostics log inside the App Group
    /// container, or nil if the App Group is unavailable.
    public static func diagnosticsFileURL() -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        else { return nil }
        return container.appendingPathComponent(diagnosticsFilename)
    }
}

/// Lifecycle / IPC diagnostics — writes structured records to BOTH the system
/// log and the App-Group diagnostics file. Used to prove that lifecycle hooks
/// actually fire, that the right binary is running, and that the IPC server
/// was instantiated by a stable owner.
public enum LifecycleDiagnostics {
    public static let log = Logger(subsystem: MenuRightIPC.subsystem, category: "lifecycle")

    /// Hard cap for the diagnostics file. Once it grows past this, it is
    /// rotated once to `bootstrap-diagnostics.log.1` (the previous `.1` is
    /// replaced). Without a cap this file grows forever on every IPC call.
    public static let maxFileBytes: Int64 = 1024 * 1024

    public static func record(_ event: String, from source: String) {
        let pid = getpid()
        let execPath = String(cString: _dyld_get_image_name(0))
        let bundlePath = Bundle.main.bundlePath
        let line = "\(Date().ISO8601Format()) pid=\(pid) source=\(source) event=\(event) exec=\(execPath) bundle=\(bundlePath)\n"

        // 1) System log via os_log (subsystem: xin.ljhsu.MenuRight)
        log.info("\(line, privacy: .public)")

        // 2) App Group diagnostics file (sandbox-safe, survives death)
        guard let url = MenuRightIPC.diagnosticsFileURL(),
              let data = line.data(using: .utf8) else { return }
        append(data, to: url)
    }

    /// Appends one line using `O_APPEND` so concurrent writers (app + extension)
    /// never truncate or interleave a single small write. The previous fallback
    /// used `Data.write(to:)`, which *replaces* the file and silently discarded
    /// the whole history.
    private static func append(_ data: Data, to url: URL) {
        rotateIfNeeded(url)

        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }  // os_log already has the line
        defer { Darwin.close(fd) }

        data.withUnsafeBytes { raw -> Void in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, base + sent, raw.count - sent)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    /// Size check happens before the fd is opened: rotating an open descriptor
    /// would keep appending to the renamed file. Best-effort under concurrency
    /// (advisory, not a lock); worst case a line lands in the rotated file.
    private static func rotateIfNeeded(_ url: URL) {
        var st = stat()
        guard stat(url.path, &st) == 0, st.st_size > maxFileBytes else { return }
        let rotated = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        do {
            try FileManager.default.moveItem(at: url, to: rotated)
            log.notice("diagnostics log rotated: \(url.lastPathComponent, privacy: .public) exceeded \(maxFileBytes, privacy: .public) bytes")
        } catch {
            log.error("diagnostics log rotation failed: \(String(describing: error), privacy: .public)")
        }
    }
}
