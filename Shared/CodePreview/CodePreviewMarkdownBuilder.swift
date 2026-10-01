import AppKit

extension CodePreviewDocumentBuilder {
    /// Renders Markdown as prose — headings, lists, quotes, tables and code
    /// blocks — tinted with the same theme the code path uses.
    ///
    /// The extension claims `net.daringfireball.markdown`, so this has to be a
    /// real renderer rather than highlighted source: taking the type over while
    /// showing raw text would replace a dedicated renderer with something worse.
    static func makeMarkdownDocument(
        source: String,
        fileName: String,
        settings: CodePreviewSettings,
        prefersDark: Bool,
        limits: CodePreviewLimits = .default
    ) -> CodePreviewDocument {
        let theme = settings.theme.resolvedTheme(prefersDark: prefersDark)
        let allLines = CodeHighlighter.splitLines(source)
        let isTruncated = allLines.count > limits.maxLines
        // Truncate before parsing: half a document still renders, and the footer
        // tells the user it was cut.
        let visibleSource = isTruncated ? allLines.prefix(limits.maxLines).joined(separator: "\n") : source

        let renderer = MarkdownRenderer(theme: theme, settings: settings)
        return CodePreviewDocument(
            text: renderer.render(MarkdownAnalyzer.analyze(visibleSource)),
            backgroundColor: renderer.background,
            language: .markdown,
            fileName: fileName,
            renderedLineCount: allLines.count,
            isTruncated: isTruncated
        )
    }
}

/// Turns `MarkdownDocument` blocks into a themed `NSAttributedString`.
///
/// Prose uses the system font (a monospaced body reads badly for paragraphs);
/// inline code, code blocks and tables use the monospaced font configured in
/// Settings, so the code parts still match the code preview.
private struct MarkdownRenderer {
    let theme: CodeTheme
    let bodySize: CGFloat
    let bodyFont: NSFont
    let codeFont: NSFont

    init(theme: CodeTheme, settings: CodePreviewSettings) {
        self.theme = theme
        self.bodySize = CGFloat(settings.theme.fontSize)
        self.bodyFont = .systemFont(ofSize: bodySize)
        self.codeFont = CodePreviewDocumentBuilder.previewFont(for: settings)
    }

    var background: NSColor { color(.background) }

