import SwiftUI

/// Code theme pane: palette selection, typography, and a live preview rendered
/// with the theme's own colours.
///
/// The preview runs the real `CodeHighlighter` over a sample document instead
/// of a hand-written token list, so what is shown here is what the Quick Look
/// extension will draw in P8 — one engine, one theme model, no drift. The
/// language picker only changes the sample; it is not a persisted setting.
struct CodeThemeSettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var previewLanguage: CodeLanguage = .swift

    private static let fontOptions: [String?] = [nil, "SF Mono", "Menlo", "Monaco", "Courier New"]

    private var settings: CodeThemeSettings { store.settings.codeTheme }

    var body: some View {
        SettingsPane(
            title: store.text(.categoryCodeTheme),
            subtitle: store.text(.codeThemeIntro)
        ) {
            themeGroup
            typographyGroup
            previewGroup
            noteGroup
        }
    }

    private var themeGroup: some View {
        SettingsGroup(title: store.text(.codeThemeTheme)) {
            SettingsRow(title: store.text(.codeThemeTheme), systemImage: "paintpalette") {
                Picker("", selection: store.binding(\.codeTheme.themeID)) {
                    ForEach(CodeThemeCatalog.all) { theme in
                        Text(themeDisplayName(theme)).tag(theme.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220, alignment: .trailing)
            }
        }
    }

    private var typographyGroup: some View {
        SettingsGroup(title: store.text(.codeThemeFont)) {
            SettingsRow(title: store.text(.codeThemeFont), systemImage: "textformat") {
                Picker("", selection: store.binding(\.codeTheme.fontName)) {
                    ForEach(Self.fontOptions, id: \.self) { name in
                        Text(name ?? store.text(.codeThemeFontSystem)).tag(name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220, alignment: .trailing)
            }
            SettingsRowDivider()
            SettingsRow(title: store.text(.codeThemeFontSize), systemImage: "textformat.size") {
                HStack(spacing: 10) {
                    Slider(
                        value: store.binding(\.codeTheme.fontSize),
                        in: CodeThemeSettings.fontSizeRange,
                        step: 1
                    )
                    .frame(width: 150)
                    Text("\(Int(store.settings.codeTheme.fontSize)) pt")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
            SettingsRowDivider()
            SettingsToggleRow(
                title: store.text(.codeThemeLineNumbers),
                isOn: store.binding(\.codeTheme.showsLineNumbers)
            )
        }
    }

    private var previewGroup: some View {
        SettingsGroup(title: store.text(.codeThemePreview)) {
            SettingsRow(
                title: store.text(.codePreviewLanguage),
                systemImage: "chevron.left.forwardslash.chevron.right"
            ) {
                Picker("", selection: $previewLanguage) {
                    ForEach(CodeLanguage.allCases, id: \.self) { language in
                        Text(languageName(language)).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220, alignment: .trailing)
            }
            SettingsRowDivider()
            preview
        }
    }

    private var noteGroup: some View {
        SettingsGroup(title: store.text(.sectionImplementationStatus)) {
            Text(store.text(.codeThemeNote))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Preview

    private var preview: some View {
        let theme = settings.resolvedTheme(prefersDark: colorScheme == .dark)
        let lines = CodeHighlighter.highlight(
            CodePreviewSamples.source(for: previewLanguage),
            language: previewLanguage
        )
        return VStack(alignment: .leading, spacing: 3) {
            Text(CodePreviewSamples.fileName(for: previewLanguage))
                .font(.caption)
                .foregroundStyle(Color(rgb: theme.rgb(for: .comment)))
                .padding(.bottom, 4)
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 10) {
                    if settings.showsLineNumbers {
                        Text("\(index + 1)")
                            .foregroundStyle(Color(rgb: theme.rgb(for: .comment)))
                            .frame(width: 20, alignment: .trailing)
                    }
                    Text(attributed(line, theme: theme))
                }
                .font(previewFont)
            }
        }
        .textSelection(.enabled)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(rgb: theme.rgb(for: .background)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.3))
        )
    }

    private var previewFont: Font {
        if let name = settings.fontName {
            return .custom(name, size: settings.fontSize)
        }
        return .system(size: settings.fontSize, design: .monospaced)
    }

    private func attributed(_ line: CodeHighlightedLine, theme: CodeTheme) -> AttributedString {
        // An empty `Text` collapses and would make the preview lose blank
        // lines; a single space keeps the line height of the sample.
        if line.text.isEmpty { return AttributedString(" ") }

        var result = AttributedString()
        for token in line.tokens {
            var piece = AttributedString(token.text)
            piece.foregroundColor = Color(rgb: theme.rgb(for: token.kind))
            result.append(piece)
        }
        return result
    }

    private func languageName(_ language: CodeLanguage) -> String {
        // Code languages are product names and stay untranslated; plain text is
        // a real label and goes through the catalog.
        language == .plainText ? store.text(.codePreviewPlainText) : language.displayName
    }

    private func themeDisplayName(_ theme: CodeTheme) -> String {
        // The dynamic entry has a translatable name; the palettes are product
        // names and stay as they are.
        theme.appearance == .dynamic ? store.text(.generalLanguageSystem) : theme.name
    }
}
