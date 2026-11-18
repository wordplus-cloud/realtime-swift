import Foundation
import XCTest
@testable import WordPlusRealtime

/// Rooms joined and left in one moment go in one request, as the browser's do since @wordplus/realtime-client 1.0.6
/// (rooms.ts, joinMany and leaveMany, better-messages-server 4fa3c70, inc/channels/socket.ts joinMany): each token once,
/// each room naming its own by index and answered as its own join, at most 100 a request, a reconnect's and a move's
/// rejoins too, and one room a request on a server from before it. An inbox joins the rooms of its visible rows so.
final class JoinManyTests: XCTestCase {
    private var rt: Realtime!
    private var socket: FakeSocket!
    private let queue = DispatchQueue(label: "join-many-test")

    /// Tokens by the rooms' first part, with no route to ask: `a:` and `c:` rooms one, `b:` rooms another.
    override func setUp() {
        super.setUp()
        // Room for a busy machine: one moment longer than a test's joins take, however slowly they run.
        Realtime.togetherAfter = 0.15
        let exp = Date().timeIntervalSince1970 + 3600
        rt = Realtime(RealtimeOptions(
            app: "s1", endpoint: URL(string: "https://routes.test/api/realtime")!,
            grants: [
                PublicGrant(token: "t-a", exp: exp, rooms: ["a:{id}", "c:{id}"]),
                PublicGrant(token: "t-b", exp: exp, rooms: ["b:{id}"]),
            ],
            callbackQueue: queue
        ))
        socket = FakeSocket(rt)
        rt.socketAsked = socket
    }

    override func tearDown() {
        Realtime.togetherAfter = 0.01
        super.tearDown()
    }

    private func answered(_ make: @escaping (JSONValue) -> JSONValue?) {
        socket.answer = { event, data in event == "join" ? make(data) : ["ok": true] }
    }

    /// Each room named in a `join { rooms }` answered as joined.
    private func allJoined(_ data: JSONValue) -> JSONValue {
        var told: [String: JSONValue] = [:]
        for entry in data["rooms"]?.array ?? [] { told[entry["room"]?.string ?? ""] = ["ok": true] }
        return ["ok": true, "rooms": .object(told)]
    }

    private func settled(_ wait: TimeInterval = 0.4) {
        Thread.sleep(forTimeInterval: wait)
        rt.queue.sync {}
        queue.sync {}
    }

    private func hold(_ rooms: [Room]) -> Bool? {
        var ok: Bool?
        let done = expectation(description: "held")
        rt.queue.async { self.rt.joinMany(rooms, on: self.socket) { ok = $0; done.fulfill() } }
        wait(for: [done], timeout: 5)
        return ok
    }

    func testRoomsJoinedInOneMomentGoInOneRequestEachTokenOnce() {
        answered(allJoined)
        let rooms = ["a:1", "b:1", "c:1"].map { rt.join($0) }
        settled()

        XCTAssertEqual(socket.asked("join").count, 1)
        let sent = socket.asked("join")[0]
        XCTAssertEqual(sent["tab"]?.string, rt.tab)
        let tokens = sent["tokens"]?.array?.compactMap(\.string) ?? []
        XCTAssertEqual(Set(tokens), ["t-a", "t-b"])
        XCTAssertEqual(tokens.count, 2)
        var named: [String: String] = [:]
        for entry in sent["rooms"]?.array ?? [] { named[entry["room"]?.string ?? ""] = tokens[entry["t"]?.int ?? -1] }
        XCTAssertEqual(named, ["a:1": "t-a", "b:1": "t-b", "c:1": "t-a"])
        XCTAssertNil(sent["room"])
        rooms.forEach { XCTAssertEqual($0.state, .joined) }
    }

