import SwiftUI
import AppKit
import os

/// A compression the Finder asked for, waiting for the user to confirm it in the
/// custom-compression dialog.
struct PendingArchiveRequest: Identifiable, Equatable {
    let id = UUID()
    let sources: [URL]
    let directory: URL
    var name: String
    var label: String
    var format: ArchiveFormat
    var mode: ArchiveCompressionMode
    /// 固实压缩 (7z only). Part of the parked request so the self-test can ask
    /// for a non-solid archive without going through the dialog.
    var solid: Bool = true
    /// 加密文件名 (7z only): encrypt the header too, not just the content.
    var encryptsFileNames: Bool = false
    /// 分卷压缩: the maximum size of one part in MB, nil for a single file.
    var volumeSizeMB: Int?
}

/// Anything that can put a parked request on screen: the process-level dialog
/// window in the running app, or a spy in a unit test.
protocol ArchiveDialogPresenting: AnyObject {
    func show(_ request: PendingArchiveRequest)
    func close()
}

/// Main-thread hand-off between the IPC dispatcher and the dialog.
///
/// The dispatcher runs on a connection queue and must never block on UI, so it
/// parks the request here and returns; the presenter puts it on screen.
/// `@Published` mutation happens on the main thread (the dispatcher hops before
/// calling `present`).
final class ArchiveRequestCenter: ObservableObject {
    static let shared = ArchiveRequestCenter()

    private static let log = Logger(subsystem: "xin.ljhsu.MenuRight", category: "archive-dialog")

    @Published var pending: PendingArchiveRequest?

    /// Test seam. Production leaves this `nil` and `activePresenter` falls back to
    /// the process-level dialog window, so the dialog cannot be silently lost by
    /// forgetting to wire a presenter at launch.
    var presenter: (any ArchiveDialogPresenting)?

    private var activePresenter: (any ArchiveDialogPresenting)? {
        if let presenter { return presenter }
        // Only a process with an `NSApplication` can put a window on screen. A
        // test bundle usually has none — but AppKit creates one as soon as a test
        // makes a window, and then this fallback builds the real dialog there too,
        // which is exactly what `CustomCompressionDialogTests` asserts.
        guard NSApp != nil else { return nil }
        return CustomCompressionDialogWindow.shared
    }

    private init() {}

    /// Parks a request and brings the app forward so the dialog is actually seen:
    /// a Finder action can arrive while MenuRight is behind other windows — or
    /// with *no* window open at all, which is why the dialog is owned by the
    /// process instead of by the settings window (2026-10-03).
    func present(_ request: PendingArchiveRequest) {
        let show = {
            self.pending = request
            NSApp?.activate(ignoringOtherApps: true)
            self.activePresenter?.show(request)
            Self.log.info("ARCHIVE dialog presented sources=\(request.sources.count, privacy: .public) format=\(request.format.rawValue, privacy: .public)")
        }
        if Thread.isMainThread {
            show()
        } else {
            DispatchQueue.main.async(execute: show)
        }
    }

    func dismiss() {
        pending = nil
        activePresenter?.close()
    }
}

/// Cross-thread "stop" flag for one compression run.
///
/// 取消 dismisses the sheet immediately, but the tree walk keeps running on a
/// background queue until it notices — this flag is the hand-off between the two
/// threads. A fresh instance is created for every run, so a cancel can never
/// Main-thread folder picker for "解压到指定位置…".
///
/// Lives here rather than in the dispatcher so that the dispatcher stays free of
/// AppKit and can be unit-tested with an injected directory.
enum FolderChooser {
    static func chooseDirectory() -> URL? {
        var chosen: URL?
        let present = {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = NSLocalizedString("Choose", comment: "NSOpenPanel default button")
            if panel.runModal() == .OK { chosen = panel.url }
        }
        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.sync(execute: present)
        }
        return chosen
    }
}

/// The native folder popup used by 位置.
///
/// SwiftUI's `Picker` cannot show a file's *own* icon, and hand-rolling the row
/// ended up looking like a text field. Finder and the system panels use an
/// `NSPopUpButton` for a location (参考图一: the folder's Finder icon, its name and
/// the up/down chevrons), so the row is a thin AppKit wrapper around exactly that.
///
/// The menu offers the folder currently selected, the ones this dialog already
/// visited, and 「选择…」 (which comes back as `nil`, meaning "open the panel").
struct NativeFolderPicker: NSViewRepresentable {
    let directory: URL
    let recent: [URL]
    let chooseTitle: String
    let onPick: (URL?) -> Void

