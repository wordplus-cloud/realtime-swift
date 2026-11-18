import Foundation
@_spi(WordPlusModules) import WordPlusRealtime

/**
 How a call's signalling reaches the relay, and the relay's answers and events come back: the one seam between the SDK's
 call engine and what carries it, as the web's `calls/transport.ts`. The SDK's own calls take the realtime connection's
 `call` request, `P2PCallTransport` takes Better Messages' `p2pCall`, and an app may carry them its own way, to a relay
 that answers the same ops: `join`, `signal`, `sync`, `ice_servers`, `alive`, `pulse`, `report`, `trace`, `failed` and
 `leave`, as the realtime server's does.

 Hand one to `RealtimeCalls.call(over:id:role:peer:peerInfo:type:signalKey:mediaKey:)`: the call runs on the SDK's engine,
 and shows on its call screen, as any other. The engine calls the transport on the main queue, and reads `connected`
 there. The transport may answer on any queue: `ack`, the events and the reconnects are taken to the main queue in the
 order they are called.
 */
public protocol CallTransport: AnyObject {
    /// Whether a request sent now would go out. While it is false the engine holds what it would send, a signal up to the
    /// relay's 45 seconds of grace, and joins again once `onReconnect` says the transport is back.
    var connected: Bool { get }

    /// One op to the relay. `payload` is an object holding `op`, `call_id` and `session`, and the op's own fields. `ack`,
    /// when given, wants the relay's answer (`{ "ok": true, … }`, or `{ "ok": false, "error": … }`), or nil when none came:
    /// the engine gives up on an answer after 8 seconds and asks again as often as the op deserves, so the transport needs
    /// no timer of its own. With no `ack`, the op wants no answer.
    func send(_ payload: JSONValue, ack: ((JSONValue?) -> Void)?)

    /// The relay's events for one session of one call, each an object with `op` (`ready`, `signal`, `peer_lost`,
    /// `peer_back`, `fallback` or `ended`), `call_id` and `session`. Several calls, and several sessions of one, may share a
    /// transport, so it hands each only its own. Answers what stops listening.
    func listen(callId: String, session: String, _ handler: @escaping (JSONValue) -> Void) -> () -> Void

    /// Called each time the transport is back after a drop, or on another connection, such as after a move to another
    /// node: the engine joins the call again there, and the relay replays what it missed. Answers what stops it.
    func onReconnect(_ listener: @escaping () -> Void) -> () -> Void
}

/// Whether a connection that still says it is connected answers anything, and how long its answers take, as the web's
/// `calls/signaling.ts` (`SOCKET_STALL`). Stalled: a request has waited `stall` and nothing at all has been answered
/// meanwhile. The connection only finds out at its ping timeout, up to three quarters of a minute later, and until then
/// whatever this side sends sits in it: a Firefox caller's socket stalled for 47 s on 31 Oct 2026 while its audio kept
/// flowing, and the ICE restart it made meanwhile arrived after the connection had come back on its own. A slow
/// connection that does answer, however late each answer, is not stalled: the clock runs from the last answer, a late
/// one included. A stall, once seen, lasts until something is answered: the requests that found it time out and are
/// tried again, or given up, and that is not the connection coming back.
final class CallSocketWatch {
    static let stall: TimeInterval = 5
    static let roundTripsKept = 5

    private var inflight: [Int: Date] = [:]
    private var seq = 0
    private var lastAnswerAt: Date?
    private var stalledSince: Date?
    private var roundTrips: [TimeInterval] = []
    private let lock = NSLock()

    /// A request on the wire; `settled` takes it off.
    func sent(at: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        seq += 1
        inflight[seq] = at
        return seq
    }

    /// Answered, or given up on (`answered` false: timed out).
    func settled(_ id: Int, answered: Bool, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        let sentAt = inflight.removeValue(forKey: id)
        guard answered else {
            // Timed out with nothing answered since it went: the stall it waited through is one, whether or not
            // anyone asked meanwhile.
            if let sentAt, stalledSince == nil {
                let since = max(sentAt, lastAnswerAt ?? sentAt)
                if now.timeIntervalSince(since) >= CallSocketWatch.stall { stalledSince = since }
            }
            return
        }
        lastAnswerAt = now
        stalledSince = nil
        if let sentAt {
            roundTrips.append(now.timeIntervalSince(sentAt))
            if roundTrips.count > CallSocketWatch.roundTripsKept { roundTrips.removeFirst() }
        }
    }

