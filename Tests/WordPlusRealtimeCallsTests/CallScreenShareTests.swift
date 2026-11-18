import LiveKitWebRTC
import XCTest
@testable import WordPlusRealtime
@testable import WordPlusRealtimeCalls

/// Screens in a call between two: the one the other side shares, as the browser's `remote.screen` (realtime-client
/// calls.ts:660, 694). With no server: the route and the socket are stand-ins, and the microphone is refused.
final class CallScreenShareTests: XCTestCase {
    @MainActor
    private func placed() async throws -> Call {
        let (rt, socket, _) = standInCalls()
        socket.answer = { event, _ in event == "call" ? ["ok": true, "role": "polite"] : ["ok": true] }
        CallPermissions.answerAsked = { _ in false }
        addTeardownBlock { CallPermissions.answerAsked = nil }
        await mainSettled()
        return try await rt.calls.start("support:34:42", to: "34", type: .video)
    }

    @MainActor
    func testTheOtherSidesScreenIsDrawnApartFromTheirCamera() async throws {
        let call = try await placed()
        XCTAssertNil(call.remoteScreen)

        let factory = CallMedia.shared.factory
        let screen = factory.videoTrack(with: factory.videoSource(forScreenCast: true), trackId: "their-screen")
        call.session.peerTrack(source: .screenShare, track: screen)
        await mainSettled()

        XCTAssertEqual(call.remoteScreen?.track.trackId, "their-screen")
        XCTAssertNil(call.remoteCamera)

        call.session.peerTrack(source: .screenShare, track: nil)
        await mainSettled()
        XCTAssertNil(call.remoteScreen)
        call.end()
    }
}
