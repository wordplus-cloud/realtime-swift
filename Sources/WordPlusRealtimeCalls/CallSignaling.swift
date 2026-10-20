import Foundation

/// How a call's session reaches the relay: the one seam between the call engine and what it runs in, as the web's
/// `calls/transport.ts`. The SDK's is the realtime connection's `call` request (Calls.swift).
protocol CallTransport: AnyObject {
    var connected: Bool { get }
    /// An op to the relay, `call_id` and `session` already in it; its answer (nil when none came) on the main queue.
    func send(_ payload: [String: Any], ack: (([String: Any]?) -> Void)?)
    /// The relay's events for one session of one call, on the main queue. Answers what stops listening.
    func listen(callId: String, session: String, _ handler: @escaping ([String: Any]) -> Void) -> () -> Void
    /// Called after each reconnect and each move to another node, on the main queue. Answers what stops it.
    func onReconnect(_ listener: @escaping () -> Void) -> () -> Void
}

/// A call's requests to the relay, each tried as often as it deserves, as the web's `calls/signaling.ts`: a signal is
/// the negotiation itself and must arrive, a pulse comes round again in two seconds. Everything on the main queue.
final class CallSignaling {
    /// How long an answer is waited for before the request is tried again.
    private static let ackTimeout: TimeInterval = 8

    /// How long a signal, or the word that the direct path failed, sits out a socket that is down before the seconds
    /// start counting as attempts: the relay gives a side whose socket has gone this long to come back.
    private static let offlineWait = 45

    /// 16 characters from [A-Za-z0-9], the shape the web uses; the relay names it back in every message.
    let session = CallSignaling.randomId(16)

    private let transport: CallTransport
    private let callId: String
    private var stopListening: (() -> Void)?
    private(set) var isClosed = false

    /// Signals go one after another, each once the one before is answered: negotiation depends on their order.
    private var signals: [(@escaping () -> Void) -> Void] = []
    private var signalling = false

    init(transport: CallTransport, callId: String, onMessage: @escaping ([String: Any]) -> Void) {
        self.transport = transport
        self.callId = callId
        stopListening = transport.listen(callId: callId, session: session) { [weak self] message in
            guard let self, !self.isClosed else { return }
            onMessage(message)
        }
    }

    var connected: Bool { transport.connected }

    func join(epoch: Int, lastId: String?, resume: Bool, _ done: @escaping ([String: Any]?) -> Void) {
        var payload: [String: Any] = ["op": "join", "epoch": epoch, "last_id": lastId ?? NSNull()]
        if resume { payload["resume"] = true }
        request(payload, attempts: 3, done)
    }

    func signal(generation: Int, body: [String: Any], _ done: @escaping ([String: Any]?) -> Void) {
        let payload: [String: Any] = ["op": "signal", "generation": generation, "nonce": CallSignaling.randomId(16), "body": body]
        signals.append { [weak self] next in
            guard let self else { return next() }
            self.request(payload, attempts: 5, offlineWait: CallSignaling.offlineWait) { reply in
                done(reply)
                next()
            }
        }
        pumpSignals()
    }

    private func pumpSignals() {
        guard !signalling, !signals.isEmpty else { return }
        signalling = true
        let task = signals.removeFirst()
        task { [weak self] in
            self?.signalling = false
            self?.pumpSignals()
        }
    }

    /// Asked for on the way into an ICE restart, which must not wait on it: one attempt.
    func iceServers(_ done: @escaping ([String: Any]?) -> Void) {
        request(["op": "ice_servers"], attempts: 1, done)
    }

    func alive(_ done: @escaping ([String: Any]?) -> Void) {
        request(["op": "alive"], attempts: 1, done)
    }

    func pulse(_ body: [String: Any], _ done: @escaping ([String: Any]?) -> Void) {
        request(["op": "pulse", "pulse": body], attempts: 1, done)
    }

    func report(_ report: [String: Any]) {
        request(["op": "report", "report": report], attempts: 1) { _ in }
    }

    func trace(_ lines: [String], _ done: @escaping ([String: Any]?) -> Void) {
        request(["op": "trace", "lines": lines], attempts: 3, done)
    }

    func failed(_ reason: String, _ done: @escaping ([String: Any]?) -> Void) {
        request(["op": "failed", "reason": reason], attempts: 3, offlineWait: CallSignaling.offlineWait, done)
    }

    func leave(_ reason: String) {
        request(["op": "leave", "reason": reason], attempts: 2) { _ in }
    }

    /// A leave sent once with no wait, for a session that never joined or has handed off: the relay takes it either way.
    func leaveNow(_ reason: String) {
        transport.send(["op": "leave", "reason": reason, "call_id": callId, "session": session], ack: nil)
    }

    func close() {
        isClosed = true
        stopListening?()
        stopListening = nil
        signals.removeAll()
    }

    /// One request, tried `attempts` times; with `offlineWait`, the seconds the socket is down count only after that.
    private func request(_ payload: [String: Any], attempts: Int, offlineWait: Int = 0, _ done: @escaping ([String: Any]?) -> Void) {
        var waited = 0
        var body = payload
        body["call_id"] = callId
        body["session"] = session

        func attempt(_ n: Int) {
            if isClosed && (payload["op"] as? String) != "leave" { return done(nil) }
            if !connected {
                if waited < offlineWait {
                    waited += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { attempt(n) }
                } else if n < attempts {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { attempt(n + 1) }
                } else {
                    done(nil)
                }
                return
            }
            var settled = false
            let timer = DispatchWorkItem {
                guard !settled else { return }
                settled = true
                if n < attempts { attempt(n + 1) } else { done(nil) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + CallSignaling.ackTimeout, execute: timer)
            transport.send(body) { reply in
                guard !settled, let reply else { return }
                settled = true
                timer.cancel()
                done(reply)
            }
        }

        attempt(1)
    }

    static func randomId(_ length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int(generator.next(upperBound: UInt64(alphabet.count)))] })
    }
}
