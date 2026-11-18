import XCTest
@testable import WordPlusRealtime
@testable import WordPlusRealtimeCalls

/// Who this app's user may add, and whom they may call, through the app's calls route, as the browser's ask them
/// (realtime-client calls.ts:273, 288, its test/sdk-calls.test.ts). With no server.
final class CallPeopleTests: XCTestCase {
    func testPeopleAreAskedOfTheCallsRoute() async {
        let (rt, _, asked) = standInCalls(route: { _ in
            (200, ["people": [
                ["id": 43, "name": "Ann", "avatar": "https://shop.example/ann.png"],
                ["id": "auth0|5f7c", "name": "Ben"],
                ["id": "", "name": "No id"],
                ["id": 0, "name": "Nobody"],
                ["id": "with space", "name": "Spaced"],
                ["id": 44],
                "not a person",
            ]])
        })
        let people = await rt.calls.people("support-42")
        XCTAssertEqual(asked.bodies, [["people": "support-42"]])
        XCTAssertEqual(people, [
            CallPerson(id: "43", name: "Ann", avatar: "https://shop.example/ann.png"),
            CallPerson(id: "auth0|5f7c", name: "Ben"),
        ])
    }

    func testNoPeopleWhenNoneAreListedOrTheRouteRefuses() async {
        let none = await standInCalls(route: { _ in (200, ["ok": true]) }).rt.calls.people("support-42")
        let denied = await standInCalls(route: { _ in (200, ["denied": "forbidden"]) }).rt.calls.people("support-42")
        let refused = await standInCalls(route: { _ in (403, nil) }).rt.calls.people("support-42")
        let failed = await standInCalls(route: { _ in (500, nil) }).rt.calls.people("support-42")
        XCTAssertEqual(none, [])
        XCTAssertEqual(denied, [])
        XCTAssertEqual(refused, [])
        XCTAssertEqual(failed, [])
    }

    func testMayIsAskedInTheOrderGiven() async {
        let (rt, _, asked) = standInCalls(route: { _ in (200, ["may": [true, false]]) })
        let may = await rt.calls.may([CallAsk(call: "support:42:43", to: "43"), CallAsk(call: "support:42:x", to: "auth0|5f7c")])
        XCTAssertEqual(may, [true, false])
        XCTAssertEqual(asked.bodies, [["may": [
            ["call": "support:42:43", "to": 43],
            ["call": "support:42:x", "to": "auth0|5f7c"],
        ]]])
    }

    func testMayGoesAHundredARequest() async {
        let (rt, _, asked) = standInCalls(route: { body in
            (200, ["may": .array(Array(repeating: .bool(true), count: body["may"]?.array?.count ?? 0))])
        })
        let may = await rt.calls.may((0..<150).map { CallAsk(call: "support:{pair}", to: String(100 + $0)) })
        XCTAssertEqual(may, Array(repeating: true, count: 150))
        XCTAssertEqual(asked.bodies.map { $0["may"]?.array?.count }, [100, 50])
    }

    func testMayIsNilWhereTheServerGaveNoAnswer() async {
        let ask = [CallAsk(call: "support:42:old", to: "old")]
        let unknown = await standInCalls(route: { _ in (200, ["ok": true]) }).rt.calls.may(ask)
        let failed = await standInCalls(route: { _ in (500, nil) }).rt.calls.may(ask)
        let denied = await standInCalls(route: { _ in (200, ["denied": "forbidden"]) }).rt.calls.may(ask)
        let wrong = await standInCalls(route: { _ in (200, ["may": [true, true]]) }).rt.calls.may(ask)
        XCTAssertEqual(unknown, [nil])
        XCTAssertEqual(failed, [nil])
        XCTAssertEqual(denied, [nil])
        XCTAssertEqual(wrong, [nil])
    }

    func testAnAnswerThatIsNotTrueIsNo() async {
        let (rt, _, _) = standInCalls(route: { _ in (200, ["may": [1, "yes", .null]]) })
        let may = await rt.calls.may((0..<3).map { CallAsk(call: "c", to: String(1 + $0)) })
        XCTAssertEqual(may, [false, false, false])
    }

    func testNothingToAskAsksNothing() async {
        let (rt, _, asked) = standInCalls()
        let may = await rt.calls.may([])
        XCTAssertEqual(may, [])
        XCTAssertEqual(asked.bodies, [])
    }

    func testAUserReadsAsTheBrowserReadsThem() {
        XCTAssertEqual(RealtimeCalls.user(.number(42)), "42")
        XCTAssertEqual(RealtimeCalls.user(.string("42")), "42")
        XCTAssertEqual(RealtimeCalls.user(.string("auth0|5f7c")), "auth0|5f7c")
        XCTAssertEqual(RealtimeCalls.user(.string(String(repeating: "a", count: 64))), String(repeating: "a", count: 64))
        XCTAssertNil(RealtimeCalls.user(.number(0)))
        XCTAssertNil(RealtimeCalls.user(.number(1.5)))
        XCTAssertNil(RealtimeCalls.user(.string("0")))
        XCTAssertNil(RealtimeCalls.user(.string("")))
        XCTAssertNil(RealtimeCalls.user(.string("a b")))
        XCTAssertNil(RealtimeCalls.user(.string("a\u{7f}")))
        XCTAssertNil(RealtimeCalls.user(.string(String(repeating: "a", count: 65))))
        XCTAssertNil(RealtimeCalls.user(.null))
        XCTAssertNil(RealtimeCalls.user(nil))
    }
}
