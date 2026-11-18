#if canImport(UIKit)
import UIKit
import XCTest
@testable import WordPlusRealtimeUI

/// A group call's recording on the call screens, as the web's recording.tsx draws it: who is told and asked under each
/// of the site's ways of telling, the words, the time, the start's facts, and the real screen drawing the notice, the
/// question to stay or leave and REC from the engine's state. Run on a simulator: `xcodebuild test -scheme
/// WordPlusRealtime-Package -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:WordPlusRealtimeUITests`.
@MainActor
final class RecordingTests: XCTestCase {
    private func recording( _ values: [ String: Any ] ) -> CallsRecording {
        var base: [ String: Any ] = [ "state": "on", "id": "7", "since": 0, "can": false, "tell": "notice", "by": "Ann", "mine": false, "notice": true, "answer": "" ]
        base.merge( values ) { $1 }
        return CallsRecording( base )!
    }

    // MARK: Who is told

    func testEachWayOfTellingAsTheWebTellsIt() {
        // REC alone: nobody is told or asked more.
        XCTAssertFalse( recording( [ "tell": "indicator" ] ).told )
        XCTAssertTrue( recording( [ "tell": "indicator" ] ).pillShown )

        // Only moderators know: a member sees no REC and is told nothing; a moderator sees REC.
        XCTAssertFalse( recording( [ "tell": "moderators" ] ).pillShown )
        XCTAssertFalse( recording( [ "tell": "moderators" ] ).told )
        XCTAssertTrue( recording( [ "tell": "moderators", "can": true ] ).pillShown )

        // A notice, until it is seen or turned off for good.
        XCTAssertTrue( recording( [ "tell": "notice" ] ).noticeShown )
        XCTAssertFalse( recording( [ "tell": "notice" ] ).asking )
        XCTAssertFalse( recording( [ "tell": "notice", "answer": "seen" ] ).noticeShown )
        XCTAssertFalse( recording( [ "tell": "notice", "notice": false ] ).noticeShown )

        // The question, until they agree, with the microphone and camera held for `muted`.
        XCTAssertTrue( recording( [ "tell": "ask" ] ).asking )
        XCTAssertTrue( recording( [ "tell": "muted" ] ).asking )
        XCTAssertFalse( recording( [ "tell": "muted", "answer": "agreed" ] ).asking )
        XCTAssertFalse( recording( [ "tell": "ask" ] ).noticeShown )

        // Whoever started it is told and asked nothing, and nothing is told before it records.
        XCTAssertFalse( recording( [ "tell": "ask", "mine": true ] ).asking )
        XCTAssertFalse( recording( [ "tell": "notice", "mine": true ] ).noticeShown )
        XCTAssertFalse( recording( [ "tell": "ask", "state": "starting" ] ).asking )
        XCTAssertFalse( recording( [ "tell": "ask", "id": "" ] ).asking )

        // Unknown ways are a notice, and the store's states read as the call screen's.
        XCTAssertEqual( recording( [ "tell": "shout" ] ).tell, "notice" )
        XCTAssertEqual( CallsRecording.stateOf( "recording" ), "on" )
        XCTAssertEqual( CallsRecording.stateOf( "finishing" ), "off" )
        XCTAssertEqual( recording( [ "id": 42 ] ).id, "42" )
    }

    func testJoinedWhileItRecordedOrThereAsItStarted() {
        var there = CallsRecordingLate()
        there.see( connected: true, recording: recording( [ "state": "off" ] ) )
        there.see( connected: true, recording: recording( [ "state": "on" ] ) )
        XCTAssertFalse( there.isLate( "7" ) )

        var joined = CallsRecordingLate()
        joined.see( connected: false, recording: recording( [ "state": "on" ] ) )
        joined.see( connected: true, recording: recording( [ "state": "on" ] ) )
        XCTAssertTrue( joined.isLate( "7" ) )

        let said = recording( [ "settings": [ "watch": "people" ] ] )
        XCTAssertEqual( said.noticeTitle( late: false ), "Ann started recording this call" )
        XCTAssertEqual( said.noticeTitle( late: true ), "This call is being recorded" )
        XCTAssertEqual( said.noticeNote( late: true ), "Ann started recording. The people who were in the call can watch it afterwards." )
        XCTAssertEqual( said.noticeNote( late: false ), "The people who were in the call can watch it afterwards." )
    }

