import UIKit
import XCTest
@testable import WordPlusRealtimeUI

/// The presence parts (OnlineList, PersonRow, RowAction, OnlineCount, Avatar, PresenceDot, TypingDots and
/// ActivityIndicator), as realtime-ui's draw them, given plain values and no room. Run on a simulator, as PiecesTests.
@MainActor
final class PresenceTests: XCTestCase {
    override func tearDown() {
        CallScreen.shared.configure( .init() )
        super.tearDown()
    }

    /// The words on screen: every label's text, under no hidden view.
    private func texts( _ view: UIView ) -> [ String ] {
        guard !view.isHidden else { return [] }

        return [ ( view as? UILabel )?.text ].compactMap { $0 } + view.subviews.flatMap( texts )
    }

    /// A tap's actions, run as UIKit would: the tests have no application to send them through.
    private func press( _ control: UIControl ) {
        for target in control.allTargets {
            for action in control.actions( forTarget: target, forControlEvent: .touchUpInside ) ?? [] {
                _ = ( target as NSObject ).perform( Selector( action ) )
            }
        }
    }

    /// `view` laid out at `width`, in a window that writes in `direction`.
    private func laidOut( _ view: UIView, width: CGFloat = 320, height: CGFloat? = nil, direction: UITraitEnvironmentLayoutDirection = .leftToRight ) -> UIWindow {
        let parent = UIViewController()
        let child = UIViewController()
        parent.addChild( child )
        parent.view.addSubview( child.view )
        child.didMove( toParent: parent )
        parent.setOverrideTraitCollection( UITraitCollection( layoutDirection: direction == .rightToLeft ? .rightToLeft : .leftToRight ), forChild: child )

        let window = UIWindow( frame: CGRect( x: 0, y: 0, width: width, height: height ?? 600 ) )
        window.rootViewController = parent
        window.isHidden = false
        child.view.frame = window.bounds

        view.translatesAutoresizingMaskIntoConstraints = false
        child.view.addSubview( view )
        var pins = [
            view.leadingAnchor.constraint( equalTo: child.view.leadingAnchor ),
            view.trailingAnchor.constraint( equalTo: child.view.trailingAnchor ),
            view.topAnchor.constraint( equalTo: child.view.topAnchor ),
        ]
        if let height { pins.append( view.heightAnchor.constraint( equalToConstant: height ) ) }
        NSLayoutConstraint.activate( pins )
        window.layoutIfNeeded()
        return window
    }

    // MARK: OnlineCount

    func testACountDrawsNothingAtNoneAndNinetyNinePlusPastNinetyNine() {
        let count = OnlineCount()
        XCTAssertTrue( count.isHidden, "nothing at 0" )
        XCTAssertNil( OnlineCount.said( 0 ) )
        XCTAssertNil( OnlineCount.said( -1 ) )

        count.count = 1
        XCTAssertFalse( count.isHidden )
        XCTAssertEqual( texts( count ), [ "1" ] )
        XCTAssertEqual( count.accessibilityLabel, "1" )

        count.count = 99
        XCTAssertEqual( texts( count ), [ "99" ] )
        count.count = 100
        XCTAssertEqual( texts( count ), [ "99+" ] )

        count.count = 0
        XCTAssertTrue( count.isHidden, "and goes again" )
    }

    // MARK: OnlineList

    func testAListSaysItsTitleAndCountAndItsEmptyLineWithNobody() {
        let list = OnlineList()
        XCTAssertEqual( list.titleShown, "ONLINE (0)" )
        XCTAssertEqual( list.emptyShown, "No users online" )
        XCTAssertNil( list.closeShown, "no close button where the list can't be closed" )

        list.title = "In the shop"
        list.empty = "Nobody is in the shop"
        XCTAssertEqual( list.titleShown, "IN THE SHOP (0)" )
        XCTAssertEqual( list.emptyShown, "Nobody is in the shop" )

        list.rows = [ PersonRow( avatar: Avatar( name: "Ann", size: 32 ), name: "Ann" ) ]
        list.count = 1
        XCTAssertEqual( list.titleShown, "IN THE SHOP (1)" )
        XCTAssertNil( list.emptyShown, "the empty line goes with someone in it" )
        XCTAssertTrue( texts( list ).contains( "Ann" ) )

        list.rows = []
        list.count = 0
        XCTAssertFalse( texts( list ).contains( "Ann" ), "a row gone is gone" )
    }

    func testAListClosesWhereItIsToldHow() {
        var closed = 0
        let list = OnlineList( onClose: { closed += 1 } )
        let close = list.closeShown
        XCTAssertNotNil( close )
        XCTAssertEqual( close?.accessibilityLabel, "Close" )
        press( close! )
        XCTAssertEqual( closed, 1 )

        list.onClose = nil
        XCTAssertNil( list.closeShown )
    }

