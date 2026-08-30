import XCTest

final class CutPayloadTests: XCTestCase {
    private func makePayload(urls: [String]) -> CutPayload {
        CutPayload(urls: urls.map { URL(fileURLWithPath: $0) })
    }

    private func decode(_ json: String) throws -> CutPayload {
        try CutPayloadCodec.decode(Data(json.utf8))
    }

    private func jsonDictionary(_ dictionary: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: dictionary)
        return String(data: data, encoding: .utf8)!
    }

    func testRoundTripSingleURL() throws {
        let payload = makePayload(urls: ["/Users/foo/example.png"])
        let data = try CutPayloadCodec.encode(payload)
        XCTAssertEqual(try CutPayloadCodec.decode(data), payload)
    }

    func testRoundTripMultipleURLs() throws {
        let payload = makePayload(urls: ["/Users/foo/a.txt", "/Users/foo/b.txt", "/Users/foo/Dir"])
        let data = try CutPayloadCodec.encode(payload)
        XCTAssertEqual(try CutPayloadCodec.decode(data), payload)
    }

    func testEncodeUsesFileURLStrings() throws {
        let payload = makePayload(urls: ["/Users/foo/My Project/notes.txt"])
        let data = try CutPayloadCodec.encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let urls = try XCTUnwrap(json["urls"] as? [String])
        XCTAssertEqual(urls, ["file:///Users/foo/My%20Project/notes.txt"])
    }

    func testRoundTripPathsWithSpacesUnicodeChineseEmoji() throws {
        let payload = makePayload(urls: [
            "/Users/foo/My Project/a b.txt",
            "/Users/foo/报告 2025.pdf",
            "/Users/foo/😀 照片.JPG",
        ])
        let data = try CutPayloadCodec.encode(payload)
        XCTAssertEqual(try CutPayloadCodec.decode(data), payload)
    }

    func testEncodeIsDeterministic() throws {
        let payload = makePayload(urls: ["/Users/foo/z.txt", "/Users/foo/a.txt"])
        let first = try CutPayloadCodec.encode(payload)
        let second = try CutPayloadCodec.encode(payload)
        XCTAssertEqual(first, second)
    }

    func testMalformedDataRejected() {
        XCTAssertThrowsError(try CutPayloadCodec.decode(Data("this is not json".utf8))) { error in
            XCTAssertEqual(error as? CutPayloadError, .malformedData)
        }
    }

    func testEmptyJSONRejected() {
        XCTAssertThrowsError(try decode("{}")) { error in
            XCTAssertEqual(error as? CutPayloadError, .malformedData)
        }
    }

    func testWrongOperationRejected() throws {
        let json = jsonDictionary([
            "version": 1,
            "operation": "copy",
            "urls": ["file:///Users/foo/a.txt"],
        ])
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(error as? CutPayloadError, .malformedData)
        }
    }

    func testUnsupportedVersionRejected() throws {
        let json = jsonDictionary([
            "version": 99,
            "operation": "cut",
            "urls": ["file:///Users/foo/a.txt"],
        ])
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(error as? CutPayloadError, .unsupportedVersion(99))
        }
    }

    func testNonFileURLRejected() throws {
        let json = jsonDictionary([
            "version": 1,
            "operation": "cut",
            "urls": ["https://example.com/foo.txt"],
        ])
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(error as? CutPayloadError, .containsNonFileURL)
        }
    }

    func testMixedValidAndNonFileURLRejected() throws {
        let json = jsonDictionary([
            "version": 1,
            "operation": "cut",
            "urls": ["file:///Users/foo/a.txt", "ftp://example.com", "file:///Users/foo/b.txt"],
        ])
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(error as? CutPayloadError, .containsNonFileURL)
        }
    }

    func testEmptyURLListRejected() throws {
        let json = jsonDictionary([
            "version": 1,
            "operation": "cut",
            "urls": [],
        ])
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(error as? CutPayloadError, .emptyURLList)
        }
    }

    func testMissingURLsRejected() throws {
        let json = jsonDictionary([
            "version": 1,
            "operation": "cut",
        ])
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(error as? CutPayloadError, .emptyURLList)
        }
    }
}