    func testTheQuestionAndTheModeratorsWords() {
        XCTAssertEqual( recording( [ "tell": "muted" ] ).questionLead, "Ann started recording. Your microphone and camera stay off until you agree to be recorded." )
        XCTAssertEqual( recording( [ "tell": "muted" ] ).questionYes, "I Agree" )
        XCTAssertEqual( recording( [ "tell": "ask", "by": "" ] ).questionLead, "If you stay in the call, you agree to be recorded." )
        XCTAssertEqual( recording( [ "tell": "ask" ] ).questionYes, "Stay in Call" )

        XCTAssertEqual( recording( [ "tell": "moderators" ] ).startNote, "Asks you first. Nobody else in the call is told." )
        XCTAssertEqual( recording( [ "tell": "indicator" ] ).startNote, "Asks you first. Everyone in the call then sees REC beside the call controls." )
        XCTAssertEqual( recording( [ "settings": [ "watch": "admins" ] ] ).readyLead, "Site administrators can watch it in a few minutes." )
        XCTAssertEqual( recording( [ "settings": [ "watch": "admins" ] ] ).watchNote, "" )
        XCTAssertEqual( recording( [ "settings": [ "watch": "everyone", "transcript": true ] ] ).watchNote,
                        "Everyone in the conversation can watch it afterwards. A transcript is made too." )
    }

    func testTheTimeAndTheStartsFacts() {
        XCTAssertEqual( CallsRecording.elapsed( 0 ), "0:00" )
        XCTAssertEqual( CallsRecording.elapsed( 724 ), "12:04" )
        XCTAssertEqual( CallsRecording.elapsed( 3725 ), "1:02:05" )
        XCTAssertEqual( CallsRecording.elapsed( -5 ), "0:00" )

        let video = recording( [ "settings": [ "size": 720, "layout": "gallery", "transcript": true, "language": "auto", "watch": "moderators", "keepDays": 0 ] ] )
        let rows = video.facts( audio: false ).map { $0.0 + ": " + $0.1 }
        XCTAssertEqual( rows, [ "Picture: 720p, Gallery layout", "Transcript: Automatic", "Who can watch: Moderators", "Kept: Until deleted" ] )

        // An audio call's picture only where the site has its layout; a language and days only in the host's words.
        let audio = recording( [ "settings": [ "size": 1080, "transcript": true, "language": "uk", "keepDays": 30 ], "words": [ "kept": "30 днів", "language": "українська" ] ] )
        XCTAssertEqual( audio.facts( audio: true ).map { $0.0 + ": " + $0.1 }, [ "Transcript: українська", "Kept: 30 днів" ] )
        XCTAssertEqual( recording( [ "settings": [ "keepDays": 30, "transcript": true, "language": "uk" ] ] ).facts( audio: false ).count, 0 )
    }

    // MARK: On the screen

    private func person( local: Bool, admin: Bool = false ) -> CallsRoomParticipant {
        CallsRoomParticipant(
            identity: local ? "user_1" : "user_2", name: local ? "Me" : "Ann", avatar: "", isLocal: local, video: nil, screen: nil,
            speaking: false, audioLevel: 0, muted: true, micMuted: false, handRaised: false, isPinned: false,
            canPublish: true, canAdmin: admin, mode: "participant", lost: false
        )
    }

    /// `full`: the dock an app's moderator has on a phone, Show Chat and Share Screen too.
    private func screen( _ recording: [ String: Any ], admin: Bool = false, full: Bool = false ) -> CallsScreen {
        let screen = CallsScreen()
        screen.loadViewIfNeeded()
        if full {
            screen.canShareScreen = true
            screen.onToggleChat = {}
        }
        screen.view.frame = CGRect( x: 0, y: 0, width: 390, height: 844 )
        screen.setRoster( [ person( local: true, admin: admin ), person( local: false ) ] )
        apply( screen, recording )
        return screen
    }

    private func apply( _ screen: CallsScreen, _ recording: [ String: Any ] ) {
        var base: [ String: Any ] = [ "state": "on", "id": "9", "since": Int( Date().timeIntervalSince1970 ) - 65, "can": false, "tell": "notice", "by": "Ann", "mine": false, "notice": true, "answer": "" ]
        base.merge( recording ) { $1 }
        screen.apply( state: [ "phase": "in_progress", "type": "video", "group": true, "local": [ "muted": true, "camera": false ], "recording": base ] )
        screen.view.layoutIfNeeded()
    }

