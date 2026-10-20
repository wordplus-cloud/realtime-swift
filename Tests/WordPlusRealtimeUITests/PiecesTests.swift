#if canImport(UIKit)
import UIKit
import XCTest
@testable import WordPlusRealtimeUI

/// The call screen's pieces (CallScreen.Pieces), on the real screen with no call:
/// the dock arranged as the app answers, its own button drawn as ours are and hanging up still last, the status line,
/// the view over the stage, and none of it without pieces. Run on a simulator: `xcodebuild test -scheme
/// WordPlusRealtime-Package -destination 'platform=iOS Simulator,name=iPhone 16'`.
@MainActor
final class PiecesTests: XCTestCase {
    override func tearDown() {
        CallScreen.shared.pieces = .init()
        super.tearDown()
    }

    private func screen( phase: String ) -> BmCallsScreen {
        _ = CallScreen.shared
        let screen = BmCallsScreen()
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect( x: 0, y: 0, width: 390, height: 844 )
        screen.apply( state: [ "phase": phase, "type": "video", "group": false, "local": [ "muted": false, "camera": false ] ] )
        screen.view.layoutIfNeeded()
        return screen
    }

    /// The dock's buttons, in their order: by what VoiceOver says of them.
    private func dock( _ screen: BmCallsScreen ) -> [ String ] {
        func find( _ view: UIView ) -> UIStackView? {
            if let stack = view as? UIStackView, stack.arrangedSubviews.contains( where: { $0.accessibilityLabel == "End Call" } ) { return stack }
            return view.subviews.lazy.compactMap( find ).first
        }
        return find( screen.view )?.arrangedSubviews.map { $0.accessibilityLabel ?? "?" } ?? []
    }

    private func label( _ screen: BmCallsScreen, _ text: String ) -> UILabel? {
        func find( _ view: UIView ) -> UILabel? {
            if let label = view as? UILabel, label.text == text { return label }
            return view.subviews.lazy.compactMap( find ).first
        }
        return find( screen.view )
    }

    func testWithoutPiecesTheScreenIsOurs() {
        let ours = screen( phase: "ringing_out" )
        XCTAssertEqual( dock( ours ).last, "End Call" )
        XCTAssertFalse( dock( ours ).contains( "Call notes" ) )
        XCTAssertNotNil( label( ours, "Calling…" ) )
    }

    func testTheAppArrangesTheDockAndAddsItsOwnButtonWithHangingUpLast() {
        var pressed = 0
        var phases: [ String ] = []
        CallScreen.shared.pieces = .init( controls: { ours, state in
            phases.append( state.phase )
            // Hanging up put first: it stays last. Picture in picture dropped, the app's button added.
            let end = ours.filter { $0.id == "end" }
            return end + ours.filter { $0.id != "end" && $0.id != "pip" } + [
                .init( id: "notes", label: "Call notes", icon: CallScreen.CallControl.icons[ "alert" ]! ) { pressed += 1 },
            ]
        } )
        let screen = screen( phase: "ringing_out" )
        let row = dock( screen )

        XCTAssertEqual( row.last, "End Call" )
        XCTAssertEqual( row[ row.count - 2 ], "Call notes" )
        XCTAssertFalse( row.contains( "Picture In Picture" ) )
        XCTAssertTrue( phases.contains( "ringing_out" ) )

        // Drawn as ours: a dock button, sized with the rest, and it does what the app said.
        func find( _ view: UIView ) -> UIView? {
            if view.accessibilityIdentifier == "call-control-notes" { return view }
            return view.subviews.lazy.compactMap( find ).first
        }
        let notes = find( screen.view )
        XCTAssertTrue( notes is BmCallsButton )
        XCTAssertGreaterThan( notes?.bounds.width ?? 0, 30 )
        XCTAssertTrue( notes?.accessibilityActivate() ?? false )
        XCTAssertEqual( pressed, 1 )
    }

    func testTheStatusLineAndTheViewOverTheStage() {
        let over = UIView()
        over.accessibilityIdentifier = "my-stage"
        CallScreen.shared.pieces = .init(
            status: { state in state.phase == "ringing_out" ? "Ringing Ann…" : nil },
            stage: { _ in over }
        )
        let ringing = screen( phase: "ringing_out" )
        XCTAssertNotNil( label( ringing, "Ringing Ann…" ) )
        XCTAssertNil( label( ringing, "Calling…" ) )
        XCTAssertTrue( over.superview === ringing.view )

        // A phase the app leaves to us: ours.
        let connecting = screen( phase: "connecting" )
        XCTAssertNotNil( label( connecting, "Connecting..." ) )
    }

    func testAButtonTheAppMakesAnewAtEachChangeKeepsTheDockAsItIsAndDoesTheNewestAction() {
        // As the docs write it: the app's button made in `controls`, so anew at every change of the call, many a second
        // while it connects. The dock keeps the one it shows, with what the newest one says, and isn't built again.
        var made = 0
        var pressed: [ Int ] = []
        CallScreen.shared.pieces = .init( controls: { ours, _ in
            made += 1
            let n = made
            return ours + [ .init( id: "order", label: "Order \( n )", icon: CallScreen.CallControl.icons[ "alert" ]! ) { pressed.append( n ) } ]
        } )
        let screen = screen( phase: "in_progress" )
        func row( _ view: UIView ) -> UIStackView? {
            if let stack = view as? UIStackView, stack.arrangedSubviews.contains( where: { $0.accessibilityLabel == "End Call" } ) { return stack }
            return view.subviews.lazy.compactMap( row ).first
        }
        let before = row( screen.view )?.arrangedSubviews ?? []
        let order = before.first { $0.accessibilityIdentifier == "call-control-order" }
        XCTAssertNotNil( order )

        for _ in 0..<5 {
            screen.apply( state: [ "phase": "in_progress", "type": "video", "group": false, "local": [ "muted": false, "camera": false ] ] )
        }

        XCTAssertGreaterThan( made, 5 )
        XCTAssertEqual( row( screen.view )?.arrangedSubviews ?? [], before )
        XCTAssertEqual( order?.accessibilityLabel, "Order \( made )" )
        XCTAssertTrue( order?.accessibilityActivate() ?? false )
        XCTAssertEqual( pressed, [ made ] )
    }
}
#endif
