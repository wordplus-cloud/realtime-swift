import Foundation

/// WordPlus Cloud's realtime SDK for an iOS or macOS app, on the same realtime
/// servers and protocol as the browser's `rooms()`: rooms with events and acks, presence, live counts and history, who
/// is online, and what the app's server sends the user, sealed end to end with keys only the app's server hands out.
///
///     let rt = Realtime(RealtimeOptions(app: "s1500000007", endpoint: URL(string: "https://shop.example.com/api/realtime")!,
///                                       headers: { ["Authorization": "Bearer \(session.token)"] }))
///     rt.connect()
///     let chat = rt.join("chat:34:42")
///     chat.on("message") { message, meta in show(message, from: meta.from) }
///     let ack = try await chat.emitWithAck("message", ["text": "Hi"])
///
/// The app's server answers its routes as every server package does (`{endpoint}/auth`, `/keys`): the same Express,
/// Laravel or Django server its web pages use.
public final class Realtime: @unchecked Sendable {
    /// This app's name on the connection, as a browser tab's: what the app's server's emit takes as `except`.
    public let tab: String
    public let keyring: Keyring
    /// Who is online across the app, for a user the app vouched for.
    public private(set) var online: Online!

    let options: RealtimeOptions
    let queue = DispatchQueue(label: "cloud.wordplus.realtime")
    private let connection: Connection
    private var rooms: [String: Room] = [:]
    private var tokens: [String: (token: String, exp: Double)] = [:]
    private var identity: Identity?
    private var listeners = Listeners<(JSONValue, EventMeta)>()
    private var stateListeners = Listeners<(ConnectionState, String?)>()
    private var pendingAuth: [String] = []
    private var authWaiters: [() -> Void] = []
    private var waiting: [(labels: [String], run: () -> Void)] = []
    private var resolving = false
    private var renewal: DispatchWorkItem?
    /// What this app answers the asks of its server with, by event (`answer`).
    private var answerers: [String: Answerer] = [:]
    /// What the SDK's other modules hear and hold (Modules.swift).
    var moduleEvents: [String: [(JSONValue) -> Void]] = [:]
    var moduleHolds: [(ModuleSocket, @escaping () -> Void) -> Void] = []

    public init(_ options: RealtimeOptions) {
        self.options = options
        tab = Realtime.newTab()
        keyring = options.keyring ?? Keyring()
        keyring.add(options.keys)
        identity = options.identity
        connection = Connection(server: options.server, path: options.path, auth: ["site": .string(options.app), "rt": 3], queue: queue, store: options.nodeStore ?? UserDefaultsNodeStore())
        online = Online(self)

        connection.onEvent = { [weak self] name, data in self?.event(name, data) }
        connection.onState = { [weak self] state, reason in
            guard let self else { return }
            if state == .disconnected { self.rooms.values.forEach { $0.lost() } }
            let public_: ConnectionState = state == .connected ? .connected : state == .connecting ? .connecting : state == .closed ? .closed : .disconnected
            self.stateListeners.fire((public_, reason), on: self.options.callbackQueue)
        }
        connection.onRefused = { [weak self] code in
            guard let self else { return }
            self.listeners.fire("error", (["code": .string(code)], EventMeta()), on: self.options.callbackQueue)
        }
        connection.hold = { [weak self] socket, _, done in
            guard let self else { return done(false) }
            self.holdAll(on: socket, done)
        }
    }

    /// Connects to the realtime servers, and keeps the connection: through drops, and from node to node.
    public func connect() {
        queue.async { [self] in
            if identity == nil, options.keys.isEmpty {
                askKeys([]) { self.connection.start() }
            } else {
                connection.start()
            }
        }
    }

    /// Leaves every room, and closes the connection.
    public func close() {
        queue.async { [self] in
            renewal?.cancel()
            rooms.values.forEach { $0.ended() }
            rooms.removeAll()
            connection.close()
        }
    }

    /// The user the app vouched for, or nil.
    public var user: String? {
        guard let token = identity?.token, let payload = Realtime.payload(token) else { return nil }
        return payload["sub"]?.id
    }

