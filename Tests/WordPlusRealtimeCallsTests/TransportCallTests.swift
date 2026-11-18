import Foundation
import XCTest
@testable import WordPlusRealtime
@testable import WordPlusRealtimeCalls

/// A call between two people carried end to end by a transport of the test's own (`LoopRelay`, written with the public
/// API alone): both sides join, the relay carries their offer, answer and candidates, the direct connection comes up
/// between them in this process, a drop of one side's transport has it join again, and a hang-up ends the call for the
/// other side. No server; the microphone and camera stay closed.
final class TransportCallTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CallPermissions.answerAsked = { _ in false }
    }

    override func tearDown() {
        CallPermissions.answerAsked = nil
        super.tearDown()
    }

    /// Two connections with no server, one for each side.
    private func connections() -> (Realtime, Realtime) {
        let make = { Realtime(RealtimeOptions(app: "s1500000007", endpoint: URL(string: "https://shop.example/api/realtime")!, server: URL(string: "https://nowhere.invalid")!)) }
        return (make(), make())
    }

    @MainActor
    private func until(_ timeout: TimeInterval = 20, _ done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    @MainActor
    func testACallCarriedByATransportOfTheAppsOwnConnectsAndEnds() async throws {
        let relay = LoopRelay(callId: "4711", caller: "34", callee: "42")
        let (ann, ben) = connections()
        var heard: [Call] = []
        ann.calls.onCall { heard.append($0) }
        await mainSettled()

        let calling = try await ann.calls.call(over: relay.caller, id: "4711", role: .caller, peer: "42", peerInfo: ["name": "Ben"], type: .audio, signalKey: "the call's own key")
        XCTAssertEqual(calling.state, .ringing, "a caller rings until the other side joins")
        XCTAssertEqual(calling.peer, "42")
        XCTAssertEqual(calling.peerInfo["name"]?.string, "Ben")
        XCTAssertTrue(heard.first === calling, "onCall hears it, so the call screen does")

        let answering = try await ben.calls.call(over: relay.callee, id: "4711", role: .callee, peer: "34", type: .audio, signalKey: "the call's own key")
        await until { calling.state == .connected && answering.state == .connected }
        XCTAssertEqual(calling.state, .connected, "the direct connection is up for the caller")
        XCTAssertEqual(answering.state, .connected, "and for the callee")
        // Read off the connection's report, every two seconds.
        await until(5) { calling.path != nil }
        XCTAssertEqual(calling.path, .direct)

        // The relay carried the negotiation: sealed with the call's key, as it never sees it.
        let signals = relay.caller.ops.filter { $0["op"]?.string == "signal" }
        XCTAssertFalse(signals.isEmpty)
        XCTAssertTrue(signals.allSatisfy { $0["body"]?["sealed"] == 1 && $0["body"]?["kind"] == nil }, "no signal goes in the clear")
        XCTAssertTrue(signals.allSatisfy { $0["generation"] == 1 && $0["nonce"]?.string != nil })

        // One side's transport drops and comes back: it joins the call again there, and the call goes on.
        let joins = relay.callee.ops.filter { $0["op"]?.string == "join" }.count
        relay.callee.dropAndComeBack()
        await until { relay.callee.ops.filter { $0["op"]?.string == "join" }.count > joins }
        let rejoin = try XCTUnwrap(relay.callee.ops.last { $0["op"]?.string == "join" })
        XCTAssertEqual(rejoin["resume"], true, "joined again as the same session")
        await until(5) { answering.state == .connected }
        XCTAssertEqual(answering.state, .connected)

        // A hang-up: the caller leaves, and the relay tells the callee.
        var ended: String?
        answering.onEnded { ended = $0 }
        calling.end()
        await until { ended != nil }
        XCTAssertEqual(calling.endReason, "hangup")
        XCTAssertEqual(ended, "hangup")
        XCTAssertEqual(relay.caller.ops.last?["op"]?.string, "leave")
        XCTAssertNil(relay.caller.ops.first { $0["token"] != nil || $0["tab"] != nil }, "nothing of the SDK's own transport goes on another")
    }

    @MainActor
    func testACallOnATransportOfItsOwnAddsNobody() async throws {
        let relay = LoopRelay(callId: "4712", caller: "34", callee: "42")
        let (ann, _) = connections()
        let call = try await ann.calls.call(over: relay.caller, id: "4712", role: .caller, peer: "42", type: .audio, signalKey: "k")
        await XCTAssertThrowsCode("not_supported") { _ = try await call.add("43") }
        call.end()
    }

    /// Better Messages' relay hands a room over by its token alone (its pages know the media server from the site), where
    /// the SDK's own names the mesh in it: a call on a transport of the app's own goes to the server the app gave.
    func testARoomHandedOverByItsTokenAloneIsOnTheServerTheAppGave() throws {
        let bare = try XCTUnwrap(CallRoomTicket(["token": "room-token", "room": "bm_9_4711"]))
        XCTAssertNil(bare.server)
        XCTAssertEqual(bare.at("wss://mesh.example").server, "wss://mesh.example")
        XCTAssertEqual(bare.at("wss://mesh.example").token, "room-token")
        XCTAssertNil(bare.at(nil).server, "nothing given, nothing named")
        let named = try XCTUnwrap(CallRoomTicket(["token": "room-token", "server": "wss://named.example"]))
        XCTAssertEqual(named.at("wss://mesh.example").server, "wss://named.example", "the relay's own address wins")
        XCTAssertNil(CallRoomTicket(["token": "room-token", "server": ""])?.server, "an empty address is none")
    }

    @MainActor
    func testAJoinTheRelayRefusesThrowsItsCode() async {
        let relay = LoopRelay(callId: "4713", caller: "34", callee: "42")
        let (ann, _) = connections()
        await XCTAssertThrowsCode("no_call") {
            _ = try await ann.calls.call(over: relay.caller, id: "another", role: .caller, peer: "42", type: .audio, signalKey: "k")
        }
    }
}
