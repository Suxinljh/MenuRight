import Foundation

/// Lexer configuration for one language.
///
/// The highlighter is one generic scanner driven by this profile, plus three
/// dedicated modes (`markup`, `markdown`, `plain`). Keeping the differences in
/// data instead of separate tokenizers is what makes the engine small enough to
/// ship inside a Quick Look extension later.
struct CodeSyntaxProfile: Sendable {
    /// Prefixes that start a comment running to the end of the line.
    var lineCommentPrefixes: [String] = []
    /// Block comment delimiters, when the language has them.
    var blockComment: (open: String, close: String)?
    /// Single-line string delimiters.
    var stringDelimiters: [String] = []
    /// Delimiters that may span lines (Swift/Python `"""`, JS backtick,
    /// Markdown fences). Checked before `stringDelimiters`, longest first.
    var multilineStringDelimiters: [String] = []
    var keywords: Set<String> = []
    /// Type names that are not keywords (`Int`, `String`, `Vec`, …).
    var builtinTypes: Set<String> = []
    /// SQL is case-insensitive; the rest are not.
    var caseInsensitiveKeywords = false
    /// Heuristic: an identifier starting with an uppercase letter is a type
    /// (`Greeting`, `URLSession`). Off for languages where that misleads.
    var uppercaseIdentifierIsType = false
    /// Treat `name:` as a label — CSS properties, YAML keys, JSON keys.
    var marksLabelBeforeColon = false
    /// Treat `$name` as a reference (Shell).
    var marksVariables = false
    /// Treat `@media`-style at-rules as keywords (CSS).
    var marksAtRules = false
    /// Identifiers may contain `-`, and may start with `-` (CSS `font-size`,
    /// `--accent`).
    var allowsHyphenInIdentifiers = false
    /// Colour literals like `#3b82f6` are numbers (CSS).
    var marksHexColors = false
}

extension CodeSyntaxProfile {
    static func profile(for language: CodeLanguage) -> CodeSyntaxProfile {
        switch language {
        case .swift:
            return CodeSyntaxProfile(
                lineCommentPrefixes: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\""],
                multilineStringDelimiters: ["\"\"\""],
                keywords: Keywords.swift,
                builtinTypes: Types.swift,
                uppercaseIdentifierIsType: true
            )
        case .python:
            return CodeSyntaxProfile(
                lineCommentPrefixes: ["#"],
                stringDelimiters: ["\"", "'"],
                multilineStringDelimiters: ["\"\"\"", "'''"],
                keywords: Keywords.python,
                builtinTypes: Types.python,
                uppercaseIdentifierIsType: true
            )
        case .javascript:
            return CodeSyntaxProfile(
                lineCommentPrefixes: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                multilineStringDelimiters: ["`"],
                keywords: Keywords.javascript,
                builtinTypes: Types.javascript,
                uppercaseIdentifierIsType: true
            )
        case .typescript:
            return CodeSyntaxProfile(
                lineCommentPrefixes: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                multilineStringDelimiters: ["`"],
                keywords: Keywords.javascript.union(Keywords.typescript),
                builtinTypes: Types.javascript.union(Types.typescript),
                uppercaseIdentifierIsType: true
            )
        case .css:
            return CodeSyntaxProfile(
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                keywords: Keywords.css,
                marksLabelBeforeColon: true,
                marksAtRules: true,
                allowsHyphenInIdentifiers: true,
                marksHexColors: true
            )
        case .json:
            return CodeSyntaxProfile(
                stringDelimiters: ["\""],
                keywords: Keywords.json,
                marksLabelBeforeColon: true
            )
        case .yaml:
            return CodeSyntaxProfile(
                lineCommentPrefixes: ["#"],
                stringDelimiters: ["\"", "'"],
                keywords: Keywords.yaml,
                marksLabelBeforeColon: true
            )
        case .shell:
            return CodeSyntaxProfile(
                lineCommentPrefixes: ["#"],
                stringDelimiters: ["\"", "'"],
                keywords: Keywords.shell,
                marksVariables: true
            )
        case .sql:
            return CodeSyntaxProfile(
                lineCommentPrefixes: ["--"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["'", "\""],
                keywords: Keywords.sql,
                builtinTypes: Types.sql,
                caseInsensitiveKeywords: true
            )
        case .c:
            return CodeSyntaxProfile(
                lineCommentPrefixes: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                keywords: Keywords.c,
                builtinTypes: Types.c,
                uppercaseIdentifierIsType: true
            )
        case .cpp:
            return CodeSyntaxProfile(
                lineCommentPrefixes: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                keywords: Keywords.c.union(Keywords.cpp),
                builtinTypes: Types.c.union(Types.cpp),
                uppercaseIdentifierIsType: true
            )
        case .go:
            return CodeSyntaxProfile(
                lineCommentPrefixes: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                multilineStringDelimiters: ["`"],
                keywords: Keywords.go,
                builtinTypes: Types.go,
                uppercaseIdentifierIsType: true
            )
        case .rust:
            return CodeSyntaxProfile(
                lineCommentPrefixes: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\""],
                keywords: Keywords.rust,
                builtinTypes: Types.rust,
                uppercaseIdentifierIsType: true
            )
        case .java:
            return CodeSyntaxProfile(
                lineCommentPrefixes: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                keywords: Keywords.java,
                builtinTypes: Types.java,
                uppercaseIdentifierIsType: true
            )
        case .html, .markdown, .plainText:
            // Handled by dedicated modes; an empty profile keeps the generic
            // scanner's behaviour defined if it is ever reached.
            return CodeSyntaxProfile()
        }
    }
}

