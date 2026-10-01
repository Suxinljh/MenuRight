import Foundation

/// One coloured run of preview text.
struct CodeHighlightToken: Equatable, Sendable {
    let text: String
    let kind: CodeThemeToken
}

/// One source line, already split into coloured runs.
///
/// Invariant (asserted by `CodeHighlightTests`): `tokens.map(\.text).joined()`
/// equals the original line exactly. A preview may colour the wrong thing, but
/// it must never drop or reorder code.
struct CodeHighlightedLine: Equatable, Sendable {
    let tokens: [CodeHighlightToken]

    var text: String { tokens.map(\.text).joined() }
}

/// The project's one syntax highlighter.
///
/// It is deliberately small and dependency-free: one generic scanner driven by
/// `CodeSyntaxProfile`, plus dedicated modes for HTML, Markdown and plain text.
/// The same engine renders the settings preview today and is meant to render
/// Quick Look previews in P8, so both surfaces can never drift apart.
///
/// It is a *preview* highlighter, not a parser: regex-free, single pass per
/// line, with carry-over state for block comments and multi-line strings. It
/// imports Foundation only — no AppKit, no SwiftUI — so it stays usable inside
/// an app extension.
enum CodeHighlighter {
    /// Highlights a whole document. Line endings are normalized and one
    /// trailing empty line is dropped, so a file ending in "\n" does not show a
    /// phantom last line.
    static func highlight(_ source: String, language: CodeLanguage) -> [CodeHighlightedLine] {
        let lines = splitLines(source)
        switch language.family {
        case .plain:
            return lines.map { line in
                CodeHighlightedLine(tokens: line.isEmpty ? [] : [CodeHighlightToken(text: line, kind: .foreground)])
            }
        case .markup:
            return highlightMarkup(lines)
        case .markdown:
            return highlightMarkdown(lines)
        case .code:
            return highlightCode(lines, profile: .profile(for: language))
        }
    }

    /// Convenience for callers that only have a file name: the language is
    /// resolved with `CodeLanguage.detect(fileName:)`.
    static func highlight(_ source: String, fileName: String) -> [CodeHighlightedLine] {
        highlight(source, language: CodeLanguage.detect(fileName: fileName))
    }

    /// Normalizes CRLF/CR to LF, splits, and drops a single trailing empty
    /// line. Exposed because the Quick Look side will want the same line model.
    static func splitLines(_ source: String) -> [String] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }

    /// True when every language in the catalog has a working profile. Used by
    /// tests as a guard against a language being added without a tokenizer.
    static func supports(_ language: CodeLanguage) -> Bool {
        switch language.family {
        case .plain, .markup, .markdown: return true
        case .code:
            let profile = CodeSyntaxProfile.profile(for: language)
            return !(profile.keywords.isEmpty && profile.stringDelimiters.isEmpty && profile.lineCommentPrefixes.isEmpty)
        }
    }
}

// MARK: - Generic scanner

private extension CodeHighlighter {
    /// Appends text, merging into the previous token when the kind matches so
    /// the rendered `AttributedString` stays short.
    static func append(_ text: String, _ kind: CodeThemeToken, to tokens: inout [CodeHighlightToken]) {
        guard !text.isEmpty else { return }
        if let last = tokens.last, last.kind == kind {
            tokens[tokens.count - 1] = CodeHighlightToken(text: last.text + text, kind: kind)
        } else {
            tokens.append(CodeHighlightToken(text: text, kind: kind))
        }
    }

