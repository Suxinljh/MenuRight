import Foundation

/// An sRGB colour parsed from a hex string.
///
/// Kept platform-agnostic (no SwiftUI import) so the catalog and its parsing
/// are unit-testable; the UI layer maps it to `Color`.
struct RGBColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Accepts "#RRGGBB", "RRGGBB", or the same with a leading "#" and any
    /// casing. Returns nil for anything else instead of guessing.
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.red = Double((number & 0xFF0000) >> 16) / 255.0
        self.green = Double((number & 0x00FF00) >> 8) / 255.0
        self.blue = Double(number & 0x0000FF) / 255.0
    }

    static let black = RGBColor(red: 0, green: 0, blue: 0)
    static let white = RGBColor(red: 1, green: 1, blue: 1)
}

/// One themable role in the preview.
enum CodeThemeToken: String, CaseIterable, Sendable {
    case background
    case foreground
    case comment
    case keyword
    case string
    case number
    case type
    case function
}

/// Whether a theme suits a light or dark appearance. `.dynamic` (the "follow
/// system" entry) resolves to a concrete theme at render time.
enum CodeThemeAppearance: String, Equatable, Sendable {
    case light
    case dark
    case dynamic
}

/// A highlight palette. Names are product names (Monokai, Dracula, …) and are
/// intentionally not translated.
struct CodeTheme: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let appearance: CodeThemeAppearance
    private let background: String
    private let foreground: String
    private let comment: String
    private let keyword: String
    private let string: String
    private let number: String
    private let type: String
    private let function: String

    init(
        id: String,
        name: String,
        appearance: CodeThemeAppearance,
        background: String,
        foreground: String,
        comment: String,
        keyword: String,
        string: String,
        number: String,
        type: String,
        function: String
    ) {
        self.id = id
        self.name = name
        self.appearance = appearance
        self.background = background
        self.foreground = foreground
        self.comment = comment
        self.keyword = keyword
        self.string = string
        self.number = number
        self.type = type
        self.function = function
    }

    func hex(for token: CodeThemeToken) -> String {
        switch token {
        case .background: return background
        case .foreground: return foreground
        case .comment: return comment
        case .keyword: return keyword
        case .string: return string
        case .number: return number
        case .type: return type
        case .function: return function
        }
    }

    /// Parsed colour, falling back to black/white by appearance when a hex
    /// literal is malformed. A unit test asserts the catalog parses cleanly, so
    /// the fallback is a safety net rather than a normal path.
    func rgb(for token: CodeThemeToken) -> RGBColor {
        if let parsed = RGBColor(hex: hex(for: token)) { return parsed }
        return appearance == .light ? .black : .white
    }
}

/// Built-in palettes. Six fixed themes plus the "follow system" entry, which
/// resolves to Xcode Light or Xcode Dark.
enum CodeThemeCatalog {
    static let systemID = "system"

    static let system = CodeTheme(
        id: systemID,
        name: "Follow System",
        appearance: .dynamic,
        background: "#FFFFFF",
        foreground: "#000000",
        comment: "#5D6C79",
        keyword: "#AD3DA4",
        string: "#D12F1B",
        number: "#1C00CF",
        type: "#0B4F79",
        function: "#326D74"
    )

    static let xcodeLight = CodeTheme(
        id: "xcode-light",
        name: "Xcode Light",
        appearance: .light,
        background: "#FFFFFF",
        foreground: "#000000",
        comment: "#5D6C79",
        keyword: "#AD3DA4",
        string: "#D12F1B",
        number: "#1C00CF",
        type: "#0B4F79",
        function: "#326D74"
    )

    static let xcodeDark = CodeTheme(
        id: "xcode-dark",
        name: "Xcode Dark",
        appearance: .dark,
        background: "#292A30",
        foreground: "#FFFFFF",
        comment: "#6C7986",
        keyword: "#FC5FA3",
        string: "#FC6A5D",
        number: "#D0BF69",
        type: "#5DD8FF",
        function: "#41A1C0"
    )

    static let solarizedLight = CodeTheme(
        id: "solarized-light",
        name: "Solarized Light",
        appearance: .light,
        background: "#FDF6E3",
        foreground: "#657B83",
        comment: "#93A1A1",
        keyword: "#859900",
        string: "#2AA198",
        number: "#D33682",
        type: "#B58900",
        function: "#268BD2"
    )

