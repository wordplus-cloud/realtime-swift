import LiveKit
import XCTest
@testable import WordPlusRealtimeCalls

/// What a group call sends by the media server's settings (GroupShapes): the schema's defaults, the browsers' values,
/// where the server says nothing, and the server's value where it does.
final class GroupSettingsTests: XCTestCase {
    private func settings(_ json: String) -> MeshSettings {
        MeshSettings.parse(Data(json.utf8))!
    }

    func testTheMicrophoneIsTheBrowsersAndNeverRedIntoAnEncryptedRoom() {
        let open = GroupShapes.microphone(encrypted: false, settings: .none)
        XCTAssertEqual(open.encoding?.maxBitrate, 64000)
        XCTAssertTrue(open.red)
        XCTAssertTrue(open.dtx)
        XCTAssertTrue(open.resend, "its node may ask it again for what its upload lost")
        XCTAssertFalse(GroupShapes.microphone(encrypted: true, settings: .none).red)
        XCTAssertTrue(GroupShapes.microphone(encrypted: true, settings: .none).resend)

        let set = settings(#"{"rev":3,"set":{"mic.kbps":32,"mic.red":false,"mic.dtx":false}}"#)
        let mic = GroupShapes.microphone(encrypted: false, settings: set)
        XCTAssertEqual(mic.encoding?.maxBitrate, 32000)
        XCTAssertFalse(mic.red)
        XCTAssertFalse(mic.dtx)
    }

    func testTheCameraIsCapturedAt1080AndSentWithTheLadderAt30Frames() {
        let capture = GroupShapes.cameraCapture(settings: .none)
        XCTAssertEqual(capture.dimensions.height, 1080)
        XCTAssertEqual(capture.fps, 30)

        let publish = GroupShapes.camera(codec: .h264, backup: .vp8, dimensions: capture.dimensions, settings: .none)
        XCTAssertEqual(publish.encoding?.maxBitrate, 3_500_000)
        XCTAssertEqual(publish.simulcastLayers.map { Int($0.dimensions.height) }, [270, 540])
        XCTAssertEqual(publish.simulcastLayers.map { $0.encoding.maxFps }, [30, 30])
        XCTAssertEqual(publish.simulcastLayers.map { $0.encoding.maxBitrate }, [400_000, 1_200_000])
        XCTAssertEqual(publish.preferredBackupCodec, .vp8)

        let vp8 = GroupShapes.camera(codec: .vp8, backup: nil, dimensions: capture.dimensions, settings: .none)
        XCTAssertEqual(vp8.encoding?.maxBitrate, 4_000_000)
    }

    func testTheServersNumbersShapeTheCamera() {
        let set = settings(#"{"rev":2,"set":{"camera.captureHeight":720,"camera.captureFps":24,"camera.fps":24,"camera.topKbps.h264.720":1500,"camera.ladder.720":[{"h":360,"kbps":500,"fps":24}],"camera.degradation":"maintain-resolution"}}"#)
        let capture = GroupShapes.cameraCapture(settings: set)
        XCTAssertEqual(capture.dimensions.height, 720)
        XCTAssertEqual(capture.fps, 24)

        let publish = GroupShapes.camera(codec: .h264, backup: nil, dimensions: capture.dimensions, settings: set)
        XCTAssertEqual(publish.encoding?.maxBitrate, 1_500_000)
        XCTAssertEqual(publish.encoding?.maxFps, 24)
        XCTAssertEqual(publish.simulcastLayers.map { Int($0.dimensions.width) }, [640])
        XCTAssertEqual(publish.degradationPreference, .maintainResolution)
    }

    func testASoftwareCameraIsHeldTo720AndHardwareTo1080() {
        XCTAssertEqual(GroupShapes.cameraCap(hardware: false, lines: 1080, settings: .none), MeshCaps(height: 720))
        XCTAssertTrue(GroupShapes.cameraCap(hardware: true, lines: 1080, settings: .none).isEmpty)
        XCTAssertTrue(GroupShapes.cameraCap(hardware: false, lines: 720, settings: .none).isEmpty)
    }

    func testTheCodecRulesComeBeforeTheCodecs() {
        #if os(iOS)
        let os = "ios"
        #else
        let os = "mac"
        #endif
        let set = settings(#"{"rev":4,"set":{"camera.codecRules":[{"browser":"chrome","camera":["vp9"]},{"os":"windows","camera":["av1"]},{"os":"\#(os)","camera":["h265:hw","vp8"]}],"camera.codecs":["vp8"]}}"#)
        XCTAssertEqual(GroupShapes.cameraCodecs(settings: set), ["h265:hw", "vp8"])
        XCTAssertEqual(GroupShapes.cameraCodecs(settings: settings(#"{"rev":4,"set":{"camera.codecs":["vp8"]}}"#)), ["vp8"])
        XCTAssertEqual(GroupShapes.cameraCodecs(settings: .none), ["h264:hw", "vp8"])
    }

    func testAnSvcCameraTakesTheSettingsMode() {
        let dimensions = Dimensions(width: 1920, height: 1080)
        XCTAssertEqual(GroupShapes.camera(codec: .vp9, backup: .vp8, dimensions: dimensions, settings: .none).scalabilityMode, .L3T3_KEY)
        XCTAssertNil(GroupShapes.camera(codec: .h264, backup: .vp8, dimensions: dimensions, settings: .none).scalabilityMode,
                     "simulcast for any other codec")
        let set = settings(#"{"rev":2,"set":{"camera.svcMode":"L2T3_KEY"}}"#)
        XCTAssertEqual(GroupShapes.camera(codec: .av1, backup: nil, dimensions: dimensions, settings: set).scalabilityMode, .L2T3_KEY)
        XCTAssertEqual(GroupShapes.camera(codec: .vp9, backup: nil, dimensions: Dimensions(width: 960, height: 540), settings: set).scalabilityMode,
                       .L2T3_KEY)
    }

    func testARevisionWithApplyNowRepublishesACameraWhosePublishSettingsChanged() {
        let before = settings(#"{"rev":1,"set":{"camera.fps":30,"mic.kbps":48}}"#)
        let fps = settings(#"{"rev":2,"applyNow":true,"set":{"camera.fps":24,"mic.kbps":48}}"#)
        let mic = settings(#"{"rev":3,"applyNow":true,"set":{"camera.fps":30,"mic.kbps":32}}"#)
        XCTAssertNotEqual(GroupShapes.cameraPrint(before), GroupShapes.cameraPrint(fps), "a camera key changed: out again")
        XCTAssertEqual(GroupShapes.cameraPrint(before), GroupShapes.cameraPrint(mic), "the microphone's: the camera stays")
        XCTAssertTrue(GroupShapes.touchesPublish(["camera.fps"]))
        XCTAssertFalse(GroupShapes.touchesPublish(["camera.capHeight", "tune.failsafeS"]), "live keys need no publish")
        // each device at its own moment of the minute
        XCTAssertLessThan(MeshSettings.republishDelay(identity: "user_7"), 60)
    }

    func testTheJoinNamesThisPackageAndTakesTheSettingsTimeouts() {
        let caps = CallCodecCaps(families: [:], canSwitch: false, engine: nil)
        let defaults = GroupShapes.connectOptions(settings: .none, iceServers: [], caps: caps)
        XCTAssertEqual(defaults.meshApp, MeshApp(name: "realtime-swift", version: RealtimeCalls.version))
        XCTAssertEqual(defaults.socketConnectTimeoutInterval, 20)
        XCTAssertEqual(defaults.primaryTransportConnectTimeout, 20)
        XCTAssertEqual(defaults.meshJoinBudget, 300)
        XCTAssertEqual(defaults.iceTransportPolicy, .all)
        XCTAssertEqual(defaults.meshReconnectDelays, [0, 0.3, 1.2, 2.7, 4.8, 7, 7, 7, 7, 7])

        let set = settings(#"{"rev":5,"set":{"connect.signalTimeoutMs":10000,"connect.pcTimeoutMs":15000,"connect.joinBudgetMs":60000,"ice.transportPolicy":"relay","reconnect.delaysMs":[100,1000]}}"#)
        let options = GroupShapes.connectOptions(settings: set, iceServers: [], caps: caps)
        XCTAssertEqual(options.socketConnectTimeoutInterval, 10)
        XCTAssertEqual(options.primaryTransportConnectTimeout, 15)
        XCTAssertEqual(options.meshJoinBudget, 60)
        XCTAssertEqual(options.iceTransportPolicy, .relay)
        XCTAssertEqual(options.meshReconnectDelays, [0.1, 1])
    }
}
