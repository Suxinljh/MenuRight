import Foundation

/// One published release, read from the GitHub Releases API.
///
/// Pure data + pure rules: no networking, no UI. `UpdateChecker` does the
/// request and the SwiftUI/AppKit layers do the presenting, which keeps the
/// interesting parts (version ordering, what to skip, when to check) testable.
struct UpdateRelease: Equatable, Sendable {
    /// Tag with any leading "v" removed — "1.1" for tag "v1.1".
    let version: String
    let tagName: String
    /// Release title; falls back to the tag when GitHub has no name.
    let title: String
    /// Release body (Markdown).
    let notes: String
    /// Release page on GitHub — what "Download" opens.
    let pageURL: URL
    /// First `.zip` asset, when the release carries one.
    let downloadURL: URL?

    func isNewer(than current: String) -> Bool {
        UpdateVersion.compare(version, current) == .orderedDescending
    }
}

// MARK: - GitHub decoding

extension UpdateRelease {
    enum DecodingFailure: Error, Equatable {
        case malformed(String)
        /// GitHub answers 404 when a repository has no published release yet.
        case noPublishedRelease
    }

    /// Decodes `GET /repos/{owner}/{repo}/releases/latest`.
    ///
    /// Drafts and pre-releases are refused rather than offered: `releases/latest`
    /// already excludes them, but a hand-crafted payload must not be able to
    /// push one to users.
    static func decode(from data: Data) throws -> UpdateRelease {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw DecodingFailure.malformed(String(describing: error))
        }

        guard !(payload.draft ?? false), !(payload.prerelease ?? false) else {
            throw DecodingFailure.malformed("draft or pre-release")
        }
        guard let pageURL = URL(string: payload.htmlURL) else {
            throw DecodingFailure.malformed("html_url is not a URL")
        }
        let version = UpdateVersion.normalized(payload.tagName)
        guard !version.isEmpty else {
            throw DecodingFailure.malformed("empty tag_name")
        }

        let asset = payload.assets?.first { $0.name.lowercased().hasSuffix(".zip") }
        return UpdateRelease(
            version: version,
            tagName: payload.tagName,
            title: payload.name?.isEmpty == false ? payload.name! : payload.tagName,
            notes: payload.body ?? "",
            pageURL: pageURL,
            downloadURL: asset.flatMap { URL(string: $0.browserDownloadURL) }
        )
    }

    private struct Payload: Decodable {
        var tagName: String
        var name: String?
        var body: String?
        var htmlURL: String
        var draft: Bool?
        var prerelease: Bool?
        var assets: [Asset]?

        struct Asset: Decodable {
            var name: String
            var browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case draft
            case prerelease
            case assets
        }
    }
}

// MARK: - Version ordering

enum UpdateVersion {
    /// Strips a leading "v"/"V" and trims whitespace.
    static func normalized(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        return value
    }

    /// Numeric component-wise comparison.
    ///
    /// A string compare gets "1.10" vs "1.9" wrong, which is exactly the case a
    /// release train hits. Missing components count as zero ("1.1" == "1.1.0"),
    /// and anything after a "-"/"+" suffix is ignored.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        let count = max(left.count, right.count)

        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func components(_ raw: String) -> [Int] {
        let base = normalized(raw).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let core = base.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return core.split(separator: ".").map { part in
            // "1" -> 1, "2beta" -> 2, "" -> 0
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }
}

// MARK: - When to check, when to speak

enum UpdatePolicy {
    /// Automatic checks are throttled to once a day; a manual check ignores it.
    static let minimumInterval: TimeInterval = 24 * 60 * 60

    static func shouldCheck(
        automatically: Bool,
        lastCheck: Date?,
        now: Date,
        minimumInterval: TimeInterval = UpdatePolicy.minimumInterval
    ) -> Bool {
        guard automatically else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= minimumInterval
    }

    /// A version the user skipped stays quiet until a newer one appears.
    static func shouldPresent(_ release: UpdateRelease, skippedVersion: String?) -> Bool {
        guard let skippedVersion else { return true }
        return UpdateVersion.compare(release.version, skippedVersion) == .orderedDescending
    }

    /// Release notes are shown in an alert and a settings row; keep them short.
    static func summarizedNotes(_ notes: String, limit: Int = 400) -> String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let cut = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
