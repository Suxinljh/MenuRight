import XCTest
import AppKit

/// The compression progress window.
///
/// These assertions exist because the window's whole point is what it *refuses*
/// to do: there is no working close button (closing it would look like a cancel),
/// the bar is a real one, and 暂停/取消 report through the callbacks rather than
/// doing anything on their own. All of that is checkable without Finder.
final class ArchiveProgressWindowTests: XCTestCase {

    private func makeWindow() -> ArchiveProgressWindow {
        let icon = NSImage(contentsOfFile: repoRoot.appendingPathComponent("zip:7z.png").path)
        return ArchiveProgressWindow(
            title: "正在压缩",
            pauseTitle: "暂停",
            resumeTitle: "继续",
            cancelTitle: "取消",
            icon: icon
        )
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)      // …/MenuRightTests/ArchiveProgressWindowTests.swift
            .deletingLastPathComponent()     // …/MenuRightTests
            .deletingLastPathComponent()     // repository root
    }

    /// The design brief: 最小化 only. `.closable` must be absent, which AppKit
    /// renders as a close button that is present but **disabled**.
    func testWindowOffersMinimizeAndNotClose() throws {
        let window = try XCTUnwrap(makeWindow())
        let nsWindow = try XCTUnwrap(window.window)
        XCTAssertTrue(nsWindow.styleMask.contains(.titled))
        XCTAssertTrue(nsWindow.styleMask.contains(.miniaturizable))
        XCTAssertFalse(nsWindow.styleMask.contains(.closable), "a closable progress window reads as a cancel button")

        XCTAssertEqual(nsWindow.standardWindowButton(.closeButton)?.isEnabled, false)
        XCTAssertEqual(nsWindow.standardWindowButton(.miniaturizeButton)?.isEnabled, true)
        XCTAssertEqual(nsWindow.standardWindowButton(.zoomButton)?.isEnabled, false)
    }

    func testBarIsDeterminateAndButtonsAreWiredToCallbacks() throws {
        let window = try XCTUnwrap(makeWindow())
        XCTAssertFalse(window.isBarIndeterminate)
        XCTAssertEqual(window.progressFraction, 0)

        window.update(fraction: 0.4)
        XCTAssertEqual(window.progressFraction, 0.4, accuracy: 0.001)
        // Out-of-range values are clamped rather than passed to the bar.
        window.update(fraction: 5)
        XCTAssertEqual(window.progressFraction, 1, accuracy: 0.001)

        XCTAssertEqual(window.buttonTitles, ["暂停", "取消"])

        var paused: Bool?
        var cancelled = false
        window.onPauseToggle = { paused = $0 }
        window.onCancel = { cancelled = true }

        window.pressPause()
        XCTAssertEqual(paused, true, "the first press asks to pause")
        XCTAssertEqual(window.buttonTitles, ["继续", "取消"], "and the button then offers to resume")
        window.pressPause()
        XCTAssertEqual(paused, false)
        XCTAssertEqual(window.buttonTitles, ["暂停", "取消"])

        window.pressCancel()
        XCTAssertTrue(cancelled)
    }

    /// Renders the window to a PNG when asked, so the layout can be eyeballed
    /// without a Finder click:
    ///
    ///     MENURIGHT_DUMP_PROGRESS_WINDOW=/tmp/progress.png xcodebuild test …
    func testWindowRendersToAnImageWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["MENURIGHT_DUMP_PROGRESS_WINDOW"] else {
            throw XCTSkip("set MENURIGHT_DUMP_PROGRESS_WINDOW to render the window")
        }
        let window = try XCTUnwrap(makeWindow())
        window.update(fraction: 0.42)
        let nsWindow = try XCTUnwrap(window.window)
        // The window is off screen in a host-less bundle, so lay it out and draw
        // its content view directly (the same technique the other UI probes use).
        let view = try XCTUnwrap(nsWindow.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
