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
        // NSAlert.runModal() must run on the main thread. Callers today already
        // hop there, but an API whose correctness depends on every future
        // caller remembering to do so is a trap: marshal here instead.
        if Thread.isMainThread {
            presentTitleOnMain(title: title, message: message)
        } else {
            DispatchQueue.main.async { presentTitleOnMain(title: title, message: message) }
        }
    }

    private static func presentTitleOnMain(title: String, message: String) {
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

    /// **P6** UI bridge for per-item delegated actions (alias creation, locking,
    /// unlocking). Silent on full success; on failure reports the first message
    /// plus how many items failed.
    static func presentDelegatedItemFailures(
        _ items: [FileOperationContract.ItemResult],
        action: String
    ) {
        let failures = items.filter { !$0.success }
        guard !failures.isEmpty else { return }

        let firstMessage = failures.first?.message.flatMap { $0.isEmpty ? nil : $0 }
            ?? "The operation failed."
        let detail: String
        if failures.count == 1 {
            detail = firstMessage
        } else if failures.count == items.count {
            detail = "All \(failures.count) items failed. " + firstMessage
        } else {
            detail = "\(failures.count) of \(items.count) items failed. " + firstMessage
        }
        presentTitle("Couldn't \(action).", message: detail)

        for failure in failures {
            NSLog("[MenuRight] %@ failed: source=%@ code=%@ message=%@",
                  action,
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

    /// **P7-b** UI bridge for a favorite that could not be opened. The main app
    /// has already resolved the target (path, bundle identifier or URL) and
    /// returns a message that names the actual problem, so the alert shows it
    /// instead of a generic failure.
    static func presentDelegatedOpenFailure(name: String, code: FileOperationContract.ErrorCode, message: String) {
        NSLog("[MenuRight] open failed: name=%@ code=%@ message=%@", name, code.rawValue, message)
        let displayed = message.isEmpty ? "The item could not be opened." : message
        presentTitle("Couldn’t open “" + name + "”.", message: displayed)
    }

    /// **P9** UI bridge for a compression/extraction failure.
    static func presentDelegatedArchiveFailure(action: String, code: FileOperationContract.ErrorCode, message: String) {
        NSLog("[MenuRight] archive %@ failed: code=%@ message=%@", action, code.rawValue, message)
        let displayed = message.isEmpty ? "The operation failed." : message
        presentTitle("Couldn’t \(action).", message: displayed)
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
