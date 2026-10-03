//
//  SevenZipPasswordSource.swift
//  MenuRight
//
//  7z 密码与 AES. SWCompression refuses encrypted 7-Zip outright
//  (`SevenZipError.encryptionNotSupported`), so both halves of the feature — the
//  "does this file need a password?" probe and reading the decrypted items — go
//  through PLzmaSDK, the same library that writes our encrypted 7z.
//

import Foundation
import PLzmaSDK
import SWCompression

/// 7z encryption as seen from the outside: whether a file needs a password, and
/// whether a given password is the right one.
///
/// Both answers cost one decode at most, and neither writes anything.
enum SevenZipEncryption {
    /// True when the container needs a password to list its items (file names
    /// encrypted) or to decode them (content encrypted).
    ///
    /// Two steps, because 7z has two independent switches: a header-encrypted
    /// archive is the one whose *header* cannot be decoded — SWCompression says
    /// so by name, and that is a password rather than damage — while a
    /// content-only encrypted archive lists fine and hides in the streams.
    static func needsPassword(archiveURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: archiveURL, options: [.mappedIfSafe]) else { return false }
        do {
            _ = try SevenZipContainer.info(container: data)
        } catch {
            if let sevenZipError = error as? SevenZipError, case .encryptionNotSupported = sevenZipError {
                return true
            }
            // Not an archive, or an archive whose coders are beyond us: not a
            // password question. Extraction reports the real problem.
            return false
        }
        guard let decoder = makeDecoder(archiveURL) else { return false }
        defer { try? decoder.abort() }
        guard (try? decoder.open()) == true, let items = try? items(of: decoder) else { return false }
        return items.contains { $0.encrypted }
    }

    /// True when `password` opens `archiveURL`.
    ///
    /// A header-encrypted archive is proven by `open()` alone; a content-only one
    /// needs one decoded stream, and the smallest file is the cheapest proof
    /// (7z folders are solid, so that one decode may pull in its whole block —
    /// still the least we can do to tell a typo from a success).
    static func validates(password: String, archiveURL: URL) -> Bool {
        guard let decoder = makeDecoder(archiveURL) else { return false }
        defer { try? decoder.abort() }
        guard (try? decoder.setPassword(password)) != nil, (try? decoder.open()) == true,
              let items = try? items(of: decoder) else { return false }
        let encrypted = items.filter { $0.encrypted && !$0.isDir }
        guard let probe = encrypted.min(by: { $0.size < $1.size }) else {
            // Header-only encryption: getting this far already proved the key.
            return true
        }
        return (try? decode(probe, with: decoder)) != nil
    }

    static func makeDecoder(_ archiveURL: URL) -> Decoder? {
        guard let path = try? Path(archiveURL.path), let stream = try? InStream(path: path) else { return nil }
        return try? Decoder(stream: stream, fileType: .sevenZ)
    }

    /// `ItemArray` is an indexed collection, not a `Sequence`.
    static func items(of decoder: Decoder) throws -> [Item] {
        let array = try decoder.items()
        var all: [Item] = []
        all.reserveCapacity(Int(array.count))
        for index in 0..<array.count { all.append(try array.item(at: index)) }
        return all
    }

    /// Decodes one item into memory.
    static func decode(_ item: Item, with decoder: Decoder) throws -> Data {
        let name = (try? item.path().description) ?? "?"
        let out = try OutStream()
        let array = try ItemOutStreamArray(items: [item: out])
        guard try decoder.extract(itemsToStreams: array) else {
            throw ArchiveError.readFailed("7z: the decoder returned nothing for “\(name)”")
        }
        return try out.copyContent()
    }
}

/// An AES-encrypted 7z, read through PLzmaSDK.
///
/// A solid 7z cannot be read item by item cheaply — asking for item *n* decodes
/// items 1…n again — so the SDK's one-pass `extract` is the fast path. It is also
/// the dangerous one, because the SDK builds every output path out of the **entry
/// name** (`plzma_extract_callback.cpp`): `Path.normalize` folds repeated
/// separators and nothing else, so an entry called `../../../Library/LaunchAgents/x.plist`
/// really does walk out of the scratch directory. `decideLayout()` therefore sorts
/// an archive into one of two layouts *before* a single byte is written: extract
/// flat — SDK mode `itemsFullPath: false`, where directory entries are skipped and
/// every file lands as `<scratch>/<last path component>`, so no name can steer a
/// write — or decode each item in memory. The in-memory layout costs one decode per
/// item in a solid archive; that is the price of not trusting a suspicious name.
///
/// `members()` still never decodes anything, so the extractor's size guard and name
/// rules run first, and the scratch copy only appears once the plan has accepted
/// the archive.
///
/// Two consequences of the LZMA SDK doing the writing, both documented in the
/// README: directories are not reported (7z has no use for them, readers
/// reconstruct them from the file names), and a symlink entry is written as a plain
/// file holding its target text rather than as a link — the SDK opens an
/// `OutFileStream` for every non-directory item and never creates a symlink, so
/// there is nothing on disk to follow out of the scratch directory.
final class SevenZipPasswordMemberSource: ArchiveMemberSource, ArchiveMemberSourceClosing {
    private let archiveURL: URL
    private let password: String
    private var metadata: [ArchiveMember]?
    private var scratch: URL?
    private var layout: Layout?

    /// How the decrypted items reach `contents(of:)`. Decided once, on first use.
    private enum Layout {
        /// One flat file per entry, all inside the directory.
        case flat(directory: URL)
        /// Nothing written: items are decoded one at a time into memory.
        case inMemory
    }

    init(archiveURL: URL, password: String) {
        self.archiveURL = archiveURL
        self.password = password
    }

