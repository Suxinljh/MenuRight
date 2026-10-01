import XCTest

/// The one highlighter that backs the settings preview today and the Quick Look
/// extension in P8. The tests pin the parts that both surfaces depend on:
/// language detection, the lossless line model, and a representative token per
/// language family.
final class CodeHighlightTests: XCTestCase {

    // MARK: - Helpers

    private func highlight(_ source: String, _ language: CodeLanguage) -> [CodeHighlightedLine] {
        CodeHighlighter.highlight(source, language: language)
    }

    private func token(_ text: String, in line: CodeHighlightedLine) -> CodeHighlightToken? {
        line.tokens.first { $0.text == text }
    }

    /// Adjacent runs of the same kind are merged, so a plain identifier can end
    /// up inside a larger foreground token ("name=", ">Hello"). Assert on the
    /// kind of the run that contains the text instead of on an exact match.
    private func contains(_ text: String, kind: CodeThemeToken, in line: CodeHighlightedLine) -> Bool {
        line.tokens.contains { $0.kind == kind && $0.text.contains(text) }
    }

    private func allTokens(_ language: CodeLanguage) -> [CodeHighlightToken] {
        highlight(CodePreviewSamples.source(for: language), language).flatMap(\.tokens)
    }

    // MARK: - Detection

    func testDetectionByExtension() {
        XCTAssertEqual(CodeLanguage.detect(fileExtension: "swift"), .swift)
        XCTAssertEqual(CodeLanguage.detect(fileExtension: ".SWIFT"), .swift)
        XCTAssertEqual(CodeLanguage.detect(fileExtension: "Md"), .markdown)
        XCTAssertEqual(CodeLanguage.detect(fileExtension: "tsx"), .typescript)
        XCTAssertEqual(CodeLanguage.detect(fileExtension: "hpp"), .cpp)
        XCTAssertEqual(CodeLanguage.detect(fileExtension: "yml"), .yaml)
        XCTAssertEqual(CodeLanguage.detect(fileExtension: "unknown"), .plainText)
        XCTAssertEqual(CodeLanguage.detect(fileExtension: ""), .plainText)
    }

    func testDetectionByFileName() {
        XCTAssertEqual(CodeLanguage.detect(fileName: "Makefile"), .shell)
        XCTAssertEqual(CodeLanguage.detect(fileName: "Dockerfile"), .shell)
        XCTAssertEqual(CodeLanguage.detect(fileName: "CMakeLists.txt"), .cpp)
        XCTAssertEqual(CodeLanguage.detect(fileName: "/tmp/dir/Greeting.Swift"), .swift)
        XCTAssertEqual(CodeLanguage.detect(fileName: ".zshrc"), .shell)
        XCTAssertEqual(CodeLanguage.detect(fileName: "README"), .plainText)
    }

    func testDetectionByTypeIdentifier() {
        XCTAssertEqual(CodeLanguage.detect(contentTypeIdentifier: "public.swift-source"), .swift)
        XCTAssertEqual(CodeLanguage.detect(contentTypeIdentifier: "public.python-script"), .python)
        XCTAssertEqual(CodeLanguage.detect(contentTypeIdentifier: "net.daringfireball.markdown"), .markdown)
        XCTAssertNil(CodeLanguage.detect(contentTypeIdentifier: "public.png"))
    }

    func testExtensionWinsAndTypeIdentifierIsTheFallback() {
        XCTAssertEqual(
            CodeLanguage.detect(fileName: "main.swift", contentTypeIdentifier: "public.json"),
            .swift
        )
        XCTAssertEqual(
            CodeLanguage.detect(fileName: "script.unknownext", contentTypeIdentifier: "public.python-script"),
            .python
        )
        XCTAssertEqual(
            CodeLanguage.detect(fileName: "photo.unknownext", contentTypeIdentifier: "public.png"),
            .plainText
        )
    }

    // MARK: - Catalog and samples

