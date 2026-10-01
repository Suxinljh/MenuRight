import XCTest

/// Guards the one invariant of failure reporting that cannot be observed at
/// runtime: **the Finder Sync extension must never park its main thread.**
///
/// A modal `runModal()` alert blocks the extension's main thread, which is the
/// same thread Finder calls `menu(for:)` on. While it is parked, Finder gets no
/// menu items at all — so the symptom of a modal alert is not "an alert is
/// showing", it is "the MenuRight entries silently disappeared from the context
/// menu", and it lasts until the alert is dismissed or Finder replaces the
/// extension. That is exactly what was reported on 2026-10-01 and it is the same
/// bug class `FinderSync.ipcQueue` exists to prevent.
///
/// There is no runtime assertion that can catch it (the call simply blocks inside
/// AppKit), so this test reads the sources instead. It is deliberately a source
/// scan rather than a behavioural test: in a host-less test bundle there is no
/// `NSApplication`, so the blocking path would not even be exercised.
final class ExtensionMainThreadTests: XCTestCase {
    /// Every source file the extension can reach for user-visible reporting.
    private static let extensionReportSources = [
        "Shared/FileOperations/OperationPresenter.swift",
    ]

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)      // …/MenuRightTests/ExtensionMainThreadTests.swift
            .deletingLastPathComponent()     // …/MenuRightTests
            .deletingLastPathComponent()     // repository root
    }

    private func sources(in relativeDirectory: String) throws -> [(path: String, text: String)] {
        let directory = Self.repositoryRoot.appendingPathComponent(relativeDirectory, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return try names
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .map { name in
                let path = "\(relativeDirectory)/\(name)"
                return (path, try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))
            }
    }

    /// Source with line comments removed, so documentation that *mentions* the
    /// forbidden API (this file's own doc comment does) cannot trip the guard.
    private func code(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// Nothing compiled into the extension may start a modal session.
    func testNoExtensionSourceRunsAModalLoop() throws {
        var scanned = try sources(in: "MenuRightFinder")
        for relative in Self.extensionReportSources {
            scanned.append((relative, try String(contentsOf: Self.repositoryRoot.appendingPathComponent(relative), encoding: .utf8)))
        }
        XCTAssertFalse(scanned.isEmpty, "the scan found no sources — the paths must have moved")

        let offenders = scanned
            .filter { code($0.text).contains("runModal") || code($0.text).contains("beginSheetModal") }
            .map(\.path)
        XCTAssertEqual(
            offenders, [],
            """
            A modal alert parks the Finder Sync extension's main thread, so Finder \
            stops showing any MenuRight menu items until it is dismissed. Present \
            non-modally instead — see OperationPresenter.
            """
        )
    }

    /// The presenter must keep showing something, though: "no reaction at all"
    /// is the other half of the same complaint.
    func testThePresenterStillPutsItsWarningOnScreenWithoutAModalSession() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Shared/FileOperations/OperationPresenter.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("makeKeyAndOrderFront"), "the alert window must be ordered front")
        XCTAssertTrue(source.contains("dismissAllAlerts"), "the OK button needs its own action outside a modal session")
    }

    /// 暂停/继续/取消 must never be queued behind the operation they interrupt.
    ///
    /// `ipcQueue` is serial and the file operation holds it for its whole
    /// lifetime (it is blocked waiting for the answer), so a control message sent
    /// on it only leaves after the compression has finished — a pause button that
    /// does nothing. That shipped once, measured 2026-10-01, which is why this is
    /// a source guard: no runtime assertion in a host-less bundle can reach
    /// `FinderSync.sendControl`.
    func testControlMessagesAreNotQueuedBehindTheOperationTheyInterrupt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("MenuRightFinder/FinderSync.swift"),
            encoding: .utf8
        )

        guard let start = source.range(of: "private func sendControl(")?.upperBound,
              let body = Self.bracedBody(in: source, from: start) else {
            return XCTFail("sendControl not found in FinderSync")
        }
        let code = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")

        XCTAssertFalse(
            code.contains("ipcQueue"),
            """
            sendControl must not run on ipcQueue: that queue is occupied by the \
            operation being controlled, so 暂停/取消 would not be sent until it \
            had already finished. Use controlQueue.
            """
        )
        XCTAssertTrue(code.contains("controlQueue"), "control messages need their own queue")
    }

    /// Text between `{` (the first one after `start`) and its matching `}`.
    private static func bracedBody(in source: String, from start: String.Index) -> String? {
        guard let open = source[start...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[source.index(after: open)..<index]) }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }
}
