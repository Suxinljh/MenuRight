import XCTest

/// 分卷压缩: one archive cut into `name.001`, `name.002`, … — the convention
/// 7-Zip, Keka and WinRAR all read, so a split archive written here opens in
/// another tool and a split archive written there opens here.
final class ArchiveVolumeSetTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-volumes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func payload(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }

    func testASmallPayloadStillGetsAFullThreeDigitFirstPart() throws {
        let base = root.appendingPathComponent("small.zip")
        let parts = try ArchiveVolumeSet.write(payload(5), baseURL: base, volumeBytes: 1024, overwrite: false)
        XCTAssertEqual(parts.map(\.lastPathComponent), ["small.zip.001"])
        XCTAssertEqual(try Data(contentsOf: parts[0]), payload(5))
    }

    func testThePayloadIsCutIntoNumberedPartsThatJoinBackExactly() throws {
        let base = root.appendingPathComponent("big.zip")
        let original = payload(3500)

        let parts = try ArchiveVolumeSet.write(original, baseURL: base, volumeBytes: 1000, overwrite: false)

        XCTAssertEqual(parts.map(\.lastPathComponent), ["big.zip.001", "big.zip.002", "big.zip.003", "big.zip.004"])
        for part in parts.dropLast() {
            XCTAssertEqual(try Data(contentsOf: part).count, 1000, "every part but the last is full")
        }
        XCTAssertEqual(try Data(contentsOf: parts[3]).count, 500)

        let joined = parts.reduce(into: Data()) { $0.append((try? Data(contentsOf: $1)) ?? Data()) }
        XCTAssertEqual(joined, original, "concatenating the parts has to reproduce the archive byte for byte")
    }

    func testOnlyTheFirstPartIsMistakenForAnArchive() {
        XCTAssertTrue(ArchiveVolumeSet.isFirstPart(root.appendingPathComponent("a.zip.001")))
        XCTAssertFalse(ArchiveVolumeSet.isFirstPart(root.appendingPathComponent("a.zip")))
        XCTAssertFalse(ArchiveVolumeSet.isFirstPart(root.appendingPathComponent("a.zip.002")))
    }

    func testTheSearchForPartsStopsAtTheFirstGap() throws {
        for name in ["a.zip.001", "a.zip.002", "a.zip.004"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        let found = ArchiveVolumeSet.existingParts(firstPart: root.appendingPathComponent("a.zip.001"))
        XCTAssertEqual(found.map(\.lastPathComponent), ["a.zip.001", "a.zip.002"])
    }

    func testResolvingJoinsThePartsIntoOneTemporaryArchive() throws {
        let base = root.appendingPathComponent("joined.zip")
        let original = payload(2500)
        _ = try ArchiveVolumeSet.write(original, baseURL: base, volumeBytes: 1000, overwrite: false)

        let resolved = try ArchiveVolumeSet.resolve(root.appendingPathComponent("joined.zip.001"))
        defer { resolved.discard() }

        XCTAssertEqual(resolved.parts.count, 3)
        XCTAssertEqual(resolved.sourceFiles.count, 3, "deleting the archive later has to remove every part")
        XCTAssertEqual(try Data(contentsOf: resolved.url), original)
        XCTAssertNotEqual(resolved.url, root.appendingPathComponent("joined.zip.001"))
        let scratch = try XCTUnwrap(resolved.scratchDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path), "the join lives while it is being read")
        resolved.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path), "the join is cleaned up afterwards")
    }

    func testASingleFileIsLeftExactlyWhereItIs() throws {
        let file = root.appendingPathComponent("plain.zip")
        try Data("PK\u{03}\u{04} not really".utf8).write(to: file)

        let resolved = try ArchiveVolumeSet.resolve(file)
        defer { resolved.discard() }

        XCTAssertEqual(resolved.url, file)
        XCTAssertTrue(resolved.parts.isEmpty)
        XCTAssertEqual(resolved.sourceFiles, [file])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "an unsplit file must not be touched")
    }

    func testALoneFirstPartIsNotJoinedButIsStillTheArchive() throws {
        let base = root.appendingPathComponent("one.zip")
        _ = try ArchiveVolumeSet.write(payload(20), baseURL: base, volumeBytes: 1024, overwrite: false)

        let resolved = try ArchiveVolumeSet.resolve(root.appendingPathComponent("one.zip.001"))
        defer { resolved.discard() }

        XCTAssertTrue(resolved.parts.isEmpty)
        XCTAssertEqual(resolved.sourceFiles.map(\.lastPathComponent), ["one.zip.001"])
        XCTAssertEqual(try Data(contentsOf: resolved.url), payload(20))
    }

    func testWritingAgainRemovesTheStaleTailParts() throws {
        let base = root.appendingPathComponent("again.zip")
        _ = try ArchiveVolumeSet.write(payload(3000), baseURL: base, volumeBytes: 1000, overwrite: true)
        XCTAssertEqual(ArchiveVolumeSet.existingParts(firstPart: root.appendingPathComponent("again.zip.001")).count, 3)

        let parts = try ArchiveVolumeSet.write(payload(500), baseURL: base, volumeBytes: 1000, overwrite: true)

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(try Data(contentsOf: parts[0]).count, 500)
        for stale in ["again.zip.002", "again.zip.003"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(stale).path),
                "\(stale) is left over from the bigger write and would corrupt the join"
            )
        }
    }

    /// `partSuffix` grows a fourth digit past 999, a name `existingParts` never
    /// probes for, so a set that big is refused before anything is written.
    func testASetBiggerThanThePartCeilingIsRejected() throws {
        let base = root.appendingPathComponent("huge.zip")
        XCTAssertThrowsError(
            try ArchiveVolumeSet.write(payload(1000), baseURL: base, volumeBytes: 1, overwrite: false)
        ) { error in
            guard case ArchiveError.writeFailed = error else {
                return XCTFail("expected writeFailed, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("huge.zip.001").path),
            "the ceiling is checked before the first part is written"
        )
    }

    func testAnExistingPartIsRefusedInsteadOfClobbered() throws {
        let base = root.appendingPathComponent("taken.zip")
        let sentinel = Data("original".utf8)
        let taken = root.appendingPathComponent("taken.zip.002")
        try sentinel.write(to: taken)

        XCTAssertThrowsError(
            try ArchiveVolumeSet.write(payload(2500), baseURL: base, volumeBytes: 1000, overwrite: false)
        ) { error in
            guard case ArchiveError.conflict = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: taken), sentinel, "the existing part keeps its old contents")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("taken.zip.001").path),
            "the refusal happens before the first part is written"
        )
    }

    /// A failure part-way through must not leave the earlier parts behind: a
    /// lone `.001` plus a stale tail reads as a complete archive. The second
    /// part is a dangling symlink into a missing directory, so the first write
    /// succeeds and the second fails without any pre-existing *file* to detect.
    func testAFailedWriteRemovesThePartsItAlreadyWrote() throws {
        let base = root.appendingPathComponent("rollback.zip")
        let link = root.appendingPathComponent("rollback.zip.002")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: root.appendingPathComponent("missing-dir/rollback.zip.002")
        )

        XCTAssertThrowsError(
            try ArchiveVolumeSet.write(payload(2500), baseURL: base, volumeBytes: 1000, overwrite: false)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("rollback.zip.001").path),
            "the first part is rolled back when a later one fails"
        )
        XCTAssertNoThrow(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            "a path that was already there is not this call's to delete"
        )
    }

    func testANormalSetStillSplitsAndResolves() throws {
        let base = root.appendingPathComponent("normal.zip")
        let original = payload(2500)

        let parts = try ArchiveVolumeSet.write(original, baseURL: base, volumeBytes: 1000, overwrite: false)

        XCTAssertEqual(parts.map(\.lastPathComponent), ["normal.zip.001", "normal.zip.002", "normal.zip.003"])
        let resolved = try ArchiveVolumeSet.resolve(root.appendingPathComponent("normal.zip.001"))
        defer { resolved.discard() }
        XCTAssertEqual(try Data(contentsOf: resolved.url), original)
    }
}
