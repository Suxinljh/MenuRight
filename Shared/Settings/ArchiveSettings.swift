import Foundation

/// An archive format the extraction backend can be asked to handle.
///
/// `rar` is listed so the pane can state plainly that it is unsupported instead
/// of leaving the user guessing why the menu never shows it (decision D5-R1:
/// no pure-Swift, MIT-licensed RAR implementation exists).
enum ArchiveFormat: String, Codable, CaseIterable, Sendable {
    case zip
    case sevenZip
    case tar
    case gzip
    case bzip2
    case xz
    case rar

    var isSupported: Bool { self != .rar }

    var titleKey: StringKey {
        switch self {
        case .zip: return .archiveFormatZip
        case .sevenZip: return .archiveFormatSevenZip
        case .tar: return .archiveFormatTar
        case .gzip: return .archiveFormatGZip
        case .bzip2: return .archiveFormatBZip2
        case .xz: return .archiveFormatXZ
        case .rar: return .archiveFormatRAR
        }
    }

    /// File-name suffixes used to match a selection. ZIP-family matching is
    /// case-insensitive at the call site.
    var pathExtensions: [String] {
        switch self {
        case .zip: return ["zip"]
        case .sevenZip: return ["7z"]
        case .tar: return ["tar"]
        case .gzip: return ["gz", "tgz"]
        case .bzip2: return ["bz2", "tbz2"]
        case .xz: return ["xz", "txz"]
        case .rar: return ["rar"]
        }
    }
}

enum ArchiveDestination: String, Codable, CaseIterable, Sendable {
    case askEachTime
    case sameFolder
    case customFolder

    var titleKey: StringKey {
        switch self {
        case .askEachTime: return .archiveDestinationAsk
        case .sameFolder: return .archiveDestinationSameFolder
        case .customFolder: return .archiveDestinationCustom
        }
    }
}

enum ArchiveConflictPolicy: String, Codable, CaseIterable, Sendable {
    case keepBoth
    case skip
    case overwrite

    var titleKey: StringKey {
        switch self {
        case .keepBoth: return .archiveConflictKeepBoth
        case .skip: return .archiveConflictSkip
        case .overwrite: return .archiveConflictOverwrite
        }
    }
}

/// Extraction policy persisted by the app and (from P9) read by the extractor.
///
/// The defaults mirror the product decisions: never overwrite silently, never
/// delete the user's archive, and cap the payload because the planned backend
/// takes the whole archive as `Data`.
struct ArchiveSettings: Codable, Equatable, Sendable {
    var enabledFormats: Set<ArchiveFormat>
    var destination: ArchiveDestination
    var customDestinationPath: String?
    var conflictPolicy: ArchiveConflictPolicy
    var deletesArchiveAfterExtraction: Bool
    var skipsMetadataEntries: Bool
    var sizeLimitMB: Int

    static let sizeLimitRange: ClosedRange<Int> = 1...8192
    static let defaultSizeLimitMB = 1024

    init(
        enabledFormats: Set<ArchiveFormat> = Set(ArchiveFormat.allCases.filter(\.isSupported)),
        destination: ArchiveDestination = .askEachTime,
        customDestinationPath: String? = nil,
        conflictPolicy: ArchiveConflictPolicy = .keepBoth,
        deletesArchiveAfterExtraction: Bool = false,
        skipsMetadataEntries: Bool = true,
        sizeLimitMB: Int = ArchiveSettings.defaultSizeLimitMB
    ) {
        self.enabledFormats = enabledFormats
        self.destination = destination
        self.customDestinationPath = customDestinationPath
        self.conflictPolicy = conflictPolicy
        self.deletesArchiveAfterExtraction = deletesArchiveAfterExtraction
        self.skipsMetadataEntries = skipsMetadataEntries
        self.sizeLimitMB = sizeLimitMB
    }

