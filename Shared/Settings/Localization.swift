import Foundation

/// Every user-visible string of the settings UI **and of the Finder context
/// menu** (the extension compiles this file so both read one catalog).
///
/// Raw values are stable identifiers (never shown); the text lives in
/// `Localization.table`. Keeping both languages in one table makes a missing
/// translation impossible to miss in review, and
/// `LocalizationTests.testEveryKeyHasBothLanguages` enforces it in CI.
enum StringKey: String, CaseIterable {
    // MARK: Sidebar
    case sidebarSectionPermissions
    case sidebarSectionGeneral
    case sidebarVersionLine
    case categoryGeneral
    case categoryFilePermissions
    case categoryFolderPermissions
    case categoryNewFile
    case categoryFavoriteFolders
    case categoryFavoriteApps
    case categoryFavoriteWebsites
    case categoryCodeTheme
    case categoryArchives

    // MARK: Shared controls
    case commonAdd
    case commonRemove
    case commonEdit
    case commonReset
    case commonResetAll
    case commonResetAllMessage
    case commonCancel
    case commonConfirm
    case commonView
    case commonClose
    case commonEmpty
    case commonVersion
    case commonPath
    case commonRefresh
    case onboardingTitle
    case onboardingStepIndicator
    case onboardingSkip
    case onboardingBack
    case onboardingNext
    case onboardingStart
    case onboardingEnableTitle
    case onboardingEnableBody
    case onboardingEnableStatusOn
    case onboardingEnableStatusOff
    case onboardingEnableOpenSettings
    case onboardingEnableHint
    case onboardingBlockedExtension
    case onboardingBlockedFolder
    case onboardingAuthorizeTitle
    case onboardingAuthorizeBody
    case onboardingAuthorizeChoose
    case onboardingAuthorizeCount
    case onboardingReadyTitle
    case onboardingReadyBody
    case onboardingReadyRestartHint
    case commonRestartApp
    case commonRestartAppHint
    case commonRestartFailedTitle
    case commonRestartFailedMessage
    case commonReorderHint
    case commonRevealInFinder
    case commonUnsupported
    case commonLastChecked
    case commonNeverChecked
    case commonMissingOnDisk
    case commonEnabledCount
    case commonMoveUp
    case commonMoveDown

    // MARK: General
    case generalIntro
    case generalLanguage
    case generalLanguageSystem
    case generalLanguageChinese
    case generalLanguageEnglish
    case generalLaunchAtLogin
    case generalLaunchAtLoginError
    case generalLaunchAtLoginRequiresApproval
    case generalLaunchAtLoginOpenSettings
    case generalAbout
    case generalUpdates
    case generalAutoUpdate
    case generalCheckNow
    case generalChecking
    case generalUpdateIdle
    case generalUpToDate
    case generalUpdateAvailable
    case generalUpdateRunningVersion
    case generalUpdateOpenReleasePage
    case generalUpdateSkip
    case generalUpdateFailed
    case generalUpdateNoReleases
    /// The request never left the machine (or never came back): DNS, no route,
    /// interface down. Distinct from a rate limit, which is a *successful*
    /// connection the server refused to answer.
    case generalUpdateOffline
    /// Connected, but GitHub did not answer in time.
    case generalUpdateTimedOut
    /// 403/429 from GitHub's unauthenticated quota, with no reset stamp.
    case generalUpdateRateLimited
    /// Same, but GitHub told us when the quota comes back (`%@` = a clock time).
    case generalUpdateRateLimitedUntil
    // MARK: Terminal (P6 打开终端)
    case generalTerminalTitle
    case generalTerminalFooter
    case generalTerminalDefault
    case generalTerminalChoose
    case generalTerminalReset
    case generalTerminalService
    case generalTerminalServiceFooter
    case generalTerminalMissing
    /// Confirmation shown before a sensitive action (`%@` = the action name).
    case confirmDestructiveTitle
    case confirmDestructiveMessage
    case confirmDestructiveLock
    case confirmDestructiveUnlock
    case confirmDestructiveCut
    case generalLicenses
    case generalLicensesFooter
    case generalLicensesEmpty
    case generalAppName
    case generalWebsite
    case generalWebsiteOpen
    // MARK: Compression dialog (P9 stage 3)
    case archiveCustomTitle
    case archiveSaveAs
    case archiveLabel
    case archiveLabelZipOnly
    case archiveLocation
    case archiveFormat
    case archiveMode
    case archiveEncrypt
    case archiveSplit
    case archiveSolid
    // MARK: How the three compression modes actually differ, per format
    case archiveModeNote
    case archiveSplitOff
    case archiveSplitNote
    case archiveSplitZipOnly
    case archiveSolidNote
    case archiveSolidZipOnly
    case archiveEncryptFormatsNote
    case archiveEncryptSevenZipNote
    case archiveCustomFailed
    // MARK: Encryption and the 密码本 (password book)
    case archivePassword
    case archivePasswordMissing
    case archivePasswordPlaceholder
    case archivePasswordBook
    case archivePasswordBookPick
    case archiveEncryptionNote
    case archiveEncryptionFailed
    case archiveFileNameEncryption
    case archivePasswordBookTitle
    case archivePasswordBookEmpty
    case archivePasswordBookSequence
    case archivePasswordBookName
    case archivePasswordBookImport
    case archivePasswordBookExport
    case archivePasswordBookAutoSave
    case archivePasswordBookStorageFailed
    case archivePasswordBookImported
    case archivePasswordBookExported
    case archivePasswordBookImportFailed
    case archivePasswordBookExportFailed
    case archivePasswordBookExportPlaintextTitle
    case archivePasswordBookExportPlaintextMessage
    case archivePasswordBookImportConfirmTitle
    case archivePasswordBookImportConfirmMessage
    case archivePasswordBookReveal
    case archivePasswordBookHide
    // MARK: Unlocking an encrypted archive for extraction
    case archiveUnlockTitle
    case archiveUnlockMessage
    case archiveUnlockWrongMessage
    case archiveUnlockRemember
    case archiveUnlockExtract
    case archiveUnlockSkipped
    case finderMenuCompressCustom
    case commonChoose
    case archiveModeFast
    case archiveModeStandard
    case archiveModeMaximum
    case generalExtension
    case generalExtensionEnabled
    case generalExtensionDisabled
    case generalExtensionManage
    case generalExtensionCopyWarning
    case generalIPC
    case generalIPCFooter
    case generalIPCNotHealthy
    case generalIPCStarting
    case generalIPCListening
    case generalIPCWaiting
    case generalIPCFailed
    case generalIPCStopped
    case generalResetFooter

    // MARK: File permissions
    case filePermissionIntro
    case filePermissionAllowed
    case filePermissionGroupCreate
    case filePermissionGroupCopy
    case filePermissionGroupOther
    case filePermissionActionCreateFile
    case filePermissionActionCreateFolder
    case filePermissionActionCreateAlias
    case filePermissionActionCutPaste
    case filePermissionActionCopyName
    case filePermissionActionCopyPath
    case filePermissionActionCopyFileURL
    case filePermissionActionLockUnlock
    case filePermissionActionOpenTerminal
    case filePermissionActionExtractArchive
    case filePermissionActionCompressArchive
    case filePermissionActionOpenFavorite
    case filePermissionSafety
    case filePermissionRestrict
    case filePermissionRestrictFooter
    case filePermissionConfirm

    // MARK: Folder permissions
    case folderPermissionIntro
    case folderPermissionAuthorized
    case folderPermissionAdd
    case folderPermissionEmpty
    case folderPermissionStatusAuthorized
    case folderPermissionStatusNeedsReauth
    case folderPermissionStatusUnavailable
    case folderPermissionRemoveTitle
    case folderPermissionRemoveMessage
    case folderPermissionStorageUnavailable
    case folderPermissionFavoritesHint

