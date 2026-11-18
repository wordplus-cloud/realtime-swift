import Foundation
import XCTest
@testable import WordPlusRealtime

/// A watch that fails says so, as the browser's does (realtime-client rooms.ts, Online's `send`), where it was passed over
/// and a screen showed everyone offline with no word why.
final class OnlineTests: XCTestCase {
    private var rt: Realtime!
    private var socket: FakeSocket!

    override func setUp() {
        super.setUp()
        rt = Realtime(RealtimeOptions(app: "s1", endpoint: URL(string: "https://routes.test/api/realtime")!, callbackQueue: DispatchQueue(label: "online-test")))
        socket = FakeSocket(rt)
    }

    private func watched(_ answer: JSONValue?) -> (errors: [String], changes: Int) {
        socket.answer = { _, _ in answer }
        var errors: [String] = [], changes = 0
        rt.online.on("error") { errors.append($0["code"]?.string ?? "") }
        rt.online.on("change") { _ in changes += 1 }
        rt.online.watch(["34"])
        let done = expectation(description: "held")
        rt.queue.async { self.rt.online.again(on: self.socket) { done.fulfill() } }
        wait(for: [done], timeout: 5)
        rt.options.callbackQueue.sync {}
        return (errors, changes)
    }

    func testARefusedWatchSaysWhy() {
        let heard = watched(["error": "no_identity"])
        XCTAssertEqual(heard.errors, ["no_identity"])
        XCTAssertEqual(heard.changes, 0)
    }

    func testAWatchNotAnsweredSaysSo() {
        XCTAssertEqual(watched(nil).errors, ["timeout"])
    }

    func testAnAnswerWithoutACodeIsTheServers() {
        XCTAssertEqual(watched(["ok": false]).errors, ["server"])
    }

    func testAWatchAnsweredTellsTheStatesAndNoError() {
        let heard = watched(["ok": true, "online": [["id": "34", "online": true]]])
        XCTAssertEqual(heard.errors, [])
        XCTAssertEqual(heard.changes, 1)
        XCTAssertTrue(rt.online.has("34"))
    }
}