    func testAListScrollsWhatDoesNotFit() {
        let rows = ( 0..<40 ).map { PersonRow( avatar: Avatar( name: "P\( $0 )", size: 32 ), name: "P\( $0 )" ) }
        let list = OnlineList( count: 40, rows: rows )
        let window = laidOut( list, height: 200 )
        defer { window.isHidden = true }

        func scroll( _ view: UIView ) -> UIScrollView? {
            if let found = view as? UIScrollView { return found }
            return view.subviews.lazy.compactMap( scroll ).first
        }
        let found = scroll( list )
        XCTAssertNotNil( found )
        XCTAssertGreaterThan( found!.contentSize.height, found!.bounds.height )
        XCTAssertLessThanOrEqual( found!.contentSize.width, found!.bounds.width, "and never sideways" )
    }

    // MARK: PersonRow and RowAction

    func testARowDrawsTheFaceTheNameTheLineUnderItAndWhatMayBeDone() {
        var called = 0
        let action = RowAction( icon: RowAction.icons[ "phone" ]!, label: "Call Ann" ) { called += 1 }
        let row = PersonRow( avatar: Avatar( name: "Ann", size: 32, decorative: true ), name: "Ann", sub: "support", actions: [ action ] )
        XCTAssertEqual( texts( row ).filter { $0 == "Ann" || $0 == "support" }, [ "Ann", "support" ] )
        XCTAssertEqual( action.accessibilityLabel, "Call Ann" )
        XCTAssertTrue( action.accessibilityTraits.contains( .button ) )

        press( action )
        XCTAssertEqual( called, 1 )

        row.sub = nil
        XCTAssertNil( row.subShown, "no line under the name without one" )
        row.name = "Anna"
        XCTAssertTrue( texts( row ).contains( "Anna" ) )
    }

    func testARowActionTakesAFingerRoundItsSmallButton() {
        let action = RowAction( icon: CallScreen.CallControl.icons[ "phone" ]!, label: "Call" ) {}
        action.frame = CGRect( x: 0, y: 0, width: 28, height: 28 )
        XCTAssertTrue( action.point( inside: CGPoint( x: -7, y: 35 ), with: nil ) )
        XCTAssertFalse( action.point( inside: CGPoint( x: -9, y: 14 ), with: nil ) )
    }

    func testARowEndsWhereTheLineEndsInEitherDirection() {
        func frames( _ direction: UITraitEnvironmentLayoutDirection ) -> ( avatar: CGRect, action: CGRect ) {
            let avatar = Avatar( name: "Ann", size: 32 )
            let action = RowAction( icon: RowAction.icons[ "phone" ]!, label: "Call" ) {}
            let row = PersonRow( avatar: avatar, name: "Ann", actions: [ action ] )
            let window = laidOut( row, direction: direction )
            defer { window.isHidden = true }
            return ( avatar.convert( avatar.bounds, to: row ), action.convert( action.bounds, to: row ) )
        }

        let leftToRight = frames( .leftToRight )
        XCTAssertLessThan( leftToRight.avatar.maxX, leftToRight.action.minX )
        let rightToLeft = frames( .rightToLeft )
        XCTAssertGreaterThan( rightToLeft.avatar.minX, rightToLeft.action.maxX, "the face at the start of the line, on the right" )
    }

    // MARK: Avatar and PresenceDot

    func testAFaceHasItsLettersWithNoPictureAndWhereThePictureDoesNotLoad() {
        XCTAssertEqual( Avatar( name: "Ann Lee" ).lettersShown, "AL" )
        XCTAssertEqual( Avatar( name: "ann" ).lettersShown, "A" )
        XCTAssertEqual( Avatar().lettersShown, "?" )
        let own = AvatarLetters( text: "Z", background: .black, color: .white )
        XCTAssertEqual( Avatar( name: "Ann", letters: own ).lettersShown, "Z", "an app's own letters" )
        XCTAssertTrue( texts( Avatar( name: "Ann", picture: "https://example.invalid/none.png" ) ).contains( "A" ) )
    }

    func testAFaceWearsItsDotWhileThePersonIsNotOffline() {
        let avatar = Avatar( name: "Ann" )
        XCTAssertNil( avatar.dotShown, "no status, no dot" )

        avatar.presence = .online
        XCTAssertEqual( avatar.dotShown?.presence, .online )
        XCTAssertEqual( avatar.accessibilityLabel, "Ann, Online" )

        avatar.presence = .busy
        XCTAssertEqual( avatar.dotShown?.presence, .busy, "the same dot, in the new status" )
        XCTAssertEqual( avatar.accessibilityLabel, "Ann, Do not disturb" )

        avatar.presence = .offline
        XCTAssertNil( avatar.dotShown, "no dot for someone offline, where no dot says as much" )
        XCTAssertEqual( avatar.accessibilityLabel, "Ann" )

        avatar.showOffline = true
        XCTAssertEqual( avatar.dotShown?.presence, .offline, "unless asked" )
    }

