#if canImport(UIKit)
import UIKit
import XCTest
@testable import WordPlusRealtimeUI
import WordPlusRealtime
import WordPlusRealtimeCalls

/// A host on the SDK's group calls, as the web's SDK screens have one (realtime-ui's use-group-call.ts): the person
/// menu's acts as the SDK's calls take them, the user a tile is, and Host Controls without the room's own rules, which
/// the cloud doesn't keep. Run on a simulator: `xcodebuild test -scheme WordPlusRealtime-Package -destination
/// 'platform=iOS Simulator,name=iPhone 16' -only-testing:WordPlusRealtimeUITests/ModerationTests`.
@MainActor
final class ModerationTests: XCTestCase {
    override func tearDown() {
        let engine = CallsEngine.shared
        engine.canModerate = false
        engine.carriesRoomRules = false
        engine.carriesSpotlight = false
        engine.onSpotlight = nil
        engine.isVideo = true
        engine.offers = nil
        engine.carriesAsks = false
        engine.canEndForEveryone = false
        engine.onBan = nil
        engine.callMode = "participatory"
        engine.roomLocked = false
        engine.roomMuted = false
        super.tearDown()
    }

    func testTheSDKsActsAreTheWebs() {
        let all = CallAct.allCases
        XCTAssertEqual( CallScreen.act( for: "remove_participant", offered: all ), .remove )
        XCTAssertEqual( CallScreen.act( for: "mute_participant", offered: all ), .listen )
        XCTAssertEqual( CallScreen.act( for: "demote_participant", offered: all ), .listen )
        XCTAssertEqual( CallScreen.act( for: "unmute_participant", offered: all ), .speak )
        XCTAssertEqual( CallScreen.act( for: "promote_participant", offered: all ), .speak )
        // Mute Microphone holds it where the call holds one, else mutes it once; Allow Microphone lets it go.
        XCTAssertEqual( CallScreen.act( for: "mute_mic", offered: all ), .holdMic )
        XCTAssertEqual( CallScreen.act( for: "mute_mic", offered: CallAct.base ), .mute )
        XCTAssertEqual( CallScreen.act( for: "unmute_mic", offered: all ), .releaseMic )
        // What the SDK's calls carry none of answers false.
        XCTAssertNil( CallScreen.act( for: "lock_room", offered: all ) )
        XCTAssertNil( CallScreen.act( for: "pin_participant", offered: all ) )
        // The room's rules and the asks, in the screens' words.
        XCTAssertEqual( CallScreen.rule( for: "mute_all" )?.muted, true )
        XCTAssertEqual( CallScreen.rule( for: "unlock_room" )?.locked, false )
        XCTAssertEqual( CallScreen.rule( for: "set_broadcast_mode" )?.mode, .broadcast )
        XCTAssertEqual( CallScreen.rule( for: "set_participatory_mode" )?.mode, .participatory )
        XCTAssertNil( CallScreen.rule( for: "remove_participant" ) )
        XCTAssertEqual( CallScreen.devices( for: "ask_camera_microphone" ), [ .camera, .microphone ] )
        XCTAssertEqual( CallScreen.devices( for: "ask_microphone" ), [ .microphone ] )

        XCTAssertEqual( CallScreen.user( of: "user_42" ), "42" )
        XCTAssertEqual( CallScreen.user( of: "user_auth0|5f7c8e" ), "auth0|5f7c8e" )
        XCTAssertNil( CallScreen.user( of: "user_" ) )
        XCTAssertNil( CallScreen.user( of: "ingest" ) )
    }

    private func person( _ id: Int, local: Bool = false, admin: Bool = false ) -> CallsRoomParticipant {
        CallsRoomParticipant(
            identity: "user_\( id )", name: local ? "Me" : "Person \( id )", avatar: "", isLocal: local, video: nil, screen: nil,
            speaking: false, audioLevel: 0, muted: false, micMuted: false, handRaised: false, isPinned: false,
            canPublish: true, canAdmin: admin, mode: "participant", lost: false
        )
    }

