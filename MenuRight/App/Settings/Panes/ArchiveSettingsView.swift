import SwiftUI
import AppKit

/// Archive management pane: which formats are allowed, where extraction goes,
/// how name conflicts are resolved, and the memory guard.
///
/// RAR is listed as unsupported with the reason, so the absence of that menu
/// entry is explained rather than mysterious (decision D5-R1).
struct ArchiveSettingsView: View {
    @EnvironmentObject private var store: SettingsStore

    private var settings: ArchiveSettings { store.settings.archives }

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

    private var sizeLimitGroup: some View {
        SettingsGroup(
            title: store.text(.archiveSizeLimit),
            footer: store.text(.archiveFormatsFooter)
        ) {
            SettingsRow(title: store.text(.archiveSizeLimit), systemImage: "gauge.with.dots.needle.33percent") {
                Stepper(
                    value: store.binding(\.archives.sizeLimitMB),
                    in: ArchiveSettings.sizeLimitRange
                ) {
                    Text("\(store.settings.archives.sizeLimitMB) \(store.text(.archiveSizeLimitUnit))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
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