    func testEveryLanguageHasASampleAndAFilenameThatDetectsBack() {
        for language in CodeLanguage.allCases {
            let source = CodePreviewSamples.source(for: language)
            let name = CodePreviewSamples.fileName(for: language)
            XCTAssertFalse(source.isEmpty, "\(language.rawValue) has no sample")
            XCTAssertFalse(name.isEmpty, "\(language.rawValue) has no sample file name")
            XCTAssertEqual(
                CodeLanguage.detect(fileName: name),
                language,
                "\(name) should detect as \(language.rawValue)"
            )
        }
    }

    func testEveryLanguageIsSupported() {
        for language in CodeLanguage.allCases {
            XCTAssertTrue(CodeHighlighter.supports(language), "\(language.rawValue) has no profile")
        }
    }

    /// The invariant the preview relies on: highlighting may colour the wrong
    /// run, but it must never drop, add or reorder a character.
    func testHighlightingIsLosslessForEveryLanguage() {
        for language in CodeLanguage.allCases {
            let source = CodePreviewSamples.source(for: language)
            let expected = CodeHighlighter.splitLines(source)
            let lines = highlight(source, language)

            XCTAssertEqual(lines.count, expected.count, "\(language.rawValue) line count")
            for (index, line) in lines.enumerated() where index < expected.count {
                XCTAssertEqual(line.text, expected[index], "\(language.rawValue) line \(index + 1)")
            }
        }
    }

    func testSplitLinesNormalizesLineEndingsAndDropsOneTrailingLine() {
        XCTAssertEqual(CodeHighlighter.splitLines("a\r\nb\rc"), ["a", "b", "c"])
        XCTAssertEqual(CodeHighlighter.splitLines("a\n"), ["a"])
        XCTAssertEqual(CodeHighlighter.splitLines("a\n\n"), ["a", ""])
        XCTAssertEqual(CodeHighlighter.splitLines(""), [""])
    }

    func testHighlighterNeverEmitsBackground() {
        for language in CodeLanguage.allCases {
            let kinds = Set(allTokens(language).map(\.kind))
            XCTAssertFalse(kinds.contains(.background), "\(language.rawValue) emitted a background token")
        }
    }

    // MARK: - Swift / generic scanner

    func testSwiftSampleUsesEveryThemeTokenKind() {
        let used = Set(allTokens(.swift).map(\.kind))
        XCTAssertEqual(
            used,
            Set([.foreground, .comment, .keyword, .type, .function, .string, .number])
        )
    }

    func testSwiftTokens() {
        let source = """
        // note
        struct Greeting {
            let count: Int = 42
            func hello(name: String) -> String {
                return "Hello, \\(name)!"
            }
        }
        """
        let lines = highlight(source, .swift)

        XCTAssertEqual(lines[0].tokens, [CodeHighlightToken(text: "// note", kind: .comment)])
        XCTAssertEqual(token("struct", in: lines[1])?.kind, .keyword)
        XCTAssertEqual(token("Greeting", in: lines[1])?.kind, .type)
        XCTAssertEqual(token("Int", in: lines[2])?.kind, .type)
        XCTAssertEqual(token("42", in: lines[2])?.kind, .number)
        XCTAssertEqual(token("hello", in: lines[3])?.kind, .function)
        XCTAssertEqual(token("\"Hello, \\(name)!\"", in: lines[4])?.kind, .string)
    }

    func testBlockCommentSpansLines() {
        let lines = highlight("/* one\n two */\nlet x = 1", .swift)

        XCTAssertEqual(lines[0].tokens, [CodeHighlightToken(text: "/* one", kind: .comment)])
        XCTAssertEqual(lines[1].tokens, [CodeHighlightToken(text: " two */", kind: .comment)])
        XCTAssertEqual(token("let", in: lines[2])?.kind, .keyword)
    }

    func testSwiftRangeIsNotSwallowedByTheNumberScanner() {
        let line = highlight("let range = 1...5", .swift)[0]

        XCTAssertEqual(token("1", in: line)?.kind, .number)
        XCTAssertEqual(token("...", in: line)?.kind, .foreground)
        XCTAssertEqual(token("5", in: line)?.kind, .number)
    }

