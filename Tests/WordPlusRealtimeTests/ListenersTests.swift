import Foundation
import XCTest
@testable import WordPlusRealtime

/// `once` and `off( event )`, as the browser's rooms have them (realtime-client rooms.ts, `once`, `off`). With no server:
/// a room's events fired as the connection fires them.
final class ListenersTests: XCTestCase {
    private let rt = Realtime(RealtimeOptions(app: "s1", endpoint: URL(string: "https://routes.test/api/realtime")!, callbackQueue: DispatchQueue(label: "listeners-test")))

    /// Fired, and everything fired so far has run.
    private func settle() {
        rt.options.callbackQueue.sync {}
    }

    func testOnceHearsTheNextOneOnly() {
        let room = rt.join("chat:34:42")
        var heard: [Double] = []
        room.once("message") { data, _ in heard.append(data.number ?? 0) }

        // Fired twice before the first has run, as a burst of events is: still once.
        room.fire("message", .number(1), EventMeta())
        room.fire("message", .number(2), EventMeta())
        settle()
        XCTAssertEqual(heard, [1])
    }

    func testOnceCanBeTakenOffBeforeItHears() {
        let room = rt.join("chat:34:42")
        var heard = 0
        let listener = room.once("message") { _, _ in heard += 1 }
        room.off(listener)
        room.fire("message", .null, EventMeta())
        settle()
        XCTAssertEqual(heard, 0)
    }

    func testOnceBesideOnLeavesOnInPlace() {
        let room = rt.join("chat:34:42")
        var always = 0, onlyOnce = 0
        room.on("message") { _, _ in always += 1 }
        room.once("message") { _, _ in onlyOnce += 1 }
        room.fire("message", .null, EventMeta())
        room.fire("message", .null, EventMeta())
        settle()
        XCTAssertEqual([always, onlyOnce], [2, 1])
    }

    func testOffWithAnEventTakesEveryHandlerOfItOffAndNoOther() {
        let room = rt.join("chat:34:42")
        var messages = 0, typing = 0
        room.on("message") { _, _ in messages += 1 }
        room.once("message") { _, _ in messages += 1 }
        room.on("typing") { _, _ in typing += 1 }
        room.off("message")
        room.fire("message", .null, EventMeta())
        room.fire("typing", .null, EventMeta())
        settle()
        XCTAssertEqual([messages, typing], [0, 1])
    }

    func testTheConnectionHasOnceAndOffToo() {
        var notices = 0, moved = 0
        rt.once("notice") { _, _ in notices += 1 }
        rt.on("moved") { _, _ in moved += 1 }
        rt.off("moved")
        rt.queue.sync {
            rt.event("u", ["event": "notice", "data": 1])
            rt.event("u", ["event": "notice", "data": 2])
            rt.event("moved", .null)
        }
        settle()
        XCTAssertEqual([notices, moved], [1, 0])
    }

    func testOnlineTakesAnEventOffToo() {
        var changes = 0
        rt.online.on("change") { _ in changes += 1 }
        rt.online.off("change")
        rt.online.watch(["34"])
        rt.queue.sync { rt.online.changed(["id": "34", "online": true]) }
        settle()
        XCTAssertEqual(changes, 0)
    }
}
