import Foundation

/// A single copy action offered by the Finder context menu.
struct FinderCopyAction: Equatable {
    let title: String
    let payload: String
}

/// Pure mapping from a selection snapshot to the copy actions for a contextual
/// menu. No AppKit or FinderSync imports: fully unit-testable.
enum FinderMenuBuilder {
    /// Phase A1 actions for a selection:
    ///   - with items: Copy Name / Copy Path / Copy File URL
    ///   - container (background) click: Copy Folder Path
    ///   - nothing usable: empty array (hide the menu)
    static func copyActions(for selection: FinderSelectionContext) -> [FinderCopyAction] {
        if selection.hasSelection {
            return [
                FinderCopyAction(title: "Copy Name", payload: selection.formattedNames),
                FinderCopyAction(title: "Copy Path", payload: selection.formattedPaths),
                FinderCopyAction(title: "Copy File URL", payload: selection.formattedFileURLs),
            ]
        }

        // Empty background right-click: only offer the folder path.
        if let folder = selection.containerDirectory {
            return [FinderCopyAction(title: "Copy Folder Path", payload: folder.path)]
        }

        return []
    }
}
