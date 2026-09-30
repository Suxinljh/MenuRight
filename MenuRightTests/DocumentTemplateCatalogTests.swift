import XCTest

/// P6-b: which “New File” kinds this build can actually create, and the payload
/// that tells the Finder extension about it.
final class DocumentTemplateCatalogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-templates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeTemplate(_ name: String) throws {
        try Data("template".utf8).write(to: directory.appendingPathComponent(name))
    }

    // MARK: - Catalog

    func testOnlyIWorkKindsNeedATemplate() {
        XCTAssertEqual(
            NewFileType.allCases.filter(\.requiresTemplate),
            [.pages, .numbers, .keynote]
        )
        XCTAssertEqual(DocumentTemplateCatalog.templateFileName(for: .pages), "blank.pages")
        XCTAssertEqual(DocumentTemplateCatalog.templateFileName(for: .numbers), "blank.numbers")
        XCTAssertEqual(DocumentTemplateCatalog.templateFileName(for: .keynote), "blank.key")
        XCTAssertNil(DocumentTemplateCatalog.templateFileName(for: .docx))
    }

    func testGeneratedKindsAreAvailableWithoutAnyTemplate() {
        for type in NewFileType.allCases where !type.requiresTemplate {
            XCTAssertTrue(DocumentTemplateCatalog.canCreate(type, in: nil), "\(type.rawValue) is generated, not copied")
        }
    }

    func testMissingTemplatesHideExactlyTheTemplateBackedKinds() {
        XCTAssertEqual(Set(DocumentTemplateCatalog.creatableTypes(in: directory)),
                       Set(NewFileType.allCases).subtracting([.pages, .numbers, .keynote]))
        XCTAssertEqual(DocumentTemplateCatalog.missingTemplateTypes(in: directory), [.pages, .numbers, .keynote])
        XCTAssertNil(DocumentTemplateCatalog.templateURL(for: .pages, in: directory))
    }

    func testAPresentTemplateMakesItsKindCreatable() throws {
        try writeTemplate("blank.pages")
        try writeTemplate("blank.key")

        XCTAssertTrue(DocumentTemplateCatalog.canCreate(.pages, in: directory))
        XCTAssertTrue(DocumentTemplateCatalog.canCreate(.keynote, in: directory))
        XCTAssertFalse(DocumentTemplateCatalog.canCreate(.numbers, in: directory))
        XCTAssertEqual(DocumentTemplateCatalog.missingTemplateTypes(in: directory), [.numbers])
        XCTAssertEqual(
            DocumentTemplateCatalog.templateURL(for: .keynote, in: directory)?.lastPathComponent,
            "blank.key"
        )
    }

    /// An iWork document is usually a *package directory* on disk, and the
    /// catalog must not assume a flat file.
    func testATemplatePackageDirectoryCountsAsPresent() throws {
        let package = directory.appendingPathComponent("blank.numbers", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("index".utf8).write(to: package.appendingPathComponent("Index.zip"))
        XCTAssertTrue(DocumentTemplateCatalog.canCreate(.numbers, in: directory))
    }

    // MARK: - Published availability

    func testPublishWritesThePayloadTheExtensionReads() throws {
        let suiteName = "xin.ljhsu.MenuRight.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try writeTemplate("blank.key")
        _ = DocumentTemplateCatalog.publishAvailability(directory: directory, defaults: defaults)

        let published = try XCTUnwrap(NewFileAvailability.read(from: defaults))
        XCTAssertTrue(published.canCreate(NewFileType.text.rawValue))
        XCTAssertTrue(published.canCreate(NewFileType.docx.rawValue))
        XCTAssertTrue(published.canCreate(NewFileType.keynote.rawValue))
        XCTAssertFalse(published.canCreate(NewFileType.pages.rawValue))
        XCTAssertFalse(published.canCreate(NewFileType.numbers.rawValue))
    }

    func testPublishWithoutAnyDirectoryPublishesTheGeneratedKindsOnly() throws {
        let suiteName = "xin.ljhsu.MenuRight.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = DocumentTemplateCatalog.publishAvailability(directory: nil, defaults: defaults)
        let published = try XCTUnwrap(NewFileAvailability.read(from: defaults))
        XCTAssertEqual(
            Set(published.creatableTypes),
            Set(NewFileType.allCases.filter { !$0.requiresTemplate }.map(\.rawValue))
        )
    }
}
