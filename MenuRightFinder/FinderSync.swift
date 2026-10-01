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

    /// 暂停/继续/取消 go here, **never** on `ipcQueue`.
    ///
    /// `ipcQueue` is serial and a file operation occupies it for its whole
    /// lifetime — it is blocked waiting for the answer. A control message queued
    /// behind it would therefore be sent *after* the compression it is meant to
    /// interrupt had already finished, which is a pause button that does nothing.
    /// Measured 2026-10-01: exactly that, reported as "暂停按钮无效".
    private let controlQueue = DispatchQueue(
        label: "xin.ljhsu.MenuRight.FinderSync.control",
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
        // P6-b: which kinds the *running* main app can create. Also a cfprefsd
        // read, not a filesystem scan; the templates themselves are never
        // touched from this process.
        let newFileKinds = NewFileKind.available(from: NewFileAvailability.readFromAppGroup())
        // P7-b: the favorites submenus. A second cfprefsd read, no file access —
        // an entry whose app was uninstalled is resolved at click time.
        let favorites = FinderFavorites.entries()
        // P9: which selected items are archives. Extension check only — no
        // filesystem probe, so the menu-build budget holds.
        let archives = FinderArchives.classify(selection.itemURLs)
        // Two more cfprefsd reads from the same payload: where 解压位置 sends the
        // second 解压 item, and which formats 允许的压缩格式 leaves in 压缩 ▸.
        let plan = FinderMenuBuilder.plan(
            for: selection,
            containerMenu: menuKind == .contextualMenuForContainer,
            hasCutPayload: hasCutPayload,
            newFileKinds: newFileKinds,
            favorites: favorites,
            archives: archives,
            archiveDestination: FinderArchives.destination(),
            compressionFormats: FinderArchives.enabledCompressionFormats()
        )
        Self.diag.log("menu(for:) plan.count=\(plan.count, privacy: .public) hasCutPayload=\(hasCutPayload, privacy: .public) newFileKinds=[\(newFileKinds.map(\.rawValue).joined(separator: ","), privacy: .public)] favorites=\(favorites.count, privacy: .public) archives=\(archives.archives.count, privacy: .public)/\(archives.compressible.count, privacy: .public)")
        guard !plan.isEmpty else {
            Self.diag.log("menu(for:) plan empty -> returning nil")
            return nil
        }

        // The app owns the setting; the extension reads it from the shared App
        // Group payload on every build, so a language change in 通用设置 shows up
        // on the next right-click.
        let language = FinderMenuLanguage.resolve()
        Self.diag.log("menu(for:) language=\(language.rawValue, privacy: .public)")
        let menu = makeMenu(from: plan, language: language)
        Self.diag.log("menu(for:) returning menu with \(menu.items.count, privacy: .public) items")
        return menu
    }

    // MARK: - Menu construction

    private func makeMenu(from plan: [FinderMenuPlanItem], language: AppLanguage) -> NSMenu {
        let menu = NSMenu(title: "")
        for item in plan {
            switch item {
            case .action(let action):
                add(action, to: menu, language: language)
            case .submenu(let titleKey, let actions):
                let title = FinderMenuTitles.submenuTitle(titleKey, language: language)
                let submenu = NSMenu(title: title)
                for action in actions {
                    add(action, to: submenu, language: language)
                }
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                menuItem.submenu = submenu
                menu.addItem(menuItem)
            }
        }
        return menu
    }

    private func add(_ action: FinderMenuAction, to menu: NSMenu, language: AppLanguage) {
        let title = FinderMenuTitles.title(for: action, language: language)
        switch action {
        case .copyName(let payload):
            addItem(title: title, selector: #selector(performCopy(_:)), representedObject: payload, to: menu)
        case .copyPath(let payload):
            addItem(title: title, selector: #selector(performCopy(_:)), representedObject: payload, to: menu)
        case .copyFileURL(let payload):
            addItem(title: title, selector: #selector(performCopy(_:)), representedObject: payload, to: menu)
        case .copyFolderPath(let payload):
            addItem(title: title, selector: #selector(performCopy(_:)), representedObject: payload, to: menu)
        case .cut(let items):
            addItem(title: title, selector: #selector(performCut(_:)), representedObject: items, to: menu)
        case .pasteHere(let destination, let enabled):
            let item = NSMenuItem(title: title, action: #selector(performPaste(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            item.representedObject = destination
            menu.addItem(item)
        case .newFile(let kind, let directory):
            addItem(
                title: title,
                selector: #selector(performNewFile(_:)),
                representedObject: NewFileRequest(kind: kind, directory: directory),
                to: menu
            )
        case .newFolder(let directory):
            addItem(title: title, selector: #selector(performNewFolder(_:)), representedObject: directory, to: menu)
        case .openTerminal(let directory):
            addItem(title: title, selector: #selector(performOpenTerminal(_:)), representedObject: directory, to: menu)
        case .copyFolderName(let payload):
            addItem(title: title, selector: #selector(performCopy(_:)), representedObject: payload, to: menu)
        case .createAlias(let items):
            addItem(title: title, selector: #selector(performCreateAlias(_:)), representedObject: items, to: menu)
        case .setLocked(let items, let locked):
            _ = locked   // the title already encodes it (Lock / Unlock)
            addItem(
                title: title,
                selector: #selector(performSetLocked(_:)),
                representedObject: items,
                to: menu
            )
        case .openFavorite(let entry):
            addItem(
                title: title,
                selector: #selector(performOpenFavorite(_:)),
                representedObject: entry,
                image: FinderFavoriteIcons.image(named: entry.iconFile),
                to: menu
            )
        case .extractArchives(let archives, let destination):
            addItem(
                title: title,
                selector: #selector(performExtractArchives(_:)),
                representedObject: ArchiveRequest(archives: archives, destination: destination),
                to: menu
            )
        case .compressItems(let items, let format):
            addItem(
                title: title,
                selector: #selector(performCompressItems(_:)),
                representedObject: ArchiveRequest(archives: items, destination: nil, format: format),
                to: menu
            )
        case .extractArchivesCustomize(let archives):
            addItem(
                title: title,
                selector: #selector(performExtractArchives(_:)),
                representedObject: ArchiveRequest(archives: archives, destination: nil),
                to: menu
            )
        case .extractArchivesToFolder(let archives, let destination):
            addItem(
                title: title,
                selector: #selector(performExtractArchives(_:)),
                representedObject: ArchiveRequest(archives: archives, destination: destination),
                to: menu
            )
        case .compressItemsCustomize(let items):
            // Same selector: the click is dispatched from the live selection and
            // the title, which is what tells the dialog variant apart.
            addItem(
                title: title,
                selector: #selector(performCompressItems(_:)),
                representedObject: ArchiveRequest(archives: items, destination: nil, format: "zip"),
                to: menu
            )
        }
    }

    private func addItem(
        title: String,
        selector: Selector,
        representedObject: Any?,
        image: NSImage? = nil,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        // Only the favorites carry one: it is the app's full-colour PNG, so
        // there is nothing for Finder to tint (a *template* image here is the
        // thing that came out black on a highlighted row, which is why the first
        // icon attempt was removed). See README "Finder 右键菜单的图标".
        item.image = image
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
        switch FinderMenuTitles.copySubject(forTitle: title) {
        case .names:
            payload = selection.formattedNames
        case .paths:
            payload = selection.formattedPaths
        case .fileURLs:
            payload = selection.formattedFileURLs
        case .folderName:
            payload = selection.containerDirectory?.lastPathComponent
        case .folderPath:
            payload = selection.containerDirectory?.path
        case nil:
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
            OperationPresenter.presentCutFailure()
        }
    }
    @objc private func performNewFile(_ sender: NSMenuItem) {
        guard let kind = FinderMenuTitles.newFileKind(forTitle: sender.title) else {
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

        // Text kinds are generated here (small, no bundle resources). Document
        // kinds name themselves and let the main app do the work: the OOXML
        // archive writer must not ship inside the sandboxed extension, and the
        // blank iWork templates live in the app bundle.
        let request: FileOperationContract.Request
        switch kind.category {
        case .text:
            let contentsBase64 = kind.contents.map { $0.base64EncodedString() }
            request = FileOperationContract.Request(
                kind: .createFile,
                args: FileOperationContract.OperationArgs(
                    directory: directory.path,
                    name: kind.defaultName,
                    contentsBase64: contentsBase64
                ),
                clientRequestId: UUID().uuidString
            )
        case .office:
            request = FileOperationContract.Request(
                kind: .createDocument,
                args: FileOperationContract.OperationArgs(
                    directory: directory.path,
                    name: kind.defaultName,
                    documentKind: kind.rawValue
                ),
                clientRequestId: UUID().uuidString
            )
        case .iWork:
            request = FileOperationContract.Request(
                kind: .createFromTemplate,
                args: FileOperationContract.OperationArgs(
                    directory: directory.path,
                    name: kind.defaultName,
                    documentKind: kind.rawValue
                ),
                clientRequestId: UUID().uuidString
            )
        }
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
            // 取消 is not a failure: the user asked for it in the progress
            // window, and nothing was written. Say nothing at all.
            guard code != .cancelledByUser else {
                Self.diag.log("ACTION delegated CANCELLED by the user")
                return
            }
            Self.diag.log("ACTION performNewFile delegated FAILURE code=\(code.rawValue, privacy: .public) message=\(message, privacy: .public)")
            OperationPresenter.presentDelegatedCreateFailure(name: kind.defaultName, code: code, message: message)
        case .stillRunning:
            Self.diag.log("ACTION delegated STILL RUNNING after the file-operation budget")
            OperationPresenter.presentOperationStillRunning()
        case .unavailable(let reason):
            Self.diag.log("ACTION performNewFile delegated UNAVAILABLE reason=\(reason, privacy: .public)")
            OperationPresenter.presentMainAppUnavailable(context: reason)
        }
    }

    // MARK: - P7-b: favorites

    /// Opens a 常用软件 / 常用网页 / 常用文件夹 entry.
    ///
    /// Finder replays the click through a reconstructed menu item that drops
    /// `representedObject`, so the entry is looked up by title against the live
    /// settings — the same pure function that built the menu produces the same
    /// titles, and a settings change between build and click cannot mis-dispatch.
    @objc private func performOpenFavorite(_ sender: NSMenuItem) {
        let title = sender.title
        guard let entry = FinderFavorites.entries().first(where: { $0.menuTitle == title }) else {
            Self.diag.log("ACTION performOpenFavorite: no favorite matches title=\(title, privacy: .public)")
            return
        }
        Self.diag.log("ACTION INVOKED performOpenFavorite kind=\(entry.kind.rawValue, privacy: .public) target=\(entry.target, privacy: .public)")

        let request: FileOperationContract.Request
        switch entry.kind {
        case .folder:
            request = FileOperationContract.Request(
                kind: .openFolder,
                args: FileOperationContract.OperationArgs(directory: entry.target),
                clientRequestId: UUID().uuidString
            )
        case .application:
            request = FileOperationContract.Request(
                kind: .openApplication,
                args: FileOperationContract.OperationArgs(target: entry.target),
                clientRequestId: UUID().uuidString
            )
        case .website:
            request = FileOperationContract.Request(
                kind: .openURL,
                args: FileOperationContract.OperationArgs(target: entry.target),
                clientRequestId: UUID().uuidString
            )
        }
        sendDelegated(request) { [weak self] outcome in
            self?.handleOpenFavoriteOutcome(outcome, entry: entry)
        }
    }

    private func handleOpenFavoriteOutcome(
        _ outcome: ExtensionIPCClient.FileOperationOutcome,
        entry: FinderFavoriteEntry
    ) {
        switch outcome {
        case .success:
            Self.diag.log("ACTION performOpenFavorite delegated SUCCESS target=\(entry.target, privacy: .public)")
        case .batchSuccess:
            Self.diag.log("ACTION performOpenFavorite unexpected batch success target=\(entry.target, privacy: .public)")
        case .failure(let code, let message):
            // 取消 is not a failure: the user asked for it in the progress
            // window, and nothing was written. Say nothing at all.
            guard code != .cancelledByUser else {
                Self.diag.log("ACTION delegated CANCELLED by the user")
                return
            }
            Self.diag.log("ACTION performOpenFavorite delegated FAILURE code=\(code.rawValue, privacy: .public) message=\(message, privacy: .public)")
            OperationPresenter.presentDelegatedOpenFailure(name: entry.menuTitle, code: code, message: message)
        case .stillRunning:
            Self.diag.log("ACTION delegated STILL RUNNING after the file-operation budget")
            OperationPresenter.presentOperationStillRunning()
        case .unavailable(let reason):
            Self.diag.log("ACTION performOpenFavorite delegated UNAVAILABLE reason=\(reason, privacy: .public)")
            OperationPresenter.presentMainAppUnavailable(context: reason)
        }
    }

    // MARK: - P9: compression and extraction

    /// 解压 ▸.
    ///
    /// The archives come from the **live selection**, not from the menu item
    /// (Finder drops `representedObject` across the process boundary): a menu
    /// built before the selection changed cannot extract the wrong files.
    @objc private func performExtractArchives(_ sender: NSMenuItem) {
        let controller = FIFinderSyncController.default()
        let selection = FinderSelectionContext(
            itemURLs: controller.selectedItemURLs() ?? [],
            targetedURL: controller.targetedURL()
        )
        let archives = FinderArchives.classify(selection.itemURLs)
        guard archives.canExtract else {
            Self.diag.log("ACTION performExtractArchives: live selection has no extractable archive")
            return
        }
        Self.diag.log("ACTION INVOKED performExtractArchives count=\(archives.archives.count, privacy: .public) delegating=true")

        let wantsDestination = FinderMenuTitles.isCustomExtractionTitle(sender.title)
        // Finder drops `representedObject` across the process boundary, so the
        // clicked title and the live settings are the only inputs — both are
        // re-derived here exactly the way the menu built them.
        let title = sender.title
        var destinationDirectory: String?
        var customize: Bool?
        if case .folder(let configured) = FinderArchives.destination(),
           FinderMenuTitles.isConfiguredFolderExtractionTitle(title, folderName: configured.lastPathComponent) {
            // 解压位置 names a folder: go straight there, no question.
            destinationDirectory = configured.path
        } else if wantsDestination {
            customize = true
        } else if !FinderMenuTitles.isExtractHereTitle(title) {
            // The settings changed between the menu being built and the click, so
            // the title matches nothing current. Ask rather than guess a target.
            customize = true
        }
        Self.diag.log("ACTION performExtractArchives destination=\(destinationDirectory ?? (customize == true ? "<panel>" : "<archive folder>"), privacy: .public)")
        let request = FileOperationContract.Request(
            kind: .extractArchive,
            args: FileOperationContract.OperationArgs(
                sourcePaths: archives.archives.map(\.path),
                destinationDirectory: destinationDirectory,
                customize: customize
            ),
            clientRequestId: UUID().uuidString
        )
        sendDelegated(request) { [weak self] outcome in
            self?.handleArchiveOutcome(outcome, action: .presenterActionExtract)
        }
    }

    /// 压缩 ▸. Every selected item goes into one archive in its own folder.
    @objc private func performCompressItems(_ sender: NSMenuItem) {
        let controller = FIFinderSyncController.default()
        let selection = FinderSelectionContext(
            itemURLs: controller.selectedItemURLs() ?? [],
            targetedURL: controller.targetedURL()
        )
        let items = selection.itemURLs
        guard let destination = items.first?.deletingLastPathComponent() else {
            Self.diag.log("ACTION performCompressItems: no live selection")
            return
        }
        let wantsDialog = FinderMenuTitles.isCustomCompressionTitle(sender.title)
        let format = FinderMenuTitles.compressionFormat(forTitle: sender.title) ?? "zip"
        Self.diag.log("ACTION INVOKED performCompressItems count=\(items.count, privacy: .public) format=\(format, privacy: .public) target=\(destination.path, privacy: .public) delegating=true")

        let request = FileOperationContract.Request(
            kind: .compressItems,
            args: FileOperationContract.OperationArgs(
                sourcePaths: items.map(\.path),
                destinationDirectory: destination.path,
                archiveFormat: format,
                customize: wantsDialog ? true : nil
            ),
            clientRequestId: UUID().uuidString
        )
        sendDelegated(request) { [weak self] outcome in
            self?.handleArchiveOutcome(outcome, action: .presenterActionCompress)
        }
    }

    private func handleArchiveOutcome(_ outcome: ExtensionIPCClient.FileOperationOutcome, action: StringKey) {
        switch outcome {
        case .success(let createdPath):
            Self.diag.log("ACTION archive \(action.rawValue, privacy: .public) delegated SUCCESS createdPath=\(createdPath ?? "<none>", privacy: .public)")
        case .batchSuccess(let items):
            Self.diag.log("ACTION archive \(action.rawValue, privacy: .public) delegated BATCH items=\(items.count, privacy: .public) failures=\(items.filter { !$0.success }.count, privacy: .public)")
            OperationPresenter.presentDelegatedItemFailures(items, action: action)
        case .failure(let code, let message):
            // 取消 is not a failure: the user asked for it in the progress
            // window, and nothing was written. Say nothing at all.
            guard code != .cancelledByUser else {
                Self.diag.log("ACTION delegated CANCELLED by the user")
                return
            }
            Self.diag.log("ACTION archive \(action.rawValue, privacy: .public) delegated FAILURE code=\(code.rawValue, privacy: .public) message=\(message, privacy: .public)")
            OperationPresenter.presentDelegatedArchiveFailure(action: action, code: code, message: message)
        case .stillRunning:
            Self.diag.log("ACTION delegated STILL RUNNING after the file-operation budget")
            OperationPresenter.presentOperationStillRunning()
        case .unavailable(let reason):
            Self.diag.log("ACTION archive \(action.rawValue, privacy: .public) delegated UNAVAILABLE reason=\(reason, privacy: .public)")
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
            // 取消 is not a failure: the user asked for it in the progress
            // window, and nothing was written. Say nothing at all.
            guard code != .cancelledByUser else {
                Self.diag.log("ACTION delegated CANCELLED by the user")
                return
            }
            Self.diag.log("ACTION performNewFolder delegated FAILURE code=\(code.rawValue, privacy: .public) message=\(message, privacy: .public)")
            OperationPresenter.presentDelegatedCreateFailure(name: "New Folder", code: code, message: message)
        case .stillRunning:
            Self.diag.log("ACTION delegated STILL RUNNING after the file-operation budget")
            OperationPresenter.presentOperationStillRunning()
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
            // 取消 is not a failure: the user asked for it in the progress
            // window, and nothing was written. Say nothing at all.
            guard code != .cancelledByUser else {
                Self.diag.log("ACTION delegated CANCELLED by the user")
                return
            }
            Self.diag.log("ACTION performPaste delegated FAILURE code=\(code.rawValue, privacy: .public) message=\(message, privacy: .public)")
            if code == .notAuthorized || code == .pathOutsideAuthorizedScope {
                OperationPresenter.presentFolderAccessRequired()
            } else {
                OperationPresenter.presentOperationFailure(title: .presenterPasteFailedTitle, message: message)
            }
        case .stillRunning:
            Self.diag.log("ACTION delegated STILL RUNNING after the file-operation budget")
            OperationPresenter.presentOperationStillRunning()
        case .unavailable(let reason):
            Self.diag.log("ACTION performPaste delegated UNAVAILABLE reason=\(reason, privacy: .public)")
            OperationPresenter.presentMainAppUnavailable(context: reason)
        }
    }

    /// Runs one delegated file operation on `ipcQueue` and delivers the outcome
    /// on the main queue. Called from Finder menu actions, which run on the main
    /// thread: the transport call must never happen there, and the alert must
    /// only happen there.
    ///
    /// Also the single place that knows an operation is *in flight*, which is the
    /// only progress signal this side has: the extension sends one request and
    /// gets one reply, so "we are still waiting" is all it can honestly say —
    /// but saying nothing at all for minutes reads as "the click did nothing",
    /// which is exactly how a folder compression looked before this notice.
    private func sendDelegated(
        _ request: FileOperationContract.Request,
        then handle: @escaping (ExtensionIPCClient.FileOperationOutcome) -> Void
    ) {
        let token: Int = { delegatedToken += 1; return delegatedToken }()
        let clientRequestId = request.clientRequestId ?? ""

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.busyNoticeDelay) { [weak self] in
            // A fast operation has already finished and bumped the token; do not
            // flash a notice over its result.
            guard let self, self.delegatedToken == token else { return }
            self.showProgress(for: request, clientRequestId: clientRequestId)
        }

        ipcQueue.async {
            let outcome = ExtensionIPCClient.sendFileOperation(request) { fraction in
                // Progress frames arrive on this queue; the bar is main-thread.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.delegatedToken == token else { return }
                    self.progressWindow?.update(fraction: fraction)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Only the operation that currently owns the window may take it
                // down — otherwise a second click would hide the first one's.
                if self.delegatedToken == token {
                    self.delegatedToken += 1
                    self.dismissProgress()
                }
                handle(outcome)
            }
        }
    }

    /// The compression window, or nil. Main thread only.
    private var progressWindow: ArchiveProgressWindow?

    private func showProgress(for request: FileOperationContract.Request, clientRequestId: String) {
        // Archive work reports real progress and can be paused or cancelled;
        // everything else has nothing to report, so a spinner notice is the most
        // the extension can honestly say.
        let titleKey: StringKey
        switch request.kind {
        case .compressItems: titleKey = .presenterProgressTitle
        case .extractArchive: titleKey = .presenterProgressExtractTitle
        default:
            OperationPresenter.presentBusy(for: request.kind)
            return
        }
        OperationPresenter.dismissBusy()
        let window = ArchiveProgressWindow(
            title: appText(titleKey),
            pauseTitle: appText(.presenterProgressPause),
            resumeTitle: appText(.presenterProgressResume),
            cancelTitle: appText(.presenterProgressCancel)
        )
        window.onPauseToggle = { [weak self] paused in
            self?.sendControl(paused ? .pause : .resume, clientRequestId: clientRequestId)
        }
        window.onCancel = { [weak self] in
            self?.sendControl(.cancel, clientRequestId: clientRequestId)
        }
        progressWindow = window
        window.update(fraction: 0)
        window.show()
    }

    /// 暂停/继续/取消 travel on their own connection: the data connection is
    /// parked waiting for the answer, so a control frame sent there would not be
    /// read until the work it is meant to interrupt had finished.
    private func sendControl(_ action: ArchiveControlAction, clientRequestId: String) {
        guard !clientRequestId.isEmpty else {
            Self.diag.log("ACTION control \(action.rawValue, privacy: .public) dropped: the request has no clientRequestId")
            return
        }
        Self.diag.log("ACTION control \(action.rawValue, privacy: .public) cid=\(clientRequestId, privacy: .public)")
        controlQueue.async {
            let applied = ExtensionIPCClient.sendFileOperationControl(clientRequestId: clientRequestId, action: action)
            Self.diag.log("ACTION control \(action.rawValue, privacy: .public) applied=\(applied, privacy: .public)")
        }
    }

    private func dismissProgress() {
        progressWindow?.close()
        progressWindow = nil
    }

    /// Localized text for the extension's own windows.
    private func appText(_ key: StringKey) -> String {
        Localization.text(key, language: FinderMenuLanguage.resolve())
    }

    /// How long an operation may stay silent before the progress notice appears.
    /// Short enough to cover a real folder compression, long enough that the
    /// common sub-second operation never flashes a window.
    private static let busyNoticeDelay: TimeInterval = 1.5

    /// Bumped on the main queue when a delegated operation starts or finishes;
    /// see `sendDelegated`.
    private var delegatedToken = 0

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
            // 取消 is not a failure: the user asked for it in the progress
            // window, and nothing was written. Say nothing at all.
            guard code != .cancelledByUser else {
                Self.diag.log("ACTION delegated CANCELLED by the user")
                return
            }
            Self.diag.log("ACTION performOpenTerminal delegated FAILURE code=\(code.rawValue, privacy: .public) message=\(message, privacy: .public)")
            OperationPresenter.presentOperationFailure(title: .presenterTerminalFailedTitle, message: message)
        case .stillRunning:
            Self.diag.log("ACTION delegated STILL RUNNING after the file-operation budget")
            OperationPresenter.presentOperationStillRunning()
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
            self?.handleItemResultsOutcome(outcome, action: .presenterActionCreateAlias)
        }
    }

    @objc private func performSetLocked(_ sender: NSMenuItem) {
        let items = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !items.isEmpty else {
            Self.diag.log("ACTION performSetLocked: no live selection, ignoring")
            return
        }
        // Title-based dispatch, because representedObject is lost. Matched in any
        // language, so a menu built before a language switch still works.
        let locked = !FinderMenuTitles.isUnlockTitle(sender.title)
        Self.diag.log("ACTION INVOKED performSetLocked locked=\(locked, privacy: .public) count=\(items.count, privacy: .public) delegating=true")
        let request = FileOperationContract.Request(
            kind: .setLocked,
            args: FileOperationContract.OperationArgs(sourcePaths: items.map(\.path), locked: locked),
            clientRequestId: UUID().uuidString
        )
        sendDelegated(request) { [weak self] outcome in
            self?.handleItemResultsOutcome(outcome, action: locked ? .presenterActionLock : .presenterActionUnlock)
        }
    }

    /// Shared handler for the per-item operations (alias creation, locking).
    /// Success stays silent; failures are reported once, per item count.
    private func handleItemResultsOutcome(
        _ outcome: ExtensionIPCClient.FileOperationOutcome,
        action: StringKey
    ) {
        switch outcome {
        case .success:
            Self.diag.log("ACTION \(action.rawValue, privacy: .public) delegated SUCCESS")
        case .batchSuccess(let items):
            let failures = items.filter { !$0.success }
            Self.diag.log("ACTION \(action.rawValue, privacy: .public) delegated DONE count=\(items.count, privacy: .public) failures=\(failures.count, privacy: .public)")
            OperationPresenter.presentDelegatedItemFailures(items, action: action)
        case .failure(let code, let message):
            // 取消 is not a failure: the user asked for it in the progress
            // window, and nothing was written. Say nothing at all.
            guard code != .cancelledByUser else {
                Self.diag.log("ACTION delegated CANCELLED by the user")
                return
            }
            Self.diag.log("ACTION \(action.rawValue, privacy: .public) delegated FAILURE code=\(code.rawValue, privacy: .public) message=\(message, privacy: .public)")
            if code == .notAuthorized || code == .pathOutsideAuthorizedScope {
                OperationPresenter.presentFolderAccessRequired()
            } else {
                OperationPresenter.presentDelegatedActionFailure(action: action, message: message)
            }
        case .stillRunning:
            Self.diag.log("ACTION delegated STILL RUNNING after the file-operation budget")
            OperationPresenter.presentOperationStillRunning()
        case .unavailable(let reason):
            Self.diag.log("ACTION \(action.rawValue, privacy: .public) delegated UNAVAILABLE reason=\(reason, privacy: .public)")
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

/// Represented object carried by the archive menu items (P9).
struct ArchiveRequest {
    let archives: [URL]
    let destination: URL?
    var format: String = "zip"
}
