import Foundation
@testable import WordPlusRealtime

/// A socket for the tests, in place of a realtime server: what it was asked, in order, and what it answers each with, on
/// the connection's queue as a socket's answers come. Nil from `answer` is no answer: the socket ended, or it timed out.
final class FakeSocket: RoomSocket {
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
