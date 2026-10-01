import AppKit

/// The compression progress window.
///
/// A plain window, not an `NSAlert`: an alert cannot host a live bar with two
/// controls, always grows an OK button, and (shown without a modal session)
/// leaks AppKit's unused nib slots — see `OperationPresenter`.
///
/// The style mask is the point of the design: `.titled` plus `.miniaturizable`
/// leaves AppKit's close and zoom buttons **present but disabled**, so the only
/// traffic light that does anything is 最小化. That is exactly the system's own
/// "item is locked" sheet this was modelled on, and it is why `.closable` is
/// deliberately absent — a progress window the user can close would leave them
/// wondering whether the compression was cancelled.
///
/// Granularity is one archive entry, so the bar advances per file: a single
/// multi-gigabyte file moves it once, at the end.
final class ArchiveProgressWindow {
    /// Called with the *requested* new state when 暂停/继续 is pressed.
    var onPauseToggle: ((Bool) -> Void)?
    var onCancel: (() -> Void)?

    private let window_: NSWindow
    private let progressBar = NSProgressIndicator()
    private let pauseButton = NSButton()
    private var cancelButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private var isPaused = false

    private let pauseTitle: String
    private let resumeTitle: String

    /// `icon` is injectable so the window can be rendered outside the extension
    /// bundle (tests); production callers let it use the bundled icon.
    init(
        title: String,
        pauseTitle: String,
        resumeTitle: String,
        cancelTitle: String,
        icon injectedIcon: NSImage? = nil
    ) {
        self.pauseTitle = pauseTitle
        self.resumeTitle = resumeTitle

        window_ = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 570, height: 156),
            // `.fullSizeContentView`: the content runs to the top of the window,
            // which is what removes the divider under the title bar. The title
            // text itself is hidden below — the heading lives in the content, as
            // the design has it.
            styleMask: [.titled, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window_.title = title
        window_.titleVisibility = .hidden
        window_.titlebarAppearsTransparent = true
        // No title bar to grab, so the whole surface drags the window.
        window_.isMovableByWindowBackground = true
        window_.isReleasedWhenClosed = false
        window_.level = .floating
        window_.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        guard let content = window_.contentView else { return }

        // Geometry follows the design sketch: icon at the left, the heading and a
        // full-width bar to its right, both buttons bottom-right. The top ~30pt
        // stay clear for the traffic lights, which `.fullSizeContentView` now
        // overlays the content with.
        let icon = NSImageView(frame: NSRect(x: 28, y: 46, width: 64, height: 64))
        icon.image = injectedIcon
            ?? Bundle.main.image(forResource: "archive-zip-7z")
            ?? NSApp?.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)

        titleLabel.stringValue = title
        titleLabel.font = .boldSystemFont(ofSize: 15)
        titleLabel.frame = NSRect(x: 112, y: 108, width: 430, height: 18)
        content.addSubview(titleLabel)

        progressBar.frame = NSRect(x: 112, y: 78, width: 430, height: 12)
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.controlSize = .small
        content.addSubview(progressBar)

        pauseButton.title = pauseTitle
        pauseButton.bezelStyle = .rounded
        pauseButton.frame = NSRect(x: 338, y: 16, width: 96, height: 30)
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        content.addSubview(pauseButton)

        cancelButton = NSButton(title: cancelTitle, target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: 446, y: 16, width: 96, height: 30)
        content.addSubview(cancelButton)

        // Enter pauses and Escape cancels: the two things a user reaches for
        // without aiming.
        pauseButton.keyEquivalent = ""
        cancelButton.keyEquivalent = "\u{1b}"
    }

    func update(fraction: Double) {
        progressBar.doubleValue = min(max(fraction, 0), 1)
    }

    func show() {
        window_.center()
        window_.makeKeyAndOrderFront(nil)
    }

    func close() {
        window_.orderOut(nil)
    }

    @objc private func togglePause() {
        isPaused.toggle()
        pauseButton.title = isPaused ? resumeTitle : pauseTitle
        onPauseToggle?(isPaused)
    }

    @objc private func cancel() {
        onCancel?()
    }

    // MARK: - Test seams

    /// The window itself, the bar and the buttons — exposed so the layout and the
    /// "only 最小化 works" rule can be asserted without Finder.
    var window: NSWindow { window_ }
    var isBarIndeterminate: Bool { progressBar.isIndeterminate }
    var progressFraction: Double { progressBar.doubleValue }
    var buttonTitles: [String] { [pauseButton.title, cancelButton.title] }
    func pressPause() { togglePause() }
    func pressCancel() { cancel() }
}
