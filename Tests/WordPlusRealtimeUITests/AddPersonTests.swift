import UIKit
import XCTest
import WordPlusRealtimeCalls
@testable import WordPlusRealtimeUI

/// Add Person (realtime-ui's add-person.tsx) on the real screen, with a stand-in for the host: the button only where the
/// host gives whom to add and only once the call is up, the list as it loads, a press that rings, how each ring stands,
/// Cancel, and a failure said by the screen. Run on a simulator, as PiecesTests.
@MainActor
final class AddPersonTests: XCTestCase {
    private var asked: [ ( [ CallsAddPerson.Person ] ) -> Void ] = []
    private var added: [ ( person: CallsAddPerson.Person, done: ( String? ) -> Void ) ] = []
    private var cancelled: [ ( ring: String, done: ( String? ) -> Void ) ] = []
    private var rings: [ CallsAddPerson.Ring ] = []

    private let ann = CallsAddPerson.Person( id: "43", name: "Ann", avatar: "" )
    private let ben = CallsAddPerson.Person( id: "44", name: "Ben", avatar: "" )

    override func setUp() {
        super.setUp()
        _ = CallScreen.shared
        asked = []
        added = []
        cancelled = []
        rings = []
        CallsAddPersonStore.current = CallsAddPerson(
            people: { [unowned self] done in self.asked.append( done ) },
            add: { [unowned self] person, done in self.added.append( ( person, done ) ) },
            rings: { [unowned self] in self.rings },
            cancel: { [unowned self] ring, done in self.cancelled.append( ( ring, done ) ) }
        )
    }

    override func tearDown() {
        CallsAddPersonStore.current = nil
        super.tearDown()
    }

    private func screen( phase: String = "in_progress", group: Bool = false ) -> CallsScreen {
        let screen = CallsScreen()
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect( x: 0, y: 0, width: 390, height: 844 )
        screen.apply( state: state( phase: phase, group: group ) )
        screen.view.layoutIfNeeded()
        return screen
    }

    private func state( phase: String, group: Bool = false ) -> [ String: Any ] {
        [ "phase": phase, "type": "video", "group": group, "local": [ "muted": false, "camera": false ] ]
    }

    private func button( _ view: UIView ) -> CallsButton? {
        if view.accessibilityLabel == "Add Person", let found = view as? CallsButton { return found }
        return view.subviews.lazy.compactMap( button ).first
    }

    private func panel( _ view: UIView ) -> CallsAddPersonPanel? {
        if let found = view as? CallsAddPersonPanel { return found }
        return view.subviews.lazy.compactMap( panel ).first
    }

    private func texts( _ view: UIView ) -> [ String ] {
        guard !view.isHidden else { return [] }

        return [ ( view as? UILabel )?.text ].compactMap { $0 } + view.subviews.flatMap( texts )
    }

    private func row( _ name: String, in view: UIView ) -> UIControl? {
        if let found = view as? UIControl, !( view is CallsDevicePill ), texts( found ).contains( name ) { return found }
        return view.subviews.lazy.compactMap { self.row( name, in: $0 ) }.first
    }

    private func pill( _ view: UIView ) -> CallsDevicePill? {
        if let found = view as? CallsDevicePill { return found }
        return view.subviews.lazy.compactMap( pill ).first
    }

    private func press( _ control: UIControl ) {
        for target in control.allTargets {
            for action in control.actions( forTarget: target, forControlEvent: .touchUpInside ) ?? [] {
                _ = ( target as NSObject ).perform( Selector( action ) )
            }
        }
    }

    private func opened( _ people: [ CallsAddPerson.Person ]? = nil ) -> CallsScreen {
        let screen = screen()
        screen.showAddPerson()
        if let people { asked.removeLast()( people ) }
        screen.view.layoutIfNeeded()
        return screen
    }

    func testALongListScrollsUnderItsTitleAboveTheDock() {
        let everyone = ( 0..<100 ).map { CallsAddPerson.Person( id: String( $0 ), name: "Person \( $0 )", avatar: "" ) }
        let screen = opened( everyone )
        screen.view.layoutIfNeeded()

        func find( _ view: UIView ) -> UILabel? {
            if let label = view as? UILabel, label.text == "Add Person" { return label }
            return view.subviews.lazy.compactMap( find ).first
        }
        func scroll( _ view: UIView ) -> UIScrollView? {
            if let found = view as? UIScrollView { return found }
            return view.subviews.lazy.compactMap( scroll ).first
        }
        let card = panel( screen.view )!
        XCTAssertGreaterThan( find( card )?.bounds.height ?? 0, 10, "the rows give way, never the title" )
        XCTAssertGreaterThan( scroll( card )!.contentSize.height, scroll( card )!.bounds.height )
        XCTAssertGreaterThan( scroll( card )!.bounds.height, 100 )
    }

    func testAHostThatGivesNoneDrawsNoButton() {
        CallsAddPersonStore.current = nil
        XCTAssertEqual( button( screen().view )?.isHidden, true )

        let screen = screen()
        screen.showAddPerson()
        XCTAssertNil( panel( screen.view ), "and nothing opens" )
    }

