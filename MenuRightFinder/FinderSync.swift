import Cocoa
import FinderSync

/// Principal class of the MenuRightFinder Finder Sync Extension.
///
/// Phase A2 scope adds file operations (New File / New Folder / Cut / Paste
/// Here) while keeping menu(for:) strictly CPU-cheap: no networking, no
/// directory scans, no write probes, no hashing, no timers, no observers.
/// All filesystem work happens only after the user invokes an action.
final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        // Monitor the user home directory (and everything below it).
        // Deliberately NOT "/", /Volumes, network volumes, or iCloud.
        FIFinderSyncController.default().directoryURLs = [
            FileManager.default.homeDirectoryForCurrentUser
        ]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // Phase A2 supports only contextual menus (items + container).
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            return nil
        }

        // Read the selection inside the legitimate Finder Sync context only.
        let controller = FIFinderSyncController.default()
        let selection = FinderSelectionContext(
            itemURLs: controller.selectedItemURLs() ?? [],
            targetedURL: controller.targetedURL()
        )

        // Pasteboard decode only — no filesystem work while building the menu.
        let hasCutPayload = CutPasteboard.containsValidCut()
        let plan = FinderMenuBuilder.plan(for: selection, hasCutPayload: hasCutPayload)
        guard !plan.isEmpty else { return nil }

        return makeMenu(from: plan)
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
        guard let payload = sender.representedObject as? String else { return }
        PasteboardWriter.write(payload)
    }

    @objc private func performCut(_ sender: NSMenuItem) {
        guard let items = sender.representedObject as? [URL] else { return }
        do {
            try CutPasteboard.write(CutPayload(urls: items))
        } catch {
            OperationPresenter.presentTitle("Couldn’t cut items.", message: "The cut information could not be written to the pasteboard.")
        }
    }

    @objc private func performNewFile(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? NewFileRequest else { return }
        switch FileOperationService.createFile(
            in: request.directory,
            preferredName: request.kind.defaultName,
            contents: request.kind.contents
        ) {
        case .success:
            break
        case .failure(let error):
            OperationPresenter.presentCreationFailure(name: request.kind.defaultName, in: request.directory, error: error)
        }
    }

    @objc private func performNewFolder(_ sender: NSMenuItem) {
        guard let directory = sender.representedObject as? URL else { return }
        switch FileOperationService.createDirectory(in: directory, preferredName: "New Folder") {
        case .success:
            break
        case .failure(let error):
            OperationPresenter.presentCreationFailure(name: "New Folder", in: directory, error: error)
        }
    }

    @objc private func performPaste(_ sender: NSMenuItem) {
        guard let destination = sender.representedObject as? URL else { return }
        guard let payload = CutPasteboard.read() else { return }

        let results = FileOperationService.moveItems(payload.urls, to: destination)
        applyPasteLifecycle(for: results)

        switch FileOperationBatchSummary.summarize(results) {
        case .allSucceeded:
            break
        case .allFailed, .partial:
            OperationPresenter.presentPasteResults(results)
        }
    }

    // MARK: - Cut payload lifecycle (§15)

    /// allSucceeded: clear the cut payload.
    /// partial:      keep only the failed source URLs for retry.
    /// allFailed:    leave the existing payload untouched.
    private func applyPasteLifecycle(for results: [FileOperationItemResult]) {
        switch FileOperationBatchSummary.summarize(results) {
        case .allSucceeded:
            CutPasteboard.remove()
        case .partial(let failures):
            try? CutPasteboard.write(CutPayload(urls: failures.map { $0.sourceURL }))
        case .allFailed:
            break
        }
    }
}

/// Represented object carried by New File menu items.
struct NewFileRequest {
    let kind: NewFileKind
    let directory: URL
}