    /// One row of the popup's menu, as data: the mapping from folders to menu
    /// entries is the part worth testing, and it needs no AppKit.
    struct Entry: Equatable {
        let title: String
        let url: URL?
        let isSeparator: Bool
    }

    /// 位置's menu: the folder we are writing into, then the ones this dialog has
    /// already visited (without repeating it), then 「选择…」 — which carries no URL
    /// and means "open the system panel".
    static func menu(directory: URL, recent: [URL], chooseTitle: String) -> [Entry] {
        var entries = [Entry(title: title(for: directory), url: directory, isSeparator: false)]
        let others = recent.filter { $0.path != directory.path }
        if !others.isEmpty {
            entries.append(Entry(title: "", url: nil, isSeparator: true))
            entries += others.map { Entry(title: title(for: $0), url: $0, isSeparator: false) }
        }
        entries.append(Entry(title: "", url: nil, isSeparator: true))
        entries.append(Entry(title: chooseTitle, url: nil, isSeparator: false))
        return entries
    }

    private static func title(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .rounded
        button.imagePosition = .imageLeading
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        // A long folder name shortens in the middle, like the system does.
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onPick = onPick
        button.removeAllItems()
        for entry in Self.menu(directory: directory, recent: recent, chooseTitle: chooseTitle) {
            guard !entry.isSeparator else {
                button.menu?.addItem(.separator())
                continue
            }
            let item = NSMenuItem()
            item.title = entry.title
            item.representedObject = entry.url
            if let url = entry.url { item.image = Self.icon(for: url) }
            button.menu?.addItem(item)
        }
        // Item 0 is the folder we are writing into, so the button shows its name.
        button.selectItem(at: 0)
    }

    /// The folder's own Finder icon — including its tag colour, which is what makes
    /// the native control recognisable at a glance.
    private static func icon(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    final class Coordinator: NSObject {
        var onPick: (URL?) -> Void

        init(onPick: @escaping (URL?) -> Void) {
            self.onPick = onPick
        }

        @objc func picked(_ sender: NSPopUpButton) {
            let url = sender.selectedItem?.representedObject as? URL
            // 「选择…」 leaves the popup showing its own title; put the folder back
            // before the panel opens.
            if url == nil { sender.selectItem(at: 0) }
            onPick(url)
        }
    }
}

/// The custom-compression sheet: 保存为 / 标签 / 位置 / 压缩格式 / 压缩模式, plus
/// 加密压缩 / 分卷压缩 / 固实压缩.
///
/// The form is deliberately terse (2026-10-03, 用户要求): the long grey
/// explanations that used to sit under every control are gone from the front end,
/// and the same sentences survive as tooltips. Whatever the chosen format cannot
/// carry is still visible but greyed out, so the option never disappears.
struct CustomCompressionSheet: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var passwordBook: ArchivePasswordBook
    @ObservedObject var center: ArchiveRequestCenter

    /// Working copy: nothing is written until 保存.
    @State private var name: String
    @State private var label: String
    @State private var directory: URL
    @State private var format: ArchiveFormat
    @State private var mode: ArchiveCompressionMode
    @State private var encrypts = false
    @State private var encryptsFileNames = false
    @State private var password = ""
    @State private var revealsPassword = false
    @State private var volumeSizeMB: Int?
    @State private var solid = true
    @State private var errorText: String?
    @State private var isWorking = false
    @State private var control: ArchiveOperationControl?
    /// Folders picked in this dialog, offered by the 位置 popup's menu.
    @State private var recents: [URL] = []

    /// 分卷 compression sizes offered in the dialog. 10 MB is small enough to see
    /// a split happen while testing, 700 MB is a CD and the largest anyone still
    /// asks for.
    static let volumeSizes = [10, 50, 100, 250, 700]

    private let sources: [URL]
    private let onDone: () -> Void

    init(request: PendingArchiveRequest, center: ArchiveRequestCenter, onDone: @escaping () -> Void) {
        _name = State(initialValue: request.name)
        _label = State(initialValue: request.label)
        _directory = State(initialValue: request.directory)
        _format = State(initialValue: request.format)
        _mode = State(initialValue: request.mode)
        _solid = State(initialValue: request.solid)
        _encryptsFileNames = State(initialValue: request.encryptsFileNames)
        _volumeSizeMB = State(initialValue: request.volumeSizeMB)
        self.sources = request.sources
        self.center = center
        self.onDone = onDone
    }