    func testTheButtonIsThereOnceTheCallIsUp() {
        for phase in [ "ringing_out", "ringing_in", "connecting", "reconnecting" ] {
            XCTAssertEqual( button( screen( phase: phase ).view )?.isHidden, true, phase )
        }
        XCTAssertEqual( button( screen().view )?.isHidden, false, "a call between two" )
        XCTAssertEqual( button( screen( group: true ).view )?.isHidden, false, "a group call" )
        XCTAssertEqual( button( screen( phase: "connecting", group: true ).view )?.isHidden, true, "a group call joining" )
    }

    func testTheListSaysItIsLoadingThenWhomItOffersOrThatThereIsNoOne() {
        let loading = opened()
        XCTAssertTrue( texts( loading.view ).contains( "Add Person" ) )
        XCTAssertTrue( texts( loading.view ).contains( "Loading..." ) )
        XCTAssertEqual( button( loading.view )?.isOn, true, "its button latched while it is open" )

        asked.removeLast()( [ ann, ben ] )
        XCTAssertFalse( texts( loading.view ).contains( "Loading..." ) )
        XCTAssertTrue( texts( loading.view ).contains( "Ann" ) )
        XCTAssertTrue( texts( loading.view ).contains( "Ben" ) )

        let nobody = opened( [] )
        XCTAssertTrue( texts( nobody.view ).contains( "There is no one else to add" ) )
    }

    func testAPressRingsThemAndTheirRowSaysHowItStands() {
        let screen = opened( [ ann, ben ] )
        press( row( "Ann", in: screen.view )! )
        XCTAssertEqual( added.map( \.person ), [ ann ] )
        XCTAssertEqual( row( "Ben", in: screen.view )?.isEnabled, false, "one at a time, as the web" )

        press( row( "Ben", in: screen.view )! )
        XCTAssertEqual( added.count, 1 )

        rings = [ .init( id: "r1", to: "43", state: "ringing", canCancel: true ) ]
        added.removeLast().done( nil )
        XCTAssertNotNil( panel( screen.view ), "it stays, where the row says how the ring stands" )
        XCTAssertTrue( texts( screen.view ).contains( "Ringing…" ) )
        XCTAssertEqual( row( "Ann", in: screen.view )?.isEnabled, false, "ringing, not rung again" )
        XCTAssertEqual( row( "Ben", in: screen.view )?.isEnabled, true )
    }

    func testEachWayARingEndsIsSaid() {
        let screen = opened( [ ann ] )
        for ( state, said ) in [
            ( "answered", "Answered" ), ( "rejected", "Declined" ), ( "busy", "Busy" ), ( "no_answer", "No answer" ), ( "cancelled", "Cancelled" ),
        ] {
            rings = [ .init( id: "r", to: "43", state: state, canCancel: false ) ]
            screen.apply( state: self.state( phase: "in_progress" ) )
            XCTAssertTrue( texts( screen.view ).contains( said ), state )
            XCTAssertEqual( row( "Ann", in: screen.view )?.isEnabled, true, "\( state ): the person can be rung again" )
            XCTAssertNil( pill( panel( screen.view )! ), "\( state ): nothing to call off" )
        }
    }

    func testAPersonsLastRingIsWhatTheirRowSays() {
        rings = [
            .init( id: "old", to: "43", state: "busy", canCancel: false ),
            .init( id: "new", to: "43", state: "no_answer", canCancel: false ),
        ]
        let screen = opened( [ ann ] )
        XCTAssertTrue( texts( screen.view ).contains( "No answer" ) )
        XCTAssertFalse( texts( screen.view ).contains( "Busy" ) )
    }

    func testCancelCallsOffARingThisAppRangAlone() {
        rings = [ .init( id: "r1", to: "43", state: "ringing", canCancel: false ) ]
        let screen = opened( [ ann ] )
        XCTAssertNil( pill( panel( screen.view )! ), "a ring of someone else in the call" )

        rings = [ .init( id: "r1", to: "43", state: "ringing", canCancel: true ) ]
        screen.apply( state: state( phase: "in_progress" ) )
        let cancel = pill( panel( screen.view )! )
        XCTAssertEqual( cancel?.accessibilityLabel, "Cancel Ann" )
        XCTAssertFalse( row( "Ann", in: screen.view )?.isAccessibilityElement ?? true, "read beside its Cancel, not over it" )

        press( cancel! )
        XCTAssertEqual( cancelled.map( \.ring ), [ "r1" ] )
        XCTAssertEqual( pill( panel( screen.view )! )?.isEnabled, false, "once" )

        rings = [ .init( id: "r1", to: "43", state: "cancelled", canCancel: false ) ]
        cancelled.removeLast().done( nil )
        XCTAssertNotNil( panel( screen.view ) )
        XCTAssertTrue( texts( screen.view ).contains( "Cancelled" ) )
        XCTAssertNil( pill( panel( screen.view )! ) )
    }

