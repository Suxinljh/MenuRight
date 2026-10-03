import Foundation
import ServiceManagement

/// "Launch at login" backed by the real system registration (`SMAppService`,
/// macOS 13+). Nothing is simulated: the UI reflects
/// `SMAppService.mainApp.status` and reports failures instead of pretending.
///
/// Registration only succeeds for a copy of the app that the system accepts as
/// a login item (normally the one in /Applications), so an unsigned build run
/// from Xcode surfaces an error rather than silently doing nothing.
///
/// The status is *three-way*, not a `Bool`: `requiresApproval` means "registered,
/// but the user has not allowed it in System Settings yet". The pane shows that
/// state instead of reading it as "off" (see `LaunchAtLoginState`).
enum LaunchAtLogin {
    /// The system's answer, mapped into a `ServiceManagement`-free type.
    static var state: LaunchAtLoginState {
        LaunchAtLoginState(systemStatus: LaunchAtLoginSystemStatus(SMAppService.mainApp.status))
    }

    /// Registers or unregisters the app, skipping redundant calls so the UI can
    /// call this with the value the user just picked.
    static func setEnabled(_ isEnabled: Bool) throws {
        let status = SMAppService.mainApp.status
        if isEnabled {
            // `.enabled` would be the same request twice; `.requiresApproval`
            // still calls `register()` so the system can (re)surface the
            // approval prompt instead of the user being stuck.
            guard status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            // `.enabled` and `.requiresApproval` both describe a registered item,
            // and `unregister()` is what removes it. Skipping `.requiresApproval`
            // here would leave the user unable to switch it back off.
            guard status == .enabled || status == .requiresApproval else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    /// Opens 系统设置 → 通用 → 登录项, the only place a pending approval can be
    /// granted. Available since macOS 13 and the deployment target is 14.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

private extension LaunchAtLoginSystemStatus {
    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        case .notRegistered: self = .notRegistered
        @unknown default: self = .notRegistered
        }
    }
}
