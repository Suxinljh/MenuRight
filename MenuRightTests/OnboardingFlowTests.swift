import XCTest

/// The first-run guide's decision logic.
///
/// The view itself needs a window, but "should the guide appear at all" and the
/// step transitions are the parts that can be wrong in a way users notice, so
/// they live in `OnboardingFlow`.
final class OnboardingFlowTests: XCTestCase {
    func testGuideAppearsOnFirstRun() {
        XCTAssertTrue(OnboardingFlow.shouldPresent(hasCompleted: false, isExtensionEnabled: false))
        // Even if the extension is already on (an old install), a first run still
        // gets the explanation.
        XCTAssertTrue(OnboardingFlow.shouldPresent(hasCompleted: false, isExtensionEnabled: true))
    }

    /// A disabled extension means the app cannot do anything, so the guide comes
    /// back rather than leaving the user with a context menu that never appears.
    func testGuideReturnsWhileTheExtensionIsOff() {
        XCTAssertTrue(OnboardingFlow.shouldPresent(hasCompleted: true, isExtensionEnabled: false))
    }

    func testGuideStaysAwayOnceDoneAndEnabled() {
        XCTAssertFalse(OnboardingFlow.shouldPresent(hasCompleted: true, isExtensionEnabled: true))
    }

    func testStepsAdvanceAndRetreatWithinBounds() {
        var flow = OnboardingFlow()
        XCTAssertEqual(flow.step, .enableExtension)
        XCTAssertTrue(flow.isFirstStep)
        XCTAssertFalse(flow.isLastStep)

        // Retreating from the first step is a no-op, not a crash.
        flow.retreat()
        XCTAssertEqual(flow.step, .enableExtension)

        flow.advance()
        XCTAssertEqual(flow.step, .authorizeFolders)
        flow.advance()
        XCTAssertEqual(flow.step, .ready)
        XCTAssertTrue(flow.isLastStep)

        // Advancing past the last step is a no-op too.
        flow.advance()
        XCTAssertEqual(flow.step, .ready)

        flow.retreat()
        XCTAssertEqual(flow.step, .authorizeFolders)
    }

    func testStepNumberingIsOneBasedAndComplete() {
        var flow = OnboardingFlow()
        XCTAssertEqual(flow.stepCount, OnboardingStep.allCases.count)
        XCTAssertEqual(flow.stepCount, 3, "the guide is enable → authorize → done")
        XCTAssertEqual(flow.stepNumber, 1)

        flow.advance()
        XCTAssertEqual(flow.stepNumber, 2)
        flow.advance()
        XCTAssertEqual(flow.stepNumber, 3)
    }

    // MARK: - A step must be done before the next one

    func testCannotAdvanceUntilTheExtensionIsOn() {
        var flow = OnboardingFlow()
        XCTAssertEqual(flow.step, .enableExtension)

        XCTAssertFalse(flow.canAdvance(isExtensionEnabled: false, authorizedFolderCount: 0))
        XCTAssertEqual(
            flow.blockedReasonKey(isExtensionEnabled: false, authorizedFolderCount: 0),
            .onboardingBlockedExtension
        )

        XCTAssertTrue(flow.canAdvance(isExtensionEnabled: true, authorizedFolderCount: 0))
        XCTAssertNil(flow.blockedReasonKey(isExtensionEnabled: true, authorizedFolderCount: 0))
    }

    func testCannotAdvanceWithoutAnAuthorizedFolder() {
        var flow = OnboardingFlow()
        flow.advance()
        XCTAssertEqual(flow.step, .authorizeFolders)

        XCTAssertFalse(flow.canAdvance(isExtensionEnabled: true, authorizedFolderCount: 0))
        XCTAssertEqual(
            flow.blockedReasonKey(isExtensionEnabled: true, authorizedFolderCount: 0),
            .onboardingBlockedFolder
        )

        XCTAssertTrue(flow.canAdvance(isExtensionEnabled: true, authorizedFolderCount: 1))
        XCTAssertNil(flow.blockedReasonKey(isExtensionEnabled: true, authorizedFolderCount: 1))
    }

    /// The summary only reports status, so it never blocks finishing.
    func testSummaryStepAlwaysAllowsFinishing() {
        var flow = OnboardingFlow()
        flow.jump(to: .ready)
        XCTAssertTrue(flow.canAdvance(isExtensionEnabled: false, authorizedFolderCount: 0))
        XCTAssertNil(flow.blockedReasonKey(isExtensionEnabled: false, authorizedFolderCount: 0))
    }

    func testReviewHookCanJumpToAStep() {
        var flow = OnboardingFlow()
        flow.jump(to: .ready)
        XCTAssertEqual(flow.step, .ready)
        XCTAssertTrue(flow.isLastStep)
    }

    /// The guide's copy exists in both languages (the catalog test covers every
    /// key, this pins the ones the guide needs to be non-empty).
    func testGuideCopyIsPresentInBothLanguages() {
        let keys: [StringKey] = [
            .onboardingTitle, .onboardingStepIndicator, .onboardingSkip, .onboardingBack,
            .onboardingNext, .onboardingStart, .onboardingEnableTitle, .onboardingEnableBody,
            .onboardingEnableStatusOn, .onboardingEnableStatusOff, .onboardingEnableOpenSettings,
            .onboardingEnableHint, .onboardingBlockedExtension, .onboardingBlockedFolder,
            .onboardingAuthorizeTitle, .onboardingAuthorizeBody,
            .onboardingAuthorizeChoose, .onboardingAuthorizeCount, .onboardingReadyTitle,
            .onboardingReadyBody, .onboardingReadyRestartHint,
        ]
        for key in keys {
            for language in [AppLanguage.simplifiedChinese, .english] {
                XCTAssertFalse(
                    Localization.text(key, language: language).isEmpty,
                    "\(key.rawValue) is empty in \(language.rawValue)"
                )
            }
        }
        XCTAssertEqual(
            String(format: Localization.text(.onboardingStepIndicator, language: .english), 2, 3),
            "Step 2 of 3"
        )
        XCTAssertEqual(
            String(format: Localization.text(.onboardingAuthorizeCount, language: .simplifiedChinese), 1),
            "已授权 1 个文件夹"
        )
    }
}
