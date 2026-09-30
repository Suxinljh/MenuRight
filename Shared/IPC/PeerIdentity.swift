import Foundation
import Security
import Darwin
import os

/// Peer identity verification for the App-Group Unix-socket IPC.
///
/// Public APIs only. No private headers, no copied-in struct definitions, no
/// hardcoded undocumented syscalls.
///
/// On every accepted connection the main app obtains:
///   1. UID/GID via `getpeereid()` — sanity check that the peer is owned by
///      a real user (not a system service or an unrelated sandbox).
///   2. PID via `getsockopt(SOL_LOCAL, LOCAL_PEERPID)` — used for log
///      correlation and (with PID reuse caveats) for cross-checking the
///      audit-token result.
///   3. Audit token via `getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN)` — the
///      canonical proof of the peer's process identity. We pass it to
///      `SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags, &code)`
///      using `kSecGuestAttributeAudit` to obtain a `SecCodeRef`, then we
///      `SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement)` against
///      a designated requirement that pins the peer to our bundle identifier
///      and team.
///   4. The peer's on-disk binary path via `proc_pidpath_audittoken` — used
///      to read the team identifier from the static code's signing info,
///      since the live SecCode's team-identifier is not always populated in
///      the same code path.
///
/// ## Verification strategy (and why there are two paths)
///
/// The live-code path (3) is preferred: it describes the *running* process.
/// Inside an App Sandbox, however, `SecCodeCopyGuestWithAttributes` can fail
/// for a peer at the `OSStatus 100001` step — measured from the FinderSync
/// extension on macOS 26.6.1, while the same call succeeds from the main app.
/// When that specific infrastructure step is unavailable we fall back to
/// validating the **static code at the peer's kernel-provided executable path**
/// (`proc_pidpath_audittoken`, which the peer cannot forge) against the same
/// designated requirement. That is the same class of check the main app already
/// performs for the team identifier, and it is strictly weaker than the live
/// check (the app bundle on disk could be replaced between the two) — so it is
/// used only when the live path cannot run at all, and every fallback is logged.
///
/// A requirement that is *checked and fails* is never retried through the
/// fallback: only an unusable live-code API is.
public enum PeerIdentity {

    public struct Verified {
        public let pid: pid_t
        public let uid: uid_t
        public let gid: gid_t
        public let bundleIdentifier: String
        public let teamIdentifier: String
        public let executablePath: String
    }

    public enum Result {
        case verified(Verified)
        case rejected(reason: String)
    }

    private static let log = Logger(subsystem: MenuRightIPC.subsystem, category: "peer-identity")

    /// Bundle identifier of the FinderSync extension (the main app's peer).
    public static let extensionBundleIdentifier = "xin.ljhsu.MenuRight.FinderSync"

    /// Bundle identifier of the main app (the extension's peer).
    public static let mainAppBundleIdentifier = "xin.ljhsu.MenuRight"

    /// Value used when the build configuration does not inject a team id.
    public static let fallbackTeamIdentifier = "92X76S5UFL"

