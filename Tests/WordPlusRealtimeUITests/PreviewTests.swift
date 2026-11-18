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

    /// The words on screen: every label's text, under no hidden view.
    private func texts( _ view: UIView ) -> [ String ] {
        guard !view.isHidden else { return [] }

        return [ ( view as? UILabel )?.text ].compactMap { $0 } + view.subviews.flatMap( texts )
    }

    private func drawn( _ shown: CallScreenPreview.Shown ) -> ( CallScreenPreview, CallsScreen ) {
        let preview = CallScreenPreview( shown )
        preview.loadViewIfNeeded()
        preview.view.frame = CGRect( x: 0, y: 0, width: 390, height: 844 )
        preview.view.layoutIfNeeded()
        let screen = preview.children.compactMap { $0 as? CallsScreen }.first
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
                // A group call is left, not ended, and draws its people. Host Controls is a moderator's alone, and
                // nobody in the preview moderates.
                XCTAssertTrue( said.contains( "Exit Chat" ), "\( shown ) offers Exit Chat: \( said )" )
                let words = texts( screen.view )
                let people = shown == .groupJoining || shown == .groupWaiting ? [ "You" ] : [ "You", "Ann", "Ben", "Cara" ]
                XCTAssertTrue( people.allSatisfy( words.contains ), "\( shown ) draws its people: \( words )" )
                XCTAssertFalse( said.contains( "Host Controls" ), "\( shown ) offers Host Controls to nobody who moderates: \( said )" )
            } else {
                XCTAssertTrue( said.contains( "End Call" ), "\( shown ) offers End Call: \( said )" )
            }
        }
    }

    func testAJoinWaitingForAPlaceSaysSo() {
        // The web's status of a group call waiting (use-group-call.ts).
        XCTAssertTrue( texts( drawn( .groupWaiting ).1.view ).contains( "Waiting for a free place in the call..." ) )
        XCTAssertFalse( texts( drawn( .groupJoining ).1.view ).contains( "Waiting for a free place in the call..." ) )
    }

    func testARecordingIsTold() {
        // Someone else's recording: the pill, and the notice.
        func pill( _ view: UIView ) -> CallsRecordingPill? {
            if let found = view as? CallsRecordingPill, !found.isHidden { return found }
            return view.subviews.lazy.compactMap( pill ).first
        }
        let recorded = drawn( .recording ).1.view!
        XCTAssertNotNil( pill( recorded ) )
        XCTAssertTrue( texts( recorded ).contains( "This call is being recorded" ) )
        XCTAssertNil( pill( drawn( .group ).1.view ) )
    }

    func testACameraChangingCodecIsSaidOnItsTileAndNowhereElse() {
        let words = "Optimizing video quality..."
        let ( _, changing ) = drawn( .optimizing )
        XCTAssertEqual( labels( changing.view ).filter { $0 == words }.count, 1, "one tile says it: \( labels( changing.view ) )" )
        let ( _, still ) = drawn( .group )
        XCTAssertFalse( labels( still.view ).contains( words ), "no tile says it with no camera changing" )
    }

    func testACameraChangingCodecIsToldOncePerPersonWhereverTheirTileGoes() {
        let said = CallsOptimizingSaid()
        XCTAssertTrue( said.first( "ann" ) )
        XCTAssertFalse( said.first( "ann" ), "another tile of Ann's, or hers drawn again" )
        XCTAssertTrue( said.first( "ben" ) )
        said.keep( [ "ben" ] )
        XCTAssertTrue( said.first( "ann" ), "Ann's change over: her next one is told" )
        XCTAssertFalse( said.first( "ben" ) )
    }

    /// The web's group call while its room connects: the grid, no "Connecting..." over it, the spinner before the dock,
    /// and the dock Show Chat and Exit Chat alone. Connected, the spinner is gone and the dock is whole.
    func testAGroupCallBeingJoinedSaysSoBeforeItsDock() {
        let ( preview, joining ) = drawn( .groupJoining )
        preview.view.layoutIfNeeded()
        let said = labels( joining.view )
        let words = texts( joining.view )
        XCTAssertFalse( words.contains( "Connecting..." ), "nothing says Connecting... over the grid: \( words )" )
        XCTAssertTrue( said.contains( "Connection Status (Quality)" ), "the bar starts with the connection: \( said )" )
        XCTAssertTrue( said.contains( "Exit Chat" ), "the way out is there: \( said )" )
        for control in [ "Enable Microphone", "Disable Microphone", "Enable Camera", "Disable Camera", "Speaker", "Device Settings" ] {
            XCTAssertFalse( said.contains( control ), "\( control ) waits for the room: \( said )" )
        }

        XCTAssertEqual( pill( joining.view )?.accessibilityValue, "Connecting...", "the bar says it connects" )

        let ( connected, joined ) = drawn( .group )
        connected.view.layoutIfNeeded()
        let offered = labels( joined.view )
        XCTAssertTrue( offered.contains( "Connection Status (Quality)" ), "a connected call keeps its connection, as a dot: \( offered )" )
        XCTAssertNil( pill( joined.view )?.accessibilityValue, "a connected call still turns its spinner" )
        XCTAssertTrue( offered.contains( "Disable Microphone" ) || offered.contains( "Enable Microphone" ), "a connected call has its microphone: \( offered )" )
    }

    private func everything( _ view: UIView ) -> [ UIView ] {
        [ view ] + view.subviews.flatMap( everything )
    }

    private func pill( _ view: UIView ) -> UIView? {
        everything( view ).first { $0 is CallsConnectionPill }
    }

    /// The web's group bar on a phone: its tiles stop above the dock, 8 from the screen's edges and from each other,
    /// the connection at the bar's start and the dock at its end. A tap leaves the bar where it is.
    func testAGroupCallsTilesStopAboveItsBar() {
        let ( preview, screen ) = drawn( .group )
        preview.view.layoutIfNeeded()
        let root = screen.view!
        let width = root.bounds.width
        guard let dock = everything( root ).first( where: { $0 is CallsDock } ), let badge = pill( root ) else {
            return XCTFail( "the bar is drawn" )
        }

        let docked = dock.convert( dock.bounds, to: root )
        let started = badge.convert( badge.bounds, to: root )
        let tiles = everything( root )
            .filter { String( describing: type( of: $0 ) ) == "Tile" && !$0.isHidden }
            .map { $0.convert( $0.bounds, to: root ) }
            .sorted { $0.minY < $1.minY }

        XCTAssertEqual( tiles.count, 4, "every person has a tile" )
        for tile in tiles {
            XCTAssertLessThanOrEqual( tile.maxY, docked.minY - 9 + 0.5, "a tile runs under the dock: \( tile ) over \( docked )" )
            XCTAssertEqual( tile.minX, 8, accuracy: 0.5, "a tile is 8 from the start: \( tile )" )
            XCTAssertEqual( tile.maxX, width - 8, accuracy: 0.5, "a tile is 8 from the end: \( tile )" )
        }
        for ( above, below ) in zip( tiles, tiles.dropFirst() ) {
            XCTAssertEqual( below.minY - above.maxY, 8, accuracy: 0.5, "the tiles are 8 apart" )
        }
        XCTAssertEqual( tiles.last?.maxY ?? 0, docked.minY - 9, accuracy: 0.5, "the last tile ends where the bar starts" )

        XCTAssertFalse( badge.isHidden, "the bar starts with the connection" )
        XCTAssertEqual( started.minX, 14, accuracy: 0.5, "the connection is 14 from the start" )
        XCTAssertEqual( docked.maxX, width - 14, accuracy: 0.5, "the dock is 14 from the end" )
        XCTAssertLessThanOrEqual( started.maxX + 10, docked.minX + 0.5, "the dock leaves the connection its room" )
        XCTAssertEqual( started.midY, docked.midY, accuracy: 0.5, "the two are level" )

        // The web's controls on a phone: 30 across, hanging up 16 wider, 5 apart, 6 in from the dock's edge.
        let buttons = ( dock as? CallsDock )?.row.arrangedSubviews.filter { !$0.isHidden }.map { $0.convert( $0.bounds, to: root ) } ?? []
        XCTAssertFalse( buttons.isEmpty, "the dock has controls" )
        for button in buttons {
            XCTAssertEqual( button.height, 30, accuracy: 0.5, "a control is not the web's 30: \( button )" )
        }
        XCTAssertEqual( buttons.last?.width ?? 0, 46, accuracy: 0.5, "leaving is not 16 wider than a control" )
        for ( before, after ) in zip( buttons, buttons.dropFirst() ) {
            XCTAssertEqual( after.minX - before.maxX, 5, accuracy: 0.5, "the controls are not 5 apart" )
        }
        XCTAssertEqual( ( buttons.first?.minX ?? 0 ) - docked.minX, 6, accuracy: 0.5, "the first control is not 6 in from the dock's edge" )
        XCTAssertEqual( docked.height, 42, accuracy: 0.5, "the dock is not the web's 42 tall" )

        screen.perform( NSSelectorFromString( "stageTapped" ) )
        XCTAssertEqual( dock.alpha, 1, "a tap put a group call's bar away" )
    }

    /// A press in Device Settings is the panel's: the screen's own tap took it from every button there (UIKit keeps a
    /// UIButton's tap from an ancestor's recognizer, not a UIControl of ours), so Done, Test and Preview did nothing.
    /// The dock is its own too, and a press on a tile is still the screen's.
    func testThePopupsKeepTheirPresses() {
        let ( preview, screen ) = drawn( .group )
        preview.view.layoutIfNeeded()
        guard let ground = screen.view.gestureRecognizers?.compactMap( { $0 as? CallsGroundTap } ).first else {
            return XCTFail( "the screen has its tap" )
        }

        screen.showDevices()
        preview.view.layoutIfNeeded()
        let panel = everything( screen.view ).compactMap { $0 as? CallsDevices }.first
        let done = panel.flatMap { everything( $0 ).first { $0 is CallsDevicePill } }
        XCTAssertNotNil( done, "Device Settings has its Done" )
        XCTAssertFalse( ground.takes( done ), "the screen takes the press on Done" )
        XCTAssertFalse( ground.takes( panel ), "the screen takes a press on the panel" )

        let dock = everything( screen.view ).first { $0 is CallsDock }
        XCTAssertFalse( ground.takes( dock?.subviews.first ), "the screen takes a press on the dock" )

        let tile = everything( screen.view ).first { String( describing: type( of: $0 ) ) == "Tile" }
        XCTAssertTrue( ground.takes( tile ), "a press on a tile is no longer the screen's" )
    }

    /// Device Settings: the camera in use is a field the width of its row with the system's own menu of the cameras, the
    /// one in use ticked, and the speaker's opens the system's list of outputs. As `.wplus-call-device-current`, where a
    /// line of quiet text read as a caption and people did not find where to choose a device.
    func testADeviceInUseIsAFieldThatOpensTheSystemsMenu() {
        let ( preview, screen ) = drawn( .video )
        screen.showDevices()
        preview.view.layoutIfNeeded()

        guard let panel = everything( screen.view ).compactMap( { $0 as? CallsDevices } ).first else {
            return XCTFail( "Device Settings opens" )
        }

        let rows = everything( panel ).compactMap { $0 as? CallsDeviceRow }
        XCTAssertEqual( rows.map( \.kind ), [ .camera, .microphone, .speaker ] )

        guard let camera = rows.first.flatMap( { everything( $0 ).compactMap { $0 as? CallsDeviceField }.first } ),
              let speaker = rows.last.flatMap( { everything( $0 ).compactMap { $0 as? CallsDeviceField }.first } ) else {
            return XCTFail( "each device has its field" )
        }

        XCTAssertTrue( camera.opens )
        XCTAssertTrue( camera.showsMenuAsPrimaryAction, "a press on the field is the menu" )
        XCTAssertEqual( camera.frame.height, 40, accuracy: 0.5, "the field is not a finger's height" )
        XCTAssertEqual( camera.frame.width, rows[ 0 ].frame.width - 16, accuracy: 0.5, "the field is not the width of its row" )

        let cameras = camera.menu?.children.compactMap { $0 as? UIAction } ?? []
        XCTAssertEqual( cameras.map( \.title ), [ "Front Camera", "Back Camera" ] )
        XCTAssertEqual( cameras.filter { $0.state == .on }.map( \.title ), [ camera.name.text ?? "" ], "the camera in use is not the one ticked" )

        XCTAssertTrue( speaker.opens )
        XCTAssertNil( speaker.menu, "the system keeps the list of outputs" )
        XCTAssertFalse( speaker.showsMenuAsPrimaryAction )
    }

    /// A device with nothing else to choose is plain text, with no arrow to press.
    func testADeviceWithNothingToChooseIsPlainText() {
        let field = CallsDeviceField()
        field.opens = false
        field.layoutIfNeeded()

        XCTAssertFalse( field.isUserInteractionEnabled )
        XCTAssertEqual( field.layer.borderWidth, 0 )
        XCTAssertTrue( everything( field ).filter { $0 is CallsIconView }.allSatisfy( \.isHidden ), "an arrow on a field that opens nothing" )
    }

    /// A window shrunk into the band under a page's header overlaps none of the screen's unsafe edges, so the call
    /// in it starts at its top: UIKit went on giving it the status bar's inset, an empty strip over the call. A window
    /// over the whole screen keeps every edge, and one reaching under the status bar keeps what it reaches.
    func testAWindowInABandHasNoStatusBarToClear() {
        let screen = CGRect( x: 0, y: 0, width: 402, height: 874 )
        let edges = UIEdgeInsets( top: 62, left: 0, bottom: 34, right: 0 )

        XCTAssertEqual( CallsScreen.safeArea( of: CGRect( x: 0, y: 118, width: 402, height: 302 ), on: screen, edges: edges ), .zero )
        XCTAssertEqual( CallsScreen.safeArea( of: screen, on: screen, edges: edges ), edges )
        XCTAssertEqual(
            CallsScreen.safeArea( of: CGRect( x: 0, y: 40, width: 402, height: 820 ), on: screen, edges: edges ),
            UIEdgeInsets( top: 22, left: 0, bottom: 20, right: 0 )
        )
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
