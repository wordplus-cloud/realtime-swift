#if canImport(UIKit)
import UIKit
import XCTest
@testable import WordPlusRealtimeUI

/// Spotlight for Everyone and Pin for Me on the call screens, as the web's calls/spotlight.tsx and
/// moderation-panels.tsx have them: who is in the spotlight and who is on the main tiles, the pins that wait for a
/// spotlight to end, the label on a spotlighted tile, and a moderator's rows in the person menu and Host Controls. Run on
/// a simulator: `xcodebuild test -scheme WordPlusRealtime-Package -destination 'platform=iOS Simulator,name=iPhone 16'
/// -only-testing:WordPlusRealtimeUITests/SpotlightTests`.
@MainActor
final class SpotlightTests: XCTestCase {
    private func person( _ id: Int, local: Bool = false, pinned: Bool = false, admin: Bool = false, publish: Bool = true ) -> CallsRoomParticipant {
        CallsRoomParticipant(
            identity: "user_\( id )", name: local ? "Me" : "Person \( id )", avatar: "", isLocal: local, video: nil, screen: nil,
            speaking: false, audioLevel: 0, muted: true, micMuted: false, handRaised: false, isPinned: pinned,
            canPublish: publish, canAdmin: admin, mode: "participant", lost: false
        )
    }

    override func tearDown() {
        let engine = CallsEngine.shared
        engine.canModerate = false
        engine.carriesSpotlight = false
        engine.isVideo = true
        super.tearDown()
    }

    // MARK: Who is in it, and the main tiles

    func testTheSpotlightInItsOrderAndAnOlderAppsPin() {
        let people = [ person( 1, local: true ), person( 2 ), person( 3, pinned: true ), person( 4 ) ]

        // The room's order, those in the call alone, once each; then anyone an older app pinned for everyone.
        XCTAssertEqual( CallsSpotlight.spotlit( people, spotlight: [ "user_4", "user_9", "user_2", "user_4" ] ), [ "user_4", "user_2", "user_3" ] )
        XCTAssertEqual( CallsSpotlight.spotlit( people, spotlight: [] ), [ "user_3" ] )
        XCTAssertEqual( CallsSpotlight.spotlit( [ person( 1 ) ], spotlight: [] ), [] )
        XCTAssertEqual( CallsSpotlight.most, 4 )
    }

    func testASpotlightComesFirstAndThePinsWaitForIt() {
        let people = [ person( 1, local: true ), person( 2 ), person( 3 ), person( 4, admin: true ), person( 5, publish: false ) ]

        // The spotlight alone, the pins and a broadcast's speakers waiting.
        XCTAssertEqual( CallsSpotlight.main( people, spotlight: [ "user_3" ], pinned: [ "user_2" ], broadcast: true ), [ "user_3" ] )
        // Nobody in it: this user's pins in the order pinned, someone gone no longer one.
        XCTAssertEqual( CallsSpotlight.main( people, spotlight: [], pinned: [ "user_3", "user_7", "user_2" ], broadcast: false ), [ "user_3", "user_2" ] )
        // In broadcast mode the speakers after the pins, a viewer not.
        XCTAssertEqual( CallsSpotlight.main( people, spotlight: [], pinned: [ "user_3" ], broadcast: true ), [ "user_3", "user_1", "user_2", "user_4" ] )
        XCTAssertEqual( CallsSpotlight.main( people, spotlight: [], pinned: [], broadcast: false ), [] )
        // A spotlight of someone who left is nobody's: the pins show.
        XCTAssertEqual( CallsSpotlight.main( people, spotlight: [ "user_9" ], pinned: [ "user_2" ], broadcast: false ), [ "user_2" ] )
    }

    func testPinsOnAndOffAndForThoseStillThere() {
        XCTAssertEqual( CallsSpotlight.toggled( [], "user_2" ), [ "user_2" ] )
        XCTAssertEqual( CallsSpotlight.toggled( [ "user_2", "user_3" ], "user_2" ), [ "user_3" ] )
        XCTAssertEqual( CallsSpotlight.toggled( [ "user_3" ], "user_2" ), [ "user_3", "user_2" ] )
        XCTAssertEqual( CallsSpotlight.kept( [ "user_2", "user_3" ], people: [ person( 1, local: true ), person( 3 ) ] ), [ "user_3" ] )
    }

    // MARK: On the screen

    private func screen( _ people: [ CallsRoomParticipant ], spotlight: [ String ], video: Bool = true ) -> CallsScreen {
        let screen = CallsScreen()
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect( x: 0, y: 0, width: 390, height: 844 )
        screen.show( name: "Group", avatar: "", video: video )
        apply( screen, spotlight: spotlight, video: video )
        screen.setRoster( people )
        screen.view.layoutIfNeeded()
        return screen
    }

    private func apply( _ screen: CallsScreen, spotlight: [ String ], video: Bool = true ) {
        screen.apply( state: [ "phase": "in_progress", "type": video ? "video" : "audio", "group": true, "local": [ "muted": true, "camera": false ], "spotlight": spotlight ] )
        screen.view.layoutIfNeeded()
    }

    private func grid( _ screen: CallsScreen ) -> CallsGrid {
        find( CallsGrid.self, in: screen.view )!
    }

    private func find<T: UIView>( _ type: T.Type, in view: UIView ) -> T? {
        if let found = view as? T, !found.isHidden { return found }
        return view.subviews.lazy.compactMap { self.find( type, in: $0 ) }.first
    }

    private func texts( _ view: UIView ) -> [ String ] {
        guard !view.isHidden else { return [] }
        return ( ( view as? UILabel )?.text.map { [ $0 ] } ?? [] ) + view.subviews.flatMap { texts( $0 ) }
    }

