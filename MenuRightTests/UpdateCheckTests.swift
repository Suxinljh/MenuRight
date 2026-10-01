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

    // MARK: - Failure wording
    //
    // "被限流" and "网络不通" used to both read "检查更新失败：HTTP 403", which
    // sends the user to the wrong fix (check the router vs. wait an hour).

    func testRateLimitIsNotReportedAsANetworkFailure() {
        let limited = UpdateFailureMessage.make(
            for: UpdateCheckError.rateLimited(resetAt: nil),
            language: .simplifiedChinese
        )
        let offline = UpdateFailureMessage.make(for: UpdateCheckError.offline, language: .simplifiedChinese)

        XCTAssertNotEqual(limited, offline)
        XCTAssertTrue(limited.contains("上限"), "the rate limit is not named: \(limited)")
        XCTAssertFalse(limited.contains("网络不通"), "a rate limit is not a network failure: \(limited)")
        XCTAssertTrue(offline.contains("网络不通"), "the offline case lost its wording: \(offline)")
        XCTAssertFalse(offline.contains("上限"), "a network failure is not a rate limit: \(offline)")
        XCTAssertFalse(limited.contains("HTTP 403"), "the raw status code is not the user's problem: \(limited)")
    }

    func testRateLimitResetStampIsRenderedAsALocalClockTime() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        for language in [AppLanguage.simplifiedChinese, .english] {
            let message = UpdateFailureMessage.make(
                for: UpdateCheckError.rateLimited(resetAt: reset),
                language: language
            )
            XCTAssertTrue(
                message.contains(UpdateFailureMessage.clockTime(reset)),
                "\(language) did not render the reset time: \(message)"
            )
            XCTAssertFalse(message.contains("%@"), "\(language) left a placeholder unfilled: \(message)")
        }
    }

    func testAConnectivityFailureAndATimeoutReadDifferently() {
        let offline = UpdateFailureMessage.make(for: UpdateCheckError.offline, language: .english)
        let timedOut = UpdateFailureMessage.make(for: UpdateCheckError.timedOut, language: .english)
        let generic = UpdateFailureMessage.make(for: UpdateCheckError.httpStatus(500), language: .english)

        XCTAssertNotEqual(offline, timedOut)
        XCTAssertTrue(timedOut.lowercased().contains("time"), "the timeout is not named: \(timedOut)")
        XCTAssertNotEqual(offline, generic)
        XCTAssertNotEqual(timedOut, generic)
        // Anything we have no special wording for still names its status code.
        XCTAssertTrue(generic.contains("500"), "the generic message lost the status code: \(generic)")
    }

    func testNoPublishedReleaseKeepsItsOwnWording() {
        let message = UpdateFailureMessage.make(
            for: UpdateRelease.DecodingFailure.noPublishedRelease,
            language: .simplifiedChinese
        )
        XCTAssertEqual(message, Localization.text(.generalUpdateNoReleases, language: .simplifiedChinese))
    }

    func testRateLimitResetPrefersRetryAfterOverTheEpochHeader() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func response(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(
                url: URL(string: "https://api.github.com/repos/Suxinljh/MenuRight/releases/latest")!,
                statusCode: 403,
                httpVersion: "HTTP/2",
                headerFields: headers
            )!
        }

        XCTAssertEqual(
            UpdateChecker.rateLimitReset(in: response(["Retry-After": "120"]), now: now),
            now.addingTimeInterval(120)
        )
        XCTAssertEqual(
            UpdateChecker.rateLimitReset(in: response(["X-RateLimit-Reset": "1800003600"]), now: now),
            Date(timeIntervalSince1970: 1_800_003_600)
        )
        // Both present: `retry-after` is the server talking about *this* request.
        XCTAssertEqual(
            UpdateChecker.rateLimitReset(
                in: response(["Retry-After": "60", "X-RateLimit-Reset": "1800036000"]),
                now: now
            ),
            now.addingTimeInterval(60)
        )
        // Neither: the message falls back to the version without a time.
        XCTAssertNil(UpdateChecker.rateLimitReset(in: response([:]), now: now))
        XCTAssertNil(UpdateChecker.rateLimitReset(in: response(["X-RateLimit-Reset": "not a number"]), now: now))
    }

    // MARK: - Classification, end to end
    //
    // The wording tests above pin the sentences; the header test pins the reset
    // parsing. These drive the *whole* path — request, status/header
    // classification, published state — because the branch that turns a 403 into
    // `.rateLimited` is private, and no pure test would notice it being folded
    // back into the generic case.

    @MainActor
    func testA403EndsUpAsTheRateLimitMessage() async throws {
        let checker = UpdateChecker(
            store: try makeScratchStore(),
            session: stubbedSession(ForbiddenURLProtocol.self),
            currentVersion: "1.0"
        )
        await checker.checkNow()

        guard case .failed(let message) = checker.state else {
            return XCTFail("expected a failure state, got \(checker.state)")
        }
        XCTAssertTrue(message.contains("上限"), "a 403 was not classified as rate limiting: \(message)")
        XCTAssertFalse(message.contains("网络不通"), "a 403 is not a network failure: \(message)")
        XCTAssertFalse(message.contains("HTTP 403"), "the raw status code leaked through: \(message)")
        XCTAssertTrue(
            message.contains(UpdateFailureMessage.clockTime(Date(timeIntervalSince1970: 1_800_003_600))),
            "the reset stamp GitHub sent was dropped: \(message)"
        )
    }

    @MainActor
    func testAnUnreachableHostEndsUpAsTheOfflineMessage() async throws {
        let checker = UpdateChecker(
            store: try makeScratchStore(),
            session: stubbedSession(UnreachableURLProtocol.self),
            currentVersion: "1.0"
        )
        await checker.checkNow()

        guard case .failed(let message) = checker.state else {
            return XCTFail("expected a failure state, got \(checker.state)")
        }
        XCTAssertTrue(message.contains("网络不通"), "a dead network was not named: \(message)")
        XCTAssertFalse(message.contains("上限"), "a dead network is not a rate limit: \(message)")
    }

    @MainActor
    func testASlowGitHubEndsUpAsTheTimeoutMessage() async throws {
        let checker = UpdateChecker(
            store: try makeScratchStore(),
            session: stubbedSession(SilentURLProtocol.self),
            currentVersion: "1.0"
        )
        await checker.checkNow()

        guard case .failed(let message) = checker.state else {
            return XCTFail("expected a failure state, got \(checker.state)")
        }
        XCTAssertTrue(message.contains("超时"), "a timeout was not named: \(message)")
        XCTAssertFalse(message.contains("上限"), "a timeout is not a rate limit: \(message)")
    }

    // MARK: - Helpers

    /// A scratch store whose language is pinned: the machine running the tests
    /// may resolve `.system` to either language, and these assertions are about
    /// *which* sentence comes out, not which locale this Mac is set to.
    @MainActor
    private func makeScratchStore(language: AppLanguage = .simplifiedChinese) throws -> SettingsStore {
        let suiteName = "MenuRightTests.update.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults, storageKey: "test.settings")
        store.mutate { $0.general.language = language }
        return store
    }

    private func stubbedSession(_ protocolClass: URLProtocol.Type) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return URLSession(configuration: configuration)
    }


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

// MARK: - Canned transports
//
// One class per behaviour, with no shared mutable state: two tests that set a
// static "what should this return" flag would be racing each other the moment
// XCTest runs the class in parallel.

/// GitHub's unauthenticated quota exhausted: 403 plus the reset stamp the real
/// API sends.
private final class ForbiddenURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 403,
            httpVersion: "HTTP/2",
            headerFields: [
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": "1800003600",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"message":"API rate limit exceeded for 1.2.3.4."}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// No route to the network at all.
private final class UnreachableURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

/// Connected, then nothing came back.
private final class SilentURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }

    override func stopLoading() {}
}
