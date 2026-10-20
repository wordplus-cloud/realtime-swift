import Foundation
import XCTest
@testable import WordPlusRealtime

/// The routes of the app's server as its config() names them: beside each other, or each at an address of its own.
final class RoutesTests: XCTestCase {
    private let base = URL(string: "https://shop.example.com/")!

    private func options(_ config: String) throws -> RealtimeOptions {
        RealtimeOptions(config: try XCTUnwrap(JSONValue.parse(config)), base: base)
    }

    func testRoutesBesideEachOtherNeedOnlyTheEndpoint() throws {
        let options = try options(#"{"site":"s1","auth":{"endpoint":"/api/realtime/auth"},"calls":{"endpoint":"/api/realtime/calls"},"keys":{"endpoint":"/api/realtime/keys"}}"#)
        XCTAssertEqual(options.endpoint.appendingPathComponent("calls").absoluteString, "https://shop.example.com/api/realtime/calls")
        XCTAssertEqual(options.routes, [:])
    }

    func testARouteAtAnAddressOfItsOwnIsKeptInFull() throws {
        let options = try options(#"{"site":"s1","auth":{"endpoint":"/api/realtime/auth"},"calls":{"endpoint":"/check-call"},"keys":{"endpoint":"https://api.example.com/my/keys"}}"#)
        XCTAssertEqual(options.routes.mapValues(\.absoluteString), ["calls": "https://shop.example.com/check-call", "keys": "https://api.example.com/my/keys"])
    }
}
