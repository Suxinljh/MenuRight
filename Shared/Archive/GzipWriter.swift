//
//  GzipWriter.swift
//  MenuRight
//
//  压缩模式 for `.tar.gz`. SWCompression's `GzipArchive.archive` takes no level:
//  it emits the payload as one static-Huffman block, so a `.tar.gz` written here
//  used to ignore 快速/标准/极限 entirely. gzip is DEFLATE plus a 10-byte header
//  and an 8-byte trailer, and zlib is already linked for the ZIP writer, so the
//  level is ours to choose.
//

import Foundation
import zlib

/// Writes a gzip member around an already-built TAR image.
///
/// Level 1/6/9 comes straight from `ArchiveCompressionMode.deflateLevel`, which
/// is the same knob the ZIP writer uses — "compress harder" now means the same
/// thing for both.
enum GzipWriter {
    /// - Parameter modificationTime: written as MTIME, so the archive is a
    ///   function of its input rather than of the clock (`nil` = 0, "no time
    ///   stamp", which is also what keeps two runs byte-identical).
    static func archive(_ data: Data, level: Int32, modificationTime: Date? = nil) throws -> Data {
        // An empty payload still needs a *valid* DEFLATE stream; zlib produces
        // the two-byte one (`03 00`) for empty input, but `rawDeflate` short-
        // circuits to `Data()` for it, so that case is spelled out.
        let deflated: Data
        if data.isEmpty {
            deflated = Data([0x03, 0x00])
        } else if let compressed = ZipWriter.rawDeflate(data, level: level) {
            deflated = compressed
        } else {
            throw ArchiveError.writeFailed("gzip: zlib refused to compress the TAR payload")
        }

        var out = Data()
        // ID1 ID2, CM = 8 (DEFLATE), FLG = 0 (no name, no comment, no extra).
        out.append(contentsOf: [0x1f, 0x8b, 0x08, 0x00])
        out.append(littleEndian(UInt32(truncatingIfNeeded: Int64(modificationTime?.timeIntervalSince1970 ?? 0))))
        // XFL: 2 = maximum compression, 4 = fastest algorithm, 0 = "no comment".
        // OS = 3 (Unix), which is what every macOS writer emits.
        out.append(contentsOf: [level >= 9 ? 0x02 : (level <= 2 ? 0x04 : 0x00), 0x03])
        out.append(deflated)
        out.append(littleEndian(ZipWriter.crc32(data)))
        out.append(littleEndian(UInt32(truncatingIfNeeded: data.count)))
        return out
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
