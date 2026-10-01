import Foundation

/// Languages the lightweight highlighter understands.
///
/// The list is deliberately closed. Detection never guesses from file contents:
/// a known extension or UTI maps to a language, everything else falls back to
/// `.plainText`, so the preview always renders *something* instead of failing.
///
/// Raw values are stable identifiers used by the settings UI and tests; the
/// user-visible name is `displayName` (product names, intentionally not
/// translated — see `Localization.codePreviewPlainText` for the one entry that
/// does need translating).
enum CodeLanguage: String, CaseIterable, Sendable {
    case swift
    case python
    case javascript
    case typescript
    case html
    case css
    case json
    case yaml
    case markdown
    case shell
    case sql
    case c
    case cpp
    case go
    case rust
    case java
    case plainText

    /// Name shown in the language picker. `plainText` has no product name; the
    /// UI substitutes a localized string for it.
    var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .html: return "HTML"
        case .css: return "CSS"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .markdown: return "Markdown"
        case .shell: return "Shell"
        case .sql: return "SQL"
        case .c: return "C"
        case .cpp: return "C++"
        case .go: return "Go"
        case .rust: return "Rust"
        case .java: return "Java"
        case .plainText: return "Plain Text"
        }
    }

    /// Which tokenizer family handles this language. Kept out of `displayName`
    /// so the highlighter can branch without re-parsing strings.
    var family: Family {
        switch self {
        case .html: return .markup
        case .markdown: return .markdown
        case .plainText: return .plain
        default: return .code
        }
    }

    enum Family: Sendable {
        case code
        case markup
        case markdown
        case plain
    }

    // MARK: - Detection

    /// Extensions are matched case-insensitively, without the leading dot.
    private static let byExtension: [String: CodeLanguage] = [
        "swift": .swift,
        "py": .python, "pyw": .python, "pyi": .python,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .typescript, "mts": .typescript, "cts": .typescript, "tsx": .typescript,
        "html": .html, "htm": .html, "xhtml": .html,
        "css": .css, "scss": .css,
        "json": .json, "jsonc": .json,
        "yml": .yaml, "yaml": .yaml,
        "md": .markdown, "markdown": .markdown,
        "sh": .shell, "bash": .shell, "zsh": .shell, "ksh": .shell, "command": .shell,
        "sql": .sql,
        "c": .c, "h": .c,
        "cpp": .cpp, "cxx": .cpp, "cc": .cpp, "hpp": .cpp, "hxx": .cpp, "hh": .cpp,
        "go": .go,
        "rs": .rust,
        "java": .java,
        "txt": .plainText, "text": .plainText, "log": .plainText,
        "csv": .plainText, "ini": .plainText, "toml": .plainText, "conf": .plainText,
    ]

    /// Extension-less files that are still code. Compared lowercased.
    private static let byFileName: [String: CodeLanguage] = [
        "makefile": .shell, "gnumakefile": .shell,
        "dockerfile": .shell, "containerfile": .shell,
        "cmakelists.txt": .cpp,
        ".gitignore": .shell, ".gitattributes": .shell,
        ".bashrc": .shell, ".zshrc": .shell,
        ".bash_profile": .shell, ".profile": .shell,
        ".env": .shell,
    ]

    /// UTIs of the types macOS hands us for the common code files. Only
    /// system-declared identifiers are listed; anything else is resolved by
    /// extension instead of guessed.
    private static let byTypeIdentifier: [String: CodeLanguage] = [
        "public.swift-source": .swift,
        "public.python-script": .python,
        "public.c-source": .c,
        "public.c-plus-plus-source": .cpp,
        "public.rust-source": .rust,
        "public.shell-script": .shell,
        "public.json": .json,
        "public.html": .html,
        "public.css": .css,
        "public.yaml": .yaml,
        "public.sql": .sql,
        "public.markdown": .markdown,
        "net.daringfireball.markdown": .markdown,
        "com.netscape.javascript-source": .javascript,
    ]

    /// Language for a bare extension ("swift", ".swift", "SWIFT" all work).
    static func detect(fileExtension: String) -> CodeLanguage {
        var value = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix(".") { value.removeFirst() }
        return byExtension[value] ?? .plainText
    }

    /// Language for a file name, preferring the whole name (Makefile,
    /// Dockerfile) over the extension.
    static func detect(fileName: String) -> CodeLanguage {
        let name = (fileName as NSString).lastPathComponent.lowercased()
        if let exact = byFileName[name] { return exact }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return .plainText }
        return detect(fileExtension: ext)
    }

    /// Language for a UTI string, or `nil` when the UTI is not one we know.
    static func detect(contentTypeIdentifier: String) -> CodeLanguage? {
        byTypeIdentifier[contentTypeIdentifier.lowercased()]
    }

    /// Detection order for a real file: extension first (cheap and precise),
    /// then UTI, then plain text. `contentType` is expected to come from the
    /// caller's `UTType` lookup so this file stays Foundation-only.
    static func detect(fileName: String, contentTypeIdentifier: String?) -> CodeLanguage {
        let byName = detect(fileName: fileName)
        if byName != .plainText { return byName }
        if let identifier = contentTypeIdentifier, let byUTI = detect(contentTypeIdentifier: identifier) {
            return byUTI
        }
        return .plainText
    }
}
