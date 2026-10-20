import Foundation

public enum RoomState: String, Sendable {
    case joining, joined, failed, left
}

/// A room the app joined: its events, what it may send, and for a presence room who is in it. Its own events are
/// `joined` (the members), `join` ({ id, info }), `leave` ({ id }), `count` ({ n }), `error` ({ code }) and `kicked`.
public final class Room: @unchecked Sendable {
    public let name: String
    unowned let owner: Realtime

    private var _state: RoomState = .joining
    private var _error: String?
    private var _members: [String: JSONValue] = [:]
    private var _count: Int?
    private var readyWaiters: [(Result<Void, RealtimeError>) -> Void] = []
    private let listeners = Listeners<(JSONValue, EventMeta)>()
    /// Why the app's server refused it, from the auth route.
    var denied: String?
    /// The last kept event it had, which a reconnect joins again from.
    var lastId: String?

    init(owner: Realtime, name: String) {
        self.owner = owner
        self.name = name
    }

    public var state: RoomState { owner.queue.sync { _state } }
    /// The state, for code already on the owner's queue (a sync there would deadlock).
    var stateOnQueue: RoomState { _state }
    /// Why it failed: forbidden, expired, bad_token, full, kicked, no_rule, auth_failed …
    public var error: String? { owner.queue.sync { _error } }
    /// A presence room's members, as many as the server listed and the changes since: id → info.
    public var members: [String: JSONValue] { owner.queue.sync { _members } }
    /// How many are in it, for a counting room (presence, or its rule's `count`); nil for one that doesn't.
    public var count: Int? { owner.queue.sync { _count } }

    /// An event of the room, `handler( data, meta )`, or one of the room's own.
    @discardableResult
    public func on(_ event: String, _ handler: @escaping (JSONValue, EventMeta) -> Void) -> Listener {
        listeners.add(event, handler)
    }

    /// Every event of the room, whatever its name.
    @discardableResult
    public func onAny(_ handler: @escaping (String, JSONValue, EventMeta) -> Void) -> Listener {
        listeners.onAny { event, value in handler(event, value.0, value.1) }
    }

    public func off(_ listener: Listener) {
        listeners.remove(listener)
    }

    /// An event of the room, as an async sequence.
    public func events(_ event: String) -> AsyncStream<(JSONValue, EventMeta)> {
        AsyncStream { continuation in
            let listener = self.on(event) { continuation.yield(($0, $1)) }
            continuation.onTermination = { [weak self] _ in self?.off(listener) }
        }
    }

    /// An event of the room, its data decoded.
    public func events<T: Decodable>(_ event: String, as type: T.Type) -> AsyncStream<(T, EventMeta)> {
        AsyncStream { continuation in
            let listener = self.on(event) { data, meta in
                if let value = try? data.decode(T.self) { continuation.yield((value, meta)) }
            }
            continuation.onTermination = { [weak self] _ in self?.off(listener) }
        }
    }

    /// Sends an event to the room's others, as its rule allows; nothing is waited for. Before the room is joined, it waits for it.
    public func emit(_ event: String, _ data: JSONValue = .null) {
        send(event, data, ack: false, volatile: false) { _ in }
    }

    public func emit<T: Encodable>(_ event: String, _ data: T) {
        emit(event, (try? JSONValue(encoding: data)) ?? .null)
    }

    /// Sends an event and waits for the cloud to take it (checked, kept, sent): its id and time, or a RealtimeError.
    @discardableResult
    public func emitWithAck(_ event: String, _ data: JSONValue = .null, timeout: TimeInterval = 8) async throws -> Ack {
        try await withCheckedThrowingContinuation { continuation in
            send(event, data, ack: true, volatile: false, timeout: timeout) { continuation.resume(with: $0) }
        }
    }

    @discardableResult
    public func emitWithAck<T: Encodable>(_ event: String, _ data: T, timeout: TimeInterval = 8) async throws -> Ack {
        try await emitWithAck(event, try JSONValue(encoding: data), timeout: timeout)
    }

    /// Sends without waiting and without keeping: dropped rather than queued while off line.
    public var volatile: VolatileEmitter { VolatileEmitter(room: self) }

