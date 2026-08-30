import AppKit

/// Lightweight user-visible failure reporting for Finder operations.
///
/// NSAlert only — no custom windows. Successful normal operations stay silent;
/// failures get one concise, actionable alert.
enum OperationPresenter {
    static func presentTitle(_ title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func presentCreationFailure(name: String, in directory: URL, error: FileOperationError) {
        let title = "Couldn’t create “" + name + "”."
        let message = error.userFacingDescription
        presentTitle(title, message: message)
        logOperationFailure(operation: "create", error: error, directory: directory)
    }

    /// Summarizes a move batch into a single alert; silent when everything moved.
    static func presentPasteResults(_ results: [FileOperationItemResult]) {
        switch FileOperationBatchSummary.summarize(results) {
        case .allSucceeded:
            return
        case .allFailed(let failures), .partial(let failures):
            let count = failures.count
            let conflictNames = failures.compactMap { result -> String? in
                if case .failed(.destinationExists) = result.status { return result.sourceURL.lastPathComponent }
                return nil
            }
            let invalidReasons = failures.compactMap { result -> String? in
                if case .failed(.invalidMove(let reason)) = result.status { return reason }
                return nil
            }

            var message: String
            if !conflictNames.isEmpty {
                let joined = conflictNames.joined(separator: ", ")
                message = count == conflictNames.count
                    ? "Items could not be moved because files with the same names already exist in the destination: " + joined + "."
                    : "Some items could not be moved because files with the same names already exist in the destination."
            } else if !invalidReasons.isEmpty {
                message = invalidReasons.first ?? "The move is not allowed."
            } else {
                message = "The move failed. " + (firstFailureDescription(of: failures) ?? "")
            }

            let noun = count == 1 ? "1 item" : String(count) + " items"
            let title = count == 1 ? "Couldn’t move the item." : "Couldn’t move " + noun + "."
            presentTitle(title, message: message)
            for failure in failures {
                logOperationFailure(operation: "move", error: failureError(from: failure), directory: URL(fileURLWithPath: "/"), source: failure.sourceURL)
            }
        }
    }

    /// Phase A2.5: authorization errors surface as the Folder Access Required
    /// message instead of a raw Cocoa 513.
    static func presentAuthorizationError(_ error: FolderAuthorizationError) {
        presentFolderAccessRequired()
    }

    static func presentFolderAccessRequired() {
        let line1 = "Menu Right needs access to this folder before it can modify files here."
        let line2 = "Open Menu Right → Folder Access and authorize this folder or one of its parent folders."
        presentTitle("Folder Access Required", message: line1 + String(UnicodeScalar(10)) + String(UnicodeScalar(10)) + line2)
    }

    // MARK: - Logging (development only, low frequency)

    private static func firstFailureDescription(of failures: [FileOperationItemResult]) -> String? {
        for failure in failures {
            if case .failed(let error) = failure.status { return error.userFacingDescription }
        }
        return nil
    }

    private static func failureError(from result: FileOperationItemResult) -> FileOperationError {
        if case .failed(let error) = result.status { return error }
        return .unknown("unknown")
    }

    private static func logOperationFailure(operation: String, error: FileOperationError, directory: URL, source: URL? = nil) {
        if case .fileSystem(let domain, let code, let description, let posixCode) = error {
            var log = "[MenuRight] " + operation + " failed: domain=" + domain + " code=" + String(code)
            if let posixCode { log += " posix=" + String(posixCode) }
            log += " description=" + description
            if let source { log += " source=" + source.path }
            log += " directory=" + directory.path
            NSLog("%@", log)
        }
    }
}
