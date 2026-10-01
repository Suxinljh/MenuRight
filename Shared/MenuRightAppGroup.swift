import Foundation

/// The App Group container shared by the app and its extensions.
///
/// Single source of truth for the container identifier: the settings store, the
/// folder-authorization store, the IPC socket and both extensions read this
/// value, so a typo can never split them across two containers. It lives in its
/// own file so the Quick Look extension can compile just this constant instead
/// of the whole IPC layer.
enum MenuRightAppGroup {
    /// Container identifier. Also declared in every target's entitlements.
    static let identifier = "group.xin.ljhsu.MenuRight"

    /// Key of the settings JSON payload inside the group's `UserDefaults`.
    /// `SettingsStore` writes it; the Finder and Quick Look extensions read it.
    static let settingsStorageKey = "xin.ljhsu.MenuRight.settings"

    /// `os_log` subsystem for every process of the product, so a single
    /// `log show --predicate 'subsystem == …'` covers app and extensions.
    static let logSubsystem = "xin.ljhsu.MenuRight"
}