    /// A page of the room's history, oldest first: the newest `limit`, or those before or after an event's id.
    public func history(before: String? = nil, after: String? = nil, limit: Int = 50) async throws -> HistoryPage {
        try await ready()
        var ask: [String: JSONValue] = ["room": .string(name), "limit": .number(Double(limit))]
        if let before { ask["before"] = .string(before) }
        if let after { ask["after"] = .string(after) }
        let reply = try await owner.request("history", ask)
        let events = reply["events"]?.array ?? []
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            owner.queue.async { self.owner.inOrder(events.map { $0["data"] ?? .null }) { c.resume() } }
        }
        return HistoryPage(
            events: events.map { e in
                HistoryEvent(event: e["event"]?.string ?? "", data: owner.keyring.openJSON(e["data"] ?? .null) ?? .null, meta: EventMeta(from: e["from"]?.id, id: e["id"]?.string, at: e["at"]?.number))
            },
            more: reply["more"]?.bool ?? false
        )
    }

    /// A page of a presence room's members past the first ones listed, from `cursor` ("0" first); `next` is "0" after the last.
    public func membersPage(cursor: String = "0", limit: Int? = nil) async throws -> (members: [String: JSONValue], next: String) {
        try await ready()
        var ask: [String: JSONValue] = ["room": .string(name), "cursor": .string(cursor)]
        if let limit { ask["limit"] = .number(Double(limit)) }
        let reply = try await owner.request("members", ask)
        var out: [String: JSONValue] = [:]
        for m in reply["list"]?.array ?? [] { if let id = m["id"]?.id { out[id] = owner.openInfo(m["info"] ?? .null) } }
        return (out, reply["next"]?.string ?? "0")
    }

    public func leave() {
        owner.leave(name)
    }

    /// Waits until the room is joined; throws its error when it failed, or `timeout` when it isn't joined in time.
    public func ready(timeout: TimeInterval = 20) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            owner.queue.async { [self] in
                switch _state {
                case .joined: continuation.resume()
                case .failed, .left: continuation.resume(throwing: RealtimeError(_error ?? "left"))
                case .joining: waitForJoin(timeout: timeout) { continuation.resume(with: $0.mapError { $0 as Error }) }
                }
            }
        }
    }

    /// On the owner's queue: `done` once the room is joined, or failed, or after `timeout`, whichever comes first.
    private func waitForJoin(timeout: TimeInterval, _ done: @escaping (Result<Void, RealtimeError>) -> Void) {
        var answered = false
        let once: (Result<Void, RealtimeError>) -> Void = { result in
            guard !answered else { return }
            answered = true
            done(result)
        }
        readyWaiters.append(once)
        owner.queue.asyncAfter(deadline: .now() + timeout) { once(.failure(RealtimeError("timeout"))) }
    }

    func send(_ event: String, _ data: JSONValue, ack: Bool, volatile: Bool, timeout: TimeInterval = 8, _ done: @escaping (Result<Ack, RealtimeError>) -> Void) {
        owner.queue.async { [self] in
            if _state == .failed || _state == .left { return done(.failure(RealtimeError(_error ?? "left"))) }
            let label = owner.keyring.newest("ch:" + name + ":")
            let sent: JSONValue = label.flatMap { owner.keyring.sealJSON(data, label: $0) }.map(JSONValue.string) ?? data
            var payload: [String: JSONValue] = ["tab": .string(owner.tab), "room": .string(name), "event": .string(event), "data": sent]
            if volatile { payload["v"] = 1 }

            let go = { [self] in
                guard let socket = owner.socketForEmit(), socket.isConnected else { return done(.failure(RealtimeError("offline"))) }
                guard ack else {
                    socket.emit("emit", .object(payload))
                    return done(.success(Ack(id: "", at: 0)))
                }
                socket.emit("emit", .object(payload), timeout: timeout) { [self] reply in
                    guard let reply else { return done(.failure(RealtimeError("timeout"))) }
                    guard reply["ok"]?.bool == true, let id = reply["id"]?.string else { return done(.failure(RealtimeError(reply["error"]?.string ?? "server"))) }
                    owner.queue.async { self.seen(id) }
                    done(.success(Ack(id: id, at: reply["at"]?.number ?? 0)))
                }
            }
            if _state == .joined { return go() }
            if volatile { return done(.success(Ack(id: "", at: 0))) }
            waitForJoin(timeout: ack ? timeout : 120) { result in
                switch result {
                case .success: go()
                case let .failure(error): done(.failure(error))
                }
            }
        }
    }

    // MARK: - On the owner's queue

    func joined(members: [(String, JSONValue)]?, count: Int?) {
        _state = .joined
        _error = nil
        if let members {
            _members = Dictionary(members, uniquingKeysWith: { $1 })
        }
        if let count { _count = max(count, _members.count) }
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0(.success(())) }
        fire("joined", .array(_members.map { ["id": .string($0.key), "info": $0.value] }), EventMeta())
    }

    func failed(_ code: String) {
        _state = .failed
        _error = code
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0(.failure(RealtimeError(code))) }
        fire(code == "kicked" ? "kicked" : "error", ["code": .string(code)], EventMeta())
    }

    func lost() {
        if _state == .joined { _state = .joining }
    }

    func ended() {
        _state = .left
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0(.failure(RealtimeError("left"))) }
    }

    func memberJoined(_ id: String, info: JSONValue) {
        if _members[id] == nil, _count != nil { _count! += 1 }
        _members[id] = info
        fire("join", ["id": .string(id), "info": info], EventMeta())
    }

    func memberLeft(_ id: String) {
        if _members.removeValue(forKey: id) != nil, _count != nil { _count = max(0, _count! - 1) }
        fire("leave", ["id": .string(id)], EventMeta())
    }

    func counted(_ n: Int) {
        _count = n
        fire("count", ["n": .number(Double(n))], EventMeta())
    }

    /// Whether a kept event is newer than the last this app had; it becomes the last.
    func fresh(_ id: String) -> Bool {
        guard let parsed = Room.parse(id) else { return true }
        if let last = lastId.flatMap(Room.parse), parsed <= last { return false }
        lastId = id
        return true
    }

    func seen(_ id: String) {
        guard let parsed = Room.parse(id) else { return }
        if let last = lastId.flatMap(Room.parse), parsed <= last { return }
        lastId = id
    }

    func fire(_ event: String, _ data: JSONValue, _ meta: EventMeta) {
        let own = ["joined", "join", "leave", "count", "error", "kicked"].contains(event)
        listeners.fire(event, (data, meta), on: owner.options.callbackQueue, any: !own)
    }

    private static func parse(_ id: String) -> Pair? {
        let parts = id.split(separator: "-")
        guard parts.count == 2, let ms = UInt64(parts[0]), let n = UInt64(parts[1]) else { return nil }
        return Pair(ms: ms, n: n)
    }

    private struct Pair: Comparable {
        let ms: UInt64
        let n: UInt64
        static func < (a: Pair, b: Pair) -> Bool { a.ms != b.ms ? a.ms < b.ms : a.n < b.n }
    }
}

