import Cocoa
import FinderSync
import os
import Darwin

/// Principal class of the MenuRightFinder Finder Sync Extension.
///
/// Phase A2 scope adds file operations (New File / New Folder / Cut / Paste
/// Here) while keeping menu(for:) strictly CPU-cheap: no networking, no
/// directory scans, no write probes, no hashing, no timers, no observers.
/// All filesystem work happens only after the user invokes an action.
final class FinderSync: FIFinderSync {
    /// Low-frequency lifecycle logger (os_log). Fires once at init and once per
    /// menu(for:) invocation — no timers, no polling.
    /// Visibility: log stream --predicate 'subsystem == "xin.ljhsu.MenuRight"'
    private static let diag = Logger(subsystem: "xin.ljhsu.MenuRight", category: "finder-sync-lifecycle")

    /// Real user home directory resolved through the POSIX passwd entry.
    ///
    /// Sandbox caveat: inside this FinderSync extension process,
    /// FileManager.default.homeDirectoryForCurrentUser, NSHomeDirectory() and
    /// NSHomeDirectoryForUser(NSUserName()) all resolve to the extension's own
    /// sandbox container (…/Containers/xin.ljhsu.MenuRight.FinderSync/Data).
    /// Monitoring that path makes Finder call menu(for:) only inside the
    /// container, so the real home is resolved via getpwuid(getuid()).pw_dir
    /// (empirically verified on this machine). Cached: the value cannot change
    /// within the process and menu(for:) may run repeatedly.
    private static let realUserHome: URL? = {
        guard let passwd = getpwuid(getuid()),
              let home = passwd.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
    }()

    private func realUserHomeDirectory() -> URL? { Self.realUserHome }

    /// Serial queue for every IPC round trip.
    ///
    /// Finder replays menu actions on the extension's main thread. Blocking
    /// there freezes the whole extension — and before H1 was fixed, a main app
    /// that accepted the connection and then stalled could block it forever.
    /// All `ExtensionIPCClient` calls run here; alerts are presented back on the
    /// main queue.
    private let ipcQueue = DispatchQueue(
        label: "xin.ljhsu.MenuRight.FinderSync.ipc",
        qos: .userInitiated
    )

    override init() {
        super.init()
        LifecycleDiagnostics.record("FinderSync.init", from: "finder-sync")
        // Monitor the real user home directory (and everything below it).
        // Deliberately NOT "/", /Volumes, network volumes, or iCloud.
        guard let homeURL = realUserHomeDirectory() else {
            Self.diag.log("init: realUserHomeDirectory() failed; directoryURLs left EMPTY (explicitly no fallback to the sandbox container home)")
            return
        }
        FIFinderSyncController.default().directoryURLs = [homeURL]
        Self.diag.log("init executed; real user home = \(homeURL.path, privacy: .public); directoryURLs=[\(homeURL.path, privacy: .public)]")
        let controller = FIFinderSyncController.default()
        let urls = controller.directoryURLs ?? []
        Self.diag.log("init read-back: directoryURLs.count=\(urls.count, privacy: .public) containsRealHome=\(urls.contains(homeURL), privacy: .public) urls=[\(urls.sorted { $0.path < $1.path }.map(\.path).joined(separator: "|"), privacy: .public)]")

        // P5-0.6 POC: probe the IPC channel to the main app on init.
        // Deliberately asynchronous: `init` must never block the Finder process
        // on IPC (the probe has no actionable result for the user).
        ipcQueue.async {
            switch ExtensionIPCClient.sendPing() {
            case .pong(let reply):
                Self.diag.log("init IPC pong: \(reply, privacy: .public)")
            case .unavailable(let reason):
                Self.diag.log("init IPC unavailable: \(reason, privacy: .public)")
            }
        }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // Lifecycle diagnostics: log every invocation + monitored-scope sanity check.
        let controller = FIFinderSyncController.default()
        let home = realUserHomeDirectory()
        let urls = controller.directoryURLs ?? []
        let containsRealHome = home.map { urls.contains($0) } ?? false
        Self.diag.log("menu(for:) called kind=\(menuKind.rawValue, privacy: .public) (\(String(describing: menuKind), privacy: .public)) containsRealHome=\(containsRealHome, privacy: .public)")

        // Phase A2 supports only contextual menus (items + container).
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            Self.diag.log("menu(for:) unsupported kind -> returning nil")
            return nil
        }

