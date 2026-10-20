import Foundation

/// A JSON value as the realtime servers carry it: what an event, a member's info or a profile holds. Binary parts
/// (`binary`) travel as bytes, and in a sealed room as `{ "$b": base64 }` inside its JSON, as the
/// browser's client and every server package carry them.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    case binary(Data)

    public subscript(key: String) -> JSONValue? {
        if case let .object(fields) = self { return fields[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case let .array(items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    public var string: String? { if case let .string(s) = self { return s }; return nil }
    public var number: Double? { if case let .number(n) = self { return n }; return nil }
    public var int: Int? { number.map { Int($0) } }
    public var bool: Bool? { if case let .bool(b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case let .array(a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case let .object(o) = self { return o }; return nil }
    public var data: Data? { if case let .binary(d) = self { return d }; return nil }
    public var isNull: Bool { self == .null }

    /// A user id as the realtime servers name them: a string, or an integer as text.
    public var id: String? {
        switch self {
        case let .string(s): return s
        case let .number(n): return n == n.rounded() ? String(Int64(n)) : String(n)
        default: return nil
        }
    }

    /// Any Encodable value, as JSON.
    public init<T: Encodable>(encoding value: T) throws {
        if let given = value as? JSONValue {
            self = given
            return
        }
        let data = try JSONEncoder().encode(value)
        self = JSONValue(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// A Decodable value from this JSON.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        if let same = self as? T { return same }
        return try JSONDecoder().decode(T.self, from: try encoded())
    }

    /// From what JSONSerialization parses; Data as binary.
    init(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let data as Data: self = .binary(data)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) } else { self = .number(number.doubleValue) }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map(JSONValue.init(any:)))
        case let object as [String: Any]: self = .object(object.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    /// For JSONSerialization; binary as `{ "$b": base64 }`.
    var any: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(b): return b
        case let .number(n): return n == n.rounded() && abs(n) < 9.0e15 ? NSNumber(value: Int64(n)) : NSNumber(value: n)
        case let .string(s): return s
        case let .array(a): return a.map(\.any)
        case let .object(o): return o.mapValues(\.any)
        case let .binary(d): return ["$b": d.base64EncodedString()]
        }
    }

    /// Its JSON, binary as `{ "$b": base64 }`.
    public func encoded() throws -> Data {
        try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
    }

    public func jsonString() -> String {
        (try? encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    public static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(any: any)
    }

    /// `{ "$b": base64 }` parts as binary again.
    func unpackingBinary(depth: Int = 0) -> JSONValue {
        guard depth < 17 else { return self }
        switch self {
        case let .array(items): return .array(items.map { $0.unpackingBinary(depth: depth + 1) })
        case let .object(fields):
            if fields.count == 1, let b = fields["$b"]?.string, let data = Data(base64Encoded: b) { return .binary(data) }
            return .object(fields.mapValues { $0.unpackingBinary(depth: depth + 1) })
        default: return self
        }
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n): try c.encode(n)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        case let .binary(d): try c.encode(["$b": d.base64EncodedString()])
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
}
