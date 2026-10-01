import SwiftUI
import AppKit

/// Archive management pane: which formats are allowed, where extraction goes,
/// how name conflicts are resolved, and the memory guard.
///
/// RAR is listed as unsupported with the reason, so the absence of that menu
/// entry is explained rather than mysterious (decision D5-R1).
struct ArchiveSettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    /// Read-only peek at the folder authorizations, used for one warning: a
    /// chosen destination outside every authorized folder cannot be written to.
    @State private var authStore: FolderAuthorizationStore? = FolderAuthorizationStore.appGroupDefault()

    /// The size limit as the user is typing it. Kept separate from the stored
    /// value so an out-of-range number can be *shown while it is being typed*
    /// instead of being silently clamped mid-keystroke.
    @State private var sizeLimitText = ""
    /// Why the current `sizeLimitText` is not what will be stored; nil when it is.
    @State private var sizeLimitHint: String?
    @FocusState private var sizeLimitIsFocused: Bool

    private var settings: ArchiveSettings { store.settings.archives }

    /// True when 解压位置 points somewhere the sandbox will actually allow. An
    /// unreadable authorization list means "cannot tell", which must not produce
    /// a warning the user cannot act on.
    private var customDestinationIsAuthorized: Bool {
        guard settings.destination == .customFolder,
              let path = settings.customDestinationPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              let folders = authStore?.loadFolders()
        else { return true }
        return AuthorizedURLResolver.folderMatching(URL(fileURLWithPath: path), folders: folders) != nil
    }

    var body: some View {
        SettingsPane(
            title: store.text(.categoryArchives),
            subtitle: store.text(.archiveIntro)
        ) {
            formatsGroup
            behaviorGroup
            sizeLimitGroup
            noteGroup
        }
    }

    private var formatsGroup: some View {
        SettingsGroup(title: store.text(.archiveFormats)) {
            ForEach(Array(ArchiveFormat.allCases.enumerated()), id: \.element) { index, format in
                if format.isSupported {
                    SettingsToggleRow(
                        title: store.text(format.titleKey),
                        isOn: store.containsBinding(\.archives.enabledFormats, format)
                    )
                } else {
                    SettingsRow(
                        title: store.text(format.titleKey),
                        subtitle: store.text(.archiveFormatRARNote),
                        systemImage: "nosign",
                        isEnabled: false
                    ) {
                        SettingsBadge(text: store.text(.commonUnsupported), color: .secondary)
                    }
                }
                if index != ArchiveFormat.allCases.count - 1 {
                    SettingsRowDivider()
                }
            }
        }
    }

    private var behaviorGroup: some View {
        SettingsGroup(title: store.text(.archiveBehavior)) {
            SettingsRow(title: store.text(.archiveDestination), systemImage: "arrow.down.doc") {
                Picker("", selection: store.binding(\.archives.destination)) {
                    ForEach(ArchiveDestination.allCases, id: \.self) { destination in
                        Text(store.text(destination.titleKey)).tag(destination)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 200, alignment: .trailing)
            }
            if settings.destination == .customFolder {
                SettingsRowDivider()
                SettingsRow(
                    title: store.text(.commonPath),
                    subtitle: settings.customDestinationPath ?? store.text(.commonEmpty)
                ) {
                    Button(store.text(.commonEdit)) {
                        chooseCustomDestination()
                    }
                }
                if !customDestinationIsAuthorized {
                    SettingsRowDivider()
                    VStack(alignment: .leading, spacing: 4) {
                        Label(store.text(.archiveDestinationNotAuthorized), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(store.text(.archiveDestinationNotAuthorizedDetail))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsRowDivider()
            SettingsRow(title: store.text(.archiveConflict)) {
                Picker("", selection: store.binding(\.archives.conflictPolicy)) {
                    ForEach(ArchiveConflictPolicy.allCases, id: \.self) { policy in
                        Text(store.text(policy.titleKey)).tag(policy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 200, alignment: .trailing)
            }
            SettingsRowDivider()
            SettingsToggleRow(
                title: store.text(.archiveCleanup),
                isOn: store.binding(\.archives.deletesArchiveAfterExtraction)
            )
            SettingsRowDivider()
            SettingsToggleRow(
                title: store.text(.archiveSkipMetadata),
                isOn: store.binding(\.archives.skipsMetadataEntries)
            )
        }
    }

    /// 体积上限, as an editable field rather than a stepper-only readout.
    ///
    /// The value is typed far more often than it is nudged, and a stepper alone
    /// silently *refused* anything past its range — tap the up arrow at the
    /// maximum and nothing happens, with no explanation. Here the field takes
    /// what the user types, says which limit it hit, and stores the clamped
    /// value on commit.
    ///
    /// The hint therefore does double duty: it names the allowed range at rest
    /// (so the maximum is discoverable before typing anything) and replaces
    /// itself with the specific limit the moment the input breaks it.
    private var sizeLimitGroup: some View {
        SettingsGroup(
            title: store.text(.archiveSizeLimit),
            footer: store.text(.archiveFormatsFooter)
        ) {
            SettingsRow(
                title: store.text(.archiveSizeLimit),
                subtitle: sizeLimitHint ?? sizeLimitRangeHint,
                systemImage: "gauge.with.dots.needle.33percent"
            ) {
                HStack(spacing: 6) {
                    TextField("", text: $sizeLimitText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 76)
                        .focused($sizeLimitIsFocused)
                        .onSubmit { commitSizeLimit() }
                        .accessibilityLabel(store.text(.archiveSizeLimit))
                    Text(store.text(.archiveSizeLimitUnit))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Stepper(
                        "",
                        value: store.binding(\.archives.sizeLimitMB),
                        in: ArchiveSettings.sizeLimitRange
                    )
                    .labelsHidden()
                    .accessibilityLabel(store.text(.archiveSizeLimit))
                }
            }
        }
        .onAppear { sizeLimitText = formattedSizeLimit(settings.sizeLimitMB) }
        // The stepper, another window, or a launch marker can all change the
        // stored value; the field follows it.
        .onChange(of: settings.sizeLimitMB) { _, new in
            guard !sizeLimitIsFocused else { return }
            sizeLimitText = formattedSizeLimit(new)
            sizeLimitHint = nil
        }
        // Live, so 10000 tells the user the maximum while they are still typing.
        .onChange(of: sizeLimitText) { _, new in
            sizeLimitHint = hint(for: ArchiveSettings.interpretSizeLimit(new))
        }
        .onChange(of: sizeLimitIsFocused) { _, focused in
            // Editing works on plain digits; at rest the row shows the grouped
            // form ("1,024 MB") that matches the rest of the pane.
            sizeLimitText = focused ? String(settings.sizeLimitMB) : formattedSizeLimit(settings.sizeLimitMB)
            if !focused { commitSizeLimit() }
        }
    }

    /// "可输入 1–8,192 MB" — the allowed range, always visible.
    private var sizeLimitRangeHint: String {
        String(
            format: store.text(.archiveSizeLimitRangeHint),
            formattedSizeLimit(ArchiveSettings.sizeLimitRange.lowerBound),
            formattedSizeLimit(ArchiveSettings.sizeLimitRange.upperBound)
        )
    }

    private func formattedSizeLimit(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// The message for an entry that will not be stored as typed.
    private func hint(for entry: ArchiveSettings.SizeLimitEntry) -> String? {
        switch entry {
        case .accepted:
            return nil
        case .aboveMaximum:
            return String(
                format: store.text(.archiveSizeLimitMaxHint),
                formattedSizeLimit(ArchiveSettings.sizeLimitRange.upperBound)
            )
        case .belowMinimum:
            return String(
                format: store.text(.archiveSizeLimitMinHint),
                formattedSizeLimit(ArchiveSettings.sizeLimitRange.lowerBound)
            )
        case .unusable:
            return store.text(.archiveSizeLimitInvalidHint)
        }
    }

    /// Applies what is in the field. Never leaves an invalid setting behind: the
    /// clamped value is stored and the text is rewritten to match, so the field
    /// and the setting cannot drift apart.
    private func commitSizeLimit() {
        switch ArchiveSettings.interpretSizeLimit(sizeLimitText) {
        case .accepted(let value), .aboveMaximum(let value), .belowMinimum(let value):
            store.mutate { $0.archives.sizeLimitMB = value }
            sizeLimitText = formattedSizeLimit(value)
        case .unusable:
            // Revert to what is stored rather than guessing a number.
            sizeLimitText = formattedSizeLimit(settings.sizeLimitMB)
        }
    }

    private var noteGroup: some View {
        SettingsGroup(title: store.text(.sectionImplementationStatus)) {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.text(.archiveNote))
                Text(store.text(.archiveSecurity))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseCustomDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = store.text(.commonConfirm)
        panel.directoryURL = settings.customDestinationPath.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.mutate { $0.archives.customDestinationPath = url.path }
    }
}
