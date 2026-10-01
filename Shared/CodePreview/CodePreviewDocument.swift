import AppKit

/// A rendered code preview: the attributed text plus the few facts the panel
/// chrome needs (background colour, truncation).
struct CodePreviewDocument {
    let text: NSAttributedString
    let backgroundColor: NSColor
    let language: CodeLanguage
    let fileName: String
    /// Lines actually rendered.
    let renderedLineCount: Int
    /// True when the source had more lines than `CodePreviewLimits.maxLines`.
    let isTruncated: Bool
}

/// Guards that keep a huge file from stalling the preview panel.
struct CodePreviewLimits {
    /// Bytes read from disk before the preview gives up on the rest.
    var maxBytes: Int = 1_000_000
    /// Lines rendered. A longer file shows its first page plus a footer notice.
    var maxLines: Int = 5_000

    static let `default` = CodePreviewLimits()
}

/// Reads a previewable text file with a byte cap and an encoding fallback.
///
/// The byte cap exists because Quick Look must stay responsive: reading a 2 GB
/// log into memory to colour ten visible lines would hang the panel.
enum CodePreviewFileReader {
    struct Result {
        let text: String
        /// True when the file was longer than `maxBytes`.
        let isByteTruncated: Bool
    }

    enum Failure: Error {
        case unreadable(underlying: Error)
    }

    static func read(from url: URL, maxBytes: Int = CodePreviewLimits.default.maxBytes) throws -> Result {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Failure.unreadable(underlying: error)
        }
        defer { try? handle.close() }

        let data: Data
        do {
            // One extra byte tells us whether there is more to come.
            data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        } catch {
            throw Failure.unreadable(underlying: error)
        }

        let isTruncated = data.count > maxBytes
        let body = isTruncated ? Data(data.prefix(maxBytes)) : data
        return Result(text: decode(body), isByteTruncated: isTruncated)
    }

    /// UTF-8 first, then GB18030 when the bytes really look Chinese, then
    /// ISO Latin-1 — which never fails, so a preview always renders something.
    ///
    /// Deliberately simpler than `ZipReader`'s filename heuristic: source files
    /// are overwhelmingly UTF-8, and a wrong guess only affects colouring.
    static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        // A byte cap can cut a multi-byte character in half; drop the partial
        // tail once before giving up on UTF-8.
        if data.count > 4, let text = String(data: data.dropLast(4), encoding: .utf8) { return text }
        if looksLikeLegacyChinese(data), let text = String(data: data, encoding: gb18030), containsCJK(text) {
            return text
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// At least a quarter of the bytes are non-ASCII — the shape of a legacy
    /// Chinese source file (`let 名称 = 1`) rather than of a Western one with a
    /// few accents (`Übersicht`). GB18030 accepts a large fraction of arbitrary
    /// bytes, so this guard is what keeps `Übersicht` from turning Chinese.
    static func looksLikeLegacyChinese(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let high = data.reduce(into: 0) { count, byte in if byte >= 0x80 { count += 1 } }
        return high * 4 >= data.count
    }

    /// True when the text contains a CJK ideograph or CJK/fullwidth punctuation.
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
                return true
            default:
                return false
            }
        }
    }

    /// GB18030 — a superset of GBK and GB2312 (`kCFStringEncodingGB_18030_2000`).
    static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )
}

/// Builds the attributed text for a Quick Look code preview.
///
/// Pure — no view, no file IO — so the whole rendering contract is unit-testable
/// and `PreviewViewController` stays a thin plumbing layer. It reuses the same
/// `CodeHighlighter` and the same `CodeThemeSettings` as the settings preview,
/// which is what keeps the two surfaces from drifting apart.
enum CodePreviewDocumentBuilder {
    static func makeDocument(
        source: String,
        fileName: String,
        settings: CodePreviewSettings,
        prefersDark: Bool,
        limits: CodePreviewLimits = .default
    ) -> CodePreviewDocument {
        let theme = settings.theme.resolvedTheme(prefersDark: prefersDark)
        let language = CodeLanguage.detect(fileName: fileName)

        let allLines = CodeHighlighter.splitLines(source)
        let isTruncated = allLines.count > limits.maxLines
        let visibleLines = isTruncated ? Array(allLines.prefix(limits.maxLines)) : allLines
        let highlighted = CodeHighlighter.highlight(visibleLines.joined(separator: "\n"), language: language)

        let font = previewFont(for: settings)
        let paragraph = paragraphStyle(showsLineNumbers: settings.theme.showsLineNumbers, fontSize: settings.theme.fontSize)
        let text = NSMutableAttributedString()

        for (index, line) in highlighted.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: "\n", attributes: attributes(font: font, paragraph: paragraph, color: color(theme, .foreground))))
            }
            if settings.theme.showsLineNumbers {
                text.append(NSAttributedString(string: "\(index + 1)\t\t", attributes: attributes(font: font, paragraph: paragraph, color: color(theme, .comment))))
            }
            for token in line.tokens {
                text.append(NSAttributedString(string: token.text, attributes: attributes(font: font, paragraph: paragraph, color: color(theme, token.kind))))
            }
        }

        return CodePreviewDocument(
            text: text,
            backgroundColor: color(theme, .background),
            language: language,
            fileName: fileName,
            renderedLineCount: highlighted.count,
            isTruncated: isTruncated
        )
    }

    /// Gutter width in points: room for four digits at the chosen size.
    static func gutterWidth(fontSize: Double) -> CGFloat {
        max(28, CGFloat(fontSize) * 3)
    }

    /// Gap between the right edge of the numbers and the first code column.
    static func gutterGap(fontSize: Double) -> CGFloat {
        max(8, CGFloat(fontSize) * 0.75)
    }

    /// Two tab stops, not one: a right-aligned stop ends the number, and a
    /// left-aligned stop starts the code. A single stop would butt the number
    /// against the code (`1// note`), because the text resumes exactly where the
    /// right-aligned stop is.
    static func paragraphStyle(showsLineNumbers: Bool, fontSize: Double) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        if showsLineNumbers {
            let gutter = gutterWidth(fontSize: fontSize)
            let codeColumn = gutter + gutterGap(fontSize: fontSize)
            paragraph.tabStops = [
                NSTextTab(textAlignment: .right, location: gutter),
                NSTextTab(textAlignment: .left, location: codeColumn),
            ]
            // Wrapped lines line up under the code, not under the gutter.
            paragraph.headIndent = codeColumn
            paragraph.firstLineHeadIndent = 0
        }
        return paragraph
    }

    /// The configured font, falling back to the system monospaced font when the
    /// name is nil or not installed.
    static func previewFont(for settings: CodePreviewSettings) -> NSFont {
        let size = CGFloat(settings.theme.fontSize)
        if let name = settings.theme.fontName, let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func color(_ theme: CodeTheme, _ token: CodeThemeToken) -> NSColor {
        let rgb = theme.rgb(for: token)
        return NSColor(
            srgbRed: CGFloat(rgb.red),
            green: CGFloat(rgb.green),
            blue: CGFloat(rgb.blue),
            alpha: 1
        )
    }

    private static func attributes(font: NSFont, paragraph: NSParagraphStyle, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }
}
