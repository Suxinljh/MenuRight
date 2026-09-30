import SwiftUI
import AppKit

// MARK: - Settings bindings

extension SettingsStore {
    /// Two-way binding for a settings field.
    ///
    /// Reads go straight to the published tree; writes go through `mutate`,
    /// which normalizes, persists, and republishes. Views therefore never hold
    /// their own copy of a setting.
    func binding<Value>(_ keyPath: WritableKeyPath<MenuRightSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in self.mutate { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// Binding for one member of a `Set`-valued setting (allowed actions,
    /// new-file types, archive formats).
    func containsBinding<Element: Hashable>(
        _ keyPath: WritableKeyPath<MenuRightSettings, Set<Element>>,
        _ member: Element
    ) -> Binding<Bool> {
        Binding(
            get: { self.settings[keyPath: keyPath].contains(member) },
            set: { isOn in
                self.mutate { settings in
                    if isOn {
                        settings[keyPath: keyPath].insert(member)
                    } else {
                        settings[keyPath: keyPath].remove(member)
                    }
                }
            }
        )
    }
}

// MARK: - Colours

extension Color {
    init(rgb: RGBColor) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}

// MARK: - Pane scaffold

/// Standard pane layout: a title block, then the settings groups.
///
/// The content column is capped in width and centred so panes stay readable in
/// a wide window, which is also how the system settings look.
struct SettingsPane<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 2)

                content
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Layout constants shared by every settings card.
///
/// The card draws its own background instead of using `GroupBox`: GroupBox's
/// insets are asymmetric (measured ≈7pt horizontally, ≈11pt vertically), so rows
/// looked cramped left/right and loose top/bottom. Drawing the card here makes
/// the padding identical on all four sides, and the only vertical rhythm inside
/// a card comes from `SettingsRowDivider` — which keeps the outer padding exact.
enum SettingsMetrics {
    /// Padding inside a card, on all four sides.
    static let cardInset: CGFloat = 12
    /// Spacing above and below a row divider.
    static let rowSpacing: CGFloat = 8
    static let cardCornerRadius: CGFloat = 14

    /// Corner radius of the sidebar's selected row. The system's own highlight
    /// is drawn with a much tighter radius (measured ~6pt), and `.sidebar` lists
    /// have no API for it, so the row draws its own rounded background.
    static let sidebarSelectionCornerRadius: CGFloat = 10
}

/// Bordered group of related controls, optionally with an explanatory footer.
struct SettingsGroup<Content: View>: View {
    /// `nil` for a card that carries no heading of its own (the first-run guide
    /// uses headings in its step layout instead).
    let title: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(SettingsMetrics.cardInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(
                    cornerRadius: SettingsMetrics.cardCornerRadius,
                    style: .continuous
                )
                .fill(.quinary)
            )

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One row inside a `SettingsGroup`: leading icon, title/subtitle, trailing
/// control. Rows are separated by the caller via `SettingsRowDivider`.
struct SettingsRow<Content: View>: View {
    let title: String
    var subtitle: String?
    /// SF Symbol for rows that are not part of the icon specification.
    var systemImage: String?
    /// Vendored Lucide/Phosphor asset (draws instead of `systemImage`).
    var iconAsset: String?
    var isEnabled: Bool = true
    /// Caps the subtitle to this many lines (middle-truncated). A long path
    /// otherwise competes with the trailing control for width.
    var subtitleLineLimit: Int?
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        iconAsset: String? = nil,
        isEnabled: Bool = true,
        subtitleLineLimit: Int? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.iconAsset = iconAsset
        self.isEnabled = isEnabled
        self.subtitleLineLimit = subtitleLineLimit
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let iconAsset {
                AssetIcon(assetName: iconAsset)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .center)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .center)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(subtitleLineLimit)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: subtitleLineLimit == nil)
                }
            }
            Spacer(minLength: 12)
            content
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Toggle row: label on the leading edge, switch on the trailing edge — the
/// same right alignment as the pickers, buttons and steppers in other rows.
///
/// A bare `Toggle` sizes itself to its content, which both floated the switch
/// next to the label and shrank the whole card to ~150pt. The `HStack` +
/// `Spacer` + `labelsHidden()` form fills the card so the switch lands on the
/// same vertical line as every other control.
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String?
    /// Vendored Lucide/Phosphor asset shown before the label.
    var iconAsset: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let iconAsset {
                AssetIcon(assetName: iconAsset)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .center)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }
}

/// Read-only "label — value" line, used by the About group.
struct SettingsInfoRow: View {
    let label: String
    let value: String
    var isMonospaced: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .font(isMonospaced ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

/// Separator between rows. It carries the vertical rhythm inside a card, so
/// `SettingsRow`/`SettingsToggleRow` stay padding-free and the card's own
/// padding is the same on all four sides.
struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, SettingsMetrics.rowSpacing)
    }
}