    public var state: ConnectionState {
        queue.sync {
            switch connection.state {
            case .connected: return .connected
            case .connecting: return .connecting
            case .closed: return .closed
            case .disconnected: return .disconnected
            }
        }
    }

    /// The connection's state as it changes: connecting, connected, disconnected (with the reason), closed.
    @discardableResult
    public func onState(_ handler: @escaping (ConnectionState, String?) -> Void) -> Listener {
        stateListeners.add("state", handler)
    }

    /// What the server of the app sends this user (`toUser( id ).emit( event, data )`), `handler( data, meta )`, and
    /// those of the connection itself: `error` ({ code }: the handshake refused, such as `over_capacity`), `moved`, and
    /// `signed_out` (the server of the app disconnected the user, and the app asks its routes again).
    @discardableResult
    public func on(_ event: String, _ handler: @escaping (JSONValue, EventMeta) -> Void) -> Listener {
        listeners.add(event, handler)
    }

    /// Answers what the server of the app asks this user (`user( id ).ask( event, data )`): `handler( data, meta )`
    /// returns the reply, sealed with the key of the user when the app holds it. One answer an event, nil takes it away.
    /// A handler that throws does not answer.
    public func answer(_ event: String, _ handler: Answerer?) {
        queue.async { self.answerers[event] = handler }
    }

    public func off(_ listener: Listener) {
        listeners.remove(listener)
        stateListeners.remove(listener)
    }

    /// What the app's server sends this user, as an async sequence.
    public func events(_ event: String) -> AsyncStream<(JSONValue, EventMeta)> {
        AsyncStream { continuation in
            let listener = self.on(event) { continuation.yield(($0, $1)) }
            continuation.onTermination = { [weak self] _ in self?.off(listener) }
        }
    }

    /// A room of the app, joined: the same one again for the same name.
    @discardableResult
    public func join(_ name: String) -> Room {
        queue.sync {
            if let room = rooms[name] { return room }
            let room = Room(owner: self, name: name)
            rooms[name] = room
            if let socket = connection.current, socket.isConnected { joinOne(room, on: socket) { _ in } }
            return room
        }
    }

    /// A room this app joined, or nil.
    public func room(_ name: String) -> Room? {
        queue.sync { rooms[name] }
    }

    /// Leaves a room.
    public func leave(_ name: String) {
        queue.async { [self] in
            guard let room = rooms.removeValue(forKey: name) else { return }
            tokens[name] = nil
            room.ended()
            connection.current?.emit("leave", ["tab": .string(tab), "room": .string(name)])
        }
    }