    func testNumbersCoverHexAndFractionalForms() {
        let line = highlight("let a = 0xFF; let b = 3.14; let c = 1_000", .swift)[0]

        XCTAssertEqual(token("0xFF", in: line)?.kind, .number)
        XCTAssertEqual(token("3.14", in: line)?.kind, .number)
        XCTAssertEqual(token("1_000", in: line)?.kind, .number)
    }

    // MARK: - Python

    func testPythonCommentsAndTripleQuotedStringsSpanLines() {
        let source = "text = \"\"\"\nhello\n\"\"\"\nprint(text)  # note"
        let lines = highlight(source, .python)

        XCTAssertEqual(lines[0].tokens.last, CodeHighlightToken(text: "\"\"\"", kind: .string))
        XCTAssertEqual(lines[1].tokens, [CodeHighlightToken(text: "hello", kind: .string)])
        XCTAssertEqual(lines[2].tokens, [CodeHighlightToken(text: "\"\"\"", kind: .string)])
        XCTAssertEqual(token("print", in: lines[3])?.kind, .function)
        XCTAssertEqual(lines[3].tokens.last?.kind, .comment)
    }

    // MARK: - JavaScript / TypeScript

    func testJavaScriptTemplateLiteralSpansLines() {
        let lines = highlight("const s = `Hello\nworld`;", .javascript)

        XCTAssertEqual(lines[0].tokens.last, CodeHighlightToken(text: "`Hello", kind: .string))
        XCTAssertEqual(lines[1].tokens.first, CodeHighlightToken(text: "world`", kind: .string))
        XCTAssertEqual(token("const", in: lines[0])?.kind, .keyword)
    }

    func testTypeScriptKeywords() {
        let line = highlight("interface Greeting { name: string }", .typescript)[0]

        XCTAssertEqual(token("interface", in: line)?.kind, .keyword)
        XCTAssertEqual(token("Greeting", in: line)?.kind, .type)
        XCTAssertEqual(token("string", in: line)?.kind, .type)
    }

    // MARK: - HTML / Markdown

    func testMarkupTagsAttributesAndComments() {
        let lines = highlight("<!-- note -->\n<h1 class=\"title\">Hello</h1>", .html)

        XCTAssertEqual(lines[0].tokens, [CodeHighlightToken(text: "<!-- note -->", kind: .comment)])
        XCTAssertEqual(token("h1", in: lines[1])?.kind, .keyword)
        XCTAssertEqual(token("class", in: lines[1])?.kind, .type)
        XCTAssertEqual(token("\"title\"", in: lines[1])?.kind, .string)
        XCTAssertTrue(contains("Hello", kind: .foreground, in: lines[1]))
    }

    func testMarkdownHeadingsListsCodeAndLinks() {
        let source = "# Title\n\n- `space` opens it\n\n[Doc](https://example.com)\n\n**bold**"
        let lines = highlight(source, .markdown)

        XCTAssertEqual(lines[0].tokens, [CodeHighlightToken(text: "# Title", kind: .keyword)])
        XCTAssertEqual(token("- ", in: lines[2])?.kind, .keyword)
        XCTAssertEqual(token("`space`", in: lines[2])?.kind, .string)
        XCTAssertEqual(token("[Doc]", in: lines[4])?.kind, .function)
        XCTAssertEqual(token("(https://example.com)", in: lines[4])?.kind, .type)
        XCTAssertEqual(token("**bold**", in: lines[6])?.kind, .function)
    }

    func testMarkdownFencedCodeIsStringContent() {
        let lines = highlight("```swift\nlet x = 1\n```", .markdown)

        XCTAssertEqual(lines[0].tokens, [CodeHighlightToken(text: "```swift", kind: .keyword)])
        XCTAssertEqual(lines[1].tokens, [CodeHighlightToken(text: "let x = 1", kind: .string)])
        XCTAssertEqual(lines[2].tokens, [CodeHighlightToken(text: "```", kind: .keyword)])
    }

    // MARK: - Data and config formats