    /// The people on the main tiles: their tiles stand outside the scroller, in the grid itself.
    private func main( _ screen: CallsScreen ) -> [ String ] {
        let grid = grid( screen )
        return grid.subviews.filter { !( $0 is UIScrollView ) }.flatMap { texts( $0 ) }.filter { $0.hasPrefix( "Person" ) || $0 == "Me" }
    }

    /// Who wears the Spotlight label, by the name beside it.
    private func labeled( _ screen: CallsScreen ) -> [ String ] {
        func tiles( _ view: UIView ) -> [ UIView ] {
            let words = view.subviews.compactMap { ( $0 as? UILabel )?.text }
            if words.contains( where: { $0.hasPrefix( "Person" ) || $0 == "Me" } ) { return [ view ] }
            return view.subviews.flatMap { tiles( $0 ) }
        }

        return tiles( grid( screen ) ).filter { texts( $0 ).contains( "Spotlight" ) }.compactMap { tile in
            tile.subviews.compactMap { ( $0 as? UILabel )?.text }.first { $0.hasPrefix( "Person" ) || $0 == "Me" }
        }
    }

    func testAJoinWithASpotlightOnShowsItLabeled() {
        let people = [ person( 1, local: true ), person( 2 ), person( 3 ), person( 4 ) ]
        let screen = screen( people, spotlight: [ "user_3", "user_2" ] )

        XCTAssertEqual( screen.spotlight, [ "user_3", "user_2" ] )
        XCTAssertEqual( main( screen ), [ "Person 3", "Person 2" ] )
        XCTAssertEqual( labeled( screen ).sorted(), [ "Person 2", "Person 3" ] )

        // Taken out for everyone: the usual tiles, no label.
        apply( screen, spotlight: [] )
        XCTAssertEqual( main( screen ), [] )
        XCTAssertEqual( labeled( screen ), [] )
    }

    func testPinForMeWaitsWhileASpotlightIsOn() {
        let people = [ person( 1, local: true ), person( 2 ), person( 3 ) ]
        let screen = screen( people, spotlight: [ "user_2" ] )

        screen.togglePinForMe( "user_3" )
        screen.view.layoutIfNeeded()
        XCTAssertEqual( screen.pinnedForMe, [ "user_3" ] )
        XCTAssertEqual( main( screen ), [ "Person 2" ] )

        // The spotlight ends: the pin shows, and the label goes.
        apply( screen, spotlight: [] )
        XCTAssertEqual( main( screen ), [ "Person 3" ] )
        XCTAssertEqual( labeled( screen ), [] )

        // Someone who leaves is unpinned.
        screen.setRoster( [ person( 1, local: true ), person( 2 ) ] )
        XCTAssertEqual( screen.pinnedForMe, [] )
    }

    func testAnAudioCallHasNoMainTiles() {
        let screen = screen( [ person( 1, local: true ), person( 2 ) ], spotlight: [ "user_2" ], video: false )

        XCTAssertEqual( screen.spotlight, [] )
        XCTAssertEqual( labeled( screen ), [] )
    }

    // MARK: A moderator's rows

    private func personMenu( _ screen: CallsScreen, _ who: CallsRoomParticipant ) -> [ String ] {
        CallsModeration.showFor( from: screen, person: who )
        defer { screen.closePopover() }
        // The newest: one closed a moment ago fades out over the call before it goes.
        return screen.view.subviews.compactMap { $0 as? CallsPopover }.last.map { texts( $0 ) } ?? []
    }

    func testAModeratorSpotlightsInPlaceOfThePin() {
        let engine = CallsEngine.shared
        engine.canModerate = true
        engine.carriesSpotlight = true

        let people = [ person( 1, local: true, admin: true ), person( 2 ), person( 3 ) ]
        let screen = screen( people, spotlight: [ "user_3" ] )

        let other = personMenu( screen, people[ 1 ] )
        XCTAssertTrue( other.contains( "Spotlight for Everyone" ) )
        XCTAssertTrue( other.contains( "Their tile is the main one for everyone in the call." ) )
        XCTAssertTrue( other.contains( "Pin for Me" ) )
        XCTAssertTrue( other.contains( "On your screen once nobody is in the spotlight." ) )
        XCTAssertFalse( other.contains( "Pin Participant" ) )

        let spotlit = personMenu( screen, people[ 2 ] )
        XCTAssertTrue( spotlit.contains( "Remove Spotlight" ) )
        XCTAssertFalse( spotlit.contains( "Spotlight for Everyone" ) )
    }

    func testAFifthIsRefusedAsTheWebRefusesIt() {
        let engine = CallsEngine.shared
        engine.canModerate = true
        engine.carriesSpotlight = true

        let people = [ person( 1, local: true, admin: true ) ] + ( 2 ... 6 ).map { person( $0 ) }
        let screen = screen( people, spotlight: [ "user_2", "user_3", "user_4", "user_5" ] )

        let fifth = personMenu( screen, people[ 5 ] )
        XCTAssertTrue( fifth.contains( "Spotlight for Everyone" ) )
        XCTAssertTrue( fifth.contains( "Up to four people can be in the spotlight." ) )
    }

    func testACallWithoutASpotlightKeepsThePin() {
        let engine = CallsEngine.shared
        engine.canModerate = true
        engine.carriesSpotlight = false

        let people = [ person( 1, local: true, admin: true ), person( 2 ) ]
        let screen = screen( people, spotlight: [] )

        let menu = personMenu( screen, people[ 1 ] )
        XCTAssertTrue( menu.contains( "Pin Participant" ) )
        XCTAssertTrue( menu.contains( "Pin for Me" ) )
        XCTAssertFalse( menu.contains( "Spotlight for Everyone" ) )
    }
}
#endif