    func testARoomAloneGoesAsItAlwaysDid() {
        answered { _ in ["ok": true] }
        let room = rt.join("a:1")
        settled()

        let sent = socket.asked("join")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0]["room"]?.string, "a:1")
        XCTAssertEqual(sent[0]["token"]?.string, "t-a")
        XCTAssertNil(sent[0]["rooms"])
        XCTAssertEqual(room.state, .joined)
    }

    func testEachRoomIsAnsweredAsItsOwnJoin() {
        answered { _ in
            ["ok": true, "rooms": [
                "a:1": ["ok": true, "members": ["count": 2, "list": [["id": 34, "info": ["name": "Ann"]], ["id": "x", "info": .null]]], "count": 2],
                "a:2": ["ok": true, "missed": [["event": "updated", "data": ["n": 1], "id": "5-0", "at": 5]], "gap": true],
                "b:1": ["error": "forbidden"],
                // c:1 not told of.
            ]]
        }
        let one = rt.join("a:1"), two = rt.join("a:2"), three = rt.join("b:1"), four = rt.join("c:1")
        var missed: [EventMeta] = [], errors: [String] = []
        two.on("updated") { _, meta in missed.append(meta) }
        two.on("error") { data, _ in errors.append(data["code"]?.string ?? "") }
        settled()

        XCTAssertEqual(one.state, .joined)
        XCTAssertEqual(Set(one.members.keys), ["34", "x"])
        XCTAssertEqual(one.count, 2)
        XCTAssertEqual(two.state, .joined)
        XCTAssertEqual(missed.map(\.replayed), [true])
        XCTAssertEqual(errors, ["gap"])
        XCTAssertEqual(three.error, "forbidden")
        XCTAssertEqual(three.state, .failed)
        XCTAssertEqual(four.error, "server")
    }

    func testARoomJoinsFromTheLastEventItHad() {
        answered(allJoined)
        let one = rt.join("a:1"), two = rt.join("a:2")
        rt.queue.sync { one.lastId = "9-1" }
        settled()

        let entries = socket.asked("join")[0]["rooms"]?.array ?? []
        XCTAssertEqual(entries.first { $0["room"]?.string == "a:1" }?["since"]?.string, "9-1")
        XCTAssertNil(entries.first { $0["room"]?.string == "a:2" }?["since"])
        _ = two
    }

    func testAtMostAHundredARequest() {
        answered(allJoined)
        // Off line as they are joined, then held at once, as at a reconnect.
        socket.isConnected = false
        let rooms = (1 ... 250).map { rt.join("a:\($0)") }
        socket.isConnected = true
        XCTAssertEqual(hold(rooms), true)
        settled()

        let sizes = socket.asked("join").map { $0["rooms"]?.array?.count ?? 0 }
        XCTAssertEqual(sizes.sorted(), [50, 100, 100])
        rooms.forEach { XCTAssertEqual($0.state, .joined) }
    }

    func testAServerFromBeforeThisJoinsThemOneByOneAndIsNotAskedAgain() {
        // No `room` to read: as a server before better-messages-server 4fa3c70 answers.
        answered { data in data["room"] == nil ? ["error": "bad_request"] : ["ok": true] }
        let rooms = ["a:1", "b:1"].map { rt.join($0) }
        settled()

        XCTAssertEqual(socket.asked("join").filter { $0["rooms"] != nil }.count, 1)
        XCTAssertEqual(Set(socket.asked("join").compactMap { $0["room"]?.string }), ["a:1", "b:1"])
        rooms.forEach { XCTAssertEqual($0.state, .joined) }

        let more = ["a:2", "b:2"].map { rt.join($0) }
        settled()
        XCTAssertEqual(socket.asked("join").filter { $0["rooms"] != nil }.count, 1, "asked for many again")
        more.forEach { XCTAssertEqual($0.state, .joined) }
    }

    func testAWholeRequestRefusedFailsItsRoomsWithItsCode() {
        answered { _ in ["error": "rate_limited"] }
        let rooms = ["a:1", "b:1"].map { rt.join($0) }
        settled()
        rooms.forEach { XCTAssertEqual($0.error, "rate_limited") }
    }

    func testARoomWhoseTokenRanOutIsAskedAgainAlone() {
        var first = true
        answered { data in
            guard data["rooms"] != nil else { return ["ok": true] }
            defer { first = false }
            return first ? ["ok": true, "rooms": ["a:1": ["error": "expired"], "b:1": ["ok": true]]] : nil
        }
        let rooms = ["a:1", "b:1"].map { rt.join($0) }
        settled()

        XCTAssertEqual(socket.asked("join").compactMap { $0["room"]?.string }, ["a:1"])
        rooms.forEach { XCTAssertEqual($0.state, .joined) }
    }

    func testARequestNotAnsweredLeavesItsRoomsJoiningAndFailsTheHold() {
        // A move switches sockets only once all of it is held (Connection.swift), so this keeps the old socket.
        answered { _ in nil }
        let rooms = ["a:1", "b:1"].map { rt.join($0) }
        settled()
        rooms.forEach { XCTAssertEqual($0.state, .joining) }
        XCTAssertEqual(hold(rooms), false)
    }

    func testAReconnectsAndAMovesRejoinsGoInOneRequest() {
        // Off line: nothing goes as the rooms are joined.
        socket.isConnected = false
        let rooms = ["a:1", "b:1", "c:1"].map { rt.join($0) }
        settled()
        XCTAssertTrue(socket.asked.isEmpty)

        let next = FakeSocket(rt)
        next.answer = { [self] event, data in event == "join" ? allJoined(data) : ["ok": true] }
        var ok: Bool?
        let held = expectation(description: "held")
        rt.queue.async { self.rt.holdAll(on: next) { ok = $0; held.fulfill() } }
        wait(for: [held], timeout: 5)

        XCTAssertEqual(ok, true)
        XCTAssertEqual(next.asked("join").count, 1)
        XCTAssertEqual(next.asked("join")[0]["rooms"]?.array?.count, 3)
        rooms.forEach { XCTAssertEqual($0.state, .joined) }
    }

    func testRoomsLeftInOneMomentGoInOneRequest() {
        answered(allJoined)
        ["a:1", "b:1"].forEach { rt.join($0) }
        settled()
        ["a:1", "b:1"].forEach { rt.leave($0) }
        settled()

        let left = socket.asked("leave")
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left[0]["tab"]?.string, rt.tab)
        XCTAssertEqual(Set(left[0]["rooms"]?.array?.compactMap(\.string) ?? []), ["a:1", "b:1"])
    }

    func testARoomLeftAloneGoesAsItAlwaysDid() {
        answered { _ in ["ok": true] }
        rt.join("a:1")
        settled()
        rt.leave("a:1")
        settled()
        XCTAssertEqual(socket.asked("leave").map { $0["room"]?.string }, ["a:1"])
    }

    func testAServerFromBeforeThisTakesLeavesOneByOne() {
        socket.answer = { event, data in
            if event == "leave", data["rooms"] != nil { return ["error": "bad_request"] }
            return event == "join" ? self.allJoined(data) : ["ok": true]
        }
        ["a:1", "b:1"].forEach { rt.join($0) }
        settled()
        ["a:1", "b:1"].forEach { rt.leave($0) }
        settled()
        XCTAssertEqual(Set(socket.asked("leave").compactMap { $0["room"]?.string }), ["a:1", "b:1"])
    }

    func testARoomLeftBeforeItsJoinWentIsNotJoined() {
        answered(allJoined)
        let kept = rt.join("a:1")
        rt.join("b:1")
        rt.leave("b:1")
        settled()

        XCTAssertEqual(socket.asked("join").map { $0["room"]?.string }, ["a:1"])
        XCTAssertEqual(kept.state, .joined)
    }

    func testARoomLeftAndJoinedAgainLeavesFirst() {
        answered(allJoined)
        rt.join("a:1")
        settled()
        rt.leave("a:1")
        let again = rt.join("a:1")
        settled()

        let order = socket.asked.map(\.event)
        XCTAssertEqual(order, ["join", "leave", "join"])
        XCTAssertEqual(again.state, .joined)
    }

    func testARoomAnsweredAfterItWasLeftIsLeftAlone() {
        let late = DispatchSemaphore(value: 0)
        answered { [self] data in
            if data["rooms"] != nil { late.wait() }
            return allJoined(data)
        }
        let rooms = ["a:1", "b:1"].map { rt.join($0) }
        Thread.sleep(forTimeInterval: 0.05)
        rt.leave("a:1")
        late.signal()
        settled()

        XCTAssertEqual(rooms[0].state, .left)
        XCTAssertEqual(rooms[1].state, .joined)
    }
}