// MARK: - Keyword tables

/// Declaration and control-flow words. Deliberately not exhaustive: the
/// preview needs the words that carry visual structure, not a compiler grammar.
private enum Keywords {
    static let swift: Set<String> = [
        "associatedtype", "actor", "any", "as", "async", "await", "break", "case", "catch",
        "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
        "fallthrough", "false", "fileprivate", "final", "for", "func", "guard", "if", "import",
        "in", "indirect", "init", "inout", "internal", "is", "let", "mutating", "nil",
        "nonmutating", "open", "operator", "override", "private", "protocol", "public",
        "repeat", "required", "rethrows", "return", "self", "some", "static", "struct",
        "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias",
        "var", "where", "while",
    ]
    static let python: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def",
        "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if",
        "import", "in", "is", "lambda", "match", "None", "nonlocal", "not", "or", "pass",
        "raise", "return", "self", "True", "try", "while", "with", "yield",
    ]
    static let javascript: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "false", "finally", "for",
        "from", "function", "get", "if", "import", "in", "instanceof", "let", "new", "null",
        "of", "return", "set", "static", "super", "switch", "this", "throw", "true", "try",
        "typeof", "undefined", "var", "void", "while", "with", "yield",
    ]
    static let typescript: Set<String> = [
        "abstract", "as", "declare", "enum", "implements", "infer", "interface", "is", "keyof",
        "namespace", "private", "protected", "public", "readonly", "satisfies", "type",
    ]
    static let css: Set<String> = [
        "and", "auto", "calc", "charset", "font-face", "from", "hsl", "important", "import",
        "inherit", "initial", "keyframes", "media", "none", "not", "only", "or", "print",
        "rgb", "rgba", "screen", "supports", "to", "unset", "url", "var",
    ]
    static let json: Set<String> = ["true", "false", "null"]
    static let yaml: Set<String> = ["false", "no", "null", "off", "on", "true", "yes"]
    static let shell: Set<String> = [
        "alias", "case", "cd", "do", "done", "echo", "elif", "else", "esac", "exit", "export",
        "false", "fi", "for", "function", "if", "in", "local", "printf", "readonly", "return",
        "set", "shift", "source", "then", "trap", "true", "unset", "wait", "while",
    ]
    static let sql: Set<String> = [
        "all", "alter", "and", "as", "asc", "begin", "between", "by", "case", "commit",
        "constraint", "count", "create", "default", "delete", "desc", "distinct", "drop",
        "else", "end", "exists", "foreign", "from", "group", "having", "in", "index", "inner",
        "insert", "into", "is", "join", "key", "left", "like", "limit", "not", "null", "offset",
        "on", "or", "order", "outer", "primary", "references", "right", "rollback", "select",
        "set", "table", "then", "true", "false", "union", "unique", "update", "values", "view",
        "when", "where", "with",
    ]
    static let c: Set<String> = [
        "auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern",
        "for", "goto", "if", "inline", "register", "restrict", "return", "sizeof", "static",
        "struct", "switch", "typedef", "union", "volatile", "while",
    ]
    static let cpp: Set<String> = [
        "catch", "class", "constexpr", "const_cast", "delete", "dynamic_cast", "explicit",
        "false", "friend", "mutable", "namespace", "new", "noexcept", "nullptr", "operator",
        "override", "private", "protected", "public", "reinterpret_cast", "static_cast",
        "template", "this", "throw", "true", "try", "typename", "using", "virtual",
    ]
    static let go: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else",
        "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
        "package", "range", "return", "select", "struct", "switch", "type", "var",
    ]
    static let rust: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
        "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
        "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
        "trait", "true", "type", "unsafe", "use", "where", "while",
    ]
    static let java: Set<String> = [
        "abstract", "assert", "break", "case", "catch", "class", "continue", "default", "do",
        "else", "enum", "extends", "false", "final", "finally", "for", "if", "implements",
        "import", "instanceof", "interface", "native", "new", "null", "package", "private",
        "protected", "public", "record", "return", "sealed", "static", "strictfp", "super",
        "switch", "synchronized", "this", "throw", "throws", "transient", "true", "try", "var",
        "volatile", "while", "yield",
    ]
}

