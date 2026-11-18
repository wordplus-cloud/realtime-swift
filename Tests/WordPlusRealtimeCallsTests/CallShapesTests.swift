import XCTest
@testable import WordPlusRealtimeCalls

/// A direct call's camera shape by the path's ceiling (CallShapes.camera), as the web's calls/peer.ts: full size takes
/// the ceiling it is given, 10 Mbps on a direct path and 4 through a relay, and the picture-size steps stay under both.
final class CallShapesTests: XCTestCase {
    private let direct = CallShapes.cameraDirectMaxBitrate
    private let relay = CallShapes.cameraRelayMaxBitrate

    func testTheCeilingsAreTheWebs() {
        XCTAssertEqual(direct, 10_000_000)
        XCTAssertEqual(relay, 4_000_000)
    }

    func testFullSizeTakesThePathsCeiling() {
        for wanted in [nil, 1080, 1440, 2160] as [Int?] {
            XCTAssertEqual(CallShapes.camera(wanted: wanted, captureHeight: 1080, ceiling: direct).maxBitrate, direct)
            XCTAssertEqual(CallShapes.camera(wanted: wanted, captureHeight: 1080, ceiling: relay).maxBitrate, relay)
        }

        let full = CallShapes.camera(wanted: 2160, captureHeight: 1080, ceiling: direct)
        XCTAssertTrue(full.active)
        XCTAssertEqual(full.scale, 1)
        XCTAssertNil(full.maxFramerate)
    }

    func testTheStepsStayUnderBothCeilings() {
        for ceiling in [direct, relay] {
            let shown = CallShapes.camera(wanted: 720, captureHeight: 1080, ceiling: ceiling)
            XCTAssertEqual(shown.maxBitrate, 2_000_000)
            XCTAssertEqual(shown.maxFramerate, 30)
            XCTAssertEqual(shown.scale, 1.5)

            XCTAssertEqual(CallShapes.camera(wanted: 540, captureHeight: 1080, ceiling: ceiling).maxBitrate, 1_000_000)
            XCTAssertEqual(CallShapes.camera(wanted: 180, captureHeight: 1080, ceiling: ceiling).maxBitrate, 200_000)
        }
    }

    func testAHiddenCameraIsPausedAtThePathsCeiling() {
        let hidden = CallShapes.camera(wanted: 0, captureHeight: 1080, ceiling: direct)
        XCTAssertFalse(hidden.active)
        XCTAssertEqual(hidden.maxBitrate, direct)
    }
}