    static func highlightCode(_ lines: [String], profile: CodeSyntaxProfile) -> [CodeHighlightedLine] {
        var blockCommentEnd: String?
        var multilineStringEnd: String?
        let multilineDelimiters = profile.multilineStringDelimiters.sorted { $0.count > $1.count }

        var output: [CodeHighlightedLine] = []

        for line in lines {
            var tokens: [CodeHighlightToken] = []
            var index = line.startIndex

            while index < line.endIndex {
                let rest = line[index...]

                // Carry-over state always wins: a line inside a block comment or
                // a multi-line string is consumed before any other rule.
                if let end = blockCommentEnd {
                    if let range = rest.range(of: end) {
                        append(String(rest[rest.startIndex..<range.upperBound]), .comment, to: &tokens)
                        index = range.upperBound
                        blockCommentEnd = nil
                    } else {
                        append(String(rest), .comment, to: &tokens)
                        index = line.endIndex
                    }
                    continue
                }

                if let end = multilineStringEnd {
                    if let range = rest.range(of: end) {
                        append(String(rest[rest.startIndex..<range.upperBound]), .string, to: &tokens)
                        index = range.upperBound
                        multilineStringEnd = nil
                    } else {
                        append(String(rest), .string, to: &tokens)
                        index = line.endIndex
                    }
                    continue
                }

                let character = rest.first!

                if character.isWhitespace {
                    let end = rest.firstIndex { !$0.isWhitespace } ?? line.endIndex
                    append(String(rest[rest.startIndex..<end]), .foreground, to: &tokens)
                    index = end
                    continue
                }

                if let comment = profile.blockComment, rest.hasPrefix(comment.open) {
                    let body = rest.dropFirst(comment.open.count)
                    if let range = body.range(of: comment.close) {
                        append(String(rest[rest.startIndex..<range.upperBound]), .comment, to: &tokens)
                        index = range.upperBound
                    } else {
                        append(String(rest), .comment, to: &tokens)
                        index = line.endIndex
                        blockCommentEnd = comment.close
                    }
                    continue
                }

                if profile.lineCommentPrefixes.contains(where: { rest.hasPrefix($0) }) {
                    append(String(rest), .comment, to: &tokens)
                    index = line.endIndex
                    continue
                }

                if let delimiter = multilineDelimiters.first(where: { rest.hasPrefix($0) }) {
                    let body = rest.dropFirst(delimiter.count)
                    if let range = body.range(of: delimiter) {
                        append(String(rest[rest.startIndex..<range.upperBound]), .string, to: &tokens)
                        index = range.upperBound
                    } else {
                        append(String(rest), .string, to: &tokens)
                        index = line.endIndex
                        multilineStringEnd = delimiter
                    }
                    continue
                }

                if let delimiter = profile.stringDelimiters.first(where: { rest.hasPrefix($0) }) {
                    let value = scanString(rest, delimiter: delimiter)
                    let next = nextNonSpaceCharacter(in: line, from: value.endIndex)
                    let kind: CodeThemeToken = (profile.marksLabelBeforeColon && next == ":") ? .type : .string
                    append(String(value), kind, to: &tokens)
                    index = value.endIndex
                    continue
                }

                if profile.marksVariables, character == "$" {
                    if let variable = scanVariable(rest) {
                        append(String(variable), .type, to: &tokens)
                        index = variable.endIndex
                        continue
                    }
                }

                if profile.marksHexColors, character == "#", let hex = scanHexColor(rest) {
                    append(String(hex), .number, to: &tokens)
                    index = hex.endIndex
                    continue
                }

                if character.isNumber {
                    let number = scanNumber(rest)
                    append(String(number), .number, to: &tokens)
                    index = number.endIndex
                    continue
                }

                if isIdentifierStart(character) || (profile.allowsHyphenInIdentifiers && startsHyphenatedIdentifier(rest)) {
                    let word = scanIdentifier(rest, profile: profile)
                    var kind = classify(String(word), in: line, after: word.endIndex, profile: profile)
                    if profile.marksAtRules,
                       previousNonSpaceCharacter(in: line, before: word.startIndex) == "@" {
                        kind = .keyword
                    }
                    append(String(word), kind, to: &tokens)
                    index = word.endIndex
                    continue
                }

                append(String(character), .foreground, to: &tokens)
                index = rest.index(after: rest.startIndex)
            }

            output.append(CodeHighlightedLine(tokens: tokens))
        }

        return output
    }

