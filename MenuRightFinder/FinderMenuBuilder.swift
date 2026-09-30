import Foundation

/// Templates for "New File". Phase P6 covers the text formats; the document
/// formats (Word/Excel/PPT/Pages/Numbers/Keynote) arrive in P6-b and are backed
/// by OOXML generation + bundled templates.
enum NewFileKind: String, CaseIterable, Equatable {
    case text
    case markdown
    case html
    case css
    case javascript
    case json

    var title: String {
        switch self {
        case .text: return "Text File"
        case .markdown: return "Markdown File"
        case .html: return "HTML File"
        case .css: return "CSS File"
        case .javascript: return "JavaScript File"
        case .json: return "JSON File"
        }
    }

    var defaultName: String {
        switch self {
        case .text: return "Untitled.txt"
        case .markdown: return "Untitled.md"
        case .html: return "Untitled.html"
        case .css: return "Untitled.css"
        case .javascript: return "Untitled.js"
        case .json: return "Untitled.json"
        }
    }

    /// Initial contents. `nil` means an empty file; the code formats get a
    /// minimal, valid skeleton so a new file is immediately usable.
    var contents: Data? {
        switch self {
        case .text, .markdown:
            return nil   // empty file
        case .html:
            return Data("""
            <!DOCTYPE html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <title>Untitled</title>
            </head>
            <body>

            </body>
            </html>

            """.utf8)
        case .css:
            return Data("""
            /* Styles */

            body {
            }

            """.utf8)
        case .javascript:
            return Data("\"use strict\";\n".utf8)
        case .json:
            return Data("{}".utf8)
        }
    }
}

/// Menu-item titles for the P6 actions.
///
/// Shared constants on purpose: Finder replays an action through a reconstructed
/// NSMenuItem that does not carry `representedObject` across the process
/// boundary, so `FinderSync` dispatches on `sender.title`. Title strings are
/// therefore part of the contract between this file and `FinderSync`.
enum FinderMenuTitles {
    static let createAlias = "Create Alias"
    static let lock = "Lock"
    static let unlock = "Unlock"
    static let openTerminal = "Open Terminal"
}

/// A single actionable item the Finder context menu offers.
enum FinderMenuAction: Equatable {
    // Item selection (flat menu, no submenus — see FinderMenuBuilder.plan).
    case createAlias(items: [URL])
    case setLocked(items: [URL], locked: Bool)
    case copyName(payload: String)
    case copyPath(payload: String)
    case copyFileURL(payload: String)
    case cut(items: [URL])
    // Container / desktop background.
    case openTerminal(directory: URL)
    case copyFolderName(payload: String)
    case copyFolderPath(payload: String)
    case newFile(kind: NewFileKind, directory: URL)
    case newFolder(directory: URL)
    case pasteHere(destination: URL, enabled: Bool)
}

/// Pure description of the context menu. AppKit only enters at build time in
/// FinderSync; everything here is unit-testable without Finder.
enum FinderMenuPlanItem: Equatable {
    case separator
    case action(FinderMenuAction)
    case submenu(title: String, actions: [FinderMenuAction])
}

/// Pure mapping from the right-click context to the MenuRight menu.
///
/// Platform note: macOS renders an extension's menu inside its own entry in the
/// Finder context menu, and an extension cannot create top-level items or
/// control where that entry sits. So "same level as MenuRight" is not
/// achievable; what we control is the *content* — and the item-selection case
/// is therefore built completely flat (no submenus) so no cascade appears under
/// our entry, matching the intent of "选中后不再显示级联".
///
/// The branch is decided by the *actual* menu kind (container background vs item
/// selection), NOT by selection.hasSelection: on a container right-click Finder
/// may still report a stale selectedItemURLs() from the window, and selection
/// must never be conflated with the target.
///
/// Item selection (non-empty selection, not a container menu):
///   Create Alias / Lock / Unlock ─ Copy Name / Copy Path / Copy File URL ─ Cut
/// Container background:
///   Open Terminal / Copy Folder Name / Copy Folder Path ─ New File ▸
///   / New Folder ─ Paste Here
enum FinderMenuBuilder {
    static func plan(
        for selection: FinderSelectionContext,
        containerMenu: Bool = false,
        hasCutPayload: Bool
    ) -> [FinderMenuPlanItem] {
        if !containerMenu && selection.hasSelection {
            return [
                .action(.createAlias(items: selection.itemURLs)),
                .action(.setLocked(items: selection.itemURLs, locked: true)),
                .action(.setLocked(items: selection.itemURLs, locked: false)),
                .separator,
                .action(.copyName(payload: selection.formattedNames)),
                .action(.copyPath(payload: selection.formattedPaths)),
                .action(.copyFileURL(payload: selection.formattedFileURLs)),
                .separator,
                .action(.cut(items: selection.itemURLs)),
            ]
        }

        guard let container = selection.containerDirectory else { return [] }

        return [
            .action(.openTerminal(directory: container)),
            .action(.copyFolderName(payload: container.lastPathComponent)),
            .action(.copyFolderPath(payload: container.path)),
            .separator,
            .submenu(title: "New File", actions: NewFileKind.allCases.map { kind in
                .newFile(kind: kind, directory: container)
            }),
            .action(.newFolder(directory: container)),
            .separator,
            .action(.pasteHere(destination: container, enabled: hasCutPayload)),
        ]
    }
}
