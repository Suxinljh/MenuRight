import Foundation

/// Groups shown in the New File pane and, later, in the Finder submenu.
enum NewFileCategory: String, Codable, CaseIterable, Sendable {
    case text
    case office
    case iWork
}

/// A file kind the New File menu can create.
///
/// Raw values of the text kinds intentionally match the Finder extension's
/// `NewFileKind` raw values (the enum that is shipped today), so the settings
/// payload can drive the extension menu later without a translation table.
/// `MenuRightTests` asserts that match.
enum NewFileType: String, Codable, CaseIterable, Sendable {
    case text
    case markdown
    case html
    case css
    case javascript
    case json
    case docx
    case xlsx
    case pptx
    case pages
    case numbers
    case keynote

    var titleKey: StringKey {
        switch self {
        case .text: return .newFileKindText
        case .markdown: return .newFileKindMarkdown
        case .html: return .newFileKindHTML
        case .css: return .newFileKindCSS
        case .javascript: return .newFileKindJavaScript
        case .json: return .newFileKindJSON
        case .docx: return .newFileKindWord
        case .xlsx: return .newFileKindExcel
        case .pptx: return .newFileKindPowerPoint
        case .pages: return .newFileKindPages
        case .numbers: return .newFileKindNumbers
        case .keynote: return .newFileKindKeynote
        }
    }

    var category: NewFileCategory {
        switch self {
        case .text, .markdown, .html, .css, .javascript, .json:
            return .text
        case .docx, .xlsx, .pptx:
            return .office
        case .pages, .numbers, .keynote:
            return .iWork
        }
    }

    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .markdown: return "md"
        case .html: return "html"
        case .css: return "css"
        case .javascript: return "js"
        case .json: return "json"
        case .docx: return "docx"
        case .xlsx: return "xlsx"
        case .pptx: return "pptx"
        case .pages: return "pages"
        case .numbers: return "numbers"
        case .keynote: return "key"
        }
    }

    /// Lucide/Phosphor asset rendered next to the type in 新建文件.
    ///
    /// Eleven come from Phosphor (MIT), the JSON one from Lucide (ISC) — these
    /// are the two sets the icon specification names. Both vendors' licence
    /// texts ship in `Resources/Third-Party-Notices/`, and
    /// `Scripts/check-icons.sh` fails if an asset here is missing from the
    /// catalog.
    ///
    /// Phosphor draws filled shapes on a 256pt grid, Lucide draws 2pt strokes on
    /// a 24pt grid; at 16pt they read as one family but are not pixel-identical.
    var iconAsset: String {
        switch self {
        case .text: return "phosphor-file-txt"
        case .markdown: return "phosphor-file-md"
        case .html: return "phosphor-file-html"
        case .css: return "phosphor-file-css"
        case .javascript: return "phosphor-file-js"
        case .json: return "lucide-file-braces-corner"
        case .docx: return "phosphor-file-doc"
        case .xlsx: return "phosphor-file-xls"
        case .pptx: return "phosphor-file-ppt"
        case .pages: return "phosphor-file"
        case .numbers: return "phosphor-table"
        case .keynote: return "phosphor-lectern"
        }
    }

    /// True for kinds the app **copies from a bundled blank document**
    /// (Pages/Numbers/Keynote). The settings pane badges these when the template
    /// is not in this build, and the Finder menu hides them (P6-b).
    var requiresTemplate: Bool {
        category == .iWork
    }

    /// True for kinds the app produces from scratch: text formats written by the
    /// extension, and Word/Excel/PowerPoint packages written by
    /// `OOXMLDocumentFactory`. These are always available.
    var isGenerated: Bool {
        !requiresTemplate
    }

    /// The file name the menu would create for a given base name.
    func defaultFileName(baseName: String) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? NewFileSettings.defaultBaseName : trimmed
        return "\(base).\(fileExtension)"
    }
}
