@testable import LiveKit
import XCTest
@testable import WordPlusRealtime
@_spi(WordPlusUI) @testable import WordPlusRealtimeCalls

/// A join waiting for a place on the mesh, as the browser's group calls and streams tell it (realtime-client
/// group-call.ts:284-288, stream.ts:187, 408), and what carries a call as it changes (calls.ts:800). The state stays
/// `connecting`, since a new case would break a `switch` over it in every app: `waiting` says the rest. With no server.
@MainActor
final class CallWaitingTests: XCTestCase {
    private let wait = CallWait(until: Date(timeIntervalSince1970: 1_760_000_000), reason: "busy")

    private func group() -> (Realtime, GroupCall) {
        let (rt, _, _) = standInCalls()
        return (rt, GroupCall(owner: rt.calls, name: "meeting:7", link: nil, key: nil, microphone: false, camera: false))
    }

    private func call() -> (Realtime, Call) {
        let (rt, socket, _) = standInCalls()
        socket.answer = { _, _ in ["ok": true, "server": "wss://nowhere.invalid", "token": "room-token"] }
        let call = Call(owner: rt.calls, id: "call-1", name: "support:34:42", type: .audio, role: .caller, peer: "34", peerInfo: .null, request: [:], grant: ["token": "t"])
        return (rt, call)
    }

    func testAGroupCallWaitsAndSaysSo() {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        var heard: [CallWait] = []
        call.onWaiting { heard.append($0) }
        XCTAssertNil(call.waiting)

        call.heardWait(wait)
        XCTAssertEqual(call.waiting, wait)
        XCTAssertEqual(heard, [wait])
        XCTAssertEqual(call.state, .connecting, "a new state would break a switch over it")
    }

    func testAGroupCallConnectedWaitsNoMore() {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        var heard = 0
        call.onWaiting { _ in heard += 1 }
        call.heardWait(wait)

        call.room(call.liveKitRoom, didCompleteReconnectWithMode: .quick)
        let settled = expectation(description: "on the main queue")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(call.state, .connected)
        XCTAssertNil(call.waiting)

        call.heardWait(wait)
        XCTAssertNil(call.waiting, "a wait heard late is over")
        XCTAssertEqual(heard, 1)
    }

    func testAGroupCallLeftWaitsNoMore() {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        call.heardWait(wait)
        call.leave()
        XCTAssertNil(call.waiting)
    }

    func testAWaitingHandlerComesOff() {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        var heard = 0
        let listener = call.onWaiting { _ in heard += 1 }
        call.off(listener)
        call.heardWait(wait)
        XCTAssertEqual(heard, 0)
    }

    func testTheConnectTellsOfTheWait() {
        var told: [MeshWait] = []
        let caps = CallCodecCaps(families: [:], canSwitch: false)
        let options = GroupShapes.connectOptions(settings: .none, iceServers: [], caps: caps) { told.append($0) }
        options.onMeshWait?(MeshWait(until: Date(timeIntervalSince1970: 1), reason: .full))
        XCTAssertEqual(told.map(\.reason), [.full])
        XCTAssertNil(GroupShapes.connectOptions(settings: .none, iceServers: [], caps: caps).onMeshWait)
        XCTAssertEqual(CallWait(MeshWait(until: Date(timeIntervalSince1970: 1), reason: .unreachable)), CallWait(until: Date(timeIntervalSince1970: 1), reason: "unreachable"))
    }

    func testAPathChangedIsHeardOnce() {
        let (rt, call) = call()
        defer { withExtendedLifetime(rt) {} }
        var heard: [CallPath] = []
        call.onPath { heard.append($0) }

        call.setPath(.direct)
        call.setPath(.direct)
        call.setPath(.relay)
        XCTAssertEqual(call.path, .relay)
        XCTAssertEqual(heard, [.direct, .relay])
        call.end()
    }

    func testACallMovedToARoomSaysSoAndTellsOfItsWait() async throws {
        let (rt, call) = call()
        defer { withExtendedLifetime(rt) {} }
        var paths: [CallPath] = []
        var waits: [CallWait] = []
        call.onPath { paths.append($0) }
        call.onWaiting { waits.append($0) }

        call.toRoom(try XCTUnwrap(CallRoomTicket(["token": "t", "server": "wss://nowhere.invalid"])))
        XCTAssertEqual(paths, [.room])
        await mainSettled()
        let room = try XCTUnwrap(call.carryingRoom)
        room.heardWait(wait)
        XCTAssertEqual(waits, [wait])
        XCTAssertEqual(call.state, .connecting)
        call.end()
    }

    /// As the browser's player infers it (realtime-client streams/client.ts:1565, 1612): the room doesn't say why it refuses.
    func testAFullStreamWaitsForAPlaceAndSaysSo() {
        let (rt, _) = group()
        defer { withExtendedLifetime(rt) {} }
        let stream = LiveStream(owner: rt.calls, name: "show:1")
        var heard: [CallWait] = []
        stream.onWaiting { heard.append($0) }
        stream.apply("viewers", ["n": 50])

        // No limit, or room for more: a join that takes a while is only that, and a failed one is out of it.
        stream.media = .connecting
        stream.waitIfFull()
        XCTAssertNil(stream.waiting)
        stream.audience = 51
        stream.waitIfFull()
        XCTAssertNil(stream.waiting)
        stream.joinFailed(asViewer: true)
        XCTAssertNil(stream.waiting)
        XCTAssertEqual(stream.media, .reconnecting)

        // As many watch as it takes.
        stream.audience = 50
        stream.media = .connecting
        let before = Date()
        stream.waitIfFull()
        XCTAssertEqual(stream.waiting?.reason, "full")
        XCTAssertGreaterThanOrEqual(stream.waiting!.until.timeIntervalSince(before), LiveStream.fullRetry)
        XCTAssertEqual(heard.count, 1)

        // Refused while full: still joining, as far as the app goes, and told again.
        stream.joinFailed(asViewer: true)
        XCTAssertEqual(stream.media, .connecting)
        XCTAssertEqual(stream.waiting?.reason, "full")
        XCTAssertEqual(heard.count, 2)

        // A host or a guest takes no place among those watching.
        stream.media = .connecting
        stream.joinFailed(asViewer: false)
        XCTAssertEqual(stream.media, .reconnecting)
        XCTAssertNil(stream.waiting)
    }

    func testAStreamWaitsAndSaysSo() {
        let rt = Realtime(RealtimeOptions(app: "app_test", endpoint: URL(string: "https://shop.example/api/realtime")!))
        let stream = LiveStream(owner: rt.calls, name: "show:1")
        var heard: [CallWait] = []
        var changes = 0
        stream.onWaiting { heard.append($0) }
        stream.onChange { changes += 1 }

        stream.heardWait(wait)
        XCTAssertNil(stream.waiting, "nothing waits with no join under way")

        stream.media = .connecting
        stream.heardWait(wait)
        XCTAssertEqual(stream.waiting, wait)
        XCTAssertEqual(heard, [wait])
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(stream.media, .connecting, "a new media would break a switch over it")

        stream.media = .live
        XCTAssertNil(stream.waiting)
        stream.heardWait(wait)
        XCTAssertEqual(heard, [wait])

        stream.media = .connecting
        stream.heardWait(wait)
        stream.media = .off
        XCTAssertNil(stream.waiting)
    }
}
