import Foundation

/// The app's one connection to the realtime servers, as the browser's connector keeps
/// it: straight to a node when it knows one, else the realtime server (the load balancer); to another node at a
/// `migrate`, make before break, its rooms joined there before the switch; and again after a drop, from the first node
/// that hasn't expired.
final class Connection: @unchecked Sendable {
    enum State: String, Sendable {
        case connecting, connected, disconnected, closed
    }

    let server: URL
    private let path: String
    private let auth: JSONValue
    private let queue: DispatchQueue
    private let store: NodeStore

    /// What rides the connection: its events, and what to hold again on a socket before it takes over (rooms,
    /// identity, watches), at each connect and on a move's new socket.
    var onEvent: (String, JSONValue) -> Void = { _, _ in }
    var onState: (State, String?) -> Void = { _, _ in }
    var onRefused: (String) -> Void = { _ in }
    /// Called on the connection's queue; answers on it, true when everything was held.
    var hold: (SocketIO, Bool, @escaping (Bool) -> Void) -> Void = { _, _, done in done(true) }

    private(set) var current: SocketIO?
    private(set) var state: State = .closed
    private var attempt = 0
    private var moving = false
    private var scheduled: (reason: String, item: DispatchWorkItem)?
    private var closed = false

    init(server: URL, path: String, auth: JSONValue, queue: DispatchQueue, store: NodeStore = UserDefaultsNodeStore()) {
        self.server = server
        self.path = path
        self.auth = auth
        self.queue = queue
        self.store = store
    }

    func start() {
        queue.async { [self] in
            closed = false
            connect(candidates())
        }
    }

    func close() {
        queue.async { [self] in
            closed = true
            scheduled?.item.cancel()
            current?.close()
            current = nil
            setState(.closed, nil)
        }
    }

    /// Where to try, in order: the cached nodes that haven't expired, unless direct connections are paused, then the
    /// realtime server.
    private func candidates() -> [URL] {
        let cache = store.load(server: server)
        let nodes = cache.paused ? [] : cache.nodes.compactMap { URL(string: $0.url) }
        return nodes + [server]
    }

    private func connect(_ targets: [URL]) {
        guard !closed, let target = targets.first else { return }
        setState(.connecting, nil)
        let atServer = target == server
        let socket = SocketIO(base: target, path: path, namespace: "/channels", auth: auth, queue: queue) { [weak self] socket, event in
            self?.socketEvent(socket, event, rest: Array(targets.dropFirst()))
        }
        current = socket
        socket.open(timeout: atServer ? 7 : 5)
    }

    private func socketEvent(_ socket: SocketIO, _ event: SocketIO.Event, rest: [URL]) {
        switch event {
        case .connected:
            guard socket === current else { return }
            attempt = 0
            store.forgetFailed(server: server)
            hold(socket, false) { [weak self] _ in
                guard let self, socket === self.current else { return }
                self.setState(.connected, nil)
            }
        case let .refused(reason):
            guard socket === current else { return }
            if reason.hasPrefix("connect_failed:") {
                // A node that doesn't answer: the next one, then the realtime server, then a while off line.
                if socket.base != server { store.markFailed(server: server, url: socket.base.absoluteString) }
                if !rest.isEmpty { return connect(rest) }
                retry()
            } else {
                // The handshake refused (not_licensed, over_capacity …): the app's to answer.
                onRefused(reason)
                retry()
            }
        case let .closed(reason):
            guard socket === current else { return }
            setState(.disconnected, reason)
            retry()
        case let .event(name, data):
            if name == "migrate" { return migrate(data, on: socket) }
            if name == "nodes" { return remember(data["nodes"]) }
            guard socket === current else { return }
            onEvent(name, data)
        }
    }

