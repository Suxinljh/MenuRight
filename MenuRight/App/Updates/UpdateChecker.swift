import AppKit
import Foundation
import os

/// Checks GitHub Releases for a newer build and publishes the outcome.
///
/// It deliberately never downloads or installs anything: replacing a running
/// app needs signature verification, an atomic swap and a relaunch — that is
/// Sparkle's job, and this app has no third-party dependencies. This checks,
/// tells the user, and opens the release page.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// `GET /repos/{owner}/{repo}/releases/latest`. The repository is public, so
    /// no token is needed; unauthenticated GitHub allows 60 requests per hour and
    /// the automatic check is throttled to one per day.
    static let releasesEndpoint = URL(string: "https://api.github.com/repos/Suxinljh/MenuRight/releases/latest")!

    enum State: Equatable {
        case idle
        case checking
        case upToDate(version: String)
        case updateAvailable(UpdateRelease)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let store: SettingsStore
    private let session: URLSession
    private let currentVersion: String
    private static let log = Logger(subsystem: MenuRightIPC.subsystem, category: "updates")

    init(
        store: SettingsStore = .shared,
        session: URLSession = .shared,
        currentVersion: String = UpdateChecker.bundleVersion()
    ) {
        self.store = store
        self.session = session
        self.currentVersion = currentVersion
    }

    /// `nonisolated` so it can be used as a default argument (and from tests)
    /// without hopping to the main actor — it only reads a bundle.
    nonisolated static func bundleVersion(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    nonisolated static func bundleBuild(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// The version this build reports, e.g. "1.0".
    var runningVersion: String { currentVersion }

    // MARK: - Checking

    /// Manual check: ignores the daily throttle and reports every outcome,
    /// including failures.
    func checkNow() async {
        state = .checking
        do {
            let release = try await requestLatestRelease()
            store.mutate { $0.general.lastUpdateCheck = Date() }
            state = release.isNewer(than: currentVersion)
                ? .updateAvailable(release)
                : .upToDate(version: currentVersion)
        } catch {
            state = .failed(message(for: error))
        }
    }

    /// Launch check: respects the toggle and the throttle, stays silent on
    /// failure, and returns a release only when it is worth interrupting for.
    @discardableResult
    func checkAutomaticallyIfNeeded(now: Date = Date()) async -> UpdateRelease? {
        let general = store.settings.general
        guard UpdatePolicy.shouldCheck(
            automatically: general.automaticallyChecksForUpdates,
            lastCheck: general.lastUpdateCheck,
            now: now
        ) else { return nil }

        do {
            let release = try await requestLatestRelease()
            store.mutate { $0.general.lastUpdateCheck = now }
            guard release.isNewer(than: currentVersion),
                  UpdatePolicy.shouldPresent(release, skippedVersion: general.skippedUpdateVersion) else {
                return nil
            }
            state = .updateAvailable(release)
            return release
        } catch {
            // A failed background check is not worth a dialog; the manual button
            // reports it inline instead.
            Self.log.notice("update check failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Acting on a release

    func skip(_ release: UpdateRelease) {
        store.mutate { $0.general.skippedUpdateVersion = release.version }
        state = .idle
    }

    func openReleasePage(_ release: UpdateRelease) {
        NSWorkspace.shared.open(release.pageURL)
    }

    // MARK: - Networking

    private func requestLatestRelease() async throws -> UpdateRelease {
        var request = URLRequest(url: Self.releasesEndpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MenuRight/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.transport("no HTTP response")
        }
        switch http.statusCode {
        case 200:
            return try UpdateRelease.decode(from: data)
        case 404:
            // A public repository with no published release answers 404.
            throw UpdateRelease.DecodingFailure.noPublishedRelease
        default:
            throw UpdateCheckError.httpStatus(http.statusCode)
        }
    }

    private func message(for error: Error) -> String {
        let language = store.settings.general.language
        if case UpdateRelease.DecodingFailure.noPublishedRelease = error {
            return Localization.text(.generalUpdateNoReleases, language: language)
        }
        let format = Localization.text(.generalUpdateFailed, language: language)
        return String(format: format, error.localizedDescription)
    }
}

enum UpdateCheckError: LocalizedError, Equatable {
    case httpStatus(Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "HTTP \(code)"
        case .transport(let detail): return detail
        }
    }
}
