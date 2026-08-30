import AppKit

/// System-pasteboard bridge for the Menu Right cut payload.
///
/// Finder Sync Extension processes may restart at any time, so the cut state is
/// deliberately NOT an in-memory property and NOT App Group state — the system
/// pasteboard is the single source of truth. Only our reverse-DNS type is
/// written: standard file-URL types are intentionally omitted so that Finder's
/// Cmd-V never mistakes a Menu Right cut for a Finder copy.
enum CutPasteboard {
    static let type = NSPasteboard.PasteboardType("xin.ljhsu.MenuRight.cut-items")

    static func write(_ payload: CutPayload) throws {
        let data = try CutPayloadCodec.encode(payload)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: type)
    }

    /// Returns the decoded cut payload, or nil when the pasteboard holds no
    /// valid Menu Right cut state (e.g. replaced by another app).
    static func read() -> CutPayload? {
        guard let data = NSPasteboard.general.data(forType: type) else { return nil }
        return try? CutPayloadCodec.decode(data)
    }

    static func containsValidCut() -> Bool {
        read() != nil
    }

    /// Removes the Menu Right cut state.
    ///
    /// clearContents is safe here because write() is the only path that sets our
    /// type and it clears first; if another app replaced the pasteboard after
    /// our cut, our type is already gone and we must NOT touch their content.
    static func remove() {
        let pasteboard = NSPasteboard.general
        if pasteboard.data(forType: type) != nil {
            pasteboard.clearContents()
        }
    }
}