/// Primitive and common library types, coloured as `.type` rather than
/// `.keyword`.
private enum Types {
    static let swift: Set<String> = [
        "Any", "AnyObject", "Array", "Bool", "Character", "CGFloat", "Data", "Date",
        "Dictionary", "Double", "Error", "Float", "Int", "Int8", "Int16", "Int32", "Int64",
        "Optional", "Result", "Set", "String", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "URL", "Void",
    ]
    static let python: Set<String> = [
        "bool", "bytes", "dict", "Exception", "float", "int", "list", "object", "set", "str",
        "tuple", "ValueError",
    ]
    static let javascript: Set<String> = [
        "Array", "BigInt", "Boolean", "Date", "Error", "Map", "Number", "Object", "Promise",
        "RegExp", "Set", "String", "Symbol",
    ]
    static let typescript: Set<String> = [
        "any", "bigint", "boolean", "never", "number", "object", "string", "symbol", "unknown",
        "void",
    ]
    static let sql: Set<String> = [
        "bigint", "boolean", "date", "decimal", "integer", "jsonb", "numeric", "serial", "text",
        "timestamp", "uuid", "varchar",
    ]
    static let c: Set<String> = [
        "bool", "char", "double", "FILE", "float", "int", "int32_t", "int64_t", "long", "short",
        "size_t", "uint8_t", "uint32_t", "unsigned", "void",
    ]
    static let cpp: Set<String> = [
        "map", "shared_ptr", "std", "string", "unique_ptr", "unordered_map", "vector",
    ]
    static let go: Set<String> = [
        "any", "bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int",
        "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16",
        "uint32", "uint64",
    ]
    static let rust: Set<String> = [
        "Box", "HashMap", "Option", "Result", "String", "Vec", "bool", "char", "f32", "f64",
        "i8", "i16", "i32", "i64", "i128", "isize", "str", "u8", "u16", "u32", "u64", "u128",
        "usize",
    ]
    static let java: Set<String> = [
        "ArrayList", "Boolean", "Byte", "Character", "Double", "Exception", "Float", "HashMap",
        "Integer", "List", "Long", "Map", "Object", "Optional", "RuntimeException", "Set",
        "Short", "Stream", "String", "boolean", "byte", "char", "double", "float", "int",
        "long", "short", "void",
    ]
}