    enum CodingKeys: String, CodingKey {
        case enabledFormats
        case destination
        case customDestinationPath
        case conflictPolicy
        case deletesArchiveAfterExtraction
        case skipsMetadataEntries
        case sizeLimitMB
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let supported = ArchiveFormat.allCases.filter(\.isSupported)
        let rawFormats = try container.decodeOr([String].self, .enabledFormats, supported.map(\.rawValue))
        enabledFormats = Set(rawFormats.compactMap(ArchiveFormat.init(rawValue:)))
        let rawDestination = try container.decodeOr(String.self, .destination, ArchiveDestination.askEachTime.rawValue)
        destination = ArchiveDestination(rawValue: rawDestination) ?? .askEachTime
        customDestinationPath = try container.decodeIfPresent(String.self, forKey: .customDestinationPath)
        let rawConflict = try container.decodeOr(String.self, .conflictPolicy, ArchiveConflictPolicy.keepBoth.rawValue)
        conflictPolicy = ArchiveConflictPolicy(rawValue: rawConflict) ?? .keepBoth
        deletesArchiveAfterExtraction = try container.decodeOr(Bool.self, .deletesArchiveAfterExtraction, false)
        skipsMetadataEntries = try container.decodeOr(Bool.self, .skipsMetadataEntries, true)
        sizeLimitMB = try container.decodeOr(Int.self, .sizeLimitMB, ArchiveSettings.defaultSizeLimitMB)
    }

    func normalized() -> ArchiveSettings {
        var copy = self
        // RAR can never be enabled, and a stored payload from a build with a
        // different format list may name formats that no longer exist.
        copy.enabledFormats = enabledFormats.intersection(Set(ArchiveFormat.allCases.filter(\.isSupported)))
        copy.sizeLimitMB = min(max(sizeLimitMB, ArchiveSettings.sizeLimitRange.lowerBound), ArchiveSettings.sizeLimitRange.upperBound)
        if let path = copy.customDestinationPath,
           path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.customDestinationPath = nil
        }
        return copy
    }

    func isEnabled(_ format: ArchiveFormat) -> Bool {
        format.isSupported && enabledFormats.contains(format)
    }

    /// Formats offered in the menu, in catalog order.
    var activeFormats: [ArchiveFormat] {
        ArchiveFormat.allCases.filter { isEnabled($0) }
    }
}

extension ArchiveSettings {
    /// What the size-limit field should do with the text the user typed.
    ///
    /// The rule lives next to `sizeLimitRange` on purpose: the field and
    /// `normalized()` must never disagree about the bound, and the decoder's
    /// silent clamp is exactly what the field has to explain out loud instead.
    ///
    /// Pure, so it is testable without a UI — the pane can only be checked by
    /// hand in Finder-facing terms.
    enum SizeLimitEntry: Equatable {
        /// Inside `sizeLimitRange`; store it as typed.
        case accepted(Int)
        /// Above the maximum. `stored` is the clamped value to save, so the
        /// caller can both keep the setting valid and name the real limit.
        case aboveMaximum(stored: Int)
        /// Below the minimum, same contract as above.
        case belowMinimum(stored: Int)
        /// Empty, not a number, or a mix the user probably did not mean.
        case unusable
    }

    /// Interprets text typed into the 体积上限 field.
    ///
    /// Thousands separators and a trailing unit are tolerated so the value this
    /// same row displays while unfocused (`1,024 MB`) can be selected, retyped
    /// over, or pasted straight back in.
    static func interpretSizeLimit(_ text: String) -> SizeLimitEntry {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for unit in ["MB", "mb", "Mb", "mB", "兆"] {
            cleaned = cleaned.replacingOccurrences(of: unit, with: "")
        }
        cleaned = cleaned
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: " ", with: "")

        // ASCII digits only. `Character.isNumber` is also true for Arabic-Indic
        // and full-width digits, but `Int(_:)` cannot parse those, and treating
        // them as an overflowing number (the branch below) would report ١٢ as
        // "above the maximum" — a wrong explanation for a wrong reason.
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.isASCII && $0.isNumber }) else { return .unusable }
        // An ASCII digit run too long for `Int` is certainly past the maximum,
        // and saying "not a number" there would be wrong.
        guard let value = Int(cleaned) else {
            return .aboveMaximum(stored: sizeLimitRange.upperBound)
        }

        if value < sizeLimitRange.lowerBound { return .belowMinimum(stored: sizeLimitRange.lowerBound) }
        if value > sizeLimitRange.upperBound { return .aboveMaximum(stored: sizeLimitRange.upperBound) }
        return .accepted(value)
    }
}
