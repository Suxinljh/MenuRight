//
//  SevenZipWriter.swift
//  MenuRight
//
//  7z 写入. The container comes from PLzmaSDK (MIT), which wraps the LZMA SDK's
//  LZMA/LZMA2 encoders — writing the container by hand would mean writing and
//  debugging an LZMA2 encoder, which is not this app's job.
//

import Foundation
import PLzmaSDK

/// Builds a 7z archive in memory from a tree the caller already walked.
///
/// **Files only, and deliberately so.** `libplzma` decides what goes into the
/// archive from a path's own kind: a directory argument is walked exactly one
/// level and only its non-directory children are added
/// (`EncoderImpl::processAddedPaths`), and a directory entry is never written.
/// Directories therefore exist in the archive only as the prefixes of file
/// names, which is what every 7z reader reconstructs anyway. The one visible
/// consequence: an *empty* folder cannot be represented, so it is dropped here
/// while the ZIP and TAR writers keep it. The caller's own walking is still what
/// picks the files, so symlinks stay skipped and the size limit stays enforced.
enum SevenZipWriter {
    /// One file to store, at `archivePath` (relative, `/`-separated).
    struct Entry {
        let archivePath: String
        let url: URL
    }

    /// `mode` is the same fast/standard/maximum the other writers take; the LZMA
    /// SDK's own scale is 0...9.
    static func level(for mode: ArchiveCompressionMode) -> UInt8 {
        switch mode {
        case .fast: return 1
        case .standard: return 6
        case .maximum: return 9
        }
    }

    /// Compresses `entries` into a 7z image. The image is assembled in memory,
    /// like every other writer here, so a failure leaves nothing behind.
    ///
    /// LZMA2 rather than LZMA1: it is what 7-Zip itself defaults to for 7z, and
    /// our own reader (SWCompression) opens it.
    ///
    /// - Parameters:
    ///   - password: 加密压缩 for 7z. Non-nil and non-empty switches on AES-256 —
    ///     the strong encryption, unlike ZIP's traditional ZipCrypto.
    ///   - solid: 固实压缩. One compressed block for the whole archive (the LZMA
    ///     SDK's default, and what 7-Zip does) versus one block per file. Solid
    ///     is smaller and much slower to pull a single file out of.
    ///   - encryptsFileNames: 加密文件名. Encrypts the archive *header* too, so
    ///     the item names are unreadable without the password — opening the
    ///     archive then needs it before anything can be listed. Only meaningful
    ///     together with `password`.
    static func archive(
        entries: [Entry],
        mode: ArchiveCompressionMode,
        password: String? = nil,
        solid: Bool = true,
        encryptsFileNames: Bool = false,
        control: ArchiveOperationControl? = nil,
        onEntry: ((Int) -> Void)? = nil
    ) throws -> Data {
        do {
            let stream = try OutStream()
            let encoder = try Encoder(stream: stream, fileType: .sevenZ, method: .LZMA2)
            try encoder.setCompressionLevel(level(for: mode))
            try encoder.setShouldCreateSolidArchive(solid)

            let trimmed = password?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                try encoder.setPassword(trimmed)
                try encoder.setShouldEncryptContent(true)
                if encryptsFileNames {
                    try encoder.setShouldEncryptHeader(true)
                }
            }

            for (index, entry) in entries.enumerated() {
                try control?.checkpoint()
                try encoder.add(
                    path: try Path(entry.url.path),
                    mode: .default,
                    archivePath: try Path(entry.archivePath)
                )
                onEntry?(index + 1)
            }

            // An empty selection would produce a 7z with no items at all; the
            // caller rejects that earlier, so this is only a belt-and-braces
            // guard against handing the encoder a stream it refuses.
            guard !entries.isEmpty else {
                throw ArchiveError.writeFailed("7z: nothing to store")
            }

            guard try encoder.open() else {
                throw ArchiveError.writeFailed("7z: the encoder could not open the archive")
            }
            guard try encoder.compress() else {
                throw ArchiveError.writeFailed("7z: the encoder did not finish")
            }
            try encoder.abort()
            return try stream.copyContent()
        } catch let error as ArchiveError {
            throw error
        } catch {
            // PLzmaSDK throws `Exception`, whose description carries libplzma's
            // own reason ("Can't add path: …, The path doesn't exist or is not
            // readable."). Keep it: it is the only diagnostic there is.
            throw ArchiveError.writeFailed("7z: \(error)")
        }
    }
}
