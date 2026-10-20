import Foundation
import Security

/// The keys that open what the realtime servers carry, and seal what the app sends through them:
/// each `{label}:{64 hex}` as the app's server hands it out, never from the realtime server. A sealed value is
/// `{label}:1.{base64url(nonce + ciphertext)}`, XChaCha20-Poly1305 with the label as associated data.
///
/// - `d:{day}` the day's key, for the directory and calls' people;
/// - `u:{id}:{generation}` the user's own, for what the app's server sends them;
/// - `ch:{room}:{generation}` a sealed room's.
public final class Keyring: @unchecked Sendable {
    private var keys: [String: Data] = [:]
    private let lock = NSLock()

    static let labelPattern = "[a-z][a-z0-9]{0,15}:[A-Za-z0-9_\\-=@,.;:]{1,240}"
    private static let sealed = try! NSRegularExpression(pattern: "^(" + labelPattern + "):1\\.([A-Za-z0-9_-]+)$")
    private static let label = try! NSRegularExpression(pattern: "^" + labelPattern + "$")

    public init() {}

    /// Keys as the app's server hands them out; the labels added.
    @discardableResult
    public func add(_ entries: [String]) -> [String] {
        var added: [String] = []
        lock.lock()
        defer { lock.unlock() }
        for entry in entries {
            guard let colon = entry.lastIndex(of: ":") else { continue }
            let label = String(entry[..<colon]), hex = String(entry[entry.index(after: colon)...])
            guard hex.count == 64, Keyring.valid(label), let key = Data(hex: hex) else { continue }
            keys[label] = key
            added.append(label)
        }
        return added
    }

    public func has(_ label: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keys[label] != nil
    }

    /// The keys held whose label starts with `prefix`, as the app's server hands them out (`{label}:{64 hex}`): for a
    /// module that keeps some across launches, as the calls keep the day's keys so a phone woken by a ring opens the
    /// caller's name before anything connects (WordPlusRealtimeCalls' SystemCalls).
    @_spi(WordPlusModules) public func entries(_ prefix: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return keys.filter { $0.key.hasPrefix(prefix) }.map { label, key in
            label + ":" + key.map { String(format: "%02x", $0) }.joined()
        }.sorted()
    }

    /// The newest key held of one thing, by its label up to the generation (`ch:chat:34:42:`, `u:42:`); nil for none.
    public func newest(_ prefix: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        var best = 0
        for label in keys.keys where label.hasPrefix(prefix) {
            if let n = Int(label.dropFirst(prefix.count)), n > best, label.dropFirst(prefix.count).allSatisfy(\.isNumber) { best = n }
        }
        return best > 0 ? prefix + String(best) : nil
    }

    public func seal(_ text: String, label: String) -> String? {
        guard let key = key(label) else { return nil }
        var nonce = Data(count: 24)
        let status = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 24, $0.baseAddress!) }
        guard status == errSecSuccess, let sealed = try? XChaCha.seal(key: key, nonce: nonce, plain: Data(text.utf8), aad: Data(label.utf8)) else { return nil }
        return label + ":1." + Base64URL.encode(nonce + sealed)
    }

    /// JSON sealed with a label's key, its binary parts inside as `{ "$b": base64 }`.
    public func sealJSON(_ value: JSONValue, label: String) -> String? {
        seal(value.jsonString(), label: label)
    }

    /// The plain text of a sealed value; a value not sealed comes back as it is; nil when its key isn't held or it doesn't open.
    public func open(_ value: String) -> String? {
        guard let match = Keyring.sealed.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let labelRange = Range(match.range(at: 1), in: value), let bodyRange = Range(match.range(at: 2), in: value) else { return value }
        let label = String(value[labelRange])
        guard let key = key(label), let raw = Base64URL.decode(String(value[bodyRange])), raw.count >= 40,
              let plain = XChaCha.open(key: key, nonce: raw.prefix(24), sealed: raw.dropFirst(24), aad: Data(label.utf8)) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// A sealed value's JSON, parsed, its `{ "$b" }` parts as binary; a value not sealed as it is; nil when it doesn't open.
    public func openJSON(_ value: JSONValue) -> JSONValue? {
        guard case let .string(text) = value, Keyring.labelOf(text) != nil else { return value.unpackingBinary() }
        guard let plain = open(text), let parsed = JSONValue.parse(plain) else { return nil }
        return parsed.unpackingBinary()
    }

    /// The labels a value needs that the keyring doesn't hold, however deep.
    public func missing(_ value: JSONValue) -> [String] {
        var out = Set<String>()
        func visit(_ v: JSONValue, _ depth: Int) {
            guard depth < 9 else { return }
            switch v {
            case let .string(s): if let label = Keyring.labelOf(s), !has(label) { out.insert(label) }
            case let .array(items): items.forEach { visit($0, depth + 1) }
            case let .object(fields): fields.values.forEach { visit($0, depth + 1) }
            default: break
            }
        }
        visit(value, 0)
        return Array(out)
    }

    /// The label of the key a sealed value needs, or nil when it isn't sealed.
    public static func labelOf(_ value: String) -> String? {
        guard let match = sealed.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    static func valid(_ label: String) -> Bool {
        label.count <= 256 && Keyring.label.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil
    }

    private func key(_ label: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return keys[label]
    }
}
