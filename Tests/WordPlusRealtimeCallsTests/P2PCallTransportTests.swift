import Foundation
import XCTest
@testable import WordPlusRealtime
@testable import WordPlusRealtimeCalls

/// Better Messages' `p2pCall` as a transport, on a connection opened on its namespace with a stand-in socket: a request
/// goes as it is, with no token or tab of the SDK's own, each session hears only its own events, a call id that is a
/// number is the same call, and the connection coming back or moving is told. On that namespace the SDK's line isn't held.
final class P2PCallTransportTests: XCTestCase {
    private func betterMessages(namespace: String = "/") -> (Realtime, CallsSocket) {
        let rt = Realtime(RealtimeOptions(
            app: "site-9",
            endpoint: URL(string: "https://site.example/wp-json/better-messages/v1")!,
            server: URL(string: "https://nowhere.invalid")!,
            callbackQueue: DispatchQueue(label: "p2p-tests"),
            namespace: namespace,
            auth: namespace == "/" ? ["sid": "site-9", "uid": 7, "sk": "user-key"] : nil
        ))
        let socket = CallsSocket(rt)
        rt.socketAsked = socket
        return (rt, socket)
    }

    func testARequestGoesAsP2PCallAsItIs() async throws {
        let (rt, socket) = betterMessages()
        socket.answer = { event, data in event == "p2pCall" ? ["ok": true, "role": "polite", "op": data["op"] ?? .null] : nil }
        let transport = P2PCallTransport(rt)

        let join: JSONValue = ["op": "join", "call_id": "4711", "session": "s1", "epoch": 0, "last_id": nil]
        let reply: JSONValue? = await withCheckedContinuation { done in transport.send(join) { done.resume(returning: $0) } }
        XCTAssertEqual(reply?["op"], "join", "the relay's answer comes back")
        XCTAssertEqual(socket.asked("p2pCall"), [join], "nothing added: the socket is the user's, by its handshake")

        transport.send(["op": "leave", "call_id": "4711", "session": "s1", "reason": "hangup"], ack: nil)
        rt.queue.sync {}
        XCTAssertEqual(socket.asked("p2pCall").count, 2)
        XCTAssertTrue(socket.asked("call").isEmpty, "never the SDK's own `call` request")
    }

    func testEachSessionHearsItsOwnEvents() {
        let (rt, _) = betterMessages()
        let transport = P2PCallTransport(rt)
        let mine = LockedValues(), theirs = LockedValues()
        let stop = transport.listen(callId: "4711", session: "s1") { mine.append($0) }
        _ = transport.listen(callId: "4711", session: "s2") { theirs.append($0) }
        rt.queue.sync {}

        let ready: JSONValue = ["op": "ready", "call_id": 4711, "session": "s1", "generation": 1]
        rt.queue.sync { rt.event("p2pCall", ready) }
        rt.queue.sync { rt.event("p2pCall", ["op": "ended", "call_id": "4711", "session": "s2", "reason": "hangup"]) }
        rt.queue.sync { rt.event("p2pCall", ["op": "ready", "call_id": "4712", "session": "s1"]) }
        XCTAssertEqual(mine.items, [ready], "a call id that is a number is the same call")
        XCTAssertEqual(theirs.items.map { $0["op"] }, ["ended"])

        stop()
        rt.queue.sync { rt.event("p2pCall", ready) }
        XCTAssertEqual(mine.items.count, 1, "nothing after it stopped listening")
    }

    func testTheConnectionMovingIsTold() {
        let (rt, _) = betterMessages()
        let transport = P2PCallTransport(rt)
        let told = expectation(description: "told")
        let stop = transport.onReconnect { told.fulfill() }
        rt.queue.sync {}
        rt.queue.sync { rt.event("moved", .null) }
        wait(for: [told], timeout: 2)
        stop()
    }

    func testOnAnotherNamespaceTheSDKsLineIsNotHeld() async {
        for (namespace, holds) in [("/", false), ("/channels", true)] {
            let (rt, socket) = betterMessages(namespace: namespace)
            let asked = CallsRouteAsked()
            rt.calls.routeAsked = { body in
                asked.add(body)
                return (200, ["token": "line-token", "exp": .number(Date().timeIntervalSince1970 + 3600)])
            }
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                rt.queue.async { rt.holdAll(on: socket) { _ in done.resume() } }
            }
            if holds {
                let deadline = Date().addingTimeInterval(5)
                while socket.asked("line").isEmpty, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
            }
            XCTAssertEqual(asked.bodies.contains { $0["line"] != nil }, holds, namespace)
            XCTAssertEqual(!socket.asked("line").isEmpty, holds, namespace)
        }
    }
}

/// Values a handler heard on another queue.
final class LockedValues: @unchecked Sendable {
    private var stored: [JSONValue] = []
    private let lock = NSLock()

    var items: [JSONValue] { lock.withLock { stored } }

    func append(_ value: JSONValue) {
        lock.withLock { stored.append(value) }
    }
}
