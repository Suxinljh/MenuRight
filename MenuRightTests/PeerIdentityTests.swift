import XCTest
import Darwin

/// Static assertions about the designated requirements used on both sides of the
/// IPC channel (M2). A requirement that is not team-bound is exactly the defect
/// this pins.
final class PeerIdentityTests: XCTestCase {
    func testExtensionRequirementPinsIdentifierTeamAndAppleAnchor() {
        let requirement = PeerIdentity.extensionRequirementString
        XCTAssertTrue(requirement.contains("anchor apple generic"))
        XCTAssertTrue(requirement.contains("identifier \"\(PeerIdentity.extensionBundleIdentifier)\""))
        XCTAssertTrue(
            requirement.contains("certificate leaf[subject.OU]"),
            "the requirement itself must be team-bound, not only the static-code check"
        )
        XCTAssertTrue(requirement.contains(PeerIdentity.expectedTeamIdentifier))
    }

    func testMainAppRequirementPinsTheMainAppIdentifier() {
        let requirement = PeerIdentity.mainAppRequirementString
        XCTAssertTrue(requirement.contains("identifier \"\(PeerIdentity.mainAppBundleIdentifier)\""))
        XCTAssertTrue(requirement.contains("certificate leaf[subject.OU]"))
        XCTAssertFalse(
            requirement.contains(PeerIdentity.extensionBundleIdentifier),
            "the client-side check must not accept the extension itself"
        )
    }