    /// Users of the app from its directory, by id, opened: those it holds, as `[id: { user_id, name, avatar, … }]`.
    public func users(_ ids: [String]) async throws -> [String: JSONValue] {
        let asked: [JSONValue] = Array(Set(ids)).prefix(100).map { id in Int(id).map { JSONValue.number(Double($0)) } ?? .string(id) }
        let reply = try await request("users", ["ids": .array(asked)])
        let found = reply["users"]?.object ?? [:]
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { self.inOrder([.object(found)]) { continuation.resume() } }
        }
        var out: [String: JSONValue] = [:]
        for (id, profile) in found {
            guard case let .object(fields) = profile else { continue }
            out[id] = .object(fields.mapValues { openDeep($0, 0) })
        }
        return out
    }

    // MARK: - On the queue

    func request(_ event: String, _ payload: [String: JSONValue], timeout: TimeInterval = 8) async throws -> JSONValue {
        guard let socket = queue.sync(execute: { connection.current }), socket.isConnected else { throw RealtimeError("offline") }
        var body = payload
        body["tab"] = .string(tab)
        var reply = await socket.emit(event, .object(body), timeout: timeout)
        if reply?["error"]?.string == "no_identity" {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async { self.identify(on: socket) { continuation.resume() } }
            }
            reply = await socket.emit(event, .object(body), timeout: timeout)
        }
        guard let answer = reply else { throw RealtimeError("timeout") }
        guard answer["ok"]?.bool == true else { throw RealtimeError(answer["error"]?.string ?? "server") }
        return answer
    }

    /// Everything held again on a socket: the identity first, every room from the last event it had, the watches.
    private func holdAll(on socket: SocketIO, _ done: @escaping (Bool) -> Void) {
        let group = DispatchGroup()
        var ok = true
        group.enter()
        identify(on: socket) { group.leave() }
        for room in rooms.values {
            group.enter()
            joinOne(room, on: socket) { joined in
                if !joined { ok = false }
                group.leave()
            }
        }
        group.enter()
        online.again(on: socket) { group.leave() }
        for hold in moduleHolds {
            group.enter()
            hold(ModuleSocket(socket: socket)) { group.leave() }
        }
        group.notify(queue: queue) { done(ok) }
    }

    /// Tells the socket who the user is. An identity refused as `expired` (signed before the server of the app
    /// disconnected the user, or run out) is asked for again, once.
    private func identify(on socket: SocketIO, renew: Bool = true, _ done: @escaping () -> Void) {
        guard let token = identity?.token else { return done() }
        socket.emit("identify", ["tab": .string(tab), "token": .string(token)]) { [self] reply in
            if reply?["error"]?.string == "expired", renew, identity?.token == token {
                identity = nil
                queue.asyncAfter(deadline: .now() + Realtime.renewAfter) { self.renewIdentity() }
            }
            done()
        }
    }

    /// After the server of the app disconnected the user: how long the app waits before it asks its routes again, as
    /// the realtime server refuses the tokens signed in the second of the disconnect too.
    static let renewAfter: TimeInterval = 1.1

    /// The identity asked of the keys route again, then who the app watches and what its modules hold, held again.
    private func renewIdentity() {
        askKeys([], renew: false) { [self] in
            guard identity != nil, let socket = connection.current, socket.isConnected else { return }
            online.again(on: socket) {}
            for hold in moduleHolds { hold(ModuleSocket(socket: socket)) {} }
        }
    }

    /// An ask of the server of the app for this user: answered when this app answers its event (`answer`).
    private func answerAsk(_ data: JSONValue) {
        guard let id = data["id"]?.string, let event = data["event"]?.string, let handler = answerers[event] else { return }
        let payload = data["data"] ?? .null
        inOrder([payload]) { [self] in
            guard let opened = keyring.openJSON(payload) else { return }
            let meta = EventMeta(at: data["at"]?.number)
            Task {
                guard let reply = try? await handler(opened, meta) else { return }
                queue.async { [self] in
                    let label = user.flatMap { keyring.newest("u:" + $0 + ":") }
                    let sent = label.flatMap { keyring.sealJSON(reply, label: $0) }.map(JSONValue.string) ?? reply
                    connection.current?.emit("reply", ["tab": .string(tab), "id": .string(id), "data": sent])
                }
            }
        }
    }

    /// Joins a room on a socket with its token, from the last kept event it had; true when it is in.
    func joinOne(_ room: Room, on socket: SocketIO, retry: Bool = true, _ done: @escaping (Bool) -> Void) {
        tokenFor(room.name) { [self] token in
            guard rooms[room.name] === room else { return done(true) }
            guard let token else {
                if room.stateOnQueue != .failed { room.failed(room.denied ?? "auth_failed") }
                return done(true)
            }
            var payload: [String: JSONValue] = ["tab": .string(tab), "room": .string(room.name), "token": .string(token)]
            if let since = room.lastId { payload["since"] = .string(since) }
            socket.emit("join", .object(payload)) { [self] reply in
                guard rooms[room.name] === room else { return done(true) }
                guard let reply else { return done(false) }
                if reply["ok"]?.bool == true {
                    let members = reply["members"]
                    let missed = reply["missed"]?.array ?? []
                    inOrder([members?["list"] ?? .null] + missed.map { $0["data"] ?? .null }) { [self] in
                        guard rooms[room.name] === room else { return }
                        let list = (members?["list"]?.array ?? []).compactMap { m -> (String, JSONValue)? in
                            guard let id = m["id"]?.id else { return nil }
                            return (id, openInfo(m["info"] ?? .null))
                        }
                        room.joined(members: members == nil ? nil : list, count: reply["count"]?.int)
                        for e in missed { deliver(e, room: room.name, replayed: true) }
                        if reply["gap"]?.bool == true { room.fire("error", ["code": "gap"], EventMeta()) }
                    }
                    done(true)
                } else if reply["error"]?.string == "expired", retry {
                    tokens[room.name] = nil
                    joinOne(room, on: socket, retry: false, done)
                } else {
                    room.failed(reply["error"]?.string ?? "server")
                    done(true)
                }
            }
        }
    }

    private func tokenFor(_ name: String, _ done: @escaping (String?) -> Void) {
        let now = Date().timeIntervalSince1970
        if let held = tokens[name], held.exp - now > 60 { return done(held.token) }
        if let open = options.grants.first(where: { $0.exp - now > 60 && $0.rooms.contains { Realtime.patternMatches($0, name) } }) { return done(open.token) }
        let first = pendingAuth.isEmpty
        pendingAuth.append(name)
        authWaiters.append { [weak self] in done(self?.tokens[name]?.token) }
        if first { queue.async { self.flushAuth() } }
    }

    /// Asks the app's server for the rooms asked for in the same moment, in one request.
    private func flushAuth() {
        let names = Array(Set(pendingAuth))
        let waiters = authWaiters
        pendingAuth = []
        authWaiters = []
        post("auth", ["rooms": .array(names.map(JSONValue.string))]) { [self] answer in
            let exp = answer?["exp"]?.number ?? Date().timeIntervalSince1970 + 3600
            keyring.add(answer?["keys"]?.array?.compactMap(\.string) ?? [])
            for name in names {
                if let denied = answer?["denied"]?[name]?.string {
                    tokens[name] = nil
                    rooms[name]?.denied = denied
                } else if let token = answer?["token"]?.string {
                    tokens[name] = (token, exp)
                } else {
                    rooms[name]?.denied = "auth_failed"
                }
            }
            scheduleRenewal()
            waiters.forEach { $0() }
        }
    }

    /// The tokens of the rooms still held, asked for again ten minutes before the first runs out.
    private func scheduleRenewal() {
        renewal?.cancel()
        let held = tokens.filter { rooms[$0.key] != nil }
        guard let first = held.values.map(\.exp).min() else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for name in held.keys where self.rooms[name] != nil { self.tokenFor(name) { _ in } }
        }
        renewal = item
        queue.asyncAfter(deadline: .now() + max(30, first - 600 - Date().timeIntervalSince1970), execute: item)
    }

    /// The keys route: keys asked for that the user may have, or with none their own keys and identity.
    func askKeys(_ labels: [String], renew: Bool = true, _ done: @escaping () -> Void) {
        post("keys", ["labels": .array(labels.map(JSONValue.string))]) { [self] answer in
            keyring.add(answer?["keys"]?.array?.compactMap(\.string) ?? [])
            if let token = answer?["identity"]?["token"]?.string, token != identity?.token {
                identity = Identity(token: token, exp: answer?["identity"]?["exp"]?.number ?? 0)
                if let socket = connection.current, socket.isConnected { identify(on: socket, renew: renew) {} }
            }
            done()
        }
    }

    /// A POST to one of the app's routes, its JSON answer on the queue (nil when it failed).
    private func post(_ route: String, _ body: [String: JSONValue], _ done: @escaping (JSONValue?) -> Void) {
        postRoute(route, body) { status, answer in done(status == 200 ? answer : nil) }
    }

    /// A POST to one of the app's routes: its status (0 when it never answered) and JSON answer, on the queue.
    @_spi(WordPlusModules)
    public func postRoute(_ route: String, _ body: [String: JSONValue], _ done: @escaping (Int, JSONValue?) -> Void) {
        var request = URLRequest(url: options.routes[route] ?? options.endpoint.appendingPathComponent(route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in options.headers() { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try? JSONValue.object(body).encoded()
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let answer = data.flatMap { String(data: $0, encoding: .utf8) }.flatMap(JSONValue.parse)
            self?.queue.async { done(status, answer) }
        }.resume()
    }

    /// Runs `then` once the keyring holds the keys these values need, after whatever waits before it, so a listener
    /// never gets an event ahead of an earlier one.
    func inOrder(_ values: [JSONValue], _ then: @escaping () -> Void) {
        let missing = values.flatMap { keyring.missing($0) }
        if missing.isEmpty, waiting.isEmpty { return then() }
        waiting.append((missing, then))
        pump()
    }

    private func pump() {
        guard !resolving, let head = waiting.first else { return }
        let need = head.labels.filter { !keyring.has($0) }
        if need.isEmpty {
            waiting.removeFirst()
            head.run()
            return pump()
        }
        resolving = true
        askKeys(need) { [self] in
            resolving = false
            waiting.removeFirst()
            head.run()
            pump()
        }
    }

    private func event(_ name: String, _ data: JSONValue) {
        switch name {
        case "e": deliver(data, room: data["room"]?.string ?? "", replayed: false)
        case "join":
            guard data["x"]?.string != tab, let room = rooms[data["room"]?.string ?? ""], let id = data["id"]?.id else { return }
            inOrder([data["info"] ?? .null]) { room.memberJoined(id, info: self.openInfo(data["info"] ?? .null)) }
        case "leave":
            guard let room = rooms[data["room"]?.string ?? ""], let id = data["id"]?.id else { return }
            inOrder([]) { room.memberLeft(id) }
        case "count":
            rooms[data["room"]?.string ?? ""]?.counted(data["n"]?.int ?? 0)
        case "kicked":
            guard data["tab"]?.string == tab, let name = data["room"]?.string, let room = rooms[name] else { return }
            tokens[name] = nil
            // The server of the app disconnected the user: the room is asked of its routes again, whose rules decide.
            if data["renew"]?.bool == true {
                room.lost()
                queue.asyncAfter(deadline: .now() + Realtime.renewAfter) { [self] in
                    guard rooms[name] === room, let socket = connection.current, socket.isConnected else { return }
                    joinOne(room, on: socket) { _ in }
                }
                return
            }
            rooms[name] = nil
            room.failed("kicked")
        case "signed_out":
            identity = nil
            listeners.fire("signed_out", (.null, EventMeta()), on: options.callbackQueue)
            queue.asyncAfter(deadline: .now() + Realtime.renewAfter) { self.renewIdentity() }
        case "ask":
            answerAsk(data)
        case "u":
            guard let event = data["event"]?.string, data["x"]?.string != tab else { return }
            let payload = data["data"] ?? .null
            inOrder([payload]) { [self] in
                let meta = EventMeta(at: data["at"]?.number)
                if let opened = keyring.openJSON(payload) {
                    listeners.fire(event, (opened, meta), on: options.callbackQueue)
                } else {
                    listeners.fire("error", (["code": "unopened", "event": .string(event), "label": .string(Keyring.labelOf(payload.string ?? "") ?? "")], meta), on: options.callbackQueue)
                }
            }
        case "online": online.changed(data)
        case "online_count": online.counted(data["n"]?.int ?? 0)
        case "moved": listeners.fire("moved", (.null, EventMeta()), on: options.callbackQueue)
        default: moduleEvents[name]?.forEach { $0(data) }
        }
    }

    /// An event for one of this app's rooms: never one its own action made (`x`), nor one it had already.
    private func deliver(_ e: JSONValue, room name: String, replayed: Bool) {
        guard let event = e["event"]?.string, e["x"]?.string != tab, let room = rooms[name] else { return }
        let payload = e["data"] ?? .null
        inOrder([payload]) { [self] in
            guard rooms[name] === room, room.stateOnQueue != .failed else { return }
            if let id = e["id"]?.string, !room.fresh(id) { return }
            let meta = EventMeta(from: e["from"]?.id, id: e["id"]?.string, at: e["at"]?.number, replayed: replayed)
            if let opened = keyring.openJSON(payload) {
                room.fire(event, opened, meta)
            } else {
                room.fire("error", ["code": "unopened", "event": .string(event), "label": .string(Keyring.labelOf(payload.string ?? "") ?? "")], meta)
            }
        }
    }

    func openInfo(_ info: JSONValue) -> JSONValue {
        keyring.openJSON(info) ?? .null
    }

    private func openDeep(_ value: JSONValue, _ depth: Int) -> JSONValue {
        switch value {
        case let .string(s): return keyring.open(s).map(JSONValue.string) ?? .null
        case let .array(items) where depth < 9: return .array(items.map { openDeep($0, depth + 1) })
        case let .object(fields) where depth < 9: return .object(fields.mapValues { openDeep($0, depth + 1) })
        default: return value
        }
    }

    func socketForEmit() -> SocketIO? {
        connection.current
    }

    /// A pattern of a public grant, as the realtime server matches it: each `{part}` one or more characters other
    /// than `:` and `.`.
    static func patternMatches(_ pattern: String, _ room: String) -> Bool {
        guard pattern.contains("{") else { return pattern == room }
        var source = "^"
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            source += NSRegularExpression.escapedPattern(for: String(rest[..<open])) + "[^:.]+?"
            rest = rest[rest.index(after: close)...]
        }
        source += NSRegularExpression.escapedPattern(for: String(rest)) + "$"
        return room.range(of: source, options: .regularExpression) != nil
    }

    static func payload(_ token: String) -> JSONValue? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let data = Base64URL.decode(String(parts[1])) else { return nil }
        return String(data: data, encoding: .utf8).flatMap(JSONValue.parse)
    }

    private static func newTab() -> String {
        (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }.joined()
    }
}

