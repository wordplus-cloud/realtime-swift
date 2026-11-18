import Foundation
import XCTest
@testable import WordPlusRealtime

/// A connection on a namespace the app names (`RealtimeOptions.namespace`), against two realtime nodes on this machine
/// (`FakeNode`): the namespace and its handshake on every socket, a room joined and its events, a drop and the connection
/// back from the node cache with the room joined again from its last event, a drain's move to the other node, make before
/// break, and the nodes a node lists kept for the next launch. With no namespace named, the connection is `/channels`'
/// as before.
final class NamespaceTests: XCTestCase {
    /// The node the cache knows, which the connection tries first.
    private var cached: FakeNode!
    /// The realtime server itself, which a drain sends the connection to.
    private var server: FakeNode!
    private var store: MemoryNodeStore!
    private var connections: [Realtime] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        URLProtocol.registerClass(FakeRoutes.self)
        FakeRoutes.reset()
        FakeRoutes.answer("keys") { _ in "{}" }
        cached = try FakeNode()
        server = try FakeNode()
        store = MemoryNodeStore()
        store.save(server: server.url, NodeCache(nodes: [CachedNode(url: cached.url.absoluteString, until: Date().timeIntervalSince1970 + 3600)]))
    }

    override func tearDown() {
        connections.forEach { $0.close() }
        cached.stop()
        server.stop()
        URLProtocol.unregisterClass(FakeRoutes.self)
        super.tearDown()
    }

    private func connection(namespace: String? = nil, auth: JSONValue? = nil) -> Realtime {
        var options = RealtimeOptions(
            app: "s1500000007",
            endpoint: URL(string: "https://routes.test/api/realtime")!,
            server: server.url,
            grants: [PublicGrant(token: "lobby-grant", exp: Date().timeIntervalSince1970 + 3600, rooms: ["lobby:{n}"])],
            callbackQueue: DispatchQueue(label: "namespace-tests")
        )
        if let namespace { options.namespace = namespace }
        options.auth = auth
        options.nodeStore = store
        let rt = Realtime(options)
        connections.append(rt)
        return rt
    }

    func testARoomOnANamedNamespaceJoinsHearsReconnectsAndMoves() throws {
        let rt = connection(namespace: "/messenger", auth: ["sid": "site-9", "uid": 7])
        let heard = LockedList()
        let moved = LockedList()
        rt.on("moved") { _, _ in moved.append("moved") }
        rt.connect()
        let room = rt.join("lobby:1")
        room.on("message") { data, _ in heard.append(data["text"]?.string ?? "") }

        // The node the cache knows first, on the namespace named, with its handshake and `rt`, which tells the server it moves.
        let first = try XCTUnwrap(cached.client(1), "the cached node is tried first")
        XCTAssertEqual(first.namespace, "/messenger")
        XCTAssertEqual(first.auth, ["sid": "site-9", "uid": 7, "rt": 1])
        eventually { room.state == .joined }
        let join = try XCTUnwrap(first.asked("join").first)
        XCTAssertEqual(join["room"]?.string, "lobby:1")
        XCTAssertEqual(join["token"]?.string, "lobby-grant")
        XCTAssertEqual(join["tab"]?.string, rt.tab)
        XCTAssertEqual(FakeRoutes.asked("keys").count, 0, "on another namespace nothing is asked before connecting")

        first.emit("e", ["room": "lobby:1", "event": "message", "data": ["text": "one"], "id": "1-0"])
        eventually { heard.items == ["one"] }
        XCTAssertEqual(heard.items, ["one"])

        // Dropped: back on the cached node, the same namespace, the room joined again from the last event it had.
        first.drop()
        let again = try XCTUnwrap(cached.client(2, timeout: 10), "it reconnects")
        XCTAssertEqual(again.namespace, "/messenger")
        XCTAssertEqual(again.auth, ["sid": "site-9", "uid": 7, "rt": 1])
        eventually { !again.asked("join").isEmpty }
        XCTAssertEqual(again.asked("join").first?["since"]?.string, "1-0")
        eventually { room.state == .joined }
        again.emit("e", ["room": "lobby:1", "event": "message", "data": ["text": "two"], "id": "2-0"])
        eventually { heard.items == ["one", "two"] }
        XCTAssertEqual(heard.items, ["one", "two"])

        // A drain: to the realtime server, the room joined there before the switch, as on `/channels`.
        again.emit("migrate", ["target": .string(server.url.absoluteString), "spread": 0, "reason": "drain"])
        let moving = try XCTUnwrap(server.client(1), "it moves")
        XCTAssertEqual(moving.namespace, "/messenger")
        XCTAssertEqual(moving.auth?["rt"], 1)
        eventually { moved.items.count == 1 }
        XCTAssertEqual(moved.items, ["moved"])
        XCTAssertEqual(moving.asked("join").first?["since"]?.string, "2-0", "held on the new socket before it took over")
        moving.emit("e", ["room": "lobby:1", "event": "message", "data": ["text": "three"], "id": "3-0"])
        eventually { heard.items == ["one", "two", "three"] }
        XCTAssertEqual(heard.items, ["one", "two", "three"])
        eventually(timeout: 6) { again.closed }
        XCTAssertTrue(again.closed, "the old socket goes once the new one has taken over")

        // The nodes a node lists, kept for the next connection, under the realtime server's address.
        moving.emit("nodes", ["nodes": [["url": "https://ws-a.de.example.test", "ttl": 120]]])
        eventually { store.load(server: server.url).nodes.map(\.url) == ["https://ws-a.de.example.test"] }
        XCTAssertEqual(store.load(server: server.url).nodes.map(\.url), ["https://ws-a.de.example.test"])
    }

    func testWithNoNamespaceNamedItIsTheChannelsAsBefore() throws {
        let rt = connection()
        XCTAssertEqual(rt.options.namespace, "/channels")
        rt.connect()
        let socket = try XCTUnwrap(cached.client(1))
        XCTAssertEqual(socket.namespace, "/channels")
        XCTAssertEqual(socket.auth, ["site": "s1500000007", "rt": 3])
        XCTAssertEqual(FakeRoutes.asked("keys").count, 1, "with no keys given, the keys route is asked first, as before")
    }

    func testAHandshakeKeepsAnRtOfItsOwnAndOneNotAnObjectGoesAsItIs() {
        var options = RealtimeOptions(app: "s1", endpoint: URL(string: "https://routes.test/api/realtime")!, namespace: "/", auth: ["sid": "site-9", "rt": 2])
        XCTAssertEqual(options.handshake, ["sid": "site-9", "rt": 2])
        options.auth = ["site-9", 7, "key"]
        XCTAssertEqual(options.handshake, ["site-9", 7, "key"])
        options.auth = nil
        XCTAssertEqual(options.handshake, ["site": "s1", "rt": 3])
    }
}