    static func classify(
        _ word: String,
        in line: String,
        after end: String.Index,
        profile: CodeSyntaxProfile
    ) -> CodeThemeToken {
        let lookup = profile.caseInsensitiveKeywords ? word.lowercased() : word
        if profile.keywords.contains(lookup) { return .keyword }
        if profile.builtinTypes.contains(lookup) { return .type }

        let next = nextNonSpaceCharacter(in: line, from: end)
        if profile.marksLabelBeforeColon, next == ":" { return .type }
        if next == "(" { return .function }
        if profile.uppercaseIdentifierIsType, let first = word.first, first.isUppercase { return .type }
        return .foreground
    }

    // MARK: Character scanning

    static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    static func startsHyphenatedIdentifier(_ text: Substring) -> Bool {
        guard text.first == "-" else { return false }
        let next = text.index(after: text.startIndex)
        guard next < text.endIndex else { return false }
        return text[next].isLetter || text[next] == "-"
    }

    static func scanIdentifier(_ text: Substring, profile: CodeSyntaxProfile) -> Substring {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let isBody = character.isLetter || character.isNumber || character == "_"
                || (profile.allowsHyphenInIdentifiers && character == "-")
            if !isBody { break }
            index = text.index(after: index)
        }
        return text[..<index]
    }

    /// Scans a quoted string, honouring backslash escapes, and stops at the end
    /// of the line when the closing delimiter is missing.
    static func scanString(_ text: Substring, delimiter: String) -> Substring {
        var index = text.index(text.startIndex, offsetBy: delimiter.count)
        while index < text.endIndex {
            if text[index] == "\\" {
                index = text.index(after: index)
                if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            if text[index...].hasPrefix(delimiter) {
                return text[..<text.index(index, offsetBy: delimiter.count)]
            }
            index = text.index(after: index)
        }
        return text
    }

    /// `$NAME` / `${NAME}` — Shell only.
    static func scanVariable(_ text: Substring) -> Substring? {
        var index = text.index(after: text.startIndex)
        if index < text.endIndex, text[index] == "{" {
            let afterBrace = text.index(after: index)
            guard let close = text[afterBrace...].firstIndex(of: "}") else { return nil }
            return text[..<text.index(after: close)]
        }
        while index < text.endIndex, text[index].isLetter || text[index].isNumber || text[index] == "_" {
            index = text.index(after: index)
        }
        let start = text.index(after: text.startIndex)
        return index > start ? text[..<index] : nil
    }

    /// Numbers, including `0x`/`0b`/`0o` forms, underscores, an optional
    /// fractional part and exponent, and a trailing unit/type suffix.
    ///
    /// The fractional part is only taken when a digit follows the dot, so a
    /// Swift range like `1...5` stays intact instead of becoming one "number".
    static func scanNumber(_ text: Substring) -> Substring {
        var index = text.startIndex

        if text[index] == "0" {
            let next = text.index(after: index)
            if next < text.endIndex, "xXbBoO".contains(text[next]) {
                index = text.index(after: next)
                while index < text.endIndex, text[index].isHexDigit || text[index] == "_" {
                    index = text.index(after: index)
                }
                return text[..<index]
            }
        }

        while index < text.endIndex, text[index].isNumber || text[index] == "_" {
            index = text.index(after: index)
        }

        if index < text.endIndex, text[index] == "." {
            let afterDot = text.index(after: index)
            if afterDot < text.endIndex, text[afterDot].isNumber {
                index = afterDot
                while index < text.endIndex, text[index].isNumber || text[index] == "_" {
                    index = text.index(after: index)
                }
            }
        }

        if index < text.endIndex, "eE".contains(text[index]) {
            var probe = text.index(after: index)
            if probe < text.endIndex, "+-".contains(text[probe]) { probe = text.index(after: probe) }
            if probe < text.endIndex, text[probe].isNumber {
                index = probe
                while index < text.endIndex, text[index].isNumber || text[index] == "_" {
                    index = text.index(after: index)
                }
            }
        }

        while index < text.endIndex, "fFdDuUlLiI".contains(text[index]) {
            index = text.index(after: index)
        }

        return text[..<index]
    }

    /// `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA` — CSS only.
    static func scanHexColor(_ text: Substring) -> Substring? {
        var index = text.index(after: text.startIndex)
        var count = 0
        while index < text.endIndex, text[index].isHexDigit, count < 8 {
            index = text.index(after: index)
            count += 1
        }
        guard count == 3 || count == 4 || count == 6 || count == 8 else { return nil }
        return text[..<index]
    }

    static func nextNonSpaceCharacter(in line: String, from index: String.Index) -> Character? {
        var probe = index
        while probe < line.endIndex {
            let character = line[probe]
            if !character.isWhitespace { return character }
            probe = line.index(after: probe)
        }
        return nil
    }

    static func previousNonSpaceCharacter(in line: String, before index: String.Index) -> Character? {
        var probe = index
        while probe > line.startIndex {
            probe = line.index(before: probe)
            let character = line[probe]
            if !character.isWhitespace { return character }
        }
        return nil
    }
}

