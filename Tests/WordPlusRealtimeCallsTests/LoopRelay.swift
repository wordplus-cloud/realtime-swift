import Foundation
// The public API alone, as an app has it: no `@testable`, and no `@_spi`. This file compiling is the proof that a transport
// of an app's own can be written against the SDK as it ships.
import WordPlusRealtime
import WordPlusRealtimeCalls

/// A relay of the test's own for one call between two people, each side reaching it through a `CallTransport` an app could
/// write: what Better Messages' calls would carry over its socket, carried here in the process. It answers the ops as the
/// realtime server's relay does for a direct call (inc/calls/p2p/relay.ts): a join with this side's role and who the other
/// is, `ready` to both once both are in, each signal to the other side with an id of its own and those sent before a side
/// joined replayed in its join, and a leave told to the other as `ended`. Every op it heard is kept, in order.
final class LoopRelay: @unchecked Sendable {
    /// One side of the call: its transport, and what it asked.
    final class Side: CallTransport, @unchecked Sendable {
        let user: String
        // Held, as an app's transport holds what it sends on: the engine may still send a leave after the test is done.
        fileprivate let relay: LoopRelay
        fileprivate var handlers: [String: (JSONValue) -> Void] = [:]
        fileprivate var reconnects: [UUID: () -> Void] = [:]
        fileprivate var session: String?
        fileprivate var waiting: [JSONValue] = []
        fileprivate var asked: [JSONValue] = []
        private var up = true

        fileprivate init(user: String, relay: LoopRelay) {
            self.user = user
            self.relay = relay
        }

        var connected: Bool { relay.lock.withLock { up } }

        func send(_ payload: JSONValue, ack: ((JSONValue?) -> Void)?) {
            // Answered on the relay's own queue, as a socket's answers come: the engine takes them to the main queue.
            relay.queue.async { [self] in
                let answer = relay.handle(payload, from: self)
                ack?(answer)
            }
        }

        func listen(callId: String, session: String, _ handler: @escaping (JSONValue) -> Void) -> () -> Void {
            let key = callId + ":" + session
            relay.lock.withLock { handlers[key] = handler }
            return { [weak self] in
                guard let self else { return }
                self.relay.lock.withLock { self.handlers[key] = nil }
            }
        }

        func onReconnect(_ listener: @escaping () -> Void) -> () -> Void {
            let token = UUID()
            relay.lock.withLock { reconnects[token] = listener }
            return { [weak self] in
                guard let self else { return }
                self.relay.lock.withLock { self.reconnects[token] = nil }
            }
        }

        /// The ops this side asked, in order, each with its fields.
        var ops: [JSONValue] { relay.lock.withLock { asked } }

        /// The transport drops, and is back a moment later, as a connection that moved to another node.
        func dropAndComeBack() {
            relay.lock.withLock { up = false }
            relay.queue.asyncAfter(deadline: .now() + 0.3) { [self] in
                let listeners = relay.lock.withLock {
                    up = true
                    return Array(reconnects.values)
                }
                listeners.forEach { $0() }
            }
        }

        fileprivate func deliver(_ message: JSONValue) {
            let key = (message["call_id"]?.string ?? "") + ":" + (message["session"]?.string ?? "")
            let handler = relay.lock.withLock { handlers[key] }
            handler?(message)
        }
    }

    let callId: String
    private(set) var caller: Side!
    private(set) var callee: Side!
    fileprivate let lock = NSLock()
    fileprivate let queue = DispatchQueue(label: "loop-relay")
    private var signals = 0
    private var readied = false

    init(callId: String, caller: String, callee: String) {
        self.callId = callId
        self.caller = Side(user: caller, relay: self)
        self.callee = Side(user: callee, relay: self)
    }

    private func other(_ side: Side) -> Side { side === caller ? callee : caller }

    /// An op, on the relay's queue: its answer, as the realtime server's relay gives it.
    fileprivate func handle(_ payload: JSONValue, from side: Side) -> JSONValue? {
        lock.withLock { side.asked.append(payload) }
        guard payload["call_id"]?.string == callId, let session = payload["session"]?.string else { return ["ok": false, "error": "no_call"] }
        let peer = other(side)
        switch payload["op"]?.string {
        case "join":
            let replay: [JSONValue] = lock.withLock {
                side.session = session
                defer { side.waiting = [] }
                return side.waiting
            }
            let present = lock.withLock { peer.session != nil }
            let answer: JSONValue = [
                "ok": true, "mode": "p2p", "ordered": true, "generation": 1, "ice_servers": [],
                "role": side === caller ? "impolite" : "polite",
                "peer": ["user_id": .string(peer.user), "present": .bool(present)],
                "replay": .array(replay),
            ]
            if present, !readied {
                readied = true
                queue.async { [self] in
                    for one in [caller!, callee!] {
                        let them = other(one)
                        one.deliver(["op": "ready", "call_id": .string(callId), "session": .string(lock.withLock { one.session } ?? ""), "generation": 1, "peer": ["user_id": .string(them.user)]])
                    }
                }
            }
            return answer
        case "signal":
            signals += 1
            var message: JSONValue = ["op": "signal", "call_id": .string(callId), "generation": payload["generation"] ?? 1, "body": payload["body"] ?? .null, "id": .string("\(signals)-0")]
            if let theirs = lock.withLock({ peer.session }) {
                if case var .object(fields) = message {
                    fields["session"] = .string(theirs)
                    message = .object(fields)
                }
                peer.deliver(message)
            } else {
                lock.withLock { peer.waiting.append(message) }
            }
            return ["ok": true]
        case "leave":
            if let theirs = lock.withLock({ peer.session }) {
                peer.deliver(["op": "ended", "call_id": .string(callId), "session": .string(theirs), "reason": payload["reason"] ?? "hangup"])
            }
            return ["ok": true]
        case "ice_servers":
            return ["ok": true, "ice_servers": []]
        default:
            // alive, pulse, report, trace, sync, failed: taken.
            return ["ok": true, "mode": "p2p"]
        }
    }
}
