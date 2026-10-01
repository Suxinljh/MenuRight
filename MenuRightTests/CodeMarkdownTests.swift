import AppKit
import XCTest

/// Markdown support: the block analysis that both emitters share, the table
/// alignment it produces, and the AppKit rendering the Quick Look panel shows.
///
/// The extension claims `net.daringfireball.markdown`, so this path replaces a
/// dedicated renderer — it has to render prose, not highlighted source.
final class CodeMarkdownTests: XCTestCase {

    // MARK: - Analysis

    func testHeadingsCarryTheirLevel() {
        let document = MarkdownAnalyzer.analyze("# One\n\n## Two\n\n### Three")

        XCTAssertEqual(document.blocks.count, 3)
        guard case .heading(let first, let firstRuns) = document.blocks[0],
              case .heading(let second, _) = document.blocks[1],
              case .heading(let third, _) = document.blocks[2] else {
            return XCTFail("expected three headings, got \(document.blocks)")
        }
        XCTAssertEqual([first, second, third], [1, 2, 3])
        XCTAssertEqual(firstRuns.map(\.text).joined(), "One")
    }

    func testInlineRunsCarryEmphasisCodeAndLink() throws {
        let document = MarkdownAnalyzer.analyze("Plain **bold** *italic* `code` [link](https://example.com)")
        guard case .paragraph(let runs) = try XCTUnwrap(document.blocks.first) else {
            return XCTFail("expected a paragraph")
        }

        func run(_ text: String) throws -> MarkdownDocument.InlineRun {
            try XCTUnwrap(runs.first { $0.text == text }, "missing run \(text)")
        }

        XCTAssertTrue(try run("bold").isStrong)
        XCTAssertTrue(try run("italic").isEmphasis)
        XCTAssertTrue(try run("code").isInlineCode)
        XCTAssertTrue(try run("link").isLink)
        XCTAssertFalse(try run("Plain ").isStrong)
    }

