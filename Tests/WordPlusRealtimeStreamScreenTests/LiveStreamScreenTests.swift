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

    private func settled(_ screen: LiveStreamScreen, until done: () -> Bool) async {
        for _ in 0..<100 where !done() { try? await Task.sleep(nanoseconds: 10_000_000) }
        screen.render()
    }

    func testASignedInViewerAsksToComeOnStageAndLowersTheirHand() async {
        let s = stream()
        s.apply("hello", hello(state: "live"))
        let screen = screen(s)
        var asked: [JSONValue] = []
        s.asking = { event, payload in
            XCTAssertEqual(event, "hand")
            asked.append(payload["up"] ?? .null)
            return JSONValue.parse(#"{"ok": true}"#)
        }

        XCTAssertFalse(screen.stageRow.isHidden)
        XCTAssertFalse(screen.hand.isHidden)
        XCTAssertEqual(screen.hand.configuration?.title, "Ask to join on stage")
        XCTAssertTrue(screen.cameraButton.isHidden)
        XCTAssertTrue(screen.leaveStage.isHidden)

        screen.handPressed()
        await settled(screen) { s.handRaised }
        XCTAssertEqual(screen.hand.configuration?.title, "Lower hand")
        XCTAssertEqual(screen.hand.accessibilityValue, "up")

        screen.handPressed()
        await settled(screen) { !s.handRaised }
        XCTAssertEqual(screen.hand.configuration?.title, "Ask to join on stage")
        XCTAssertEqual(asked, [.bool(true), .bool(false)])
    }

    func testNoAskingForOneTheStreamWouldNotTake() {
        func hidden(_ change: (String) -> String) -> Bool {
            let s = stream()
            var text = #"{"stream": {"id": "show:1", "state": "live", "started_at": 1760000000000, "ended_at": null}, "#
            text += #""you": {"identity": "u:34", "role": "viewer", "name": "Ben", "chat": "write", "mod": false}, "#
            text += #""viewers": 1, "peak": 1, "slow": 0, "history": [], "hands": [], "pinned": null, "timeout": null, "reactions": true}"#
            s.apply("hello", json(change(text)))
            let shown = screen(s)
            return shown.hand.isHidden && shown.stageRow.isHidden
        }
        XCTAssertFalse(hidden { $0 })
        XCTAssertTrue(hidden { $0.replacingOccurrences(of: #""mod": false"#, with: #""mod": false, "stage": false"#) })
        XCTAssertTrue(hidden { $0.replacingOccurrences(of: #""identity": "u:34""#, with: #""identity": "a:0123456789abcdef""#) }, "a visitor")
        XCTAssertTrue(hidden { $0.replacingOccurrences(of: #""role": "viewer""#, with: #""role": "host""#) })
        XCTAssertTrue(hidden { $0.replacingOccurrences(of: #""state": "live""#, with: #""state": "idle""#) })
    }

    func testTheInvitationAsksAndNotNowPutsItAway() {
        let s = stream()
        s.apply("hello", hello(state: "live"))
        let screen = screen(s)
        XCTAssertTrue(screen.invitation.isHidden)

        s.apply("invited", json("{}"))
        XCTAssertFalse(screen.invitation.isHidden)
        XCTAssertEqual(screen.invitedTitle.text, "The host invites you on stage")
        XCTAssertEqual(screen.invitedText.text, "Your camera and microphone will be live for everyone watching.")
        XCTAssertTrue(screen.hand.isHidden, "invited, there is nothing left to ask")

        screen.notNowPressed()
        XCTAssertFalse(s.invited)
        XCTAssertTrue(screen.invitation.isHidden)
        XCTAssertFalse(screen.hand.isHidden)
    }

    func testAJoinThatFailsSaysWhyAndStaysAViewer() async {
        let s = stream()
        s.apply("hello", hello(state: "live"))
        let screen = screen(s)
        s.asking = { _, _ in JSONValue.parse(#"{"ok": false, "error": "not_invited"}"#) }
        s.apply("invited", json("{}"))

        screen.joinPressed()
        await settled(screen) { !screen.failure.isHidden }
        XCTAssertEqual(screen.failure.text, "You could not join the stage (not_invited)")
        XCTAssertFalse(s.onStage)
        XCTAssertFalse(s.invited, "refused, the invitation is gone, as on the web")
        XCTAssertTrue(screen.invitation.isHidden)
        XCTAssertFalse(screen.hand.isHidden)
    }

    func testOnStageItHasTheirDevicesAndAWayOff() async {
        let s = stream()
        s.apply("hello", hello(state: "live"))
        let screen = screen(s)
        var asked: [String] = []
        s.asking = { event, _ in asked.append(event); return JSONValue.parse(#"{"ok": true}"#) }

        s.onStage = true
        screen.render()
        XCTAssertTrue(screen.hand.isHidden)
        XCTAssertFalse(screen.cameraButton.isHidden)
        XCTAssertFalse(screen.microphoneButton.isHidden)
        XCTAssertFalse(screen.leaveStage.isHidden)
        XCTAssertEqual(screen.leaveStage.configuration?.title, "Leave stage")
        XCTAssertEqual(screen.cameraButton.accessibilityLabel, "Camera")
        XCTAssertEqual(screen.cameraButton.accessibilityValue, "off")
        XCTAssertEqual(screen.microphoneButton.accessibilityLabel, "Microphone")
        XCTAssertTrue(screen.own.isHidden, "no camera on, nothing of their own to show")

        screen.leaveStagePressed()
        await settled(screen) { asked == ["unstage"] }
        XCTAssertFalse(s.onStage)
        XCTAssertEqual(asked, ["unstage"])
        XCTAssertFalse(screen.hand.isHidden)
        XCTAssertTrue(screen.leaveStage.isHidden)
    }

    func testAnEndedStreamOffersNothingAboutTheStage() {
        let s = stream()
        s.apply("hello", hello(state: "live"))
        s.onStage = true
        let screen = screen(s)
        XCTAssertFalse(screen.stageRow.isHidden)
        s.apply("hello", hello(state: "ended"))
        screen.render()
        XCTAssertTrue(screen.stageRow.isHidden)
        XCTAssertTrue(screen.invitation.isHidden)
    }

    func testItsStageWordsInTheUserLanguage() {
        let s = stream()
        s.apply("hello", hello(state: "live"))
        let screen = screen(s, strings: ["ask_stage": "Auf die Bühne", "join_stage": "Beitreten"])
        XCTAssertEqual(screen.hand.configuration?.title, "Auf die Bühne")
        XCTAssertEqual(screen.joinStage.configuration?.title, "Beitreten")
    }
}
