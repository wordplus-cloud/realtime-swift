import Foundation
import CryptoKit

/// The seal on every signal a direct call exchanges.
///
/// WordPress hands both sides a key in the `callCreate` / `joinCall` replies.
/// The realtime server relays and stores the sealed bodies and never holds
/// that key, so the offer, the answer, the candidates and everything the two
/// sides say about their cameras stay between them.
///
/// AES-256-GCM under SHA-256 of the key, one random nonce per signal. The wire
/// form is the web's exactly - {sealed: 1, iv, data}, base64, with the tag
/// appended to the ciphertext, which is what `crypto.subtle` produces and what
/// CryptoKit has to be told to do by hand.
final class CallCipher {
    /// The label and the key are joined by a NUL byte, which is what the web
    /// hashes; a space or an empty string here derives a different key and
    /// every signal silently fails to open.
    private static let label = "better-messages-p2p-signal\u{0}"

    private let key: SymmetricKey

    init?(secret: String) {
        guard !secret.isEmpty,
              let material = (CallCipher.label + secret).data(using: .utf8) else {
            return nil
        }

        key = SymmetricKey(data: SHA256.hash(data: material))
    }

    /// True for a body that arrived sealed. A plain one is still accepted -
    /// an older build on the other side seals nothing.
    static func isSealed(_ body: Any?) -> Bool {
        guard let map = body as? [String: Any] else { return false }

        return (map["sealed"] as? Int) == 1 && map["iv"] is String && map["data"] is String
    }

    func seal(_ body: [String: Any]) -> [String: Any]? {
        guard JSONSerialization.isValidJSONObject(body),
              let plain = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }

        var nonceBytes = Data(count: 12)
        let status = nonceBytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }

            return SecRandomCopyBytes(kSecRandomDefault, 12, base)
        }

        guard status == errSecSuccess,
              let nonce = try? AES.GCM.Nonce(data: nonceBytes),
              let box = try? AES.GCM.seal(plain, using: key, nonce: nonce) else {
            return nil
        }

        return [
            "sealed": 1,
            "iv": nonceBytes.base64EncodedString(),
            // The web reads one buffer of ciphertext followed by the tag;
            // CryptoKit keeps them apart, so they are joined here.
            "data": (box.ciphertext + box.tag).base64EncodedString()
        ]
    }

    func open(_ body: [String: Any]) -> [String: Any]? {
        guard let ivText = body["iv"] as? String,
              let dataText = body["data"] as? String,
              let ivData = Data(base64Encoded: ivText),
              let combined = Data(base64Encoded: dataText),
              combined.count > 16,
              let nonce = try? AES.GCM.Nonce(data: ivData) else {
            return nil
        }

        let cipherText = combined.prefix(combined.count - 16)
        let tag = combined.suffix(16)

        guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherText, tag: tag),
              let plain = try? AES.GCM.open(box, using: key),
              let parsed = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              parsed["kind"] is String else {
            return nil
        }

        return parsed
    }
}
