import SwiftUI
import AppKit

/// New File pane: the default file name, which kinds the Finder submenu offers,
/// their order, and which folder supplies the blank templates — with a live
/// preview of the resulting menu.
struct NewFileSettingsView: View {
    @EnvironmentObject private var store: SettingsStore

    private var settings: NewFileSettings { store.settings.newFile }

    var body: some View {
        SettingsPane(
            title: store.text(.categoryNewFile),
            subtitle: store.text(.newFileIntro)
        ) {
            baseNameGroup
            typesGroup
            templateDirectoryGroup
            previewGroup
        }
    }

    /// P7: the blank iWork templates normally come from the app bundle, but a
    /// user may point 新建文件 at their own folder of `blank.pages` /
    /// `blank.numbers` / `blank.key`. The path travels to the main app; the
    /// resolution (and the fallback to the bundle) lives in
    /// `DocumentTemplateCatalog`.
    private var templateDirectoryGroup: some View {
        SettingsGroup(
            title: store.text(.newFileTemplateDirectory),
            footer: store.text(.newFileTemplateDirectoryFooter)
        ) {
            SettingsRow(
                title: store.text(.newFileTemplateDirectory),
                subtitle: templateDirectorySubtitle,
                systemImage: "folder",
                subtitleLineLimit: 1
            ) {
                HStack(spacing: 8) {
                    Button(store.text(.newFileTemplateDirectoryChoose)) { chooseTemplateDirectory() }
                    if settings.hasCustomTemplateDirectory {
                        Button(store.text(.newFileTemplateDirectoryReset)) { resetTemplateDirectory() }
                    }
                }
            }
            if DocumentTemplateCatalog.hasBrokenOverride(for: settings) {
                Text(store.text(.newFileTemplateDirectoryMissing))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
        }
    }

    private var templateDirectorySubtitle: String {
        guard let directory = DocumentTemplateCatalog.resolvedDirectory(for: settings) else {
            return store.text(.commonUnsupported)
        }
        return directory.path
    }

    private func chooseTemplateDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = store.text(.newFileTemplateDirectoryChoose)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The dispatcher copies templates while holding the scoped access it
        // already has for the destination folder; the bookmark is kept so a
        // custom folder outside the sandbox can be granted once and reused.
        let bookmark = try? SecurityScopedBookmark.create(for: url)
        store.mutate {
            $0.newFile.templateDirectoryPath = url.path
            $0.newFile.templateDirectoryBookmark = bookmark
        }
        publishTemplateAvailability()
    }

    private func resetTemplateDirectory() {
        store.mutate {
            $0.newFile.templateDirectoryPath = ""
            $0.newFile.templateDirectoryBookmark = nil
        }
        publishTemplateAvailability()
    }

    /// The Finder submenu reads the published availability; republish at once so
    /// the next right-click already knows what the new folder can supply.
    private func publishTemplateAvailability() {
        DocumentTemplateCatalog.publishAvailability(settings: store.settings.newFile)
    }

    private var baseNameGroup: some View {
        SettingsGroup(
            title: store.text(.newFileBaseName),
            footer: store.text(.newFileBaseNameFooter)
        ) {
            SettingsRow(title: store.text(.newFileBaseName), systemImage: "textformat") {
                TextField("", text: store.binding(\.newFile.baseName))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
        }
    }

    private var typesGroup: some View {
        SettingsGroup(
            title: store.text(.newFileTypes),
            footer: typesFooter
        ) {
            ForEach(Array(settings.types.enumerated()), id: \.element) { index, type in
                typeRow(type, index: index, count: settings.types.count)
                if index != settings.types.count - 1 {
                    SettingsRowDivider()
                }
            }
        }
    }

    /// Reorder/count hint plus — only when something is actually missing — the
    /// blank-template files the user has to supply. There is no separate
    /// "implementation status" card: naming the missing file is the only part of
    /// that note that changes what the user can do.
    private var typesFooter: String {
        var lines = [
            "\(store.text(.commonReorderHint)) · \(store.enabledCountText(settings.enabledTypes.count, NewFileType.allCases.count))"
        ]
        if !missingTemplateFileNames.isEmpty {
            lines.append(store.text(.newFileMissingTemplates) + " " + missingTemplateFileNames.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// Blank templates the resolved folder does not carry, so the pane and the
    /// Finder submenu tell the same story. Resolved — not `bundledDirectory` —
    /// because 模板目录 can be overridden.
    private var missingTemplateFileNames: [String] {
        DocumentTemplateCatalog
            .missingTemplateTypes(in: DocumentTemplateCatalog.resolvedDirectory(for: settings))
            .compactMap { DocumentTemplateCatalog.templateFileName(for: $0) }
    }

    private func hasTemplate(_ type: NewFileType) -> Bool {
        DocumentTemplateCatalog.canCreate(
            type,
            in: DocumentTemplateCatalog.resolvedDirectory(for: settings)
        )
    }

    private var previewGroup: some View {
        SettingsGroup(title: store.text(.newFilePreview)) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "doc.badge.plus")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(store.text(.categoryNewFile))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            let enabled = settings.types.filter { settings.enabledTypes.contains($0) }
            if enabled.isEmpty {
                SettingsRowDivider()
                SettingsEmptyHint(text: store.text(.commonEmpty))
            } else {
                ForEach(enabled, id: \.self) { type in
                    SettingsRowDivider()
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        AssetIcon(assetName: type.iconAsset)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(store.text(type.titleKey))
                        if type.requiresTemplate && !hasTemplate(type) {
                            SettingsBadge(text: store.text(.newFileTemplateMissingBadge), color: .orange)
                        }
                        Spacer()
                        Text(type.defaultFileName(baseName: settings.baseName))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 22)
                }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func typeRow(_ type: NewFileType, index: Int, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            AssetIcon(assetName: type.iconAsset)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            HStack(spacing: 6) {
                Text(store.text(type.titleKey))
                if type.requiresTemplate && !hasTemplate(type) {
                    SettingsBadge(text: store.text(.newFileTemplateMissingBadge), color: .orange)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                Button {
                    move(type, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help(store.text(.commonMoveUp))

                Button {
                    move(type, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(index >= count - 1)
                .help(store.text(.commonMoveDown))
            }
            Toggle("", isOn: store.containsBinding(\.newFile.enabledTypes, type))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private func move(_ type: NewFileType, by offset: Int) {
        store.mutate { settings in
            guard let index = settings.newFile.types.firstIndex(of: type) else { return }
            let destination = index + offset
            guard settings.newFile.types.indices.contains(destination) else { return }
            settings.newFile.types.swapAt(index, destination)
        }
    }
}
