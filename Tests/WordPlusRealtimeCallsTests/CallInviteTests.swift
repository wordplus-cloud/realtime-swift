import XCTest
@testable import WordPlusRealtime
@testable import WordPlusRealtimeCalls

/// A ring into a group call, as the browser's (realtime-client invite.ts, calls.ts:379-384 and 531-548): it updates its
/// state in the relay's words, the app that rang can call it off, and everyone in the call hears of rings others started.
/// With no server.
@MainActor
final class CallInviteTests: XCTestCase {
    private let link = GroupOf(id: "g-1", name: "support:34:42", type: .audio, pair: nil, member: nil)

    private func standIn() -> (Realtime, CallsSocket, CallsRouteAsked) {
        let (rt, socket, route) = standInCalls(route: { _ in (200, ["token": "ring-token", "ring": "ring-proof"]) })
        socket.answer = { event, _ in
            switch event {
            case "group": return ["ok": true, "server": "wss://nowhere.invalid", "token": "room-token"]
            case "invite": return ["ok": true, "state": "ringing"]
            case "uninvite": return ["ok": true, "state": "cancelled"]
            default: return ["ok": true]
            }
        }
        return (rt, socket, route)
    }

    private func told(_ fields: [String: JSONValue]) -> JSONValue { .object(["op": "invite", "id": "ring-9", "group": "g-1", "from": 34, "to": 43, "state": "ringing"].merging(fields) { $1 }) }

    func testARingAsksTheRouteThenTheServer() async throws {
        let (rt, socket, route) = standIn()
        let invite = try await rt.calls.invite(link, user: "43")
        XCTAssertEqual(invite.to, "43")
        XCTAssertEqual(invite.group, "g-1")
        XCTAssertNil(invite.from)
        XCTAssertEqual(invite.state, "ringing")
        XCTAssertEqual(route.bodies.first?["to"], 43)
        XCTAssertEqual(socket.asked("invite").first?["token"]?.string, "ring-token")
        XCTAssertEqual(socket.asked("invite").first?["ring"]?.string, "ring-proof")
    }

    func testAStateTheServerDoesNotNameIsRinging() async throws {
        let (rt, socket, _) = standIn()
        socket.answer = { _, _ in ["ok": true, "state": "whatever"] }
        let invite = try await rt.calls.invite(link, user: "43")
        XCTAssertEqual(invite.state, "ringing")
    }

    func testARingUpdatesItsStateOnce() {
        let invite = CallInvite(id: "r", group: "g", to: "43", state: "ringing")
        var heard: [String] = []
        invite.onState { heard.append($0) }
        invite.update("ringing")
        invite.update("answered")
        invite.update("no_answer")
        XCTAssertEqual(invite.state, "answered", "a ring that ended stays ended, whichever word arrives last")
        XCTAssertEqual(heard, ["answered"])
    }

    func testAStateHandlerComesOff() {
        let invite = CallInvite(id: "r", group: "g", to: "43", state: "ringing")
        var heard = 0
        let listener = invite.onState { _ in heard += 1 }
        invite.off(listener)
        invite.update("busy")
        XCTAssertEqual(heard, 0)
    }

    func testTheAppThatRangCallsItOff() async throws {
        let (rt, socket, _) = standIn()
        let invite = try await rt.calls.invite(link, user: "43")
        var heard: [String] = []
        invite.onState { heard.append($0) }
        XCTAssertTrue(invite.canCancel)
        try await invite.cancel()
        XCTAssertEqual(invite.state, "cancelled")
        XCTAssertEqual(heard, ["cancelled"])
        XCTAssertEqual(socket.asked("uninvite").first?["token"]?.string, "ring-token")
        XCTAssertEqual(socket.asked("uninvite").first?["tab"]?.string, rt.tab)
        XCTAssertFalse(invite.canCancel, "a ring that ended has nothing to call off")
    }

    func testARefusalToCallItOffComesBackByItsCode() async throws {
        let (rt, socket, _) = standIn()
        let invite = try await rt.calls.invite(link, user: "43")
        socket.answer = { _, _ in ["ok": false, "error": "not_ringing"] }
        await XCTAssertThrowsCode("not_ringing") { try await invite.cancel() }
        XCTAssertEqual(invite.state, "ringing")
    }

    func testARingThatEndedHasNothingToCallOff() async throws {
        let (rt, socket, _) = standIn()
        let invite = try await rt.calls.invite(link, user: "43")
        invite.update("rejected")
        try await invite.cancel()
        XCTAssertEqual(socket.asked("uninvite").count, 0)
    }

    func testARingHeardCannotBeCalledOffHere() async {
        let (rt, _, _) = standIn()
        rt.calls.heardInvite(told([:]))
        let invite = rt.calls.invites(of: "g-1").first
        XCTAssertEqual(invite?.from, "34")
        XCTAssertEqual(invite?.to, "43")
        await XCTAssertThrowsCode("forbidden") { try await invite?.cancel() }
    }

