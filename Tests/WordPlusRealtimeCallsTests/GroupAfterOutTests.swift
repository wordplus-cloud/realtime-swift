import XCTest
@testable import WordPlusRealtime
@testable import WordPlusRealtimeCalls

/// Joining a group call again after being taken out of it, as the browser's (realtime-client calls.ts:425-431): the
/// realtime server refuses a token signed in the second of that. With no server.
@MainActor
final class GroupAfterOutTests: XCTestCase {
    private func placed() -> (Realtime, CallsRouteAsked) {
        let (rt, socket, route) = standInCalls()
        socket.answer = { _, _ in ["ok": true, "server": "wss://nowhere.invalid", "token": "room-token"] }
        return (rt, route)
    }

    func testTheWaitIsIntoTheNextSecondAndALittleMore() {
        let out = Date(timeIntervalSince1970: 1_000.4)
        XCTAssertEqual(RealtimeCalls.outWait(out: out, now: out), 0.75, accuracy: 0.001)
        XCTAssertEqual(RealtimeCalls.outWait(out: out, now: Date(timeIntervalSince1970: 1_001.15)), 0, accuracy: 0.001)
        XCTAssertLessThan(RealtimeCalls.outWait(out: out, now: Date(timeIntervalSince1970: 1_002)), 0)
    }

    func testJoiningAgainAfterBeingRemovedAsksInTheNextSecond() async throws {
        let (rt, route) = placed()
        let first = try await rt.calls.group("meeting:7", type: .audio)
        first.finish("removed")
        await mainSettled()
        let out = Date()

        let second = try await rt.calls.group("meeting:7", type: .audio)
        let asked = try XCTUnwrap(route.at.last)
        XCTAssertGreaterThanOrEqual(asked.timeIntervalSince1970, out.timeIntervalSince1970.rounded(.down) + 1, "not in the second it was removed")
        second.leave()
    }

    func testJoiningAgainAfterItWasClosedAsksInTheNextSecond() async throws {
        let (rt, route) = placed()
        let first = try await rt.calls.group("meeting:7", type: .audio)
        first.finish("closed")
        await mainSettled()
        let out = Date()

        let second = try await rt.calls.group("meeting:7", type: .audio)
        let asked = try XCTUnwrap(route.at.last)
        XCTAssertGreaterThanOrEqual(asked.timeIntervalSince1970, out.timeIntervalSince1970.rounded(.down) + 1)
        second.leave()
    }

    func testJoiningAgainAfterLeavingWaitsForNothing() async throws {
        let (rt, route) = placed()
        let first = try await rt.calls.group("meeting:7", type: .audio)
        first.leave()
        await mainSettled()
        let before = Date()
        let second = try await rt.calls.group("meeting:7", type: .audio)
        XCTAssertLessThan(try XCTUnwrap(route.at.last).timeIntervalSince(before), 0.1)
        second.leave()
    }

    func testAnotherCallWaitsForNothing() async throws {
        let (rt, route) = placed()
        let first = try await rt.calls.group("meeting:7", type: .audio)
        first.finish("removed")
        await mainSettled()
        let before = Date()
        let other = try await rt.calls.group("meeting:8", type: .audio)
        XCTAssertLessThan(try XCTUnwrap(route.at.last).timeIntervalSince(before), 0.1)
        other.leave()
    }

    func testTheWaitIsOnce() async throws {
        let (rt, route) = placed()
        let first = try await rt.calls.group("meeting:7", type: .audio)
        first.finish("removed")
        await mainSettled()
        try await rt.calls.group("meeting:7", type: .audio).leave()
        await mainSettled()
        let before = Date()
        try await rt.calls.group("meeting:7", type: .audio).leave()
        XCTAssertLessThan(try XCTUnwrap(route.at.last).timeIntervalSince(before), 0.1)
    }
}
