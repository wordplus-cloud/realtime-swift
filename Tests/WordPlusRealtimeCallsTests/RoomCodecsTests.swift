import XCTest
@testable import WordPlusRealtimeCalls

/// The codec a room's camera goes out in and what goes behind it (CallCodecs.roomPublishCodec, roomBackupCodec), as
/// the browser's rule picks them (the realtime client's calls/room-publish.ts) and Better Messages' app does: the media
/// server's policy first choice first, where this device encodes it, else H.264 from hardware with VP8 behind it.
final class RoomCodecsTests: XCTestCase {
    private func caps(_ encoders: [String: (ok: Bool, hw: Bool)]) -> CallCodecCaps {
        var families: [String: (enc: CallCodecScore, dec: CallCodecScore)] = [:]
        for family in CallCodecs.families {
            let name = String(family.dropFirst("video/".count))
            let enc = encoders[name] ?? (ok: false, hw: false)
            families[family] = (enc: CallCodecScore(ok: enc.ok, hw: enc.hw, smooth: true, fast: enc.hw), dec: CallCodecScore(ok: true, hw: true, smooth: true, fast: true))
        }
        return CallCodecCaps(families: families, canSwitch: false, engine: nil)
    }

    private lazy var phone = caps(["H264": (true, true), "H265": (true, true), "VP8": (true, false), "VP9": (true, false)])

    func testWithoutAPolicyItIsH264FromHardwareWithVP8BehindIt() {
        XCTAssertEqual(CallCodecs.roomPublishCodec(phone, encrypted: false), "h264")
        XCTAssertEqual(CallCodecs.roomBackupCodec("h264", encrypted: false), "vp8")

        let software = caps(["H264": (true, false), "VP8": (true, false)])
        XCTAssertEqual(CallCodecs.roomPublishCodec(software, encrypted: false), "vp8")
        XCTAssertNil(CallCodecs.roomBackupCodec("vp8", encrypted: false))
    }

    func testAnEncryptedRoomTakesVP8AloneWhateverThePolicy() {
        XCTAssertEqual(CallCodecs.roomPublishCodec(phone, encrypted: true, onMesh: true, policy: ["h265:hw", "h264"]), "vp8")
        XCTAssertNil(CallCodecs.roomBackupCodec("vp8", encrypted: true))
        XCTAssertNil(CallCodecs.roomBackupCodec("h264", encrypted: true))
    }

    func testThePolicyGoesFirstChoiceFirstWhereThisDeviceEncodesIt() {
        // VP9 in software is taken where the list says vp9; "h265:hw" only from hardware, and only on the mesh.
        XCTAssertEqual(CallCodecs.roomPublishCodec(phone, encrypted: false, onMesh: true, policy: ["vp9", "h264", "vp8"]), "vp9")
        XCTAssertEqual(CallCodecs.roomPublishCodec(phone, encrypted: false, onMesh: true, policy: ["h265:hw", "vp8"]), "h265")
        XCTAssertEqual(CallCodecs.roomPublishCodec(phone, encrypted: false, onMesh: false, policy: ["h265:hw", "vp8"]), "vp8")
        XCTAssertEqual(CallCodecs.roomPublishCodec(phone, encrypted: false, onMesh: true, policy: ["vp9:hw", "h264:hw"]), "h264")
        // A codec this device can't encode, or a name nobody knows, is passed over, and VP8 is where any list ends.
        XCTAssertEqual(CallCodecs.roomPublishCodec(phone, encrypted: false, onMesh: true, policy: ["av1", "opus"]), "vp8")
        // An empty list is no policy.
        XCTAssertEqual(CallCodecs.roomPublishCodec(phone, encrypted: false, onMesh: true, policy: []), "h264")
    }

    func testThePolicysBackupIsH264WhereItAsksForItAndTheCodecIsAnother() {
        XCTAssertEqual(CallCodecs.roomBackupCodec("vp9", encrypted: false, policy: "h264"), "h264")
        XCTAssertEqual(CallCodecs.roomBackupCodec("h264", encrypted: false, policy: "h264"), "vp8")
        XCTAssertEqual(CallCodecs.roomBackupCodec("h265", encrypted: false, policy: "vp8"), "vp8")
    }

    func testTheJoinNamesWhatThisDeviceEncodesAndDecodesInHardware() {
        XCTAssertEqual(CallCodecs.hardwareEncoders(phone), ["h264", "h265"])
        XCTAssertEqual(CallCodecs.hardwareDecoders(phone), ["h264", "h265", "vp8", "vp9", "av1"])
    }

    func testTheMeshIsTheCloudsRtcNameAndTheNamesUnderIt() {
        XCTAssertTrue(CallCodecs.onMesh("wss://rtc.wordplus.cloud"))
        XCTAssertTrue(CallCodecs.onMesh("wss://n-5c03a.de.rtc.wordplus.cloud/rtc"))
        XCTAssertFalse(CallCodecs.onMesh("wss://video-cloud.better-messages.com"))
        XCTAssertFalse(CallCodecs.onMesh("ws://127.0.0.1:17431"))
        XCTAssertFalse(CallCodecs.onMesh("not a url"))
    }
}
