import Foundation

/// Minimal length-prefixed JSON request/response envelope for the App-Group
/// Unix socket transport. P5-0.6 transport proof only ships `ping`/`pong`;
/// future methods are added here without changing the framing.
public enum IPCProtocol {

    public struct Request: Codable {
        public let version: Int
        public let id: String
        public let method: String
        public let payload: String?

        public init(id: String = UUID().uuidString, method: String, payload: String? = nil) {
            self.version = 1
            self.id = id
            self.method = method
            self.payload = payload
        }
    }

    public struct Response: Codable {
        public let version: Int
        public let id: String
        public let result: String?
        public let error: String?

        public static func ok(id: String, result: String) -> Response {
            Response(version: 1, id: id, result: result, error: nil)
        }
        public static func fail(id: String, error: String) -> Response {
            Response(version: 1, id: id, result: nil, error: error)
        }
    }

    public static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