    func render(_ document: MarkdownDocument) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for block in document.blocks {
            append(block, to: output)
        }
        // Every block ends with its own newline so its paragraph spacing applies;
        // the very last one is dropped again.
        if output.length > 0, output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
    }

    // MARK: Blocks

    private func append(_ block: MarkdownDocument.Block, to output: NSMutableAttributedString) {
        switch block {
        case .heading(let level, let runs):
            let font = NSFont.systemFont(ofSize: headingSize(level), weight: .semibold)
            let paragraph = paragraph(spacingBefore: bodySize * 0.9, spacingAfter: bodySize * 0.35)
            appendInline(runs, baseFont: font, baseColor: color(.foreground), paragraph: paragraph, to: output)
            newline(paragraph, to: output)

        case .paragraph(let runs):
            let paragraph = paragraph(spacingAfter: bodySize * 0.5)
            appendInline(runs, baseFont: bodyFont, baseColor: color(.foreground), paragraph: paragraph, to: output)
            newline(paragraph, to: output)

        case .listItem(let depth, let marker, let runs):
            let indent = bodySize * 1.1 * CGFloat(max(0, depth - 1))
            let paragraph = paragraph(
                spacingAfter: bodySize * 0.2,
                headIndent: indent + bodySize * 1.4,
                firstLineHeadIndent: indent
            )
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent + bodySize * 1.4)]
            output.append(NSAttributedString(string: marker + "\t", attributes: [
                .font: bodyFont,
                .foregroundColor: color(.keyword),
                .paragraphStyle: paragraph,
            ]))
            appendInline(runs, baseFont: bodyFont, baseColor: color(.foreground), paragraph: paragraph, to: output)
            newline(paragraph, to: output)

        case .blockQuote(let runs):
            let indent = bodySize * 1.2
            let paragraph = paragraph(spacingAfter: bodySize * 0.5, headIndent: indent, firstLineHeadIndent: indent)
            output.append(NSAttributedString(string: "▎ ", attributes: [
                .font: bodyFont,
                .foregroundColor: color(.comment),
                .paragraphStyle: paragraph,
            ]))
            appendInline(runs, baseFont: bodyFont, baseColor: color(.comment), paragraph: paragraph, to: output)
            newline(paragraph, to: output)

        case .codeBlock(let hint, let code):
            appendCodeBlock(code, languageHint: hint, to: output)

        case .table(let table):
            appendTable(table, to: output)

        case .thematicBreak:
            let paragraph = paragraph(spacingBefore: bodySize * 0.4, spacingAfter: bodySize * 0.5)
            output.append(NSAttributedString(string: "⸻", attributes: [
                .font: bodyFont,
                .foregroundColor: color(.comment),
                .paragraphStyle: paragraph,
            ]))
            newline(paragraph, to: output)
        }
    }

    private func appendCodeBlock(_ code: String, languageHint: String?, to output: NSMutableAttributedString) {
        let language = codeLanguage(for: languageHint)
        let lines = CodeHighlighter.highlight(code, language: language)

        // A tint on every run rather than an `NSTextBlock` background: the block
        // background is not drawn by a plain `NSTextView` (measured — the
        // rendered panel came out byte-identical with the tint at 7% and 16%),
        // while a run background is reliably visible.
        let tint = blend(background, with: color(.foreground), amount: 0.12)
        let paragraph = paragraph(
            spacingBefore: bodySize * 0.5,
            spacingAfter: bodySize * 0.6,
            headIndent: 10,
            firstLineHeadIndent: 10,
            lineSpacing: 2
        )

        for (index, line) in lines.enumerated() {
            if index > 0 { newline(paragraph, to: output, background: tint) }
            for token in line.tokens {
                output.append(NSAttributedString(string: token.text, attributes: [
                    .font: codeFont,
                    .foregroundColor: color(token.kind),
                    .backgroundColor: tint,
                    .paragraphStyle: paragraph,
                ]))
            }
        }
        newline(paragraph, to: output, background: tint)
    }

    private func appendTable(_ table: MarkdownDocument.MarkdownTable, to output: NSMutableAttributedString) {
        let paragraph = paragraph(spacingBefore: bodySize * 0.3, spacingAfter: bodySize * 0.6, lineSpacing: 1)
        let lines = table.alignedLines

        for (index, line) in lines.enumerated() {
            if index > 0 { newline(paragraph, to: output) }
            let token: CodeThemeToken = line.kind == .separator ? .comment : (line.kind == .header ? .keyword : .foreground)
            let font = line.kind == .header ? withTrait(.bold, codeFont) : codeFont
            output.append(NSAttributedString(string: line.text, attributes: [
                .font: font,
                .foregroundColor: color(token),
                .paragraphStyle: paragraph,
            ]))
        }
        newline(paragraph, to: output)
    }

    // MARK: Inline

    private func appendInline(
        _ runs: [MarkdownDocument.InlineRun],
        baseFont: NSFont,
        baseColor: NSColor,
        paragraph: NSParagraphStyle,
        to output: NSMutableAttributedString
    ) {
        for run in runs {
            if run.isInlineCode {
                output.append(NSAttributedString(string: run.text, attributes: [
                    .font: codeFont,
                    .foregroundColor: color(.string),
                    .backgroundColor: blend(background, with: color(.foreground), amount: 0.12),
                    .paragraphStyle: paragraph,
                ]))
                continue
            }

            var font = baseFont
            if run.isStrong { font = withTrait(.bold, font) }
            if run.isEmphasis { font = withTrait(.italic, font) }

            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
            if run.isLink {
                attributes[.foregroundColor] = color(.function)
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            } else {
                attributes[.foregroundColor] = baseColor
            }
            output.append(NSAttributedString(string: run.text, attributes: attributes))
        }
    }

    // MARK: Helpers

    private func headingSize(_ level: Int) -> CGFloat {
        let scales: [CGFloat] = [1.7, 1.45, 1.25, 1.1, 1.0, 1.0]
        let scale = scales[min(max(level, 1), 6) - 1]
        return (bodySize * scale).rounded()
    }

    private func paragraph(
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = 0,
        headIndent: CGFloat = 0,
        firstLineHeadIndent: CGFloat = 0,
        lineSpacing: CGFloat = 0
    ) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.paragraphSpacing = spacingAfter
        paragraph.headIndent = headIndent
        paragraph.firstLineHeadIndent = firstLineHeadIndent
        paragraph.lineSpacing = lineSpacing
        return paragraph
    }

    private func newline(_ paragraph: NSParagraphStyle, to output: NSMutableAttributedString, background: NSColor? = nil) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: color(.foreground),
            .paragraphStyle: paragraph,
        ]
        if let background { attributes[.backgroundColor] = background }
        output.append(NSAttributedString(string: "\n", attributes: attributes))
    }

    private func withTrait(_ trait: NSFontDescriptor.SymbolicTraits, _ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private func codeLanguage(for hint: String?) -> CodeLanguage {
        guard let hint, !hint.isEmpty else { return .plainText }
        if let exact = CodeLanguage(rawValue: hint.lowercased()) { return exact }
        let byExtension = CodeLanguage.detect(fileExtension: hint)
        return byExtension == .plainText ? .plainText : byExtension
    }

    private func color(_ token: CodeThemeToken) -> NSColor {
        CodePreviewDocumentBuilder.color(theme, token)
    }

    /// Mixes two colours — used for the subtle code/table tints that have to sit
    /// on top of an arbitrary theme background.
    private func blend(_ base: NSColor, with other: NSColor, amount: CGFloat) -> NSColor {
        guard let a = base.usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return base }
        return NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * amount,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * amount,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * amount,
            alpha: 1
        )
    }
}
