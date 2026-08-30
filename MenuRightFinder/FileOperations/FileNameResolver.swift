import Foundation

/// Deterministic collision resolution for new files and folders.
///
/// Convention: append " 2", " 3", ... before the extension, or at the end for
/// extensionless names:
///   Untitled.txt -> Untitled 2.txt
///   New Folder   -> New Folder 2
/// Comparisons are case-insensitive to match the default (case-insensitive)
/// APFS/HFS+ filesystems; this never guesses filesystem semantics — it simply
/// errs on the side of uniqueness.
enum FileNameResolver {
    /// Returns a name that does not collide with any name in existingNames.
    static func uniqueName(preferred: String, existing existingNames: [String]) -> String {
        let used = Set(existingNames.map { $0.lowercased() })
        if !used.contains(preferred.lowercased()) { return preferred }

        let (base, ext) = splitExtension(preferred)
        var index = 2
        while true {
            let candidate: String
            if ext.isEmpty {
                candidate = base + " " + String(index)
            } else {
                candidate = base + " " + String(index) + "." + ext
            }
            if !used.contains(candidate.lowercased()) { return candidate }
            index += 1
        }
    }

    /// Splits a file name (not a path) into an extension-preserving base.
    /// Hidden files (leading dot) and extensionless names stay whole.
    static func splitExtension(_ name: String) -> (base: String, ext: String) {
        if name.hasPrefix(".") { return (name, "") }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        if ext.isEmpty || base.isEmpty { return (name, "") }
        return (base, ext)
    }
}
