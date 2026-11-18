import XCTest
@testable import WordPlusRealtimeCalls

/// How a direct call encodes and plays in its quality readings, at the level a
/// group call's client tells its node, as the web's calls/quality.ts says it.
final class CallQualityTests: XCTestCase {
    private typealias Entry = CallPair.Entry

    private func n(_ value: Double) -> NSNumber { NSNumber(value: value) }

    private func scope(playing: Set<CallSource> = [ .camera, .microphone ]) -> CallQualityScope {
        let mids: [String: CallSource] = [ "0": .camera, "1": .microphone ]

        return CallQualityScope(
            sending: [ .camera, .microphone ],
            playing: playing,
            outbound: { mids[$0["mid"] as? String ?? ""] },
            inbound: { mids[$0["mid"] as? String ?? ""] }
        )
    }

    private let codecs = [
        Entry(id: "CV", type: "codec", values: [ "mimeType": "video/H264" ]),
        Entry(id: "CD", type: "codec", values: [ "mimeType": "video/VP9" ]),
        Entry(id: "CA", type: "codec", values: [ "mimeType": "audio/opus" ])
    ]

    private func capture(_ t: Double) -> Entry {
        Entry(id: "S1", type: "media-source", values: [ "frames": n(t * 30), "framesPerSecond": n(30), "width": n(1280), "height": n(720) ])
    }

    private func out(_ t: Double, _ more: [String: Any] = [:]) -> Entry {
        Entry(id: "O1", type: "outbound-rtp", values: [
            "kind": "video", "mid": "0", "codecId": "CV", "mediaSourceId": "S1", "bytesSent": n(t * 150_000), "packetsSent": n(t * 150),
            "framesSent": n(t * 29), "framesEncoded": n(t * 30), "totalEncodeTime": n(t * 30 * 0.006), "keyFramesEncoded": n(t),
            "pliCount": n(t), "firCount": n(t), "targetBitrate": n(1_500_000), "retransmittedPacketsSent": n(t * 3), "hugeFramesSent": n(t)
        ].merging(more) { $1 })
    }

    private func video(_ t: Double, _ more: [String: Any] = [:]) -> Entry {
        Entry(id: "I1", type: "inbound-rtp", values: [
            "kind": "video", "mid": "0", "codecId": "CD", "bytesReceived": n(t * 125_000), "packetsReceived": n(t * 140), "packetsLost": n(0),
            "framesDecoded": n(t * 25), "frameHeight": n(540), "totalDecodeTime": n(t * 25 * 0.003), "totalInterFrameDelay": n(t),
            "totalSquaredInterFrameDelay": n(t * 25 * (0.04 * 0.04 + 0.01 * 0.01)), "freezeCount": n(0), "totalFreezesDuration": n(0),
            "pauseCount": n(0), "totalPausesDuration": n(0), "pliCount": n(t), "nackCount": n(t * 2), "jitter": n(0.009)
        ].merging(more) { $1 })
    }

    private func sound(_ t: Double) -> Entry {
        Entry(id: "I2", type: "inbound-rtp", values: [
            "kind": "audio", "mid": "1", "codecId": "CA", "bytesReceived": n(t * 4_000), "packetsReceived": n(t * 50), "packetsLost": n(0),
            "totalSamplesReceived": n(t * 48_000), "insertedSamplesForDeceleration": n(t * 240), "removedSamplesForAcceleration": n(t * 240)
        ])
    }

    private func totals(_ t: Double, _ entries: [Entry], playing: Set<CallSource> = [ .camera, .microphone ]) -> CallQualityWatch.Totals {
        CallQualityWatch.totals(codecs + entries, scope: scope(playing: playing), at: t * 1000)
    }

    private func between(_ from: [Entry], _ to: [Entry]) -> [String: Any] {
        CallQualityWatch.between(totals(10, from), totals(20, to), sending: [ .camera, .microphone ], playing: [ .camera, .microphone ], stalls: [:])
    }

    /// The same gap read two ways: while this side doesn't show the source its
    /// counters stand, and the pause it comes out as lands in the reading after
    /// it shows it again.
    private func watched(_ frozen: [String: Any], resumes: Bool) -> [String: Any] {
        let watch = CallQualityWatch()
        let whole = scope()
        let hiding = scope(playing: [ .microphone ])

        watch.note(totals(10, [ video(10) ]), scope: whole, at: 10_000)
        watch.note(totals(12, [ video(12) ]), scope: whole, at: 12_000)
        _ = watch.reading(health: nil)

        if resumes { watch.note(totals(14, [ video(14) ]), scope: hiding, at: 14_000) }

        watch.note(totals(22, [ video(22, frozen) ]), scope: whole, at: 22_000)

        return (watch.reading(health: nil)?["played"] as? [[String: Any]])?.first ?? [:]
    }

