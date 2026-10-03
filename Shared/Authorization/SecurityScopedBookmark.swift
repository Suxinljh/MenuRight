import Foundation
import os

private let bookmarkDiag = Logger(subsystem: "xin.ljhsu.MenuRight", category: "bookmark-diag")

enum SecurityScopedBookmarkError: Equatable, Error {
    case creationFailed(URL, message: String)
    case resolutionFailed(String)
}

/// App-scope security-scoped bookmark creation and resolution.
/// Creation must originate from a user-selected (NSOpenPanel) URL — the
/// Powerbox permission is required; constructing URLs by hand never grants it.
enum SecurityScopedBookmark {
    static func create(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            let nsError = error as NSError
            let message = nsError.localizedDescription
                + " (domain=" + nsError.domain
                + " code=" + String(nsError.code) + ")"
            throw SecurityScopedBookmarkError.creationFailed(url, message: message)
        }
    }

    static func resolve(_ data: Data) -> Result<(url: URL, isStale: Bool), SecurityScopedBookmarkError> {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return .success((url, isStale))
        } catch {
            let nsError = error as NSError
            SecurityScopedBookmark.diagnoseFailure(nsError, data: data)
            return .failure(.resolutionFailed(
                nsError.localizedDescription + " (domain=" + nsError.domain + " code=" + String(nsError.code) + ")"
            ))
        }
    }

    /// Dumps the full NSError for a bookmark that would not resolve, plus a plain
    /// (no-security-scope) resolve to separate "the data is bad" from "the OS
    /// rejects the scope for this process". Verbose and `.public` on purpose:
    /// this is the only place a field failure becomes diagnosable, and it is the
    /// single implementation of that dump (`FolderAuthorizationAccess` uses it
    /// through `ScopedAccessConfiguration.system` instead of duplicating it).
    private static func diagnoseFailure(_ nsError: NSError, data: Data) {
        bookmarkDiag.log("BOOKMARK resolve(withSecurityScope) FAILED outer domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) desc=\(nsError.localizedDescription, privacy: .public)")

        var uiPairs: [String] = []
        for (k, v) in nsError.userInfo {
            uiPairs.append(Self.describeKeyValue(k, v))
        }
        let uiJoined: String = uiPairs.joined(separator: " | ")
        bookmarkDiag.log("BOOKMARK userInfo=[\(uiJoined, privacy: .public)]")

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            var uPairs: [String] = []
            for (k, v) in underlying.userInfo {
                uPairs.append(Self.describeKeyValue(k, v))
            }
            let uJoined: String = uPairs.joined(separator: " | ")
            bookmarkDiag.log("BOOKMARK underlying domain=\(underlying.domain, privacy: .public) code=\(underlying.code, privacy: .public) desc=\(underlying.localizedDescription, privacy: .public) userInfo=[\(uJoined, privacy: .public)]")
        } else {
            bookmarkDiag.log("BOOKMARK underlying: none")
        }

        // Fallback: resolve WITHOUT .withSecurityScope to test bookmark data validity.
        var plainIsStale = false
        do {
            _ = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &plainIsStale)
            bookmarkDiag.log("BOOKMARK resolve(plain, no security scope) SUCCEEDED — bookmark data is valid; the .withSecurityScope path is being rejected by the OS for this process")
        } catch let plainError as NSError {
            bookmarkDiag.log("BOOKMARK resolve(plain) FAILED domain=\(plainError.domain, privacy: .public) code=\(plainError.code, privacy: .public) desc=\(plainError.localizedDescription, privacy: .public)")
        }
    }

    private static func describeKeyValue(_ k: Any, _ v: Any) -> String {
        return String(describing: k) + "=" + String(describing: v)
    }
}
