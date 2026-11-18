@testable import LiveKit
import XCTest
@testable import WordPlusRealtime
@_spi(WordPlusUI) @testable import WordPlusRealtimeCalls

/// What goes wrong in a group call that goes on, as the browser's `error` event says it (realtime-client
/// group-call.ts:254, 401). With no server.
@MainActor
final class GroupErrorTests: XCTestCase {
    private struct Refused: Error {}

    private func group() -> (Realtime, GroupCall) {
        let (rt, _, _) = standInCalls()
        return (rt, GroupCall(owner: rt.calls, name: "meeting:7", link: nil, key: nil, microphone: false, camera: false))
    }

    func testWhatCouldNotGoOutIsTold() async {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        var heard: [GroupCallFailure] = []
        call.onError { heard.append($0) }
        call.publishFailed("camera", Refused())
        await mainSettled()
        XCTAssertEqual(heard.map(\.code), ["publish_failed"])
        XCTAssertEqual(heard.map(\.source), ["camera"])
        XCTAssertNotNil(heard.first?.message)
        XCTAssertEqual(call.state, .connecting, "the call goes on")
    }

    func testACameraThatCannotOpenIsTold() async {
        // The simulator has no camera, so asking for it fails as a phone whose camera is taken does.
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        var heard: [GroupCallFailure] = []
        call.onError { heard.append($0) }
        await call.publishCamera(true)
        await mainSettled()
        XCTAssertEqual(heard.map(\.source), ["camera"])
    }

    func testACameraStoppedThatWasNeverOnSaysNothing() async {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        var heard = 0
        call.onError { _ in heard += 1 }
        await call.publishCamera(false)
        await mainSettled()
        XCTAssertEqual(heard, 0)
    }

    func testATrackThatCannotBeEncryptedIsTold() async {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        var heard: [GroupCallFailure] = []
        call.onError { heard.append($0) }
        let publication = TrackPublication(info: .init(), participant: call.liveKitRoom.localParticipant)
        for state in [E2EEState.new, .ok, .key_ratcheted, .missing_key] {
            call.room(call.liveKitRoom, trackPublication: publication, didUpdateE2EEState: state)
        }
        await mainSettled()
        XCTAssertEqual(heard, [], "a key missing for a moment as someone joins says nothing yet")
        for state in [E2EEState.encryption_failed, .decryption_failed, .internal_error] {
            call.room(call.liveKitRoom, trackPublication: publication, didUpdateE2EEState: state)
        }
        await mainSettled()
        XCTAssertEqual(heard.map(\.code), ["encryption_failed", "encryption_failed", "encryption_failed"])
    }

    func testNothingIsToldOnceItHasEndedOrOfAHandlerTakenOff() async {
        let (rt, call) = group()
        defer { withExtendedLifetime(rt) {} }
        var heard = 0
        let listener = call.onError { _ in heard += 1 }
        call.off(listener)
        call.publishFailed("camera", Refused())
        await mainSettled()
        XCTAssertEqual(heard, 0)

        call.onError { _ in heard += 1 }
        call.leave()
        call.publishFailed("camera", Refused())
        await mainSettled()
        XCTAssertEqual(heard, 0)
    }
}