/// connect()'s settings: the app, its routes, and a signed-in user's keys and identity when the app's server gave them.
public struct RealtimeOptions: @unchecked Sendable {
    /// The app's key, from the WordPlus Cloud account (Apps). Public: every app carries it.
    public var app: String
    /// Where the app's server answers: `{endpoint}/auth`, `/calls` and `/keys`, in full.
    public var endpoint: URL
    /// A route at an address of its own, in full, in place of `{endpoint}/{name}`, as the server package's `routes` put
    /// it: `["calls": URL(string: "https://shop.example.com/check-call")!]`.
    public var routes: [String: URL]
    /// What every request to the app's routes carries, such as the user's session token.
    public var headers: @Sendable () -> [String: String]
    public var server: URL
    public var path: String
    /// A signed-in user's keys and identity, from the server's config(): then no request comes first.
    public var keys: [String]
    public var identity: Identity?
    /// Grants for the app's public rooms, from the server's config().
    public var grants: [PublicGrant]
    /// Where handlers are called: the main queue by default.
    public var callbackQueue: DispatchQueue
    public var keyring: Keyring?
    var nodeStore: NodeStore?

    public init(app: String, endpoint: URL, routes: [String: URL] = [:], headers: @escaping @Sendable () -> [String: String] = { [:] }, server: URL = URL(string: "https://ws.wordplus.cloud")!, path: String = "/websocket", keys: [String] = [], identity: Identity? = nil, grants: [PublicGrant] = [], callbackQueue: DispatchQueue = .main, keyring: Keyring? = nil) {
        self.app = app
        self.endpoint = endpoint
        self.routes = routes
        self.headers = headers
        self.server = server
        self.path = path
        self.keys = keys
        self.identity = identity
        self.grants = grants
        self.callbackQueue = callbackQueue
        self.keyring = keyring
    }

