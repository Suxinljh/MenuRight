import SwiftUI

/// Code theme pane: palette selection, typography, and a live preview rendered
/// with the theme's own colours.
///
/// The preview is a fixed sample with explicit token kinds, not a tokenizer:
/// real highlighting belongs to the Quick Look extension (P8), and showing the
/// palette accurately is what this pane is for.
struct CodeThemeSettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.colorScheme) private var colorScheme

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
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(CodeThemePreviewSample.lines.enumerated()), id: \.offset) { index, line in
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

    private func attributed(_ line: [CodeThemePreviewSample.Token], theme: CodeTheme) -> AttributedString {
        var result = AttributedString()
        for token in line {
            var piece = AttributedString(token.text)
            piece.foregroundColor = Color(rgb: theme.rgb(for: token.kind))
            result.append(piece)
        }
        return result
    }

    private func themeDisplayName(_ theme: CodeTheme) -> String {
        // The dynamic entry has a translatable name; the palettes are product
        // names and stay as they are.
        theme.appearance == .dynamic ? store.text(.generalLanguageSystem) : theme.name
    }
}

/// Fixed sample used by the preview. Token kinds are explicit so the palette is
/// shown exactly; nothing here parses code.
enum CodeThemePreviewSample {
    struct Token {
        let text: String
        let kind: CodeThemeToken
    }

    static let lines: [[Token]] = [
        [Token(text: "// MenuRight code preview", kind: .comment)],
        [
            Token(text: "struct ", kind: .keyword),
            Token(text: "Greeting", kind: .type),
            Token(text: " {", kind: .foreground),
        ],
        [
            Token(text: "    let ", kind: .keyword),
            Token(text: "count", kind: .foreground),
            Token(text: ": ", kind: .foreground),
            Token(text: "Int", kind: .type),
            Token(text: " = ", kind: .foreground),
            Token(text: "42", kind: .number),
        ],
        [
            Token(text: "    func ", kind: .keyword),
            Token(text: "hello", kind: .function),
            Token(text: "(name: ", kind: .foreground),
            Token(text: "String", kind: .type),
            Token(text: ") -> ", kind: .foreground),
            Token(text: "String", kind: .type),
            Token(text: " {", kind: .foreground),
        ],
        [
            Token(text: "        return ", kind: .keyword),
            Token(text: "\"Hello, \\(name)!\"", kind: .string),
        ],
        [Token(text: "    }", kind: .foreground)],
        [Token(text: "}", kind: .foreground)],
    ]
}
