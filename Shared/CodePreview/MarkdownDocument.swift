import Foundation

/// UI-agnostic analysis of a Markdown document.
///
/// `AttributedString(markdown:)` does the parsing — including the hard parts
/// (nested lists, emphasis, links, tables) — and this turns its runs into a
/// small block model. Two emitters consume that model: AppKit for the Quick
/// Look panel, SwiftUI for the settings preview. Keeping the analysis shared is
/// what stops the two surfaces from rendering Markdown differently.
///
/// Markdown syntax markers are intentionally *not* part of the model: this is a
/// renderer, not a highlighter.
struct MarkdownDocument: Equatable {
    var blocks: [Block]

    static let empty = MarkdownDocument(blocks: [])

    enum Block: Equatable {
        case heading(level: Int, runs: [InlineRun])
        case paragraph([InlineRun])
        /// `depth` is 1 for a top-level item; `marker` is "•" or "3.".
        case listItem(depth: Int, marker: String, runs: [InlineRun])
        case blockQuote([InlineRun])
        case codeBlock(languageHint: String?, code: String)
        case table(MarkdownTable)
        case thematicBreak

        var runs: [InlineRun] {
            switch self {
            case .heading(_, let runs), .paragraph(let runs), .blockQuote(let runs): return runs
            case .listItem(_, _, let runs): return runs
            case .codeBlock, .table, .thematicBreak: return []
            }
        }
    }

    struct InlineRun: Equatable {
        var text: String
        var isStrong = false
        var isEmphasis = false
        var isInlineCode = false
        var isLink = false
    }

    struct MarkdownTable: Equatable {
        /// Header cells; an empty table has no header.
        var header: [[InlineRun]]
        var rows: [[[InlineRun]]]
    }
}

// MARK: - Analysis

enum MarkdownAnalyzer {
    static func analyze(_ source: String) -> MarkdownDocument {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let attributed = try? AttributedString(markdown: source, options: options) else {
            // Parsing must never cost the user the file's content.
            return source.isEmpty ? .empty : MarkdownDocument(blocks: [.paragraph([.init(text: source)])])
        }

        return MarkdownDocument(blocks: blocks(from: attributed))
    }

    // MARK: Run grouping

    /// One group of consecutive runs that share a block identity.
    private struct RunGroup {
        var key: String
        var kind: PresentationIntent.Kind
        var containers: [PresentationIntent.Kind]
        var runs: [MarkdownDocument.InlineRun]
    }

    private static func blocks(from attributed: AttributedString) -> [MarkdownDocument.Block] {
        var groups: [RunGroup] = []

        for run in attributed.runs {
            let components = run.presentationIntent?.components ?? []
            let kind = components.first?.kind ?? .paragraph
            let containers = components.dropFirst().map(\.kind)
            let key = "\(String(describing: kind))|\(containers.map { String(describing: $0) }.joined(separator: ">"))"

            let inline = run.inlinePresentationIntent
            let piece = MarkdownDocument.InlineRun(
                text: String(attributed[run.range].characters),
                isStrong: inline?.contains(.stronglyEmphasized) ?? false,
                isEmphasis: inline?.contains(.emphasized) ?? false,
                isInlineCode: inline?.contains(.code) ?? false,
                isLink: run.link != nil
            )

            if var last = groups.last, last.key == key {
                last.runs.append(piece)
                groups[groups.count - 1] = last
            } else {
                groups.append(RunGroup(key: key, kind: kind, containers: containers, runs: [piece]))
            }
        }

        var blocks: [MarkdownDocument.Block] = []
        var table: MarkdownDocument.MarkdownTable?

        func flushTable() {
            if let table, !table.header.isEmpty || !table.rows.isEmpty {
                blocks.append(.table(table))
            }
            table = nil
        }

        for group in groups {
            if let cell = tableCell(in: group) {
                var current = table ?? MarkdownDocument.MarkdownTable(header: [], rows: [])
                if cell.isHeader {
                    pad(&current.header, to: cell.column + 1)
                    current.header[cell.column] = group.runs
                } else {
                    let rowIndex = max(0, cell.row - 1)
                    pad(&current.rows, to: rowIndex + 1)
                    pad(&current.rows[rowIndex], to: cell.column + 1)
                    current.rows[rowIndex][cell.column] = group.runs
                }
                table = current
                continue
            }

            flushTable()

            switch group.kind {
            case .header(let level):
                blocks.append(.heading(level: level, runs: group.runs))
            case .codeBlock(let hint):
                blocks.append(.codeBlock(languageHint: hint, code: group.runs.map(\.text).joined()))
            case .thematicBreak:
                blocks.append(.thematicBreak)
            case .paragraph:
                if let list = listInfo(group.containers) {
                    blocks.append(.listItem(depth: list.depth, marker: list.marker, runs: group.runs))
                } else if group.containers.contains(where: isBlockQuote) {
                    blocks.append(.blockQuote(group.runs))
                } else {
                    blocks.append(.paragraph(group.runs))
                }
            default:
                blocks.append(.paragraph(group.runs))
            }
        }

        flushTable()
        return blocks
    }

