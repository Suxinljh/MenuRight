import Foundation

/// One entry of the menu bar item.
///
/// It exists as a value type instead of an inline button because the *order* of
/// the menu is a user-visible contract (打开设置 → 检查更新 → 分隔线 → 退出) and
/// because "退出" carries the lifecycle rule the whole item exists for: the main
/// app has to stay alive after its window closes, otherwise every Finder menu
/// action fails with "主应用未运行". `StatusMenuTests` pins both without an app
/// host.
enum StatusMenuCommand: String, CaseIterable {
    case openSettings
    case checkForUpdates
    case quit

    /// The same two-language catalog the settings UI uses, so a new command
    /// without a translation fails `LocalizationTests` instead of shipping a raw
    /// identifier as a menu title.
    var titleKey: StringKey {
        switch self {
        case .openSettings: return .statusMenuOpenSettings
        case .checkForUpdates: return .statusMenuCheckForUpdates
        case .quit: return .statusMenuQuit
        }
    }
}

/// One row of the menu: a command, or the separator above 退出.
enum StatusMenuEntry: Equatable {
    case command(StatusMenuCommand)
    case separator
}

enum StatusMenuPlan {
    /// 打开设置 / 检查更新 / ─── / 退出
    static let entries: [StatusMenuEntry] = [
        .command(.openSettings),
        .command(.checkForUpdates),
        .separator,
        .command(.quit),
    ]

    /// Every command the menu carries, in order. Used by the tests to prove no
    /// `StatusMenuCommand` case was forgotten when one is added.
    static var commands: [StatusMenuCommand] {
        entries.compactMap { entry in
            guard case .command(let command) = entry else { return nil }
            return command
        }
    }
}

/// The icon the status item shows.
///
/// The brand mark (`top-bar-logo.svg`, committed in
/// `BrandAssets.xcassets/top-bar-logo.imageset`). It is the one brand asset drawn
/// as a **template**: the system tints status items with the menu bar's own
/// colour, so the artwork's white fills cannot survive there — and a white glyph
/// on a light menu bar would be invisible. `Scripts/check-icons.sh` asserts the
/// asset is still in the catalog and still a template.
enum StatusMenuIcon {
    static let assetName = "top-bar-logo"

    /// Only used if the catalog asset is ever dropped. A status item with no
    /// image is an invisible click target, which is worse than the wrong glyph.
    static let fallbackSymbolName = "contextualmenu.and.cursorarrow"

    /// Menu bar sizes are stated in points and every system item sits at roughly
    /// 16×16 inside its slot; a 120×120 SVG left at its intrinsic size would
    /// stretch the menu bar.
    static let pointSize: CGFloat = 16
}

/// What a manual check started from the menu bar has to report.
///
/// `.updateAvailable` is deliberately absent: that path reuses `UpdatePrompter`,
/// which already owns 前往下载 / 跳过此版本 / 稍后. The two cases here are the ones
/// the settings pane renders *inline* — from the menu bar there is no pane to
/// write into, so they have to become an alert. Reporting nothing on a failure
/// is exactly the silent behaviour the manual path exists to avoid.
enum StatusMenuUpdateOutcome: Equatable {
    case nothing
    case upToDate(running: String)
    case failed(message: String)

    static func make(from state: UpdateChecker.State) -> StatusMenuUpdateOutcome {
        switch state {
        case .upToDate(let version):
            return .upToDate(running: version)
        case .failed(let message):
            return .failed(message: message)
        case .updateAvailable, .idle, .checking:
            return .nothing
        }
    }
}