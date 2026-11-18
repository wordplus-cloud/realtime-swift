import Foundation
@_spi(WordPlusModules) import WordPlusRealtime

/**
 Better Messages' signalling for its calls between two people: the `p2pCall` requests and events of its namespace of the
 realtime server, the web's transport in Better Messages, on a connection opened there. The relay behind it is the one the
 SDK's own calls reach on `/channels`, with the same ops; on Better Messages' namespace the socket is one user's, by its
 handshake, so a request carries no token.

     let rt = Realtime(RealtimeOptions(app: site, endpoint: siteREST, server: URL(string: "https://cloud.better-messages.com")!,
                                       namespace: "/", auth: ["sid": .string(site), "uid": .number(user), "sk": .string(key), "v": "3.2.0"]))
     rt.connect()
     let call = try await rt.calls.call(over: P2PCallTransport(rt), id: messageId, role: .callee, peer: caller, signalKey: key,
                                        roomServer: siteMediaServer)

 The connection reconnects, moves between nodes and keeps the nodes it knows as on any namespace, and the call joins again
 on each new socket. One transport serves every call of the connection, and lives as long as it does.
 */
public final class P2PCallTransport: CallTransport, @unchecked Sendable {
    private let rt: Realtime
    private let lock = NSLock()
    private var handlers: [String: (token: UUID, handler: (JSONValue) -> Void)] = [:]
    private var reconnects: [UUID: () -> Void] = [:]
    private var listeners: [Listener] = []

    /// On `rt`, a connection opened on Better Messages' namespace (`RealtimeOptions.namespace`, with its handshake in
    /// `auth`).
    public init(_ rt: Realtime) {
        self.rt = rt
        rt.onSocketEvent("p2pCall") { [weak self] message in self?.relayed(message) }
        // Back after a drop, and on a new socket after a move: each call joins again there.
        listeners.append(rt.onState { [weak self] state, _ in if state == .connected { self?.changed() } })
        listeners.append(rt.on("moved") { [weak self] _, _ in self?.changed() })
    }

    deinit {
        listeners.forEach(rt.off)
    }

    /// Whether the connection is up. Read on the main queue, as the engine reads it.
    public var connected: Bool { rt.state == .connected }

    /// A `p2pCall` request on the socket the connection holds now: nil to `ack` when there is none, or it doesn't answer
    /// within 10 seconds.
    public func send(_ payload: JSONValue, ack: ((JSONValue?) -> Void)?) {
        rt.moduleQueue.async { [rt] in
            guard let socket = rt.currentSocket else {
                ack?(nil)
                return
            }
            guard let ack else { return socket.emit("p2pCall", payload) }
            socket.emit("p2pCall", payload, timeout: 10, ack: ack)
        }
    }

    /// The `p2pCall` events of one session of one call: the relay sends every session's to the socket of its user, so the
    /// call and the session in each say whose it is.
    public func listen(callId: String, session: String, _ handler: @escaping (JSONValue) -> Void) -> () -> Void {
        let key = callId + ":" + session
        let token = UUID()
        lock.withLock { handlers[key] = (token, handler) }
        return { [weak self] in
            guard let self else { return }
            self.lock.withLock { if self.handlers[key]?.token == token { self.handlers[key] = nil } }
        }
    }

    /// Each time the connection is up again, after a drop or on another node.
    public func onReconnect(_ listener: @escaping () -> Void) -> () -> Void {
        let token = UUID()
        lock.withLock { reconnects[token] = listener }
        return { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.reconnects[token] = nil }
        }
    }

    private func relayed(_ message: JSONValue) {
        guard let call = message["call_id"]?.id, let session = message["session"]?.string else { return }
        let handler = lock.withLock { handlers[call + ":" + session]?.handler }
        handler?(message)
    }

    private func changed() {
        let all = lock.withLock { Array(reconnects.values) }
        all.forEach { $0() }
    }
}