/// `room.volatile`: sent without waiting and never kept.
public struct VolatileEmitter {
    let room: Room

    public func emit(_ event: String, _ data: JSONValue = .null) {
        room.send(event, data, ack: false, volatile: true) { _ in }
    }

    public func emit<T: Encodable>(_ event: String, _ data: T) {
        emit(event, (try? JSONValue(encoding: data)) ?? .null)
    }
}

/// What the cloud answers an acked emit: the event's id, rising within the room, and when it took it.
public struct Ack: Sendable, Equatable {
    public let id: String
    public let at: Double
}

public struct HistoryEvent: Sendable, Equatable {
    public let event: String
    public let data: JSONValue
    public let meta: EventMeta
}

public struct HistoryPage: Sendable, Equatable {
    public let events: [HistoryEvent]
    public let more: Bool
}

/// Who is online across the app, for a user the app vouched for: the users it watches,
/// each with `change` ({ id, online, at? }: offline since `at`), and how many are online, with `count`.
public final class Online: @unchecked Sendable {
    unowned let owner: Realtime
    private var states: [String: (online: Bool, at: Double?)] = [:]
    private var watching = Set<String>()
    private var counting = false
    private var _count: Int?
    private let listeners = Listeners<(JSONValue, EventMeta)>()

    init(_ owner: Realtime) {
        self.owner = owner
    }

