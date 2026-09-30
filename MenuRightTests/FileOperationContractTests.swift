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
            .aliasFailed: "alias_failed",
            .lockFailed: "lock_failed",
            .openFailed: "open_failed",
            .templateMissing: "template_missing",
            .unsupportedDocumentKind: "unsupported_document_kind",
            .archiveUnsupported: "archive_unsupported",
            .archiveUnsafePath: "archive_unsafe_path",
            .archiveTooLarge: "archive_too_large",
            .archiveFailed: "archive_failed",
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

    /// P6 added operations whose arguments must survive the wire unchanged.
    func testP6OperationKindsAndArgumentsRoundTrip() throws {
        let cases: [FileOperationContract.Request] = [
            FileOperationContract.Request(
                kind: .createAlias,
                args: FileOperationContract.OperationArgs(sourcePaths: ["/a/one.txt", "/a/two.txt"])
            ),
            FileOperationContract.Request(
                kind: .setLocked,
                args: FileOperationContract.OperationArgs(sourcePaths: ["/a/one.txt"], locked: false)
            ),
            FileOperationContract.Request(
                kind: .openTerminal,
                args: FileOperationContract.OperationArgs(directory: "/a/folder")
            ),
        ]
        for request in cases {
            let payload = try XCTUnwrap(request.encodedForIPC())
            XCTAssertEqual(FileOperationContract.Request.decode(fromIPC: payload), request)
        }
    }

    func testLockedFlagIsOptionalAndNotRequiredByOtherKinds() throws {
        let legacy = #"{"kind":"createFile","args":{"directory":"/a","name":"x.txt"}}"#
        let decoded = try XCTUnwrap(FileOperationContract.Request.decode(fromIPC: legacy))
        XCTAssertNil(decoded.args.locked, "older payloads without the P6 field must still decode")
    }

    /// P6-b: the document kinds travel as a name plus a kind — never bytes.
    func testP6bDocumentRequestsRoundTrip() throws {
        let cases: [FileOperationContract.Request] = [
            FileOperationContract.Request(
                kind: .createDocument,
                args: FileOperationContract.OperationArgs(
                    directory: "/a/folder",
                    name: "Untitled.docx",
                    documentKind: "docx"
                )
            ),
            FileOperationContract.Request(
                kind: .createFromTemplate,
                args: FileOperationContract.OperationArgs(
                    directory: "/a/folder",
                    name: "Untitled.key",
                    documentKind: "keynote"
                )
            ),
        ]
        for request in cases {
            let payload = try XCTUnwrap(request.encodedForIPC())
            let decoded = try XCTUnwrap(FileOperationContract.Request.decode(fromIPC: payload))
            XCTAssertEqual(decoded, request)
            XCTAssertNil(decoded.args.contentsBase64, "generation must not depend on extension-supplied bytes")
        }
    }

    /// The field is additive: a payload written before P6-b still decodes.
    func testDocumentKindIsOptionalForOlderPayloads() throws {
        let legacy = #"{"kind":"createFile","args":{"directory":"/a","name":"x.txt","contentsBase64":""}}"#
        let decoded = try XCTUnwrap(FileOperationContract.Request.decode(fromIPC: legacy))
        XCTAssertNil(decoded.args.documentKind)
    }

    /// P7-b: the favorites hand-offs carry a target (path, bundle identifier or
    /// URL) instead of bytes or paths-to-write.
    func testP7bOpenRequestsRoundTrip() throws {
        let cases: [FileOperationContract.Request] = [
            FileOperationContract.Request(
                kind: .openFolder,
                args: FileOperationContract.OperationArgs(directory: "/Users/foo/Projects")
            ),
            FileOperationContract.Request(
                kind: .openApplication,
                args: FileOperationContract.OperationArgs(target: "com.apple.TextEdit")
            ),
            FileOperationContract.Request(
                kind: .openURL,
                args: FileOperationContract.OperationArgs(target: "https://example.com/a?b=1")
            ),
        ]
        for request in cases {
            let payload = try XCTUnwrap(request.encodedForIPC())
            let decoded = try XCTUnwrap(FileOperationContract.Request.decode(fromIPC: payload))
            XCTAssertEqual(decoded, request)
            XCTAssertEqual(decoded.kind, request.kind)
        }

        // `target` is additive: a P6 payload without it still decodes.
        let legacy = #"{"kind":"openTerminal","args":{"directory":"/a"}}"#
        XCTAssertNil(try XCTUnwrap(FileOperationContract.Request.decode(fromIPC: legacy)).args.target)
    }

    /// P9: compress/extract requests carry paths plus an explicit format.
    func testP9ArchiveRequestsRoundTrip() throws {
        let cases: [FileOperationContract.Request] = [
            FileOperationContract.Request(
                kind: .compressItems,
                args: FileOperationContract.OperationArgs(
                    name: "Bundle.zip",
                    sourcePaths: ["/a/one.txt", "/a/two.txt"],
                    destinationDirectory: "/a",
                    archiveFormat: "zip"
                )
            ),
            FileOperationContract.Request(
                kind: .extractArchive,
                args: FileOperationContract.OperationArgs(
                    sourcePaths: ["/a/bundle.zip"],
                    destinationDirectory: nil
                )
            ),
        ]
        for request in cases {
            let payload = try XCTUnwrap(request.encodedForIPC())
            XCTAssertEqual(FileOperationContract.Request.decode(fromIPC: payload), request)
        }

        // Both fields are additive; older payloads keep decoding.
        let legacy = #"{"kind":"extractArchive","args":{"sourcePaths":["/a/b.zip"]}}"#
        let decoded = try XCTUnwrap(FileOperationContract.Request.decode(fromIPC: legacy))
        XCTAssertNil(decoded.args.archiveFormat)
        XCTAssertNil(decoded.args.destinationDirectory)
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
            .operationFailed, .aliasFailed, .lockFailed, .openFailed,
            .templateMissing, .unsupportedDocumentKind,
            .archiveUnsupported, .archiveUnsafePath, .archiveTooLarge, .archiveFailed,
        ]
    }
}
