import XCTest
@testable import WordPlusRealtime
@testable import WordPlusRealtimeCalls

/// A live stream's state from Easy Stream's chat socket (LiveStream.swift),
/// with no cloud: the hello, the chat, the counts and the stage as the events say. Going live against a real
/// cloud is the native proof's.
@MainActor
final class LiveStreamTests: XCTestCase {
    private func stream() -> LiveStream {
        let rt = Realtime(RealtimeOptions(app: "app_test", endpoint: URL(string: "https://shop.example/api/realtime")!))
        return LiveStream(owner: rt.calls, name: "show:1")
    }

    private func json(_ text: String) -> JSONValue { JSONValue.parse(text)! }

    private let hello = """
    {"stream": {"id": "show:1", "state": "live", "started_at": 1760000000000, "ended_at": null},
     "you": {"identity": "u:34", "role": "viewer", "name": "Ben", "chat": "write", "mod": false, "stage": true},
     "viewers": 120, "peak": 134, "slow": 0,
     "history": [
       {"id": "m1", "from": {"id": "u:42", "name": "Ann", "avatar": "https://shop.example/ann.png", "role": "host"}, "text": "Hi!", "at": 1760000001000},
       {"id": "m2", "from": {"id": "a:0123456789abcdef", "name": "Guest", "avatar": null, "role": "viewer"}, "text": "Hello", "at": 1760000002000}
     ],
     "hands": [], "pinned": {"id": "m1", "from": {"id": "u:42", "name": "Ann", "avatar": null, "role": "host"}, "text": "Hi!", "at": 1760000001000},
     "layout": {"mode": "spotlight", "identity": "u:42"}, "timeout": null, "reactions": true}
    """

