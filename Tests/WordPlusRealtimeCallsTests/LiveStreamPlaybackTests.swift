import XCTest
@testable import WordPlusRealtime
@testable import WordPlusRealtimeCalls

/// A live stream's layers, the viewer's choice among them, and its account of how it plays, as the browser's has them
/// (realtime-client sdk-calls/stream.ts:268-289, streams/playback.ts:64-90).
final class LiveStreamPlaybackTests: XCTestCase {
    private let fullHd = LiveStreamPicture.layers(width: 1920, height: 1080, simulcast: true)

    private func at(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }

    func testAPictureInLayersHasThreeAndOneNotHasOne() {
        XCTAssertEqual(fullHd, [
            LiveStreamLayer(quality: .high, width: 1920, height: 1080),
            LiveStreamLayer(quality: .medium, width: 960, height: 540),
            LiveStreamLayer(quality: .low, width: 480, height: 270),
        ])
        XCTAssertEqual(LiveStreamPicture.layers(width: 1280, height: 720, simulcast: false), [LiveStreamLayer(quality: .high, width: 1280, height: 720)])
    }

    func testNoneAbove720pMayBeChosenAndOneAboveItGivesTheLargestBelow() {
        XCTAssertEqual(LiveStreamPicture.choosable(fullHd).map(\.quality), [.medium, .low])
        XCTAssertEqual(LiveStreamPicture.chosen(.high, in: fullHd)?.quality, .medium)
        XCTAssertEqual(LiveStreamPicture.chosen(.low, in: fullHd)?.quality, .low)
        XCTAssertNil(LiveStreamPicture.chosen(.auto, in: fullHd))

        // A picture on its side is held to its shorter side, and a layer of no size stays.
        XCTAssertEqual(LiveStreamPicture.choosable(LiveStreamPicture.layers(width: 720, height: 1280, simulcast: true)).count, 3)
        XCTAssertEqual(LiveStreamPicture.choosable(LiveStreamPicture.layers(width: 0, height: 0, simulcast: true)).count, 1)
    }

    func testAPictureIsTheLayerNearestItsHeight() {
        XCTAssertEqual(LiveStreamPicture.layer(atHeight: 500, in: fullHd), .medium)
        XCTAssertNil(LiveStreamPicture.layer(atHeight: 0, in: fullHd))
    }

    func testAViewAsksForJustTheLayerChosen() throws {
        let layer = LiveStreamLayer(quality: .medium, width: 960, height: 540)
        // A wide picture fitted into a phone in portrait is as tall as its width allows: 390 x 9/16.
        XCTAssertEqual(try XCTUnwrap(LiveStreamPicture.density(for: layer, in: CGSize(width: 390, height: 844), fills: false)), 540.0 / (390.0 * 9 / 16), accuracy: 0.001)
        // Filling the same view, it is as tall as the view.
        XCTAssertEqual(try XCTUnwrap(LiveStreamPicture.density(for: layer, in: CGSize(width: 390, height: 844), fills: true)), 540.0 / 844, accuracy: 0.001)
        XCTAssertNil(LiveStreamPicture.density(for: layer, in: .zero, fills: false))
        XCTAssertNil(LiveStreamPicture.density(for: LiveStreamLayer(quality: .low, width: 0, height: 0), in: CGSize(width: 390, height: 844), fills: false))
    }

