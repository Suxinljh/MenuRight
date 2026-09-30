import XCTest

/// P6-b: the App-Group payload that tells the Finder extension which document
/// kinds the running main app can create.
final class NewFileAvailabilityTests: XCTestCase {
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

    func testRoundTripsThroughTheAppGroupPayload() {
        let availability = NewFileAvailability(creatableTypes: ["text", "docx", "keynote"])
        availability.write(to: defaults)

        let read = NewFileAvailability.read(from: defaults)
        XCTAssertEqual(read, availability)
        XCTAssertTrue(read?.canCreate("keynote") ?? false)
        XCTAssertFalse(read?.canCreate("pages") ?? true)
    }

    /// "Not published" is a distinct state from "nothing creatable": the
    /// extension turns the former into the text-only menu and the latter would
    /// be an empty submenu.
    func testMissingPayloadReadsAsNil() {
        XCTAssertNil(NewFileAvailability.read(from: defaults))
    }

    func testCorruptPayloadReadsAsNilInsteadOfCrashing() {
        defaults.set(Data("not json".utf8), forKey: NewFileAvailability.storageKey)
        XCTAssertNil(NewFileAvailability.read(from: defaults))

        defaults.set(Data(), forKey: NewFileAvailability.storageKey)
        XCTAssertNil(NewFileAvailability.read(from: defaults))
    }

    /// The extension reads the group suite, so the identifier must be the shared
    /// one — a typo here would silently disable every document kind.
    func testAppGroupDefaultsUseTheSharedSuite() {
        XCTAssertEqual(NewFileAvailability.appGroupDefaults === UserDefaults.standard, false)
    }

    /// A kind added to the settings catalog must be representable in the payload;
    /// otherwise it could never appear in the menu.
    func testPayloadCanCarryEverySettingsKind() {
        let all = NewFileType.allCases.map(\.rawValue)
        let availability = NewFileAvailability(creatableTypes: all)
        availability.write(to: defaults)
        let read = NewFileAvailability.read(from: defaults)
        for rawValue in all {
            XCTAssertTrue(read?.canCreate(rawValue) ?? false, "\(rawValue) did not survive the round trip")
        }
    }
}