    /// How long nothing has been answered with a request waiting, once that is `stall` or more; 0 otherwise.
    func stalledFor(now: Date = Date()) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        if stalledSince == nil, let oldest = inflight.values.min() {
            let since = max(oldest, lastAnswerAt ?? oldest)
            if now.timeIntervalSince(since) >= CallSocketWatch.stall { stalledSince = since }
        }
        return stalledSince.map { now.timeIntervalSince($0) } ?? 0
    }

    /// The longest of the latest round trips, in seconds: 0 before any.
    var roundTrip: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return roundTrips.max() ?? 0
    }
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

    /// Signals go in their order. To a relay whose join says it handles them in order (`ordered`), each goes once the
    /// one before is on the wire, which a connected socket keeps in order; to any other, once the one before is
    /// answered, as before, since one before 30 Oct 2026 relayed two that came together the other way round. Waiting
    /// for each answer, a side that heard the relay late sent one signal a round trip: six seconds behind, a caller's
    /// answer to the other side's restart sat behind its own candidates until the restart was given up (the web engine,
    /// 30 Oct 2026). A quick answer still goes first, up to `signalPipeline`, and a signal whose answer is lost is sent
    /// again by itself, which the relay drops by its nonce. While the socket is down they wait for it in order. The web
    /// does the same.
    private static let signalPipeline: TimeInterval = 0.25
    private var ordered = false
    private var signals: [(@escaping () -> Void) -> Void] = []
    private var signalling = false

    init(transport: CallTransport, callId: String, onMessage: @escaping ([String: Any]) -> Void) {
        self.transport = transport
        self.callId = callId
        // A transport may hand its events over on any queue: they reach the session on the main one, in their order.
        stopListening = transport.listen(callId: callId, session: session) { [weak self] message in
            DispatchQueue.main.async {
                guard let self, !self.isClosed, let fields = message.anyValue as? [String: Any] else { return }
                onMessage(fields)
            }
        }
    }

    var connected: Bool { transport.connected }

    /// What the connection has answered, for a stall and the round trip (`CallSocketWatch`).
    private let socketWatch = CallSocketWatch()

    /// How long the connection has sat on a request with nothing at all answered, once that is long enough to count;
    /// 0 otherwise, and 0 for a connection that is down, which the session reads first.
    func stalledFor(now: Date = Date()) -> TimeInterval {
        guard connected, !isClosed else { return 0 }
        return socketWatch.stalledFor(now: now)
    }

    /// The longest of the latest round trips to the relay and back, in seconds: 0 before any.
    var roundTrip: TimeInterval { socketWatch.roundTrip }

    func join(epoch: Int, lastId: String?, resume: Bool, _ done: @escaping ([String: Any]?) -> Void) {
        var payload: [String: Any] = ["op": "join", "epoch": epoch, "last_id": lastId ?? NSNull()]
        if resume { payload["resume"] = true }
        request(payload, attempts: 3) { [weak self] reply in
            if reply?["ordered"] as? Bool == true { self?.ordered = true }
            done(reply)
        }
    }

    func signal(generation: Int, body: [String: Any], _ done: @escaping ([String: Any]?) -> Void) {
        let payload: [String: Any] = ["op": "signal", "generation": generation, "nonce": CallSignaling.randomId(16), "body": body]
        signals.append { [weak self] next in
            guard let self else { return next() }
            var released = false
            let release = {
                guard !released else { return }
                released = true
                next()
            }
            self.request(payload, attempts: 5, offlineWait: CallSignaling.offlineWait, onSent: self.ordered ? {
                DispatchQueue.main.asyncAfter(deadline: .now() + CallSignaling.signalPipeline) { release() }
            } : nil) { reply in
                done(reply)
                release()
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

    /// This side's counters, and its quality reading when one is due (`CallQuality.swift`).
    func pulse(_ body: [String: Any], quality: [String: Any]? = nil, _ done: @escaping ([String: Any]?) -> Void) {
        var payload: [String: Any] = ["op": "pulse", "pulse": body]
        if let quality { payload["quality"] = quality }
        request(payload, attempts: 1, done)
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
        transport.send(["op": "leave", "reason": .string(reason), "call_id": .string(callId), "session": .string(session)], ack: nil)
    }

    func close() {
        isClosed = true
        stopListening?()
        stopListening = nil
        signals.removeAll()
    }

    /// One request, tried `attempts` times; with `offlineWait`, the seconds the socket is down count only after that.
    /// `onSent` is told once, when it first goes out on a connected socket.
    private func request(_ payload: [String: Any], attempts: Int, offlineWait: Int = 0, onSent: (() -> Void)? = nil, _ done: @escaping ([String: Any]?) -> Void) {
        var waited = 0
        var told = false
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
            let onWire = socketWatch.sent()
            let timer = DispatchWorkItem { [socketWatch] in
                guard !settled else { return }
                settled = true
                socketWatch.settled(onWire, answered: false)
                if n < attempts { attempt(n + 1) } else { done(nil) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + CallSignaling.ackTimeout, execute: timer)
            transport.send(JSONValue.from(any: body)) { [socketWatch] answer in
                // On the main queue, whichever the transport answered on.
                DispatchQueue.main.async {
                    let reply = answer?.anyValue as? [String: Any]
                    // Late or not: an answer is the connection carrying answers again.
                    socketWatch.settled(onWire, answered: reply != nil)
                    guard !settled, let reply else { return }
                    settled = true
                    timer.cancel()
                    done(reply)
                }
            }
            if !told, let onSent {
                told = true
                onSent()
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