    /// Compressed variants always wrap a TAR, so the suffix follows the format.
    private var writtenName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Archive" : trimmed
        let extensionName = ArchiveCompressor.fileNameExtension(for: format) ?? "zip"
        // Never double up an extension the user typed themselves.
        if base.lowercased().hasSuffix(".\(extensionName)") { return base }
        let withoutSuffix = (base as NSString).deletingPathExtension
        return "\(withoutSuffix.isEmpty ? base : withoutSuffix).\(extensionName)"
    }

    /// Only ZIP carries an archive comment, so the field is disabled elsewhere
    /// instead of silently dropping what the user typed.
    private var labelIsStored: Bool { format == .zip }

    /// 允许的压缩格式 filters this picker as well, so the setting cannot be
    /// bypassed from the dialog. It never narrows to nothing, though: with every
    /// box unticked the dialog falls back to the four formats this build can
    /// write, because an unusable dialog is worse than a setting being odd.
    private var selectableFormats: [ArchiveFormat] {
        let allowed = ArchiveCompressor.writableFormats.filter { store.settings.archives.isEnabled($0) }
        return allowed.isEmpty ? ArchiveCompressor.writableFormats : allowed
    }

    /// Only ZIP (traditional ZipCrypto) and 7z (AES-256) can hold a password.
    private var encryptsIsAvailable: Bool { format == .zip || format == .sevenZip }

    /// 分卷压缩 is offered for the two formats every unarchiver opens as a set:
    /// a `.001` of a TAR or gzip is just a raw byte split that nothing reads.
    private var splitIsAvailable: Bool { format == .zip || format == .sevenZip }

    /// 固实压缩 is a property of the 7z container.
    private var solidIsAvailable: Bool { format == .sevenZip }

    /// The switch actually shown for 固实压缩: outside 7z the option is meaningless,
    /// so it renders unchecked and disabled rather than keeping a 7z tick that
    /// looks like an available setting.
    private var solidBinding: Binding<Bool> {
        Binding(get: { solidIsAvailable && solid }, set: { solid = $0 })
    }

    /// 保存为 / 标签 / 位置 share this width, so the centered block reads as one
    /// column (参考 保存为).
    private static let controlWidth: CGFloat = 300

    /// 位置: a **native** `NSPopUpButton` — the folder's own Finder icon, its name
    /// and the system's up/down chevrons (参考图一) — followed by the small button
    /// that opens the system folder panel. The popup's menu lists the folders this
    /// dialog has already visited and 「选择…」, which is the same panel.
    private var locationControl: some View {
        HStack(spacing: 6) {
            NativeFolderPicker(
                directory: directory,
                recent: recents,
                chooseTitle: store.text(.commonChoose),
                onPick: { url in
                    if let url {
                        use(url)
                    } else {
                        chooseDirectory()
                    }
                }
            )
            .frame(width: Self.controlWidth)
            Button {
                chooseDirectory()
            } label: {
                Image(systemName: "chevron.down")
            }
            .help(store.text(.commonChoose))
        }
    }

    /// Remembers a folder the dialog may write to, keeping a short history for the
    /// 位置 popup.
    private func use(_ url: URL) {
        directory = url
        recents.removeAll { $0.path == url.path }
        recents.insert(url, at: 0)
        if recents.count > 5 { recents.removeLast() }
    }

    /// 保存为 / 标签 / 位置: one centered block, all three controls the same width
    /// so the labels and the fields line up as a single column (用户要求:三个居中).
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text(store.text(.archiveSaveAs)).gridColumnAlignment(.trailing)
                        TextField("", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: Self.controlWidth)
                    }
                    GridRow {
                        Text(store.text(.archiveLabel)).gridColumnAlignment(.trailing)
                        TextField("", text: $label)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: Self.controlWidth)
                            .disabled(!labelIsStored)
                            // The caption under this field is gone; the rule is a
                            // tooltip now, so a disabled 标签 still explains itself.
                            .help(store.text(.archiveLabelZipOnly))
                    }
                    GridRow {
                        Text(store.text(.archiveLocation)).gridColumnAlignment(.trailing)
                        locationControl
                    }
                }
                Spacer(minLength: 0)
            }

            Divider()

            // 压缩格式 and 压缩模式 share one row; the pickers hug their own text
            // so the label sits right next to the popup (用户要求:间隔小一点).
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(store.text(.archiveFormat))
                Picker("", selection: $format) {
                    ForEach(selectableFormats, id: \.self) { candidate in
                        Text(store.text(candidate.titleKey)).tag(candidate)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 24)
                Text(store.text(.archiveMode))
                Picker("", selection: $mode) {
                    ForEach(ArchiveCompressionMode.allCases, id: \.self) { candidate in
                        Text(store.text(candidate.titleKey)).tag(candidate)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help(store.text(.archiveModeNote))
            }

            // The three options are real now; what is left is which formats can
            // carry them. The reason is a tooltip, and the control is greyed
            // rather than removed (用户要求:不可用就置灰).
            VStack(alignment: .leading, spacing: 6) {
                if encryptsIsAvailable {
                    encryptionRow
                        .help(store.text(format == .sevenZip ? .archiveEncryptSevenZipNote : .archiveEncryptionNote))
                } else {
                    unsupportedToggle(store.text(.archiveEncrypt))
                        .help(store.text(.archiveEncryptFormatsNote))
                }

                HStack(spacing: 8) {
                    Text(store.text(.archiveSplit))
                    Picker("", selection: $volumeSizeMB) {
                        Text(store.text(.archiveSplitOff)).tag(Int?.none)
                        ForEach(Self.volumeSizes, id: \.self) { size in
                            Text("\(size) MB").tag(Int?.some(size))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!splitIsAvailable)
                }
                .help(store.text(splitIsAvailable ? .archiveSplitNote : .archiveSplitZipOnly))

                // 固实压缩 on the left, 加密文件名 (7z only) on the right end — the
                // 压缩格式 / 压缩模式 shape (用户要求).
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    HStack(spacing: 8) {
                        // A greyed 固实压缩 shows an unchecked, disabled box: a tick
                        // in a dead checkbox reads as "on" (用户要求:不可用就置灰).
                        Toggle("", isOn: solidBinding)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .disabled(!solidIsAvailable)
                        Text(store.text(.archiveSolid))
                            .foregroundStyle(solidIsAvailable ? .primary : .secondary)
                    }
                    .help(store.text(solidIsAvailable ? .archiveSolidNote : .archiveSolidZipOnly))

                    if format == .sevenZip {
                        Spacer(minLength: 24)
                        HStack(spacing: 8) {
                            Toggle("", isOn: $encryptsFileNames)
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .disabled(!encrypts)
                            Text(store.text(.archiveFileNameEncryption))
                                .foregroundStyle(encrypts ? .primary : .secondary)
                        }
                        .help(store.text(.archiveEncryptSevenZipNote))
                    }
                }
            }
            // The option rows fill the dialog, so 加密压缩's field can run to its
            // right edge (用户要求:密码框尽量长).
            .frame(maxWidth: .infinity, alignment: .leading)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Spacer()
                Button(store.text(.commonCancel)) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(store.text(.commonConfirm)) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            // The dialog opens on ZIP; the settings may have turned ZIP off.
            if !selectableFormats.contains(format), let first = selectableFormats.first {
                format = first
            }
        }
        .onChange(of: format) { _, newFormat in
            // Encryption and splitting live in a ZIP/7z container; leaving those
            // drops the password rather than carrying a secret into a format that
            // cannot store it, and resets the 7z-only switches.
            if !(newFormat == .zip || newFormat == .sevenZip) {
                encrypts = false
                encryptsFileNames = false
                password = ""
                revealsPassword = false
                volumeSizeMB = nil
            }
            if newFormat != .sevenZip {
                encryptsFileNames = false
                solid = true
            }
        }
    }

    /// 加密压缩: a checkbox, the password itself, and the 密码本 next to it — the
    /// FastZip shape: the book is where a password comes from when you do not
    /// want to retype it.
    private var encryptionRow: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $encrypts)
                .toggleStyle(.checkbox)
                .labelsHidden()
            Text(store.text(.archiveEncrypt))
            Group {
                if revealsPassword {
                    TextField(store.text(.archivePasswordPlaceholder), text: $password)
                } else {
                    SecureField(store.text(.archivePasswordPlaceholder), text: $password)
                }
            }
            .textFieldStyle(.roundedBorder)
            // The password field is the one control that may run the full width:
            // 整行左右顶到头 (用户要求).
            .frame(maxWidth: .infinity)
            .disabled(!encrypts)
            Button {
                revealsPassword.toggle()
            } label: {
                Image(systemName: revealsPassword ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .disabled(!encrypts)
            .help(store.text(revealsPassword ? .archivePasswordBookHide : .archivePasswordBookReveal))
            if !passwordBook.isEmpty {
                // 只显示按钮和功能,不显示文案 (m03272): the password book is an icon
                // button; the words survive as its tooltip.
                Menu {
                    ForEach(passwordBook.entries) { entry in
                        Button(entry.name) {
                            password = entry.password
                            encrypts = true
                        }
                    }
                } label: {
                    Image(systemName: "key")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!encrypts)
                .help(store.text(.archivePasswordBookPick))
            }
        }
    }

    /// A grey row for an option the chosen format cannot carry — visible, so the
    /// user sees the feature exists, with the reason spelled out next to it
    /// rather than a toggle that is offered and then refused.
    private func unsupportedToggle(_ title: String) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: .constant(false))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(true)
            Text(title)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.prompt = store.text(.commonChoose)
        if panel.runModal() == .OK, let url = panel.url {
            use(url)
        }
    }

    private func save() {
        // 加密压缩 with an empty box is a mistake, not a request to skip
        // encryption: say so instead of writing a plain archive.
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsEncryption = encrypts && encryptsIsAvailable
        if wantsEncryption, trimmedPassword.isEmpty {
            errorText = store.text(.archivePasswordMissing)
            return
        }
        isWorking = true
        errorText = nil
        let settings = store.settings.archives
        let passwordToUse = wantsEncryption ? trimmedPassword : nil
        // A dialog opened on ZIP keeps its 7z-only choices out of the request.
        let cryptsNames = wantsEncryption && solidIsAvailable && encryptsFileNames
        let parts = splitIsAvailable ? volumeSizeMB : nil
        let usesSolid = solidIsAvailable ? solid : true
        let finalName = writtenName
        // 取消 must actually stop the walk, not just hide the sheet.
        let control = ArchiveOperationControl()
        self.control = control
        // Squeeze the work off the main thread; the archive is built in memory.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Goes through the dispatcher, not `ArchiveCompressor` directly:
                // the parked request's security-scoped access expired while the
                // dialog was open, so the write has to take it again here.
                let report = try FileOperationDispatcher().performCustomCompression(
                    sources: sources,
                    into: directory,
                    preferredName: writtenName,
                    format: format,
                    mode: mode,
                    label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : label,
                    password: passwordToUse,
                    solid: usesSolid,
                    encryptsFileNames: cryptsNames,
                    volumeSizeMB: parts,
                    settings: settings,
                    control: control
                )
                DispatchQueue.main.async {
                    // 自动保存压缩时输入的加密密码 (off by default).
                    if let passwordToUse, settings.remembersCompressionPassword {
                        passwordBook.remember(name: finalName, password: passwordToUse)
                    }
                    Self.log(report)
                    finish()
                }
            } catch ArchiveError.cancelled {
                // The sheet is already gone and nothing was written: the archive
                // is assembled in memory and only lands on disk at the end.
            } catch let failure as FileOperationDispatcher.CustomCompressionFailure {
                DispatchQueue.main.async {
                    isWorking = false
                    errorText = "\(store.text(.archiveCustomFailed)): \(failure.message)"
                }
            } catch {
                DispatchQueue.main.async {
                    isWorking = false
                    errorText = "\(store.text(.archiveCustomFailed)): \(ArchiveExtractor.describe(error as? ArchiveError ?? .writeFailed(error.localizedDescription)))"
                }
            }
        }
    }

    private func cancel() {
        control?.cancel()
        finish()
    }

    private func finish() {
        center.dismiss()
        onDone()
    }

    private static func log(_ report: ArchiveCompressor.Report) {
        Logger(subsystem: "xin.ljhsu.MenuRight", category: "archive-dialog")
            .info("ARCHIVE dialog SUCCESS path=\(report.archiveURL.path, privacy: .public) entries=\(report.entryCount, privacy: .public)")
    }
}