    func testTheHelloSetsTheStreamTheUserAndTheChat() {
        let s = stream()
        var changes = 0
        s.onChange { changes += 1 }
        s.apply("hello", json(hello))

        XCTAssertEqual(s.state, .live)
        XCTAssertEqual(s.startedAt, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(s.role, .viewer)
        XCTAssertTrue(s.canWrite)
        XCTAssertFalse(s.isModerator)
        XCTAssertEqual([s.viewers, s.peak], [120, 134])
        XCTAssertEqual(s.messages.map(\.text), ["Hi!", "Hello"])
        XCTAssertEqual(s.messages.map(\.user), ["42", nil])
        XCTAssertEqual(s.messages.first?.role, .host)
        XCTAssertEqual(s.messages.first?.avatar, "https://shop.example/ann.png")
        XCTAssertEqual(s.pinned?.id, "m1")
        XCTAssertEqual(s.layout, LiveStreamLayout(mode: .spotlight, identity: "u:42"))
        XCTAssertTrue(s.reactionsOn)
        XCTAssertGreaterThan(changes, 0)
    }

    func testTheChatAsItGoes() {
        let s = stream()
        var heard: [String] = []
        s.onMessage { heard.append($0.text) }
        s.apply("hello", json(hello))

        let m3 = json(#"{"id": "m3", "from": {"id": "u:7", "name": "Cara", "avatar": null, "role": "viewer"}, "text": "Nice", "at": 1760000003000}"#)
        s.apply("chat", m3)
        s.apply("chat", m3)
        XCTAssertEqual(s.messages.map(\.id), ["m1", "m2", "m3"], "a message heard twice is kept once")
        XCTAssertEqual(heard, ["Nice"])

        s.apply("chat_deleted", json(#"{"id": "m1"}"#))
        XCTAssertEqual(s.messages.map(\.id), ["m2", "m3"])
        XCTAssertNil(s.pinned, "a deleted message is unpinned")

        s.apply("pinned", json(#"{"message": {"id": "m3", "from": {"id": "u:7", "name": "Cara", "avatar": null, "role": "viewer"}, "text": "Nice", "at": 1}}"#))
        XCTAssertEqual(s.pinned?.id, "m3")
        s.apply("cleared", json("{}"))
        XCTAssertTrue(s.messages.isEmpty)
        XCTAssertNil(s.pinned)
    }

    func testTheCountsTheRulesAndTheStage() {
        let s = stream()
        s.apply("hello", json(hello))

        s.apply("viewers", json(#"{"n": 150, "peak": 160}"#))
        XCTAssertEqual([s.viewers, s.peak], [150, 160])
        s.apply("reacting", json(#"{"on": false}"#))
        XCTAssertFalse(s.reactionsOn)
        s.apply("slow", json(#"{"seconds": 30}"#))
        XCTAssertEqual(s.slow, 30)
        s.apply("layout", json(#"{"mode": "grid", "identity": null}"#))
        XCTAssertEqual(s.layout, LiveStreamLayout(mode: .grid, identity: nil))

        let until = (Date().timeIntervalSince1970 + 600) * 1000
        s.apply("timeout", json(#"{"until": \#(until)}"#))
        XCTAssertFalse(s.canWrite, "kept from writing while timed out")
        s.apply("timeout", json(#"{"until": null}"#))
        XCTAssertTrue(s.canWrite)

        s.apply("state", json(#"{"id": "show:1", "state": "ended", "started_at": 1760000000000, "ended_at": 1760000900000}"#))
        XCTAssertEqual(s.state, .ended)
    }

    func testReactionsAreHeardAsTheirCounts() {
        let s = stream()
        var heard: [[String: Int]] = []
        s.onReactions { heard.append($0) }
        s.apply("reactions", json(#"{"❤️": 2, "heart": 1, "🔥": 1, "🎉": 1, "wow": 0}"#))
        s.apply("reactions", json("{}"))
        // By emoji, a name sent before emoji as its emoji, and any emoji the site offers.
        XCTAssertEqual(heard, [["❤️": 3, "🔥": 1, "🎉": 1]])
    }

    func testABanTakesTheAppOutOfTheStream() {
        let s = stream()
        var ended: [String] = []
        s.onEnded { ended.append($0) }
        s.apply("hello", json(hello))
        s.apply("banned", json("{}"))
        s.apply("kicked", json("{}"))
        XCTAssertEqual(s.endReason, "banned")
        XCTAssertEqual(ended, ["banned"])
    }

    func testAHostKeepsTheChat() {
        let s = stream()
        s.apply("hello", json(hello.replacingOccurrences(of: #""role": "viewer", "name": "Ben", "chat": "write""#, with: #""role": "host", "name": "Ben", "chat": "write""#)))
        XCTAssertEqual(s.role, .host)
        XCTAssertTrue(s.isModerator)
    }

    func testTheAppsUserInTheCloudsNames() {
        XCTAssertEqual(LiveStream.userOf("u:7"), "7")
        XCTAssertEqual(LiveStream.userOf("u:7.0a1b2c3d"), "7", "a place in the room")
        XCTAssertEqual(LiveStream.userOf("u:ann.smith"), "ann.smith", "a user id with a dot")
        XCTAssertNil(LiveStream.userOf("a:0123456789abcdef"), "a visitor")
        XCTAssertNil(LiveStream.userOf("ingest"))
    }

    func testTheMainPictureAsTheWebsPlayerPicksIt() {
        let s = stream()
        func tile(_ id: String, role: LiveStreamRole = .guest, camera: Bool = true, screen: Bool = false, speaking: Bool = false, encoder: Bool = false) -> LiveStreamTile {
            LiveStreamTile(identity: id, user: nil, name: id, avatar: nil, role: role, local: false, camera: camera, screen: screen, microphone: true, speaking: speaking, encoder: encoder)
        }
        s.tiles = [tile("u:42.0a1b2c3d", role: .host), tile("u:7.11112222", speaking: true)]
        XCTAssertEqual(s.mainTile?.identity, "u:42.0a1b2c3d", "the host's")

        s.apply("layout", json(#"{"mode": "speaker", "identity": null}"#))
        XCTAssertEqual(s.mainTile?.identity, "u:7.11112222", "the one speaking")

        s.apply("layout", json(#"{"mode": "spotlight", "identity": "u:7"}"#))
        XCTAssertEqual(s.mainTile?.identity, "u:7.11112222", "the spotlight's, by the person's name")

        s.tiles.append(tile("u:9.33334444", screen: true))
        s.apply("layout", json(#"{"mode": "grid", "identity": null}"#))
        XCTAssertEqual(s.mainTile?.identity, "u:9.33334444", "a shared screen")

        s.tiles = [tile("u:42.0a1b2c3d", role: .host, camera: false)]
        XCTAssertNil(s.mainTile, "nobody sends a picture")
    }

    func testTheStageAsItsEventsSayIt() {
        let s = stream()
        s.apply("hello", json(hello.replacingOccurrences(of: #""hands": []"#, with: #""hands": [{"identity": "u:7", "name": "Cara", "at": 1760000004000}]"#)))
        XCTAssertEqual(s.hands, [LiveStreamHand(user: "7", name: "Cara", at: Date(timeIntervalSince1970: 1_760_000_004))], "the hello's hands")

        s.apply("hands", json(#"[{"identity": "u:7", "name": "Cara", "at": 1760000004000}, {"identity": "u:9", "name": "Dan", "at": 1760000005000}]"#))
        XCTAssertEqual(s.hands.map(\.user), ["7", "9"])

        s.apply("invited", json("{}"))
        XCTAssertTrue(s.invited)
        XCTAssertFalse(s.handRaised)
        s.apply("unstaged", json("{}"))
        XCTAssertFalse(s.onStage, "a viewer who never came on stage stays off it")
    }

    func testAViewerOffStageSendsNothing() async {
        let s = stream()
        s.apply("hello", json(hello))
        do {
            try await s.preview()
            XCTFail("a viewer previewed")
        } catch {
            XCTAssertEqual((error as? CallError)?.code, "not_host")
        }
        XCTAssertFalse(s.camera)
    }
}