    /// Expected team identifier, injected at build time through the
    /// `MenuRightExpectedTeamIdentifier` Info.plist key (populated from
    /// `$(DEVELOPMENT_TEAM)`), so changing the signing team is a build-setting
    /// change rather than a silent code edit. Falls back to the shipped value
    /// when the key is absent (e.g. the unit-test bundle, which generates its
    /// own Info.plist).
    public static var expectedTeamIdentifier: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "MenuRightExpectedTeamIdentifier") as? String,
           !value.isEmpty {
            return value
        }
        return fallbackTeamIdentifier
    }

    /// Designated requirement for a peer: Apple-anchored code, exact bundle
    /// identifier, **and** team binding via the leaf certificate's OU.
    ///
    /// The `certificate leaf[subject.OU]` clause is what makes the requirement
    /// itself team-bound. Without it the check would only prove "some code
    /// signed by Apple with this identifier", and the team binding would rest
    /// entirely on reading the on-disk static code at the peer's executable
    /// path (which is a separate, TOCTOU-exposed step).
    public static func requirementString(forIdentifier identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\""
    }

    /// Requirement the main app applies to incoming connections: the peer must
    /// be our FinderSync extension.
    public static var extensionRequirementString: String {
        requirementString(forIdentifier: extensionBundleIdentifier)
    }

    /// Requirement the extension applies to the socket it just connected to:
    /// the peer must be our main app. A same-user process can unlink the socket
    /// file and bind its own path, so the client must verify too.
    public static var mainAppRequirementString: String {
        requirementString(forIdentifier: mainAppBundleIdentifier)
    }

    /// Read peer identity from a connected Unix-domain socket fd and verify it
    /// against the caller's designated requirement. Returns `.verified` only if
    /// every step succeeds.
    /// - Parameter expectedExecutablePath: when non-nil, the peer's executable
    ///   path (as reported by the kernel via `proc_pidpath_audittoken`, which the
    ///   peer cannot forge) must equal this path exactly. This is the one strong
    ///   check that also works inside an app-extension sandbox, where the code
    ///   signing APIs are unavailable (see `verify`'s documentation).
    public static func verify(
        fd: Int32,
        requirement requirementString: String = PeerIdentity.extensionRequirementString,
        expectedTeamIdentifier expectedTeam: String = PeerIdentity.expectedTeamIdentifier,
        expectedExecutablePath: String? = nil
    ) -> Result {
        // 1) UID/GID via the public getpeereid() — no private struct required.
        var uid: uid_t = 0
        var gid: gid_t = 0
        if getpeereid(fd, &uid, &gid) != 0 {
            return reject("getpeereid failed: \(String(cString: strerror(errno)))", requirement: requirementString)
        }

        // 2) Peer PID via the public SOL_LOCAL / LOCAL_PEERPID getsockopt.
        var peerPid: pid_t = -1
        var pidLen: socklen_t = socklen_t(MemoryLayout<pid_t>.size)
        if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPid, &pidLen) != 0 {
            return reject("LOCAL_PEERPID failed: \(String(cString: strerror(errno)))", requirement: requirementString)
        }

        // 3) Audit token via SOL_LOCAL / LOCAL_PEERTOKEN. The token is a
        // 32-byte opaque value; see <mach/message.h> for the layout.
        var token = audit_token_t()
        var tokenLen: socklen_t = socklen_t(MemoryLayout<audit_token_t>.size)
        if getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLen) != 0 {
            return reject("LOCAL_PEERTOKEN failed: \(String(cString: strerror(errno)))", requirement: requirementString)
        }

        // 4) Resolve the peer's executable path from the audit token. This
        // public API is documented in <libproc.h> and is available since
        // macOS 11.0. The buffer size comes from PROC_PIDPATHINFO_MAXSIZE
        // in <sys/proc_info.h> (4 * MAXPATHLEN = 4096 on macOS). The kernel
        // fills this in, so the peer cannot choose it.
        let pathSize = 4096
        let pathBuf = UnsafeMutablePointer<CChar>.allocate(capacity: pathSize)
        defer { pathBuf.deallocate() }
        let pathResult = proc_pidpath_audittoken(&token, pathBuf, UInt32(pathSize))
        guard pathResult > 0 else {
            return reject("proc_pidpath_audittoken failed: \(String(cString: strerror(errno)))", requirement: requirementString)
        }
        let execPath = String(cString: pathBuf)

        // 5) Sandbox-compatible check: the peer must be the executable we expect.
        // `execPath` comes from the kernel, so this cannot be spoofed by the
        // peer; it defeats "unlink the socket and bind your own path" unless the
        // attacker can also replace our installed app bundle.
        if let expectedExecutablePath,
           !executablePathsMatch(execPath, expectedExecutablePath) {
            return reject(
                "peer executable path mismatch: got=\(execPath) expected=\(expectedExecutablePath)",
                requirement: requirementString
            )
        }

        // 6) Compile the designated requirement once, shared by both paths.
        var reqRef: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirementString as CFString, SecCSFlags(), &reqRef
        )
        guard requirementStatus == errSecSuccess, let requirement = reqRef else {
            return reject("SecRequirementCreateWithString failed OSStatus=\(requirementStatus)", requirement: requirementString)
        }

        // 6) Preferred path: the live code object described by the audit token.
        let tokenData = withUnsafeBytes(of: &token) { raw -> Data in
            Data(bytes: raw.baseAddress!, count: raw.count)
        }
        switch liveCode(tokenData: tokenData) {
        case .failure(let status):
            // Infrastructure failure (measured: OSStatus 100001 inside the
            // extension's sandbox). Fall through to the static check below.
            log.notice("live peer code unavailable OSStatus=\(status, privacy: .public); falling back to the static code at the peer's executable path")
        case .success(let code):
            let validity = SecCodeCheckValidity(code, SecCSFlags(), requirement)
            guard validity == errSecSuccess else {
                // The requirement *was* evaluated and failed: never retry it
                // through the fallback.
                return reject("SecCodeCheckValidity failed OSStatus=\(validity)", requirement: requirementString)
            }
            return finish(v: Verified(
                pid: peerPid, uid: uid, gid: gid,
                bundleIdentifier: "?", teamIdentifier: "?",
                executablePath: execPath
            ), execPath: execPath, expectedTeam: expectedTeam, requirement: requirementString)
        }

        // 7) Fallback: validate the static code at the path the kernel reported.
        var staticCodeRef: SecStaticCode?
        let staticStatus = SecStaticCodeCreateWithPath(
            CFURLCreateWithFileSystemPath(nil, execPath as CFString, .cfurlposixPathStyle, false),
            SecCSFlags(),
            &staticCodeRef
        )
        if staticStatus != errSecSuccess || staticCodeRef == nil {
            // Both signature paths are unusable -> this process is denied the
            // code-signing APIs entirely (measured: the FinderSync appex on
            // macOS 26.6.1 returns OSStatus 100001 for both calls, while the main
            // app performs them fine). Accept only when the caller supplied a
            // kernel-verified expected path that matched, and say so loudly.
            guard expectedExecutablePath != nil else {
                return reject("SecStaticCodeCreateWithPath failed OSStatus=\(staticStatus) path=\(execPath)", requirement: requirementString)
            }
            log.notice("peer accepted on kernel-reported executable path alone: code-signing APIs unavailable here (OSStatus=\(staticStatus, privacy: .public), path=\(execPath, privacy: .public)). The main app still verifies this process's signature server-side.")
            return .verified(Verified(
                pid: peerPid, uid: uid, gid: gid,
                bundleIdentifier: expectedExecutablePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? "?",
                teamIdentifier: "unavailable",
                executablePath: execPath
            ))
        }
        let staticValidity = SecStaticCodeCheckValidity(staticCodeRef!, SecCSFlags(), requirement)
        guard staticValidity == errSecSuccess else {
            // A real signature was read and did NOT satisfy the requirement.
            return reject("SecStaticCodeCheckValidity failed OSStatus=\(staticValidity) path=\(execPath)", requirement: requirementString)
        }
        log.notice("peer verified via static code at \(execPath, privacy: .public) (live audit-token check unavailable in this sandbox)")
        return finish(v: Verified(
            pid: peerPid, uid: uid, gid: gid,
            bundleIdentifier: "?", teamIdentifier: "?",
            executablePath: execPath
        ), execPath: execPath, expectedTeam: expectedTeam, requirement: requirementString)
    }

    /// Main-app convenience wrapper: the peer must be the FinderSync extension,
    /// verified against the extension's designated requirement and the
    /// configured team identifier.
    public static func verify(fd: Int32) -> Result {
        verify(
            fd: fd,
            requirement: extensionRequirementString,
            expectedTeamIdentifier: expectedTeamIdentifier
        )
    }

    // MARK: - Helpers

    /// Standardized comparison of two executable paths. Internal (not private)
    /// so the unit tests can pin it: this check is what remains enforceable
    /// inside a sandbox that denies the code-signing APIs.
    static func executablePathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    private enum LiveCodeOutcome {
        case success(SecCode)
        case failure(OSStatus)
    }

    /// Builds the live code object from the peer's audit token.
    private static func liveCode(tokenData: Data) -> LiveCodeOutcome {
        var outcome: LiveCodeOutcome = .failure(errSecInternalError)
        tokenData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            guard let cfData = CFDataCreateWithBytesNoCopy(
                kCFAllocatorDefault, raw.baseAddress, raw.count, kCFAllocatorNull
            ) else {
                outcome = .failure(errSecInternalError)
                return
            }
            let attrs = CFDictionaryCreateMutable(nil, 1, nil, nil)!
            CFDictionarySetValue(
                attrs,
                Unmanaged.passUnretained(kSecGuestAttributeAudit).toOpaque(),
                Unmanaged.passUnretained(cfData).toOpaque()
            )
            var codeRef: SecCode?
            let status = SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, SecCSFlags(), &codeRef)
            if status == errSecSuccess, let codeRef {
                outcome = .success(codeRef)
            } else {
                outcome = .failure(status)
            }
        }
        return outcome
    }

    /// Shared tail: read identifier + team from the static code at `execPath`
    /// and require the expected team.
    private static func finish(
        v: Verified,
        execPath: String,
        expectedTeam: String,
        requirement: String
    ) -> Result {
        var v = v
        var staticCodeRef: SecStaticCode?
        let ss = SecStaticCodeCreateWithPath(
            CFURLCreateWithFileSystemPath(nil, execPath as CFString, .cfurlposixPathStyle, false),
            SecCSFlags(),
            &staticCodeRef
        )
        guard ss == errSecSuccess, let staticCodeRef else {
            return reject("SecStaticCodeCreateWithPath failed OSStatus=\(ss) path=\(execPath)", requirement: requirement)
        }
        var infoRef: CFDictionary?
        // Empirically, the team identifier is populated only when
        // kSecCSSigningInformation (flag bit 1, value 2) is passed.
        // kSecCSRequirementInformation (bit 2, value 4) is documented
        // to return the Designated Requirement but does NOT include the
        // team identifier in this macOS version's Sec framework.
        let infoStatus = SecCodeCopySigningInformation(staticCodeRef, SecCSFlags(rawValue: 2), &infoRef)
        guard infoStatus == errSecSuccess, let infoRef else {
            return reject("SecCodeCopySigningInformation failed OSStatus=\(infoStatus)", requirement: requirement)
        }
        let identKey = Unmanaged.passUnretained(kSecCodeInfoIdentifier).toOpaque()
        let teamKey = Unmanaged.passUnretained(kSecCodeInfoTeamIdentifier).toOpaque()
        if let identCF = CFDictionaryGetValue(infoRef, identKey) {
            v = Verified(
                pid: v.pid, uid: v.uid, gid: v.gid,
                bundleIdentifier: unsafeBitCast(identCF, to: CFString.self) as String,
                teamIdentifier: v.teamIdentifier,
                executablePath: v.executablePath
            )
        }
        if let teamCF = CFDictionaryGetValue(infoRef, teamKey) {
            v = Verified(
                pid: v.pid, uid: v.uid, gid: v.gid,
                bundleIdentifier: v.bundleIdentifier,
                teamIdentifier: unsafeBitCast(teamCF, to: CFString.self) as String,
                executablePath: v.executablePath
            )
        }
        guard v.teamIdentifier == expectedTeam else {
            return reject("team mismatch: got=\(v.teamIdentifier) expected=\(expectedTeam)", requirement: requirement)
        }
        return .verified(v)
    }

    private static func reject(_ reason: String, requirement: String) -> Result {
        log.notice("peer REJECTED \(reason, privacy: .public) requirement=\(requirement, privacy: .public)")
        return .rejected(reason: reason)
    }
}