    // MARK: New file
    case newFileIntro
    case newFileTypes
    case newFileBaseName
    case newFileBaseNameFooter
    case newFilePreview
    case newFileTemplateMissingBadge
    case newFileMissingTemplates
    case newFileTemplateDirectory
    case newFileTemplateDirectoryFooter
    case newFileTemplateDirectoryChoose
    case newFileTemplateDirectoryReset
    case newFileTemplateDirectoryMissing
    case newFileKindText
    case newFileKindMarkdown
    case newFileKindHTML
    case newFileKindCSS
    case newFileKindJavaScript
    case newFileKindJSON
    case newFileKindWord
    case newFileKindExcel
    case newFileKindPowerPoint
    case newFileKindPages
    case newFileKindNumbers
    case newFileKindKeynote

    // MARK: Finder context menu
    //
    // The menu reuses the settings wording where it matches exactly
    // (`categoryNewFile`, `newFileKind*`, the copy/terminal actions) and adds a key
    // only where a menu needs its own, shorter wording. The language is read from
    // the same App Group payload the settings UI writes, so switching the language
    // switches the menu too — see `FinderMenuLanguage`.
    case finderMenuCreateAlias
    case finderMenuLock
    case finderMenuUnlock
    case finderMenuCut
    case finderMenuNewFolder
    case finderMenuPasteHere
    case finderMenuCopyFolderName
    case finderMenuCopyFolderPath
    // MARK: Finder menu — P9 archive actions
    case finderMenuExtract
    case finderMenuExtractHere
    case finderMenuExtractCustom
    /// `%@` is the folder named in 解压位置.
    case finderMenuExtractToFolder
    case finderMenuCompress
    case finderMenuCompressToZip
    case finderMenuCompressToTar
    case finderMenuCompressToTarGz
    case finderMenuCompressToTarBz2

    // MARK: Finder Sync failure prompts (OperationPresenter)
    /// Buttons.
    case presenterOK
    case presenterOpenApp
    /// Main app not running — the only prompt that offers a way out.
    case presenterAppNotRunningTitle
    case presenterAppNotRunningBody
    case presenterAppNotRunningHint
    case presenterDetails
    /// The main app is alive but has not answered a long file operation yet.
    case presenterStillRunningTitle
    case presenterStillRunningBody
    /// Progress notice shown while a delegated operation runs.
    case presenterBusyCompress
    case presenterBusyExtract
    case presenterBusyGeneric
    case presenterBusyBody
    /// The progress notice's only button: hide the notice, keep the work.
    case presenterBusyHide
    /// Progress window: window title, and its 暂停/继续/取消 buttons.
    case presenterProgressTitle
    case presenterProgressExtractTitle
    case presenterProgressPause
    case presenterProgressResume
    case presenterProgressCancel
    case presenterProgressPreparing
    /// Generic failure wording.
    case presenterOperationFailed
    case presenterCouldNotAction
    case presenterCouldNotCreate
    case presenterCouldNotOpen
    case presenterCouldNotMoveOne
    case presenterCouldNotMoveMany
    case presenterAllItemsFailed
    case presenterSomeItemsFailed
    case presenterMoveConflictAll
    case presenterMoveConflictSome
    case presenterMoveFailed
    case presenterOpenFailed
    case presenterFolderAccessTitle
    case presenterFolderAccessBody
    case presenterFolderAccessHint
    case presenterCutFailedTitle
    case presenterCutFailedBody
    case presenterPasteFailedTitle
    case presenterTerminalFailedTitle
    /// The `%@` in `presenterCouldNotAction`, one per delegated action.
    case presenterActionExtract
    case presenterActionCompress
    case presenterActionCreateAlias
    case presenterActionLock
    case presenterActionUnlock

    // MARK: Favorites
    case favoriteFoldersIntro
    case favoriteFoldersAdd
    case favoriteFoldersEmpty
    case favoriteFoldersMissing
    case favoriteAppsIntro
    case favoriteAppsAdd
    case favoriteAppsEmpty
    case favoriteAppsMissing
    case favoriteWebsitesIntro
    case favoriteWebsitesAdd
    case favoriteWebsitesEmpty
    case favoriteWebsitesName
    case favoriteWebsitesURL
    case favoriteWebsitesInvalidURL
    case favoriteWebsitesSheetTitle

    // MARK: Code theme
    case codeThemeIntro
    case codeThemeTheme
    case codeThemePreview
    case codeThemeFontSize
    case codeThemeFont
    case codeThemeFontSystem
    case codeThemeLineNumbers
    case codePreviewLanguage
    case codePreviewPlainText
    case codePreviewUnreadable
    case codePreviewTruncated

    // MARK: Archives
    case archiveIntro
    case archiveFormats
    case archiveFormatZip
    case archiveFormatSevenZip
    case archiveFormatTar
    case archiveFormatGZip
    case archiveFormatBZip2
    case archiveFormatXZ
    case archiveFormatRAR
    case archiveBehavior
    case archiveDestination
    case archiveDestinationAsk
    case archiveDestinationSameFolder
    case archiveDestinationCustom
    case archiveDestinationNotAuthorized
    case archiveDestinationNotAuthorizedDetail
    case archiveConflict
    case archiveConflictKeepBoth
    case archiveConflictSkip
    case archiveConflictOverwrite
    case archiveCleanup
    case archiveSkipMetadata
    case archiveSizeLimit
    case archiveSizeLimitUnit
    /// Shown under the field while the input is fine; names the allowed range.
    case archiveSizeLimitRangeHint
    /// Shown instead as soon as the input is above the maximum.
    case archiveSizeLimitMaxHint
    case archiveSizeLimitMinHint
    case archiveSizeLimitInvalidHint

    // MARK: Menu bar item
    case statusMenuOpenSettings
    case statusMenuCheckForUpdates
    case statusMenuQuit
    case statusMenuUpToDateTitle
    case statusMenuUpToDateBody
    case statusMenuCheckFailedTitle

    // MARK: Alerts
    case errorAlertTitle
}

/// Two-language catalog for `StringKey`.
enum Localization {
    struct Entry {
        let zh: String
        let en: String
    }

    static func text(_ key: StringKey, language: AppLanguage) -> String {
        guard let entry = table[key] else {
            // Never expected (`table` is covered by a unit test); a missing
            // entry degrades to the identifier instead of crashing the UI.
            return key.rawValue
        }
        switch language {
        case .simplifiedChinese:
            return entry.zh
        case .english, .system:
            return entry.en
        }
    }