// MARK: - HTML

private extension CodeHighlighter {
    static func highlightMarkup(_ lines: [String]) -> [CodeHighlightedLine] {
        var inComment = false
        var output: [CodeHighlightedLine] = []

        for line in lines {
            var tokens: [CodeHighlightToken] = []
            var index = line.startIndex

            while index < line.endIndex {
                let rest = line[index...]

                if inComment {
                    if let range = rest.range(of: "-->") {
                        append(String(rest[rest.startIndex..<range.upperBound]), .comment, to: &tokens)
                        index = range.upperBound
                        inComment = false
                    } else {
                        append(String(rest), .comment, to: &tokens)
                        index = line.endIndex
                    }
                    continue
                }

                if rest.hasPrefix("<!--") {
                    if let range = rest.range(of: "-->") {
                        append(String(rest[rest.startIndex..<range.upperBound]), .comment, to: &tokens)
                        index = range.upperBound
                    } else {
                        append(String(rest), .comment, to: &tokens)
                        index = line.endIndex
                        inComment = true
                    }
                    continue
                }

                if rest.hasPrefix("<") {
                    // A tag is scanned up to ">" on the same line; a tag split
                    // across lines degrades to plain text rather than guessing.
                    let end = rest.range(of: ">")?.upperBound ?? line.endIndex
                    appendMarkupTag(rest[rest.startIndex..<end], to: &tokens)
                    index = end
                    continue
                }

                let end = rest.firstIndex(of: "<") ?? line.endIndex
                append(String(rest[rest.startIndex..<end]), .foreground, to: &tokens)
                index = end
            }

            output.append(CodeHighlightedLine(tokens: tokens))
        }

        return output
    }

    /// `<tag attr="value">` — punctuation stays foreground, the tag name is a
    /// keyword, attribute names are types, values are strings.
    static func appendMarkupTag(_ tag: Substring, to tokens: inout [CodeHighlightToken]) {
        var index = tag.startIndex

        var punctuationEnd = index
        while punctuationEnd < tag.endIndex, tag[punctuationEnd] == "<" || tag[punctuationEnd] == "/" {
            punctuationEnd = tag.index(after: punctuationEnd)
        }
        append(String(tag[index..<punctuationEnd]), .foreground, to: &tokens)
        index = punctuationEnd

        let name = scanIdentifier(tag[index...], profile: CodeSyntaxProfile())
        append(String(name), .keyword, to: &tokens)
        index = name.endIndex

        while index < tag.endIndex {
            let character = tag[index]
            if character.isWhitespace {
                let end = tag[index...].firstIndex { !$0.isWhitespace } ?? tag.endIndex
                append(String(tag[index..<end]), .foreground, to: &tokens)
                index = end
            } else if character == "\"" || character == "'" {
                let value = scanString(tag[index...], delimiter: String(character))
                append(String(value), .string, to: &tokens)
                index = value.endIndex
            } else if isIdentifierStart(character) || character == "-" || character == ":" {
                let attribute = scanAttributeName(tag[index...])
                append(String(attribute), .type, to: &tokens)
                index = attribute.endIndex
            } else {
                append(String(character), .foreground, to: &tokens)
                index = tag.index(after: index)
            }
        }
    }

    /// Attribute names may contain `-` and `:` (`data-id`, `xml:lang`).
    static func scanAttributeName(_ text: Substring) -> Substring {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character.isLetter || character.isNumber || character == "_"
                || character == "-" || character == ":" else { break }
            index = text.index(after: index)
        }
        return text[..<index]
    }
}