    private func find<T: UIView>( _ type: T.Type, in view: UIView ) -> T? {
        if let found = view as? T, !found.isHidden { return found }
        return view.subviews.lazy.compactMap { self.find( type, in: $0 ) }.first
    }

    private func texts( _ view: UIView ) -> [ String ] {
        ( ( view as? UILabel )?.text.map { [ $0 ] } ?? [] ) + view.subviews.flatMap { texts( $0 ) }
    }

    func testANoticeOverTheDockWithREC() {
        let screen = screen( [ "tell": "notice" ] )

        let notice = find( CallsRecordingNotice.self, in: screen.view )
        XCTAssertNotNil( notice )
        // There as it started? The screen first saw it running while connected, with nothing before: a join.
        XCTAssertEqual( notice?.content.title, "This call is being recorded" )
        XCTAssertTrue( texts( notice! ).contains( "Got It" ) )
        XCTAssertTrue( texts( notice! ).contains( "Do Not Show Again" ) )
        XCTAssertNil( find( CallsConfirm.self, in: screen.view ) )

        let pill = find( CallsRecordingPill.self, in: screen.view )
        XCTAssertNotNil( pill )
        XCTAssertEqual( pill?.accessibilityLabel, "This call is being recorded." )
        // A member's REC is no button, and on a phone it shows the dot and the time alone.
        XCTAssertFalse( pill?.accessibilityTraits.contains( .button ) ?? true )
        XCTAssertTrue( texts( pill! ).contains( where: { $0.hasPrefix( "1:0" ) } ) )

        // Got It: gone for this recording, REC stays.
        apply( screen, [ "tell": "notice", "answer": "seen" ] )
        XCTAssertNil( find( CallsRecordingNotice.self, in: screen.view ) )
        XCTAssertNotNil( find( CallsRecordingPill.self, in: screen.view ) )
    }

    func testTheQuestionToStayOrLeaveIsAnsweredBeforeAnythingElse() {
        let screen = screen( [ "tell": "muted" ] )

        let question = find( CallsConfirm.self, in: screen.view )
        XCTAssertNotNil( question )
        let said = texts( question! )
        XCTAssertTrue( said.contains( "This call is being recorded" ) )
        XCTAssertTrue( said.contains( "Ann started recording. Your microphone and camera stay off until you agree to be recorded." ) )
        XCTAssertTrue( said.contains( "Leave Call" ) )
        XCTAssertTrue( said.contains( "I Agree" ) )
        XCTAssertNil( find( CallsRecordingNotice.self, in: screen.view ) )

        // Escape does not put it away.
        _ = question?.accessibilityPerformEscape()
        XCTAssertNotNil( question?.superview )

        // Leave Call leaves.
        var left = false
        screen.onEnd = { left = true }
        question?.finish( false )
        XCTAssertTrue( left )

        // Agreed, it goes and stays gone; stopped, it goes too.
        let again = self.screen( [ "tell": "ask" ] )
        XCTAssertNotNil( find( CallsConfirm.self, in: again.view ) )
        apply( again, [ "tell": "ask", "answer": "agreed" ] )
        XCTAssertNil( find( CallsConfirm.self, in: again.view ) )

        let stopped = self.screen( [ "tell": "ask" ] )
        apply( stopped, [ "tell": "ask", "state": "stopping" ] )
        XCTAssertNil( find( CallsConfirm.self, in: stopped.view ) )
    }

    func testOnlyModeratorsKnow() {
        let member = screen( [ "tell": "moderators", "can": false ] )
        XCTAssertNil( find( CallsRecordingPill.self, in: member.view ) )
        XCTAssertNil( find( CallsRecordingNotice.self, in: member.view ) )
        XCTAssertNil( find( CallsConfirm.self, in: member.view ) )

        let moderator = screen( [ "tell": "moderators", "can": true ], admin: true, full: true )
        let pill = find( CallsRecordingPill.self, in: moderator.view )
        XCTAssertNotNil( pill )
        XCTAssertTrue( pill?.accessibilityTraits.contains( .button ) ?? false )
        XCTAssertTrue( pill?.accessibilityLabel?.hasPrefix( "Recording, 1:0" ) ?? false )
        XCTAssertTrue( pill?.accessibilityLabel?.hasSuffix( ". Stop recording" ) ?? false )

    }

