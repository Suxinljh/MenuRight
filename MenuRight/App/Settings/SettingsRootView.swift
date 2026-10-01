import AppKit
import FinderSync
import SwiftUI

/// The app's main window: a native macOS sidebar of settings categories on the
/// left, the selected pane on the right.
///
/// `NavigationSplitView` + `.listStyle(.sidebar)` is the system source-list
/// look, so selection, keyboard navigation, and the sidebar toggle in the
/// titlebar all behave the way a Mac app should.
struct SettingsRootView: View {
    @StateObject private var store = SettingsStore.shared
    @State private var selection: SettingsCategory? = SettingsRootView.initialCategory()
    @State private var showsResetConfirmation = false
    /// Set once the guide has been finished; "Not Now" only hides it for this
    /// launch, so a still-disabled extension brings it back next time.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @StateObject private var archiveRequests = ArchiveRequestCenter.shared
    @State private var showsOnboarding = false
    @State private var onboardingStep: OnboardingStep = .enableExtension

    /// Pane shown first. `MENURIGHT_SETTINGS_PANE` (Debug builds only) selects
    /// another pane, which is how each pane is screenshotted during manual
    /// verification without clicking through the sidebar. Same opt-in style as
    /// `MENURIGHT_SELFTEST_OPEN_TERMINAL`.
    private static func initialCategory() -> SettingsCategory {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["MENURIGHT_SETTINGS_PANE"],
           let category = SettingsCategory(rawValue: raw) {
            return category
        }
        #endif
        return SettingsCategory.default
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, minHeight: 640)
        .environmentObject(store)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsResetConfirmation = true
                } label: {
                    Label(store.text(.commonResetAll), systemImage: "arrow.counterclockwise")
                }
                .help(store.text(.commonResetAllMessage))
            }

            // Right of the reset button, as requested. It restarts the *app*; the
            // tooltip says out loud that settings do not need one, so the button
            // cannot be mistaken for "apply my changes".
            ToolbarItem(placement: .primaryAction) {
                Button {
                    relaunch()
                } label: {
                    Label(store.text(.commonRestartApp), systemImage: "arrow.triangle.2.circlepath")
                }
                .help(store.text(.commonRestartAppHint))
            }
        }
        // P9 stage 3: a Finder "自定义压缩…" parks a request here; the sheet
        // edits it and performs the compression. The environment (and therefore
        // the SettingsStore) is inherited by the sheet.
        .sheet(item: $archiveRequests.pending) { request in
            CustomCompressionSheet(request: request, center: archiveRequests) {}
        }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView(
                step: $onboardingStep,
                onFinish: {
                    hasCompletedOnboarding = true
                    showsOnboarding = false
                },
                onSkip: { showsOnboarding = false },
                onRelaunch: { relaunch() }
            )
            .environmentObject(store)
        }
        .onAppear(perform: presentOnboardingIfNeeded)
        .alert(store.text(.commonResetAll), isPresented: $showsResetConfirmation) {
            Button(store.text(.commonCancel), role: .cancel) {}
            Button(store.text(.commonReset), role: .destructive) {
                store.resetAll()
            }
        } message: {
            Text(store.text(.commonResetAllMessage))
        }
    }

    // MARK: - First-run guide

    /// Shows the guide on first run, and again whenever the Finder extension is
    /// off — with the extension disabled the app cannot do anything, so that is
    /// the right moment to put the two required steps in front of the user.
    private func presentOnboardingIfNeeded() {
        if let forced = Self.reviewOnboardingStep() {
            onboardingStep = forced
            showsOnboarding = true
            return
        }
        onboardingStep = .enableExtension
        showsOnboarding = OnboardingFlow.shouldPresent(
            hasCompleted: hasCompletedOnboarding,
            isExtensionEnabled: FIFinderSyncController.isExtensionEnabled
        )
    }

    /// Review hook: `MENURIGHT_ONBOARDING=enable|authorize|ready` opens the guide
    /// at that step so each one can be screenshotted without clicking through.
    private static func reviewOnboardingStep() -> OnboardingStep? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["MENURIGHT_ONBOARDING"]?.lowercased() {
        case "enable": return .enableExtension
        case "authorize": return .authorizeFolders
        case "ready": return .ready
        default: return nil
        }
        #else
        return nil
        #endif
    }

    /// Quits and starts a fresh copy of the app.
    ///
    /// `createsNewApplicationInstance` lets the replacement start while this
    /// process is still alive, so the handover cannot leave the user with no
    /// running app. This restarts the app only: Finder owns the extension, and
    /// the extension re-reads the shared settings on every menu build, so no
    /// restart is required for a setting to take effect.
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                guard error == nil else {
                    LifecycleDiagnostics.record(
                        "relaunch failed: \(String(describing: error))",
                        from: "main-app"
                    )
                    return
                }
                LifecycleDiagnostics.record("relaunch: handing over to a new instance", from: "main-app")
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Title lockup. It lives in the sidebar column, so it collapses with
            // the sidebar toggle and keeps the column's material background.
            SidebarBrandHeader(versionText: store.sidebarVersionText)

            // No `List(selection:)`: macOS draws the table's own selection pill
            // *above* whatever `listRowBackground` provides, so a custom corner
            // radius can only ever be an extra layer around the system one (that
            // was the reported "外面套了一层"). The rows therefore own the whole
            // look — selected, hovered and idle share one shape and one radius.
            List {
                ForEach(SettingsCategory.sections) { section in
                    Section(store.text(section.titleKey)) {
                        ForEach(section.categories) { category in
                            SidebarCategoryRow(
                                title: store.text(category.titleKey),
                                assetName: category.iconAsset,
                                isSelected: selection == category
                            ) {
                                selection = category
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // The selection is ours now, so arrow keys are ours to implement.
            .onMoveCommand { direction in moveSelection(direction) }
        }
        .navigationSplitViewColumnWidth(min: 196, ideal: 214, max: 260)
    }

    /// Arrow-key navigation over the flattened category list.
    private func moveSelection(_ direction: MoveCommandDirection) {
        let categories = SettingsCategory.sections.flatMap(\.categories)
        guard !categories.isEmpty else { return }
        let current = selection ?? SettingsCategory.default
        guard let index = categories.firstIndex(of: current) else { return }
        switch direction {
        case .up:
            selection = categories[max(0, index - 1)]
        case .down:
            selection = categories[min(categories.count - 1, index + 1)]
        default:
            break
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection ?? SettingsCategory.default {
        case .filePermissions:
            FilePermissionSettingsView()
        case .folderPermissions:
            FolderPermissionSettingsView()
        case .general:
            GeneralSettingsView()
        case .newFile:
            NewFileSettingsView()
        case .favoriteFolders:
            FavoriteFoldersSettingsView()
        case .favoriteApps:
            FavoriteAppsSettingsView()
        case .favoriteWebsites:
            FavoriteWebsitesSettingsView()
        case .codeTheme:
            CodeThemeSettingsView()
        case .archives:
            ArchiveSettingsView()
        }
    }
}

#Preview {
    SettingsRootView()
}

/// One sidebar row, drawn by us.
///
/// A `List(selection:)` row would get the system's selection pill *on top of*
/// our background, so the radius could never actually change. Owning the row
/// means selected/hovered/idle are three states of one shape — which is also why
/// the hover and the selection look consistent instead of mismatched.
private struct SidebarCategoryRow: View {
    let title: String
    let assetName: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SettingsMetrics.sidebarSelectionCornerRadius, style: .continuous)
    }

    /// Selected rows are white-on-accent; idle rows follow the label colour.
    private var foreground: Color { isSelected ? .white : .primary }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            // The style has to sit on the icon itself; it is *not* redundant with
            // the `.foregroundStyle(foreground)` further down.
            //
            // `.listStyle(.sidebar)` re-applies its own foreground style to a
            // label's icon slot from the outside, so the row-level style reaches
            // the text but never the glyph: the selected row drew white text next
            // to a black icon on the accent pill. Measured 2026-10-01 by
            // offscreen-rendering this row inside a sidebar `List` — row-level
            // style only gave rgb(0,0,0), style on the icon gives white.
            // `.tint()` does not help; an explicit `HStack` does, but then the
            // row loses `Label`'s spacing and accessibility semantics.
            AssetIcon(assetName: assetName)
                .foregroundStyle(foreground)
        }
        .foregroundStyle(foreground)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            shape.fill(
                isSelected
                    ? Color.accentColor
                    : (isHovering ? Color.primary.opacity(0.10) : Color.clear)
            )
        )
        .contentShape(shape)
        .onHover { isHovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
