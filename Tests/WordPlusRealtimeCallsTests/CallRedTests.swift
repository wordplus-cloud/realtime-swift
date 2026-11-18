import XCTest
@testable import WordPlusRealtimeCalls

/// Redundant audio on a direct call's microphone (CallCodecs.redOrder), as
/// the web's codecs.ts redOrder: RED first, then Opus, then the rest as they
/// were, and nothing changed where the build has no RED.
final class CallRedTests: XCTestCase {
    func testRedLeadsThenOpusThenTheRestAsTheyWere() {
        let codecs = ["audio/opus", "audio/G722", "audio/red", "audio/PCMU", "audio/telephone-event"]

        XCTAssertEqual(CallCodecs.redOrder(codecs)?.map { codecs[$0] }, ["audio/red", "audio/opus", "audio/G722", "audio/PCMU", "audio/telephone-event"])
    }

    func testABuildWithoutRedIsLeftAsItIs() {
        XCTAssertNil(CallCodecs.redOrder(["audio/opus", "audio/PCMU"]))
    }

    func testTheNameIsReadWhateverItsCase() {
        XCTAssertEqual(CallCodecs.redOrder(["audio/OPUS", "audio/RED"]), [1, 0])
    }
}
