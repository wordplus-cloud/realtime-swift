#if canImport(UIKit)
import UIKit
import XCTest
@testable import WordPlusRealtimeUI

/// A group call's corner window: whom it shows, as the web's pipFocus chooses (realtime-ui inc/calls/pip-focus.ts), and
/// when the dock offers it, as its useGroupPip. The system's window itself takes a real device: on a simulator the tests
/// stop at what is handed to it. Run on a simulator, as PiecesTests.
@MainActor
final class GroupCornerTests: XCTestCase {
    private typealias Person = CallsPipFocus.Person

    private let me = Person( identity: "me", isLocal: true, camera: true )
    private let ann = Person( identity: "ann", camera: true )
    private let ben = Person( identity: "ben" )

    func testTheSpotlightAndThePinsComeFirst() {
        let sharing = Person( identity: "cara", screen: true )
        XCTAssertEqual( CallsPipFocus.pick( [ me, ann, ben, sharing ], first: [ "ben" ], last: "ann" ), "ben" )
        // This user's own tile, where they are the one in the spotlight.
        XCTAssertEqual( CallsPipFocus.pick( [ me, ann ], first: [ "me" ], last: nil ), "me" )
        // Of several, the loudest while they speak, then who spoke last, then the first.
        let talking = Person( identity: "ann", camera: true, speaking: true, level: 0.2 )
        let louder = Person( identity: "ben", speaking: true, level: 0.6 )
        XCTAssertEqual( CallsPipFocus.pick( [ me, talking, louder ], first: [ "ann", "ben" ], last: nil ), "ben" )
        XCTAssertEqual( CallsPipFocus.pick( [ me, ann, ben ], first: [ "ann", "ben" ], last: "ben" ), "ben" )
        XCTAssertEqual( CallsPipFocus.pick( [ me, ann, ben ], first: [ "ann", "ben" ], last: nil ), "ann" )
        // Someone who left is not kept ahead.
        XCTAssertEqual( CallsPipFocus.pick( [ me, ann ], first: [ "gone" ], last: nil ), "ann" )
    }

    func testAScreenThenWhoSpeaksThenWhoSpokeLast() {
        let sharing = Person( identity: "cara", screen: true )
        let talking = Person( identity: "ben", speaking: true, level: 0.4 )
        XCTAssertEqual( CallsPipFocus.pick( [ me, talking, sharing ], first: [], last: nil ), "cara" )
        XCTAssertEqual( CallsPipFocus.pick( [ me, ann, talking ], first: [], last: nil ), "ben" )
        XCTAssertEqual( CallsPipFocus.pick( [ me, ann, ben ], first: [], last: "ben" ), "ben" )
        // Who spoke last and has gone is nobody, and a share of this user's own is not what the window is for.
        XCTAssertEqual( CallsPipFocus.pick( [ me, ben, ann ], first: [], last: "gone" ), "ann" )
        let ownShare = Person( identity: "me", isLocal: true, screen: true )
        XCTAssertEqual( CallsPipFocus.pick( [ ownShare, ben ], first: [], last: nil ), "ben" )
    }

    func testTheFirstWithAPictureTheFirstOtherThenTheUser() {
        XCTAssertEqual( CallsPipFocus.pick( [ me, ben, ann ], first: [], last: nil ), "ann" )
        XCTAssertEqual( CallsPipFocus.pick( [ me, ben ], first: [], last: nil ), "ben" )
        XCTAssertEqual( CallsPipFocus.pick( [ me ], first: [], last: nil ), "me" )
        XCTAssertNil( CallsPipFocus.pick( [], first: [], last: nil ) )
    }

    func testAVideoCallHasItAllThroughAnAudioCallOnlyForAScreen() {
        XCTAssertTrue( CallsPipFocus.offered( [ me, ben ], video: true ) )
        XCTAssertFalse( CallsPipFocus.offered( [], video: true ) )
        XCTAssertFalse( CallsPipFocus.offered( [ me, ben ], video: false ) )
        XCTAssertTrue( CallsPipFocus.offered( [ me, Person( identity: "cara", screen: true ) ], video: false ) )
        // This user's own share would show them what they are sharing.
        XCTAssertFalse( CallsPipFocus.offered( [ Person( identity: "me", isLocal: true, screen: true ), ben ], video: false ) )
    }

    private func screen( video: Bool ) -> CallsScreen {
        let screen = CallsScreen()
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect( x: 0, y: 0, width: 390, height: 844 )
        screen.show( name: "Daily meeting", avatar: "", video: video )
        let state = CallScreenPreview.state( video ? .group : .groupVoice )
        screen.apply( state: state )
        screen.setRoster( CallScreenPreview.people() )
        screen.apply( state: state )
        screen.view.layoutIfNeeded()
        return screen
    }

    private func dock( _ screen: CallsScreen ) -> [ String ] {
        func find( _ view: UIView ) -> UIStackView? {
            if let stack = view as? UIStackView, stack.arrangedSubviews.contains( where: { $0.accessibilityLabel == "Exit Chat" } ) { return stack }
            return view.subviews.lazy.compactMap( find ).first
        }
        return find( screen.view )?.arrangedSubviews.filter { !$0.isHidden }.map { $0.accessibilityLabel ?? "?" } ?? []
    }

    func testTheDockAndTheWindowFollowTheChoice() throws {
        defer { CallsPip.shared.detach() }
        let screen = screen( video: true )
        // The one speaking, by name, and their face: the preview's people send no picture.
        XCTAssertEqual( CallsPip.shared.who, CallsPip.Who( name: "Ann", avatar: "" ) )
        XCTAssertTrue( CallsPip.shared.hasContent )

        screen.togglePinForMe( "ben" )
        XCTAssertEqual( CallsPip.shared.who?.name, "Ben" )
        screen.togglePinForMe( "ben" )

        if CallsPip.isSupported {
            XCTAssertTrue( dock( screen ).contains( "Picture In Picture" ), "\( dock( screen ) )" )
        }

        // Nobody is left, and the window goes with them.
        screen.setRoster( [] )
        XCTAssertNil( CallsPip.shared.who )
        XCTAssertFalse( CallsPip.shared.hasContent )
    }

    func testAnAudioCallHasNoWindowWithNoScreen() {
        defer { CallsPip.shared.detach() }
        let screen = screen( video: false )
        XCTAssertNil( CallsPip.shared.who )
        XCTAssertFalse( CallsPip.shared.hasContent )
        XCTAssertFalse( dock( screen ).contains( "Picture In Picture" ), "\( dock( screen ) )" )
    }

    func testTheSameWindowForACallBetweenTwo() {
        // No one named over a picture of the other side: as it was.
        defer { CallsPip.shared.detach() }
        CallsPip.shared.showRoom( nil )
        XCTAssertNil( CallsPip.shared.who )
        XCTAssertFalse( CallsPip.shared.hasContent )
    }
}
#endif
