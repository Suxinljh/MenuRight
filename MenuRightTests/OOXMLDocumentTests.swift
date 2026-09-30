import XCTest

/// P6-b: the generated Word/Excel/PowerPoint packages.
///
/// These tests pin the parts that make the difference between "Word opens it"
/// and "Word offers to repair it": the entry list and order, one content type
/// per part, resolvable relationship targets, and well-formed XML. They cannot
/// prove a real application opens the file — that stays on the manual gate —
/// but they do prove every structural rule the format imposes.
final class OOXMLDocumentTests: XCTestCase {

    private func parts(of type: NewFileType) throws -> ZipTestReader {
        try ZipTestReader(try OOXMLDocumentFactory.data(for: type))
    }

    private func xmlParts(_ reader: ZipTestReader) throws -> [(name: String, document: XMLDocument)] {
        try reader.entries
            .filter { $0.name.hasSuffix(".xml") || $0.name.hasSuffix(".rels") }
            .map { ($0.name, try XMLDocument(data: $0.data)) }
    }

    // MARK: - Shared structure

    func testEveryOfficeKindIsANonEmptyZipStartingWithContentTypes() throws {
        for type in [NewFileType.docx, .xlsx, .pptx] {
            let data = try OOXMLDocumentFactory.data(for: type)
            XCTAssertGreaterThan(data.count, 500, "\(type.rawValue) looks truncated")
            let reader = try ZipTestReader(data)
            XCTAssertEqual(reader.entries.first?.name, "[Content_Types].xml", "\(type.rawValue) must start with the content types part")
            XCTAssertNotNil(reader.text(named: "_rels/.rels"), "\(type.rawValue) must declare the package relationship")
        }
    }

    func testEveryPartIsWellFormedXML() throws {
        for type in [NewFileType.docx, .xlsx, .pptx] {
            let reader = try parts(of: type)
            let parsed = try xmlParts(reader)
            XCTAssertEqual(parsed.count, reader.entries.count, "\(type.rawValue) has a non-XML part")
        }
    }

    /// Every part must have a content type (Default extension or Override), or
    /// OOXML consumers refuse to open the package.
    func testEveryPartHasAContentType() throws {
        for type in [NewFileType.docx, .xlsx, .pptx] {
            let reader = try parts(of: type)
            let contentTypes = try XMLDocument(data: XCTUnwrap(reader.entry(named: "[Content_Types].xml")).data)

            var defaultExtensions = Set<String>()
            var overriddenParts = Set<String>()
            for child in contentTypes.rootElement()?.children ?? [] {
                switch child.localName {
                case "Default":
                    if let value = attribute(of: child, "Extension") { defaultExtensions.insert(value) }
                case "Override":
                    if let value = attribute(of: child, "PartName") { overriddenParts.insert(value) }
                default:
                    break
                }
            }

            for entry in reader.entries where entry.name != "[Content_Types].xml" {
                let extensionName = String(entry.name.split(separator: ".").last ?? "")
                XCTAssertTrue(
                    overriddenParts.contains("/" + entry.name) || defaultExtensions.contains(extensionName),
                    "\(type.rawValue): \(entry.name) has no content type"
                )
            }
        }
    }

    /// Every relationship a `_rels` part declares must point at a part that is
    /// actually in the archive.
    func testEveryRelationshipTargetExists() throws {
        for type in [NewFileType.docx, .xlsx, .pptx] {
            let reader = try parts(of: type)
            let names = Set(reader.entries.map(\.name))

            for entry in reader.entries where entry.name.hasSuffix(".rels") {
                let base = entry.name.components(separatedBy: "_rels/").first ?? ""
                let document = try XMLDocument(data: entry.data)
                for relationship in document.rootElement()?.children ?? [] where relationship.localName == "Relationship" {
                    let target = try XCTUnwrap(attribute(of: relationship, "Target"))
                    guard !target.hasPrefix("http") else { continue }   // external hyperlink
                    XCTAssertTrue(
                        names.contains(Self.resolve(target, relativeTo: base)),
                        "\(type.rawValue): \(entry.name) → \(target) is missing from the package"
                    )
                }
            }
        }
    }

    func testOnlyOfficeKindsAreGenerated() throws {
        for type in [NewFileType.text, .markdown, .html, .css, .javascript, .json, .pages, .numbers, .keynote] {
            XCTAssertThrowsError(try OOXMLDocumentFactory.data(for: type)) { error in
                XCTAssertEqual(error as? DocumentGenerationError, .unsupportedKind(type.rawValue))
            }
        }
    }

