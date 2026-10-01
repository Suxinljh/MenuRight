import XCTest

/// Update checking: version ordering, GitHub payload decoding, and the rules
/// that decide when to check and when to speak.
///
/// The networking itself stays thin on purpose — everything interesting is a
/// pure function here, so it is testable without a network.
final class UpdateCheckTests: XCTestCase {

    // MARK: - Version ordering

    func testVersionComparisonIsNumericNotLexicographic() {
        // "1.10" < "1.9" as strings, which is the bug a release train hits.
        XCTAssertEqual(UpdateVersion.compare("1.10", "1.9"), .orderedDescending)
        XCTAssertEqual(UpdateVersion.compare("1.9", "1.10"), .orderedAscending)
    }

    func testVersionComparisonHandlesMissingComponentsAndPrefixes() {
        XCTAssertEqual(UpdateVersion.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(UpdateVersion.compare("v1.1", "1.1"), .orderedSame)
        XCTAssertEqual(UpdateVersion.compare("2.0", "1.99"), .orderedDescending)
        XCTAssertEqual(UpdateVersion.compare("1.0.1", "1.0"), .orderedDescending)
        XCTAssertEqual(UpdateVersion.compare("1.0-beta", "1.0"), .orderedSame)
        XCTAssertEqual(UpdateVersion.compare("1.0", "1.0"), .orderedSame)
    }

    func testNormalizedStripsTheTagPrefix() {
        XCTAssertEqual(UpdateVersion.normalized("v1.2.3"), "1.2.3")
        XCTAssertEqual(UpdateVersion.normalized("V2.0"), "2.0")
        XCTAssertEqual(UpdateVersion.normalized(" 1.0 "), "1.0")
    }

    func testReleaseKnowsWhetherItIsNewer() {
        let release = makeRelease(version: "1.1")
        XCTAssertTrue(release.isNewer(than: "1.0"))
        XCTAssertFalse(release.isNewer(than: "1.1"))
        XCTAssertFalse(release.isNewer(than: "2.0"))
    }

    // MARK: - GitHub decoding

    func testDecodesAReleasePayload() throws {
        let release = try UpdateRelease.decode(from: Data(githubPayload.utf8))

        XCTAssertEqual(release.version, "1.1")
        XCTAssertEqual(release.tagName, "v1.1")
        XCTAssertEqual(release.title, "MenuRight 1.1")
        XCTAssertEqual(release.notes, "Fixes and a new theme.")
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/Suxinljh/MenuRight/releases/tag/v1.1")
        XCTAssertEqual(release.downloadURL?.absoluteString, "https://example.com/MenuRight-1.1-arm64.zip")
    }

    func testFallsBackToTheTagWhenTheReleaseHasNoName() throws {
        let json = githubPayload.replacingOccurrences(of: "\"name\": \"MenuRight 1.1\",", with: "\"name\": \"\",")
        XCTAssertEqual(try UpdateRelease.decode(from: Data(json.utf8)).title, "v1.1")
    }

    func testNoZipAssetMeansNoDownloadURL() throws {
        let json = githubPayload.replacingOccurrences(
            of: "\"name\": \"MenuRight-1.1-arm64.zip\", \"browser_download_url\": \"https://example.com/MenuRight-1.1-arm64.zip\"",
            with: "\"name\": \"MenuRight-1.1.dmg\", \"browser_download_url\": \"https://example.com/MenuRight-1.1.dmg\""
        )
        XCTAssertNil(try UpdateRelease.decode(from: Data(json.utf8)).downloadURL)
    }

    func testRefusesDraftsAndPreReleases() {
        let draft = githubPayload.replacingOccurrences(of: "\"draft\": false", with: "\"draft\": true")
        XCTAssertThrowsError(try UpdateRelease.decode(from: Data(draft.utf8)))

        let prerelease = githubPayload.replacingOccurrences(of: "\"prerelease\": false", with: "\"prerelease\": true")
        XCTAssertThrowsError(try UpdateRelease.decode(from: Data(prerelease.utf8)))
    }

    func testRefusesMalformedPayloads() {
        XCTAssertThrowsError(try UpdateRelease.decode(from: Data("not json".utf8)))
        XCTAssertThrowsError(try UpdateRelease.decode(from: Data(#"{"tag_name":""}"#.utf8)))
    }

    // MARK: - Policy

    func testAutomaticChecksAreThrottledAndRespectTheToggle() {
        let now = Date()
        XCTAssertFalse(UpdatePolicy.shouldCheck(automatically: false, lastCheck: nil, now: now))
        XCTAssertTrue(UpdatePolicy.shouldCheck(automatically: true, lastCheck: nil, now: now))
        XCTAssertFalse(UpdatePolicy.shouldCheck(
            automatically: true,
            lastCheck: now.addingTimeInterval(-23 * 60 * 60),
            now: now
        ))
        XCTAssertTrue(UpdatePolicy.shouldCheck(
            automatically: true,
            lastCheck: now.addingTimeInterval(-25 * 60 * 60),
            now: now
        ))
    }

    func testSkippedVersionStaysQuietUntilANewerOneAppears() {
        XCTAssertTrue(UpdatePolicy.shouldPresent(makeRelease(version: "1.1"), skippedVersion: nil))
        XCTAssertFalse(UpdatePolicy.shouldPresent(makeRelease(version: "1.1"), skippedVersion: "1.1"))
        XCTAssertTrue(UpdatePolicy.shouldPresent(makeRelease(version: "1.2"), skippedVersion: "1.1"))
        XCTAssertFalse(UpdatePolicy.shouldPresent(makeRelease(version: "1.0"), skippedVersion: "1.1"))
    }

    func testNotesAreSummarized() {
        XCTAssertEqual(UpdatePolicy.summarizedNotes("  short  "), "short")
        let long = String(repeating: "x", count: 500)
        let summarized = UpdatePolicy.summarizedNotes(long, limit: 100)
        XCTAssertEqual(summarized.count, 101)          // 100 characters plus the ellipsis
        XCTAssertTrue(summarized.hasSuffix("…"))
    }

    // MARK: - Settings compatibility

    func testGeneralSettingsDefaultsKeepCheckingEnabled() throws {
        // A payload written before the update fields existed must not opt the
        // user out of update checks.
        let json = #"{"language":"en","launchAtLogin":false}"#
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: Data(json.utf8))

        XCTAssertTrue(decoded.automaticallyChecksForUpdates)
        XCTAssertNil(decoded.skippedUpdateVersion)
        XCTAssertNil(decoded.lastUpdateCheck)
    }

    func testGeneralSettingsRoundTripCarriesTheUpdateFields() throws {
        let settings = GeneralSettings(
            language: .english,
            launchAtLogin: true,
            automaticallyChecksForUpdates: false,
            skippedUpdateVersion: "1.1",
            lastUpdateCheck: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    // MARK: - Helpers

    private func makeRelease(version: String) -> UpdateRelease {
        UpdateRelease(
            version: version,
            tagName: "v\(version)",
            title: "MenuRight \(version)",
            notes: "notes",
            pageURL: URL(string: "https://example.com")!,
            downloadURL: nil
        )
    }

    private let githubPayload = """
    {
      "tag_name": "v1.1",
      "name": "MenuRight 1.1",
      "body": "Fixes and a new theme.",
      "html_url": "https://github.com/Suxinljh/MenuRight/releases/tag/v1.1",
      "draft": false,
      "prerelease": false,
      "assets": [
        { "name": "MenuRight-1.1-arm64.zip", "browser_download_url": "https://example.com/MenuRight-1.1-arm64.zip" },
        { "name": "checksums.txt", "browser_download_url": "https://example.com/checksums.txt" }
      ]
    }
    """
}
