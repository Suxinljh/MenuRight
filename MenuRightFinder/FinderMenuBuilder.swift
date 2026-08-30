import Foundation

/// Templates for New File. Exactly three kinds in Phase A2.
enum NewFileKind: String, CaseIterable, Equatable {
    case text
    case markdown
    case json

    var title: String {
        switch self {
        case .text: return "Text File"
        case .markdown: return "Markdown File"
        case .json: return "JSON File"
        }
    }

    var defaultName: String {
        switch self {
        case .text: return "Untitled.txt"
        case .markdown: return "Untitled.md"
        case .json: return "Untitled.json"
        }
    }

    var contents: Data? {
        switch self {
        case .text, .markdown: return nil   // empty file
        case .json: return Data("{}".utf8)
        }
    }
}

/// A single actionable item the Finder context menu offers.
enum FinderMenuAction: Equatable {
    case copyName(payload: String)
    case copyPath(payload: String)
    case copyFileURL(payload: String)
    case copyFolderPath(payload: String)
    case cut(items: [URL])
    case pasteHere(destination: URL, enabled: Bool)
    case newFile(kind: NewFileKind, directory: URL)
    case newFolder(directory: URL)
}

/// Pure description of the context menu. AppKit only enters at build time in
/// FinderSync; everything here is unit-testable without Finder.
enum FinderMenuPlanItem: Equatable {
    case separator
    case action(FinderMenuAction)
    case submenu(title: String, actions: [FinderMenuAction])
}

/// Pure mapping from selection snapshot to the Phase A1 + A2 menu structure.
///
/// Item selection:
///   Copy Name / Copy Path / Copy File URL ─ Cut
/// Container background:
///   New File ▸ Text / Markdown / JSON; New Folder ─ Paste Here ─ Copy Folder Path
enum FinderMenuBuilder {
    static func plan(for selection: FinderSelectionContext, hasCutPayload: Bool) -> [FinderMenuPlanItem] {
        if selection.hasSelection {
            return [
                .action(.copyName(payload: selection.formattedNames)),
                .action(.copyPath(payload: selection.formattedPaths)),
                .action(.copyFileURL(payload: selection.formattedFileURLs)),
                .separator,
                .action(.cut(items: selection.itemURLs)),
            ]
        }

        guard let container = selection.containerDirectory else { return [] }

        return [
            .submenu(title: "New File", actions: NewFileKind.allCases.map { kind in
                .newFile(kind: kind, directory: container)
            }),
            .action(.newFolder(directory: container)),
            .separator,
            .action(.pasteHere(destination: container, enabled: hasCutPayload)),
            .separator,
            .action(.copyFolderPath(payload: container.path)),
        ]
    }
}
