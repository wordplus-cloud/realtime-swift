#if canImport(UIKit)
import UIKit
import XCTest
@testable import WordPlusRealtimeUI

/// The call screen's look from the app's tokens (CallScreen.Appearance, step 1 of customizing): the web's own names
/// for the stage, a grid's tiles, a control and the dock's glass recolour them, and without them the stage stays
/// near-black whatever the palette's other colours. Run on a simulator, as PiecesTests.
@MainActor
final class ThemeTests: XCTestCase {
    override func tearDown() {
        CallScreen.shared.configure( .init() )
        super.tearDown()
    }

    private func rgb( _ color: UIColor ) -> [ Int ] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed( &r, green: &g, blue: &b, alpha: &a )
        return [ r, g, b ].map { Int( ( $0 * 255 ).rounded() ) }
    }

    func testTheAppsTokensColourTheStageTilesControlsAndDock() {
        CallScreen.shared.configure( .init( tokens: [
            "--bm-call-canvas": "248, 250, 252",
            "--bm-call-tile": "226, 232, 240",
            "--bm-call-btn": "#2563eb",
            "--bm-call-dock": "255, 255, 255",
        ] ) )

        XCTAssertEqual( rgb( BmCallsTheme.stage ), [ 248, 250, 252 ] )
        XCTAssertEqual( rgb( BmCallsTheme.tile ), [ 226, 232, 240 ] )
        XCTAssertEqual( rgb( BmCallsTheme.control ), [ 37, 99, 235 ] )
        XCTAssertEqual( rgb( BmCallsTheme.dockGlass ), [ 255, 255, 255 ] )

        // On the real screen: its ground is the app's stage.
        let preview = CallScreenPreview( .video )
        preview.loadViewIfNeeded()
        let screen = preview.children.compactMap { $0 as? BmCallsScreen }.first
        XCTAssertEqual( screen.flatMap { $0.view.backgroundColor }.map( rgb ), [ 248, 250, 252 ] )
    }

    func testWithoutThemTheStageStaysNearBlack() {
        CallScreen.shared.configure( .init( tokens: [ "--bm-color-accent": "37, 99, 235" ] ) )

        XCTAssertEqual( rgb( BmCallsTheme.stage ), [ 13, 15, 20 ] )
        XCTAssertEqual( rgb( BmCallsTheme.accent ), [ 37, 99, 235 ] )
    }
}
#endif