    /// From the server package's config() answer (`realtime` in the API demo's sign-in), its routes resolved
    /// against `base`, the app server's address.
    public init(config: JSONValue, base: URL, headers: @escaping @Sendable () -> [String: String] = { [:] }, callbackQueue: DispatchQueue = .main) {
        // Each route in full, and the ones not beside the auth route kept apart.
        func address(_ name: String) -> URL {
            URL(string: config[name]?["endpoint"]?.string ?? "/api/realtime/" + name, relativeTo: base)!.absoluteURL
        }
        let endpoint = address("auth").deletingLastPathComponent()
        var routes: [String: URL] = [:]
        for name in ["auth", "calls", "keys"] where address(name) != endpoint.appendingPathComponent(name) {
            routes[name] = address(name)
        }
        self.init(
            app: config["site"]?.string ?? "",
            endpoint: endpoint,
            routes: routes,
            headers: headers,
            server: config["server"]?.string.flatMap(URL.init(string:)) ?? URL(string: "https://ws.wordplus.cloud")!,
            path: config["path"]?.string ?? "/websocket",
            keys: config["keys"]?["entries"]?.array?.compactMap(\.string) ?? [],
            identity: config["keys"]?["identity"].flatMap { id in id["token"]?.string.map { Identity(token: $0, exp: id["exp"]?.number ?? 0) } },
            grants: config["grants"]?.array?.compactMap { g in g["token"]?.string.map { PublicGrant(token: $0, exp: g["exp"]?.number ?? 0, rooms: g["rooms"]?.array?.compactMap(\.string) ?? []) } } ?? [],
            callbackQueue: callbackQueue
        )
    }
}

