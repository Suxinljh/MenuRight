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
}

/// Main-thread hand-off between the IPC dispatcher and the dialog.
///
/// The dispatcher runs on a connection queue and must never block on UI, so it
/// parks the request here and returns; the window presents the sheet. `@Published`
/// mutation happens on the main thread (the dispatcher hops before calling
/// `present`).
final class ArchiveRequestCenter: ObservableObject {
    static let shared = ArchiveRequestCenter()

    private static let log = Logger(subsystem: "xin.ljhsu.MenuRight", category: "archive-dialog")

    @Published var pending: PendingArchiveRequest?

    private init() {}

    /// Parks a request and brings the app forward so the sheet is actually seen:
    /// a Finder action can arrive while MenuRight is behind other windows.
    func present(_ request: PendingArchiveRequest) {
        let show = {
            self.pending = request
            NSApp.activate(ignoringOtherApps: true)
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
    }
}

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

/// The custom-compression sheet: 保存为 / 标签 / 位置 / 压缩格式 / 压缩模式, with
/// the three options this build cannot honour shown disabled **and explained**.
struct CustomCompressionSheet: View {
    @EnvironmentObject private var store: SettingsStore
    @ObservedObject var center: ArchiveRequestCenter

    /// Working copy: nothing is written until 保存.
    @State private var name: String
    @State private var label: String
    @State private var directory: URL
    @State private var format: ArchiveFormat
    @State private var mode: ArchiveCompressionMode
    @State private var errorText: String?
    @State private var isWorking = false

    private let sources: [URL]
    private let onDone: () -> Void

    init(request: PendingArchiveRequest, center: ArchiveRequestCenter, onDone: @escaping () -> Void) {
        _name = State(initialValue: request.name)
        _label = State(initialValue: request.label)
        _directory = State(initialValue: request.directory)
        _format = State(initialValue: request.format)
        _mode = State(initialValue: request.mode)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.text(.archiveCustomTitle))
                .font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(store.text(.archiveSaveAs)).gridColumnAlignment(.trailing)
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                GridRow {
                    Text(store.text(.archiveLabel)).gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("", text: $label)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                            .disabled(!labelIsStored)
                        if !labelIsStored {
                            Text(store.text(.archiveLabelZipOnly))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    Text(store.text(.archiveLocation)).gridColumnAlignment(.trailing)
                    HStack(spacing: 8) {
                        Text(directory.path)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(width: 232, alignment: .leading)
                        Button(store.text(.commonChoose)) { chooseDirectory() }
                    }
                }
                GridRow {
                    Text(store.text(.archiveFormat)).gridColumnAlignment(.trailing)
                    Picker("", selection: $format) {
                        ForEach(ArchiveCompressor.writableFormats, id: \.self) { candidate in
                            Text(store.text(candidate.titleKey)).tag(candidate)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                GridRow {
                    Text(store.text(.archiveMode)).gridColumnAlignment(.trailing)
                    Picker("", selection: $mode) {
                        ForEach(ArchiveCompressionMode.allCases, id: \.self) { candidate in
                            Text(store.text(candidate.titleKey)).tag(candidate)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            Divider()

            // Options this build cannot honour: visible, disabled, and with the
            // reason next to them — never quietly missing.
            VStack(alignment: .leading, spacing: 6) {
                unsupportedToggle(store.text(.archiveEncrypt))
                unsupportedToggle(store.text(.archiveSplit))
                unsupportedToggle(store.text(.archiveSolid))
                Text(store.text(.archiveUnsupportedOptionsNote))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(store.text(.commonCancel)) { finish() }
                    .keyboardShortcut(.cancelAction)
                Button(store.text(.commonConfirm)) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func unsupportedToggle(_ title: String) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: .constant(false))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(true)
            Text(title)
            Text(store.text(.archiveOptionUnsupported))
                .font(.caption)
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
            directory = url
        }
    }

    private func save() {
        isWorking = true
        errorText = nil
        let settings = store.settings.archives
        // Squeeze the work off the main thread; the archive is built in memory.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let report = try ArchiveCompressor.compress(
                    sources,
                    into: directory,
                    preferredName: writtenName,
                    format: format,
                    conflictPolicy: settings.conflictPolicy,
                    sizeLimitMB: settings.sizeLimitMB,
                    mode: mode,
                    label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : label
                )
                DispatchQueue.main.async {
                    Self.log(report)
                    finish()
                }
            } catch {
                DispatchQueue.main.async {
                    isWorking = false
                    errorText = "\(store.text(.archiveCustomFailed)): \(ArchiveExtractor.describe(error as? ArchiveError ?? .writeFailed(error.localizedDescription)))"
                }
            }
        }
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
