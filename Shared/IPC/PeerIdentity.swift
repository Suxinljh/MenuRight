import Foundation
import Security
import Darwin

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
///      a designated requirement that pins the peer to our extension bundle
///      identifier signed by our team.
///   4. The peer's on-disk binary path via `proc_pidpath_audittoken` — used
///      to read the team identifier from the static code's signing info,
///      since the live SecCode's team-identifier is not always populated in
///      the same code path.
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
    public static func verify(
        fd: Int32,
        requirement requirementString: String = PeerIdentity.extensionRequirementString,
        expectedTeamIdentifier expectedTeam: String = PeerIdentity.expectedTeamIdentifier
    ) -> Result {
        // 1) UID/GID via the public getpeereid() — no private struct required.
        var uid: uid_t = 0
        var gid: gid_t = 0
        if getpeereid(fd, &uid, &gid) != 0 {
            return .rejected(reason: "getpeereid failed: \(String(cString: strerror(errno)))")
        }

        // 2) Peer PID via the public SOL_LOCAL / LOCAL_PEERPID getsockopt.
        var peerPid: pid_t = -1
        var pidLen: socklen_t = socklen_t(MemoryLayout<pid_t>.size)
        if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPid, &pidLen) != 0 {
            return .rejected(reason: "LOCAL_PEERPID failed: \(String(cString: strerror(errno)))")
        }

        // 3) Audit token via SOL_LOCAL / LOCAL_PEERTOKEN. The token is a
        // 32-byte opaque value; see <mach/message.h> for the layout.
        var token = audit_token_t()
        var tokenLen: socklen_t = socklen_t(MemoryLayout<audit_token_t>.size)
        if getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLen) != 0 {
            return .rejected(reason: "LOCAL_PEERTOKEN failed: \(String(cString: strerror(errno)))")
        }

        // 4) Resolve the peer's executable path from the audit token. This
        // public API is documented in <libproc.h> and is available since
        // macOS 11.0. The buffer size comes from PROC_PIDPATHINFO_MAXSIZE
        // in <sys/proc_info.h> (4 * MAXPATHLEN = 4096 on macOS).
        let pathSize = 4096
        let pathBuf = UnsafeMutablePointer<CChar>.allocate(capacity: pathSize)
        defer { pathBuf.deallocate() }
        let pathResult = proc_pidpath_audittoken(&token, pathBuf, UInt32(pathSize))
        guard pathResult > 0 else {
            return .rejected(reason: "proc_pidpath_audittoken failed: \(String(cString: strerror(errno)))")
        }
        let execPath = String(cString: pathBuf)

        // 5) Build a SecCodeRef from the audit token.
        let tokenData = withUnsafeBytes(of: &token) { rawBuf -> Data in
            Data(bytes: rawBuf.baseAddress!, count: rawBuf.count)
        }
        let guestResult: Result = tokenData.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) -> Result in
            guard let cfData = CFDataCreateWithBytesNoCopy(
                kCFAllocatorDefault,
                rawBuf.baseAddress, rawBuf.count,
                kCFAllocatorNull
            ) else {
                return .rejected(reason: "CFDataCreateWithBytesNoCopy returned nil")
            }
            let attrs = CFDictionaryCreateMutable(nil, 1, nil, nil)!
            CFDictionarySetValue(attrs,
                Unmanaged.passUnretained(kSecGuestAttributeAudit).toOpaque(),
                Unmanaged.passUnretained(cfData).toOpaque())
            let attrsRef: CFDictionary = attrs

            var codeRef: SecCode?
            let s = SecCodeCopyGuestWithAttributes(nil, attrsRef, SecCSFlags(), &codeRef)
            guard s == errSecSuccess, let codeRef else {
                return .rejected(reason: "SecCodeCopyGuestWithAttributes failed OSStatus=\(s)")
            }

            // 6) Compile the designated requirement.
            let reqStr = requirementString as CFString
            var reqRef: SecRequirement?
            let rs = SecRequirementCreateWithString(reqStr, SecCSFlags(), &reqRef)
            guard rs == errSecSuccess, let reqRef else {
                return .rejected(reason: "SecRequirementCreateWithString failed OSStatus=\(rs)")
            }

            // 7) Check the code against the requirement.
            let vs = SecCodeCheckValidity(codeRef, SecCSFlags(), reqRef)
            guard vs == errSecSuccess else {
                return .rejected(reason: "SecCodeCheckValidity failed OSStatus=\(vs) requirement=\(requirementString)")
            }
            return .verified(Verified(
                pid: peerPid, uid: uid, gid: gid,
                bundleIdentifier: "?", teamIdentifier: "?",
                executablePath: execPath
            ))
        }
        // If guest verification succeeded, augment with bundle/team info from
        // the static code at execPath.
        if case .verified(var v) = guestResult {
            // 8) Read identifier / team identifier from the on-disk static
            // code at the peer's executable path. Using a static code
            // (file path) ensures the kSecCodeInfoTeamIdentifier is populated
            // when the on-disk signature includes the team (true for our dev
            // and prod certs).
            guard let url = CFURLCreateWithFileSystemPath(nil, execPath as CFString, .cfurlposixPathStyle, false) else {
                return .rejected(reason: "CFURLCreateWithFileSystemPath failed")
            }
            var staticCodeRef: SecStaticCode?
            let ss = SecStaticCodeCreateWithPath(url, SecCSFlags(), &staticCodeRef)
            guard ss == errSecSuccess, let staticCodeRef else {
                return .rejected(reason: "SecStaticCodeCreateWithPath failed OSStatus=\(ss) path=\(execPath)")
            }
            var infoRef: CFDictionary?
            // Empirically, the team identifier is populated only when
            // kSecCSSigningInformation (flag bit 1, value 2) is passed.
            // kSecCSRequirementInformation (bit 2, value 4) is documented
            // to return the Designated Requirement but does NOT include the
            // team identifier in this macOS version's Sec framework.
            let infoStatus = SecCodeCopySigningInformation(
                staticCodeRef,
                SecCSFlags(rawValue: 2),
                &infoRef
            )
            guard infoStatus == errSecSuccess, let infoRef else {
                return .rejected(reason: "SecCodeCopySigningInformation failed OSStatus=\(infoStatus)")
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
            // Final team check.
            if v.teamIdentifier != expectedTeam {
                return .rejected(reason: "team mismatch: got=\(v.teamIdentifier) expected=\(expectedTeam)")
            }
            return .verified(v)
        }
        return guestResult
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
}
