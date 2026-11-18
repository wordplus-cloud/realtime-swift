import Foundation
import XCTest
@testable import WordPlusRealtime

/// A volatile event with its ack, as the browser's rooms send it (realtime-client rooms.ts, `volatile.emitWithAck`): never
/// kept, so its answer has no id, and unlike one with no ack it waits for the room rather than being dropped.
final class VolatileTests: XCTestCase {
    private var rt: Realtime!
    private var socket: FakeSocket!

    override func setUp() {
        super.setUp()
        rt = Realtime(RealtimeOptions(
            app: "s1", endpoint: URL(string: "https://routes.test/api/realtime")!,
            grants: [PublicGrant(token: "t", exp: Date().timeIntervalSince1970 + 3600, rooms: ["chat:{a}:{b}"])]
        ))
        socket = FakeSocket(rt)
        rt.socketAsked = socket
    }

    private func joined(_ name: String) -> Room {
        let room = rt.join(name)
        rt.queue.sync { room.joined(members: nil, count: nil) }
        return room
    }

    func testItIsSentVolatileAndAnsweredWithNoId() async throws {
        socket.answer = { _, _ in ["ok": true] }
        let ack = try await joined("chat:34:42").volatile.emitWithAck("typing", ["on": true])

        XCTAssertEqual(ack, Ack(id: "", at: 0))
        let sent = try XCTUnwrap(socket.asked("emit").first)
        XCTAssertEqual(sent["room"], "chat:34:42")
        XCTAssertEqual(sent["event"], "typing")
        XCTAssertEqual(sent["v"], 1)
    }

    func testARefusalComesBackByItsCode() async {
        socket.answer = { _, _ in ["error": "rate_limited"] }
        do {
            try await joined("chat:34:42").volatile.emitWithAck("typing")
            XCTFail("no refusal")
        } catch {
            XCTAssertEqual(error as? RealtimeError, RealtimeError("rate_limited"))
        }
    }

    func testItWaitsForTheRoomWhereOneWithNoAckIsDropped() async throws {
        // The room's own join isn't answered, so it stays joining.
        socket.answer = { event, _ in event == "join" ? nil : ["ok": true] }
        let room = rt.join("chat:34:42")
        room.volatile.emit("typing")
        async let ack = room.volatile.emitWithAck("read", ["id": "1-0"])

        // Neither has gone: the one with no ack never will.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(socket.asked("emit").isEmpty)

        rt.queue.async { room.joined(members: nil, count: nil) }
        _ = try await ack
        XCTAssertEqual(socket.asked("emit").map { $0["event"] }, ["read"])
    }

    func testAKeptEventStillHasItsId() async throws {
        socket.answer = { _, _ in ["ok": true, "id": "1700000000000-0", "at": 1_700_000_000_000] }
        let ack = try await joined("chat:34:42").emitWithAck("message", ["text": "Hi"])
        XCTAssertEqual(ack, Ack(id: "1700000000000-0", at: 1_700_000_000_000))
        XCTAssertNil(socket.asked("emit").first?["v"])
    }
}