    private func screen( _ people: [ CallsRoomParticipant ], spotlight: [ String ] = [] ) -> CallsScreen {
        let screen = CallsScreen()
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect( x: 0, y: 0, width: 390, height: 844 )
        screen.show( name: "Group", avatar: "", video: true )
        screen.apply( state: [ "phase": "in_progress", "type": "video", "group": true, "local": [ "muted": true, "camera": false ], "spotlight": spotlight ] )
        screen.setRoster( people )
        screen.view.layoutIfNeeded()
        return screen
    }

    private func texts( _ view: UIView ) -> [ String ] {
        guard !view.isHidden else { return [] }
        return ( ( view as? UILabel )?.text.map { [ $0 ] } ?? [] ) + view.subviews.flatMap { texts( $0 ) }
    }

    private func hostControls( _ screen: CallsScreen ) -> [ String ] {
        CallsModeration.show( from: screen, participants: screen.roster )
        defer { screen.closePopover() }
        return screen.view.subviews.compactMap { $0 as? CallsPopover }.last.map { texts( $0 ) } ?? []
    }

    func testHostControlsHoldTheRoomsRulesOnlyWhereTheCallCarriesThem() {
        let engine = CallsEngine.shared
        engine.canModerate = true
        let people = [ person( 1, local: true, admin: true ), person( 2 ) ]

        // The SDK's calls: the join alerts, no rule of the room.
        engine.carriesRoomRules = false
        let sdk = hostControls( screen( people ) )
        XCTAssertTrue( sdk.contains( "Host Controls" ) )
        XCTAssertTrue( sdk.contains( "Join Alerts" ) )
        for rule in [ "Mute Everyone", "Lock Room", "Broadcast Mode", "Sound for Raised Hands" ] {
            XCTAssertFalse( sdk.contains( rule ), rule )
        }

        // An engine with them (Better Messages' app): every one, as before.
        engine.carriesRoomRules = true
        let rules = hostControls( screen( people ) )
        for rule in [ "Mute Everyone", "Lock Room", "Broadcast Mode", "Sound for Raised Hands", "Join Alerts" ] {
            XCTAssertTrue( rules.contains( rule ), rule )
        }
    }

    func testAHostOfTheSDKsCallsClearsTheSpotlightFromHostControls() {
        let engine = CallsEngine.shared
        engine.canModerate = true
        engine.carriesSpotlight = true
        let people = [ person( 1, local: true, admin: true ), person( 2 ) ]

        XCTAssertFalse( hostControls( screen( people ) ).contains( "Clear Spotlight" ) )
        let spotlit = hostControls( screen( people, spotlight: [ "user_2" ] ) )
        XCTAssertTrue( spotlit.contains( "Clear Spotlight" ) )
        XCTAssertFalse( spotlit.contains( "Lock Room" ) )
    }

    func testTheSpotlightGoesWhereTheCallScreenSendsIt() {
        let engine = CallsEngine.shared
        var answers: [ String ] = []
        func say( _ ok: Bool, _ error: String? ) { answers.append( ok ? "ok" : error ?? "failed" ) }

        // Nobody answering it: nothing happens.
        engine.spotlight( identity: "user_2", on: true, completion: say )

        var asked: [ String ] = []
        engine.onSpotlight = { identity, on, completion in
            asked.append( ( identity ?? "everyone" ) + ( on ? " on" : " off" ) )
            identity == "user_5" ? completion( false, CallsSpotlight.fullText ) : completion( true, nil )
        }
        engine.spotlight( identity: "user_2", on: true, completion: say )
        engine.spotlight( identity: "user_1", on: true, completion: say )
        engine.spotlight( identity: nil, on: false, completion: say )
        engine.spotlight( identity: "user_5", on: true, completion: say )

        XCTAssertEqual( asked, [ "user_2 on", "user_1 on", "everyone off", "user_5 on" ] )
        XCTAssertEqual( answers, [ "failed", "ok", "ok", "ok", "Up to four people can be in the spotlight." ] )
    }

    // MARK: What the call offers (GroupCall.acts), row by row