public struct Identity: Sendable, Equatable {
    public var token: String
    public var exp: Double
    public init(token: String, exp: Double) {
        self.token = token
        self.exp = exp
    }
}

public struct PublicGrant: Sendable, Equatable {
    public var token: String
    public var exp: Double
    public var rooms: [String]
    public init(token: String, exp: Double, rooms: [String]) {
        self.token = token
        self.exp = exp
        self.rooms = rooms
    }
}

/// What an app answers an ask of its server with (`Realtime.answer`): the reply to `data`, sealed with the key of the
/// user when the app holds it.
public typealias Answerer = @Sendable (JSONValue, EventMeta) async throws -> JSONValue

/// What comes with every event: who sent it (none for the app's server), its id when the room keeps it, when, and
/// whether it was missed while the connection was down.
public struct EventMeta: Sendable, Equatable {
    public var from: String?
    public var id: String?
    public var at: Double?
    public var replayed: Bool
    public init(from: String? = nil, id: String? = nil, at: Double? = nil, replayed: Bool = false) {
        self.from = from
        self.id = id
        self.at = at
        self.replayed = replayed
    }
}

public enum ConnectionState: String, Sendable {
    case connecting, connected, disconnected, closed
}

/// What the realtime server or the app's server refused, by its code: `forbidden`, `rate_limited`, `too_large` …
public struct RealtimeError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public init(_ code: String) { self.code = code }
    public var description: String { "RealtimeError(\(code))" }
}

