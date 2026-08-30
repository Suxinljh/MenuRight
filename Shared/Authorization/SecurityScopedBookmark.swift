import Foundation

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
            return .failure(.resolutionFailed(
                nsError.localizedDescription + " (domain=" + nsError.domain + " code=" + String(nsError.code) + ")"
            ))
        }
    }
}