    private func who( _ id: Int, muted: Bool = false, micMuted: Bool = false, hand: Bool = false, publish: Bool = true ) -> CallsRoomParticipant {
        CallsRoomParticipant(
            identity: "user_\( id )", name: "Person \( id )", avatar: "", isLocal: false, video: nil, screen: nil,
            speaking: false, audioLevel: 0, muted: muted, micMuted: micMuted, handRaised: hand, isPinned: false,
            canPublish: publish, canAdmin: false, mode: "participant", lost: false
        )
    }

    private func menu( _ target: CallsRoomParticipant, offers: [ CallAct ] ) -> [ String ] {
        let engine = CallsEngine.shared
        engine.canModerate = true
        engine.offers = Set( offers.map( \.rawValue ) )
        engine.carriesAsks = offers.contains( .ask )
        engine.carriesSpotlight = offers.contains( .spotlight )
        let shown = screen( [ person( 1, local: true, admin: true ), target ] )
        return CallsModeration.personEntries( target, screen: shown ).compactMap { entry in
            if case let .row( row ) = entry { return row.label }
            return nil
        }
    }

    func testAPersonsMenuOffersOnlyWhatTheCallOffers() {
        CallsEngine.shared.onBan = { _, _, done in done( true ) }

        // Today's five: Mute Microphone once, Stop Camera & Mic, Remove from Call, the spotlight. No ban, no asks.
        let base = menu( who( 2 ), offers: CallAct.base )
        for row in [ "Mute Microphone", "Stop Camera & Mic", "Remove from Call", "Spotlight for Everyone", "Pin for Me" ] {
            XCTAssertTrue( base.contains( row ), row )
        }
        for row in [ "Remove and Ban from Calls…", "Ask to Turn On Camera" ] { XCTAssertFalse( base.contains( row ), row ) }

        // Every act: the ban, and the asks for what is off.
        let all = menu( who( 2, muted: true ), offers: CallAct.allCases )
        for row in [ "Keep Microphone Off", "Remove from Call", "Remove and Ban from Calls…", "Ask to Turn On Camera and Microphone" ] {
            XCTAssertTrue( all.contains( row ), row )
        }

        // None: nothing to do to them, and no pin for everyone of an older engine.
        let none = menu( who( 2 ), offers: [] )
        XCTAssertEqual( none, [ "Pin for Me" ] )

        // A microphone off already, with a mute once alone: nothing to keep off.
        XCTAssertFalse( menu( who( 2, muted: true ), offers: CallAct.base ).contains( "Keep Microphone Off" ) )
        // Without the engine's way to ban, no ban row, whatever the call offers.
        CallsEngine.shared.onBan = nil
        XCTAssertFalse( menu( who( 2 ), offers: CallAct.allCases ).contains( "Remove and Ban from Calls…" ) )
    }

    func testAListenerIsLetSpeakOnlyWhereTheCallOffersSpeak() {
        let listener = who( 2, muted: true, publish: false )
        XCTAssertTrue( menu( listener, offers: [ .speak, .remove ] ).contains( "Allow Camera & Mic" ) )
        XCTAssertFalse( menu( listener, offers: [ .listen, .remove ] ).contains( "Allow Camera & Mic" ) )
        XCTAssertFalse( menu( who( 2 ), offers: [ .speak ] ).contains( "Stop Camera & Mic" ) )
        CallsEngine.shared.callMode = "broadcast"
        XCTAssertTrue( menu( listener, offers: [ .speak ] ).contains( "Promote to Speaker" ) )
        XCTAssertFalse( menu( listener, offers: [ .listen ] ).contains( "Promote to Speaker" ) )
        XCTAssertTrue( menu( who( 2 ), offers: [ .listen ] ).contains( "Demote to Viewer" ) )
    }

    func testAHeldMicrophoneIsLetGoOnlyWhereTheCallOffersIt() {
        let held = who( 2, micMuted: true )
        XCTAssertTrue( menu( held, offers: CallAct.allCases ).contains( "Allow Microphone" ) )
        XCTAssertFalse( menu( held, offers: [ .remove, .holdMic ] ).contains( "Allow Microphone" ) )
        // Its header says who holds it.
        XCTAssertEqual( CallsModeration.personState( held ).map( \.label ), [ "Muted by a moderator" ] )
    }

