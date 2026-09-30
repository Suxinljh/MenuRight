import AppKit
import FinderSync
import SwiftUI

/// The first-run guide: the two things a new user has to do before MenuRight can
/// do anything, and a summary that offers the restart button.
///
/// Deliberately short. The app needs exactly one system-level permission
/// (enabling the Finder extension — there is no Accessibility/AppleScript
/// requirement by design) plus in-app folder authorization, so the guide is three
/// steps and can be skipped. `OnboardingFlow` owns the state machine so the
/// transitions are unit-testable.
struct OnboardingView: View {
    @EnvironmentObject private var store: SettingsStore

    /// Called when the user finishes the guide.
    let onFinish: () -> Void
    /// Called for "Not Now" — dismisses for this launch only.
    let onSkip: () -> Void
    /// The toolbar's restart action, reused so both do the same thing.
    let onRelaunch: () -> Void

    /// Owned by the presenter: `@State(initialValue:)` here would freeze the
    /// first value it ever saw, which broke the Debug step-review hook.
    @Binding var step: OnboardingStep
    @State private var isExtensionEnabled = FIFinderSyncController.isExtensionEnabled
    @State private var authorizedCount = 0
    @State private var authStore: FolderAuthorizationStore? = FolderAuthorizationStore.appGroupDefault()
    @State private var authorizationError: String?

    init(
        step: Binding<OnboardingStep>,
        onFinish: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onRelaunch: @escaping () -> Void
    ) {
        _step = step
        self.onFinish = onFinish
        self.onSkip = onSkip
        self.onRelaunch = onRelaunch
    }

    /// The state machine for the current step; transitions write back to `step`.
    private var flow: OnboardingFlow {
        var flow = OnboardingFlow()
        flow.jump(to: step)
        return flow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            // An explicit spacer takes the slack. Without it the extra height of
            // the fixed-size sheet is handed to the `Text` children, which grow
            // and leave a gap under each paragraph.
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .frame(width: 520)
        .frame(minHeight: 360, alignment: .top)
        .onAppear(perform: refresh)
        // Enabling the extension happens in System Settings, so re-read the live
        // status when the user comes back — otherwise "Next" would stay disabled
        // until they found the refresh button.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(store.text(.onboardingTitle))
                .font(.title3.weight(.semibold))
            Spacer()
            Text(String(format: store.text(.onboardingStepIndicator), flow.stepNumber, flow.stepCount))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch flow.step {
        case .enableExtension:
            step(
                title: store.text(.onboardingEnableTitle),
                body: store.text(.onboardingEnableBody)
            ) {
                SettingsGroup {
                    SettingsRow(
                        title: store.text(.onboardingEnableTitle),
                        systemImage: isExtensionEnabled ? "checkmark.seal" : "exclamationmark.triangle"
                    ) {
                        HStack(spacing: 7) {
                            StatusDot(color: isExtensionEnabled ? .green : .red)
                            Text(
                                isExtensionEnabled
                                    ? store.text(.onboardingEnableStatusOn)
                                    : store.text(.onboardingEnableStatusOff)
                            )
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button(store.text(.onboardingEnableOpenSettings)) {
                        FIFinderSyncController.showExtensionManagementInterface()
                    }
                    Button(store.text(.commonRefresh)) { refresh() }
                }
                Text(store.text(.onboardingEnableHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .authorizeFolders:
            step(
                title: store.text(.onboardingAuthorizeTitle),
                body: store.text(.onboardingAuthorizeBody)
            ) {
                SettingsGroup {
                    SettingsRow(
                        title: authorizedCountText,
                        systemImage: "folder.badge.plus"
                    ) {
                        Button(store.text(.onboardingAuthorizeChoose)) { authorize() }
                    }
                }
                if let authorizationError {
                    Text(authorizationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .ready:
            step(
                title: store.text(.onboardingReadyTitle),
                body: store.text(.onboardingReadyBody)
            ) {
                SettingsGroup {
                    SettingsRow(
                        title: store.text(.onboardingEnableTitle),
                        systemImage: isExtensionEnabled ? "checkmark.seal" : "exclamationmark.triangle"
                    ) {
                        Text(
                            isExtensionEnabled
                                ? store.text(.onboardingEnableStatusOn)
                                : store.text(.onboardingEnableStatusOff)
                        )
                        .foregroundStyle(isExtensionEnabled ? Color.secondary : Color.red)
                    }
                    SettingsRowDivider()
                    SettingsRow(
                        title: authorizedCountText,
                        systemImage: "folder"
                    ) {
                        EmptyView()
                    }
                }
                Button(store.text(.commonRestartApp)) { onRelaunch() }
                Text(store.text(.onboardingReadyRestartHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // Always available: a user who cannot grant a permission is not trapped.
            Button(store.text(.onboardingSkip)) { onSkip() }
                .buttonStyle(.link)
            Spacer()
            if let reasonKey = blockedReasonKey {
                Text(store.text(reasonKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !flow.isFirstStep {
                Button(store.text(.onboardingBack)) {
                    step = flow.step.previous ?? step
                    refresh()
                }
            }
            if flow.isLastStep {
                Button(store.text(.onboardingStart)) { onFinish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(store.text(.onboardingNext)) {
                    step = flow.step.next ?? step
                    refresh()
                }
                .keyboardShortcut(.defaultAction)
                // A step that has not happened cannot be walked past.
                .disabled(blockedReasonKey != nil)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    /// Non-nil while the current step's requirement is unmet.
    private var blockedReasonKey: StringKey? {
        flow.blockedReasonKey(
            isExtensionEnabled: isExtensionEnabled,
            authorizedFolderCount: authorizedCount
        )
    }

    /// Shared step layout: heading, paragraph, then the step-specific content.
    @ViewBuilder
    private func step<Content: View>(
        title: String,
        body: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.top, 14)
        }
        // Without this the sheet's spare height is shared out among the `Text`
        // children, which grow and leave a gap under every paragraph.
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    /// Re-reads both live states. The extension status comes from the framework,
    /// so returning from System Settings is enough — no restart involved.
    private func refresh() {
        isExtensionEnabled = FIFinderSyncController.isExtensionEnabled
        authorizedCount = authStore?.loadFolders().count ?? 0
    }

    private var authorizedCountText: String {
        String(format: store.text(.onboardingAuthorizeCount), authorizedCount)
    }

    private func authorize() {
        guard let authStore else { return }
        switch FolderAuthorizationAction.present(
            store: authStore,
            prompt: store.text(.onboardingAuthorizeChoose)
        ) {
        case .cancelled:
            break
        case .added:
            authorizationError = nil
        case .failed(let message):
            authorizationError = message
        }
        refresh()
    }
}
