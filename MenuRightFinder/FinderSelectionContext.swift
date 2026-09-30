import Foundation

/// Parsed snapshot of a Finder right-click selection.
///
/// Pure Foundation on purpose: it never touches FIFinderSyncController, so the
/// formatting logic is unit-testable without mocking Finder APIs. FinderSync
/// reads selectedItemURLs() / targetedURL() inside the legitimate menu(for:)
/// context and hands the raw URLs to this type.
///
/// IMPORTANT: on a real Finder, selectedItemURLs() and targetedURL() are NOT
/// guaranteed to describe the same location (e.g. the right-clicked item lives
/// in one window while targetedURL() reports the frontmost window's folder).
/// Future file operations must choose by operation semantics and never assume
/// selection and target are equal.
struct FinderSelectionContext {
    let itemURLs: [URL]
    let targetedURL: URL?

    init(itemURLs: [URL], targetedURL: URL?) {
        self.itemURLs = itemURLs
        self.targetedURL = targetedURL
    }

    /// True when the user right-clicked one or more items.
    var hasSelection: Bool { !itemURLs.isEmpty }

    var selectionCount: Int { itemURLs.count }

    /// The folder the menu applies to: the targeted container, or the parent
    /// folder of the first selected item as a fallback.
    var containerDirectory: URL? {
        targetedURL ?? itemURLs.first?.deletingLastPathComponent()
    }

    // MARK: - Formatted output

    /// One file name per line. Empty selection produces an empty string.
    var formattedNames: String {
        FinderTextFormatter.names(from: itemURLs)
    }

    /// One absolute file path per line (no file:// scheme).
    var formattedPaths: String {
        FinderTextFormatter.paths(from: itemURLs)
    }

    /// One percent-encoded file URL per line.
    var formattedFileURLs: String {
        FinderTextFormatter.fileURLs(from: itemURLs)
    }
}

/// Pure string formatting extracted from Finder URL metadata.
enum FinderTextFormatter {
    /// The newline character, kept in one place for readability.
    static let newline = String(UnicodeScalar(10))

    /// "example.png" for a single item; one name per line for multiple items.
    static func names(from urls: [URL]) -> String {
        urls.map { url in url.lastPathComponent }.joined(separator: newline)
    }

    /// Absolute POSIX paths, one per line. Never emits "file://".
    static func paths(from urls: [URL]) -> String {
        urls.map { url in url.path }.joined(separator: newline)
    }

    /// Percent-encoded file URLs, one per line.
    static func fileURLs(from urls: [URL]) -> String {
        urls.map { url in url.absoluteString }.joined(separator: newline)
    }
}
