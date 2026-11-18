import CoreVideo
import LiveKit
import LiveKitWebRTC
import XCTest
@testable import WordPlusRealtime
@testable import WordPlusRealtimeCalls

/// Sharing the screen on iOS, as far as a simulator can go, which runs no broadcast extension: when it may be asked for, what
/// the first frame does, and the call told. A real broadcast needs a real iPhone (the shipping guide).
final class ScreenShareTests: XCTestCase {
    private func pixels(width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer)
        return buffer!
    }

    func testAnAppWithoutTheExtensionCannotShare() {
        XCTAssertFalse(ScreenShare.isAvailable)
    }

    @MainActor
    func testACallNotUpSharesNothing() async throws {
        let (rt, socket, _) = standInCalls()
        socket.answer = { event, _ in event == "call" ? ["ok": true, "role": "polite"] : ["ok": true] }
        CallPermissions.answerAsked = { _ in false }
        defer { CallPermissions.answerAsked = nil }
        await mainSettled()
        let call = try await rt.calls.start("support:34:42", to: "34", type: .audio)
        ScreenShare.availableAsked = true
        defer { ScreenShare.availableAsked = nil }

        let asked = await call.setScreenShare(true)
        XCTAssertFalse(asked)
        XCTAssertFalse(call.sharingScreen)
        call.end()
    }

    @MainActor
    func testACallSaysWhenItSharesAndStopsWithTheCall() async throws {
        let (rt, socket, _) = standInCalls()
        socket.answer = { event, _ in event == "call" ? ["ok": true, "role": "polite"] : ["ok": true] }
        CallPermissions.answerAsked = { _ in false }
        defer { CallPermissions.answerAsked = nil }
        await mainSettled()
        let call = try await rt.calls.start("support:34:42", to: "34", type: .audio)
        var heard: [Bool] = []
        call.onScreenShare { heard.append($0) }

        let factory = CallMedia.shared.factory
        let track = factory.videoTrack(with: factory.videoSource(forScreenCast: true), trackId: "call-screen")
        call.startedSharing(track, height: 2532)
        call.startedSharing(track, height: 2532)
        XCTAssertTrue(call.sharingScreen)
        XCTAssertEqual(heard, [true])

        call.end()
        XCTAssertFalse(call.sharingScreen)
        XCTAssertEqual(heard, [true, false])
    }

    #if os(iOS)
    func testTheFirstFrameSaysTheShareBeganOnceAndTheHeightFollows() {
        let share = CallBroadcast()
        var began = 0
        share.onStarted = { began += 1 }
        // Before the track is made there is nowhere to send a frame.
        share.frame(pixels(width: 1170, height: 2532), timeStampNs: 1)
        XCTAssertEqual(began, 0)

        share.prepare(with: CallMedia.shared.factory)
        XCTAssertNotNil(share.screenTrack)
        // A size alone says nothing: `set(size:)` can come with no frame behind it.
        share.set(size: CGSize(width: 1170, height: 2532))
        XCTAssertEqual(began, 0)

        share.frame(pixels(width: 1170, height: 2532), timeStampNs: 2)
        XCTAssertEqual(began, 1)
        XCTAssertEqual(share.captureHeight, 2532)
        share.frame(pixels(width: 2532, height: 1170), timeStampNs: 3)
        XCTAssertEqual(began, 1)
        XCTAssertEqual(share.captureHeight, 1170)
    }
    #endif

    @MainActor
    func testAStreamShareIsAHostsAndShowsAsItsOwnTile() async {
        let rt = Realtime(RealtimeOptions(app: "app_test", endpoint: URL(string: "https://shop.example/api/realtime")!))
        let stream = LiveStream(owner: rt.calls, name: "show:1")
        ScreenShare.availableAsked = true
        defer { ScreenShare.availableAsked = nil }

        let asked = await stream.setScreenShare(true)
        XCTAssertFalse(asked, "a viewer sends nothing")

        stream.apply("hello", ["you": ["role": "host", "chat": "write"], "stream": ["state": "idle"]])
        stream.screenPublished(true)
        XCTAssertTrue(stream.sharingScreen)
        XCTAssertEqual(stream.tiles.first { $0.local }?.screen, true)
        XCTAssertEqual(stream.mainTile?.local, true)

        stream.screenPublished(false)
        XCTAssertFalse(stream.sharingScreen)
        XCTAssertNil(stream.tiles.first { $0.local })
    }
}

#if os(iOS)
/// The handler of the extension, as the shipping guide has an app write it: it stays a class an app can subclass.
private final class SampleHandler: LKSampleHandler {}
#endif