    func testListMarkersAndDepth() throws {
        let document = MarkdownAnalyzer.analyze("- a\n- b\n  - nested\n\n1. one\n2. two")

        let items: [(Int, String, String)] = document.blocks.compactMap { block in
            guard case .listItem(let depth, let marker, let runs) = block else { return nil }
            return (depth, marker, runs.map(\.text).joined())
        }

        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items[0].0, 1)
        XCTAssertEqual(items[0].1, "•")
        XCTAssertEqual(items[0].2, "a")
        XCTAssertEqual(items[2].0, 2, "the nested item must be one level deeper")
        XCTAssertEqual(items[3].1, "1.")
        XCTAssertEqual(items[4].1, "2.")
    }

    func testBlockQuoteAndThematicBreak() throws {
        let document = MarkdownAnalyzer.analyze("> quoted\n\n---")

        guard case .blockQuote(let runs) = try XCTUnwrap(document.blocks.first) else {
            return XCTFail("expected a block quote")
        }
        XCTAssertEqual(runs.map(\.text).joined(), "quoted")
        XCTAssertEqual(document.blocks.last, .thematicBreak)
    }

    func testCodeBlockKeepsItsLanguageHintAndContent() throws {
        let document = MarkdownAnalyzer.analyze("```swift\nlet x = 1\n```")

        guard case .codeBlock(let hint, let code) = try XCTUnwrap(document.blocks.first) else {
            return XCTFail("expected a code block")
        }
        XCTAssertEqual(hint, "swift")
        XCTAssertEqual(code, "let x = 1\n")
    }

    func testTableHeaderAndRows() throws {
        let document = MarkdownAnalyzer.analyze("| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |")

        guard case .table(let table) = try XCTUnwrap(document.blocks.first) else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(table.header.map { $0.map(\.text).joined() }, ["A", "B"])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows[1].map { $0.map(\.text).joined() }, ["3", "4"])
    }

    func testPlainTextStillBecomesAParagraph() throws {
        let document = MarkdownAnalyzer.analyze("just words")

        guard case .paragraph(let runs) = try XCTUnwrap(document.blocks.first) else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertEqual(runs.map(\.text).joined(), "just words")
    }

    func testEmptySourceProducesNoBlocks() {
        XCTAssertTrue(MarkdownAnalyzer.analyze("").blocks.isEmpty)
    }

    // MARK: - Table alignment

    func testTableAlignmentUsesDisplayWidth() throws {
        let document = MarkdownAnalyzer.analyze("| A | B |\n| --- | --- |\n| 中文 | x |")
        guard case .table(let table) = try XCTUnwrap(document.blocks.first) else {
            return XCTFail("expected a table")
        }

        let lines = table.alignedLines
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].kind, .header)
        XCTAssertEqual(lines[1].kind, .separator)
        XCTAssertEqual(lines[2].kind, .row)
        // Column 0 is four columns wide because 中文 occupies two each.
        XCTAssertEqual(lines[0].text, "A     B")
        XCTAssertEqual(lines[2].text, "中文  x")
    }

    func testDisplayWidthCountsWideCharactersAsTwo() {
        XCTAssertEqual(MarkdownWidth.displayWidth(of: "abc"), 3)
        XCTAssertEqual(MarkdownWidth.displayWidth(of: "中文"), 4)
        XCTAssertEqual(MarkdownWidth.displayWidth(of: "a中"), 3)
    }

    // MARK: - AppKit rendering

    private func makeDocument(
        _ source: String,
        fileName: String = "README.md",
        theme: CodeThemeSettings = CodeThemeSettings(themeID: "monokai"),
        prefersDark: Bool = true,
        limits: CodePreviewLimits = .default
    ) -> CodePreviewDocument {
        CodePreviewDocumentBuilder.makeDocument(
            source: source,
            fileName: fileName,
            settings: CodePreviewSettings(theme: theme, language: .english),
            prefersDark: prefersDark,
            limits: limits
        )
    }

    func testMarkdownIsRenderedRatherThanHighlighted() {
        let document = makeDocument("# Title\n\nSome **bold** text.")

        XCTAssertEqual(document.language, .markdown)
        XCTAssertEqual(document.fileName, "README.md")
        XCTAssertFalse(document.text.string.contains("#"), "the heading marker must not survive rendering")
        XCTAssertTrue(document.text.string.contains("Title"))
        XCTAssertTrue(document.text.string.contains("Some bold text."))
    }

    func testMarkdownUsesTheThemeBackground() throws {
        let document = makeDocument("# Title")
        assertColor(document.backgroundColor, equals: CodeThemeCatalog.monokai.rgb(for: .background))
    }

    func testHeadingIsLargerThanBodyText() throws {
        let document = makeDocument("# Heading\n\nBody text.")
        let heading = try font(of: "Heading", in: document)
        let body = try font(of: "Body text.", in: document)

        XCTAssertGreaterThan(heading.pointSize, body.pointSize)
    }

    func testStrongRunIsBold() throws {
        let document = makeDocument("Some **bold** text.")
        let font = try font(of: "bold", in: document)

        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testLinkUsesTheFunctionColourAndIsUnderlined() throws {
        let document = makeDocument("[link](https://example.com)")
        let range = try range(of: "link", in: document)

        try assertColor(color(of: "link", in: document), equals: CodeThemeCatalog.monokai.rgb(for: .function))
        XCTAssertNotNil(document.text.attribute(.underlineStyle, at: range.location, effectiveRange: nil))
    }

    func testInlineCodeIsMonospacedAndUsesTheStringColour() throws {
        let document = makeDocument("Use `value` here.")

        XCTAssertTrue(try font(of: "value", in: document).isFixedPitch)
        try assertColor(color(of: "value", in: document), equals: CodeThemeCatalog.monokai.rgb(for: .string))
    }

    func testCodeBlockRunsTheHighlighter() throws {
        let document = makeDocument("```swift\nfunc hello() {}\n```")

        // `func` is a Swift keyword: if the block were plain text it would be the
        // foreground colour instead.
        try assertColor(color(of: "func", in: document), equals: CodeThemeCatalog.monokai.rgb(for: .keyword))
    }

    func testTableHeaderUsesTheKeywordColour() throws {
        // The data cell must not be a substring of the header, or the colour
        // lookup would find the header instead ("a" inside "Name").
        let document = makeDocument("| Name | Value |\n| --- | --- |\n| alpha | 1 |")

        try assertColor(color(of: "Name", in: document), equals: CodeThemeCatalog.monokai.rgb(for: .keyword))
        try assertColor(color(of: "alpha", in: document), equals: CodeThemeCatalog.monokai.rgb(for: .foreground))
    }

    func testMarkdownTruncatesAtTheLineLimit() {
        let document = makeDocument("# A\n# B\n# C\n# D\n# E", limits: CodePreviewLimits(maxLines: 3))

        XCTAssertTrue(document.isTruncated)
        XCTAssertEqual(document.renderedLineCount, 5)
        XCTAssertTrue(document.text.string.contains("C"))
        XCTAssertFalse(document.text.string.contains("E"), "lines past the limit must not be rendered")
    }

    // MARK: - Helpers

    private func range(of text: String, in document: CodePreviewDocument) throws -> NSRange {
        let range = (document.text.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, "\(text) is missing from the rendered document")
        return range
    }

    private func font(of text: String, in document: CodePreviewDocument) throws -> NSFont {
        let range = try range(of: text, in: document)
        return try XCTUnwrap(document.text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
    }

    private func color(of text: String, in document: CodePreviewDocument) throws -> NSColor {
        let range = try range(of: text, in: document)
        return try XCTUnwrap(document.text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
    }

    private func assertColor(
        _ actual: NSColor,
        equals expected: RGBColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let target = NSColor(
            srgbRed: CGFloat(expected.red),
            green: CGFloat(expected.green),
            blue: CGFloat(expected.blue),
            alpha: 1
        )
        guard let lhs = actual.usingColorSpace(.sRGB), let rhs = target.usingColorSpace(.sRGB) else {
            XCTFail("could not convert colours to sRGB", file: file, line: line)
            return
        }
        XCTAssertEqual(lhs.redComponent, rhs.redComponent, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(lhs.greenComponent, rhs.greenComponent, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(lhs.blueComponent, rhs.blueComponent, accuracy: 0.002, file: file, line: line)
    }
}
