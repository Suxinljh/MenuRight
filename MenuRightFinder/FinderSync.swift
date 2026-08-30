import Cocoa
import FinderSync

/// Principal class of the MenuRightFinder Finder Sync Extension.
///
/// Phase A1 scope: monitor the user home directory, build a lightweight
/// contextual menu from the current selection, and copy text to the pasteboard.
/// menu(for:) is kept strictly CPU-cheap: no networking, no directory scans,
/// no hashing, no timers, no observers.
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
        // Phase A1 supports only contextual menus (items + container).
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            return nil
        }

        // Read the selection inside the legitimate Finder Sync context only.
        let controller = FIFinderSyncController.default()
        let selection = FinderSelectionContext(
            itemURLs: controller.selectedItemURLs() ?? [],
            targetedURL: controller.targetedURL()
        )

        let actions = FinderMenuBuilder.copyActions(for: selection)
        guard !actions.isEmpty else { return nil }

        let menu = NSMenu(title: "")
        for action in actions {
            let item = NSMenuItem(
                title: action.title,
                action: #selector(performCopy(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = action.payload
            menu.addItem(item)
        }
        return menu
    }

    @objc private func performCopy(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? String else { return }
        PasteboardWriter.write(payload)
    }
}