/// A handler that can be removed.
public struct Listener: Hashable, Sendable {
    let id: UUID
    let event: String
}

final class Listeners<Value>: @unchecked Sendable {
    private var byEvent: [String: [(UUID, (Value) -> Void)]] = [:]
    private var any: [(UUID, (String, Value) -> Void)] = []
    private let lock = NSLock()

    func add(_ event: String, _ fn: @escaping (Value) -> Void) -> Listener {
        let id = UUID()
        lock.lock()
        byEvent[event, default: []].append((id, fn))
        lock.unlock()
        return Listener(id: id, event: event)
    }

    func add(_ event: String, _ fn: @escaping (JSONValue, EventMeta) -> Void) -> Listener where Value == (JSONValue, EventMeta) {
        add(event) { (pair: Value) in fn(pair.0, pair.1) }
    }

    func add(_ event: String, _ fn: @escaping (ConnectionState, String?) -> Void) -> Listener where Value == (ConnectionState, String?) {
        add(event) { (pair: Value) in fn(pair.0, pair.1) }
    }

    func onAny(_ fn: @escaping (String, Value) -> Void) -> Listener {
        let id = UUID()
        lock.lock()
        any.append((id, fn))
        lock.unlock()
        return Listener(id: id, event: "*")
    }

    func remove(_ listener: Listener) {
        lock.lock()
        byEvent[listener.event]?.removeAll { $0.0 == listener.id }
        any.removeAll { $0.0 == listener.id }
        lock.unlock()
    }

    func fire(_ event: String, _ value: Value, on queue: DispatchQueue, any fireAny: Bool = false) {
        lock.lock()
        let list = byEvent[event] ?? []
        let anyList = fireAny ? any : []
        lock.unlock()
        guard !list.isEmpty || !anyList.isEmpty else { return }
        queue.async {
            for (_, fn) in anyList { fn(event, value) }
            for (_, fn) in list { fn(value) }
        }
    }

    func fire(_ value: Value, on queue: DispatchQueue) where Value == (ConnectionState, String?) {
        fire("state", value, on: queue)
    }
}