// MARK: - Markdown

private extension CodeHighlighter {
    static func highlightMarkdown(_ lines: [String]) -> [CodeHighlightedLine] {
        var inFence = false
        var output: [CodeHighlightedLine] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")

            if inFence {
                output.append(
                    CodeHighlightedLine(tokens: [CodeHighlightToken(text: line, kind: isFence ? .keyword : .string)])
                )
                if isFence { inFence = false }
                continue
            }

            if isFence {
                output.append(CodeHighlightedLine(tokens: [CodeHighlightToken(text: line, kind: .keyword)]))
                inFence = true
                continue
            }

            output.append(CodeHighlightedLine(tokens: markdownLineTokens(line)))
        }

        return output
    }

    static func markdownLineTokens(_ line: String) -> [CodeHighlightToken] {
        var tokens: [CodeHighlightToken] = []
        let contentStart = line.firstIndex { !$0.isWhitespace } ?? line.endIndex

        if contentStart > line.startIndex {
            append(String(line[line.startIndex..<contentStart]), .foreground, to: &tokens)
        }

        var index = contentStart
        if index < line.endIndex {
            let rest = line[index...]
            if rest.hasPrefix("#") {
                append(String(rest), .keyword, to: &tokens)
                return tokens
            }
            if rest.hasPrefix(">") {
                append(String(rest), .comment, to: &tokens)
                return tokens
            }
            if let markerEnd = listMarkerEnd(rest) {
                append(String(rest[rest.startIndex..<markerEnd]), .keyword, to: &tokens)
                index = markerEnd
            }
        }

        while index < line.endIndex {
            let rest = line[index...]

            if rest.hasPrefix("`") {
                let body = rest.dropFirst()
                if let close = body.firstIndex(of: "`") {
                    let end = body.index(after: close)
                    append(String(rest[rest.startIndex..<end]), .string, to: &tokens)
                    index = end
                    continue
                }
            }

            if rest.hasPrefix("**") || rest.hasPrefix("__") {
                let marker = String(rest.prefix(2))
                let body = rest.dropFirst(2)
                if let range = body.range(of: marker) {
                    append(String(rest[rest.startIndex..<range.upperBound]), .function, to: &tokens)
                    index = range.upperBound
                    continue
                }
            }

            if rest.hasPrefix("*") || rest.hasPrefix("_") {
                let marker = rest.first!
                let body = rest.dropFirst()
                if let close = body.firstIndex(of: marker), close > body.startIndex {
                    let end = body.index(after: close)
                    append(String(rest[rest.startIndex..<end]), .function, to: &tokens)
                    index = end
                    continue
                }
            }

            if rest.hasPrefix("["), let closeBracket = rest.firstIndex(of: "]") {
                let afterBracket = rest.index(after: closeBracket)
                if afterBracket < rest.endIndex, rest[afterBracket] == "(",
                   let closeParen = rest[afterBracket...].firstIndex(of: ")") {
                    append(String(rest[rest.startIndex...closeBracket]), .function, to: &tokens)
                    append(String(rest[afterBracket...closeParen]), .type, to: &tokens)
                    index = rest.index(after: closeParen)
                    continue
                }
            }

            append(String(rest.first!), .foreground, to: &tokens)
            index = rest.index(after: rest.startIndex)
        }

        return tokens
    }

    /// `- `, `* `, `+ `, `1. ` at the start of a line.
    static func listMarkerEnd(_ text: Substring) -> String.Index? {
        guard let first = text.first else { return nil }

        if "-*+".contains(first) {
            let after = text.index(after: text.startIndex)
            guard after < text.endIndex, text[after] == " " else { return nil }
            return text.index(after: after)
        }

        if first.isNumber {
            var index = text.startIndex
            while index < text.endIndex, text[index].isNumber { index = text.index(after: index) }
            guard index < text.endIndex, text[index] == "." else { return nil }
            let after = text.index(after: index)
            guard after < text.endIndex, text[after] == " " else { return nil }
            return text.index(after: after)
        }

        return nil
    }
}
