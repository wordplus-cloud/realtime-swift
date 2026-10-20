import XCTest
@testable @_spi(WordPlusModules) import WordPlusRealtime
@testable import WordPlusRealtimeCalls

/// What the system's ring is made of that runs with no CallKit (SystemCalls.swift): the push as the realtime server
/// sends it (better-messages-server's sdk-push.ts), the caller's
/// name opened offline, the handles Recents hands back, and on a simulator, which has no CallKit, a pushed ring taken as
/// the ring its line brings. CallKit itself and a real VoIP push are a phone's, checked on one.
final class SystemCallsTests: XCTestCase {
    /// A ring's push as the realtime server sends it to iOS: `wp`, what the line's `incoming` carries.
    private func push(_ wp: [String: Any]) -> [AnyHashable: Any] {
        ["aps": [String: Any](), "wp": wp]
    }

    private func ring(id: String = "ring-1", until: Double = (Date().timeIntervalSince1970 + 40) * 1000, info: Any? = ["sealed": "by-the-app"]) -> [String: Any] {
        var wp: [String: Any] = ["v": 1, "op": "incoming", "id": id, "call": "support:34:12", "from": 12, "type": "video", "at": Date().timeIntervalSince1970 * 1000, "until": until]
        if let info { wp["info"] = info }
        return wp
    }

    func testAPushReadsAsItsLineRings() throws {
        let read = try XCTUnwrap(PushRing(push(ring())))
        XCTAssertEqual(read.id, "ring-1")
        XCTAssertEqual(read.call, "support:34:12")
        XCTAssertEqual(read.from, "12")
        XCTAssertTrue(read.video)
        XCTAssertEqual(read.until.timeIntervalSinceNow, 40, accuracy: 2)

        // Text user ids as the app gave them, and an audio call.
        var text = ring()
        text["from"] = "auth0|5f7c"
        text["type"] = "audio"
        let audio = try XCTUnwrap(PushRing(push(text)))
        XCTAssertEqual(audio.from, "auth0|5f7c")
        XCTAssertFalse(audio.video)

        // A ring into a group call says which.
        var group = ring()
        group["group"] = "call-1"
        XCTAssertEqual(PushRing(push(group))?.group, "call-1")
    }

    func testAPushOfAnythingElseIsNoRing() {
        XCTAssertNil(PushRing(["aps": [String: Any]()]))
        XCTAssertNil(PushRing(push(["v": 1, "op": "ring_over", "id": "ring-1", "reason": "answered_elsewhere"])))
        var noId = ring()
        noId["id"] = ""
        XCTAssertNil(PushRing(push(noId)))
    }

    func testARingRingsAMinuteAtMost() throws {
        let long = try XCTUnwrap(PushRing(push(ring(until: (Date().timeIntervalSince1970 + 600) * 1000))))
        XCTAssertLessThanOrEqual(long.until.timeIntervalSinceNow, 60)
    }

    func testTheCallersNameOpensWithTheDayKeysKept() throws {
        let key = "d:20261016:" + String(repeating: "ab", count: 32)
        let keyring = Keyring()
        keyring.add([key])
        let sealed = try XCTUnwrap(keyring.sealJSON(.object(["name": .string("Ann")]), label: "d:20261016"))

        let pushed = try XCTUnwrap(PushRing(push(ring(info: sealed))))
        XCTAssertEqual(SystemCalls.callerName(pushed, keys: [key]), "Ann")
        // Without the day's key the name waits for the line.
        XCTAssertNil(SystemCalls.callerName(pushed, keys: []))
        XCTAssertNil(SystemCalls.callerName(try XCTUnwrap(PushRing(push(ring(info: nil)))), keys: [key]))

        // The keyring hands a module its keys as the app's server gave them.
        XCTAssertEqual(keyring.entries("d:"), [key])
        XCTAssertEqual(keyring.entries("u:"), [])
    }

    #if os(iOS)
    func testRecentsHandsBackTheHandlesTheCallsWereReportedWith() throws {
        let person = try XCTUnwrap(Intents.callBack(handle: "wordplus:34", video: true))
        XCTAssertEqual(person.user, "34")
        XCTAssertNil(person.group)
        XCTAssertEqual(person.type, .video)

        // A group call's name keeps its own colons, its type before it.
        let group = try XCTUnwrap(Intents.callBack(handle: "wordplus-group:audio:meeting:daily", video: true))
        XCTAssertEqual(group.group, "meeting:daily")
        XCTAssertNil(group.user)
        XCTAssertEqual(group.type, .audio)

        // A handle this app did not write is no call it can place.
        XCTAssertNil(Intents.callBack(handle: "bm:user:34", video: false))
        XCTAssertNil(Intents.callBack(handle: "wordplus:unknown", video: false))
        XCTAssertNil(Intents.callBack(handle: "wordplus-group:video", video: false))
    }

    func testWhyACallEndedIsSaidAsRecentsSaysIt() {
        XCTAssertEqual(SystemCalls.endReason("answered_elsewhere"), .answeredElsewhere)
        XCTAssertEqual(SystemCalls.endReason("rejected"), .declinedElsewhere)
        XCTAssertEqual(SystemCalls.endReason("busy"), .declinedElsewhere)
        XCTAssertEqual(SystemCalls.endReason("no_answer"), .unanswered)
        XCTAssertEqual(SystemCalls.endReason("connection_failed"), .failed)
        XCTAssertEqual(SystemCalls.endReason("cancelled"), .remoteEnded)
        XCTAssertEqual(SystemCalls.endReason("hangup"), .remoteEnded)
    }

    /// On a simulator CallKit cannot run: a pushed ring is kept until its line brings it, and the ring the line brings
    /// is that call, rung on the app's own screen.
    @MainActor
    func testOnASimulatorAPushedRingIsTheRingItsLineBrings() async throws {
        guard !SystemCalls.isAvailable else { throw XCTSkip("CallKit runs here: a phone's check") }

        SystemCalls.start(.init(name: "Example Shop")) {
            // The connection is slow to come: the ring arrives over a line of this process meanwhile.
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return nil
        }
        XCTAssertTrue(SystemCalls.isStarted)

        var reported = false
        SystemCalls.shared.pushReceived(push(ring(id: "ring-sim"))) { reported = true }
        XCTAssertTrue(reported, "a VoIP push is always done with at once")

        let rt = Realtime(RealtimeOptions(app: "app_test", endpoint: URL(string: "https://shop.example/api/realtime")!))
        let incoming = IncomingCall(owner: rt.calls, message: ["id": "ring-sim", "call": "support:34:12", "from": 12, "type": "video"], info: .object(["name": .string("Ann")]))
        XCTAssertFalse(SystemCalls.shared.ringArrived(incoming), "the pushed ring is the app's to ring")
        XCTAssertFalse(SystemCalls.shared.busy)

        // The same push again, sent twice: one ring.
        var again = false
        SystemCalls.shared.pushReceived(push(ring(id: "ring-sim"))) { again = true }
        XCTAssertTrue(again)

        // Over on the line: nothing of it is left.
        SystemCalls.shared.ringOver("ring-sim", reason: "cancelled")
        XCTAssertFalse(SystemCalls.shared.busy)
    }
    #endif
}
