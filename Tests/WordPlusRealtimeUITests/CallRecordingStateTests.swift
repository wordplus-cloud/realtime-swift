#if canImport(UIKit)
import UIKit
import XCTest
import WordPlusRealtimeCalls
@testable import WordPlusRealtimeUI

/// A group call's recording as the SDK's CallScreen names it to the screens (`state["recording"]`): Start for a host, its
/// answer, REC from the room's flag for everyone, and what a refusal leaves. Who is told what from there is RecordingTests.
@MainActor
final class CallRecordingStateTests: XCTestCase {
    private let rec = GroupRecording( id: "rec_0123456789", state: "recording" )

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject( forKey: CallsEngine.recordingNoticeNeverKey )
    }

    override func tearDown() {
        UserDefaults.standard.removeObject( forKey: CallsEngine.recordingNoticeNeverKey )
        super.tearDown()
    }

    func testNothingForSomeoneWhoMayNotWhileNothingRecords() {
        XCTAssertNil( CallRecordingState().state( can: false ) )
        let host = CallRecordingState().state( can: true )
        XCTAssertEqual( host?[ "state" ] as? String, "off" )
        XCTAssertEqual( host?[ "can" ] as? Bool, true )
    }

    func testAHostStartsAndStopsIt() {
        var state = CallRecordingState()
        state.ask( "starting" )
        XCTAssertEqual( state.state( can: true )?[ "state" ] as? String, "starting" )

        state.started( rec, now: 1_000 )
        var named = state.state( can: true )
        XCTAssertEqual( named?[ "state" ] as? String, "on" )
        XCTAssertEqual( named?[ "id" ] as? String, "rec_0123456789" )
        XCTAssertEqual( named?[ "since" ] as? Int, 1_000 )
        XCTAssertEqual( named?[ "mine" ] as? Bool, true )
        XCTAssertEqual( named?[ "can" ] as? Bool, true )

        // The room says so a moment later: the same recording, not another.
        state.flagged( true, now: 1_002 )
        XCTAssertEqual( state.state( can: true )?[ "id" ] as? String, "rec_0123456789" )
        XCTAssertEqual( state.state( can: true )?[ "since" ] as? Int, 1_000 )

        state.ask( "stopping" )
        XCTAssertEqual( state.state( can: true )?[ "state" ] as? String, "stopping" )

        // Stopped, and still stopping until the room says it has.
        state.stopped()
        named = state.state( can: true )
        XCTAssertEqual( named?[ "state" ] as? String, "stopping" )
        XCTAssertEqual( named?[ "id" ] as? String, "rec_0123456789" )
        state.flagged( false, now: 1_060 )
        XCTAssertEqual( state.state( can: true )?[ "state" ] as? String, "off" )
    }

    func testARoomThatNeverSaidSoStopsAtOnce() {
        var state = CallRecordingState()
        state.started( rec, now: 1_000 )
        state.stopped()
        XCTAssertEqual( state.state( can: true )?[ "state" ] as? String, "off" )
    }

    func testARefusalLeavesItAsItWas() {
        var state = CallRecordingState()
        state.ask( "starting" )
        state.refused()
        XCTAssertEqual( state.state( can: true )?[ "state" ] as? String, "off" )

        state.started( rec, now: 1_000 )
        state.ask( "stopping" )
        state.refused()
        XCTAssertEqual( state.state( can: true )?[ "state" ] as? String, "on" )
    }

    func testSomeoneElsesRecordingIsRECWithNoStop() {
        // Joined while it records, or there as someone else started it: the room's flag names no id to stop.
        var state = CallRecordingState( flag: true, now: 2_000 )
        var named = state.state( can: true )
        XCTAssertEqual( named?[ "state" ] as? String, "on" )
        XCTAssertEqual( named?[ "can" ] as? Bool, false )
        XCTAssertEqual( named?[ "mine" ] as? Bool, nil )
        XCTAssertEqual( named?[ "tell" ] as? String, "notice" )
        XCTAssertEqual( named?[ "since" ] as? Int, 2_000 )
        let first = named?[ "id" ] as? String
        XCTAssertFalse( first?.isEmpty ?? true )

        // The next one is told again, as the answers are kept by its id.
        state.flagged( false, now: 2_100 )
        XCTAssertNil( state.state( can: false ) )
        state.flagged( true, now: 2_200 )
        named = state.state( can: false )
        XCTAssertNotEqual( named?[ "id" ] as? String, first )
    }

    func testTheRoomStoppingItEndsOurOwnToo() {
        var state = CallRecordingState( flag: false, now: 0 )
        state.started( rec, now: 1_000 )
        state.flagged( true, now: 1_001 )
        state.flagged( false, now: 1_100 )
        XCTAssertEqual( state.state( can: true )?[ "state" ] as? String, "off" )
        XCTAssertNil( state.own )
    }

    func testDoNotShowAgainLeavesRECAlone() {
        XCTAssertEqual( CallRecordingState( flag: true, now: 1 ).state( can: false )?[ "notice" ] as? Bool, true )
        CallsEngine.shared.recordingNoticeNever()
        XCTAssertEqual( CallRecordingState( flag: true, now: 1 ).state( can: false )?[ "notice" ] as? Bool, false )
    }

    func testTheEngineAsksWhoeverAnswersAndRefusesWithNobody() {
        CallsEngine.shared.onRecord = nil
        var answer: Bool?
        CallsEngine.shared.startRecording { ok, _ in answer = ok }
        XCTAssertEqual( answer, false )

        var asked: [ Bool ] = []
        CallsEngine.shared.onRecord = { start, completion in
            asked.append( start )
            completion( true, nil )
        }
        defer { CallsEngine.shared.onRecord = nil }
        CallsEngine.shared.startRecording { ok, _ in answer = ok }
        XCTAssertEqual( answer, true )
        CallsEngine.shared.stopRecording { _, _ in }
        XCTAssertEqual( asked, [ true, false ] )
    }
}
#endif
