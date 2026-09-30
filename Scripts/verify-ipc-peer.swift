// Standalone verification of the App-Group IPC peer-identity gate.
//
// Unit tests inject a stub peer verifier (a test process cannot present the
// FinderSync extension's signature), so the REAL SecCode path is only covered
// here. This tool connects to the running main app's socket and runs the exact
// requirement strings the extension ships, from a separate process:
//
//   * positive: `mainAppRequirementString` must VERIFY the running main app
//     (this is precisely what the extension does after connect());
//   * negative: the extension's own requirement must NOT match the main app;
//   * negative: a wrong team OU must be rejected (proves the requirement is
//     genuinely team-bound, not decorative).
//
// Usage (the main app must be running and signed):
//
//   xcodebuild -project MenuRight.xcodeproj -scheme MenuRight -configuration Debug \
//     build -allowProvisioningUpdates
//   open "$(xcodebuild -project MenuRight.xcodeproj -scheme MenuRight \
//     -configuration Debug -showBuildSettings 2>/dev/null \
//     | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/MenuRight.app"
//   swiftc -O Scripts/verify-ipc-peer.swift Shared/IPC/MenuRightIPC.swift \
//     Shared/IPC/PeerIdentity.swift Shared/IPC/UnixSocketTransport.swift \
//     -o /tmp/verify-ipc-peer && /tmp/verify-ipc-peer
//
// Exit code 0 = all three checks passed.

import Foundation
import Darwin

@main
struct VerifyIPCPeer {
    static func main() {
        guard let socketURL = MenuRightIPC.socketFileURL() else {
            print("FAIL: App Group container unavailable")
            exit(2)
        }
        print("socket: \(socketURL.path)")

        var allPassed = true
        allPassed = check(
            "mainAppRequirementString (what the extension runs)",
            socketURL: socketURL,
            requirement: PeerIdentity.mainAppRequirementString,
            expectVerified: true
        ) && allPassed
        allPassed = check(
            "extensionRequirementString (must NOT match the app)",
            socketURL: socketURL,
            requirement: PeerIdentity.extensionRequirementString,
            expectVerified: false
        ) && allPassed
        allPassed = check(
            "wrong team OU (must be rejected)",
            socketURL: socketURL,
            requirement: "anchor apple generic and identifier \"\(PeerIdentity.mainAppBundleIdentifier)\" and certificate leaf[subject.OU] = \"AAAAAAAAAA\"",
            expectVerified: false
        ) && allPassed

        print(allPassed ? "RESULT: PASS" : "RESULT: FAIL")
        exit(allPassed ? 0 : 1)
    }

    /// Connects, verifies the peer, and returns whether the outcome matched
    /// `expectVerified`.
    private static func check(
        _ label: String,
        socketURL: URL,
        requirement: String,
        expectVerified: Bool
    ) -> Bool {
        let conn = UnixSocketTransport.connect(to: socketURL)
        guard conn.fd >= 0 else {
            print("\(label): connect failed: \(conn.error ?? "unknown")")
            return false
        }
        defer { Darwin.close(conn.fd) }

        switch PeerIdentity.verify(fd: conn.fd, requirement: requirement) {
        case .verified(let peer):
            print("\(label): VERIFIED pid=\(peer.pid) bundleId=\(peer.bundleIdentifier) team=\(peer.teamIdentifier)")
            return expectVerified
        case .rejected(let reason):
            print("\(label): rejected -> \(reason)")
            return !expectVerified
        }
    }
}