    static let solarizedDark = CodeTheme(
        id: "solarized-dark",
        name: "Solarized Dark",
        appearance: .dark,
        background: "#002B36",
        foreground: "#839496",
        comment: "#586E75",
        keyword: "#859900",
        string: "#2AA198",
        number: "#D33682",
        type: "#B58900",
        function: "#268BD2"
    )

    static let monokai = CodeTheme(
        id: "monokai",
        name: "Monokai",
        appearance: .dark,
        background: "#272822",
        foreground: "#F8F8F2",
        comment: "#75715E",
        keyword: "#F92672",
        string: "#E6DB74",
        number: "#AE81FF",
        type: "#66D9EF",
        function: "#A6E22E"
    )

    static let dracula = CodeTheme(
        id: "dracula",
        name: "Dracula",
        appearance: .dark,
        background: "#282A36",
        foreground: "#F8F8F2",
        comment: "#6272A4",
        keyword: "#FF79C6",
        string: "#F1FA8C",
        number: "#BD93F9",
        type: "#8BE9FD",
        function: "#50FA7B"
    )

    static let oneDark = CodeTheme(
        id: "one-dark",
        name: "One Dark",
        appearance: .dark,
        background: "#282C34",
        foreground: "#ABB2BF",
        comment: "#5C6370",
        keyword: "#C678DD",
        string: "#98C379",
        number: "#D19A66",
        type: "#E5C07B",
        function: "#61AFEF"
    )

    static let githubLight = CodeTheme(
        id: "github-light",
        name: "GitHub Light",
        appearance: .light,
        background: "#FFFFFF",
        foreground: "#24292E",
        comment: "#6A737D",
        keyword: "#D73A49",
        string: "#032F62",
        number: "#005CC5",
        type: "#6F42C1",
        function: "#6F42C1"
    )

    /// Display order in the picker: "follow system" first, then light, then dark.
    static let all: [CodeTheme] = [
        system,
        xcodeLight,
        solarizedLight,
        githubLight,
        xcodeDark,
        solarizedDark,
        monokai,
        dracula,
        oneDark,
    ]

    static func theme(id: String) -> CodeTheme {
        all.first { $0.id == id } ?? system
    }

    /// Resolves a stored theme id to a concrete palette for an appearance.
    static func resolvedTheme(id: String, prefersDark: Bool) -> CodeTheme {
        let theme = self.theme(id: id)
        guard theme.appearance == .dynamic else { return theme }
        return prefersDark ? xcodeDark : xcodeLight
    }
}

struct CodeThemeSettings: Codable, Equatable, Sendable {
    var themeID: String
    var fontSize: Double
    /// nil means "system monospaced font".
    var fontName: String?
    var showsLineNumbers: Bool

    static let fontSizeRange: ClosedRange<Double> = 9...32
    static let defaultFontSize: Double = 13

    init(
        themeID: String = CodeThemeCatalog.systemID,
        fontSize: Double = CodeThemeSettings.defaultFontSize,
        fontName: String? = nil,
        showsLineNumbers: Bool = true
    ) {
        self.themeID = themeID
        self.fontSize = fontSize
        self.fontName = fontName
        self.showsLineNumbers = showsLineNumbers
    }

    enum CodingKeys: String, CodingKey {
        case themeID, fontSize, fontName, showsLineNumbers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        themeID = try container.decodeOr(String.self, .themeID, CodeThemeCatalog.systemID)
        fontSize = try container.decodeOr(Double.self, .fontSize, CodeThemeSettings.defaultFontSize)
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName)
        showsLineNumbers = try container.decodeOr(Bool.self, .showsLineNumbers, true)
    }

    func normalized() -> CodeThemeSettings {
        var copy = self
        if CodeThemeCatalog.all.first(where: { $0.id == copy.themeID }) == nil {
            copy.themeID = CodeThemeCatalog.systemID
        }
        copy.fontSize = min(max(fontSize, CodeThemeSettings.fontSizeRange.lowerBound), CodeThemeSettings.fontSizeRange.upperBound)
        if let name = copy.fontName, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.fontName = nil
        }
        return copy
    }

    /// Concrete theme for the current selection and appearance.
    func resolvedTheme(prefersDark: Bool) -> CodeTheme {
        CodeThemeCatalog.resolvedTheme(id: themeID, prefersDark: prefersDark)
    }
}
