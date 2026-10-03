import Foundation
import Security

/// A password `ZipWriter` mixes into the entries it writes.
///
/// Only **PKWARE traditional encryption** ("ZipCrypto") is implemented — the
/// scheme macOS 归档实用工具, `unzip -P`, 7-Zip and Windows Explorer all read
/// without any extra software. It is deliberately *not* a security feature: the
/// keystream is a 96-bit linear state that the Biham–Kocher known-plaintext
/// attack (`bkcrack` and friends) recovers from ~12 bytes of known plaintext.
/// The UI says so next to the checkbox; the format is chosen for compatibility,
/// which is what a Finder-integrated archiver is judged on.
///
/// WinZip AES (method 99, extra field 0x9901) is **not** implemented: Info-ZIP
/// — including Apple's `/usr/bin/unzip` — cannot read it, and macOS 归档实用工具's
/// support is unverified.
struct ZipEncryption: Equatable, Sendable {
    /// Password bytes are UTF-8, matching Info-ZIP's default (no OEM codepage).
    var password: String

    /// Where the 10 random header bytes come from. Injectable so tests can pin
    /// the bytes: encryption makes the archive non-deterministic, and the
    /// existing writer tests rely on byte-identical output.
    var randomSource: any ZipRandomSource

    init(password: String, randomSource: any ZipRandomSource = SystemRandomSource()) {
        self.password = password
        self.randomSource = randomSource
    }

    /// Two encryption options are the same when they would produce the same
    /// archive given the same randomness; the source itself is not compared.
    static func == (lhs: ZipEncryption, rhs: ZipEncryption) -> Bool {
        lhs.password == rhs.password
    }
}

/// Supplies the random bytes an encrypted archive needs.
protocol ZipRandomSource: Sendable {
    /// `count` cryptographically random bytes, or `nil` when the system refused.
    func bytes(_ count: Int) -> Data?
}

/// `SecRandomCopyBytes`, the sandbox-safe CSPRNG on macOS.
struct SystemRandomSource: ZipRandomSource {
    func bytes(_ count: Int) -> Data? {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        return status == errSecSuccess ? data : nil
    }
}

/// A source that returns the same byte every time. Tests only.
struct FixedRandomSource: ZipRandomSource {
    let value: UInt8

    init(_ value: UInt8 = 0x5A) {
        self.value = value
    }

    func bytes(_ count: Int) -> Data? {
        Data(repeating: value, count: count)
    }
}

/// Everything that can stop `ZipCrypto` from producing or reading bytes.
enum ZipCryptoError: Error, Equatable {
    case emptyPassword
    case randomBytesUnavailable
    case truncated
}

/// PKWARE traditional encryption, byte-for-byte as Info-ZIP writes it.
///
/// Reference: zlib `contrib/minizip/crypt.h` (zlib license) — the same
/// three-key state machine, the same 12-byte encrypted header. Nothing here is
/// copied from it; the format is reproduced from the spec and cross-checked
/// against archives written by `/usr/bin/zip -e`.
enum ZipCrypto {
    /// The encrypted header is 12 bytes and is stored before the payload.
    static let encryptedHeaderLength = 12

    /// 10 of those bytes are random; the last two are the CRC check.
    static let headerRandomLength = 10

    /// CRC-32 table (IEEE polynomial, reflected), the table minizip calls
    /// `ccitt_32_tab`/`pcrc_32_tab`. The key state mixes password bytes through
    /// it, which is why encryption needs a table rather than plain `crc32`.
    static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    /// The three-key state the password is mixed into.
    struct KeyState {
        private var key0: UInt32 = 0x1234_5678
        private var key1: UInt32 = 0x2345_6789
        private var key2: UInt32 = 0x3456_7890

        init(password: String) {
            for byte in password.utf8 { update(byte) }
        }

        /// Mixes one plaintext byte into the state.
        mutating func update(_ byte: UInt8) {
            key0 = ZipCrypto.crcTable[Int((key0 ^ UInt32(byte)) & 0xFF)] ^ (key0 >> 8)
            key1 = (key1 &+ (key0 & 0xFF)) &* 0x0808_8405 &+ 1
            key2 = ZipCrypto.crcTable[Int((key2 ^ (key1 >> 24)) & 0xFF)] ^ (key2 >> 8)
        }

        /// The next keystream byte.
        mutating func streamByte() -> UInt8 {
            let temp = (key2 | 2) & 0xFFFF
            return UInt8(truncatingIfNeeded: (temp &* (temp ^ 1)) >> 8)
        }
    }

    /// The byte a reader compares against the top CRC-32 byte to tell "wrong
    /// password" from "right password". 7-Zip writes only this check; Info-ZIP
    /// writes it in byte 11 and a second check byte in byte 10.
    static func checkByte(forCRC crc: UInt32) -> UInt8 {
        UInt8((crc >> 24) & 0xFF)
    }

    /// Builds the 12-byte plaintext header for an entry with CRC `crc`.
    ///
    /// `random` should be `headerRandomLength` bytes; a short or missing buffer
    /// is zero-padded (tests pin it, the app always passes real randomness).
    static func header(crc: UInt32, random: Data) -> Data {
        var header = Data(random.prefix(headerRandomLength))
        if header.count < headerRandomLength {
            header.append(Data(repeating: 0, count: headerRandomLength - header.count))
        }
        // Info-ZIP's two-byte check form: bytes 10 and 11 of the CRC-32. Readers
        // only verify byte 11, but writing 10 as well is what `zip -e` does and
        // is what older PKZIP expects.
        header.append(UInt8(truncatingIfNeeded: crc >> 16))
        header.append(checkByte(forCRC: crc))
        return header
    }

    /// Encrypts `header` followed by `plaintext` with one continuous keystream,
    /// which is the whole point of the format: the header is not a separate
    /// record, it is the first 12 bytes of the ciphertext.
    static func encrypt(_ plaintext: Data, header: Data, password: String) -> Data {
        var state = KeyState(password: password)
        var output = Data()
        output.reserveCapacity(header.count + plaintext.count)
        for byte in header {
            output.append(byte ^ state.streamByte())
            state.update(byte)
        }
        for byte in plaintext {
            output.append(byte ^ state.streamByte())
            state.update(byte)
        }
        return output
    }

    /// Decrypts `stored` (encrypted header + encrypted payload) and returns the
    /// header's check byte alongside the payload.
    ///
    /// The check byte is the only thing a reader can validate before the CRC
    /// arrives, so callers compare it with `checkByte(forCRC:)` when they know
    /// the entry's CRC, and otherwise treat a mismatch as "wrong password".
    static func decrypt(_ stored: Data, password: String) throws -> (checkByte: UInt8, payload: Data) {
        guard !password.isEmpty else { throw ZipCryptoError.emptyPassword }
        guard stored.count >= encryptedHeaderLength else { throw ZipCryptoError.truncated }

        var state = KeyState(password: password)
        var plaintext = [UInt8]()
        plaintext.reserveCapacity(stored.count)
        for byte in stored {
            let value = byte ^ state.streamByte()
            state.update(value)
            plaintext.append(value)
        }

        let check = plaintext[encryptedHeaderLength - 1]
        return (check, Data(plaintext[encryptedHeaderLength...]))
    }
}