    func testACancelThatFailedIsSaid() {
        rings = [ .init( id: "r1", to: "43", state: "ringing", canCancel: true ) ]
        let screen = opened( [ ann ] )
        press( pill( panel( screen.view )! )! )
        cancelled.removeLast().done( "You cannot make this call" )
        XCTAssertNil( panel( screen.view ) )
        XCTAssertTrue( texts( screen.view ).contains( "You cannot make this call" ) )
    }

    func testAFailureClosesItAndTheScreenSaysWhy() {
        let screen = opened( [ ann ] )
        press( row( "Ann", in: screen.view )! )
        added.removeLast().done( "You cannot make this call" )
        XCTAssertNil( panel( screen.view ) )
        XCTAssertEqual( button( screen.view )?.isOn, false )
        XCTAssertTrue( texts( screen.view ).contains( "You cannot make this call" ) )
    }

    func testAPressOfItsButtonClosesItAndAnotherPanelTakesItsPlace() {
        let screen = opened( [ ann ] )
        screen.showAddPerson()
        XCTAssertNil( panel( screen.view ), "the same press closes it" )

        screen.showAddPerson()
        XCTAssertNotNil( panel( screen.view ) )
        screen.showPanel( title: "Something else", rows: [] )
        XCTAssertNil( panel( screen.view ), "one at a time" )
    }

    func testItStaysOverACallBecomingAGroupCall() {
        let screen = opened( [ ann ] )
        rings = [ .init( id: "r1", to: "43", state: "ringing", canCancel: true ) ]

        for ( phase, group ) in [ ( "connecting", true ), ( "reconnecting", true ), ( "in_progress", true ) ] {
            screen.apply( state: state( phase: phase, group: group ) )
            XCTAssertNotNil( panel( screen.view ), phase )
            XCTAssertTrue( texts( screen.view ).contains( "Ringing…" ), phase )
        }
        XCTAssertEqual( button( screen.view )?.isHidden, false )
        XCTAssertEqual( button( screen.view )?.isOn, true )
    }

    func testAChangeOfTheCallLeavesItsRowsWhereNothingOfThemChanged() {
        let screen = opened( [ ann ] )
        let before = row( "Ann", in: screen.view )
        screen.apply( state: state( phase: "in_progress" ) )
        XCTAssertTrue( row( "Ann", in: screen.view ) === before, "a finger on one stays on it" )

        rings = [ .init( id: "r1", to: "43", state: "busy", canCancel: false ) ]
        screen.apply( state: state( phase: "in_progress" ) )
        XCTAssertFalse( row( "Ann", in: screen.view ) === before )
    }

    func testItGoesWithTheCallAndWithAHostThatStopsGivingIt() {
        let screen = opened( [ ann ] )
        screen.apply( state: state( phase: "idle" ) )
        XCTAssertNil( panel( screen.view ) )
        XCTAssertEqual( button( screen.view )?.isHidden, true )

        screen.apply( state: state( phase: "in_progress" ) )
        screen.showAddPerson()
        XCTAssertNotNil( panel( screen.view ) )
        CallsAddPersonStore.current = nil
        screen.apply( state: state( phase: "in_progress" ) )
        XCTAssertNil( panel( screen.view ) )
        XCTAssertEqual( button( screen.view )?.isHidden, true )
    }

    func testTheAppArrangesItByItsId() {
        var ids: [ String ] = []
        CallScreen.shared.pieces = .init( controls: { ours, _ in
            ids = ours.map( \.id )
            return ours.filter { $0.id != "add" }
        } )
        defer { CallScreen.shared.pieces = .init() }
        let arranged = screen()
        XCTAssertTrue( ids.contains( "add" ) )
        XCTAssertLessThan( ids.firstIndex( of: "share" )!, ids.firstIndex( of: "add" )! )
        XCTAssertLessThan( ids.firstIndex( of: "add" )!, ids.firstIndex( of: "end" )! )
        XCTAssertNil( button( arranged.view ), "an app can take it away" )
    }

    func testTheScreenOffersThoseListedLessWhomTheRuleRefusesAndAnyoneInTheCall() {
        let listed = [
            CallPerson( id: "1", name: "One" ), CallPerson( id: "2", name: "Two", avatar: "https://example.invalid/2.png" ),
            CallPerson( id: "3", name: "Three" ), CallPerson( id: "4", name: "Four" ),
        ]
        XCTAssertEqual(
            CallScreen.offered( listed, may: [ true, nil, false, true ], inCall: [ "4" ] ),
            [ .init( id: "1", name: "One", avatar: "" ), .init( id: "2", name: "Two", avatar: "https://example.invalid/2.png" ) ],
            "no answer keeps them, as the ring still asks the rule"
        )
        XCTAssertEqual( CallScreen.offered( listed, may: [], inCall: [] ).count, 4, "a route that gave no answers at all" )
        XCTAssertEqual( CallScreen.offered( [], may: [], inCall: [] ), [] )
    }

    func testARingThatDidNotGoOutIsSaidAsACallThatDidNot() {
        XCTAssertEqual( CallScreen.addFailure( CallError( "forbidden" ) ), "You cannot make this call" )
        XCTAssertEqual( CallScreen.addFailure( CallError( "not_connected" ) ), "This call could not be connected" )
    }
}
