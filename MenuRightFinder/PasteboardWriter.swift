import AppKit

/// Minimal pasteboard helper: clear + write a plain string.
///
/// Clipboard History, monitoring, polling, and item types belong to a later
/// phase and are deliberately not implemented here.
enum PasteboardWriter {
    static func write(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
