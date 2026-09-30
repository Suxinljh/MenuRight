import Foundation

/// Which backend opens an archive, and what a name/extension implies.
///
/// Detection prefers **magic bytes** over the file extension: a `.zip` that is
/// really a 7-Zip container (or a `.tar.gz` that is really a plain gzip) must be
/// opened as what it *is*, and a renamed file must still work. The extension is
/// only the fallback when the magic is inconclusive.
enum ArchiveFormats {
    /// Image of the format's leading bytes.
    private static let signatures: [(format: ArchiveFormat, bytes: [UInt8], offset: Int)] = [
        (.zip, [0x50, 0x4b, 0x03, 0x04], 0),
        (.zip, [0x50, 0x4b, 0x05, 0x06], 0),   // empty archive
        (.sevenZip, [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c], 0),
        (.gzip, [0x1f, 0x8b], 0),
        (.bzip2, [0x42, 0x5a, 0x68], 0),
        (.xz, [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00], 0),
    ]

    /// Detects the container format, or nil when nothing matches.
    ///
    /// TAR has no leading magic — its `ustar` marker sits at offset 257 — so it
    /// is checked last and only when the extension says TAR too.
    static func detect(at url: URL) -> ArchiveFormat? {
        let formatFromName = format(forFileName: url.lastPathComponent)
        let head = (try? Data(contentsOf: url, options: [.mappedIfSafe]))?.prefix(512).map { $0 } ?? []

        for signature in signatures where head.count >= signature.offset + signature.bytes.count {
            let slice = Array(head[signature.offset..<(signature.offset + signature.bytes.count)])
            if slice == signature.bytes { return signature.format }
        }

        if head.count >= 262 {
            let marker = String(decoding: head[257..<262], as: UTF8.self)
            if marker == "ustar" { return .tar }
        }

        // `.tgz`/`.tbz2`/`.txz` and friends map to their outer compression.
        if let formatFromName, formatFromName != .rar { return formatFromName }
        return nil
    }

    /// Maps a file name's suffix to a format, including the compound
    /// `tar.gz` / `tar.bz2` / `tar.xz` spellings.
    static func format(forFileName name: String) -> ArchiveFormat? {
        let lower = name.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return .gzip }
        if lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz2") { return .bzip2 }
        if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz") { return .xz }
        let extensionName = (lower as NSString).pathExtension
        guard !extensionName.isEmpty else { return nil }
        return ArchiveFormat.allCases.first { $0.pathExtensions.contains(extensionName) }
    }

    /// True when the file name describes a tar that has been compressed as a
    /// whole (`.tar.gz`, `.tgz`, …), so extraction has to peel one layer first.
    static func isCompressedTar(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz")
            || lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz2")
            || lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz")
    }

    /// Name a single-member archive expands to: `notes.txt.gz` → `notes.txt`,
    /// `archive.tgz` → `archive.tar`.
    static func expandedName(forFileName name: String, format: ArchiveFormat) -> String {
        let lower = name.lowercased()
        if isCompressedTar(name) {
            let base = (name as NSString).deletingPathExtension
            return base.isEmpty ? "archive.tar" : "\(base).tar"
        }
        for suffix in format.pathExtensions where lower.hasSuffix(".\(suffix)") {
            let trimmed = String(name.dropLast(suffix.count + 1))
            return trimmed.isEmpty ? name : trimmed
        }
        return name
    }
}