    // MARK: - Word

    func testWordPackageParts() throws {
        let reader = try parts(of: .docx)
        XCTAssertEqual(reader.entries.map(\.name), [
            "[Content_Types].xml",
            "_rels/.rels",
            "word/document.xml",
            "word/_rels/document.xml.rels",
            "word/styles.xml",
        ])
    }

    func testWordDocumentIsOneEmptyParagraphWithASection() throws {
        let document = try XCTUnwrap(try parts(of: .docx).text(named: "word/document.xml"))
        XCTAssertTrue(document.contains("<w:body>"))
        XCTAssertTrue(document.contains("<w:p/>"), "a blank document is exactly one empty paragraph")
        XCTAssertTrue(document.contains("<w:sectPr>"), "section properties are required by Pages")
        XCTAssertTrue(document.contains("w:pgSz"), "the page size must be explicit")
        XCTAssertFalse(document.contains("wordprocessingml.document.main+xml"), "the main content type belongs in the content-types part")
    }

    func testWordContentTypesDeclareTheMainDocumentPart() throws {
        let contentTypes = try XCTUnwrap(try parts(of: .docx).text(named: "[Content_Types].xml"))
        XCTAssertTrue(contentTypes.contains("/word/document.xml"))
        XCTAssertTrue(contentTypes.contains("wordprocessingml.document.main+xml"))
    }

    // MARK: - Excel

    func testExcelPackageParts() throws {
        let reader = try parts(of: .xlsx)
        XCTAssertEqual(reader.entries.map(\.name), [
            "[Content_Types].xml",
            "_rels/.rels",
            "xl/workbook.xml",
            "xl/_rels/workbook.xml.rels",
            "xl/worksheets/sheet1.xml",
            "xl/styles.xml",
        ])
    }

    func testExcelWorkbookHasOneSheetWiredToTheWorksheet() throws {
        let reader = try parts(of: .xlsx)
        let workbook = try XCTUnwrap(reader.text(named: "xl/workbook.xml"))
        XCTAssertTrue(workbook.contains("name=\"Sheet1\""))
        XCTAssertTrue(workbook.contains("r:id=\"rId1\""))

        let sheet = try XCTUnwrap(reader.text(named: "xl/worksheets/sheet1.xml"))
        XCTAssertTrue(sheet.contains("<sheetData/>"), "a blank sheet has no rows")

        let relationships = try XCTUnwrap(reader.text(named: "xl/_rels/workbook.xml.rels"))
        XCTAssertTrue(relationships.contains("worksheets/sheet1.xml"))
        XCTAssertTrue(relationships.contains("styles.xml"), "Excel repairs a workbook without a styles relationship")
    }

    func testExcelStylesHaveTheReservedSecondFill() throws {
        let styles = try XCTUnwrap(try parts(of: .xlsx).text(named: "xl/styles.xml"))
        XCTAssertTrue(styles.contains("<fills count=\"2\">"))
        XCTAssertTrue(styles.contains("gray125"), "cell fill index 1 must stay the reserved gray125")
    }

    /// The workbook has no theme part, so a theme colour reference in the styles
    /// would be unresolvable — Excel treats that as damage and offers a repair.
    func testExcelStylesUseLiteralColoursNotThemeReferences() throws {
        let styles = try XCTUnwrap(try parts(of: .xlsx).text(named: "xl/styles.xml"))
        XCTAssertFalse(styles.contains("theme=\""), "no theme part exists to resolve a theme colour")
        XCTAssertFalse(styles.contains("<scheme val="))
        XCTAssertTrue(styles.contains("<color rgb=\"FF000000\"/>"))
    }

    // MARK: - PowerPoint

    func testPowerPointPackageParts() throws {
        let reader = try parts(of: .pptx)
        XCTAssertEqual(reader.entries.map(\.name), [
            "[Content_Types].xml",
            "_rels/.rels",
            "ppt/presentation.xml",
            "ppt/_rels/presentation.xml.rels",
            "ppt/slideMasters/slideMaster1.xml",
            "ppt/slideMasters/_rels/slideMaster1.xml.rels",
            "ppt/slideLayouts/slideLayout1.xml",
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
            "ppt/slides/slide1.xml",
            "ppt/slides/_rels/slide1.xml.rels",
            "ppt/theme/theme1.xml",
        ])
    }

