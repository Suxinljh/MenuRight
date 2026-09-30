import Foundation

/// The three steps of the first-run guide.
///
/// Kept as a small value type (not view state) so the decision to show the guide
/// and the step transitions are unit-testable without a UI.
enum OnboardingStep: Int, CaseIterable, Equatable, Sendable {
    /// Explain what the app is and get the Finder extension enabled.
    case enableExtension
    /// Explain the authorization model and let the user pick folders.
    case authorizeFolders
    /// Summary plus the restart action.
    case ready

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

/// State machine of the first-run guide.
///
/// The app has exactly one system-level permission to obtain (enabling the Finder
/// extension) plus in-app folder authorization, so the guide is deliberately
/// short: enable → authorize → done.
struct OnboardingFlow: Equatable, Sendable {
    private(set) var step: OnboardingStep = .enableExtension

    /// Whether the guide should be presented.
    ///
    /// Shown until the user finishes it once, and again whenever the extension is
    /// off — a disabled extension means the app cannot work, so the guide is the
    /// right thing to put in front of the user rather than a silently empty menu.
    /// Skipping only dismisses it for the current launch.
    static func shouldPresent(hasCompleted: Bool, isExtensionEnabled: Bool) -> Bool {
        !hasCompleted || !isExtensionEnabled
    }

    var stepNumber: Int { step.rawValue + 1 }
    var stepCount: Int { OnboardingStep.allCases.count }
    var isLastStep: Bool { step.next == nil }
    var isFirstStep: Bool { step.previous == nil }

    mutating func advance() {
        guard let next = step.next else { return }
        step = next
    }

    mutating func retreat() {
        guard let previous = step.previous else { return }
        step = previous
    }

    /// Whether the current step's requirement is met — i.e. whether the user may
    /// move on at all.
    ///
    /// The guide exists to obtain permissions, so it does not let the user walk
    /// past a step that has not happened: the extension must be on before step 2,
    /// and step 2 needs at least one authorized folder. "Not Now" stays available,
    /// so a user who cannot grant a permission is never trapped.
    func canAdvance(isExtensionEnabled: Bool, authorizedFolderCount: Int) -> Bool {
        switch step {
        case .enableExtension:
            return isExtensionEnabled
        case .authorizeFolders:
            return authorizedFolderCount > 0
        case .ready:
            // The summary only reports; "Start Using" is always allowed.
            return true
        }
    }

    /// Why "Next" is disabled, or `nil` when it is not.
    func blockedReasonKey(
        isExtensionEnabled: Bool,
        authorizedFolderCount: Int
    ) -> StringKey? {
        guard !canAdvance(
            isExtensionEnabled: isExtensionEnabled,
            authorizedFolderCount: authorizedFolderCount
        ) else { return nil }
        switch step {
        case .enableExtension: return .onboardingBlockedExtension
        case .authorizeFolders: return .onboardingBlockedFolder
        case .ready: return nil
        }
    }

    /// Jump straight to a step — used by the Debug review hook that screenshots
    /// each step without clicking through.
    mutating func jump(to step: OnboardingStep) {
        self.step = step
    }
}