    // swiftlint:disable:next line_length
    static let table: [StringKey: Entry] = [
        // Sidebar
        .sidebarSectionPermissions: Entry(zh: "权限与安全", en: "Permissions & Security"),
        .sidebarSectionGeneral: Entry(zh: "通用与功能", en: "General & Features"),
        // Sidebar header subtitle. English matches the Figma wording exactly
        // (lowercase "version"), Chinese reads naturally.
        .sidebarVersionLine: Entry(zh: "版本 %@", en: "version %@"),
        .categoryGeneral: Entry(zh: "通用设置", en: "General"),
        .categoryFilePermissions: Entry(zh: "文件权限", en: "File Permissions"),
        .categoryFolderPermissions: Entry(zh: "文件夹权限", en: "Folder Permissions"),
        .categoryNewFile: Entry(zh: "新建文件", en: "New File"),
        .categoryFavoriteFolders: Entry(zh: "常用文件夹", en: "Favorite Folders"),
        .categoryFavoriteApps: Entry(zh: "常用软件", en: "Favorite Apps"),
        .categoryFavoriteWebsites: Entry(zh: "常用网页", en: "Favorite Websites"),
        .categoryCodeTheme: Entry(zh: "代码主题", en: "Code Theme"),
        .categoryArchives: Entry(zh: "解压缩管理", en: "Archive Management"),

        // Shared controls
        .commonAdd: Entry(zh: "添加", en: "Add"),
        .commonRemove: Entry(zh: "删除", en: "Remove"),
        .commonEdit: Entry(zh: "编辑", en: "Edit"),
        .commonReset: Entry(zh: "恢复默认", en: "Reset"),
        .commonResetAll: Entry(zh: "恢复默认设置…", en: "Reset All Settings…"),
        .commonResetAllMessage: Entry(
            zh: "将把全部设置恢复为初始值，此操作不可撤销。",
            en: "This restores every setting to its initial value. It cannot be undone."
        ),
        .commonCancel: Entry(zh: "取消", en: "Cancel"),
        .commonConfirm: Entry(zh: "确定", en: "OK"),
        .commonView: Entry(zh: "查看", en: "View"),
        .commonClose: Entry(zh: "关闭", en: "Close"),
        .commonEmpty: Entry(zh: "暂无内容", en: "Nothing here yet"),
        .commonVersion: Entry(zh: "版本", en: "Version"),
        .commonPath: Entry(zh: "路径", en: "Path"),
        .commonRefresh: Entry(zh: "重新检测", en: "Check Again"),
        // First-run guide (see `OnboardingFlow`).
        .onboardingTitle: Entry(zh: "首次使用引导", en: "Getting Started"),
        .onboardingStepIndicator: Entry(zh: "第 %d 步，共 %d 步", en: "Step %d of %d"),
        .onboardingSkip: Entry(zh: "稍后再说", en: "Not Now"),
        .onboardingBack: Entry(zh: "上一步", en: "Back"),
        .onboardingNext: Entry(zh: "下一步", en: "Next"),
        .onboardingStart: Entry(zh: "开始使用", en: "Start Using MenuRight"),
        .onboardingEnableTitle: Entry(zh: "启用 Finder 扩展", en: "Turn On the Finder Extension"),
        .onboardingEnableBody: Entry(
            zh: "MenuRight 的功能都在 Finder 右键菜单里，因此需要先在系统设置中启用它的扩展。这是本应用需要的唯一系统权限。",
            en: "MenuRight lives in Finder's context menu, so its extension has to be enabled in System Settings first. That is the only system permission the app needs."
        ),
        .onboardingEnableStatusOn: Entry(zh: "扩展已启用", en: "Extension is on"),
        .onboardingEnableStatusOff: Entry(zh: "扩展尚未启用", en: "Extension is off"),
        .onboardingEnableOpenSettings: Entry(zh: "打开系统设置…", en: "Open System Settings…"),
        .onboardingEnableHint: Entry(
            zh: "启用后回到这里即可，状态会自动更新（不需要重启）。",
            en: "Come back to this window afterwards — the status updates by itself, no restart needed."
        ),
        .onboardingBlockedExtension: Entry(
            zh: "需要先启用 Finder 扩展，才能继续。",
            en: "Turn on the Finder extension to continue."
        ),
        .onboardingBlockedFolder: Entry(
            zh: "需要至少授权一个文件夹，才能继续。",
            en: "Authorize at least one folder to continue."
        ),
        .onboardingAuthorizeTitle: Entry(zh: "授权文件夹", en: "Authorize Folders"),
        .onboardingAuthorizeBody: Entry(
            zh: "Finder 扩展没有任何文件写入权限，它只负责发送请求；真正的操作由 MenuRight 在已授权的文件夹内完成。授权会以安全作用域书签保存在 App Group 中，只有主应用会解析它。",
            en: "The Finder extension has no file-write permission — it only sends requests. MenuRight performs the real work inside the folders you authorize, stored as security-scoped bookmarks in the App Group and resolved only by the main app."
        ),
        .onboardingAuthorizeChoose: Entry(zh: "选择文件夹…", en: "Choose Folder…"),
        .onboardingAuthorizeCount: Entry(zh: "已授权 %d 个文件夹", en: "%d folder(s) authorized"),
        .onboardingReadyTitle: Entry(zh: "准备就绪", en: "You’re All Set"),
        .onboardingReadyBody: Entry(zh: "当前状态：", en: "Current status:"),
        .onboardingReadyRestartHint: Entry(
            zh: "设置类改动不需要重启 —— 扩展每次构建右键菜单都会读取最新设置。仅在安装了新构建、需要刷新应用自身状态时才需要重启。",
            en: "Settings changes need no restart: the extension reads the latest settings every time it builds the menu. Restart only after installing a new build, to refresh the app's own state."
        ),

        // Toolbar. The hint states plainly that settings changes need no restart:
        // the extension reads the shared payload every time it builds the menu.
        .commonRestartApp: Entry(zh: "重启 MenuRight", en: "Restart MenuRight"),
        .commonRestartAppHint: Entry(
            zh: "退出并重新启动应用。设置改动不需要重启 —— Finder 扩展每次构建右键菜单都会读取最新设置。",
            en: "Quit and relaunch the app. Settings changes do not need a restart: the Finder extension reads the latest settings every time it builds the menu."
        ),
        // Restarting is a LaunchServices hand-off that can fail (another copy
        // refuses, the bundle moved). Saying so in the window beats a silent no-op.
        .commonRestartFailedTitle: Entry(zh: "无法重启 MenuRight", en: "Couldn’t Restart MenuRight"),
        .commonRestartFailedMessage: Entry(
            zh: "启动新副本失败，请手动退出后重新打开。\n%@",
            en: "Starting a new copy failed. Please quit and reopen the app manually.\n%@"
        ),
        .commonReorderHint: Entry(zh: "拖动可调整顺序", en: "Drag to reorder"),
        .commonRevealInFinder: Entry(zh: "在 Finder 中显示", en: "Reveal in Finder"),
        .commonUnsupported: Entry(zh: "不支持", en: "Not supported"),
        .commonLastChecked: Entry(zh: "上次检测", en: "Last checked"),
        .commonNeverChecked: Entry(zh: "尚未检测", en: "Not checked yet"),
        .commonMissingOnDisk: Entry(zh: "已不在磁盘上", en: "No longer on disk"),
        .commonEnabledCount: Entry(zh: "已启用 %d / %d 项", en: "%d of %d enabled"),
        .commonMoveUp: Entry(zh: "上移", en: "Move Up"),
        .commonMoveDown: Entry(zh: "下移", en: "Move Down"),

        // General
        .generalIntro: Entry(
            zh: "应用信息、界面语言与启动行为。",
            en: "Application info, interface language, and launch behaviour."
        ),
        .generalLanguage: Entry(zh: "界面语言", en: "Language"),
        .generalLanguageSystem: Entry(zh: "跟随系统", en: "Follow System"),
        .generalLanguageChinese: Entry(zh: "简体中文", en: "Simplified Chinese"),
        .generalLanguageEnglish: Entry(zh: "英语", en: "English"),
        .generalLaunchAtLogin: Entry(zh: "登录时自动启动", en: "Launch at Login"),
        .generalLaunchAtLoginError: Entry(
            zh: "无法更新登录项",
            en: "Couldn’t update the login item"
        ),
        // The third state of the login item: registered, but the user has to
        // approve it in System Settings. Never collapse this into "off".
        .generalLaunchAtLoginRequiresApproval: Entry(
            zh: "需要在「系统设置 → 通用 → 登录项」中允许后才能生效。",
            en: "Allow it in System Settings → General → Login Items before it can take effect."
        ),
        .generalLaunchAtLoginOpenSettings: Entry(zh: "打开登录项设置", en: "Open Login Items Settings"),
        .generalAbout: Entry(zh: "关于", en: "About"),
        // Updates
        .generalUpdates: Entry(zh: "更新", en: "Updates"),
        .generalAutoUpdate: Entry(zh: "自动检查更新", en: "Check for Updates Automatically"),
        .generalCheckNow: Entry(zh: "立即检查", en: "Check Now"),
        .generalChecking: Entry(zh: "正在检查…", en: "Checking…"),
        .generalUpdateIdle: Entry(zh: "还没有检查过", en: "Not checked yet"),
        .generalUpToDate: Entry(zh: "已是最新版本（%@）", en: "Up to date (%@)"),
        .generalUpdateAvailable: Entry(zh: "发现新版本 %@", en: "Version %@ is available"),
        .generalUpdateRunningVersion: Entry(
            zh: "当前版本 %@，最新版本 %@。",
            en: "You have %@; the latest version is %@."
        ),
        // The button opens the GitHub release page; this app never downloads the
        // asset itself, so the label must not promise a download.
        .generalUpdateOpenReleasePage: Entry(zh: "前往发布页", en: "View Release Page"),
        .generalUpdateSkip: Entry(zh: "跳过此版本", en: "Skip This Version"),
        .generalUpdateFailed: Entry(zh: "检查更新失败：%@", en: "Update check failed: %@"),
        .generalUpdateNoReleases: Entry(
            zh: "还没有发布任何版本。",
            en: "No release has been published yet."
        ),
        // The three ways a check fails are three different problems for the user:
        // fix the network, wait for the quota, or read the status code. Saying
        // "HTTP 403" to someone whose DNS is down (or the reverse) is what this
        // separation exists to avoid.
        .generalUpdateOffline: Entry(
            zh: "网络不通：连不上 GitHub。请检查网络后重试。",
            en: "No network: GitHub cannot be reached. Check your connection and try again."
        ),
        .generalUpdateTimedOut: Entry(
            zh: "连接 GitHub 超时，请稍后重试。",
            en: "GitHub did not answer in time. Please try again."
        ),
        .generalUpdateRateLimited: Entry(
            zh: "GitHub 的匿名访问次数已达上限（每小时 60 次），请稍后再试。",
            en: "GitHub's unauthenticated rate limit (60 requests per hour) is exhausted. Try again later."
        ),
        .generalUpdateRateLimitedUntil: Entry(
            zh: "GitHub 的匿名访问次数已达上限，约 %@ 之后可重试（每小时 60 次）。",
            en: "GitHub's unauthenticated rate limit is exhausted (60 per hour). Try again after %@."
        ),
        .generalTerminalTitle: Entry(zh: "终端应用", en: "Terminal Application"),
        .generalTerminalFooter: Entry(
            zh: "“打开终端”使用的应用。留空表示系统自带的 Terminal。第三方终端同样通过其 Finder 服务打开，因此需要填写服务名称（在“系统设置 › 键盘 › 键盘快捷键 › 服务”中查看）。",
            en: "The application 打开终端 launches. Leave empty for the built-in Terminal. A third-party terminal is opened through its Finder service, so its service name is required (see System Settings › Keyboard › Keyboard Shortcuts › Services)."
        ),
        .generalTerminalDefault: Entry(zh: "系统默认（Terminal）", en: "System default (Terminal)"),
        .generalTerminalChoose: Entry(zh: "选择…", en: "Choose…"),
        .generalTerminalReset: Entry(zh: "恢复默认", en: "Use Default"),
        .generalTerminalService: Entry(zh: "Finder 服务名称", en: "Finder Service Name"),
        .generalTerminalServiceFooter: Entry(
            zh: "Terminal 的服务名为“New Terminal at Folder”。若已更改系统语言或使用第三方终端，请填写对应名称。",
            en: "Terminal's service is “New Terminal at Folder”. Change it if the system language differs or a third-party terminal is used."
        ),
        .generalTerminalMissing: Entry(
            zh: "所选终端应用不存在，将回退到系统默认。",
            en: "The selected terminal application does not exist; the system default will be used."
        ),
        .confirmDestructiveTitle: Entry(zh: "确认操作", en: "Confirm Action"),
        .confirmDestructiveMessage: Entry(
            zh: "即将执行“%@”。此操作会立即生效。",
            en: "About to perform “%@”. This takes effect immediately."
        ),
        .confirmDestructiveLock: Entry(zh: "锁定所选项目", en: "Lock the selected items"),
        .confirmDestructiveUnlock: Entry(zh: "解锁所选项目", en: "Unlock the selected items"),
        .confirmDestructiveCut: Entry(zh: "将所选项目移动到目标文件夹", en: "Move the selected items to the destination folder"),
        .generalLicenses: Entry(zh: "开源许可", en: "Open Source Licenses"),
        .generalLicensesFooter: Entry(
            zh: "侧边栏图标来自 Lucide（ISC）与 Phosphor（MIT）；解压/压缩使用 SWCompression 与 BitByteData（均为 MIT）；7z 创建使用 PLzmaSDK（MIT，含 LZMA SDK）。",
            en: "Icons come from Lucide (ISC) and Phosphor (MIT); decompression/compression use SWCompression and BitByteData (both MIT); 7z creation uses PLzmaSDK (MIT, with the LZMA SDK)."
        ),
        .generalLicensesEmpty: Entry(
            zh: "应用包内没有找到许可文件。",
            en: "No licence files were found in the app bundle."
        ),
        .generalAppName: Entry(zh: "应用名称", en: "Application"),
        .generalWebsite: Entry(zh: "产品网站", en: "Product Website"),
        .generalWebsiteOpen: Entry(zh: "官网", en: "Website"),
        .archiveCustomTitle: Entry(zh: "自定义压缩", en: "Custom Compression"),
        .archiveSaveAs: Entry(zh: "保存为", en: "Save As"),
        .archiveLabel: Entry(zh: "标签", en: "Label"),
        .archiveLabelZipOnly: Entry(zh: "仅 ZIP 会写入归档注释，其它格式会忽略此标签。", en: "Only ZIP stores an archive comment; other formats ignore this label."),
        .archiveLocation: Entry(zh: "位置", en: "Location"),
        .archiveFormat: Entry(zh: "压缩格式", en: "Format"),
        .archiveMode: Entry(zh: "压缩模式", en: "Mode"),
        .archiveEncrypt: Entry(zh: "加密压缩", en: "Encrypt"),
        .archiveSplit: Entry(zh: "分卷压缩", en: "Split volumes"),
        .archiveSolid: Entry(zh: "固实压缩（仅 7z）", en: "Solid (7-Zip only)"),
        .archiveModeNote: Entry(
            zh: "模式对不同格式作用不同：zip / 7z / tar.gz 用压缩等级（快速=1、标准=6、极限=9），bzip2 用块大小（1 / 5 / 9 × 100 KB），tar 本身不压缩所以模式对它无效。",
            en: "The mode maps to what each format has: zip / 7z / tar.gz use a compression level (Fast 1, Standard 6, Maximum 9), bzip2 uses the block size (1 / 5 / 9 × 100 KB), and tar is uncompressed, so the mode does nothing there."
        ),
        .archiveSplitOff: Entry(zh: "不分卷", en: "Single file"),
        .archiveSplitNote: Entry(
            zh: "分卷把归档切成 name.zip.001、.002 … 每片不超过所选大小；7-Zip、Keka、WinRAR 都能直接打开，本 App 也能解压（选中 .001 即可）。",
            en: "Splitting writes name.zip.001, .002 … with each part under the chosen size; 7-Zip, Keka and WinRAR open the set directly, and so does this app (pick the .001)."
        ),
        .archiveSplitZipOnly: Entry(
            zh: "分卷只支持 ZIP 与 7z——其它格式的 .001 片段没有工具能当成一个归档直接打开。",
            en: "Split volumes work for ZIP and 7z only — a `.001` set of any other format has no unarchiver that reads it as one archive."
        ),
        .archiveSolidNote: Entry(
            zh: "固实把整包压成一个块，体积最小；关掉后每个文件独立压缩，体积略大但可以直接取出单个文件。",
            en: "Solid compresses the whole archive as one block — the smallest result. Turn it off and every file gets its own block: slightly larger, but a reader can pull one file out without unpacking the rest."
        ),
        .archiveSolidZipOnly: Entry(zh: "固实只对 7z 有效。", en: "Solid archives are a 7z feature."),
        .archiveEncryptFormatsNote: Entry(
            zh: "加密只支持 ZIP（传统 ZipCrypto，兼容所有工具但强度有限）与 7z（AES-256）。",
            en: "Encryption is available for ZIP (traditional ZipCrypto: universally readable, but weak) and 7z (AES-256)."
        ),
        .archiveEncryptSevenZipNote: Entry(
            zh: "7z 用 AES-256 加密内容；勾选「加密文件名」会连条目名一起加密，打开前就要密码。密码只写进归档，本机不保存（除非在解压缩管理里打开自动保存）。",
            en: "7z encrypts the content with AES-256; ticking 加密文件名 encrypts the entry names as well, so the password is needed before the list is even shown. The password goes into the archive only; nothing is kept on this Mac unless auto-save is on in Archive Management."
        ),
        .archiveCustomFailed: Entry(zh: "压缩失败", en: "Compression failed"),
        .archivePassword: Entry(zh: "密码", en: "Password"),
        .archivePasswordMissing: Entry(zh: "请输入加密密码。", en: "Enter a password to encrypt with."),
        .archivePasswordPlaceholder: Entry(zh: "输入密码", en: "Enter a password"),
        .archivePasswordBook: Entry(zh: "密码本", en: "Password Book"),
        .archivePasswordBookPick: Entry(zh: "从密码本选择", en: "Choose from the password book"),
        .archiveEncryptionNote: Entry(
            zh: "ZipCrypto 是 ZIP 的传统加密：兼容所有解压工具，但强度有限，只能防误看，不适合保护敏感数据。密码只写进归档，本机不保存（除非在解压缩管理里打开自动保存）。",
            en: "ZipCrypto is ZIP's traditional cipher: every unarchiver opens it, but it is weak — it stops casual looks, not an attacker. The password goes into the archive only; nothing is kept on this Mac unless auto-save is on in Archive Management."
        ),
        .archiveEncryptionFailed: Entry(zh: "加密失败", en: "Encryption failed"),
        .archiveFileNameEncryption: Entry(zh: "加密文件名（仅 7z）", en: "Encrypt file names (7-Zip only)"),
        .archivePasswordBookTitle: Entry(zh: "密码本", en: "Password Book"),
        .archivePasswordBookEmpty: Entry(zh: "还没有保存的密码。", en: "No saved passwords yet."),
        .archivePasswordBookSequence: Entry(zh: "序号", en: "No."),
        .archivePasswordBookName: Entry(zh: "名称", en: "Name"),
        .archivePasswordBookImport: Entry(zh: "批量导入", en: "Import"),
        .archivePasswordBookExport: Entry(zh: "批量导出", en: "Export"),
        .archivePasswordBookAutoSave: Entry(
            zh: "自动保存压缩时输入的加密密码",
            en: "Automatically save passwords typed while compressing"
        ),
        .archivePasswordBookStorageFailed: Entry(zh: "钥匙串写入失败：%@", en: "The Keychain refused the write: %@"),
        .archivePasswordBookImported: Entry(zh: "已导入 %@ 条密码。", en: "Imported %@ passwords."),
        .archivePasswordBookExported: Entry(zh: "已导出 %@ 条密码。", en: "Exported %@ passwords."),
        .archivePasswordBookImportFailed: Entry(zh: "导入失败：%@", en: "Import failed: %@"),
        .archivePasswordBookExportFailed: Entry(zh: "导出失败：%@", en: "Export failed: %@"),
        // The exported JSON is plain text (Keychain encryption does not travel
        // with it), so both directions ask first and say what will happen.
        .archivePasswordBookExportPlaintextTitle: Entry(
            zh: "导出为明文文件？",
            en: "Export as a Plain-Text File?"
        ),
        .archivePasswordBookExportPlaintextMessage: Entry(
            zh: "导出的 JSON 是明文保存的，任何能读取该文件的人都能看到里面的密码。请妥善保管，不要放进共享或同步的目录。",
            en: "The exported JSON is unencrypted: anyone who can read the file can see the passwords in it. Keep it somewhere safe, not in a shared or synced folder."
        ),
        .archivePasswordBookImportConfirmTitle: Entry(zh: "导入密码本？", en: "Import a Password Book?"),
        .archivePasswordBookImportConfirmMessage: Entry(
            zh: "导入会合并到现有密码本：同名的条目会被文件中的密码覆盖，其他条目保留。",
            en: "Importing merges into the current password book: entries with the same name are overwritten by the file, and other entries are kept."
        ),
        .archivePasswordBookReveal: Entry(zh: "显示密码", en: "Show password"),
        .archivePasswordBookHide: Entry(zh: "隐藏密码", en: "Hide password"),
        .archiveUnlockTitle: Entry(zh: "压缩包已加密", en: "This archive is encrypted"),
        .archiveUnlockMessage: Entry(
            zh: "“%@” 已用密码加密。输入密码后才能解压。",
            en: "“%@” is protected by a password. Enter it to extract the archive."
        ),
        .archiveUnlockWrongMessage: Entry(
            zh: "密码不正确，请再试一次。",
            en: "That password was not correct. Please try again."
        ),
        .archiveUnlockRemember: Entry(zh: "把密码存进密码本", en: "Save the password to the password book"),
        .archiveUnlockExtract: Entry(zh: "解压", en: "Extract"),
        .archiveUnlockSkipped: Entry(zh: "（已取消，未解压）", en: "(cancelled, nothing extracted)"),
        .finderMenuCompressCustom: Entry(zh: "自定义压缩…", en: "Custom Compression…"),
        .commonChoose: Entry(zh: "选择…", en: "Choose…"),
        .archiveModeFast: Entry(zh: "快速压缩", en: "Fast"),
        .archiveModeStandard: Entry(zh: "标准压缩", en: "Standard"),
        .archiveModeMaximum: Entry(zh: "极限压缩", en: "Maximum"),
        .generalExtension: Entry(zh: "Finder 扩展", en: "Finder Extension"),
        .generalExtensionEnabled: Entry(zh: "已启用", en: "Enabled"),
        .generalExtensionDisabled: Entry(zh: "未启用", en: "Disabled"),
        .generalExtensionManage: Entry(zh: "管理 Finder 扩展…", en: "Manage Finder Extension…"),
        .generalExtensionCopyWarning: Entry(
            zh: "当前运行的副本不是系统已启用扩展的那一份。请安装并运行已注册的副本（Scripts/install-dev-app.sh）；从 Xcode 运行时这里会显示未启用，而 Finder 加载的是已安装的构建。",
            en: "This copy is not the one the extension is enabled for. Install and run the registered copy (Scripts/install-dev-app.sh) — running from Xcode reports Disabled while Finder loads the installed build."
        ),
        .generalIPC: Entry(zh: "文件操作通道", en: "File Operations Channel"),
        .generalIPCFooter: Entry(
            zh: "Finder 扩展通过 App Group 中的套接字与本应用通信。处于此状态时 Finder 中的操作无法完成。",
            en: "The Finder extension talks to this app over a socket in the shared App Group. While this is not Listening, Finder actions cannot complete."
        ),
        .generalIPCNotHealthy: Entry(
            zh: "通道不可用",
            en: "Channel unavailable"
        ),
        // The IPC status line, localized here so the view does not depend on the
        // English `IPCStatusCenter.displayText` (which stays for logs).
        .generalIPCStarting: Entry(zh: "正在启动…", en: "Starting…"),
        .generalIPCListening: Entry(zh: "正在监听", en: "Listening"),
        .generalIPCWaiting: Entry(
            zh: "等待上一个实例退出（第 %d 次尝试）",
            en: "Waiting for the previous instance to exit (attempt %d)"
        ),
        .generalIPCFailed: Entry(zh: "失败：%@", en: "Failed: %@"),
        .generalIPCStopped: Entry(zh: "已停止", en: "Stopped"),
        .generalResetFooter: Entry(
            zh: "恢复默认只影响本应用的设置，不会移除已经授权的文件夹。",
            en: "Resetting affects settings only; authorized folders are not removed."
        ),

        // File permissions
        .filePermissionIntro: Entry(
            zh: "控制 MenuRight 在 Finder 右键菜单里允许执行的操作：关闭的项不会出现在菜单中。",
            en: "Controls what MenuRight may do from the Finder context menu: disabled items never appear in the menu."
        ),
        .filePermissionAllowed: Entry(zh: "允许的操作", en: "Allowed Actions"),
        .filePermissionGroupCreate: Entry(zh: "创建与修改", en: "Create & Modify"),
        .filePermissionGroupCopy: Entry(zh: "复制", en: "Copy"),
        .filePermissionGroupOther: Entry(zh: "其他", en: "Other"),
        .filePermissionActionCreateFile: Entry(zh: "新建文件", en: "Create File"),
        .filePermissionActionCreateFolder: Entry(zh: "新建文件夹", en: "Create Folder"),
        .filePermissionActionCreateAlias: Entry(zh: "创建快捷方式（Finder 别名）", en: "Create Alias"),
        .filePermissionActionCutPaste: Entry(zh: "剪切与「粘贴到这里」", en: "Cut & Paste Here"),
        .filePermissionActionCopyName: Entry(zh: "复制文件名", en: "Copy Name"),
        .filePermissionActionCopyPath: Entry(zh: "复制路径", en: "Copy Path"),
        .filePermissionActionCopyFileURL: Entry(zh: "复制文件 URL", en: "Copy File URL"),
        .filePermissionActionLockUnlock: Entry(zh: "锁定与解锁", en: "Lock & Unlock"),
        .filePermissionActionOpenTerminal: Entry(zh: "打开终端", en: "Open Terminal"),
        .filePermissionActionExtractArchive: Entry(zh: "解压压缩包", en: "Extract Archive"),
        .filePermissionActionCompressArchive: Entry(zh: "压缩所选项目", en: "Compress Items"),
        .filePermissionActionOpenFavorite: Entry(zh: "打开常用软件 / 网页 / 文件夹", en: "Open Favorites"),
        .filePermissionSafety: Entry(zh: "安全策略", en: "Safety"),
        .filePermissionRestrict: Entry(
            zh: "仅在已授权的文件夹内创建或修改文件",
            en: "Only create or modify files inside authorized folders"
        ),
        .filePermissionRestrictFooter: Entry(
            zh: "关闭后依然受 macOS 沙盒限制：没有授权书签的路径无法写入。",
            en: "Turning this off does not bypass the sandbox: paths without an authorization bookmark still cannot be written."
        ),
        .filePermissionConfirm: Entry(
            zh: "锁定、剪切等敏感操作前二次确认",
            en: "Ask before sensitive actions (lock, cut)"
        ),

        // Folder permissions
        .folderPermissionIntro: Entry(
            zh: "授权后 MenuRight 才能在这些文件夹中新建、移动或修改文件。授权以安全作用域书签保存在 App Group 中，只有主应用会解析它。",
            en: "Authorizing a folder lets MenuRight create, move, and modify files inside it. Authorization is stored as a security-scoped bookmark in the App Group and is only resolved by the main app."
        ),
        .folderPermissionAuthorized: Entry(zh: "已授权的文件夹", en: "Authorized Folders"),
        .folderPermissionAdd: Entry(zh: "授权文件夹…", en: "Authorize Folder…"),
        .folderPermissionEmpty: Entry(
            zh: "还没有授权任何文件夹。没有授权时，MenuRight 只能在扩展本身可访问的位置操作。",
            en: "No folder is authorized yet. Without authorization MenuRight can only act where the extension itself has access."
        ),
        .folderPermissionStatusAuthorized: Entry(zh: "已授权", en: "Authorized"),
        .folderPermissionStatusNeedsReauth: Entry(zh: "需要重新授权", en: "Needs Reauthorization"),
        .folderPermissionStatusUnavailable: Entry(zh: "不可用", en: "Unavailable"),
        .folderPermissionRemoveTitle: Entry(zh: "移除这个文件夹的授权？", en: "Remove authorization for this folder?"),
        .folderPermissionRemoveMessage: Entry(
            zh: "移除后 MenuRight 将无法再在其中写入文件，已创建的文件不受影响。",
            en: "After removal MenuRight can no longer write there. Files already created are unaffected."
        ),
        .folderPermissionStorageUnavailable: Entry(
            zh: "授权存储不可用（App Group 未配置）。",
            en: "Authorization storage is unavailable (App Group not configured)."
        ),
        .folderPermissionFavoritesHint: Entry(
            zh: "「常用文件夹」只用于打开，不需要授权。",
            en: "Favorite folders are only opened; they need no authorization."
        ),

        // New file
        .newFileIntro: Entry(
            zh: "选择「新建文件」子菜单里出现的类型，并调整它们的顺序。",
            en: "Choose which types appear in the New File submenu and in what order."
        ),
        .newFileTypes: Entry(zh: "文件类型", en: "File Types"),
        .newFileBaseName: Entry(zh: "默认文件名", en: "Default File Name"),
        .newFileBaseNameFooter: Entry(
            zh: "生成的文件形如「名称.扩展名」；同名时自动追加序号，不覆盖已有文件。",
            en: "Files are created as name.extension; a numeric suffix is added instead of overwriting."
        ),
        .newFilePreview: Entry(zh: "菜单预览", en: "Menu Preview"),
        .newFileTemplateMissingBadge: Entry(zh: "缺少模板", en: "Template missing"),
        .newFileMissingTemplates: Entry(zh: "缺少模板文件：", en: "Missing template files: "),
        .newFileTemplateDirectory: Entry(zh: "模板目录", en: "Template Folder"),
        .newFileTemplateDirectoryFooter: Entry(
            zh: "Pages / Numbers / Keynote 的空白模板从这里读取；留空表示使用应用内置模板。自定义目录需要包含相同文件名的模板（blank.pages、blank.numbers、blank.key）。",
            en: "Pages / Numbers / Keynote blank templates are read from here; leave empty to use the templates bundled with the app. A custom folder needs templates with the same file names (blank.pages, blank.numbers, blank.key)."
        ),
        .newFileTemplateDirectoryChoose: Entry(zh: "选择…", en: "Choose…"),
        .newFileTemplateDirectoryReset: Entry(zh: "使用内置模板", en: "Use Bundled Templates"),
        .newFileTemplateDirectoryMissing: Entry(
            zh: "该目录中缺少对应模板，相关类型不会出现在右键菜单中。",
            en: "Templates are missing from this folder, so those types will not appear in the context menu."
        ),
        .newFileKindText: Entry(zh: "文本文件", en: "Text File"),
        .newFileKindMarkdown: Entry(zh: "Markdown 文件", en: "Markdown File"),
        .newFileKindHTML: Entry(zh: "HTML 文件", en: "HTML File"),
        .newFileKindCSS: Entry(zh: "CSS 文件", en: "CSS File"),
        .newFileKindJavaScript: Entry(zh: "JavaScript 文件", en: "JavaScript File"),
        .newFileKindJSON: Entry(zh: "JSON 文件", en: "JSON File"),
        .newFileKindWord: Entry(zh: "Word 文档", en: "Word Document"),
        .newFileKindExcel: Entry(zh: "Excel 表格", en: "Excel Spreadsheet"),
        .newFileKindPowerPoint: Entry(zh: "PowerPoint 演示", en: "PowerPoint Presentation"),
        .newFileKindPages: Entry(zh: "Pages 文稿", en: "Pages Document"),
        .newFileKindNumbers: Entry(zh: "Numbers 表格", en: "Numbers Spreadsheet"),
        .newFileKindKeynote: Entry(zh: "Keynote 演示", en: "Keynote Presentation"),

        // Finder context menu (see `FinderMenuTitles`).
        .finderMenuCreateAlias: Entry(zh: "创建别名", en: "Create Alias"),
        .finderMenuLock: Entry(zh: "锁定", en: "Lock"),
        .finderMenuUnlock: Entry(zh: "解锁", en: "Unlock"),
        .finderMenuCut: Entry(zh: "剪切", en: "Cut"),
        .finderMenuNewFolder: Entry(zh: "新建文件夹", en: "New Folder"),
        .finderMenuPasteHere: Entry(zh: "粘贴到这里", en: "Paste Here"),
        .finderMenuExtract: Entry(zh: "解压", en: "Extract"),
        .finderMenuExtractHere: Entry(zh: "解压到当前文件夹", en: "Extract Here"),
        .finderMenuExtractCustom: Entry(zh: "解压到指定位置…", en: "Extract to…"),
        .finderMenuExtractToFolder: Entry(zh: "解压到「%@」", en: "Extract to “%@”"),
        .finderMenuCompress: Entry(zh: "压缩", en: "Compress"),
        .finderMenuCompressToZip: Entry(zh: "压缩为 ZIP", en: "Compress to ZIP"),
        .finderMenuCompressToTar: Entry(zh: "压缩为 TAR", en: "Compress to TAR"),
        .finderMenuCompressToTarGz: Entry(zh: "压缩为 TAR.GZ", en: "Compress to TAR.GZ"),
        .finderMenuCompressToTarBz2: Entry(zh: "压缩为 TAR.BZ2", en: "Compress to TAR.BZ2"),

        // Finder Sync failure prompts
        .presenterOK: Entry(zh: "好", en: "OK"),
        .presenterOpenApp: Entry(zh: "打开 MenuRight", en: "Open Menu Right"),
        .presenterAppNotRunningTitle: Entry(zh: "MenuRight 未运行", en: "Menu Right not running"),
        .presenterAppNotRunningBody: Entry(
            zh: "所有文件操作都由 MenuRight 主应用执行，所以它必须处于运行状态。",
            en: "Menu Right does the actual file work, so the app has to be running."
        ),
        .presenterAppNotRunningHint: Entry(
            zh: "打开 MenuRight 后，回到访达菜单重试一次即可。",
            en: "Open Menu Right, then try again from the Finder menu."
        ),
        .presenterDetails: Entry(zh: "详情：%@", en: "Details: %@"),
        .presenterStillRunningTitle: Entry(zh: "操作仍在进行", en: "Still working"),
        .presenterStillRunningBody: Entry(
            zh: "MenuRight 已收到这个操作，并且仍在处理（等待已超过 %@）。结果会直接出现在目标文件夹，请不要重复操作；如果很久都没有结果，可以重启 MenuRight。",
            en: "Menu Right has your request and is still working on it (over %@ now). The result will appear in the destination folder — please don't repeat the action. If nothing shows up for a long time, restart Menu Right."
        ),
        .presenterBusyCompress: Entry(zh: "正在压缩…", en: "Compressing…"),
        .presenterBusyExtract: Entry(zh: "正在解压…", en: "Extracting…"),
        .presenterBusyGeneric: Entry(zh: "正在处理…", en: "Working…"),
        .presenterBusyHide: Entry(zh: "隐藏", en: "Hide"),
        .presenterProgressTitle: Entry(zh: "正在压缩", en: "Compressing"),
        .presenterProgressExtractTitle: Entry(zh: "正在解压", en: "Extracting"),
        .presenterProgressPause: Entry(zh: "暂停", en: "Pause"),
        .presenterProgressResume: Entry(zh: "继续", en: "Resume"),
        .presenterProgressCancel: Entry(zh: "取消", en: "Cancel"),
        .presenterProgressPreparing: Entry(zh: "正在读取文件…", en: "Reading files…"),
        .presenterBusyBody: Entry(
            zh: "完成后这个提示会自动消失，结果会直接出现在目标文件夹。",
            en: "This notice closes itself when the operation finishes; the result appears in the destination folder."
        ),
        .presenterOperationFailed: Entry(zh: "操作失败。", en: "The operation failed."),
        .presenterCouldNotAction: Entry(zh: "无法完成“%@”。", en: "Couldn't %@."),
        .presenterCouldNotCreate: Entry(zh: "无法创建“%@”。", en: "Couldn't create “%@”."),
        .presenterCouldNotOpen: Entry(zh: "无法打开“%@”。", en: "Couldn't open “%@”."),
        .presenterCouldNotMoveOne: Entry(zh: "无法移动该项。", en: "Couldn't move the item."),
        .presenterCouldNotMoveMany: Entry(zh: "无法移动 %d 项。", en: "Couldn't move %d items."),
        .presenterAllItemsFailed: Entry(zh: "%d 项全部失败。", en: "All %d items failed."),
        .presenterSomeItemsFailed: Entry(zh: "%d/%d 项失败。", en: "%d of %d items failed."),
        .presenterMoveConflictAll: Entry(
            zh: "目标位置已有同名文件，无法移动：%@。",
            en: "Items could not be moved because files with the same names already exist in the destination: %@."
        ),
        .presenterMoveConflictSome: Entry(
            zh: "部分项目无法移动：目标位置已有同名文件。",
            en: "Some items could not be moved because files with the same names already exist in the destination."
        ),
        .presenterMoveFailed: Entry(zh: "移动失败。", en: "The move failed."),
        .presenterOpenFailed: Entry(zh: "该项目无法打开。", en: "The item could not be opened."),
        .presenterFolderAccessTitle: Entry(zh: "需要文件夹访问权限", en: "Folder Access Required"),
        .presenterFolderAccessBody: Entry(
            zh: "MenuRight 需要先获得这个文件夹的访问权限，才能在这里修改文件。",
            en: "Menu Right needs access to this folder before it can modify files here."
        ),
        .presenterFolderAccessHint: Entry(
            zh: "打开 MenuRight 的「文件夹权限」，授权这个文件夹或它的上层文件夹。",
            en: "Open Menu Right → Folder Access and authorize this folder or one of its parent folders."
        ),
        .presenterCutFailedTitle: Entry(zh: "无法剪切项目", en: "Couldn't cut items"),
        .presenterCutFailedBody: Entry(
            zh: "剪切信息无法写入剪贴板。",
            en: "The cut information could not be written to the pasteboard."
        ),
        .presenterPasteFailedTitle: Entry(zh: "无法粘贴项目", en: "Couldn't paste items"),
        .presenterTerminalFailedTitle: Entry(zh: "无法打开终端", en: "Couldn't open Terminal"),
        .presenterActionExtract: Entry(zh: "解压压缩包", en: "extract the archive"),
        .presenterActionCompress: Entry(zh: "压缩所选项目", en: "compress the selection"),
        .presenterActionCreateAlias: Entry(zh: "创建快捷方式", en: "create the alias"),
        .presenterActionLock: Entry(zh: "锁定项目", en: "lock the item"),
        .presenterActionUnlock: Entry(zh: "解锁项目", en: "unlock the item"),
        .finderMenuCopyFolderName: Entry(zh: "复制文件夹名称", en: "Copy Folder Name"),
        .finderMenuCopyFolderPath: Entry(zh: "复制文件夹路径", en: "Copy Folder Path"),

        // Favorites
        .favoriteFoldersIntro: Entry(
            zh: "这些文件夹会出现在 Finder 右键菜单的「常用文件夹」子菜单中。",
            en: "These folders appear under Favorite Folders in the Finder context menu."
        ),
        .favoriteFoldersAdd: Entry(zh: "添加文件夹…", en: "Add Folder…"),
        .favoriteFoldersEmpty: Entry(zh: "还没有常用文件夹。", en: "No favorite folders yet."),
        .favoriteFoldersMissing: Entry(
            zh: "文件夹已不在磁盘上，菜单项会显示为失败提示。",
            en: "This folder is gone; the menu item will report a failure."
        ),
        .favoriteAppsIntro: Entry(
            zh: "这些应用会出现在 Finder 右键菜单的「常用软件」子菜单中，用于打开当前文件夹或选中项。",
            en: "These applications appear under Favorite Apps in the Finder context menu, opening the current folder or selection."
        ),
        .favoriteAppsAdd: Entry(zh: "选择应用…", en: "Choose Application…"),
        .favoriteAppsEmpty: Entry(zh: "还没有常用软件。", en: "No favorite apps yet."),
        .favoriteAppsMissing: Entry(
            zh: "应用已不在磁盘上，菜单项会显示为失败提示。",
            en: "This application is gone; the menu item will report a failure."
        ),
        .favoriteWebsitesIntro: Entry(
            zh: "这些网页会出现在 Finder 右键菜单的「常用网页」子菜单中，使用默认浏览器打开。",
            en: "These sites appear under Favorite Websites in the Finder context menu and open in the default browser."
        ),
        .favoriteWebsitesAdd: Entry(zh: "添加网页", en: "Add Website"),
        .favoriteWebsitesEmpty: Entry(zh: "还没有常用网页。", en: "No favorite websites yet."),
        .favoriteWebsitesName: Entry(zh: "名称", en: "Name"),
        .favoriteWebsitesURL: Entry(zh: "网址", en: "URL"),
        .favoriteWebsitesInvalidURL: Entry(
            zh: "请输入有效的网址，例如 example.com 或 https://example.com。",
            en: "Enter a valid URL, for example example.com or https://example.com."
        ),
        .favoriteWebsitesSheetTitle: Entry(zh: "添加常用网页", en: "Add Favorite Website"),

        // Code theme
        .codeThemeIntro: Entry(
            zh: "选择代码预览的高亮主题与字体。预览用的是与 Quick Look 扩展同一套轻量高亮器；配色由主应用保存，扩展读取同一份配置。",
            en: "Pick the highlight theme and font for code previews. The preview runs the same lightweight highlighter the Quick Look extension uses; the palette is stored by the main app and read by the extension."
        ),
        .codeThemeTheme: Entry(zh: "主题", en: "Theme"),
        .codeThemePreview: Entry(zh: "预览", en: "Preview"),
        .codeThemeFontSize: Entry(zh: "字号", en: "Font Size"),
        .codeThemeFont: Entry(zh: "字体", en: "Font"),
        .codeThemeFontSystem: Entry(zh: "系统等宽字体", en: "System Monospaced"),
        .codeThemeLineNumbers: Entry(zh: "显示行号", en: "Show Line Numbers"),
        .codePreviewLanguage: Entry(zh: "示例语言", en: "Sample Language"),
        .codePreviewPlainText: Entry(zh: "纯文本", en: "Plain Text"),
        // Shown inside the Quick Look panel, not in Settings.
        .codePreviewUnreadable: Entry(
            zh: "无法读取这个文件。",
            en: "This file could not be read."
        ),
        .codePreviewTruncated: Entry(
            zh: "文件较大,这里只显示前 %d 行。",
            en: "Large file: only the first %d lines are shown."
        ),

        // Archives
        .archiveIntro: Entry(
            zh: "配置解压行为与允许的压缩格式。",
            en: "Configure extraction behaviour and the formats that are allowed."
        ),
        .archiveFormats: Entry(zh: "允许的压缩格式", en: "Allowed Formats"),
        .archiveFormatZip: Entry(zh: "ZIP", en: "ZIP"),
        .archiveFormatSevenZip: Entry(zh: "7-Zip", en: "7-Zip"),
        .archiveFormatTar: Entry(zh: "TAR", en: "TAR"),
        .archiveFormatGZip: Entry(zh: "GZip", en: "GZip"),
        .archiveFormatBZip2: Entry(zh: "BZip2", en: "BZip2"),
        .archiveFormatXZ: Entry(zh: "XZ", en: "XZ"),
        .archiveFormatRAR: Entry(zh: "RAR", en: "RAR"),
        .archiveBehavior: Entry(zh: "解压行为", en: "Extraction Behaviour"),
        .archiveDestination: Entry(zh: "解压位置", en: "Extract To"),
        .archiveDestinationAsk: Entry(zh: "每次询问", en: "Ask Every Time"),
        .archiveDestinationSameFolder: Entry(zh: "压缩包所在文件夹", en: "Archive’s Folder"),
        .archiveDestinationCustom: Entry(zh: "指定文件夹…", en: "Chosen Folder…"),
        .archiveDestinationNotAuthorized: Entry(
            zh: "该文件夹尚未授权，解压到那里会被拒绝。",
            en: "This folder is not authorized yet, so extracting there will be refused."
        ),
        .archiveDestinationNotAuthorizedDetail: Entry(
            zh: "请先在「文件夹权限」里授权该文件夹（或其上层文件夹）。",
            en: "Authorize it — or a parent folder — under Folder Permissions first."
        ),
        .archiveConflict: Entry(zh: "同名文件", en: "Name Conflicts"),
        .archiveConflictKeepBoth: Entry(zh: "保留两者（重命名新文件）", en: "Keep Both (rename the new file)"),
        .archiveConflictSkip: Entry(zh: "跳过", en: "Skip"),
        .archiveConflictOverwrite: Entry(zh: "覆盖", en: "Overwrite"),
        .archiveCleanup: Entry(zh: "解压成功后删除原压缩包", en: "Delete the archive after a successful extraction"),
        .archiveSkipMetadata: Entry(
            zh: "跳过 __MACOSX 与 .DS_Store",
            en: "Skip __MACOSX and .DS_Store"
        ),
        .archiveSizeLimit: Entry(zh: "体积上限", en: "Size Limit"),
        .archiveSizeLimitUnit: Entry(zh: "MB", en: "MB"),
        .archiveSizeLimitRangeHint: Entry(zh: "可输入 %@–%@ MB", en: "Enter %@–%@ MB"),
        .archiveSizeLimitMaxHint: Entry(zh: "最大不能超过 %@ MB", en: "Maximum is %@ MB"),
        .archiveSizeLimitMinHint: Entry(zh: "最小不能小于 %@ MB", en: "Minimum is %@ MB"),
        .archiveSizeLimitInvalidHint: Entry(zh: "请输入数字", en: "Enter a number"),

        // Menu bar item. The quit item carries the product name because that is
        // how a Mac app's quit command reads ("Quit MenuRight", not "Quit").
        .statusMenuOpenSettings: Entry(zh: "打开设置", en: "Open Settings"),
        .statusMenuCheckForUpdates: Entry(zh: "检查更新", en: "Check for Updates"),
        .statusMenuQuit: Entry(zh: "退出 MenuRight", en: "Quit MenuRight"),
        .statusMenuUpToDateTitle: Entry(zh: "已是最新版本", en: "You're up to date"),
        .statusMenuUpToDateBody: Entry(
            zh: "当前版本 %@，没有发现更新的版本。",
            en: "You are running %@ and no newer version was found."
        ),
        .statusMenuCheckFailedTitle: Entry(zh: "检查更新失败", en: "Update Check Failed"),

        // Alerts
        .errorAlertTitle: Entry(zh: "操作未完成", en: "Something Went Wrong"),
    ]
}
