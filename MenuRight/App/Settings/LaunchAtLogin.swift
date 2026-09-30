import Foundation
import ServiceManagement

/// "Launch at login" backed by the real system registration (`SMAppService`,
/// macOS 13+). Nothing is simulated: the toggle reflects
/// `SMAppService.mainApp.status` and reports failures instead of pretending.
///
/// Registration only succeeds for a copy of the app that the system accepts as
/// a login item (normally the one in /Applications), so an unsigned build run
/// from Xcode surfaces an error rather than silently doing nothing.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app, skipping redundant calls so the UI can
    /// call this with the value the user just picked.
    static func setEnabled(_ isEnabled: Bool) throws {
        let status = SMAppService.mainApp.status
        if isEnabled {
            guard status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard status == .enabled else { return }
            try SMAppService.mainApp.unregister()
        }
    }
}
