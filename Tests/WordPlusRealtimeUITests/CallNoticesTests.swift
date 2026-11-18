#if canImport(UIKit)
import UIKit
import XCTest
import WordPlusRealtimeCalls
@testable import WordPlusRealtimeUI

/// What the SDK's call screen says of a group call that goes on, and what its dock leaves out. Run on a simulator, as
/// PiecesTests.
@MainActor
final class CallNoticesTests: XCTestCase {
    func testTheCallsWordsForWhatCouldNotGoOut() {
        XCTAssertEqual( CallScreen.failure( GroupCallFailure( code: "publish_failed", source: "camera" ) ), "Your camera could not be sent." )
        XCTAssertEqual( CallScreen.failure( GroupCallFailure( code: "publish_failed", source: "microphone" ) ), "Your microphone could not be sent." )
        XCTAssertEqual( CallScreen.failure( GroupCallFailure( code: "encryption_failed", message: "no key" ) ), "Part of this call could not be encrypted." )
        XCTAssertEqual( CallScreen.failure( GroupCallFailure( code: "something_new" ) ), "Something went wrong in this call." )
    }

    func testAnSDKListenerHasNoHandToRaise() {
        // The call's own hands are a host's and its site's (`carriesRoomRules`): the SDK's group call has no way to send
        // one, so a listener's dock has no button that would do nothing. An app adds a control of its own (docs).
        let screen = CallsScreen()
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect( x: 0, y: 0, width: 390, height: 844 )
        var state = CallScreenPreview.state( .group )
        state[ "phase" ] = "in_progress"
        screen.apply( state: state )
        let listener = CallsRoomParticipant(
            identity: "me", name: "You", avatar: "", isLocal: true, video: nil, screen: nil,
            speaking: false, audioLevel: 0, muted: true, micMuted: false, handRaised: false,
            isPinned: false, canPublish: false, canAdmin: false, mode: "viewer", lost: false
        )
        screen.setRoster( [ listener ] )
        screen.apply( state: state )

        func labels( _ view: UIView ) -> [ String ] {
            ( view.isHidden ? [] : [ view.accessibilityLabel ].compactMap { $0 } ) + ( view.isHidden ? [] : view.subviews.flatMap( labels ) )
        }
        XCTAssertFalse( labels( screen.view ).contains( "Raise Hand" ) )
    }
}
#endif
