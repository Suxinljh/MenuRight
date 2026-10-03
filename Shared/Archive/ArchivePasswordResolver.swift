import Foundation

/// Where an encrypted archive's password comes from.
///
/// The password is a secret, so it never travels over the Finder extension's IPC:
/// the **main app** is the only process that extracts, and it is the only one
/// that asks. This protocol is the seam between that policy and the extraction
/// machinery, so the tests can drive it without a UI.
///
/// Both methods are called off the main thread. An implementation that shows UI
/// is responsible for marshalling to the main queue (see `ArchivePasswordPrompter`
/// in the app target, which does exactly that).
protocol ArchivePasswordPrompting: AnyObject {
    /// Passwords to try without asking — the password book, in the user's order.
    func automaticPasswords(forArchiveAt url: URL) -> [String]

    /// Asks the user for a password. Returns nil when they give up.
    ///
    /// - Parameter afterFailedAttempt: true when an earlier answer for this
    ///   archive was wrong, so the prompt can say so instead of looking identical.
    func askForPassword(forArchiveAt url: URL, afterFailedAttempt: Bool) -> String?
}

extension ArchivePasswordPrompting {
    func automaticPasswords(forArchiveAt url: URL) -> [String] { [] }
    func askForPassword(forArchiveAt url: URL, afterFailedAttempt: Bool) -> String? { nil }
}

/// Decides which password (if any) an archive needs, before extraction starts.
///
/// Resolving up front — instead of discovering the password requirement halfway
/// through writing entries — is what keeps a cancelled prompt from leaving a
/// half-extracted folder behind.
enum ArchivePasswordResolver {
    enum Resolution: Equatable {
        /// Not encrypted: nothing to unlock.
        case notNeeded
        /// Use this password.
        case resolved(String)
        /// Encrypted, and the user did not produce a password (cancelled, or ran
        /// out of attempts). Nothing has been written.
        case abandoned
    }

    /// How many times the user is asked before giving up. Three is enough to
    /// catch a typo, and a fourth identical dialog helps nobody.
    static let attempts = 3

    /// The two questions the resolver has to ask a container it cannot read yet:
    /// does it want a password, and is this the password? ZIP (traditional) and
    /// 7z (AES-256) answer both differently, so each gets a small adapter.
    protocol Probe {
        var needsPassword: Bool { get }
        func validates(password: String) -> Bool
    }

    /// - Throws: `ArchiveError.notAnArchive` / `.unsupportedFormat` when the file
    ///   is not a readable archive of its kind, and `.passwordRequired` when the
    ///   archive is encrypted but nothing can ask for a password.
    static func resolve(
        archiveURL: URL,
        prompting: (any ArchivePasswordPrompting)?
    ) throws -> Resolution {
        // A split set (`.001`, `.002`, …) only reads as one archive once its
        // parts are stitched together, and the central directory lives in the
        // last part; the scratch copy lives only as long as this call. Formats
        // that cannot be encrypted are not probed at all — probing every
        // archive with the ZIP reader is what made extracting a plain `.7z`,
        // `.tar` or `.tar.gz` fail with "Not a readable archive".
        let volumes = try ArchiveVolumeSet.resolve(archiveURL)
        defer { volumes.discard() }

        guard let probe = try probe(for: volumes.url) else { return .notNeeded }
        guard probe.needsPassword else { return .notNeeded }

        guard let prompting else {
            // No UI is hooked up (a test, or the extension): be honest rather
            // than reporting a CRC error the user cannot act on.
            throw ArchiveError.passwordRequired(archiveURL.lastPathComponent)
        }

        for candidate in prompting.automaticPasswords(forArchiveAt: archiveURL)
        where !candidate.isEmpty {
            if probe.validates(password: candidate) { return .resolved(candidate) }
        }

        var previousWasIncorrect = false
        for _ in 0..<attempts {
            guard let answer = prompting.askForPassword(
                forArchiveAt: archiveURL,
                afterFailedAttempt: previousWasIncorrect
            ), !answer.isEmpty else {
                return .abandoned
            }
            if probe.validates(password: answer) { return .resolved(answer) }
            previousWasIncorrect = true
        }
        return .abandoned
    }

    /// nil when the container cannot carry a password (TAR, gzip, bzip2, xz, or
    /// anything this build does not recognise), so the caller skips asking.
    static func probe(for archiveURL: URL) throws -> (any Probe)? {
        switch ArchiveFormats.detect(at: archiveURL) {
        case .zip:
            do {
                return ZipProbe(reader: try ZipReader(fileURL: archiveURL))
            } catch let error as ZipReaderError {
                throw ArchiveExtractor.map(error, archive: archiveURL)
            }
        case .sevenZip:
            return SevenZipProbe(archiveURL: archiveURL)
        default:
            return nil
        }
    }

    private struct ZipProbe: Probe {
        let reader: ZipReader
        var needsPassword: Bool { reader.needsPassword }
        func validates(password: String) -> Bool { reader.validates(password: password) }
    }

    private struct SevenZipProbe: Probe {
        let archiveURL: URL
        var needsPassword: Bool { SevenZipEncryption.needsPassword(archiveURL: archiveURL) }
        func validates(password: String) -> Bool {
            SevenZipEncryption.validates(password: password, archiveURL: archiveURL)
        }
    }
}
