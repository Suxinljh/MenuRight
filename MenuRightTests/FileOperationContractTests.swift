import XCTest

/// Wire-contract stability for `fileOperation`. Both the app and the extension
/// are built from this source, but the *encoded shape* is what actually travels
/// over the socket, so it is asserted explicitly.
final class FileOperationContractTests: XCTestCase {
    func testCreateFileRequestRoundTrip() throws {
        let request = FileOperationContract.Request(
            kind: .createFile,
            args: FileOperationContract.OperationArgs(
                directory: "/Users/foo/Desktop",
                name: "Untitled.txt",
                contentsBase64: Data("{}".utf8).base64EncodedString()
            ),
            clientRequestId: "cid-1"
        )
        let payload = try XCTUnwrap(request.encodedForIPC())
        let decoded = try XCTUnwrap(FileOperationContract.Request.decode(fromIPC: payload))
        XCTAssertEqual(decoded, request)
    }

    func testMoveRequestRoundTrip() throws {
        let request = FileOperationContract.Request(
            kind: .moveItems,
            args: FileOperationContract.OperationArgs(
                sourcePaths: ["/a/1.txt", "/a/2.txt"],
                destinationDirectory: "/b"
            )
        )
        let payload = try XCTUnwrap(request.encodedForIPC())
        XCTAssertEqual(FileOperationContract.Request.decode(fromIPC: payload), request)
    }

    func testSuccessAndBatchResponsesRoundTrip() throws {
        let success = FileOperationContract.Response.success(createdPath: "/tmp/x.txt")
        XCTAssertEqual(
            FileOperationContract.Response.decode(fromIPC: try XCTUnwrap(success.encodedForIPC())),
            success
        )

        let batch = FileOperationContract.Response.batchSuccess(items: [
            .init(sourcePath: "/a/1.txt", destinationPath: "/b/1.txt", success: true),
            .init(sourcePath: "/a/2.txt", destinationPath: "/b/2.txt", success: false, errorCode: .nameCollision, message: "exists"),
        ])
        XCTAssertEqual(
            FileOperationContract.Response.decode(fromIPC: try XCTUnwrap(batch.encodedForIPC())),
            batch
        )
    }

    func testFailureResponseRoundTrip() throws {
        let failure = FileOperationContract.Response.failure(
            code: .staleBookmarkNeedsReauthorization,
            message: "needs reauth"
        )
        let decoded = try XCTUnwrap(
            FileOperationContract.Response.decode(fromIPC: try XCTUnwrap(failure.encodedForIPC()))
        )
        XCTAssertEqual(decoded, failure)
    }

    /// Error codes are part of the contract: renaming or reshuffling one would
    /// silently break the extension's UI branching.
    func testErrorCodeRawValuesAreStable() {
        let expected: [FileOperationContract.ErrorCode: String] = [
            .invalidRequest: "invalid_request",
            .notAllowed: "not_allowed",
            .notAuthorized: "not_authorized",
            .bookmarkResolveFailed: "bookmark_resolve_failed",
            .staleBookmarkNeedsReauthorization: "stale_bookmark_needs_reauthorization",
            .accessStartFailed: "access_start_failed",
            .pathOutsideAuthorizedScope: "path_outside_authorized_scope",
            .sourceDoesNotExist: "source_does_not_exist",
            .invalidDestination: "invalid_destination",
            .nameCollision: "name_collision",
            .filesystemPermissionDenied: "filesystem_permission_denied",
            .filesystemError: "filesystem_error",
            .operationFailed: "operation_failed",
        ]
        for (code, raw) in expected {
            XCTAssertEqual(code.rawValue, raw)
        }
        XCTAssertEqual(FileOperationContract.ErrorCode.allCasesIfAvailable.count, expected.count)
    }

    func testUnknownErrorCodeDecodesToNil() {
        let json = #"{"failure":{"code":"totally_new_code","message":"x"}}"#
        XCTAssertNil(FileOperationContract.Response.decode(fromIPC: json))
    }

    func testUnknownMethodKindDecodesToNil() {
        let json = #"{"kind":"deleteEverything","args":{}}"#
        XCTAssertNil(FileOperationContract.Request.decode(fromIPC: json))
    }

    func testGarbagePayloadDecodesToNil() {
        XCTAssertNil(FileOperationContract.Request.decode(fromIPC: nil))
        XCTAssertNil(FileOperationContract.Request.decode(fromIPC: "{"))
    }
}

private extension FileOperationContract.ErrorCode {
    /// `ErrorCode` is not `CaseIterable` in production (it is a wire enum); this
    /// test-only list keeps the raw-value table exhaustive.
    static var allCasesIfAvailable: [FileOperationContract.ErrorCode] {
        [
            .invalidRequest, .notAllowed, .notAuthorized, .bookmarkResolveFailed,
            .staleBookmarkNeedsReauthorization, .accessStartFailed,
            .pathOutsideAuthorizedScope, .sourceDoesNotExist, .invalidDestination,
            .nameCollision, .filesystemPermissionDenied, .filesystemError,
            .operationFailed,
        ]
    }
}
