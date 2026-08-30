import Foundation

/// Versioned cut-payload model. Stored on the system pasteboard as JSON so it
/// survives extension restarts without App Group state or SQLite.
struct CutPayload: Equatable {
    static let currentVersion = 1
    let version: Int
    let urls: [URL]

    init(version: Int = CutPayload.currentVersion, urls: [URL]) {
        self.version = version
        self.urls = urls
    }
}

enum CutPayloadError: Equatable, Error {
    case malformedData
    case unsupportedVersion(Int)
    case containsNonFileURL
    case emptyURLList
}

/// JSON codec for the Menu Right cut payload.
///
/// Payload shape:
/// {
///   "version": 1,
///   "operation": "cut",
///   "urls": ["file:///Users/..."]
/// }
enum CutPayloadCodec {
    static let operation = "cut"

    static func encode(_ payload: CutPayload) throws -> Data {
        let object: [String: Any] = [
            "version": payload.version,
            "operation": operation,
            "urls": payload.urls.map { $0.absoluteString },
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func decode(_ data: Data) throws -> CutPayload {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any] else {
            throw CutPayloadError.malformedData
        }
        guard (object["operation"] as? String) == operation else {
            throw CutPayloadError.malformedData
        }
        guard let version = object["version"] as? Int else {
            throw CutPayloadError.malformedData
        }
        guard version == CutPayload.currentVersion else {
            throw CutPayloadError.unsupportedVersion(version)
        }
        guard let rawURLs = object["urls"] as? [String], !rawURLs.isEmpty else {
            throw CutPayloadError.emptyURLList
        }
        let urls = rawURLs.map { URL(string: $0) }
        guard urls.allSatisfy({ url in url.map { $0.isFileURL } ?? false }) else {
            throw CutPayloadError.containsNonFileURL
        }
        return CutPayload(version: version, urls: urls.compactMap { $0 })
    }
}
