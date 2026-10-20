import Foundation
import XCTest
@testable import WordPlusRealtime

/// The client against a real realtime server and a real app's server: @wordplus/realtime's Express example, signed in
/// as the shop's people, as `node test/native/serve.mjs` in realtime-js keeps them up. Set WORDPLUS_SHOP to its address
/// (http://localhost:17533); without it these are skipped.
final class LiveTests: XCTestCase {
    struct Session {
        let rt: Realtime
        let token: String
        let shop: JSONValue
    }

    private var opened: [Realtime] = []

    override func tearDown() {
        opened.forEach { $0.close() }
        opened = []
    }

    private func shopURL() throws -> URL {
        guard let value = ProcessInfo.processInfo.environment["WORDPLUS_SHOP"], let url = URL(string: value) else {
            throw XCTSkip("WORDPLUS_SHOP is not set: run `node test/native/serve.mjs` in realtime-js")
        }
        return url
    }

    /// Signs in as one of the shop's people (POST /api/token), and connects with the settings its server sent.
    private func signIn(_ person: Int) async throws -> Session {
        let base = try shopURL()
        var request = URLRequest(url: base.appendingPathComponent("api/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"as\":\(person)}".utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let answer = try XCTUnwrap(JSONValue.parse(String(decoding: data, as: UTF8.self)))
        let token = try XCTUnwrap(answer["token"]?.string)

        var options = RealtimeOptions(config: try XCTUnwrap(answer["realtime"]), base: base, headers: { ["Authorization": "Bearer " + token] }, callbackQueue: DispatchQueue(label: "test-\(person)"))
        options.nodeStore = MemoryNodeStore()
        let rt = Realtime(options)
        opened.append(rt)
        rt.connect()
        return Session(rt: rt, token: token, shop: try XCTUnwrap(answer["shop"]))
    }

    private func post(_ path: String, _ body: JSONValue, as session: Session) async throws -> Int {
        var request = URLRequest(url: try shopURL().appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + session.token, forHTTPHeaderField: "Authorization")
        request.setValue(session.rt.tab, forHTTPHeaderField: "X-Realtime-Tab")
        request.httpBody = try body.encoded()
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// The first value an event brings within `seconds`.
    private func first<T>(_ seconds: Double = 8, _ listen: (@escaping (T) -> Void) -> Void) async throws -> T {
        let box = Box<T>()
        let got = expectation(description: "event")
        listen { value in
            if box.set(value) { got.fulfill() }
        }
        await fulfillment(of: [got], timeout: seconds)
        return try XCTUnwrap(box.value)
    }

    func testConnectsWithTheKeysAndIdentityItsServerGaveAndJoinsItsOrder() async throws {
        let ben = try await signIn(42)
        XCTAssertEqual(ben.rt.user, "42")
        let order = ben.rt.join(try XCTUnwrap(ben.shop["rooms"]?["order"]?.string))
        try await order.ready()
        XCTAssertEqual(order.state, .joined)

        // A room the app's server refuses Ben.
        let other = ben.rt.join("order:999")
        do {
            try await other.ready()
            XCTFail("order:999 was joined")
        } catch let error as RealtimeError {
            XCTAssertEqual(error.code, "forbidden")
        }
    }

    func testHearsTheServersEmitToItsRoomAndToItsUserOpened() async throws {
        let ben = try await signIn(42), ann = try await signIn(34)
        let order = ben.rt.join(try XCTUnwrap(ben.shop["rooms"]?["order"]?.string))
        try await order.ready()

        async let updated: (JSONValue, EventMeta) = first { done in order.on("updated") { done(($0, $1)) } }
        async let notice: JSONValue = first { done in ben.rt.on("notice") { data, _ in done(data) } }
        let status = try await post("orders/1042/status", ["status": "packed"], as: ann)
        XCTAssertEqual(status, 200)

        let (data, meta) = try await updated
        XCTAssertEqual(data["status"], "packed")
        XCTAssertNotNil(meta.id)
        let note = try await notice
        XCTAssertEqual(note["text"]?.string, "Your order #1042 is packed.")
    }

    func testChatsWithAcksTypingVolatileHistoryAndBinarySealedInTheRoom() async throws {
        let ben = try await signIn(42), ann = try await signIn(34)
        let chatName = try XCTUnwrap(ben.shop["rooms"]?["chat"]?.string)
        let bens = ben.rt.join(chatName), anns = ann.rt.join(chatName)
        try await bens.ready()
        try await anns.ready()

        async let typing: (JSONValue, EventMeta) = first { done in bens.on("typing") { done(($0, $1)) } }
        anns.volatile.emit("typing", ["on": true])
        let (typed, typedMeta) = try await typing
        XCTAssertEqual(typed["on"], true)
        XCTAssertEqual(typedMeta.from, "34")

        let text = "From Swift " + UUID().uuidString.prefix(6)
        async let heard: (JSONValue, EventMeta) = first { done in bens.on("message") { data, meta in if data["text"]?.string == text { done((data, meta)) } } }
        let ack = try await anns.emitWithAck("message", ["from": 34, "text": .string(text), "photo": .binary(Data([1, 2, 250]))])
        XCTAssertTrue(ack.id.contains("-"))
        let (message, meta) = try await heard
        XCTAssertEqual(meta.from, "34")
        XCTAssertEqual(meta.id, ack.id)
        XCTAssertEqual(message["photo"]?.data, Data([1, 2, 250]))

        // Kept in the room's history, which Ben pages back.
        let page = try await bens.history(limit: 20)
        XCTAssertTrue(page.events.contains { $0.data["text"]?.string == text && $0.meta.id == ack.id })

        // A name the room's rule doesn't allow.
        do {
            try await anns.emitWithAck("delete", ["x": 1])
            XCTFail("an event the rule doesn't allow was taken")
        } catch let error as RealtimeError {
            XCTAssertEqual(error.code, "not_allowed")
        }
    }

    func testListsWhoIsInTheShopAndWhoIsOnline() async throws {
        let ben = try await signIn(42)
        let shop = ben.rt.join("shop")
        try await shop.ready()
        XCTAssertEqual(shop.members["42"]?["name"], "Ben")

        let changes = ben.rt.online.watch(["34"])
        async let arrived: JSONValue = first(10) { done in shop.on("join") { data, _ in if data["id"]?.string == "34" { done(data) } } }
        async let online: JSONValue = first(10) { done in changes.on("change") { if $0["id"]?.string == "34", $0["online"]?.bool == true { done($0) } } }

        let ann = try await signIn(34)
        let anns = ann.rt.join("shop")
        try await anns.ready()
        let member = try await arrived
        XCTAssertEqual(member["info"]?["role"], "Support")
        _ = try await online
        XCTAssertTrue(ben.rt.online.has("34"))

        async let left: JSONValue = first(10) { done in shop.on("leave") { data, _ in if data["id"]?.string == "34" { done(data) } } }
        async let offline: JSONValue = first(10) { done in changes.on("change") { if $0["id"]?.string == "34", $0["online"]?.bool == false { done($0) } } }
        ann.rt.close()
        _ = try await left
        let gone = try await offline
        XCTAssertNotNil(gone["at"]?.number)
        XCTAssertNotNil(ben.rt.online.lastSeen("34"))
    }

    func testReadsTheDirectoryOfUsersWhoConnected() async throws {
        let ann = try await signIn(34)
        try await ann.rt.join("shop").ready()
        let ben = try await signIn(42)
        try await ben.rt.join("shop").ready()

        // Ann's entry, sealed with the day's key, opened; nobody who never connected keeps one.
        let users = try await ben.rt.users(["34", "9999"])
        XCTAssertEqual(users["34"]?["name"], "Ann")
        XCTAssertEqual(users["34"]?["avatar"], "/avatars/ann.svg")
        XCTAssertNil(users["9999"])
    }

    /// A request to the control port of `serve.mjs` (WORDPLUS_CONTROL), which calls the realtime API as the shop.
    private func control(_ path: String, _ body: JSONValue) async throws -> JSONValue {
        guard let value = ProcessInfo.processInfo.environment["WORDPLUS_CONTROL"], let base = URL(string: value) else {
            throw XCTSkip("WORDPLUS_CONTROL is not set: run `node test/native/serve.mjs` in realtime-js")
        }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = try body.encoded()
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONValue.parse(String(decoding: data, as: UTF8.self)))
    }

    func testAnswersWhatTheServerOfTheAppAsksSealedWithTheKeyOfTheUser() async throws {
        let ben = try await signIn(42)
        try await ben.rt.join("shop").ready()
        ben.rt.answer("where") { data, _ in ["app": "swift", "n": data["n"] ?? .null] }

        let answer = try await control("ask", ["user": "42", "event": "where", "data": ["n": 5], "timeout": 5000])
        let reply = try XCTUnwrap(answer["replies"]?.array?.first)
        XCTAssertEqual(reply["data"]?["app"], "swift")
        XCTAssertEqual(reply["data"]?["n"], 5)

        // An event this app does not answer gets no reply.
        let none = try await control("ask", ["user": "42", "event": "unknown", "timeout": 1000])
        XCTAssertEqual(none["replies"]?.array?.count, 0)
    }

    func testIsSignedOutByTheServerOfTheAppAndAsksItsRoutesAgain() async throws {
        let ben = try await signIn(42)
        let shop = ben.rt.join("shop")
        try await shop.ready()

        async let signedOut: JSONValue = first(10) { done in ben.rt.on("signed_out") { data, _ in done(data) } }
        _ = try await control("disconnect", ["user": "42"])
        _ = try await signedOut

        // The room and the identity come back on tokens the shop signs after, as its rules still let Ben in.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, shop.state != .joined || ben.rt.user != "42" { try await Task.sleep(nanoseconds: 200_000_000) }
        XCTAssertEqual(shop.state, .joined)
        XCTAssertEqual(ben.rt.user, "42")
        let answer = try await control("ask", ["user": "42", "event": "nothing", "timeout": 1000])
        XCTAssertEqual(answer["ok"], true)
    }
}

final class Box<T>: @unchecked Sendable {
    private var stored: T?
    private let lock = NSLock()

    var value: T? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// True the first time.
    func set(_ value: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stored == nil else { return false }
        stored = value
        return true
    }
}
