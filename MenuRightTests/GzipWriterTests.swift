import SWCompression
import XCTest

/// `.tar.gz` before this file: the archive was always written at one fixed
/// effort, so 快速/标准/极限 produced identical bytes. Gzip itself has no level
/// field, so the level lives in the deflate stream — written here through zlib.
final class GzipWriterTests: XCTestCase {
    /// Repetitive on purpose: deflate's levels only differ when there is
    /// something to find, so a random payload would make the levels look equal.
    private func compressiblePayload(_ count: Int) -> Data {
        let line = "MenuRight 自定义压缩 — a line that repeats, so deflate has work to do.\n"
        var data = Data()
        while data.count < count { data.append(Data(line.utf8)) }
        return data
    }

    private func gunzip(_ archive: Data) throws -> Data {
        try GzipArchive.unarchive(archive: archive)
    }

    func testThePayloadSurvivesTheRoundTrip() throws {
        let original = compressiblePayload(200_000)
        let archive = try GzipWriter.archive(original, level: 6)

        XCTAssertEqual(Array(archive.prefix(2)), [0x1f, 0x8b], "gzip magic")
        XCTAssertEqual(archive[2], 0x08, "deflate is the only method we write")
        XCTAssertEqual(try gunzip(archive), original)
    }

    func testTheThreeLevelsActuallyChangeTheBytes() throws {
        let original = compressiblePayload(200_000)
        let fast = try GzipWriter.archive(original, level: 1)
        let standard = try GzipWriter.archive(original, level: 6)
        let maximum = try GzipWriter.archive(original, level: 9)

        XCTAssertLessThan(maximum.count, fast.count, "极限压缩 has to be smaller than 快速压缩")
        XCTAssertLessThanOrEqual(standard.count, fast.count)
        XCTAssertLessThanOrEqual(maximum.count, standard.count)
        for (level, archive) in [(Int32(1), fast), (Int32(6), standard), (Int32(9), maximum)] {
            XCTAssertEqual(try gunzip(archive), original, "level \(level) still has to decode")
        }
    }

    func testTheLevelIsRecordedInTheHeaderHint() throws {
        let original = compressiblePayload(4096)
        XCTAssertEqual(try GzipWriter.archive(original, level: 9)[8], 0x02, "XFL says maximum effort")
        XCTAssertEqual(try GzipWriter.archive(original, level: 1)[8], 0x04, "XFL says fastest")
        XCTAssertEqual(try GzipWriter.archive(original, level: 6)[8], 0x00, "no hint for the default level")
        XCTAssertEqual(try GzipWriter.archive(original, level: 6)[9], 0x03, "OS byte: Unix")
    }

    func testAnEmptyPayloadIsStillAValidGzip() throws {
        let archive = try GzipWriter.archive(Data(), level: 6)
        XCTAssertEqual(try gunzip(archive), Data())
    }
}