    /// Depth + marker for a list item. `containers` is innermost-first, so the
    /// first list kind encountered is the one the marker belongs to.
    private static func listInfo(_ containers: [PresentationIntent.Kind]) -> (depth: Int, marker: String)? {
        var depth = 0
        var ordinal = 1
        var ordered = false
        var sawListKind = false

        for kind in containers {
            switch kind {
            case .listItem(let value):
                if depth == 0 { ordinal = value }
                depth += 1
            case .orderedList:
                if !sawListKind { ordered = true; sawListKind = true }
            case .unorderedList:
                if !sawListKind { ordered = false; sawListKind = true }
            default:
                break
            }
        }

        guard depth > 0 else { return nil }
        return (depth, ordered ? "\(ordinal)." : "•")
    }

    private static func isBlockQuote(_ kind: PresentationIntent.Kind) -> Bool {
        if case .blockQuote = kind { return true }
        return false
    }

    private static func tableCell(in group: RunGroup) -> (row: Int, column: Int, isHeader: Bool)? {
        guard case .tableCell(let column) = group.kind else { return nil }

        var row = 0
        var isHeader = false
        for kind in group.containers {
            switch kind {
            case .tableRow(let rowIndex): row = rowIndex
            case .tableHeaderRow: isHeader = true
            default: break
            }
        }
        return (row, column, isHeader)
    }

    private static func pad<T>(_ array: inout [T], to count: Int) where T: RangeReplaceableCollection {
        while array.count < count { array.append(T()) }
    }
}

// MARK: - Table layout

extension MarkdownDocument.MarkdownTable {
    enum AlignedLineKind: Equatable {
        case header
        case separator
        case row
    }

    struct AlignedLine: Equatable {
        let text: String
        let kind: AlignedLineKind
    }

    /// Column-aligned plain text. Computed here rather than in an emitter so the
    /// AppKit panel and the SwiftUI preview lay tables out identically; both
    /// draw it with a monospaced font.
    ///
    /// Cell width uses East-Asian display width, so a Chinese cell does not
    /// knock the following columns out of line.
    var alignedLines: [AlignedLine] {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return [] }

        var widths = [Int](repeating: 0, count: columnCount)
        for (index, cell) in header.enumerated() {
            widths[index] = max(widths[index], displayWidth(of: cell))
        }
        for row in rows {
            for (index, cell) in row.enumerated() where index < columnCount {
                widths[index] = max(widths[index], displayWidth(of: cell))
            }
        }

        func line(_ cells: [[MarkdownDocument.InlineRun]], kind: AlignedLineKind) -> AlignedLine {
            var text = ""
            for column in 0..<columnCount {
                let cell = column < cells.count ? cells[column] : []
                let cellText = cell.map(\.text).joined()
                let padding = max(0, widths[column] - displayWidth(of: cell))
                text += cellText + String(repeating: " ", count: padding)
                if column < columnCount - 1 { text += "  " }
            }
            // Trailing padding on the last column is invisible.
            while text.hasSuffix(" ") { text.removeLast() }
            return AlignedLine(text: text, kind: kind)
        }

        var lines: [AlignedLine] = []
        if !header.isEmpty { lines.append(line(header, kind: .header)) }
        if !header.isEmpty {
            lines.append(AlignedLine(text: widths.map { String(repeating: "─", count: $0) }.joined(separator: "  "), kind: .separator))
        }
        for row in rows { lines.append(line(row, kind: .row)) }
        return lines
    }

    private func displayWidth(of runs: [MarkdownDocument.InlineRun]) -> Int {
        runs.reduce(0) { $0 + MarkdownWidth.displayWidth(of: $1.text) }
    }
}

/// Display width for column alignment: East-Asian wide/fullwidth characters
/// occupy two columns in a monospaced font.
enum MarkdownWidth {
    static func displayWidth(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            total + (isWide(scalar) ? 2 : 1)
        }
    }

    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,      // Hangul Jamo
             0x2E80...0xA4CF,      // CJK radicals … Yi
             0xAC00...0xD7A3,      // Hangul syllables
             0xF900...0xFAFF,      // CJK compatibility ideographs
             0xFE30...0xFE6F,      // CJK compatibility forms
             0xFF00...0xFF60,      // Fullwidth forms
             0xFFE0...0xFFE6,
             0x1F300...0x1F64F,    // Emoji
             0x20000...0x3FFFD:    // CJK extensions B+
            return true
        default:
            return false
        }
    }
}
