import XCTest

/// The Finder context menu follows the language selected in 通用设置.
///
/// Two halves: reading the shared setting (the app is the only writer) and
/// rendering/dispatching titles in the resolved language. `FinderSync` cannot be
/// unit-tested — it needs Finder — but everything it uses to build and replay a
/// menu lives in `FinderMenuLanguage` and `FinderMenuTitles`, which can.
final class FinderMenuLocalizationTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "xin.ljhsu.MenuRight.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Reading the shared setting

    func testReadsTheLanguageTheAppWrote() throws {
        try write(payload: #"{"general":{"language":"zh-Hans","launchAtLogin":false}}"#)
        XCTAssertEqual(FinderMenuLanguage.selection(from: defaults), .simplifiedChinese)
        XCTAssertEqual(FinderMenuLanguage.resolve(from: defaults), .simplifiedChinese)

        try write(payload: #"{"general":{"language":"en"}}"#)
        XCTAssertEqual(FinderMenuLanguage.resolve(from: defaults), .english)
    }

    func testFallsBackToTheSystemLanguageWhenThePayloadIsMissingOrUnusable() throws {
        XCTAssertEqual(FinderMenuLanguage.selection(from: defaults), .system, "no payload")

        // A realistic payload: the whole settings tree, which the extension must
        // be able to read without knowing about it.
        try write(payload: #"{"schemaVersion":1,"general":{"language":"zh-Hans","launchAtLogin":false},"newFile":{"types":["text"]},"codeTheme":{"themeID":"xcode-light"}}"#)
        XCTAssertEqual(FinderMenuLanguage.selection(from: defaults), .simplifiedChinese)

        try write(payload: #"{"general":{"launchAtLogin":false}}"#)
        XCTAssertEqual(FinderMenuLanguage.selection(from: defaults), .system, "field absent")

        // A language sitting at the top level is NOT the app's shape; it must be
        // ignored rather than half-read.
        try write(payload: #"{"language":"zh-Hans"}"#)
        XCTAssertEqual(FinderMenuLanguage.selection(from: defaults), .system, "wrong nesting")

        try write(payload: #"{"general":{"language":"fr"}}"#)
        XCTAssertEqual(FinderMenuLanguage.selection(from: defaults), .system, "unknown language")

        try write(payload: "not json at all")
        XCTAssertEqual(FinderMenuLanguage.selection(from: defaults), .system, "corrupt payload")

        defaults.set(Data(), forKey: FinderMenuLanguage.storageKey)
        XCTAssertEqual(FinderMenuLanguage.selection(from: defaults), .system, "empty payload")
    }

    /// `.system` resolves through the system's preferred languages, which is
    /// injectable so the test never depends on the machine's locale.
    func testSystemSelectionResolvesFromPreferredLanguages() throws {
        try write(payload: #"{"general":{"language":"system"}}"#)
        XCTAssertEqual(FinderMenuLanguage.resolve(from: defaults, preferred: ["zh-Hant-TW"]), .simplifiedChinese)
        XCTAssertEqual(FinderMenuLanguage.resolve(from: defaults, preferred: ["en-US"]), .english)
        XCTAssertEqual(FinderMenuLanguage.resolve(from: defaults, preferred: []), .english)

        // No payload at all behaves like `.system`.
        defaults.removeObject(forKey: FinderMenuLanguage.storageKey)
        XCTAssertEqual(FinderMenuLanguage.resolve(from: defaults, preferred: ["zh-Hans-CN"]), .simplifiedChinese)
    }

    /// The extension reads the payload the app writes, so the key must not drift.
    func testStorageKeyMatchesTheAppStore() {
        XCTAssertEqual(FinderMenuLanguage.storageKey, SettingsStore.storageKey)
    }

    // MARK: - Titles

    func testEveryActionHasATitleInBothLanguages() {
        for action in allActions() {
            for language in [AppLanguage.simplifiedChinese, .english] {
                let title = FinderMenuTitles.title(for: action, language: language)
                XCTAssertFalse(title.isEmpty, "\(action) has no \(language.rawValue) title")
            }
        }
    }

    /// Dispatch is by title, so two actions must never render the same string.
    func testTitlesAreUniquePerLanguage() {
        for language in [AppLanguage.simplifiedChinese, .english] {
            let titles = allActions().map { FinderMenuTitles.title(for: $0, language: language) }
            XCTAssertEqual(Set(titles).count, titles.count, "duplicate titles in \(language.rawValue): \(titles)")
        }
    }

    func testSubmenuTitleComesFromTheSharedCatalog() {
        XCTAssertEqual(FinderMenuTitles.submenuTitle(.categoryNewFile, language: .simplifiedChinese), "新建文件")
        XCTAssertEqual(FinderMenuTitles.submenuTitle(.categoryNewFile, language: .english), "New File")
    }

    // MARK: - Replay (title → action)

    func testCopyTitlesRoundTripInBothLanguages() {
        let expect: [(FinderMenuAction, FinderMenuTitles.CopySubject)] = [
            (.copyName(payload: "a.txt"), .names),
            (.copyPath(payload: "/tmp/a.txt"), .paths),
            (.copyFileURL(payload: "file:///tmp/a.txt"), .fileURLs),
            (.copyFolderName(payload: "Folder"), .folderName),
            (.copyFolderPath(payload: "/tmp"), .folderPath),
        ]
        for (action, subject) in expect {
            for language in [AppLanguage.simplifiedChinese, .english] {
                let title = FinderMenuTitles.title(for: action, language: language)
                XCTAssertEqual(
                    FinderMenuTitles.copySubject(forTitle: title),
                    subject,
                    "\(title) should replay as \(subject)"
                )
            }
        }
        XCTAssertNil(FinderMenuTitles.copySubject(forTitle: "Something Else"))
    }

    func testLockAndUnlockTitlesRoundTripInBothLanguages() {
        for language in [AppLanguage.simplifiedChinese, .english] {
            let lock = FinderMenuTitles.title(for: .setLocked(items: [], locked: true), language: language)
            let unlock = FinderMenuTitles.title(for: .setLocked(items: [], locked: false), language: language)
            XCTAssertFalse(FinderMenuTitles.isUnlockTitle(lock))
            XCTAssertTrue(FinderMenuTitles.isUnlockTitle(unlock))
        }
        XCTAssertFalse(FinderMenuTitles.isUnlockTitle("Delete"))
    }

    func testNewFileKindTitlesRoundTripInBothLanguages() {
        for kind in NewFileKind.allCases {
            for language in [AppLanguage.simplifiedChinese, .english] {
                let title = kind.title(in: language)
                XCTAssertEqual(FinderMenuTitles.newFileKind(forTitle: title), kind)
            }
        }
        XCTAssertNil(FinderMenuTitles.newFileKind(forTitle: "Spreadsheet"))
    }

    // MARK: - Helpers

    private func write(payload: String) throws {
        defaults.set(Data(payload.utf8), forKey: FinderMenuLanguage.storageKey)
    }

    private func allActions() -> [FinderMenuAction] {
        let url = URL(fileURLWithPath: "/Users/foo/Projects", isDirectory: true)
        return [
            .createAlias(items: [url]),
            .setLocked(items: [url], locked: true),
            .setLocked(items: [url], locked: false),
            .copyName(payload: "example.png"),
            .copyPath(payload: url.path),
            .copyFileURL(payload: url.absoluteString),
            .cut(items: [url]),
            .openTerminal(directory: url),
            .copyFolderName(payload: "Projects"),
            .copyFolderPath(payload: url.path),
            .newFile(kind: .text, directory: url),
            .newFolder(directory: url),
            .pasteHere(destination: url, enabled: true),
        ]
    }
}