    func testPowerPointPresentationIsOneSixteenByNineSlide() throws {
        let reader = try parts(of: .pptx)
        let presentation = try XCTUnwrap(reader.text(named: "ppt/presentation.xml"))
        XCTAssertTrue(presentation.contains("type=\"screen16x9\""))
        XCTAssertTrue(presentation.contains("cx=\"12192000\""))
        XCTAssertTrue(presentation.contains("cy=\"6858000\""))
        XCTAssertTrue(presentation.contains("r:id=\"rId2\""), "the first slide must be declared")
        XCTAssertTrue(presentation.contains("<p:notesSz"), "notesSz is required even with no notes")

        let slide = try XCTUnwrap(reader.text(named: "ppt/slides/slide1.xml"))
        XCTAssertTrue(slide.contains("<a:masterClrMapping/>"))
        XCTAssertTrue(slide.contains("<p:spTree>"), "even a blank slide needs an empty shape tree")

        let layout = try XCTUnwrap(reader.text(named: "ppt/slideLayouts/slideLayout1.xml"))
        XCTAssertTrue(layout.contains("type=\"blank\""))
    }

    func testPowerPointSlideMasterMapsEveryThemeSlot() throws {
        let master = try XCTUnwrap(try parts(of: .pptx).text(named: "ppt/slideMasters/slideMaster1.xml"))
        for attribute in ["bg1=\"lt1\"", "tx1=\"dk1\"", "bg2=\"lt2\"", "tx2=\"dk2\"",
                          "accent1=\"accent1\"", "accent6=\"accent6\"",
                          "hlink=\"hlink\"", "folHlink=\"folHlink\""] {
            XCTAssertTrue(master.contains(attribute), "clrMap is missing \(attribute)")
        }
        XCTAssertFalse(master.contains("slideLayouts/slideLayout1.xml"), "the layout target belongs in the rels part")
        XCTAssertTrue(master.contains("<p:txStyles>"), "txStyles is required on a master")
    }

    /// A master with no `p:bg` renders the slide **grey** while passing every
    /// structural check — caught by rendering, not by reading. The background
    /// must also be the first child of `p:cSld`.
    func testPowerPointSlideMasterDeclaresTheBackgroundFirst() throws {
        let master = try XCTUnwrap(try parts(of: .pptx).text(named: "ppt/slideMasters/slideMaster1.xml"))
        let background = try XCTUnwrap(master.range(of: "<p:bg>"))
        let shapeTree = try XCTUnwrap(master.range(of: "<p:spTree>"))
        XCTAssertLessThan(background.lowerBound, shapeTree.lowerBound, "p:bg must precede p:spTree")
        XCTAssertTrue(master.contains("<a:schemeClr val=\"bg1\"/>"), "the background must resolve to the theme's light colour")
    }

    /// The DrawingML theme schema requires at least three entries in each format
    /// list; short lists are what makes PowerPoint "repair" a hand-built deck.
    func testThemeFormatSchemeHasTheRequiredMinimumLists() throws {
        let theme = try XMLDocument(data: XCTUnwrap(try parts(of: .pptx).entry(named: "ppt/theme/theme1.xml")).data)
        let themeElements = try XCTUnwrap(theme.rootElement()?.children?.first { $0.localName == "themeElements" })
        let formatScheme = try XCTUnwrap(themeElements.children?.first { $0.localName == "fmtScheme" })
        let clauseScheme = try XCTUnwrap(themeElements.children?.first { $0.localName == "clrScheme" })

        XCTAssertEqual(clauseScheme.children?.count, 12, "a colour scheme is exactly 12 slots")

        for listName in ["fillStyleLst", "lnStyleLst", "effectStyleLst", "bgFillStyleLst"] {
            let list = try XCTUnwrap(formatScheme.children?.first { $0.localName == listName }, "missing \(listName)")
            XCTAssertGreaterThanOrEqual(list.children?.count ?? 0, 3, "\(listName) needs at least three entries")
        }
    }

    // MARK: - Helpers

    /// Attribute lookup that tolerates `XMLNode` (children are not statically
    /// typed as `XMLElement`).
    private func attribute(of node: XMLNode, _ name: String) -> String? {
        (node as? XMLElement)?.attribute(forName: name)?.stringValue
    }

    /// Resolves a relationship target against the directory of the declaring
    /// part, the way a package reader does.
    private static func resolve(_ target: String, relativeTo base: String) -> String {
        var components = base.split(separator: "/").map(String.init)
        for component in target.split(separator: "/").map(String.init) {
            switch component {
            case "", ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return components.joined(separator: "/")
    }
}
