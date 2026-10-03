import AppKit

/// Minimal pasteboard helper: clear + write a plain string.
///
/// Clipboard History, monitoring, polling, and item types belong to a later
/// phase and are deliberately not implemented here.
enum PasteboardWriter {
    /// - Returns: `false` when the pasteboard refused the write, so the caller
    ///   can tell the user instead of silently leaving an empty clipboard
    ///   (the previous `Void` version ignored `setString`'s result).
    static func write(_ string: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(string, forType: .string)
    }
}