    func testRatesComeFromTwoReadings() throws {
        let p = LiveStreamPlayback()
        p.joining(at: at(0))
        p.joined(server: LiveStreamStats.Server(url: "wss://node", node: "n1", region: nil, version: "1.0"), at: at(100))

        p.read(video: LiveStreamRtp(bytes: 1000, frames: 10, received: 100, height: 540), audio: nil, layers: fullHd, transport: nil, pictured: true, at: at(1100))
        XCTAssertEqual(p.snapshot(at: at(1100)).video?.kbps, 0)

        p.read(
            video: LiveStreamRtp(bytes: 126_000, frames: 40, lost: 10, received: 190, bufferDelay: 3, emitted: 30, height: 540),
            audio: LiveStreamRtp(bytes: 5000, concealed: 10, samples: 1000),
            layers: fullHd,
            transport: LiveStreamStats.Transport(protocol: "udp", relayed: false, relayProtocol: nil, rttMs: 40),
            pictured: true,
            at: at(2100)
        )
        let stats = p.snapshot(at: at(2100))
        let video = try XCTUnwrap(stats.video)
        XCTAssertEqual(video.kbps, 1000, accuracy: 0.01)
        XCTAssertEqual(video.lossPct, 10, accuracy: 0.01)
        XCTAssertEqual(video.bufferMs, 100, accuracy: 0.01)
        XCTAssertEqual(video.layer, .medium)
        XCTAssertEqual(stats.transport?.protocol, "udp")
        XCTAssertEqual(stats.server?.node, "n1")
    }

    func testTheSessionCountsTheStartupStallsAndRejoins() {
        let p = LiveStreamPlayback()
        p.joining(at: at(0))
        p.joined(server: nil, at: at(500))
        p.read(video: LiveStreamRtp(frames: 5), audio: nil, layers: fullHd, transport: nil, pictured: true, at: at(1000))
        XCTAssertEqual(p.session.startupMs, 1000)

        // No new frame for 2 s while it should show them.
        p.read(video: LiveStreamRtp(frames: 5), audio: nil, layers: fullHd, transport: nil, pictured: true, at: at(2000))
        XCTAssertEqual(p.session.stalls, 0)
        p.read(video: LiveStreamRtp(frames: 5), audio: nil, layers: fullHd, transport: nil, pictured: true, at: at(3000))
        XCTAssertEqual(p.session.stalls, 1)
        p.read(video: LiveStreamRtp(frames: 9), audio: nil, layers: fullHd, transport: nil, pictured: true, at: at(4000))
        XCTAssertEqual(p.session.stalledMs, 3000, accuracy: 0.01)

        // A view that isn't showing it is no stall.
        p.read(video: LiveStreamRtp(frames: 9), audio: nil, layers: fullHd, transport: nil, pictured: false, at: at(9000))
        XCTAssertEqual(p.session.stalls, 1)

        p.reconnecting(at: at(9500))
        p.reconnected(at: at(9600))
        p.left(at: at(10_000))
        XCTAssertEqual(p.session.watchedMs, 9500, accuracy: 0.01)
        p.joining(at: at(11_000))
        p.joined(server: nil, at: at(11_500))
        p.failed("media_unreachable", at: at(12_000))
        XCTAssertEqual([p.session.reconnects, p.session.rejoins, p.session.errors], [1, 1, 1])
        XCTAssertEqual(p.events.map(\.kind), ["joining", "joined", "first-frame", "stalled", "resumed", "reconnecting", "reconnected", "left", "joining", "rejoined", "error"])
    }

    func testItKeepsTheLastEvents() {
        let p = LiveStreamPlayback()
        for i in 0..<60 { p.note("quality", "\(i)") }
        XCTAssertEqual(p.events.count, LiveStreamPlayback.eventsKept)
        XCTAssertEqual(p.events.last?.detail, "59")
    }

    @MainActor
    func testAChoiceOfQualityIsKeptAndToldAndNoLayersBeforeThePicture() {
        let rt = Realtime(RealtimeOptions(app: "app_test", endpoint: URL(string: "https://shop.example/api/realtime")!))
        let stream = LiveStream(owner: rt.calls, name: "show:1")
        var changes = 0
        stream.onChange { changes += 1 }

        XCTAssertEqual(stream.quality, .auto)
        XCTAssertEqual(stream.qualities(), [])
        XCTAssertNil(stream.chosenLayer(of: nil))

        stream.setQuality(.low)
        XCTAssertEqual(stream.quality, .low)
        XCTAssertEqual(changes, 1)
        stream.setQuality(.low)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(stream.stats().events.last?.detail, "low")
    }
}
