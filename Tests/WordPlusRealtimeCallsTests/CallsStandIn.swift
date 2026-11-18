import Foundation
@testable import WordPlusRealtime
@testable import WordPlusRealtimeCalls

/// A socket for the tests of calls, in place of a realtime server: what it was asked, in order, and what it answers each
/// with, on the connection's queue as a socket's answers come. Nil from `answer` is no answer.
final class CallsSocket: RoomSocket {
    var isConnected = true
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var _asked: [(event: String, data: JSONValue)] = []
    var answer: (String, JSONValue) -> JSONValue? = { _, _ in ["ok": true] }

    init(_ rt: Realtime) {
        queue = rt.queue
    }

    var asked: [(event: String, data: JSONValue)] { lock.withLock { _asked } }

    func asked(_ event: String) -> [JSONValue] {
        asked.filter { $0.event == event }.map(\.data)
    }

    func send(_ event: String, _ data: JSONValue, timeout: TimeInterval, ack: ((JSONValue?) -> Void)?) {
        lock.withLock { _asked.append((event, data)) }
        guard let ack else { return }
        let reply = answer(event, data)
        queue.async { ack(reply) }
    }
}

/// What the calls route was asked, in order, and when.
final class CallsRouteAsked: @unchecked Sendable {
    private let lock = NSLock()
    private var _bodies: [[String: JSONValue]] = []
    private var _at: [Date] = []

    var bodies: [[String: JSONValue]] { lock.withLock { _bodies } }
    var at: [Date] { lock.withLock { _at } }

    func add(_ body: [String: JSONValue]) {
        lock.withLock {
            _bodies.append(body)
            _at.append(Date())
        }
    }
}

/// A connection with no server: its calls route answers `route`, and its socket is a stand-in.
func standInCalls(route: @escaping ([String: JSONValue]) -> (Int, JSONValue?) = { _ in (200, ["token": "t"]) }) -> (rt: Realtime, socket: CallsSocket, route: CallsRouteAsked) {
    let rt = Realtime(RealtimeOptions(app: "app_test", endpoint: URL(string: "https://shop.example/api/realtime")!))
    let socket = CallsSocket(rt)
    let asked = CallsRouteAsked()
    rt.socketAsked = socket
    rt.calls.connectedAsked = true
    rt.calls.routeAsked = { body in
        // The line goes on holding by itself: the tests look at what the app asks.
        if body["line"] == nil { asked.add(body) }
        return route(body)
    }
    return (rt, socket, asked)
}

/// What the main queue has waiting has run, the handlers it was given included.
func mainSettled() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
