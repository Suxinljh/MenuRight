import XCTest

final class FileOperationResultTests: XCTestCase {
    private func success(_ path: String) -> FileOperationItemResult {
        FileOperationItemResult(
            sourceURL: URL(fileURLWithPath: path),
            destinationURL: URL(fileURLWithPath: path),
            status: .success
        )
    }

    private func failure(_ path: String, _ error: FileOperationError) -> FileOperationItemResult {
        FileOperationItemResult(
            sourceURL: URL(fileURLWithPath: path),
            destinationURL: nil,
            status: .failed(error)
        )
    }

    func testAllSucceeded() {
        let results = [success("/a.txt"), success("/b.txt")]
        XCTAssertEqual(FileOperationBatchSummary.summarize(results), .allSucceeded)
        XCTAssertEqual(FileOperationBatchSummary.summarize(results).failureCount, 0)
    }

    func testEmptyBatchIsAllSucceeded() {
        XCTAssertEqual(FileOperationBatchSummary.summarize([]), .allSucceeded)
    }

    func testPartialSuccessReported() {
        let results = [
            success("/a.txt"),
            failure("/b.txt", .destinationExists(URL(fileURLWithPath: "/dest/b.txt"))),
            success("/c.txt"),
        ]
        let summary = FileOperationBatchSummary.summarize(results)
        guard case .partial(let failures) = summary else {
            return XCTFail("expected partial, got \(summary)")
        }
        XCTAssertEqual(failures.map { $0.sourceURL.path }, ["/b.txt"])
        XCTAssertEqual(summary.failureCount, 1)
    }

    func testAllFailedReported() {
        let results = [
            failure("/a.txt", .invalidMove("blocked")),
            failure("/b.txt", .sourceDoesNotExist(URL(fileURLWithPath: "/b.txt"))),
        ]
        let summary = FileOperationBatchSummary.summarize(results)
        guard case .allFailed(let failures) = summary else {
            return XCTFail("expected allFailed, got \(summary)")
        }
        XCTAssertEqual(failures.count, 2)
        XCTAssertEqual(summary.failureCount, 2)
    }

    func testEPERMWrapsToPermissionMessage() {
        let error = FileOperationError.failedError()
        XCTAssertTrue(error.userFacingDescription.contains("permission"))
    }
}

private extension FileOperationError {
    static func failedError() -> FileOperationError {
        .fileSystem(domain: NSPOSIXErrorDomain, code: Int(EPERM), description: "Operation not permitted", underlyingPOSIXCode: EPERM)
    }
}
