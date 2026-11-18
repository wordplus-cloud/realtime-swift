import LiveKit
import XCTest
@testable import WordPlusRealtime
@testable import WordPlusRealtimeCalls

/// What Device Settings asks of the calls beyond what it does itself: how loud the call sends, and the side the next camera
/// opens on, as realtime-kotlin's DeviceCheckTest. With no server: the route and the socket are stand-ins, and the
/// microphone is refused.
final class DeviceCheckTests: XCTestCase {
    @MainActor
    private func placed() async throws -> Call {
        let (rt, socket, _) = standInCalls()
        socket.answer = { event, _ in event == "call" ? ["ok": true, "role": "polite"] : ["ok": true] }
        CallPermissions.answerAsked = { _ in false }
        addTeardownBlock { CallPermissions.answerAsked = nil }
        await mainSettled()
        return try await rt.calls.start("support:34:42", to: "34", type: .audio)
    }

    @MainActor
    func testACallSaysHowLoudOnlyWhileItSends() async throws {
        let call = try await placed()
        XCTAssertNil(call.microphoneLevel, "before the first report there is nothing to read")

        var stats = CallPeerStats()
        stats.microphoneLevel = 0.25
        call.session.peerStats(stats)
        await mainSettled()
        XCTAssertEqual(call.microphoneLevel, 0.25)

        call.microphone = false
        XCTAssertNil(call.microphoneLevel, "muted, nothing is sent to read")
        call.end()
    }

    @MainActor
    func testACallOpensTheCameraChosenWhileNoneIsSent() async throws {
        let call = try await placed()
        XCTAssertTrue(call.frontCamera)
        call.preferCamera(front: false)
        XCTAssertFalse(call.frontCamera)
        call.preferCamera(front: true)
        XCTAssertTrue(call.frontCamera)
        call.end()
    }

    @MainActor
    func testAGroupCallOpensTheCameraChosenAndSaysNoLevelWhileItSendsNone() async throws {
        let (rt, _, _) = standInCalls()
        CallPermissions.answerAsked = { _ in false }
        addTeardownBlock { CallPermissions.answerAsked = nil }
        await mainSettled()
        let group = try await rt.calls.group("meeting:7", type: .audio)
        XCTAssertTrue(group.frontCamera)
        group.preferCamera(front: false)
        XCTAssertFalse(group.frontCamera)
        XCTAssertNil(group.microphoneLevel)
        group.leave()
    }

    func testTheCaptureOpensOnTheSideAsked() {
        let settings = MeshSettings.none
        XCTAssertEqual(GroupShapes.cameraCapture(settings: settings).position, .front)
        XCTAssertEqual(GroupShapes.cameraCapture(settings: settings, front: false).position, .back)
    }
}