    func testJSONKeysAreTypesAndValuesKeepTheirKind() {
        let line = highlight("{ \"name\": \"MenuRight\", \"version\": 2, \"enabled\": true }", .json)[0]

        XCTAssertEqual(token("\"name\"", in: line)?.kind, .type)
        XCTAssertEqual(token("\"MenuRight\"", in: line)?.kind, .string)
        XCTAssertEqual(token("\"version\"", in: line)?.kind, .type)
        XCTAssertEqual(token("2", in: line)?.kind, .number)
        XCTAssertEqual(token("true", in: line)?.kind, .keyword)
    }

    func testYAMLKeysCommentsAndBooleans() {
        let lines = highlight("# note\nname: MenuRight\nenabled: true", .yaml)

        XCTAssertEqual(lines[0].tokens, [CodeHighlightToken(text: "# note", kind: .comment)])
        XCTAssertEqual(token("name", in: lines[1])?.kind, .type)
        XCTAssertEqual(token("true", in: lines[2])?.kind, .keyword)
    }

    func testCSSAtRulesPropertiesAndHexColors() {
        let lines = highlight("@media screen {\n  --accent: #3b82f6;\n  font-size: 24px;\n}", .css)

        XCTAssertEqual(token("media", in: lines[0])?.kind, .keyword)
        XCTAssertEqual(token("--accent", in: lines[1])?.kind, .type)
        XCTAssertEqual(token("#3b82f6", in: lines[1])?.kind, .number)
        XCTAssertEqual(token("font-size", in: lines[2])?.kind, .type)
        XCTAssertEqual(token("24", in: lines[2])?.kind, .number)
    }

    func testSQLKeywordsAreCaseInsensitive() {
        let upper = highlight("SELECT id FROM users WHERE active = true", .sql)[0]
        let lower = highlight("select id from users where active = true", .sql)[0]

        XCTAssertEqual(token("SELECT", in: upper)?.kind, .keyword)
        XCTAssertEqual(token("select", in: lower)?.kind, .keyword)
        XCTAssertEqual(token("FROM", in: upper)?.kind, .keyword)
        XCTAssertTrue(contains("id", kind: .foreground, in: upper))
        XCTAssertEqual(token("true", in: upper)?.kind, .keyword)
    }

    func testShellShebangCommentVariableAndString() {
        let lines = highlight("#!/bin/bash\nname=\"world\"\necho $HOME", .shell)

        XCTAssertEqual(lines[0].tokens, [CodeHighlightToken(text: "#!/bin/bash", kind: .comment)])
        XCTAssertTrue(contains("name", kind: .foreground, in: lines[1]))
        XCTAssertEqual(token("\"world\"", in: lines[1])?.kind, .string)
        XCTAssertEqual(token("echo", in: lines[2])?.kind, .keyword)
        XCTAssertEqual(token("$HOME", in: lines[2])?.kind, .type)
    }

    // MARK: - Remaining languages

    func testCRustGoJavaSamplesProduceKeywordsAndTypes() {
        let expectations: [CodeLanguage: (keyword: String, type: String, function: String)] = [
            .c: ("const", "int", "main"),
            .cpp: ("class", "std", "hello"),
            .go: ("func", "int", "main"),
            .rust: ("fn", "u32", "hello"),
            .java: ("class", "String", "hello"),
        ]

        for (language, expected) in expectations {
            let tokens = allTokens(language)
            let kinds = { (text: String) in tokens.first { $0.text == text }?.kind }

            XCTAssertEqual(kinds(expected.keyword), .keyword, "\(language.rawValue) keyword")
            XCTAssertEqual(kinds(expected.type), .type, "\(language.rawValue) type")
            XCTAssertEqual(kinds(expected.function), .function, "\(language.rawValue) function")
        }
    }

    // MARK: - Plain text

    func testPlainTextKeepsEveryLine() {
        let lines = highlight("hello\n\nworld", .plainText)

        XCTAssertEqual(lines[0].tokens, [CodeHighlightToken(text: "hello", kind: .foreground)])
        XCTAssertTrue(lines[1].tokens.isEmpty)
        XCTAssertEqual(lines[2].tokens, [CodeHighlightToken(text: "world", kind: .foreground)])
    }
}