    func testAModeratorsRECOnAPhoneStandsInTheBar() {
        // A moderator's REC with Stop beside a dock with Host Controls, Show Chat and Share Screen, on a phone: the dock
        // laid out before any recording, then REC arriving and the call redrawn before the next layout, as the app's
        // state and the ticking time do. REC stands in the bar, level with the dock and clear of it, never over the
        // bar's start where it covers the last tile's name.
        let moderator = screen( [ "tell": "notice", "can": true, "mine": true, "state": "off", "id": "" ], admin: true, full: true )
        moderator.view.layoutIfNeeded()

        let running: [ String: Any ] = [ "tell": "notice", "can": true, "mine": true, "state": "on", "id": "12" ]
        let state: [ String: Any ] = [ "phase": "in_progress", "type": "video", "group": true, "local": [ "muted": true, "camera": false ],
                                       "recording": running.merging( [ "since": Int( Date().timeIntervalSince1970 ) - 5, "by": "Me", "notice": true, "answer": "" ] ) { $1 } ]
        moderator.apply( state: state )
        moderator.apply( state: state )

        for _ in 0..<3 { moderator.view.layoutIfNeeded() }

        let pill = find( CallsRecordingPill.self, in: moderator.view )
        let dock = find( CallsDock.self, in: moderator.view )
        XCTAssertNotNil( pill )
        XCTAssertNotNil( dock )
        XCTAssertEqual( pill!.frame.midY, dock!.frame.midY, accuracy: 1 )
        XCTAssertFalse( pill!.frame.intersects( dock!.frame ) )

        // Stopped: Saving recording… is wider still, and where no place in the bar holds it, it stands at the top of the
        // call, never just over the bar on the last tile's name.
        var stopping = state
        stopping[ "recording" ] = ( state[ "recording" ] as! [ String: Any ] ).merging( [ "state": "stopping" ] ) { $1 }
        moderator.apply( state: stopping )
        moderator.apply( state: stopping )

        for _ in 0..<3 { moderator.view.layoutIfNeeded() }

        XCTAssertTrue( texts( pill! ).contains( "Saving recording…" ) )
        XCTAssertFalse( pill!.frame.intersects( dock!.frame ) )
        XCTAssertTrue( abs( pill!.frame.midY - dock!.frame.midY ) < 1 || pill!.frame.minY < moderator.view.bounds.height / 4,
                       "Saving recording… stands just over the bar, at \( pill!.frame )" )
    }

    func testAModeratorsStopIsAskedFirst() {
        let screen = screen( [ "tell": "notice", "can": true, "mine": true, "settings": [ "watch": "people" ] ], admin: true )

        XCTAssertNil( find( CallsRecordingNotice.self, in: screen.view ) )
        screen.askRecording( "stop" )

        let confirm = find( CallsConfirm.self, in: screen.view )
        XCTAssertNotNil( confirm )
        XCTAssertTrue( texts( confirm! ).contains( "Stop recording?" ) )
        XCTAssertTrue( texts( confirm! ).contains( "The people who were in the call can watch it in a few minutes." ) )

        // It no longer fits once it stops.
        apply( screen, [ "tell": "notice", "can": true, "mine": true, "state": "stopping" ] )
        XCTAssertNil( find( CallsConfirm.self, in: screen.view ) )

        // Start only while it is off.
        apply( screen, [ "tell": "notice", "can": true, "state": "off", "id": "" ] )
        screen.askRecording( "start" )
        XCTAssertTrue( texts( find( CallsConfirm.self, in: screen.view )! ).contains( "Start recording?" ) )
    }

    func testNothingWithoutARecordingOrOutsideAGroupCall() {
        let screen = CallsScreen()
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect( x: 0, y: 0, width: 390, height: 844 )
        screen.apply( state: [ "phase": "in_progress", "type": "video", "group": false, "local": [ "muted": true, "camera": false ],
                               "recording": [ "state": "on", "id": "3", "tell": "ask", "by": "Ann" ] ] )
        XCTAssertNil( find( CallsConfirm.self, in: screen.view ) )
        XCTAssertNil( find( CallsRecordingPill.self, in: screen.view ) )
    }
}
#endif
