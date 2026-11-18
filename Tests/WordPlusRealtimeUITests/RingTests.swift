import XCTest
@testable import WordPlusRealtimeUI

/// A ring's end takes its screen away, but for the answer this screen itself is making: the ring says it is over as it
/// is answered (@wordplus/realtime-client a738a57), and the call's screen comes with the answer. Run on a simulator:
/// `xcodebuild test -scheme WordPlusRealtime-Package -destination 'platform=iOS Simulator,name=iPhone 16'
/// -only-testing:WordPlusRealtimeUITests/RingTests`.
@MainActor
final class RingTests: XCTestCase {
    func testTheAnswerThisScreenIsMakingKeepsIt() {
        XCTAssertFalse(CallScreen.ringGoes(reason: "answered", answeringHere: true))
    }

    func testAnyOtherEndTakesItAway() {
        // The app answered through the API, or the system's screen did: the call's screen is shown as the answer comes.
        XCTAssertTrue(CallScreen.ringGoes(reason: "answered", answeringHere: false))
        for reason in ["declined", "busy", "cancelled", "answered_elsewhere"] {
            XCTAssertTrue(CallScreen.ringGoes(reason: reason, answeringHere: false))
            XCTAssertTrue(CallScreen.ringGoes(reason: reason, answeringHere: true))
        }
    }
}
