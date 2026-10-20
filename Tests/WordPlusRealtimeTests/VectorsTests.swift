import XCTest
@testable import WordPlusRealtime

/// The conformance vectors every package checks itself against (@wordplus/realtime's spec/vectors.json, written by PHP
/// with libsodium): a value sealed here opens there, and the other way round.
final class VectorsTests: XCTestCase {
    private func vectors() throws -> JSONValue {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: "json"))
        return try XCTUnwrap(JSONValue.parse(String(contentsOf: url, encoding: .utf8)))
    }

    func testOpensWhatPHPSealedAndSealsAsLibsodium() throws {
        let v = try vectors()
        let ring = Keyring()
        ring.add(try XCTUnwrap(v["keys"]?.array).compactMap { $0["entry"]?.string })

        for case let sealed in try XCTUnwrap(v["sealed"]?.array) {
            let label = try XCTUnwrap(sealed["label"]?.string), plain = try XCTUnwrap(sealed["plain"]?.string)
            let value = try XCTUnwrap(sealed["sealed"]?.string)
            XCTAssertEqual(ring.open(value), plain, label)

            // With the vector's own nonce, the same bytes as libsodium.
            let nonce = try XCTUnwrap(Data(hex: try XCTUnwrap(sealed["nonce_hex"]?.string)))
            let entry = try XCTUnwrap(v["keys"]?.array?.first { $0["label"]?.string == label }?["entry"]?.string)
            let key = try XCTUnwrap(Data(hex: String(entry.suffix(64))))
            let ours = label + ":1." + Base64URL.encode(nonce + (try XChaCha.seal(key: key, nonce: nonce, plain: Data(plain.utf8), aad: Data(label.utf8))))
            XCTAssertEqual(ours, value, label)
        }
    }

    func testRefusesAValueMovedOrChangedAndKeepsKeysTheAppGave() throws {
        let v = try vectors()
        let ring = Keyring()
        ring.add(try XCTUnwrap(v["keys"]?.array).compactMap { $0["entry"]?.string })
        let first = try XCTUnwrap(v["sealed"]?[0])
        let value = try XCTUnwrap(first["sealed"]?.string), label = try XCTUnwrap(first["label"]?.string)

        XCTAssertNil(ring.open(value.replacingOccurrences(of: label, with: "ch:order:43:1")))
        XCTAssertNil(ring.open(String(value.dropLast(2)) + (value.hasSuffix("A") ? "BB" : "AA")))
        XCTAssertNil(Keyring().open(value))
        XCTAssertEqual(ring.open("plain text"), "plain text")

        // Room and user labels with colons, as protocol 3 names them.
        XCTAssertTrue(ring.has("ch:chat:34:42:2"))
        XCTAssertTrue(ring.has("u:k7f3q:ben:1"))
        XCTAssertEqual(ring.newest("ch:chat:34:42:"), "ch:chat:34:42:2")
        XCTAssertEqual(ring.add(["bad label:" + String(repeating: "a", count: 64), "u:1:1:short"]), [])
    }

    func testSealsJSONWithBinaryInsideAndOpensItBack() throws {
        let ring = Keyring()
        ring.add(["ch:files:1:" + String(repeating: "ab", count: 32)])
        let value: JSONValue = ["name": "a.bin", "bytes": .binary(Data([1, 2, 254]))]
        let sealed = try XCTUnwrap(ring.sealJSON(value, label: "ch:files:1"))
        XCTAssertTrue(sealed.hasPrefix("ch:files:1:1."))
        XCTAssertEqual(ring.openJSON(.string(sealed)), value)
        XCTAssertEqual(ring.missing(["a": .string(sealed), "b": .string("d:1:1.abc")]), ["d:1"])
    }
}
