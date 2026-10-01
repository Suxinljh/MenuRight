import AppKit
import XCTest

/// Rendering contract of the Quick Look code preview: the App Group settings
/// reader, the file reader (byte cap + encoding fallback), and the attributed
/// text builder that the extension and the settings pane both depend on.
final class CodePreviewDocumentTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "MenuRightTests.codePreview.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    // MARK: - Settings reader

    private struct Payload: Encodable {
        let codeTheme: CodeThemeSettings
        let general: General

        struct General: Encodable {
            let language: String
        }
    }

    private func writePayload(theme: CodeThemeSettings, language: AppLanguage) throws {
        let payload = Payload(codeTheme: theme, general: .init(language: language.rawValue))
        defaults.set(try JSONEncoder().encode(payload), forKey: MenuRightAppGroup.settingsStorageKey)
    }

    func testSettingsLoadReadsThemeAndLanguage() throws {
        let theme = CodeThemeSettings(themeID: "dracula", fontSize: 18, fontName: "Menlo", showsLineNumbers: false)
        try writePayload(theme: theme, language: .english)

        let settings = CodePreviewSettings.load(from: defaults)

        XCTAssertEqual(settings.theme, theme)
        XCTAssertEqual(settings.language, .english)
        XCTAssertEqual(settings.resolvedLanguage, .english)
    }

    func testSettingsLoadUsesDefaultsWithoutAPayload() {
        XCTAssertEqual(CodePreviewSettings.load(from: defaults), .default)
    }

    func testSettingsLoadUsesDefaultsForACorruptPayload() {
        defaults.set(Data("not json".utf8), forKey: MenuRightAppGroup.settingsStorageKey)
        XCTAssertEqual(CodePreviewSettings.load(from: defaults), .default)
    }

    func testSettingsLoadKeepsTheThemeWhenTheLanguageIsUnknown() throws {
        // A language added by a newer build must not invalidate the theme.
        let json: [String: Any] = [
            "codeTheme": ["themeID": "monokai", "fontSize": 16],
            "general": ["language": "ja"],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: MenuRightAppGroup.settingsStorageKey)

        let settings = CodePreviewSettings.load(from: defaults)

        XCTAssertEqual(settings.theme.themeID, "monokai")
        XCTAssertEqual(settings.theme.fontSize, 16)
        XCTAssertEqual(settings.language, .system)
    }

    func testSettingsLoadNormalizesAnOutOfRangeFontSize() throws {
        try writePayload(theme: CodeThemeSettings(themeID: "monokai", fontSize: 999), language: .system)

        XCTAssertEqual(
            CodePreviewSettings.load(from: defaults).theme.fontSize,
            CodeThemeSettings.fontSizeRange.upperBound
        )
    }

    // MARK: - Document builder

    private func makeDocument(
        source: String,
        fileName: String = "Sample.swift",
        theme: CodeThemeSettings = CodeThemeSettings(themeID: "monokai"),
        language: AppLanguage = .english,
        prefersDark: Bool = true,
        limits: CodePreviewLimits = .default
    ) -> CodePreviewDocument {
        CodePreviewDocumentBuilder.makeDocument(
            source: source,
            fileName: fileName,
            settings: CodePreviewSettings(theme: theme, language: language),
            prefersDark: prefersDark,
            limits: limits
        )
    }

    func testDocumentColorsFollowTheSelectedTheme() throws {
        let document = makeDocument(source: "// note\nlet count = 42\nreturn \"hi\"")
        let monokai = CodeThemeCatalog.monokai

        try assertColor(color(of: "// note", in: document), equals: monokai.rgb(for: .comment))
        try assertColor(color(of: "let", in: document), equals: monokai.rgb(for: .keyword))
        try assertColor(color(of: "42", in: document), equals: monokai.rgb(for: .number))
        try assertColor(color(of: "\"hi\"", in: document), equals: monokai.rgb(for: .string))
        assertColor(document.backgroundColor, equals: monokai.rgb(for: .background))
        XCTAssertEqual(document.language, .swift)
        XCTAssertEqual(document.fileName, "Sample.swift")
        XCTAssertFalse(document.isTruncated)
    }

    func testDocumentResolvesTheSystemThemeFromTheAppearance() throws {
        let theme = CodeThemeSettings(themeID: CodeThemeCatalog.systemID)
        let dark = makeDocument(source: "let x = 1", theme: theme, prefersDark: true)
        let light = makeDocument(source: "let x = 1", theme: theme, prefersDark: false)

        assertColor(dark.backgroundColor, equals: CodeThemeCatalog.xcodeDark.rgb(for: .background))
        assertColor(light.backgroundColor, equals: CodeThemeCatalog.xcodeLight.rgb(for: .background))
    }

    func testDocumentWithoutLineNumbersIsExactlyTheSource() {
        let source = "// note\nlet count = 42"
        let document = makeDocument(
            source: source,
            theme: CodeThemeSettings(themeID: "monokai", showsLineNumbers: false)
        )

        XCTAssertEqual(document.text.string, source)
    }

    func testDocumentPrefixesEachLineWithItsNumber() {
        let document = makeDocument(source: "let a = 1\nlet b = 2")

        // Two tabs: the first ends at the right-aligned number column, the second
        // starts the code column (see `CodePreviewDocumentBuilder.paragraphStyle`).
        XCTAssertEqual(document.text.string.components(separatedBy: "\n"), ["1\t\tlet a = 1", "2\t\tlet b = 2"])
        XCTAssertEqual(document.renderedLineCount, 2)
    }

    func testDocumentKeepsBlankLines() {
        let document = makeDocument(
            source: "let a = 1\n\nlet b = 2",
            theme: CodeThemeSettings(themeID: "monokai", showsLineNumbers: false)
        )

        XCTAssertEqual(document.text.string, "let a = 1\n\nlet b = 2")
    }

    func testDocumentTruncatesAtTheLineLimit() {
        let source = (1...10).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let document = makeDocument(source: source, limits: CodePreviewLimits(maxLines: 4))

        XCTAssertTrue(document.isTruncated)
        XCTAssertEqual(document.renderedLineCount, 4)
        XCTAssertEqual(document.text.string.components(separatedBy: "\n").count, 4)
    }

    func testDocumentUsesTheConfiguredFontSize() throws {
        let document = makeDocument(
            source: "let x = 1",
            theme: CodeThemeSettings(themeID: "monokai", fontSize: 21)
        )

        let font = try XCTUnwrap(document.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 21, accuracy: 0.01)
    }

    func testDocumentFallsBackToAMonospacedFontForAnUnknownName() throws {
        let document = makeDocument(
            source: "let x = 1",
            theme: CodeThemeSettings(themeID: "monokai", fontName: "Definitely Not An Installed Font")
        )

        let font = try XCTUnwrap(document.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.isFixedPitch)
    }

    // MARK: - File reader

    func testFileReaderReadsUTF8() throws {
        let url = try temporaryFile(Data("let x = 1\n".utf8))

        let result = try CodePreviewFileReader.read(from: url, maxBytes: 1_000)

        XCTAssertEqual(result.text, "let x = 1\n")
        XCTAssertFalse(result.isByteTruncated)
    }

    func testFileReaderCapsTheBytesItReads() throws {
        let url = try temporaryFile(Data(repeating: 0x61, count: 100))

        let result = try CodePreviewFileReader.read(from: url, maxBytes: 40)

        XCTAssertTrue(result.isByteTruncated)
        XCTAssertEqual(result.text, String(repeating: "a", count: 40))
    }

    func testFileReaderDecodesALegacyChineseSourceFile() throws {
        let source = "// 文档\nlet 名称 = 1\n"
        let data = try XCTUnwrap(source.data(using: CodePreviewFileReader.gb18030))
        let url = try temporaryFile(data)

        XCTAssertEqual(try CodePreviewFileReader.read(from: url, maxBytes: 1_000).text, source)
    }

    func testFileReaderKeepsWesternTextWestern() throws {
        // GB18030 would happily decode these bytes as CJK; the byte-ratio guard
        // is what keeps an accented Western file from turning Chinese.
        let source = "// Übersicht für alle\n"
        let data = try XCTUnwrap(source.data(using: .isoLatin1))
        let url = try temporaryFile(data)

        XCTAssertEqual(try CodePreviewFileReader.read(from: url, maxBytes: 1_000).text, source)
    }

    func testFileReaderThrowsForAMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).swift")

        XCTAssertThrowsError(try CodePreviewFileReader.read(from: url))
    }

    // MARK: - Helpers

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("menuright-preview-\(UUID().uuidString).txt")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Colour of the first run of `text` in the rendered document.
    private func color(of text: String, in document: CodePreviewDocument) throws -> NSColor {
        let range = (document.text.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, "\(text) is missing from the rendered document")
        let value = document.text.attribute(.foregroundColor, at: range.location, effectiveRange: nil)
        return try XCTUnwrap(value as? NSColor)
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