    func testAFaceBesideItsNameSaysNothing() {
        let avatar = Avatar( name: "Ann", presence: .online, decorative: true )
        XCTAssertFalse( avatar.isAccessibilityElement )
        XCTAssertNil( avatar.accessibilityLabel )
        XCTAssertTrue( avatar.accessibilityElementsHidden )
    }

    func testTheDotSitsAtTheCornerTheLineEndsOn() {
        func dotRightOfCentre( _ direction: UITraitEnvironmentLayoutDirection ) -> Bool {
            let avatar = Avatar( name: "Ann", size: 40, presence: .online )
            let holder = UIView()
            holder.addSubview( avatar )
            NSLayoutConstraint.activate( [
                avatar.centerXAnchor.constraint( equalTo: holder.centerXAnchor ),
                avatar.topAnchor.constraint( equalTo: holder.topAnchor ),
                holder.heightAnchor.constraint( equalToConstant: 60 ),
            ] )
            let window = laidOut( holder, direction: direction )
            defer { window.isHidden = true }
            return avatar.dotShown!.frame.midX > avatar.bounds.midX
        }

        XCTAssertTrue( dotRightOfCentre( .leftToRight ) )
        XCTAssertFalse( dotRightOfCentre( .rightToLeft ) )
    }

    func testTheDotsAreInTheTokensOfTheWebAndAnAppsOwnColourWhileNotOffline() {
        CallScreen.shared.configure( .init( tokens: [
            "--wplus-color-online": "1, 2, 3", "--wplus-color-busy": "4, 5, 6", "--wplus-color-away": "7, 8, 9", "--wplus-color-offline": "10, 11, 12",
        ] ) )
        func rgb( _ color: UIColor? ) -> [ Int ] {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color?.getRed( &red, green: &green, blue: &blue, alpha: &alpha )
            return [ red, green, blue ].map { Int( ( $0 * 255 ).rounded() ) }
        }
        XCTAssertEqual( rgb( PresenceDot( presence: .online ).backgroundColor ), [ 1, 2, 3 ] )
        XCTAssertEqual( rgb( PresenceDot( presence: .busy ).backgroundColor ), [ 4, 5, 6 ] )
        XCTAssertEqual( rgb( PresenceDot( presence: .away ).backgroundColor ), [ 7, 8, 9 ] )
        XCTAssertEqual( rgb( PresenceDot( presence: .offline ).backgroundColor ), [ 10, 11, 12 ] )
        XCTAssertEqual( rgb( PresenceDot( presence: nil ).backgroundColor ), [ 10, 11, 12 ], "no status is drawn as offline" )

        let own = UIColor( red: 0, green: 0, blue: 1, alpha: 1 )
        XCTAssertEqual( rgb( PresenceDot( presence: .online, color: own ).backgroundColor ), [ 0, 0, 255 ] )
        XCTAssertEqual( rgb( PresenceDot( presence: .offline, color: own ).backgroundColor ), [ 10, 11, 12 ] )
    }

    // MARK: TypingDots and ActivityIndicator

    func testTheLineSaysWhoAsTheWebGroupsThem() {
        func said( _ list: [ ActivityEntry ] ) -> String { ActivityIndicator.said( list ) }

        XCTAssertEqual( said( [ .init() ] ), "typing", "nobody named" )
        XCTAssertEqual( said( [ .init( name: "Anna" ) ] ), "Anna typing" )
        XCTAssertEqual( said( [ .init( name: "Anna" ), .init( name: "Bob" ) ] ), "Anna, Bob typing" )
        XCTAssertEqual( said( [ .init( name: "Anna" ), .init( name: "Bob" ), .init( name: "Cara" ) ] ), "3 typing", "past two, a count" )
        XCTAssertEqual( said( [ .init(), .init() ] ), "2 typing" )
        XCTAssertEqual( said( [ .init( name: " " ) ] ), "typing", "a name of nothing is no name" )

        XCTAssertEqual( said( [ .init( activity: .recording ) ] ), "recording" )
        XCTAssertEqual( said( [ .init( name: "Carol", activity: .recording ) ] ), "Carol recording" )
        XCTAssertEqual( said( [ .init( activity: .uploading ) ] ), "sending file" )
        XCTAssertEqual( said( [ .init( name: "Dan", activity: .uploading ) ] ), "Dan sending file" )

        XCTAssertEqual(
            said( [ .init( name: "Carol", activity: .recording ), .init( name: "Anna" ), .init( name: "Bob" ) ] ),
            "Anna, Bob typing, Carol recording",
            "each activity its own part, typing first"
        )
    }

