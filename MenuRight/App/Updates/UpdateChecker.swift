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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // "The request never got there" is not the same failure as "the
            // server said no", and the user's next move differs: fix the network
            // versus wait for the quota. Keep the two apart here, at the only
            // place that still knows which one happened.
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                throw UpdateCheckError.offline
            case .timedOut:
                throw UpdateCheckError.timedOut
            default:
                throw UpdateCheckError.transport(error.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.transport("no HTTP response")
        }
        switch http.statusCode {
        case 200:
            return try UpdateRelease.decode(from: data)
        case 404:
            // A public repository with no published release answers 404.
            throw UpdateRelease.DecodingFailure.noPublishedRelease
        case 403, 429:
            // Unauthenticated GitHub allows 60 requests per hour and answers 403
            // (429 when it feels like it) once that is gone — including right
            // now, from a shared IP. The reset stamp is what makes the message
            // actionable, so it is read rather than guessed.
            throw UpdateCheckError.rateLimited(resetAt: Self.rateLimitReset(in: http))
        default:
            throw UpdateCheckError.httpStatus(http.statusCode)
        }
    }

    /// When the unauthenticated quota comes back: `retry-after` (seconds) wins
    /// over `x-ratelimit-reset` (epoch seconds); `nil` when GitHub sent neither.
    nonisolated static func rateLimitReset(in http: HTTPURLResponse, now: Date = Date()) -> Date? {
        if let raw = http.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(raw) {
            return now.addingTimeInterval(seconds)
        }
        if let raw = http.value(forHTTPHeaderField: "X-RateLimit-Reset"), let epoch = TimeInterval(raw) {
            return Date(timeIntervalSince1970: epoch)
        }
        return nil
    }

    private func message(for error: Error) -> String {
        UpdateFailureMessage.make(for: error, language: store.settings.general.language)
    }
}

enum UpdateCheckError: LocalizedError, Equatable {
    case httpStatus(Int)
    /// 403/429: GitHub answered, but refused — the unauthenticated hourly quota
    /// is gone. `resetAt` is when it comes back, when GitHub said so.
    case rateLimited(resetAt: Date?)
    /// The request never left the machine: no route, DNS failure, interface down.
    case offline
    /// A connection was established but GitHub did not answer in time.
    case timedOut
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "HTTP \(code)"
        case .rateLimited(let resetAt):
            return resetAt.map { "rate limited until \($0)" } ?? "rate limited"
        case .offline: return "network unreachable"
        case .timedOut: return "request timed out"
        case .transport(let detail): return detail
        }
    }
}

/// The sentence the user is shown when a check fails.
///
/// Pure, and deliberately outside `UpdateChecker` (which owns the URLSession):
/// these are wording rules, and the whole point of them is that "rate limited",
/// "no network" and "nothing published yet" are three different problems that
/// must not collapse into one "检查更新失败：HTTP 403". The settings row and the
/// menu bar alert both come through here, so they cannot drift apart.
enum UpdateFailureMessage {
    static func make(for error: Error, language: AppLanguage) -> String {
        switch error {
        case UpdateRelease.DecodingFailure.noPublishedRelease:
            return Localization.text(.generalUpdateNoReleases, language: language)
        case UpdateCheckError.offline:
            return Localization.text(.generalUpdateOffline, language: language)
        case UpdateCheckError.timedOut:
            return Localization.text(.generalUpdateTimedOut, language: language)
        case UpdateCheckError.rateLimited(let resetAt):
            guard let resetAt else {
                return Localization.text(.generalUpdateRateLimited, language: language)
            }
            return String(
                format: Localization.text(.generalUpdateRateLimitedUntil, language: language),
                clockTime(resetAt)
            )
        default:
            return String(
                format: Localization.text(.generalUpdateFailed, language: language),
                error.localizedDescription
            )
        }
    }

    /// "21:05" — the reset stamp is the one piece of a rate-limit response that
    /// tells the user whether to retry in a minute or in an hour. Localised, so
    /// it reads the way every other time on their Mac does.
    static func clockTime(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