    func testHandsAreLoweredWhereTheCallKeepsThem() {
        let up = who( 2, hand: true )
        XCTAssertTrue( menu( up, offers: [ .hand, .remove ] ).contains( "Lower Hand" ) )
        XCTAssertFalse( menu( up, offers: [ .remove ] ).contains( "Lower Hand" ) )

        let engine = CallsEngine.shared
        engine.canModerate = true
        engine.offers = [ "hand" ]
        XCTAssertFalse( engine.carriesRoomRules )
        XCTAssertTrue( engine.carriesHands )
        let controls = hostControls( screen( [ person( 1, local: true, admin: true ), up ] ) )
        XCTAssertTrue( controls.contains( "Lower All Hands" ) )
        XCTAssertFalse( controls.contains( "Lock Room" ) )
        engine.offers = [ "remove" ]
        XCTAssertFalse( hostControls( screen( [ person( 1, local: true, admin: true ), up ] ) ).contains( "Lower All Hands" ) )
        // An engine that names no acts keeps hands with its rules, as before.
        engine.offers = nil
        engine.carriesRoomRules = true
        XCTAssertTrue( engine.carriesHands )
    }

    func testHostControlsFollowTheRoomsRulesAndOfferEndButNoRecording() {
        let engine = CallsEngine.shared
        engine.canModerate = true
        engine.offers = Set( CallAct.allCases.map( \.rawValue ) )
        engine.carriesRoomRules = true
        engine.canEndForEveryone = true
        let people = [ person( 1, local: true, admin: true ), person( 2 ) ]

        let rules = hostControls( screen( people ) )
        for row in [ "Mute Everyone", "Lock Room", "Broadcast Mode", "End for Everyone" ] { XCTAssertTrue( rules.contains( row ), row ) }
        XCTAssertFalse( rules.contains( "Start Recording" ) )
        // The call screen offers no recording: a room nobody records shows none, and one recorded shows REC alone.
        XCTAssertNil( CallRecordingState().state( can: false ) )
        XCTAssertEqual( CallRecordingState( flag: true, now: 1 ).state( can: false )?[ "can" ] as? Bool, false )

        // Without `end`, End for Everyone isn't there.
        engine.canEndForEveryone = false
        XCTAssertFalse( hostControls( screen( people ) ).contains( "End for Everyone" ) )
    }

    func testAJoinRefusedIsSaidInTheWebsWords() {
        XCTAssertEqual( CallScreen.refusal( CallError( "locked" ) ), "This call is locked" )
        XCTAssertEqual( CallScreen.refusal( CallError( "banned" ) ), "A moderator removed you from this call until it ends" )
        let until = CallScreen.refusal( CallError( "banned", until: Date( timeIntervalSince1970: 1_800_000_000 ) ) ) ?? ""
        XCTAssertTrue( until.hasPrefix( "A moderator removed you from the calls of this conversation until " ), until )
        XCTAssertFalse( until.contains( "%s" ) )
        XCTAssertNil( CallScreen.refusal( CallError( "forbidden" ) ) )
    }

    func testABanIsAskedForInMinutesHoursOrDaysAtMostSevenDays() {
        XCTAssertEqual( CallsBan.minutes( amount: 1, unit: 60 ), 60 )
        XCTAssertEqual( CallsBan.minutes( amount: 0, unit: 1 ), 1 )
        XCTAssertEqual( CallsBan.minutes( amount: 9999, unit: 60 * 24 ), 7 * 24 * 60 )
        let form = CallsBan.Form()
        XCTAssertEqual( form.minutes, 60 )
        form.unit.selectedSegmentIndex = 2
        form.amount.text = "3"
        XCTAssertEqual( form.minutes, 3 * 24 * 60 )
    }

    func testATileOfSomeoneAwaySaysReconnecting() {
        let away = CallScreen.away( identity: "user_3", info: .object( [ "name": .string( "Ann" ) ] ), publish: true, hand: true )
        XCTAssertTrue( away.reconnecting )
        XCTAssertNil( away.video )
        XCTAssertEqual( away.name, "Ann" )
        XCTAssertTrue( away.handRaised )
    }
}
#endif