    deinit { close() }

    func members() throws -> [ArchiveMember] {
        if let metadata { return metadata }
        let decoder = try Self.open(archiveURL: archiveURL, password: password)
        defer { try? decoder.abort() }
        let members = try SevenZipEncryption.items(of: decoder).enumerated().map { index, item in
            ArchiveMember(
                index: index,
                name: try item.path().description,
                isDirectory: item.isDir,
                // The LZMA SDK exposes no attribute API, so a symlink entry cannot
                // be told apart from a file here; it is written as a plain file
                // (see the type comment). `contents(of:)` still checks the file it
                // reads for a link, as a backstop that costs one lstat.
                isSymbolicLink: false,
                uncompressedSize: Int64(clamping: item.size),
                isDecompressible: true
            )
        }
        metadata = members
        return members
    }

    func contents(of member: ArchiveMember) throws -> Data {
        let resolved = try decideLayout()
        guard case .flat(let root) = resolved else { return try decodeInMemory(member) }
        let candidate = root.appendingPathComponent(Self.leaf(of: member.name))
        if let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw ArchiveError.unsupportedFormat("“\(member.name)”: symbolic links inside an encrypted 7z are not extracted")
        }
        if let data = try? Data(contentsOf: candidate, options: [.mappedIfSafe]) { return data }
        // The decoder named this member differently from the file it wrote (or
        // would not write it): fall back to decoding that one item into memory.
        return try decodeInMemory(member)
    }

    /// Decodes one item into memory, writing nothing.
    private func decodeInMemory(_ member: ArchiveMember) throws -> Data {
        let decoder = try Self.open(archiveURL: archiveURL, password: password)
        defer { try? decoder.abort() }
        let items = try SevenZipEncryption.items(of: decoder)
        var match: Item?
        for item in items where match == nil {
            if try item.path().description == member.name { match = item }
        }
        guard let item = match else {
            throw ArchiveError.readFailed("“\(member.name)”: the decrypted archive does not contain it")
        }
        return try SevenZipEncryption.decode(item, with: decoder)
    }

    /// Removes the scratch copy. Called by the extractor when it is done, and
    /// again by `deinit` as a backstop.
    func close() {
        guard let scratch else { return }
        self.scratch = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Decides — before anything is written — how the decrypted items reach
    /// `contents(of:)`.
    ///
    /// Extracting flat is only safe when it is also unambiguous, so the archive
    /// has to pass three tests first: every entry name is one the extraction
    /// planner would have accepted (`safeRelativePath` — this is what rejects a
    /// traversal payload), the name's leaf is the leaf we will read back, and no two
    /// entries share a leaf. The last test is not cosmetic: a flat extraction puts
    /// every file in one directory, so two entries called `a/x.txt` and `b/x.txt`
    /// would overwrite each other, and the case-insensitive comparison matches what
    /// the scratch volume would do (`A.txt` vs `a.txt`). An archive that fails any
    /// of the three is decoded in memory instead.
    private func decideLayout() throws -> Layout {
        if let layout { return layout }

        let decoder = try Self.open(archiveURL: archiveURL, password: password)
        defer { try? decoder.abort() }
        let items = try SevenZipEncryption.items(of: decoder)

        var leaves = Set<String>()
        var extractable = true
        for item in items where !item.isDir {
            let name = try item.path().description
            guard case .success(let relative) = ArchiveExtractionPlanner.safeRelativePath(name) else {
                extractable = false
                break
            }
            let leaf = Self.leaf(of: name)
            guard !leaf.isEmpty, leaf == Self.leaf(of: relative),
                  leaves.insert(leaf.lowercased()).inserted else {
                extractable = false
                break
            }
        }

        guard extractable else {
            layout = .inMemory
            return .inMemory
        }
        let directory = try extractFlat()
        scratch = directory
        layout = .flat(directory: directory)
        return .flat(directory: directory)
    }

    /// The name the LZMA SDK writes a flat entry under: `itemsFullPath: false`
    /// appends only the entry's last path component to the target directory.
    private static func leaf(of name: String) -> String {
        (name as NSString).lastPathComponent
    }

    private func extractFlat() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuRight-7z", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let decoder = try Self.open(archiveURL: archiveURL, password: password)
            defer { try? decoder.abort() }
            // `itemsFullPath: false` is the whole point: the SDK then skips
            // directory entries and writes `<target>/<last path component>` for every
            // file, so entry names cannot escape `directory`.
            guard try decoder.extract(to: try Path(directory.path), itemsFullPath: false) else {
                throw ArchiveError.readFailed("“\(archiveURL.lastPathComponent)”: the 7z decoder extracted nothing")
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            // A wrong password and a damaged archive surface the same way here
            // (the SDK hands back a failed decode, not a reason). Ask the one
            // question that tells them apart, so the user is not told their file
            // is broken when it is only their password that is.
            if !SevenZipEncryption.validates(password: password, archiveURL: archiveURL) {
                throw ArchiveError.badPassword(archiveURL.lastPathComponent)
            }
            throw error
        }
        return directory
    }

    private static func open(archiveURL: URL, password: String) throws -> Decoder {
        guard let decoder = SevenZipEncryption.makeDecoder(archiveURL) else {
            throw ArchiveError.notAnArchive("“\(archiveURL.lastPathComponent)” is not a readable 7z archive")
        }
        do {
            try decoder.setPassword(password)
            guard try decoder.open() else { throw ArchiveError.badPassword(archiveURL.lastPathComponent) }
        } catch let error as ArchiveError {
            throw error
        } catch {
            throw ArchiveError.badPassword(archiveURL.lastPathComponent)
        }
        return decoder
    }
}
