import XCTest
import UIKit
@testable import WordPlusRealtime
@testable import WordPlusRealtimeCalls
@testable import WordPlusRealtimeUI

/// The live stream drawn ready (LiveStreamScreen), on a simulator, with no cloud: a stream whose events the test gives,
/// as its chat socket would, drawn as it goes. A test target of its own, as it reaches inside the stream, which the call
/// screen's tests copied into an app (scripts/embed-ui.sh) cannot.
@MainActor
final class LiveStreamScreenTests: XCTestCase {
    private var rt: Realtime!

    private func stream() -> LiveStream {
        rt = Realtime(RealtimeOptions(app: "app_test", endpoint: URL(string: "https://shop.example/api/realtime")!))
        return LiveStream(owner: rt.calls, name: "show:1")
    }

    private func json(_ text: String) -> JSONValue { JSONValue.parse(text)! }

    private func hello(state: String, chat: String = "write") -> JSONValue {
        json("""
        {"stream": {"id": "show:1", "state": "\(state)", "started_at": 1760000000000, "ended_at": null},
         "you": {"identity": "u:34", "role": "viewer", "name": "Ben", "chat": "\(chat)", "mod": false},
         "viewers": 120, "peak": 134, "slow": 0,
         "history": [
           {"id": "m1", "from": {"id": "u:42", "name": "Ann", "avatar": null, "role": "host"}, "text": "Hi!", "at": 1760000001000},
           {"id": "m2", "from": {"id": "u:7", "name": "Cara", "avatar": null, "role": "viewer"}, "text": "Hello", "at": 1760000002000}
         ],
         "hands": [], "pinned": null, "layout": {"mode": "grid", "identity": null}, "timeout": null, "reactions": true}
        """)
    }

    private func screen(_ s: LiveStream, strings: [String: String] = [:]) -> LiveStreamScreen {
        let screen = LiveStreamScreen(stream: s, title: "The new mugs", appearance: .init(strings: strings))
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        screen.view.layoutIfNeeded()
        return screen
    }

    func testBeforeTheStartItSaysSoAndShowsNoLiveBadge() {
        let s = stream()
        s.apply("hello", hello(state: "idle"))
        let screen = screen(s)

        XCTAssertEqual(screen.note.text, "The stream starts soon")
        XCTAssertFalse(screen.note.isHidden)
        XCTAssertTrue(screen.badge.isHidden)
        XCTAssertTrue(screen.viewers.isHidden)
        XCTAssertEqual(screen.titleLabel.text, "The new mugs")
    }

    func testLiveItShowsTheBadgeTheCountAndTheChatAsItGoes() {
        let s = stream()
        s.apply("hello", hello(state: "live"))
        let screen = screen(s)

        XCTAssertTrue(screen.note.isHidden)
        XCTAssertEqual(screen.badge.text, "LIVE")
        XCTAssertEqual(screen.viewers.text, "120 watching")
        XCTAssertEqual(screen.table.numberOfRows(inSection: 0), 2)
        XCTAssertTrue(screen.field.isEnabled)
        XCTAssertFalse(screen.heart.isHidden)

        s.apply("viewers", json(#"{"n": 121, "peak": 134}"#))
        s.apply("chat", json(#"{"id": "m3", "from": {"id": "u:9", "name": "Dan", "avatar": null, "role": "viewer"}, "text": "Nice mugs", "at": 1760000003000}"#))
        XCTAssertEqual(screen.viewers.text, "121 watching")
        XCTAssertEqual(screen.table.numberOfRows(inSection: 0), 3)

        s.apply("pinned", json(#"{"message": {"id": "m1", "from": {"id": "u:42", "name": "Ann", "avatar": null, "role": "host"}, "text": "Hi!", "at": 1760000001000}}"#))
        XCTAssertFalse(screen.pinned.isHidden)
        XCTAssertEqual(screen.pinned.attributedText?.string, "Pinned: Ann  Hi!")

        s.apply("state", json(#"{"id": "show:1", "state": "ended", "started_at": 1760000000000, "ended_at": 1760000900000}"#))
        XCTAssertEqual(screen.note.text, "This stream has ended")
        XCTAssertTrue(screen.badge.isHidden)
    }

    func testAReadOnlyViewerCannotWrite() {
        let s = stream()
        s.apply("hello", hello(state: "live", chat: "read"))
        let screen = screen(s)

        XCTAssertFalse(screen.field.isEnabled)
        XCTAssertFalse(screen.send.isEnabled)
        XCTAssertEqual(screen.field.placeholder, "Chat is read-only for you")
    }

    func testItsWordsInTheUserLanguage() {
        let s = stream()
        s.apply("hello", hello(state: "live"))
        let screen = screen(s, strings: ["live": "Live", "watching": "%d schauen zu", "say_something": "Sag etwas…"])

        XCTAssertEqual(screen.viewers.text, "120 schauen zu")
        XCTAssertEqual(screen.field.placeholder, "Sag etwas…")
    }

    func testClosingLeavesTheStreamUnlessTheAppKeepsIt() {
        let s = stream()
        s.apply("hello", hello(state: "live"))
        let screen = screen(s)
        var closed = 0
        screen.onClose = { closed += 1 }

        screen.leavesOnClose = false
        screen.closed()
        XCTAssertEqual(closed, 1)
        XCTAssertNil(s.endReason)

        screen.leavesOnClose = true
        screen.closed()
        XCTAssertEqual(closed, 2)
        XCTAssertEqual(s.endReason, "left")
    }
}