/// Grey hint used where a group would otherwise be empty.
struct SettingsEmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Small capsule used for statuses and availability badges.
struct SettingsBadge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(0.16))
            )
            .foregroundStyle(color)
    }
}

/// Renders a vendored icon asset (Lucide or Phosphor SVG) as the app expects.
///
/// Every icon catalog marks its imagesets `template-rendering-intent`, so the
/// system tint — grey when a sidebar row is idle, accent/white when selected,
/// plain label colour inside a pane — and dark mode follow automatically;
/// nothing here picks a colour. The fixed box keeps rows aligned, and
/// `preserves-vector-representation` keeps icons crisp at any scale.
struct AssetIcon: View {
    let assetName: String
    var size: CGFloat = 16

    var body: some View {
        Image(assetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)   // the owning row/Label already names the item
    }
}

/// Brand lockup at the top of the sidebar: the mark, the wordmark, and the
/// version line.
///
/// Geometry is taken from Figma node `1430:75` (file `lnuGHTOgsBJi8Bx9xIIAFK`,
/// frame "logo"): mark 39.12pt square, 8pt gap, wordmark 120x18.689, 2pt column
/// gap, version text 13pt SF Pro Display Regular.
///
/// Two deliberate deviations, both about being a *native* sidebar rather than a
/// picture of one:
/// - the designer's text column is a fixed 146.7pt wide (an artefact of the
///   frame, wider than the 120pt wordmark it contains). Here the column hugs
///   its content, so the lockup is ~167pt instead of 193.8pt — the visible
///   pixels are identical, there is just no empty trailing box;
/// - the version line is `.secondary` rather than the design's `white`, because
///   the sidebar follows the system appearance here: white would disappear on a
///   light sidebar. It is one modifier away if the brand wants fixed white.
///
/// The mark is a gradient and the wordmark is brand cyan, so unlike
/// `AssetIcon` these are drawn with their exported colours.
struct SidebarBrandHeader: View {
    let versionText: String

    private let markSize: CGFloat = 39
    private let wordmarkWidth: CGFloat = 120
    private let wordmarkHeight: CGFloat = 18.7
    private let spacing: CGFloat = 8
    private let textSpacing: CGFloat = 2
    private let versionFontSize: CGFloat = 13

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            Image("menuright-logo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: markSize, height: markSize)

            VStack(alignment: .leading, spacing: textSpacing) {
                Image("menuright-font")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: wordmarkWidth, height: wordmarkHeight)

                Text(versionText)
                    .font(.system(size: versionFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        // Optically aligned with the navigation icon column (whose artwork
        // starts 29.5pt from the sidebar edge): the mark's ink fills its frame,
        // so 21pt of padding puts it on the same vertical line. The design's own
        // frame carries no surrounding spacing, so this is a judgement call —
        // drop it to 14 to sit on the sidebar's content margin instead.
        .padding(.leading, 21)
        .padding(.trailing, 8)
        .padding(.top, 14)
        .padding(.bottom, 10)
        // The mark, the wordmark and the version line are one heading.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("MenuRight, \(versionText)")
        .accessibilityAddTraits(.isHeader)
    }
}

extension SettingsStore {
    /// "版本 1.0" / "version 1.0" — the sidebar header subtitle.
    ///
    /// Built from the bundle's marketing version so it can never drift from the
    /// shipped build (the Figma mock happens to say 1.0, which is also what
    /// `MARKETING_VERSION` is today).
    var sidebarVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return String(format: text(.sidebarVersionLine), version)
    }
}

/// Filled status dot used for the extension and IPC indicators.
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
    }
}

// MARK: - Alerts

/// Modal warning used by panes that perform a one-off action (authorizing a
/// folder, registering a login item, adding a favorite).
/// Button titles are passed in (never hardcoded): the window can be rendered in
/// either language, so an alert must not fall back to `NSLocalizedString`,
/// which would stay English because the app ships no `.lproj` resources.
enum SettingsAlert {
    static func present(title: String, message: String, buttonTitle: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: buttonTitle)
        alert.runModal()
    }

    /// Yes/No confirmation. Returns true when the user confirms.
    static func confirm(
        title: String,
        message: String,
        confirmTitle: String,
        cancelTitle: String
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Formatting

extension SettingsStore {
    /// "已启用 8 / 12 项" style summary.
    func enabledCountText(_ enabled: Int, _ total: Int) -> String {
        String(format: text(.commonEnabledCount), enabled, total)
    }
}
