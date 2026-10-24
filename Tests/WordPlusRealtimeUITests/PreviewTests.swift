#if canImport(UIKit)
import UIKit
import XCTest
@testable import WordPlusRealtimeUI

/// The preview (CallScreenPreview): every state draws the real
/// screen with no call, ringing in offers Answer and Reject, a call offers End Call, a group call has its people, and the
/// list names every state. Run on a simulator, as PiecesTests.
@MainActor
final class PreviewTests: XCTestCase {
    private func labels( _ view: UIView ) -> [ String ] {
        ( view.isHidden ? [] : [ view.accessibilityLabel ].compactMap { $0 } ) + view.subviews.flatMap( labels )
    }

    private func drawn( _ shown: CallScreenPreview.Shown ) -> ( CallScreenPreview, BmCallsScreen ) {
        let preview = CallScreenPreview( shown )
        preview.loadViewIfNeeded()
        preview.view.frame = CGRect( x: 0, y: 0, width: 390, height: 844 )
        preview.view.layoutIfNeeded()
        let screen = preview.children.compactMap { $0 as? BmCallsScreen }.first
        XCTAssertNotNil( screen, "\( shown ) draws the screen" )
        return ( preview, screen! )
    }

    func testEveryStateDrawsTheScreen() {
        for shown in CallScreenPreview.Shown.allCases {
            let ( _, screen ) = drawn( shown )
            let said = labels( screen.view )
            if shown == .ringing {
                XCTAssertTrue( said.contains( "Answer" ), "ringing in offers to answer: \( said )" )
                XCTAssertTrue( said.contains( "Reject" ), "ringing in offers to reject: \( said )" )
            } else if shown.isGroup {
                // A group call is left, not ended, and lists its people.
                XCTAssertTrue( said.contains( "Exit Chat" ), "\( shown ) offers Exit Chat: \( said )" )
                XCTAssertTrue( said.contains( "Participants (4)" ), "\( shown ) lists its people: \( said )" )
            } else {
                XCTAssertTrue( said.contains( "End Call" ), "\( shown ) offers End Call: \( said )" )
            }
        }
    }

    func testACameraChangingCodecIsSaidOnItsTileAndNowhereElse() {
        let words = "Optimizing video quality..."
        let ( _, changing ) = drawn( .optimizing )
        XCTAssertEqual( labels( changing.view ).filter { $0 == words }.count, 1, "one tile says it: \( labels( changing.view ) )" )
        let ( _, still ) = drawn( .group )
        XCTAssertFalse( labels( still.view ).contains( words ), "no tile says it with no camera changing" )
    }

    func testACameraChangingCodecIsToldOncePerPersonWhereverTheirTileGoes() {
        let said = BmCallsOptimizingSaid()
        XCTAssertTrue( said.first( "ann" ) )
        XCTAssertFalse( said.first( "ann" ), "another tile of Ann's, or hers drawn again" )
        XCTAssertTrue( said.first( "ben" ) )
        said.keep( [ "ben" ] )
        XCTAssertTrue( said.first( "ann" ), "Ann's change over: her next one is told" )
        XCTAssertFalse( said.first( "ben" ) )
    }

    func testAGroupCallHasItsPeople() {
        let ( _, screen ) = drawn( .group )
        XCTAssertEqual( screen.roster.map( \.name ), [ "You", "Ann", "Ben", "Cara" ] )
    }

    func testTheListNamesEveryState() {
        let preview = CallScreenPreview()
        preview.loadViewIfNeeded()
        let list = preview.view.subviews.compactMap { $0 as? UITableView }.first
        XCTAssertEqual( list?.numberOfRows( inSection: 0 ), CallScreenPreview.Shown.allCases.count )
    }
}
#endif
