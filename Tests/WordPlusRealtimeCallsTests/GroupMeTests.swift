@testable import LiveKit
import XCTest
@testable import WordPlusRealtime
@_spi(WordPlusUI) @testable import WordPlusRealtimeCalls

/// `group.me`, this app's own user as the others see them, as the browser's `self` (realtime-client group-call.ts:341).
/// With no server: the room is told who it is as the media server's join would.
final class GroupMeTests: XCTestCase {
    private func group() -> (Realtime, GroupCall) {
        let (rt, _, _) = standInCalls()
        return (rt, GroupCall(owner: rt.calls, name: "meeting:7", link: nil, key: nil, microphone: false, camera: false))
    }

    private func joined(_ call: GroupCall, identity: String = "user_34", metadata: String = #"{"name":"Ben"}"#) {
        call.liveKitRoom.localParticipant._state.mutate {
            $0.identity = Participant.Identity(from: identity)
            $0.metadata = metadata
            $0.permissions = ParticipantPermissions(canSubscribe: true, canPublish: true)
        }
    }

    func testNobodyUntilConnected() {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        XCTAssertNil(call.me)
    }

    func testThisUserAsTheOthersSeeThem() throws {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        joined(call)
        let me = try XCTUnwrap(call.me)
        XCTAssertEqual(me.identity, "user_34")
        XCTAssertEqual(me.user, "34")
        XCTAssertEqual(me.info["name"]?.string, "Ben")
        XCTAssertTrue(me.publish)
        XCTAssertFalse(me.camera)
        XCTAssertFalse(me.microphone)
        XCTAssertFalse(me.speaking)
        XCTAssertFalse(me.optimizing)
    }

    func testAnIdentityNotOfAUserHasNoUser() throws {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        joined(call, identity: "ingest", metadata: "")
        let me = try XCTUnwrap(call.me)
        XCTAssertNil(me.user)
        XCTAssertEqual(me.info, .null)
    }

    func testThisUserIsNotAmongThePeople() {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        joined(call)
        XCTAssertEqual(call.people, [])
    }

    func testNobodyOnceItHasEnded() {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        joined(call)
        call.leave()
        XCTAssertNil(call.me)
    }

    // `own`, what the call screen draws this user's tile from: a tile drew "?" until the room had connected, as it had no name.

    private func token(_ claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9." + payload + ".c2lnbmF0dXJl"
    }

    func testOwnIsTheTokensBeforeTheRoomConnects() {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        call.named(by: token(["sub": "user_34", "metadata": #"{"name":"Ben","avatar":"/ben.svg"}"#]))
        XCTAssertNil(call.me)
        XCTAssertEqual(call.own.identity, "user_34")
        XCTAssertEqual(call.own.info["name"]?.string, "Ben")
        XCTAssertEqual(call.own.info["avatar"]?.string, "/ben.svg")
    }

    func testOwnOpensWhatTheAppsServerSealed() throws {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        rt.keyring.add(["d:20261109:" + String(repeating: "ab", count: 32)])
        let sealed = try XCTUnwrap(rt.keyring.sealJSON(.object(["name": .string("Ben")]), label: "d:20261109"))
        let metadata = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: sealed, options: .fragmentsAllowed), encoding: .utf8))
        call.named(by: token(["sub": "user_34", "metadata": metadata]))
        XCTAssertEqual(call.own.info["name"]?.string, "Ben")
    }

    func testOwnIsTheRoomsOnceItHasConnected() {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        call.named(by: token(["sub": "user_34", "metadata": #"{"name":"From the token"}"#]))
        joined(call, identity: "user_34", metadata: #"{"name":"From the room"}"#)
        XCTAssertEqual(call.own.info["name"]?.string, "From the room")
    }

    func testOwnKeepsTheTokensNameWhileTheRoomHasNoMetadataYet() {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        call.named(by: token(["sub": "user_34", "metadata": #"{"name":"Ben"}"#]))
        joined(call, identity: "user_34", metadata: "")
        XCTAssertEqual(call.own.info["name"]?.string, "Ben")
    }

    func testOwnWithATokenThatCantBeReadIsNobodyYet() {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        call.named(by: "not a token")
        XCTAssertEqual(call.own.identity, "")
        XCTAssertEqual(call.own.info, .null)
    }
}
