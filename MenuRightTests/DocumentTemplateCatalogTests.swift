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

    // MARK: - P7: 模板目录可选覆盖

    private func settings(templateDirectoryPath: String) -> NewFileSettings {
        var settings = NewFileSettings()
        settings.templateDirectoryPath = templateDirectoryPath
        settings.templateDirectoryBookmark = Data("bookmark".utf8)
        return settings
    }

    func testOverrideDirectoryNeedsAnExistingFolder() throws {
        XCTAssertNil(DocumentTemplateCatalog.overrideDirectory(for: NewFileSettings()))
        XCTAssertNil(DocumentTemplateCatalog.overrideDirectory(for: settings(templateDirectoryPath: "   ")))
        XCTAssertNil(
            DocumentTemplateCatalog.overrideDirectory(
                for: settings(templateDirectoryPath: directory.appendingPathComponent("missing").path)
            )
        )

        let file = directory.appendingPathComponent("not-a-folder.pages")
        try Data("x".utf8).write(to: file)
        XCTAssertNil(DocumentTemplateCatalog.overrideDirectory(for: settings(templateDirectoryPath: file.path)))

        XCTAssertEqual(
            DocumentTemplateCatalog.overrideDirectory(for: settings(templateDirectoryPath: directory.path)),
            directory
        )
    }

    func testOverrideDirectoryWinsOverTheBundledTemplates() {
        let resolved = DocumentTemplateCatalog.resolvedDirectory(
            for: settings(templateDirectoryPath: directory.path),
            bundle: .main
        )
        XCTAssertEqual(resolved, directory)
    }

    func testUnusableOverrideFallsBackToTheBundledTemplatesAndIsReportedBroken() {
        let broken = settings(templateDirectoryPath: directory.appendingPathComponent("gone").path)

        XCTAssertTrue(DocumentTemplateCatalog.hasBrokenOverride(for: broken))
        XCTAssertEqual(
            DocumentTemplateCatalog.resolvedDirectory(for: broken, bundle: .main),
            DocumentTemplateCatalog.resolvedDirectory(for: NewFileSettings(), bundle: .main)
        )
        XCTAssertFalse(DocumentTemplateCatalog.hasBrokenOverride(for: NewFileSettings()))
        XCTAssertFalse(
            DocumentTemplateCatalog.hasBrokenOverride(for: settings(templateDirectoryPath: directory.path))
        )
    }

    /// The settings-aware publish reports what the *override* folder carries, so
    /// a folder without blank.numbers hides that kind in Finder.
    func testPublishFromSettingsUsesTheOverrideFolder() throws {
        let suiteName = "xin.ljhsu.MenuRight.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try writeTemplate("blank.key")
        _ = DocumentTemplateCatalog.publishAvailability(
            settings: settings(templateDirectoryPath: directory.path),
            bundle: .main,
            defaults: defaults
        )

        let published = try XCTUnwrap(NewFileAvailability.read(from: defaults))
        XCTAssertTrue(published.canCreate(NewFileType.keynote.rawValue))
        XCTAssertFalse(published.canCreate(NewFileType.pages.rawValue))
        XCTAssertFalse(published.canCreate(NewFileType.numbers.rawValue))
    }

    /// A broken override must not make every iWork kind vanish: the bundled
    /// copies are still there, so the publish falls back to them.
    func testPublishFromSettingsFallsBackWhenTheOverrideIsGone() throws {
        let suiteName = "xin.ljhsu.MenuRight.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = DocumentTemplateCatalog.publishAvailability(
            settings: settings(templateDirectoryPath: directory.appendingPathComponent("gone").path),
            bundle: .main,
            defaults: defaults
        )

        let published = try XCTUnwrap(NewFileAvailability.read(from: defaults))
        // The test bundle has no Templates folder, so only the generated kinds
        // remain — but the point is that it equals the bundled-directory answer
        // rather than "everything missing because the override died".
        let expected = DocumentTemplateCatalog.publishAvailability(
            directory: DocumentTemplateCatalog.resolvedDirectory(for: NewFileSettings(), bundle: .main),
            defaults: defaults
        )
        XCTAssertEqual(Set(published.creatableTypes), Set(expected.creatableTypes))
    }

    // MARK: - 模板目录：书签是能力，路径只是字符串

    /// The bookmark is the capability that lets a sandboxed build back into the
    /// folder after a relaunch; the stored path is only a string for the UI. So a
    /// settings object whose *path* no longer matches must still resolve through
    /// the bookmark — otherwise the override silently dies on every restart.
    func testTheOverrideFolderComesFromTheBookmarkAndNotFromTheStoredPath() throws {
        let bookmark = try SecurityScopedBookmark.create(for: directory)
        var settings = NewFileSettings()
        settings.templateDirectoryPath = directory.appendingPathComponent("moved-away").path
        settings.templateDirectoryBookmark = bookmark

        // Asserting the *resolution* below only means something when the OS
        // accepts the bookmark here; a test host that cannot resolve
        // security-scoped data would otherwise report a false regression.
        guard case .success = SecurityScopedBookmark.resolve(bookmark) else {
            throw XCTSkip("this test host cannot resolve a security-scoped bookmark")
        }

        let resolved = try XCTUnwrap(DocumentTemplateCatalog.overrideDirectory(for: settings))
        // `temporaryDirectory` is /var/... while a bookmark resolves to the
        // canonical /private/var/..., so compare the resolved filesystem paths.
        XCTAssertEqual(
            resolved.resolvingSymlinksInPath().path,
            directory.resolvingSymlinksInPath().path,
            "the bookmark decides where the override folder is, not the stored path"
        )
        XCTAssertFalse(DocumentTemplateCatalog.hasBrokenOverride(for: settings))
    }

    /// A bookmark that cannot be resolved must not lose the folder the user
    /// picked: the path is the fallback, and `settings(templateDirectoryPath:)`
    /// stores exactly that situation (unresolvable bookmark bytes + a real path).
    func testAnUnresolvableBookmarkFallsBackToTheStoredPath() {
        let usable = settings(templateDirectoryPath: directory.path)

        XCTAssertEqual(DocumentTemplateCatalog.resolveOverride(for: usable)?.path, directory.path)
        XCTAssertEqual(DocumentTemplateCatalog.overrideDirectory(for: usable), directory)
        XCTAssertFalse(DocumentTemplateCatalog.hasBrokenOverride(for: usable))
    }

    /// `withOverrideDirectory` is what the dispatcher copies through, so the body
    /// must not run at all when the override is unusable — that is how the caller
    /// knows to fall back to the bundled templates.
    func testWithOverrideDirectoryOnlyRunsTheBodyForAUsableFolder() {
        var ran = false
        let unusable = settings(templateDirectoryPath: directory.appendingPathComponent("gone").path)
        let skipped = DocumentTemplateCatalog.withOverrideDirectory(for: unusable) { url -> String in
            ran = true
            return url.path
        }
        XCTAssertNil(skipped)
        XCTAssertFalse(ran, "an unusable override must fall through to the bundled templates")

        let seen = DocumentTemplateCatalog.withOverrideDirectory(
            for: settings(templateDirectoryPath: directory.path)
        ) { $0.path }
        XCTAssertEqual(seen, directory.path)
    }
}