    func testRequirementBuilderIsParameterizedByIdentifier() {
        let a = PeerIdentity.requirementString(forIdentifier: "com.example.a")
        let b = PeerIdentity.requirementString(forIdentifier: "com.example.b")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.contains("com.example.a"))
        XCTAssertTrue(b.contains("com.example.b"))
    }

    func testExpectedTeamIdentifierIsNeverEmpty() {
        // The unit-test bundle has no MenuRightExpectedTeamIdentifier key, so
        // this also covers the Info.plist-injection fallback path.
        XCTAssertFalse(PeerIdentity.expectedTeamIdentifier.isEmpty)
    }

    func testTeamIdentifierComesFromBuildConfigurationWhenPresent() {
        // The app/extension bundles inject $(DEVELOPMENT_TEAM); the test bundle
        // falls back. Either way the value must be a plausible 10-character team
        // id, which catches a silently empty substitution.
        XCTAssertEqual(PeerIdentity.expectedTeamIdentifier.count, 10)
    }

    // MARK: - Sandbox-compatible path check

    func testExecutablePathComparisonIsStandardizedAndExact() {
        XCTAssertTrue(PeerIdentity.executablePathsMatch(
            "/Applications/MenuRight.app/Contents/MacOS/MenuRight",
            "/Applications/MenuRight.app/Contents/MacOS/MenuRight"
        ))
        XCTAssertTrue(PeerIdentity.executablePathsMatch(
            "/Applications/MenuRight.app/Contents/MacOS/../MacOS/MenuRight",
            "/Applications/MenuRight.app/Contents/MacOS/MenuRight"
        ), "`..` must be normalized, not rejected")
        // An impostor binary with the same *shape* is still a different path.
        XCTAssertFalse(PeerIdentity.executablePathsMatch(
            "/tmp/evil/MenuRight.app/Contents/MacOS/MenuRight",
            "/Applications/MenuRight.app/Contents/MacOS/MenuRight"
        ))
        XCTAssertFalse(PeerIdentity.executablePathsMatch(
            "/Applications/MenuRight.app/Contents/MacOS/MenuRight2",
            "/Applications/MenuRight.app/Contents/MacOS/MenuRight"
        ))
    }

    func testVerifyRejectsAnUnconnectedDescriptor() {
        // fd -1 cannot be a peer socket: verification must fail closed.
        guard case .rejected = PeerIdentity.verify(fd: -1) else {
            return XCTFail("verification of an invalid fd must be rejected")
        }
    }

    // MARK: - Path-only fallback decision (the sandbox downgrade, item 1)
    //
    // Driven through `executablePathOnlyDecision` rather than a real peer: the
    // appex sandbox makes the code-signing APIs unavailable here (OSStatus
    // 100001), so the decision logic is the only part a CI box can pin. The uid
    // and gid are injected so the test does not depend on who runs it.

    private let uid = geteuid()
    private let gid = getegid()

    func testPathOnlyDecisionAcceptsExactPathWithMatchingCredentials() {
        let decision = PeerIdentity.executablePathOnlyDecision(
            peerExecutablePath: "/Applications/MenuRight.app/Contents/MacOS/MenuRight",
            expectedExecutablePath: "/Applications/MenuRight.app/Contents/MacOS/MenuRight",
            peerUID: uid,
            peerGID: gid,
            currentUID: uid,
            currentGID: gid
        )
        XCTAssertEqual(decision, .accept)
    }

    func testPathOnlyDecisionRejectsADifferentPathEvenWithSameCredentials() {
        // Same shape, same uid: only the path differs. This is the impostor the
        // fallback must still refuse.
        let decision = PeerIdentity.executablePathOnlyDecision(
            peerExecutablePath: "/tmp/evil/MenuRight.app/Contents/MacOS/MenuRight",
            expectedExecutablePath: "/Applications/MenuRight.app/Contents/MacOS/MenuRight",
            peerUID: uid,
            peerGID: gid,
            currentUID: uid,
            currentGID: gid
        )
        XCTAssertEqual(
            decision,
            .rejectPathMismatch(
                got: "/tmp/evil/MenuRight.app/Contents/MacOS/MenuRight",
                expected: "/Applications/MenuRight.app/Contents/MacOS/MenuRight"
            )
        )
    }

    func testPathOnlyDecisionRejectsAUidOrGidMismatchOnTheSamePath() {
        let path = "/Applications/MenuRight.app/Contents/MacOS/MenuRight"
        let badUID = uid &+ 1
        XCTAssertEqual(
            PeerIdentity.executablePathOnlyDecision(
                peerExecutablePath: path, expectedExecutablePath: path,
                peerUID: badUID, peerGID: gid, currentUID: uid, currentGID: gid
            ),
            .rejectUIDMismatch(got: badUID, expected: uid)
        )
        let badGID = gid &+ 1
        XCTAssertEqual(
            PeerIdentity.executablePathOnlyDecision(
                peerExecutablePath: path, expectedExecutablePath: path,
                peerUID: uid, peerGID: badGID, currentUID: uid, currentGID: gid
            ),
            .rejectGIDMismatch(got: badGID, expected: gid)
        )
    }

    func testPathOnlyDecisionNormalizesSymlinksAndDotDotBeforeComparing() throws {
        // A real directory plus a symlink to it, so `resolvingSymlinksInPath`
        // has something to resolve (the string-only `..` case is covered by
        // `testExecutablePathComparisonIsStandardizedAndExact`).
        let dir = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("mr-peer-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let real = dir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = real.appendingPathComponent("MenuRight")
        FileManager.default.createFile(atPath: tool.path, contents: Data("x".utf8))

        let link = dir.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let decision = PeerIdentity.executablePathOnlyDecision(
            peerExecutablePath: link.appendingPathComponent("MenuRight").path,
            expectedExecutablePath: real.appendingPathComponent("MenuRight").path,
            peerUID: uid,
            peerGID: gid,
            currentUID: uid,
            currentGID: gid
        )
        XCTAssertEqual(decision, .accept, "a symlinked path to the same binary must normalize to a match")

        // And a `..` variant of the same path.
        let dotted = real.appendingPathComponent("../real/MenuRight").path
        XCTAssertEqual(
            PeerIdentity.executablePathOnlyDecision(
                peerExecutablePath: dotted,
                expectedExecutablePath: tool.path,
                peerUID: uid, peerGID: gid, currentUID: uid, currentGID: gid
            ),
            .accept
        )
    }

    func testVerificationLevelRawValuesAreStable() {
        // The raw values reach the log line and the extension's branch, so they
        // are part of the diagnosis contract.
        XCTAssertEqual(PeerIdentity.VerificationLevel.codeSignature.rawValue, "codeSignature")
        XCTAssertEqual(PeerIdentity.VerificationLevel.executablePathOnly.rawValue, "executablePathOnly")
        XCTAssertNotEqual(PeerIdentity.VerificationLevel.codeSignature, PeerIdentity.VerificationLevel.executablePathOnly)
    }
}
