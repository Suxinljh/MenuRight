import XCTest

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
}