    func testTheLineHasTheIconOfItsOneActivityAndTheDotsOnceTheyMix() {
        XCTAssertEqual( ActivityIndicator.iconActivity( [ .init() ] ), .typing )
        XCTAssertEqual( ActivityIndicator.iconActivity( [ .init( activity: .recording ) ] ), .recording )
        XCTAssertEqual( ActivityIndicator.iconActivity( [ .init( activity: .uploading ) ] ), .uploading )
        XCTAssertEqual( ActivityIndicator.iconActivity( [ .init( activity: .recording ), .init( activity: .uploading ) ] ), .typing )

        let line = ActivityIndicator( names: [ "Anna" ] )
        XCTAssertTrue( line.iconView is TypingDots )
        XCTAssertEqual( line.accessibilityLabel, "Anna typing" )
        XCTAssertTrue( texts( line ).contains( "Anna typing" ) )

        line.activity = .recording
        XCTAssertFalse( line.iconView is TypingDots )
        XCTAssertEqual( line.accessibilityLabel, "Anna recording" )

        line.entries = [ .init( name: "Bob" ), .init( name: "Cara", activity: .uploading ) ]
        XCTAssertTrue( line.iconView is TypingDots )
        XCTAssertEqual( line.accessibilityLabel, "Bob typing, Cara sending file" )
    }

    func testTheWordsAreTheAppsWhereItGivesThem() {
        CallScreen.shared.configure( .init( strings: [
            "typing": "schreibt", "typing_named": "%s schreibt", "recording_named": "%s nimmt auf", "uploading": "sendet",
            "online": "Da", "online_empty": "Niemand", "close": "Schliessen", "presence_online": "Anwesend",
        ] ) )
        XCTAssertEqual( ActivityIndicator.said( [ .init() ] ), "schreibt" )
        XCTAssertEqual( ActivityIndicator.said( [ .init( name: "Anna" ) ] ), "Anna schreibt" )
        XCTAssertEqual( ActivityIndicator.said( [ .init( name: "Anna", activity: .recording ) ] ), "Anna nimmt auf" )
        XCTAssertEqual( ActivityIndicator.said( [ .init( activity: .uploading ) ] ), "sendet" )

        let list = OnlineList( onClose: {} )
        XCTAssertEqual( list.titleShown, "DA (0)" )
        XCTAssertEqual( list.emptyShown, "Niemand" )
        XCTAssertEqual( list.closeShown?.accessibilityLabel, "Schliessen" )
        XCTAssertEqual( Avatar( name: "Ann", presence: .online ).accessibilityLabel, "Ann, Anwesend" )
    }

    func testTheDotsMoveOnAWindowAndStopOffIt() {
        let dots = TypingDots()
        XCTAssertFalse( dots.moving, "off a window nothing moves" )

        let window = laidOut( dots )
        defer { window.isHidden = true }
        XCTAssertEqual( dots.moving, !UIAccessibility.isReduceMotionEnabled, "and still where motion is asked to be reduced" )
        XCTAssertFalse( dots.isAccessibilityElement, "the line says what they mean" )

        dots.removeFromSuperview()
        XCTAssertFalse( dots.moving )
    }

    // MARK: Plain values

    /// These views are fed by whoever draws them: none imports the rooms or the calls, so none can read a room.
    func testNoneOfThemReadsARoom() throws {
        let tests = URL( fileURLWithPath: #filePath ).deletingLastPathComponent()
        let sources = tests.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent( "Sources/WordPlusRealtimeUI" )
        for name in [ "Presence.swift", "OnlineList.swift" ] {
            // A copy of the screen in an app keeps these tests beside its own folders.
            guard let text = try? String( contentsOf: sources.appendingPathComponent( name ), encoding: .utf8 ) else {
                throw XCTSkip( "the package's sources are not beside these tests" )
            }
            let imports = text.split( separator: "\n" ).filter { $0.hasPrefix( "import " ) || $0.hasPrefix( "@_spi" ) }
            XCTAssertEqual( imports, [ "import UIKit" ], "\( name ) imports the view kit alone" )
            for word in [ "Room", "Realtime", "GroupCall", "RealtimeCalls" ] {
                XCTAssertFalse( text.contains( ": \( word )" ), "\( name ) takes no \( word )" )
            }
        }
    }
}
