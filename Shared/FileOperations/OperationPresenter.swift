import AppKit

/// Lightweight user-visible failure reporting for Finder operations.
///
/// NSAlert only — no custom windows. Successful normal operations stay silent;
/// failures get one concise, actionable alert.
///
/// **P5-1 responsibility split**: the Main App is the only writer, so the
/// extension no longer renders local `FileOperationError` /
/// `FileOperationItemResult` failures. Only the delegated bridges below are
/// reachable from `FinderSync`.
enum OperationPresenter {
    static func presentTitle(_ title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func presentFolderAccessRequired() {
        presentTitle("Folder Access Required", message: presentFolderAccessRequiredMessage())
    }

    /// **P5-1** UI bridge for delegated move results coming back from the
    /// Main App.
    static func presentDelegatedPasteResults(_ items: [FileOperationContract.ItemResult]) {
        let failures = items.filter { !$0.success }
        guard !failures.isEmpty else { return }
        let count = failures.count
        let conflictNames = failures.compactMap { item -> String? in
            if item.errorCode == .nameCollision {
                return (item.sourcePath as NSString).lastPathComponent
            }
            return nil
        }

        let message: String
        if !conflictNames.isEmpty {
            let joined = conflictNames.joined(separator: ", ")
            message = count == conflictNames.count
                ? "Items could not be moved because files with the same names already exist in the destination: " + joined + "."
                : "Some items could not be moved because files with the same names already exist in the destination."
        } else if let first = failures.first, let m = first.message, !m.isEmpty {
            message = m
        } else {
            message = "The move failed."
        }

        let noun = count == 1 ? "1 item" : String(count) + " items"
        let title = count == 1 ? "Couldn’t move the item." : "Couldn’t move " + noun + "."
        presentTitle(title, message: message)

        for failure in failures {
            NSLog("[MenuRight] move failed: source=%@ code=%@ message=%@",
                  failure.sourcePath,
                  failure.errorCode?.rawValue ?? "<nil>",
                  failure.message ?? "")
        }
    }

    /// **P5-1** UI bridge for a single-target delegated create operation.
    /// Shows nothing on success; on failure, displays a concise alert whose
    /// message comes from the Main App's structured response.
    static func presentDelegatedCreateFailure(name: String, code: FileOperationContract.ErrorCode, message: String) {
        let title: String
        switch code {
        case .notAuthorized, .pathOutsideAuthorizedScope:
            title = "Folder Access Required"
        default:
            title = "Couldn’t create “" + name + "”."
        }
        let displayed = (code == .notAuthorized || code == .pathOutsideAuthorizedScope)
            ? presentFolderAccessRequiredMessage()
            : message
        presentTitle(title, message: displayed)
    }

    /// **P5-1** Main App unavailable — the extension can't write locally
    /// anymore. We display one consistent message instead of attempting a
    /// fallback that would silently bypass the security gate.
    static func presentMainAppUnavailable(context: String) {
        let line1 = "Menu Right needs to be running to modify files here."
        let line2 = "Open Menu Right and try again from the Finder menu."
        let suffix = context.isEmpty ? "" : String(UnicodeScalar(10)) + String(UnicodeScalar(10)) + "Details: " + context
        presentTitle("Menu Right not running", message: line1 + String(UnicodeScalar(10)) + String(UnicodeScalar(10)) + line2 + suffix)
    }

    /// Internal helper: builds the standard "Folder Access Required" body.
    static func presentFolderAccessRequiredMessage() -> String {
        let line1 = "Menu Right needs access to this folder before it can modify files here."
        let line2 = "Open Menu Right → Folder Access and authorize this folder or one of its parent folders."
        return line1 + String(UnicodeScalar(10)) + String(UnicodeScalar(10)) + line2
    }

}