    private func retry() {
        guard !closed else { return }
        attempt += 1
        let delay = min(30, [1, 2, 5, 10, 20][min(attempt - 1, 4)]) * Double.random(in: 0.7 ... 1.3)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.closed, self.state != .connected else { return }
            self.connect(self.candidates())
        }
    }

    /// A `migrate`: to `target` (the realtime server for none) at a random moment within `spread`.
    private func migrate(_ m: JSONValue, on socket: SocketIO) {
        guard socket === current, !closed else { return }
        let reason = m["reason"]?.string ?? "drain"
        remember(m["nodes"])

        let target = m["target"]?.string.flatMap(URL.init(string:))
        if reason == "direct" {
            // Only from the realtime server itself, to an https node other than it, and never while paused or moving.
            guard socket.base == server, let target, target.scheme == "https", target != server, !store.load(server: server).paused, !moving, scheduled == nil else { return }
        } else if reason == "direct_off" {
            store.save(server: server, NodeCache())
        }

        if let scheduled, scheduled.reason == "direct" || reason != "direct" { scheduled.item.cancel() }
        let spread = max(0, (m["spread"]?.number ?? 5000) / 1000)
        let item = DispatchWorkItem { [weak self] in
            self?.scheduled = nil
            self?.move(to: target ?? self?.server ?? URL(string: "https://ws.wordplus.cloud")!, reason: reason)
        }
        scheduled = (reason, item)
        queue.asyncAfter(deadline: .now() + Double.random(in: 0 ... spread), execute: item)
    }

    /// Make before break: a second socket to the target, everything held there, then the switch; the old socket goes
    /// three seconds later, once its answers under way are in. A move that fails leaves the connection where it was.
    private func move(to target: URL, reason: String) {
        guard !closed, !moving, let old = current else { return }
        moving = true
        var switched = false
        let next = SocketIO(base: target, path: path, namespace: "/channels", auth: auth, queue: queue) { [weak self] socket, event in
            guard let self else { return }
            switch event {
            case .connected:
                self.hold(socket, true) { ok in
                    self.moving = false
                    guard ok, !self.closed, self.current === old else { return socket.close() }
                    switched = true
                    self.current = socket
                    self.setState(.connected, nil)
                    self.onEvent("moved", .null)
                    self.queue.asyncAfter(deadline: .now() + 3) { old.close() }
                }
            case .refused, .closed:
                if switched {
                    self.socketEvent(socket, event, rest: [])
                    return
                }
                self.moving = false
                // An offered node this client can't reach while the realtime server answers: no more offers for an hour.
                if reason == "direct" { self.store.pause(server: self.server) }
            case let .event(name, data):
                guard switched else { return }
                self.socketEvent(socket, .event(name, data), rest: [])
            }
        }
        next.open(timeout: target == server ? 7 : 10)
    }

    private func remember(_ nodes: JSONValue?) {
        guard let list = nodes?.array, !list.isEmpty else { return }
        var cache = store.load(server: server)
        cache.nodes = list.prefix(3).compactMap { node in
            guard let url = node["url"]?.string, url.hasPrefix("https://") else { return nil }
            let ttl = min(max(node["ttl"]?.number ?? 60, 60), 86_400)
            return CachedNode(url: url, until: Date().timeIntervalSince1970 + ttl)
        }
        cache.pausedUntil = nil
        store.save(server: server, cache)
    }

    private func setState(_ next: State, _ reason: String?) {
        guard next != state else { return }
        state = next
        onState(next, reason)
    }
}

struct CachedNode: Codable, Equatable {
    var url: String
    var until: TimeInterval
}

struct NodeCache: Codable, Equatable {
    var nodes: [CachedNode] = []
    var failed: [String] = []
    var pausedUntil: TimeInterval?

    var paused: Bool { (pausedUntil ?? 0) > Date().timeIntervalSince1970 }
}

/// Where the nodes are kept between launches: up to three, each until its ttl runs out.
protocol NodeStore: Sendable {
    func load(server: URL) -> NodeCache
    func save(server: URL, _ cache: NodeCache)
}

extension NodeStore {
    func markFailed(server: URL, url: String) {
        var cache = load(server: server)
        cache.nodes.removeAll { $0.url == url }
        save(server: server, cache)
    }

    func forgetFailed(server: URL) {}

    func pause(server: URL) {
        var cache = load(server: server)
        cache.pausedUntil = Date().timeIntervalSince1970 + 3600
        save(server: server, cache)
    }
}

final class UserDefaultsNodeStore: NodeStore, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(server: URL) -> NodeCache {
        guard let data = defaults.data(forKey: key(server)), var cache = try? JSONDecoder().decode(NodeCache.self, from: data) else { return NodeCache() }
        let now = Date().timeIntervalSince1970
        cache.nodes.removeAll { $0.until <= now }
        return cache
    }

    func save(server: URL, _ cache: NodeCache) {
        defaults.set(try? JSONEncoder().encode(cache), forKey: key(server))
    }

    private func key(_ server: URL) -> String {
        "wordplus-realtime-nodes|" + server.absoluteString
    }
}

/// For tests and apps that keep nothing between launches.
final class MemoryNodeStore: NodeStore, @unchecked Sendable {
    private var caches: [URL: NodeCache] = [:]
    private let lock = NSLock()

    func load(server: URL) -> NodeCache {
        lock.lock()
        defer { lock.unlock() }
        return caches[server] ?? NodeCache()
    }

    func save(server: URL, _ cache: NodeCache) {
        lock.lock()
        caches[server] = cache
        lock.unlock()
    }
}
