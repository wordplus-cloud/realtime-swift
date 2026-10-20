import CryptoKit
import Foundation

/// XChaCha20-Poly1305, as libsodium's `crypto_aead_xchacha20poly1305_ietf` and the browser's @noble/ciphers make it:
/// HChaCha20 turns the key and the first 16 bytes of the 24-byte nonce into a subkey, and CryptoKit's ChaCha20-Poly1305
/// seals with it and the nonce's last 8 bytes. The result is the ciphertext followed by its 16-byte tag.
enum XChaCha {
    static func seal(key: Data, nonce: Data, plain: Data, aad: Data) throws -> Data {
        precondition(key.count == 32 && nonce.count == 24)
        let box = try ChaChaPoly.seal(plain, using: SymmetricKey(data: hChaCha(key: key, nonce: nonce.prefix(16))), nonce: try ChaChaPoly.Nonce(data: Data(count: 4) + nonce.suffix(8)), authenticating: aad)
        return box.ciphertext + box.tag
    }

    /// The plain bytes, or nil when the value was changed or sealed with another key or label.
    static func open(key: Data, nonce: Data, sealed: Data, aad: Data) -> Data? {
        guard key.count == 32, nonce.count == 24, sealed.count >= 16 else { return nil }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: try ChaChaPoly.Nonce(data: Data(count: 4) + nonce.suffix(8)), ciphertext: sealed.prefix(sealed.count - 16), tag: sealed.suffix(16))
            return try ChaChaPoly.open(box, using: SymmetricKey(data: hChaCha(key: key, nonce: nonce.prefix(16))), authenticating: aad)
        } catch {
            return nil
        }
    }

    /// HChaCha20: ChaCha20's 20 rounds over the key and 16 bytes of nonce, without the final addition, words 0–3 and 12–15.
    static func hChaCha(key: Data, nonce: Data) -> Data {
        var s = [UInt32](repeating: 0, count: 16)
        s[0] = 0x6170_7865; s[1] = 0x3320_646e; s[2] = 0x7962_2d32; s[3] = 0x6b20_6574
        let k = [UInt8](key), n = [UInt8](nonce)
        for i in 0..<8 { s[4 + i] = word(k, 4 * i) }
        for i in 0..<4 { s[12 + i] = word(n, 4 * i) }

        func quarter(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            s[a] &+= s[b]; s[d] ^= s[a]; s[d] = s[d] << 16 | s[d] >> 16
            s[c] &+= s[d]; s[b] ^= s[c]; s[b] = s[b] << 12 | s[b] >> 20
            s[a] &+= s[b]; s[d] ^= s[a]; s[d] = s[d] << 8 | s[d] >> 24
            s[c] &+= s[d]; s[b] ^= s[c]; s[b] = s[b] << 7 | s[b] >> 25
        }
        for _ in 0..<10 {
            quarter(0, 4, 8, 12); quarter(1, 5, 9, 13); quarter(2, 6, 10, 14); quarter(3, 7, 11, 15)
            quarter(0, 5, 10, 15); quarter(1, 6, 11, 12); quarter(2, 7, 8, 13); quarter(3, 4, 9, 14)
        }

        var out = Data()
        for i in [0, 1, 2, 3, 12, 13, 14, 15] {
            out.append(contentsOf: [UInt8(s[i] & 0xff), UInt8(s[i] >> 8 & 0xff), UInt8(s[i] >> 16 & 0xff), UInt8(s[i] >> 24 & 0xff)])
        }
        return out
    }

    private static func word(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }
}

/// Base64url without padding, as the sealed values and the tokens use it.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var b = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }
}
