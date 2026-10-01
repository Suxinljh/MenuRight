import AppKit
import os
import Quartz

/// Diagnostics for a process that has no UI of its own: a preview extension that
/// fails silently is otherwise indistinguishable from one that never ran.
/// `log show --predicate 'subsystem == "xin.ljhsu.MenuRight"' --last 2m` shows it.
private let logger = Logger(subsystem: MenuRightAppGroup.logSubsystem, category: "CodePreview")

/// Root view that reports appearance changes back to the controller.
///
/// `viewDidChangeEffectiveAppearance` is an `NSView` method, so the controller
/// cannot observe it directly; this subclass is the hook that lets the "Follow
/// System" theme re-render when the panel switches between light and dark.
private final class PreviewRootView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// Quick Look preview extension entry point.
///
/// Quick Look owns the panel; this controller only builds a scrollable text view
/// and hands it the highlighted file. Reading, highlighting and theming live in
/// `Shared/CodePreview/` — the same engine and the same App Group settings the
/// settings pane previews — so the two surfaces cannot disagree about colours,
/// and the behaviour stays unit-testable outside the extension.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let stackView = NSStackView()

    private let limits = CodePreviewLimits.default

    /// Last successful read, kept so an appearance change (light ↔ dark) can
    /// re-render without touching the file again.
    private var lastRender: (source: String, fileName: String, settings: CodePreviewSettings, byteTruncated: Bool)?

    // MARK: - View

    override func loadView() {
        let root = PreviewRootView()
        root.wantsLayer = true
        root.onAppearanceChange = { [weak self] in self?.renderLastFile() }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.isHidden = true

        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.distribution = .fill
        stackView.spacing = 6
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 10, right: 14)
        stackView.detachesHiddenViews = true
        stackView.addArrangedSubview(scrollView)
        stackView.addArrangedSubview(footerLabel)

        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = true

        for subview in [stackView, messageLabel] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: root.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            messageLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
        ])

        self.view = root
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL) async throws {
        // Touch the view first: Quick Look asks for content before showing the
        // panel, and the renderer needs a loaded hierarchy to resolve appearance.
        _ = view

        let settings = CodePreviewSettings.load()

        do {
            let result = try CodePreviewFileReader.read(from: url, maxBytes: limits.maxBytes)
            lastRender = (
                source: result.text,
                fileName: url.lastPathComponent,
                settings: settings,
                byteTruncated: result.isByteTruncated
            )
            renderLastFile()
        } catch {
            // A read failure is a message, not a thrown error: Quick Look would
            // otherwise show its generic "cannot preview" placeholder instead.
            // The error itself goes to the log — that is the S3 evidence for
            // "can a sandboxed preview extension read the file it was handed?".
            logger.error("preview unreadable file=\(url.lastPathComponent, privacy: .public) error=\(String(describing: error), privacy: .public)")
            lastRender = nil
            showMessage(Localization.text(.codePreviewUnreadable, language: settings.resolvedLanguage))
        }
    }

    // MARK: - Rendering

    private func renderLastFile() {
        guard let lastRender else { return }

        let document = CodePreviewDocumentBuilder.makeDocument(
            source: lastRender.source,
            fileName: lastRender.fileName,
            settings: lastRender.settings,
            prefersDark: prefersDarkAppearance,
            limits: limits
        )
        apply(document, settings: lastRender.settings, byteTruncated: lastRender.byteTruncated)
    }

    private var prefersDarkAppearance: Bool {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func apply(_ document: CodePreviewDocument, settings: CodePreviewSettings, byteTruncated: Bool) {
        // `notice`, not `debug`: debug-level entries are memory-only, so they
        // never show up in `log show` — and this line is the evidence that the
        // extension ran, read the file and found the App Group theme.
        logger.notice(
            """
            preview rendered file=\(document.fileName, privacy: .public) \
            language=\(document.language.rawValue, privacy: .public) \
            lines=\(document.renderedLineCount) \
            theme=\(settings.theme.themeID, privacy: .public) \
            truncated=\(document.isTruncated || byteTruncated)
            """
        )

        stackView.isHidden = false
        messageLabel.isHidden = true

        view.layer?.backgroundColor = document.backgroundColor.cgColor
        textView.backgroundColor = document.backgroundColor
        textView.textStorage?.setAttributedString(document.text)
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))

        if document.isTruncated || byteTruncated {
            footerLabel.stringValue = String(
                format: Localization.text(.codePreviewTruncated, language: settings.resolvedLanguage),
                document.renderedLineCount
            )
            footerLabel.isHidden = false
        } else {
            footerLabel.isHidden = true
        }
    }

    private func showMessage(_ message: String) {
        stackView.isHidden = true
        messageLabel.stringValue = message
        messageLabel.isHidden = false
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)?.cgColor
    }
}
