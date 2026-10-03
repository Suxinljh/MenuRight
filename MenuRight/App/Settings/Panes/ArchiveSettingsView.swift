import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Archive management pane: which formats are allowed, where extraction goes,
/// how name conflicts are resolved, and the memory guard.
///
/// RAR is listed as unsupported with the reason, so the absence of that menu
/// entry is explained rather than mysterious (decision D5-R1).
struct ArchiveSettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    /// The 密码本 lives in the Keychain, not in `MenuRightSettings`; the pane
    /// only edits it through this object.
    @EnvironmentObject private var passwordBook: ArchivePasswordBook
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

    /// Rows whose password is shown in clear text (per row, never global).
    @State private var revealing: Set<UUID> = []
    /// Rows the minus button acts on.
    @State private var selection: Set<UUID> = []
    /// Result of the last 批量导入 / 批量导出.
    @State private var bookMessage: BookMessage?
    /// 导入/导出前的一次确认，nil 表示没有待确认的动作。
    @State private var pendingPasswordBookAction: PasswordBookAction?
    /// 解压位置 是否落在已授权目录里。缓存进 `@State`：`loadFolders()`（以及它
    /// 内部的 `AuthorizedURLResolver.status(for:)`）会 start/stop security-scoped
    /// access，绝不能进 body —— 与 FolderAccessView 同一规则。刷新时机：出现、
    /// 应用重新激活、以及用户改完自定义目录之后。
    @State private var customDestinationIsAuthorized = true

    private struct BookMessage {
        var text: String
        var isFailure: Bool
    }

    /// 密码本的两个批量方向。两者都会改变或暴露密码，所以确认文案要说准。
    private enum PasswordBookAction: Equatable {
        case importBook
        case exportBook

        var titleKey: StringKey {
            switch self {
            case .importBook: return .archivePasswordBookImportConfirmTitle
            case .exportBook: return .archivePasswordBookExportPlaintextTitle
            }
        }

        var messageKey: StringKey {
            switch self {
            case .importBook: return .archivePasswordBookImportConfirmMessage
            case .exportBook: return .archivePasswordBookExportPlaintextMessage
            }
        }
    }

    private var settings: ArchiveSettings { store.settings.archives }

    var body: some View {
        SettingsPane(
            title: store.text(.categoryArchives),
            subtitle: store.text(.archiveIntro)
        ) {
            formatsGroup
            behaviorGroup
            sizeLimitGroup
            passwordBookGroup
        }
        .onAppear { reloadCustomDestinationAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadCustomDestinationAuthorization()
        }
        // 非模态确认：导入是合并覆盖，导出是明文落盘，都先说清楚再弹面板。
        .alert(
            pendingPasswordBookAction.map { store.text($0.titleKey) } ?? "",
            isPresented: Binding(
                get: { pendingPasswordBookAction != nil },
                set: { if !$0 { pendingPasswordBookAction = nil } }
            ),
            presenting: pendingPasswordBookAction
        ) { action in
            Button(store.text(.commonConfirm)) { performPasswordBookAction(action) }
            Button(store.text(.commonCancel), role: .cancel) { pendingPasswordBookAction = nil }
        } message: { action in
            Text(store.text(action.messageKey))
        }
    }

    /// 只在明确要求时读磁盘/授权表，body 里只看这个缓存值。
    private func reloadCustomDestinationAuthorization() {
        let current = store.settings.archives
        guard current.destination == .customFolder,
              let path = current.customDestinationPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              let folders = authStore?.loadFolders()
        else {
            customDestinationIsAuthorized = true
            return
        }
        customDestinationIsAuthorized = AuthorizedURLResolver.folderMatching(URL(fileURLWithPath: path), folders: folders) != nil
    }

    private func performPasswordBookAction(_ action: PasswordBookAction) {
        pendingPasswordBookAction = nil
        switch action {
        case .importBook: importPasswords()
        case .exportBook: exportPasswords()
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
        SettingsGroup(title: store.text(.archiveSizeLimit)) {
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

    // MARK: - 密码本

    /// The book itself: one editable row per saved password, the bulk
    /// import/export pair, and the 自动保存 switch — FastZip's layout, with the
    /// Keychain instead of a plist behind it.
    private var passwordBookGroup: some View {
        SettingsGroup(title: store.text(.archivePasswordBookTitle)) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsToggleRow(
                    title: store.text(.archivePasswordBookAutoSave),
                    isOn: store.binding(\.archives.remembersCompressionPassword)
                )
                SettingsRowDivider()

                if passwordBook.isEmpty {
                    Text(store.text(.archivePasswordBookEmpty))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    passwordHeaderRow
                    SettingsRowDivider()
                    ForEach(Array(passwordBook.entries.enumerated()), id: \.element.id) { index, entry in
                        passwordRow(index: index, entry: entry)
                        if index < passwordBook.entries.count - 1 {
                            SettingsRowDivider()
                        }
                    }
                }

                SettingsRowDivider()
                HStack(spacing: 8) {
                    Button {
                        passwordBook.add(name: "", password: "")
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help(store.text(.commonAdd))
                    Button {
                        passwordBook.remove(ids: removableSelection)
                        selection = []
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selection.isEmpty)
                    .help(store.text(.commonRemove))
                    Spacer(minLength: 12)
                    Button(store.text(.archivePasswordBookImport)) { pendingPasswordBookAction = .importBook }
                    Button(store.text(.archivePasswordBookExport)) { pendingPasswordBookAction = .exportBook }
                        .disabled(passwordBook.isEmpty)
                }

                if let bookMessage {
                    Text(bookMessage.text)
                        .font(.caption)
                        .foregroundStyle(bookMessage.isFailure ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                if let storageError = passwordBook.storageError {
                    Text(String(format: store.text(.archivePasswordBookStorageFailed), storageError))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
        }
    }

    private var passwordHeaderRow: some View {
        HStack(spacing: 10) {
            Text(store.text(.archivePasswordBookSequence))
                .frame(width: 28, alignment: .trailing)
            Text(store.text(.archivePasswordBookName))
                .frame(width: 150, alignment: .leading)
            Text(store.text(.archivePassword))
                .frame(maxWidth: .infinity, alignment: .leading)
            // Reserve the remove button's width so the columns stay put.
            Text("").frame(width: 20)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    private func passwordRow(index: Int, entry: ArchivePassword) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            TextField("", text: nameBinding(for: entry.id))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
            Group {
                if revealing.contains(entry.id) {
                    TextField("", text: passwordBinding(for: entry.id))
                } else {
                    SecureField("", text: passwordBinding(for: entry.id))
                }
            }
            .textFieldStyle(.roundedBorder)
            Button {
                if revealing.contains(entry.id) {
                    revealing.remove(entry.id)
                } else {
                    revealing.insert(entry.id)
                }
            } label: {
                Image(systemName: revealing.contains(entry.id) ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(store.text(revealing.contains(entry.id) ? .archivePasswordBookHide : .archivePasswordBookReveal))
            Button {
                passwordBook.remove(ids: [entry.id])
                selection.remove(entry.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(width: 20)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selection.contains(entry.id) ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if selection.contains(entry.id) {
                selection.remove(entry.id)
            } else {
                selection.insert(entry.id)
            }
        }
    }

    /// Ids the minus button removes: whatever the user selected in the list.
    private var removableSelection: Set<UUID> { selection }

    /// Rows write through to the book on every keystroke. The Keychain write is
    /// cheap next to a redraw, and it means a crash or a quit cannot lose what
    /// is on screen — the alternative (a draft per row plus commit on blur)
    /// exists only to batch the same writes. The cost is one Keychain write per
    /// keystroke per field; a failing write is surfaced in `storageError` just
    /// below the rows rather than being swallowed.
    private func nameBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { passwordBook.entry(id: id)?.name ?? "" },
            set: { newValue in
                guard let entry = passwordBook.entry(id: id) else { return }
                passwordBook.update(id: id, name: newValue, password: entry.password)
            }
        )
    }

    private func passwordBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { passwordBook.entry(id: id)?.password ?? "" },
            set: { newValue in
                guard let entry = passwordBook.entry(id: id) else { return }
                passwordBook.update(id: id, name: entry.name, password: newValue)
            }
        )
    }

    /// 只在确认「会与现有密码本合并、同名条目被覆盖」之后运行。
    private func importPasswords() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = store.text(.archivePasswordBookImport)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try passwordBook.importEntries(from: url)
            bookMessage = BookMessage(
                text: String(format: store.text(.archivePasswordBookImported), "\(count)"),
                isFailure: false
            )
        } catch {
            bookMessage = BookMessage(
                text: String(format: store.text(.archivePasswordBookImportFailed), error.localizedDescription),
                isFailure: true
            )
        }
    }

    /// 只在确认「导出的 JSON 是明文」之后运行。
    private func exportPasswords() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MenuRight-Passwords.json"
        panel.allowedContentTypes = [.json]
        panel.prompt = store.text(.archivePasswordBookExport)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try passwordBook.exportEntries(to: url)
            bookMessage = BookMessage(
                text: String(format: store.text(.archivePasswordBookExported), "\(passwordBook.entries.count)"),
                isFailure: false
            )
        } catch {
            bookMessage = BookMessage(
                text: String(format: store.text(.archivePasswordBookExportFailed), error.localizedDescription),
                isFailure: true
            )
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
        // 新目录是否在授权范围内，得重新查一次授权表（body 只读缓存）。
        reloadCustomDestinationAuthorization()
    }
}