    func testSaysWhatRunsEachSourceTheTimeAFrameTakesAndWhatItCosts() throws {
        let more: [String: Any] = [ "encoderImplementation": "VideoToolbox", "powerEfficientEncoder": NSNumber(value: true) ]
        let reading = between([ capture(10), out(10, more) ], [ capture(20), out(20, more) ])
        let sent = try XCTUnwrap((reading["sent"] as? [[String: Any]])?.first)

        XCTAssertEqual(sent["codec"] as? String, "h264")
        XCTAssertEqual(sent["encoder"] as? String, "VideoToolbox")
        XCTAssertEqual(sent["hw"] as? Bool, true)
        XCTAssertEqual(sent["encodeMs"] as? Double, 6)
        XCTAssertEqual(sent["keyFrames"] as? Double, 10)
        XCTAssertEqual(sent["encoded"] as? Double, 300)
        XCTAssertEqual(sent["framesSent"] as? Double, 290)
        XCTAssertEqual(sent["pli"] as? Double, 20)
        XCTAssertEqual(sent["target"] as? Double, 1500)
        XCTAssertEqual(sent["resent"] as? Double, 2)
        XCTAssertEqual(sent["huge"] as? Double, 10)

        let mode = try XCTUnwrap(sent["mode"] as? [String: Any])

        XCTAssertEqual(mode["width"] as? Double, 1280)
        XCTAssertEqual(mode["height"] as? Double, 720)
        // what it gives is no mode's frames a second
        XCTAssertNil(mode["fps"])
    }

    func testReadsAnEncoderByItsNameFirst() {
        XCTAssertEqual(CallQualityWatch.encoderHardware("OpenH264", powerEfficient: true), false)
        XCTAssertEqual(CallQualityWatch.encoderHardware("libvpx", powerEfficient: nil), false)
        XCTAssertEqual(CallQualityWatch.encoderHardware("VideoToolbox", powerEfficient: false), true)
        XCTAssertEqual(CallQualityWatch.encoderHardware(nil, powerEfficient: true), true)
        XCTAssertNil(CallQualityWatch.encoderHardware(nil, powerEfficient: nil))
    }

    func testSaysHowAPictureAndASoundPlay() throws {
        let reading = between(
            [ video(10, [ "decoderImplementation": "VideoToolbox", "pauseCount": n(0), "totalPausesDuration": n(0) ]), sound(10) ],
            [ video(20, [ "decoderImplementation": "VideoToolbox", "pauseCount": n(1), "totalPausesDuration": n(6) ]), sound(20) ]
        )
        let played = try XCTUnwrap(reading["played"] as? [[String: Any]])

        XCTAssertEqual(played[0]["codec"] as? String, "vp9")
        XCTAssertEqual(played[0]["decoder"] as? String, "VideoToolbox")
        XCTAssertEqual(played[0]["decodeMs"] as? Double, 3)
        XCTAssertEqual(played[0]["unevenMs"] as? Double, 10)
        XCTAssertEqual(played[0]["pauses"] as? Double, 1)
        XCTAssertEqual(played[0]["pauseMs"] as? Double, 6000)
        XCTAssertEqual(played[0]["plis"] as? Double, 10)
        XCTAssertEqual(played[0]["nacks"] as? Double, 20)
        XCTAssertEqual(played[0]["jitterMs"] as? Double, 9)
        XCTAssertEqual(played[1]["codec"] as? String, "opus")
        XCTAssertEqual(played[1]["stretched"] as? Double, 1)
    }

    func testKeepsAGapThisSideMadeOutOfTheCallsPausesAndFreezes() {
        let paused: [String: Any] = [ "pauseCount": n(1), "totalPausesDuration": n(16.1) ]
        let shownAgain = watched(paused, resumes: true)

        XCTAssertEqual(shownAgain["hiddenGaps"] as? Double, 1)
        XCTAssertEqual(shownAgain["hiddenGapMs"] as? Double, 16100)
        XCTAssertNil(shownAgain["pauses"])

        // a freeze short of a pause is the same gap
        let froze = watched([ "freezeCount": n(1), "totalFreezesDuration": n(2) ], resumes: true)

        XCTAssertEqual(froze["freezes"] as? Double, 0)
        XCTAssertEqual(froze["freezeMs"] as? Double, 0)
        XCTAssertEqual(froze["hiddenGaps"] as? Double, 1)
        XCTAssertEqual(froze["hiddenGapMs"] as? Double, 2000)

        // the same figures on a source shown all along are the call's
        let whole = watched(paused, resumes: false)

        XCTAssertEqual(whole["pauses"] as? Double, 1)
        XCTAssertEqual(whole["pauseMs"] as? Double, 16100)
        XCTAssertNil(whole["hiddenGaps"])
    }

    func testSaysNoSpreadWhenItCantTellAGapThisSideMadeFromIt() {
        // two gaps in one reading can't be told apart
        XCTAssertNil(watched([ "pauseCount": n(2), "totalPausesDuration": n(8) ], resumes: true)["unevenMs"])
        XCTAssertEqual(watched([:], resumes: false)["unevenMs"] as? Double, 10)
    }

    func testNamesWhatTheDeviceDoesInHardwareInTheFamiliesOrder() {
        let hardware = CallCodecScore(ok: true, hw: true, smooth: true, fast: true)
        let software = CallCodecScore(ok: true, hw: false, smooth: true, fast: false)
        let caps = CallCodecCaps(families: [
            "video/VP8": (enc: software, dec: software),
            "video/VP9": (enc: software, dec: hardware),
            "video/H264": (enc: hardware, dec: hardware),
            // written off here, whatever its probe said of its hardware
            "video/H265": (enc: CallCodecScore(ok: false, hw: true, smooth: false, fast: false), dec: hardware)
        ], canSwitch: true, engine: "native")

        XCTAssertEqual(CallClientInfo.hardwareFamilies(caps, encoding: true), "h264")
        XCTAssertEqual(CallClientInfo.hardwareFamilies(caps, encoding: false), "h265,h264,vp9")
    }
}