        // Read the selection inside the legitimate Finder Sync context only.
        let selection = FinderSelectionContext(
            itemURLs: controller.selectedItemURLs() ?? [],
            targetedURL: controller.targetedURL()
        )
        Self.diag.log("menu(for:) selection: count=\(selection.itemURLs.count, privacy: .public) selected=[\(selection.itemURLs.map(\.path).joined(separator: "|"), privacy: .public)] targeted=\(selection.targetedURL?.path ?? "nil", privacy: .public)")

        // Pasteboard decode only — no filesystem work while building the menu.
        let hasCutPayload = CutPasteboard.containsValidCut()
        let plan = FinderMenuBuilder.plan(
            for: selection,
            containerMenu: menuKind == .contextualMenuForContainer,
            hasCutPayload: hasCutPayload
        )
        Self.diag.log("menu(for:) plan.count=\(plan.count, privacy: .public) hasCutPayload=\(hasCutPayload, privacy: .public)")
        guard !plan.isEmpty else {
            Self.diag.log("menu(for:) plan empty -> returning nil")
            return nil
        }

        let menu = makeMenu(from: plan)
        Self.diag.log("menu(for:) returning menu with \(menu.items.count, privacy: .public) items")
        return menu
    }

    // MARK: - Menu construction

    private func makeMenu(from plan: [FinderMenuPlanItem]) -> NSMenu {
        let menu = NSMenu(title: "")
        for item in plan {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .action(let action):
                add(action, to: menu)
            case .submenu(let title, let actions):
                let submenu = NSMenu(title: title)
                for action in actions {
                    add(action, to: submenu)
                }
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                menuItem.submenu = submenu
                menu.addItem(menuItem)
            }
        }
        return menu
    }

    private func add(_ action: FinderMenuAction, to menu: NSMenu) {
        switch action {
        case .copyName(let payload):
            addItem(title: "Copy Name", selector: #selector(performCopy(_:)), representedObject: payload, to: menu)
        case .copyPath(let payload):
            addItem(title: "Copy Path", selector: #selector(performCopy(_:)), representedObject: payload, to: menu)
        case .copyFileURL(let payload):
            addItem(title: "Copy File URL", selector: #selector(performCopy(_:)), representedObject: payload, to: menu)
        case .copyFolderPath(let payload):
            addItem(title: "Copy Folder Path", selector: #selector(performCopy(_:)), representedObject: payload, to: menu)
        case .cut(let items):
            addItem(title: "Cut", selector: #selector(performCut(_:)), representedObject: items, to: menu)
        case .pasteHere(let destination, let enabled):
            let item = NSMenuItem(title: "Paste Here", action: #selector(performPaste(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            item.representedObject = destination
            menu.addItem(item)
        case .newFile(let kind, let directory):
            addItem(
                title: kind.title,
                selector: #selector(performNewFile(_:)),
                representedObject: NewFileRequest(kind: kind, directory: directory),
                to: menu
            )
        case .newFolder(let directory):
            addItem(title: "New Folder", selector: #selector(performNewFolder(_:)), representedObject: directory, to: menu)
        case .openTerminal(let directory):
            addItem(title: FinderMenuTitles.openTerminal, selector: #selector(performOpenTerminal(_:)), representedObject: directory, to: menu)
        case .copyFolderName(let payload):
            addItem(title: "Copy Folder Name", selector: #selector(performCopy(_:)), representedObject: payload, to: menu)
        case .createAlias(let items):
            addItem(title: FinderMenuTitles.createAlias, selector: #selector(performCreateAlias(_:)), representedObject: items, to: menu)
        case .setLocked(let items, let locked):
            addItem(
                title: locked ? FinderMenuTitles.lock : FinderMenuTitles.unlock,
                selector: #selector(performSetLocked(_:)),
                representedObject: items,
                to: menu
            )
        }
    }

    private func addItem(title: String, selector: Selector, representedObject: Any?, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func performCopy(_ sender: NSMenuItem) {
        // FinderSync replays actions via a reconstructed NSMenuItem that does
        // NOT carry representedObject across the process boundary. Re-derive
        // every payload from the live controller instead of the menu item.
        let controller = FIFinderSyncController.default()
        let selection = FinderSelectionContext(
            itemURLs: controller.selectedItemURLs() ?? [],
            targetedURL: controller.targetedURL()
        )
        let title = sender.title
        let payload: String?
        switch title {
        case "Copy Name":
            payload = selection.formattedNames
        case "Copy Path":
            payload = selection.formattedPaths
        case "Copy File URL":
            payload = selection.formattedFileURLs
        case "Copy Folder Name":
            payload = selection.containerDirectory?.lastPathComponent
        case "Copy Folder Path":
            payload = selection.containerDirectory?.path
        default:
            Self.diag.log("ACTION performCopy: unknown title=\(title, privacy: .public)")
            payload = nil
        }
        guard let payload else {
            Self.diag.log("ACTION performCopy: could not derive payload title=\(title, privacy: .public) selectionCount=\(selection.itemURLs.count, privacy: .public)")
            return
        }
        Self.diag.log("ACTION INVOKED performCopy title=\(title, privacy: .public) payload=\(payload, privacy: .public)")
        PasteboardWriter.write(payload)
        let readBack = NSPasteboard.general.string(forType: .string)
        Self.diag.log("ACTION performCopy pasteboard: type=public.utf8-plain-text writeAttempted=true readbackMatches=\(readBack == payload, privacy: .public) readbackLen=\(readBack?.count ?? -1, privacy: .public)")
    }

    @objc private func performCut(_ sender: NSMenuItem) {
        let items = FIFinderSyncController.default().selectedItemURLs() ?? []
        Self.diag.log("ACTION INVOKED performCut title=\(sender.title, privacy: .public) itemCount=\(items.count, privacy: .public) selection=[\(items.map(\.path).joined(separator: "|"), privacy: .public)]")
        guard !items.isEmpty else {
            Self.diag.log("ACTION performCut: no live selection, ignoring")
            return
        }
        do {
            try CutPasteboard.write(CutPayload(urls: items))
            let readBack = CutPasteboard.read()
            let matches = (readBack?.urls == items)
            Self.diag.log("ACTION performCut pasteboard: type=xin.ljhsu.MenuRight.cut-items writeAttempted=true result=success readbackCount=\(readBack?.urls.count ?? -1, privacy: .public) matchesSelection=\(matches, privacy: .public)")
        } catch {
            Self.diag.log("ACTION performCut pasteboard: write FAILED error=\(String(describing: error), privacy: .public)")
            OperationPresenter.presentTitle("Couldn’t cut items.", message: "The cut information could not be written to the pasteboard.")
        }
    }
    @objc private func performNewFile(_ sender: NSMenuItem) {
        guard let kind = NewFileKind.allCases.first(where: { $0.title == sender.title }) else {
            Self.diag.log("ACTION performNewFile: unknown title=\(sender.title, privacy: .public)")
            return
        }
        let controller = FIFinderSyncController.default()
        let selection = FinderSelectionContext(
            itemURLs: controller.selectedItemURLs() ?? [],
            targetedURL: controller.targetedURL()
        )
        guard let directory = selection.containerDirectory else {
            Self.diag.log("ACTION performNewFile: no container directory from controller")
            return
        }
        Self.diag.log("ACTION INVOKED performNewFile title=\(sender.title, privacy: .public) kind=\(kind.rawValue, privacy: .public) target=\(directory.path, privacy: .public) delegating=true")

        let contentsBase64: String?
        if let raw = kind.contents {
            contentsBase64 = raw.base64EncodedString()
        } else {
            contentsBase64 = nil
        }
        let args = FileOperationContract.OperationArgs(
            directory: directory.path,
            name: kind.defaultName,
            contentsBase64: contentsBase64,
            sourcePaths: nil,
            destinationDirectory: nil
        )
        let request = FileOperationContract.Request(
            kind: .createFile,
            args: args,
            clientRequestId: UUID().uuidString
        )
        sendDelegated(request) { [weak self] outcome in
            self?.handleNewFileOutcome(outcome, kind: kind, directory: directory)
        }
    }

    private func handleNewFileOutcome(
        _ outcome: ExtensionIPCClient.FileOperationOutcome,
        kind: NewFileKind,
        directory: URL
    ) {
        switch outcome {
        case .success:
            Self.diag.log("ACTION performNewFile delegated SUCCESS target=\(directory.path, privacy: .public)")
        case .batchSuccess:
            Self.diag.log("ACTION performNewFile unexpected batch success target=\(directory.path, privacy: .public)")
        case .failure(let code, let message):
            Self.diag.log("ACTION performNewFile delegated FAILURE code=\(code.rawValue, privacy: .public) message=\(message, privacy: .public)")
            OperationPresenter.presentDelegatedCreateFailure(name: kind.defaultName, code: code, message: message)
        case .unavailable(let reason):
            Self.diag.log("ACTION performNewFile delegated UNAVAILABLE reason=\(reason, privacy: .public)")
            OperationPresenter.presentMainAppUnavailable(context: reason)
        }
    }

    @objc private func performNewFolder(_ sender: NSMenuItem) {
        let controller = FIFinderSyncController.default()
        let selection = FinderSelectionContext(
            itemURLs: controller.selectedItemURLs() ?? [],
            targetedURL: controller.targetedURL()
        )
        guard let directory = selection.containerDirectory else {
            Self.diag.log("ACTION performNewFolder: no container directory from controller")
            return
        }
        Self.diag.log("ACTION INVOKED performNewFolder title=\(sender.title, privacy: .public) target=\(directory.path, privacy: .public) delegating=true")

        let args = FileOperationContract.OperationArgs(
            directory: directory.path,
            name: "New Folder",
            contentsBase64: nil,
            sourcePaths: nil,
            destinationDirectory: nil
        )
        let request = FileOperationContract.Request(
            kind: .createDirectory,
            args: args,
            clientRequestId: UUID().uuidString
        )
        sendDelegated(request) { [weak self] outcome in
            self?.handleNewFolderOutcome(outcome, directory: directory)
        }
    }

    private func handleNewFolderOutcome(
        _ outcome: ExtensionIPCClient.FileOperationOutcome,
        directory: URL
    ) {
        switch outcome {
        case .success:
            Self.diag.log("ACTION performNewFolder delegated SUCCESS target=\(directory.path, privacy: .public)")
        case .batchSuccess:
            Self.diag.log("ACTION performNewFolder unexpected batch success target=\(directory.path, privacy: .public)")
        case .failure(let code, let message):
            Self.diag.log("ACTION performNewFolder delegated FAILURE code=\(code.rawValue, privacy: .public) message=\(message, privacy: .public)")
            OperationPresenter.presentDelegatedCreateFailure(name: "New Folder", code: code, message: message)
        case .unavailable(let reason):
            Self.diag.log("ACTION performNewFolder delegated UNAVAILABLE reason=\(reason, privacy: .public)")
            OperationPresenter.presentMainAppUnavailable(context: reason)
        }
    }

    @objc private func performPaste(_ sender: NSMenuItem) {
        let controller = FIFinderSyncController.default()
        let selection = FinderSelectionContext(
            itemURLs: controller.selectedItemURLs() ?? [],
            targetedURL: controller.targetedURL()
        )
        guard let destination = selection.containerDirectory else {
            Self.diag.log("ACTION performPaste: no destination from controller")
            return
        }
        guard let payload = CutPasteboard.read() else {
            Self.diag.log("ACTION performPaste: no cut payload on pasteboard, ignoring")
            return
        }
        Self.diag.log("ACTION INVOKED performPaste title=\(sender.title, privacy: .public) target=\(destination.path, privacy: .public) payloadCount=\(payload.urls.count, privacy: .public) sources=[\(payload.urls.map(\.path).joined(separator: "|"), privacy: .public)] delegating=true")

        let args = FileOperationContract.OperationArgs(
            directory: nil,
            name: nil,
            contentsBase64: nil,
            sourcePaths: payload.urls.map { $0.path },
            destinationDirectory: destination.path
        )
        let request = FileOperationContract.Request(
            kind: .moveItems,
            args: args,
            clientRequestId: UUID().uuidString
        )
        sendDelegated(request) { [weak self] outcome in
            self?.handlePasteOutcome(outcome, destination: destination)
        }
    }

    private func handlePasteOutcome(
        _ outcome: ExtensionIPCClient.FileOperationOutcome,
        destination: URL
    ) {
        switch outcome {
        case .success:
            Self.diag.log("ACTION performPaste delegated unexpected single success target=\(destination.path, privacy: .public)")
        case .batchSuccess(let items):
            Self.diag.log("ACTION performPaste delegated batch-success count=\(items.count, privacy: .public)")
            applyPasteLifecycle(for: items)
            OperationPresenter.presentDelegatedPasteResults(items)
        case .failure(let code, let message):
            Self.diag.log("ACTION performPaste delegated FAILURE code=\(code.rawValue, privacy: .public) message=\(message, privacy: .public)")
            if code == .notAuthorized || code == .pathOutsideAuthorizedScope {
                OperationPresenter.presentFolderAccessRequired()
            } else {
                OperationPresenter.presentTitle("Couldn't paste items.", message: message)
            }
        case .unavailable(let reason):
            Self.diag.log("ACTION performPaste delegated UNAVAILABLE reason=\(reason, privacy: .public)")
            OperationPresenter.presentMainAppUnavailable(context: reason)
        }
    }

    /// Runs one delegated file operation on `ipcQueue` and delivers the outcome
    /// on the main queue. Called from Finder menu actions, which run on the main
    /// thread: the transport call must never happen there, and the alert must
    /// only happen there.
    private func sendDelegated(
        _ request: FileOperationContract.Request,
        then handle: @escaping (ExtensionIPCClient.FileOperationOutcome) -> Void
    ) {
        ipcQueue.async {
            let outcome = ExtensionIPCClient.sendFileOperation(request)
            DispatchQueue.main.async { handle(outcome) }
        }
    }

    // MARK: - P6 actions

    @objc private func performOpenTerminal(_ sender: NSMenuItem) {
        let controller = FIFinderSyncController.default()
        let selection = FinderSelectionContext(
            itemURLs: controller.selectedItemURLs() ?? [],
            targetedURL: controller.targetedURL()
        )
        guard let directory = selection.containerDirectory else {
            Self.diag.log("ACTION performOpenTerminal: no container directory from controller")
            return
        }
        Self.diag.log("ACTION INVOKED performOpenTerminal target=\(directory.path, privacy: .public) delegating=true")
        let request = FileOperationContract.Request(
            kind: .openTerminal,
            args: FileOperationContract.OperationArgs(directory: directory.path),
            clientRequestId: UUID().uuidString
        )
        sendDelegated(request) { [weak self] outcome in
            self?.handleOpenTerminalOutcome(outcome, directory: directory)
        }
    }

    private func handleOpenTerminalOutcome(_ outcome: ExtensionIPCClient.FileOperationOutcome, directory: URL) {
        switch outcome {
        case .success:
            Self.diag.log("ACTION performOpenTerminal delegated SUCCESS target=\(directory.path, privacy: .public)")
        case .batchSuccess:
            Self.diag.log("ACTION performOpenTerminal unexpected batch success")
        case .failure(let code, let message):
            Self.diag.log("ACTION performOpenTerminal delegated FAILURE code=\(code.rawValue, privacy: .public) message=\(message, privacy: .public)")
            OperationPresenter.presentTitle("Couldn't open Terminal.", message: message)
        case .unavailable(let reason):
            Self.diag.log("ACTION performOpenTerminal delegated UNAVAILABLE reason=\(reason, privacy: .public)")
            OperationPresenter.presentMainAppUnavailable(context: reason)
        }
    }

    @objc private func performCreateAlias(_ sender: NSMenuItem) {
        // Re-derive the selection: representedObject does not survive the Finder
        // action replay.
        let items = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !items.isEmpty else {
            Self.diag.log("ACTION performCreateAlias: no live selection, ignoring")
            return
        }
        Self.diag.log("ACTION INVOKED performCreateAlias count=\(items.count, privacy: .public) delegating=true")
        let request = FileOperationContract.Request(
            kind: .createAlias,
            args: FileOperationContract.OperationArgs(sourcePaths: items.map(\.path)),
            clientRequestId: UUID().uuidString
        )
        sendDelegated(request) { [weak self] outcome in
            self?.handleItemResultsOutcome(outcome, action: "create the alias")
        }
    }

    @objc private func performSetLocked(_ sender: NSMenuItem) {
        let items = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !items.isEmpty else {
            Self.diag.log("ACTION performSetLocked: no live selection, ignoring")
            return
        }
        // Title-based dispatch, because representedObject is lost; hence the
        // shared FinderMenuTitles constants.
        let locked = sender.title != FinderMenuTitles.unlock
        Self.diag.log("ACTION INVOKED performSetLocked locked=\(locked, privacy: .public) count=\(items.count, privacy: .public) delegating=true")
        let request = FileOperationContract.Request(
            kind: .setLocked,
            args: FileOperationContract.OperationArgs(sourcePaths: items.map(\.path), locked: locked),
            clientRequestId: UUID().uuidString
        )
        sendDelegated(request) { [weak self] outcome in
            self?.handleItemResultsOutcome(outcome, action: locked ? "lock the item" : "unlock the item")
        }
    }

    /// Shared handler for the per-item operations (alias creation, locking).
    /// Success stays silent; failures are reported once, per item count.
    private func handleItemResultsOutcome(
        _ outcome: ExtensionIPCClient.FileOperationOutcome,
        action: String
    ) {
        switch outcome {
        case .success:
            Self.diag.log("ACTION \(action, privacy: .public) delegated SUCCESS")
        case .batchSuccess(let items):
            let failures = items.filter { !$0.success }
            Self.diag.log("ACTION \(action, privacy: .public) delegated DONE count=\(items.count, privacy: .public) failures=\(failures.count, privacy: .public)")
            OperationPresenter.presentDelegatedItemFailures(items, action: action)
        case .failure(let code, let message):
            Self.diag.log("ACTION \(action, privacy: .public) delegated FAILURE code=\(code.rawValue, privacy: .public) message=\(message, privacy: .public)")
            if code == .notAuthorized || code == .pathOutsideAuthorizedScope {
                OperationPresenter.presentFolderAccessRequired()
            } else {
                OperationPresenter.presentTitle("Couldn't \(action).", message: message)
            }
        case .unavailable(let reason):
            Self.diag.log("ACTION \(action, privacy: .public) delegated UNAVAILABLE reason=\(reason, privacy: .public)")
            OperationPresenter.presentMainAppUnavailable(context: reason)
        }
    }

    // MARK: - Cut payload lifecycle (delegated, §15)

    /// P5-1: cut-payload lifecycle is driven by the Main App's response.
    /// allSucceeded: clear the cut payload.
    /// partial:      keep only the failed source URLs for retry.
    /// allFailed:    leave the existing payload untouched.
    private func applyPasteLifecycle(for items: [FileOperationContract.ItemResult]) {
        let failed = items.filter { !$0.success }
        if failed.isEmpty {
            CutPasteboard.remove()
            return
        }
        if failed.count == items.count {
            return
        }
        // partial - rewrite the cut payload with only the failed sources
        let retryURLs = failed.map { URL(fileURLWithPath: $0.sourcePath) }
        try? CutPasteboard.write(CutPayload(urls: retryURLs))
    }
}

/// Represented object carried by New File menu items.
struct NewFileRequest {
    let kind: NewFileKind
    let directory: URL
}
