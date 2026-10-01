import Foundation

/// What the archive actions can do with the current Finder selection (P9).
struct FinderArchiveSelection: Equatable {
    static let none = FinderArchiveSelection(archives: [], compressible: [])

    /// Selected items that can be extracted.
    let archives: [URL]
    /// Every selected item (what a compress action would take).
    let compressible: [URL]

    /// 解压 is only offered when **every** selected item is an archive: a mixed
    /// selection would make "extract" silently ignore half of it.
    var canExtract: Bool { !archives.isEmpty && archives.count == compressible.count }
    var canCompress: Bool { !compressible.isEmpty }
}

/// Which selected items are archives, and which formats this build can handle.
///
/// Another deliberately tiny decoder: the appex must not link `ArchiveSettings`
/// (which drags the whole settings tree in). The suffix tables below are pinned
/// against `ArchiveFormat.pathExtensions` by a unit test, so the two sides cannot
/// drift silently.
enum FinderArchives {
    static let storageKey = "xin.ljhsu.MenuRight.settings"

    /// `ArchiveFormat` raw value → suffixes this build can **extract**.
    /// Stage 2 added the SWCompression backends.
    static let extractionSuffixesByFormat: [String: [String]] = [
        "zip": ["zip"],
        "sevenZip": ["7z"],
        "tar": ["tar"],
        "gzip": ["gz", "tgz"],
        "bzip2": ["bz2", "tbz2"],
        "xz": ["xz", "txz"],
    ]

    /// `ArchiveFormat` raw value → suffixes this build can **create**, in menu
    /// order. Compressed variants always wrap a TAR, which is what
    /// `.tar.gz`/`.tar.bz2` mean.
    static let compressionSuffixesByFormat: [String: [String]] = [
        "zip": ["zip"],
        "tar": ["tar"],
        "gzip": ["tar.gz"],
        "bzip2": ["tar.bz2"],
    ]

    /// Formats offered under 压缩 ▸, in menu order, when nothing is configured.
    static let compressionFormats: [String] = ["zip", "tar", "gzip", "bzip2"]

    /// What the **second** 解压 item should offer, from the app's 解压位置
    /// setting. The first item (解压到当前文件夹) is a literal promise and is
    /// never affected by the setting.
    enum Destination: Equatable {
        /// 每次询问 — and a 指定文件夹 whose path was never chosen: ask with a folder panel.
        case ask
        /// 指定文件夹…: extract straight into this folder, no question.
        case folder(URL)
        /// 压缩包所在文件夹: the setting repeats what the first item already does,
        /// so the second item is dropped rather than duplicating it.
        case duplicatesFirstItem
    }

    private struct Envelope: Decodable {
        struct Archives: Decodable {
            let enabledFormats: [String]?
            let destination: String?
            let customDestinationPath: String?
        }

        let archives: Archives?
    }

    /// The App-Group payload, or nil when nothing has been written yet.
    private static func archives(from defaults: UserDefaults) -> Envelope.Archives? {
        guard let data = defaults.data(forKey: storageKey),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }
        return envelope.archives
    }

    /// Suffixes the user enabled *and* this build can extract.
    ///
    /// No payload, or an empty enabled set, falls back to "everything this build
    /// supports": a fresh install must not look like a build without extraction.
    static func enabledExtractionSuffixes(from defaults: UserDefaults = FinderFavorites.appGroupDefaults) -> Set<String> {
        guard let rawFormats = archives(from: defaults)?.enabledFormats else {
            return Set(extractionSuffixesByFormat.values.flatMap { $0 })
        }
        let suffixes = rawFormats.flatMap { extractionSuffixesByFormat[$0] ?? [] }
        return Set(suffixes)
    }

    /// 解压位置, resolved to what the second 解压 item should do.
    ///
    /// Unknown or missing values fall back to `.ask`, which is what every build
    /// before this setting did — a payload from another version must never
    /// silently redirect an extraction somewhere the user did not choose.
    static func destination(from defaults: UserDefaults = FinderFavorites.appGroupDefaults) -> Destination {
        guard let payload = archives(from: defaults) else { return .ask }
        switch payload.destination {
        case "sameFolder":
            return .duplicatesFirstItem
        case "customFolder":
            let path = (payload.customDestinationPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? .ask : .folder(URL(fileURLWithPath: path))
        default:
            return .ask
        }
    }

    /// Formats offered under 压缩 ▸: 允许的压缩格式 intersected with what this
    /// build can write, in menu order.
    ///
    /// An absent or empty selection means "everything", so a fresh install (or a
    /// payload with every box unticked) never looks like a build that cannot
    /// compress. The list can come back empty only when the user enabled
    /// formats that are read-only — then 压缩 ▸ still offers 自定义压缩….
    static func enabledCompressionFormats(from defaults: UserDefaults = FinderFavorites.appGroupDefaults) -> [String] {
        guard let rawFormats = archives(from: defaults)?.enabledFormats, !rawFormats.isEmpty else {
            return compressionFormats
        }
        let enabled = Set(rawFormats)
        return compressionFormats.filter { enabled.contains($0) }
    }

    /// Splits a selection into "archives I can extract" and "everything" (which
    /// a compress action can take).
    static func classify(
        _ urls: [URL],
        defaults: UserDefaults = FinderFavorites.appGroupDefaults
    ) -> FinderArchiveSelection {
        guard !urls.isEmpty else { return .none }
        let suffixes = enabledExtractionSuffixes(from: defaults)
        let archives = urls.filter { suffixes.contains($0.pathExtension.lowercased()) }
        return FinderArchiveSelection(archives: archives, compressible: urls)
    }

    /// Suffix used for a compression format, so the extension can name the menu
    /// item without asking the app.
    static func compressionSuffix(forFormat format: String) -> String? {
        compressionSuffixesByFormat[format]?.first
    }
}