    func testARingOthersStartedReachesTheGroupCall() async throws {
        let (rt, _, _) = standIn()
        let group = try await rt.calls.joinGroup(link, token: "t", mediaKey: nil, microphone: false, camera: false)
        var heard: [CallInvite] = []
        group.onInvite { heard.append($0) }

        rt.calls.heardInvite(told([:]))
        XCTAssertEqual(heard.map(\.id), ["ring-9"])
        XCTAssertEqual(group.invites.map(\.id), ["ring-9"])

        rt.calls.heardInvite(told(["state": "busy"]))
        XCTAssertEqual(heard.count, 1, "the same ring is told once")
        XCTAssertEqual(heard.first?.state, "busy")
        group.leave()
    }

    func testAGroupCallsOwnRingIsToldToo() async throws {
        let (rt, _, _) = standIn()
        let group = try await rt.calls.joinGroup(link, token: "t", mediaKey: nil, microphone: false, camera: false)
        var heard: [String] = []
        group.onInvite { heard.append($0.to) }
        let invite = try await group.add("43")
        XCTAssertEqual(heard, ["43"])
        XCTAssertTrue(group.invites.first === invite)
        group.leave()
    }

    func testItsRingingHeardOnTheLineFirstIsTheSameRing() async throws {
        let (rt, socket, route) = standIn()
        // The relay tells of the ring before the request is answered, as it may: with the id the route was asked for.
        socket.answer = { event, _ in
            guard event == "invite", let id = route.bodies.last?["id"]?.string else { return ["ok": true] }
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                rt.calls.heardInvite(.object(["op": "invite", "id": .string(id), "group": "g-1", "to": 43, "state": "ringing"]))
                semaphore.signal()
            }
            semaphore.wait()
            return ["ok": true, "state": "ringing"]
        }
        let invite = try await rt.calls.invite(link, user: "43")
        XCTAssertEqual(rt.calls.invites(of: "g-1").count, 1)
        XCTAssertTrue(rt.calls.invites(of: "g-1").first === invite)
        // And it is this app's own to call off.
        socket.answer = { _, _ in ["ok": true, "state": "cancelled"] }
        try await invite.cancel()
        XCTAssertEqual(invite.state, "cancelled")
    }

    func testRingsForAnotherCallStayApart() async throws {
        let (rt, _, _) = standIn()
        let group = try await rt.calls.joinGroup(link, token: "t", mediaKey: nil, microphone: false, camera: false)
        var heard = 0
        group.onInvite { _ in heard += 1 }
        rt.calls.heardInvite(told(["group": "g-2"]))
        XCTAssertEqual(heard, 0)
        XCTAssertEqual(group.invites.count, 0)
        group.leave()
    }

    func testARingBeforeTheGroupCallIsThereOnceItIs() async throws {
        let (rt, _, _) = standIn()
        rt.calls.heardInvite(told([:]))
        let group = try await rt.calls.joinGroup(link, token: "t", mediaKey: nil, microphone: false, camera: false)
        XCTAssertEqual(group.invites.map(\.id), ["ring-9"])
        group.leave()
    }

    func testAGroupCallEndedForgetsItsRings() async throws {
        let (rt, _, _) = standIn()
        let group = try await rt.calls.joinGroup(link, token: "t", mediaKey: nil, microphone: false, camera: false)
        rt.calls.heardInvite(told([:]))
        group.leave()
        XCTAssertEqual(rt.calls.invites(of: "g-1").count, 0)
        XCTAssertEqual(group.invites.count, 0)
    }

    func testAGroupCallThatIsNoCallsHasNoRings() async throws {
        let (rt, socket, _) = standIn()
        socket.answer = { _, _ in ["ok": true, "server": "wss://nowhere.invalid", "token": "room-token"] }
        let group = try await rt.calls.group("meeting:7", type: .audio)
        rt.calls.heardInvite(told([:]))
        XCTAssertEqual(group.invites.count, 0)
        group.leave()
    }

    func testWhatTheRelaySaysOtherwiseIsPassedOver() {
        let (rt, _, _) = standIn()
        rt.calls.heardInvite(told(["state": "accepted"]))
        rt.calls.heardInvite(told(["to": "two words"]))
        rt.calls.heardInvite(told(["group": .null]))
        rt.calls.heardInvite(told(["id": .null]))
        XCTAssertEqual(rt.calls.invites(of: "g-1").count, 0)
    }

    func testTheLineTellsOfARing() async {
        let (rt, _, _) = standIn()
        rt.calls.onLine(["op": "invite", "id": "ring-9", "group": "g-1", "from": 34, "to": 43, "state": "ringing"], info: .null)
        await mainSettled()
        XCTAssertEqual(rt.calls.invites(of: "g-1").map(\.id), ["ring-9"])
    }
}