    /// How many are online, once something listens to `count`; nil before.
    public var count: Int? { owner.queue.sync { _count } }

    /// Watches users' status: now, then every change (`change`).
    @discardableResult
    public func watch(_ ids: [String]) -> Online {
        owner.queue.async { [self] in
            let fresh = ids.filter { !watching.contains($0) }
            fresh.forEach { watching.insert($0) }
            if !fresh.isEmpty, let socket = owner.socketForEmit(), socket.isConnected { send(["ids": .array(fresh.map(JSONValue.string))], on: socket) {} }
        }
        return self
    }

    public func unwatch(_ ids: [String]) {
        owner.queue.async { [self] in
            let gone = ids.filter { watching.remove($0) != nil }
            gone.forEach { states[$0] = nil }
            if !gone.isEmpty { owner.socketForEmit()?.emit("unwatch", ["tab": .string(owner.tab), "ids": .array(gone.map(JSONValue.string))]) }
        }
    }

    public func has(_ id: String) -> Bool {
        owner.queue.sync { states[id]?.online ?? false }
    }

    /// When a watched user was last seen, ms since 1970; nil while online or never seen.
    public func lastSeen(_ id: String) -> Double? {
        owner.queue.sync { states[id].flatMap { $0.online ? nil : $0.at } }
    }

    /// `change` ({ id, online, at? }) for the users watched, `count` ({ n }) once listened to.
    @discardableResult
    public func on(_ event: String, _ handler: @escaping (JSONValue) -> Void) -> Listener {
        let listener = listeners.add(event) { (value: (JSONValue, EventMeta)) in handler(value.0) }
        if event == "count" {
            owner.queue.async { [self] in
                guard !counting else { return }
                counting = true
                if let socket = owner.socketForEmit(), socket.isConnected { send(["count": true], on: socket) {} }
            }
        }
        return listener
    }

    public func off(_ listener: Listener) {
        listeners.remove(listener)
    }

    /// A page of who is online: their ids, and the cursor of the next page ("0" after the last).
    public func list(cursor: String = "0", limit: Int = 1000) async throws -> (ids: [String], next: String) {
        let reply = try await owner.request("online", ["cursor": .string(cursor), "limit": .number(Double(limit))])
        return ((reply["ids"]?.array ?? []).compactMap(\.id), reply["next"]?.string ?? "0")
    }

    // MARK: - On the owner's queue

    func again(on socket: SocketIO, _ done: @escaping () -> Void) {
        guard !watching.isEmpty || counting else { return done() }
        var payload: [String: JSONValue] = ["ids": .array(watching.map(JSONValue.string))]
        if counting { payload["count"] = true }
        send(payload, on: socket, done)
    }

    private func send(_ payload: [String: JSONValue], on socket: SocketIO, _ done: @escaping () -> Void) {
        var body = payload
        body["tab"] = .string(owner.tab)
        socket.emit("watch", .object(body)) { [self] reply in
            owner.queue.async {
                for state in reply?["online"]?.array ?? [] { self.set(state) }
                if let n = reply?["count"]?.int { self.counted(n) }
                done()
            }
        }
    }

    func changed(_ o: JSONValue) {
        guard let id = o["id"]?.id, watching.contains(id) else { return }
        set(o)
    }

    func counted(_ n: Int) {
        _count = n
        listeners.fire("count", (["n": .number(Double(n))], EventMeta()), on: owner.options.callbackQueue)
    }

    private func set(_ o: JSONValue) {
        guard let id = o["id"]?.id else { return }
        let online = o["online"]?.bool ?? false, at = o["at"]?.number
        let before = states[id]
        states[id] = (online, at)
        if before?.online != online || before?.at != at {
            var value: [String: JSONValue] = ["id": .string(id), "online": .bool(online)]
            if let at { value["at"] = .number(at) }
            listeners.fire("change", (.object(value), EventMeta()), on: owner.options.callbackQueue)
        }
    }
}
