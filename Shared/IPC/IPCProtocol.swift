import Foundation
import os

/// Minimal length-prefixed JSON request/response envelope for the App-Group
/// Unix socket transport. P5-0.6 transport proof only ships `ping`/`pong`;
/// future methods are added here without changing the framing.
public enum IPCProtocol {

    /// Wire version this build speaks. Every constructor below writes it, and
    /// `decode` rejects anything else. It used to be written and parsed but
    /// never checked, so a peer from a different build would have been
    /// interpreted under the wrong contract.
    public static let currentVersion = 1

    private static let log = Logger(subsystem: MenuRightIPC.subsystem, category: "ipc-protocol")

    /// A message carrying the wire `version` field. Only the envelope types
    /// conform; payloads nested in `payload`/`result` have their own versions.
    public protocol VersionedMessage {
        var version: Int { get }
    }

    public struct Request: Codable, VersionedMessage {
        public let version: Int
        public let id: String
        public let method: String
        public let payload: String?

        public init(id: String = UUID().uuidString, method: String, payload: String? = nil) {
            self.version = IPCProtocol.currentVersion
            self.id = id
            self.method = method
            self.payload = payload
        }
    }

    public struct Response: Codable, VersionedMessage {
        public let version: Int
        public let id: String
        public let result: String?
        public let error: String?
        /// Set on a **progress frame** only: `0...1`. A frame carrying progress is
        /// an interim status update, not the answer — the answer is the frame
        /// without it. Long operations (compression) use this so the extension's
        /// window can show real movement instead of a frozen spinner.
        public let progress: Double?

        public static func ok(id: String, result: String) -> Response {
            Response(version: IPCProtocol.currentVersion, id: id, result: result, error: nil, progress: nil)
        }
        public static func fail(id: String, error: String) -> Response {
            Response(version: IPCProtocol.currentVersion, id: id, result: nil, error: error, progress: nil)
        }
        public static func progress(id: String, fraction: Double) -> Response {
            Response(version: IPCProtocol.currentVersion, id: id, result: nil, error: nil, progress: fraction)
        }

        /// True for an interim progress frame.
        public var isProgress: Bool { progress != nil }
    }

    public static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    /// Decodes a frame, rejecting an incompatible wire version.
    ///
    /// A peer speaking another protocol version cannot be interpreted, so the
    /// decode fails here — logging both numbers — instead of yielding a
    /// half-understood request that misbehaves further downstream.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        guard let decoded = try? JSONDecoder().decode(type, from: data) else { return nil }
        if let versioned = decoded as? VersionedMessage, versioned.version != currentVersion {
            log.notice("\(versionMismatchMessage(received: versioned.version, expected: currentVersion), privacy: .public)")
            return nil
        }
        return decoded
    }

    /// Message naming both versions, so one log line identifies the mismatch.
    /// Internal so the unit tests can pin the wording.
    static func versionMismatchMessage(received: Int, expected: Int) -> String {
        "IPC protocol version mismatch: received \(received), this build speaks \(expected)"
    }
}
