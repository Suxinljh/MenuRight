import SwiftUI
import AppKit
import FinderSync
import UniformTypeIdentifiers

/// General settings: interface language, launch behaviour, and the live status
/// of the two moving parts this app depends on (the Finder extension and the
/// IPC channel), plus read-only build information.
///
/// The extension/IPC status used to be the whole window; it now lives here so
/// that information is not lost as the settings UI grows.
struct GeneralSettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    @StateObject private var ipcStatus = IPCStatusCenter.shared
    /// The launch check and this pane share one instance, so a result found at
    /// launch is already on screen when the pane opens.
    @StateObject private var updater = UpdateChecker.shared

    @State private var isExtensionEnabled = false
    /// 开机自启 的第三种系统状态（已注册，等用户在系统设置里允许）。它只控制
    /// 提示；开关本身显示的是用户的选择，`requiresApproval` 绝不写回「关」。
    @State private var launchAtLoginState: LaunchAtLoginState = .disabled
    @State private var launchAtLoginError: String?
    @State private var showsResetConfirmation = false
    @State private var showsLicenses = false
    /// 重启失败时把原因显示在窗口里 —— `relaunch()` 的失败不能只写日志。
    @State private var restartFailure: String?
    /// 「引导已完成」与设置同域（App Group），这样「重置全部设置」能把它一起清掉。
    @AppStorage("hasCompletedOnboarding", store: SettingsStore.defaultUserDefaults())
    private var hasCompletedOnboarding = false

    var body: some View {
        SettingsPane(title: store.text(.categoryGeneral), subtitle: store.text(.generalIntro)) {
            languageGroup
            launchGroup
            terminalGroup
            extensionGroup
            ipcGroup
            updatesGroup
            aboutGroup
            resetGroup
        }
        .onAppear {
            LifecycleDiagnostics.record("GeneralSettingsView.onAppear", from: "main-app")
            refreshExtensionStatus()
            syncLaunchAtLoginWithSystem()
        }
        // 用户去系统设置勾选扩展、允许登录项后切回窗口：这两个状态只有重新读
        // 才会变，否则得等下次打开面板（与 FolderAccessView / OnboardingView 一致）。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshExtensionStatus()
            syncLaunchAtLoginWithSystem()
        }
        .sheet(isPresented: $showsLicenses) {
            // Strings are passed in rather than read from the environment: the
            // sheet must render correctly for whatever language is selected when
            // it opens.
            LicensesSheet(
                title: store.text(.generalLicenses),
                closeTitle: store.text(.commonClose),
                emptyText: store.text(.generalLicensesEmpty),
                notices: ThirdPartyNotices.load()
            ) {
                showsLicenses = false
            }
        }
    }

    // MARK: - Groups

    private var languageGroup: some View {
        SettingsGroup(title: store.text(.generalLanguage)) {
            SettingsRow(title: store.text(.generalLanguage), systemImage: "character.bubble") {
                Picker("", selection: store.binding(\.general.language)) {
                    Text(store.text(.generalLanguageSystem)).tag(AppLanguage.system)
                    Text(store.text(.generalLanguageChinese)).tag(AppLanguage.simplifiedChinese)
                    Text(store.text(.generalLanguageEnglish)).tag(AppLanguage.english)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 190, alignment: .trailing)
            }
        }
    }

    private var launchGroup: some View {
        SettingsGroup(title: store.text(.generalLaunchAtLogin)) {
            SettingsToggleRow(
                title: store.text(.generalLaunchAtLogin),
                isOn: Binding(
                    get: { store.settings.general.launchAtLogin },
                    set: { applyLaunchAtLogin($0) }
                )
            )
            if launchAtLoginState.needsApproval {
                SettingsRowDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        store.text(.generalLaunchAtLoginRequiresApproval),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    Button(store.text(.generalLaunchAtLoginOpenSettings)) {
                        LaunchAtLogin.openLoginItemsSettings()
                    }
                }
                .padding(.bottom, 8)
            }
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
        }
    }

    /// P6: 打开终端 uses Terminal unless the user points it at another terminal.
    /// A third-party terminal is reached through its Finder **service** (the
    /// sandbox cannot launch an arbitrary .app on a folder), which is why the
    /// service name is configurable next to the app.
    private var terminalGroup: some View {
        SettingsGroup(
            title: store.text(.generalTerminalTitle),
            footer: store.text(.generalTerminalFooter)
        ) {
            SettingsRow(
                title: store.text(.generalTerminalTitle),
                subtitle: terminalApplicationSubtitle,
                systemImage: "terminal",
                subtitleLineLimit: 1
            ) {
                HStack(spacing: 8) {
                    Button(store.text(.generalTerminalChoose)) { chooseTerminalApplication() }
                    if store.settings.general.usesCustomTerminal {
                        Button(store.text(.generalTerminalReset)) { resetTerminalApplication() }
                    }
                }
            }
            if terminalApplicationIsMissing {
                Text(store.text(.generalTerminalMissing))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
            SettingsRowDivider()
            SettingsRow(
                title: store.text(.generalTerminalService),
                subtitle: store.text(.generalTerminalServiceFooter),
                systemImage: "gearshape",
                subtitleLineLimit: 2
            ) {
                TextField("", text: store.binding(\.general.terminalServiceName))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
        }
    }

    /// The configured .app, or the built-in default when none is chosen.
    private var terminalApplicationSubtitle: String {
        guard let url = store.settings.general.terminalApplicationURL else {
            return store.text(.generalTerminalDefault)
        }
        return url.path
    }

    private var terminalApplicationIsMissing: Bool {
        guard let url = store.settings.general.terminalApplicationURL else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    private func chooseTerminalApplication() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = store.text(.generalTerminalChoose)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.mutate { $0.general.terminalApplicationPath = url.path }
    }

    private func resetTerminalApplication() {
        store.mutate {
            $0.general.terminalApplicationPath = ""
            $0.general.terminalServiceName = GeneralSettings.defaultTerminalServiceName
        }
    }

    private var extensionGroup: some View {
        SettingsGroup(title: store.text(.generalExtension)) {
            SettingsRow(
                title: store.text(.generalExtension),
                subtitle: Bundle.main.bundlePath,
                systemImage: isExtensionEnabled ? "checkmark.seal" : "exclamationmark.triangle",
                subtitleLineLimit: 1
            ) {
                HStack(spacing: 7) {
                    StatusDot(color: isExtensionEnabled ? .green : .red)
                    Text(isExtensionEnabled ? store.text(.generalExtensionEnabled) : store.text(.generalExtensionDisabled))
                }
            }
            SettingsRowDivider()
            if !isExtensionEnabled {
                Text(store.text(.generalExtensionCopyWarning))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsRowDivider()
            }
            HStack {
                Button(store.text(.generalExtensionManage)) {
                    FIFinderSyncController.showExtensionManagementInterface()
                }
                Spacer()
            }
        }
    }

    private var ipcGroup: some View {
        SettingsGroup(
            title: store.text(.generalIPC),
            footer: ipcStatus.isHealthy ? nil : store.text(.generalIPCFooter)
        ) {
            SettingsRow(
                title: store.text(.generalIPC),
                subtitle: ipcStatus.isHealthy ? nil : store.text(.generalIPCNotHealthy),
                systemImage: "bolt.horizontal.circle"
            ) {
                HStack(spacing: 7) {
                    StatusDot(color: ipcStatus.isHealthy ? .green : .orange)
                    Text(ipcStatusText)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var aboutGroup: some View {
        SettingsGroup(title: store.text(.generalAbout)) {
            SettingsInfoRow(label: store.text(.generalAppName), value: appName)
            SettingsRowDivider()
            SettingsInfoRow(label: store.text(.commonVersion), value: appVersion)
            SettingsRowDivider()
            // The product page. Deliberately not gated on anything: it is a plain
            // LaunchServices hand-off, the same route the favorites use.
            SettingsRow(
                title: store.text(.generalWebsite),
                systemImage: "globe"
            ) {
                Button(store.text(.generalWebsiteOpen)) { openWebsite() }
            }
            SettingsRowDivider()
            SettingsRow(
                title: store.text(.generalLicenses),
                subtitle: store.text(.generalLicensesFooter),
                systemImage: "doc.text.magnifyingglass"
            ) {
                Button(store.text(.commonView)) { showsLicenses = true }
            }
        }
    }

    /// Public product page. A compile-time constant, resolved once: the `guard`
    /// states that without a force-unwrap at the call site.
    private static let websiteURL: URL = {
        guard let url = URL(string: "https://create.ljhsu.xin/menuright") else {
            preconditionFailure("the product page must be a valid URL")
        }
        return url
    }()

    private func openWebsite() {
        // Failure is silent on purpose: the URL is a compile-time constant, and
        // the only realistic failure is "no browser configured".
        NSWorkspace.shared.open(Self.websiteURL)
        LifecycleDiagnostics.record("ABOUT open website", from: "main-app")
    }

    // MARK: - Updates

    private var updatesGroup: some View {
        SettingsGroup(title: store.text(.generalUpdates)) {
            SettingsToggleRow(
                title: store.text(.generalAutoUpdate),
                isOn: store.binding(\.general.automaticallyChecksForUpdates)
            )
            SettingsRowDivider()
            SettingsRow(
                title: store.text(.generalCheckNow),
                subtitle: updateStatusText,
                systemImage: "arrow.triangle.2.circlepath"
            ) {
                if updater.state == .checking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(store.text(.generalCheckNow)) {
                        Task { await updater.checkNow() }
                    }
                }
            }
            if case .updateAvailable(let release) = updater.state {
                SettingsRowDivider()
                updateAvailableRow(release)
            }
        }
    }

    /// One line of state under the "Check Now" row — the manual check reports
    /// failures here rather than in a dialog.
    private var updateStatusText: String {
        switch updater.state {
        case .idle:
            return store.text(.generalUpdateIdle)
        case .checking:
            return store.text(.generalChecking)
        case .upToDate(let version):
            return String(format: store.text(.generalUpToDate), version)
        case .updateAvailable(let release):
            return String(format: store.text(.generalUpdateAvailable), release.version)
        case .failed(let message):
            return message
        }
    }

    private func updateAvailableRow(_ release: UpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(release.title)
                .font(.callout.weight(.semibold))
            let notes = UpdatePolicy.summarizedNotes(release.notes, limit: 600)
            if !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button(store.text(.generalUpdateOpenReleasePage)) {
                    updater.openReleasePage(release)
                }
                Button(store.text(.generalUpdateSkip)) {
                    updater.skip(release)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Not a settings group: a destructive action with a warning-coloured
    /// button, deliberately without a card background — and without a footer:
    /// the "settings only, folders are untouched" sentence belongs in the
    /// confirmation, where it answers the question the user is about to ask.
    private var resetGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            // `role: .destructive` + `.tint(.red)` renders a plain grey bordered
            // button on macOS, so the warning colour is applied to the label
            // explicitly (verified by screenshot).
            Button(role: .destructive) {
                showsResetConfirmation = true
            } label: {
                Text(store.text(.commonResetAll))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
        }
        .alert(store.text(.commonResetAll), isPresented: $showsResetConfirmation) {
            Button(store.text(.commonCancel), role: .cancel) {}
            Button(store.text(.commonReset), role: .destructive) {
                store.resetAll()
                // 引导标记与设置同域；重置后再走一次引导才一致。
                hasCompletedOnboarding = false
            }
        } message: {
            Text("\(store.text(.commonResetAllMessage))\n\(store.text(.generalResetFooter))")
        }
    }

    // MARK: - Actions

    private func refreshExtensionStatus() {
        // macOS 10.14+. Deployment target is 14.0, so no availability gate needed.
        isExtensionEnabled = FIFinderSyncController.isExtensionEnabled
        // Logged explicitly: "why does the window say Disabled?" is otherwise
        // guesswork. Compare with `pluginkit -m -i xin.ljhsu.MenuRight.FinderSync -v`:
        // the system answers for the extension that is *registered and enabled*,
        // which is not necessarily the copy you are running.
        LifecycleDiagnostics.record(
            "extension status isExtensionEnabled=\(isExtensionEnabled)",
            from: "main-app"
        )
    }

    /// Makes the stored flag agree with the system before the user touches it,
    /// so the switch never claims a state the system does not have.
    private func syncLaunchAtLoginWithSystem() {
        let state = LaunchAtLogin.state
        launchAtLoginState = state
        reconcileStoredPreference(with: state)
        launchAtLoginError = nil
    }

    /// 把系统的真实状态同步进设置。
    ///
    /// 三态里只有两种是确定的：`.enabled` 写「开」，`.disabled` 写「关」。
    /// `.requiresApproval` **不写** —— 登录项其实已经注册，只是等用户在系统设置里
    /// 允许；把它当「关」写回去正是之前那个 bug（开关每次出现都被回写成关）。
    private func reconcileStoredPreference(with state: LaunchAtLoginState) {
        switch state {
        case .enabled:
            guard !store.settings.general.launchAtLogin else { return }
            store.mutate { $0.general.launchAtLogin = true }
        case .disabled:
            guard store.settings.general.launchAtLogin else { return }
            store.mutate { $0.general.launchAtLogin = false }
        case .requiresApproval:
            break
        }
    }

    private func applyLaunchAtLogin(_ isEnabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(isEnabled)
            store.mutate { $0.general.launchAtLogin = isEnabled }
            launchAtLoginState = LaunchAtLogin.state
            launchAtLoginError = nil
        } catch {
            // The call failed, so the system state is unchanged: refresh what is
            // shown, reconcile only with an unambiguous state (never turn a
            // pending approval into "off"), then explain why (unsigned build,
            // app not in /Applications, …).
            launchAtLoginState = LaunchAtLogin.state
            reconcileStoredPreference(with: launchAtLoginState)
            launchAtLoginError = "\(store.text(.generalLaunchAtLoginError)): \(error.localizedDescription)"
        }
    }

    /// IPC 状态文案。`IPCStatusCenter.displayText` 是英文硬编码（且日志仍在用），
    /// 所以视图侧按 case 映射到本地化键，参数与 `displayText` 保持一致。
    private var ipcStatusText: String {
        switch ipcStatus.state {
        case .idle:
            return store.text(.generalIPCStarting)
        case .listening:
            return store.text(.generalIPCListening)
        case .waitingForOtherInstance(let attempt):
            return String(format: store.text(.generalIPCWaiting), attempt)
        case .failed(let reason):
            return String(format: store.text(.generalIPCFailed), reason)
        case .stopped:
            return store.text(.generalIPCStopped)
        }
    }

    // MARK: - Bundle info

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "MenuRight"
    }

    /// "1.0 (1)" — marketing version plus build number. The build number matters
    /// when reporting a problem, and it is what `Scripts/version.sh` bumps.
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}

/// Upstream licence texts shipped inside the app bundle.
///
/// `MenuRight/Resources/Third-Party-Notices/` is a folder reference, so adding a
/// notice for a future dependency (SWCompression is planned for P9) needs no code
/// change — the sheet lists whatever `.txt` files are there.
enum ThirdPartyNotices {
    struct Notice: Identifiable {
        let id: String
        let title: String
        let text: String
    }

    static func load(bundle: Bundle = .main) -> [Notice] {
        guard let directory = bundle.url(forResource: "Third-Party-Notices", withExtension: nil),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil
              )
        else { return [] }

        return urls
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return Notice(
                    id: url.lastPathComponent,
                    title: url.deletingPathExtension().lastPathComponent,
                    text: text
                )
            }
    }
}

/// Read-only licence viewer (ISC requires the licence text to travel with the
/// binary; this is how the user can actually reach it).
private struct LicensesSheet: View {
    let title: String
    let closeTitle: String
    let emptyText: String
    let notices: [ThirdPartyNotices.Notice]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button(closeTitle, action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if notices.isEmpty {
                        Text(emptyText)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(notices) { notice in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(notice.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(notice.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .frame(width: 560, height: 420)
    }
}
