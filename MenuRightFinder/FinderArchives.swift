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

    /// Formats offered under 压缩 ▸, in menu order.
    static let compressionFormats: [String] = ["zip", "tar", "gzip", "bzip2"]

    private struct Envelope: Decodable {
        struct Archives: Decodable {
            let enabledFormats: [String]?
        }

        let archives: Archives?
    }

    /// Suffixes the user enabled *and* this build can extract.
    ///
    /// No payload, or an empty enabled set, falls back to "everything this build
    /// supports": a fresh install must not look like a build without extraction.
    static func enabledExtractionSuffixes(from defaults: UserDefaults = FinderFavorites.appGroupDefaults) -> Set<String> {
        guard let data = defaults.data(forKey: storageKey),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return Set(extractionSuffixesByFormat.values.flatMap { $0 }) }

        guard let rawFormats = envelope.archives?.enabledFormats else {
            return Set(extractionSuffixesByFormat.values.flatMap { $0 })
        }
        let suffixes = rawFormats.flatMap { extractionSuffixesByFormat[$0] ?? [] }
        return Set(suffixes)
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
