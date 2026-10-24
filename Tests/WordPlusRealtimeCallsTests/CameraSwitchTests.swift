import XCTest
import LiveKit
@testable import WordPlusRealtime
@testable @_spi(WordPlusUI) import WordPlusRealtimeCalls

/// A camera changing codec (CameraSwitch, GroupCall), as the web's call screen holds it: the word puts it up, the old
/// camera's frames and going don't end it, a new camera's first frame does, after `ready` any camera's next frame
/// does, the camera turned off does, and the media server's failsafe does, counted from the move's first word.
/// `GroupPerson.optimizing` says it until a new camera arrives. The same rules as Better Messages' app.
@MainActor
final class CameraSwitchTests: XCTestCase {
    private let start = Date( timeIntervalSince1970: 1_000 )
    private func at( _ seconds: TimeInterval ) -> Date { start.addingTimeInterval( seconds ) }
    private func word( _ text: String ) -> String? { CameraSwitch.state( of: Data( text.utf8 ) ) }

    func testTheWordsAreTheWebsAndNothingElse() {
        XCTAssertEqual( CameraSwitch.topic, "wp-camera" )
        XCTAssertEqual( word( #"{"state":"optimizing"}"# ), "optimizing" )
        XCTAssertEqual( word( #"{"at":1,"state":"ready"} "# ), "ready" )
        XCTAssertNil( word( #"{"state":"off"}"# ) )
        XCTAssertNil( word( "1" ), "not JSON" )
        XCTAssertNil( word( #"{"state":"ready""# ), "cut short" )
        XCTAssertNil( word( #"{"camera":{"state":"ready"}}"# ), "nested" )
        XCTAssertNil( word( #"{"state":["ready"]}"# ), "not a string" )
        XCTAssertNil( word( #"{"state":"ready"}{"state":"optimizing"}"# ), "more after it" )
    }

    /// The codec policy's numbers as the WordPlus RTC client for Swift keeps them from 1.0.7 on, and as 1.0.6 has none.
    private struct PolicyWithTune { let camera: [ String ]?; let tune: [ String: Double ]? }
    private struct PolicyBefore { let camera: [ String ]? }

    func testTheFailsafeIsTheNodesHeldToItsRange() {
        XCTAssertEqual( CameraSwitch.failsafeDefault, 10 )
        XCTAssertEqual( CameraSwitch.failsafe( tune: nil ), 10 )
        XCTAssertEqual( CameraSwitch.failsafe( tune: Double.nan ), 10 )
        XCTAssertEqual( CameraSwitch.failsafe( tune: 4.5 ), 4.5 )
        XCTAssertEqual( CameraSwitch.failsafe( tune: 1 ), 3 )
        XCTAssertEqual( CameraSwitch.failsafe( tune: 120 ), 30 )

        let given: PolicyWithTune? = PolicyWithTune( camera: nil, tune: [ "failsafeS": 4.5 ] )
        XCTAssertEqual( CameraSwitch.tune( "failsafeS", of: given ), 4.5, "read by name, from the optional the room hands over" )
        XCTAssertNil( CameraSwitch.tune( "failsafeS", of: PolicyWithTune( camera: nil, tune: [ "checkMs": 3000 ] ) ) )
        XCTAssertNil( CameraSwitch.tune( "failsafeS", of: PolicyWithTune( camera: nil, tune: nil ) ) )
        XCTAssertNil( CameraSwitch.tune( "failsafeS", of: PolicyBefore( camera: [ "vp8" ] ) ), "a client with no tune: the default" )
        XCTAssertNil( CameraSwitch.tune( "failsafeS", of: nil ) )
    }

    /// The policy as the room client hands it over (`Room.meshCodecPolicy`, the WordPlus RTC client for Swift 1.0.7):
    /// its `tune` is what the failsafe is read from, and a policy without one leaves the default.
    func testTheRoomClientsOwnPolicyGivesTheFailsafe() {
        let given: MeshCodecPolicy? = MeshCodecPolicy( camera: [ "vp9", "vp8" ], check: true, adapt: true, tune: [ "failsafeS": 4.5, "checkMs": 3000 ] )
        XCTAssertEqual( CameraSwitch.tune( "failsafeS", of: given ), 4.5 )
        XCTAssertEqual( CameraSwitch.failsafe( tune: CameraSwitch.tune( "failsafeS", of: given ) ), 4.5 )
        let outOfRange: MeshCodecPolicy? = MeshCodecPolicy( tune: [ "failsafeS": 90 ] )
        XCTAssertEqual( CameraSwitch.failsafe( tune: CameraSwitch.tune( "failsafeS", of: outOfRange ) ), 30 )
        let withoutTune: MeshCodecPolicy? = MeshCodecPolicy( camera: [ "vp8" ] )
        XCTAssertEqual( CameraSwitch.failsafe( tune: CameraSwitch.tune( "failsafeS", of: withoutTune ) ), 10 )
        let none: MeshCodecPolicy? = nil
        XCTAssertEqual( CameraSwitch.failsafe( tune: CameraSwitch.tune( "failsafeS", of: none ) ), 10 )
    }

    func testUpFromTheWordUntilTheNewCamerasFirstFrame() {
        var switching = CameraSwitch()
        XCTAssertTrue( switching.heard( "optimizing", from: "user_9", camera: "TR_old", at: at( 0 ) ), "the word changes what is shown" )
        XCTAssertTrue( switching.optimizing( "user_9" ) )
        XCTAssertTrue( switching.anyUp )
        XCTAssertEqual( switching.from( "user_9" ), "TR_old" )

        // The old camera's frames and its going are the move: nothing ends.
        XCTAssertFalse( switching.watches( "user_9", camera: "TR_old" ) )
        XCTAssertFalse( switching.shown( "user_9", camera: "TR_old" ) )
        XCTAssertFalse( switching.unpublished( "user_9", camera: "TR_old" ) )
        XCTAssertTrue( switching.optimizing( "user_9" ) )

        // The new camera's first frame does, `ready` or not, and nothing brings it back.
        XCTAssertTrue( switching.watches( "user_9", camera: "TR_new" ) )
        XCTAssertTrue( switching.shown( "user_9", camera: "TR_new" ) )
        XCTAssertFalse( switching.optimizing( "user_9" ) )
        XCTAssertFalse( switching.anyUp )
        XCTAssertNil( switching.nextExpiry() )
        XCTAssertFalse( switching.shown( "user_9", camera: "TR_other" ), "a later frame changes nothing" )
        XCTAssertFalse( switching.heard( "ready", from: "user_9", camera: "TR_new", at: at( 1.5 ) ), "its ready closes the move" )
        XCTAssertFalse( switching.optimizing( "user_9" ) )
    }

    func testAReadyEndsItAtTheNextFrameOfAnyCamera() {
        var switching = CameraSwitch()
        _ = switching.heard( "optimizing", from: "user_9", camera: "TR_old", at: at( 0 ) )
        XCTAssertFalse( switching.heard( "ready", from: "user_9", camera: nil, at: at( 1 ) ), "ready before the new camera arrived" )
        XCTAssertTrue( switching.optimizing( "user_9" ) )
        XCTAssertTrue( switching.watches( "user_9", camera: "TR_new" ) )
        XCTAssertTrue( switching.shown( "user_9", camera: "TR_new" ) )
        XCTAssertFalse( switching.optimizing( "user_9" ) )

        // A move that changed nothing: the old camera's next frame after `ready`.
        _ = switching.heard( "optimizing", from: "user_5", camera: "TR_same", at: at( 0 ) )
        XCTAssertFalse( switching.shown( "user_5", camera: "TR_same" ) )
        _ = switching.heard( "ready", from: "user_5", camera: "TR_same", at: at( 0.9 ) )
        XCTAssertTrue( switching.shown( "user_5", camera: "TR_same" ) )
        XCTAssertFalse( switching.optimizing( "user_5" ) )
    }

    func testACameraTurnedOffEndsIt() {
        var switching = CameraSwitch()
        _ = switching.heard( "optimizing", from: "user_1", camera: "TR_a", at: at( 0 ) )
        XCTAssertTrue( switching.muted( "user_1" ), "muted: no move mutes" )
        XCTAssertFalse( switching.optimizing( "user_1" ) )

        _ = switching.heard( "optimizing", from: "user_2", camera: "TR_a", at: at( 0 ) )
        XCTAssertTrue( switching.unpublished( "user_2", camera: "TR_b" ), "the new camera taken out again" )
        XCTAssertFalse( switching.optimizing( "user_2" ) )

        _ = switching.heard( "optimizing", from: "user_3", camera: "TR_a", at: at( 0 ) )
        _ = switching.heard( "ready", from: "user_3", camera: "TR_a", at: at( 0.8 ) )
        XCTAssertTrue( switching.unpublished( "user_3", camera: "TR_a" ), "the old camera taken out after a ready that left it up" )
        XCTAssertFalse( switching.optimizing( "user_3" ) )

        XCTAssertFalse( switching.muted( "user_4" ) )
        XCTAssertFalse( switching.unpublished( "user_4", camera: "TR_a" ) )
    }

    func testThePeoplesModelSaysItUntilANewCameraArrives() {
        var switching = CameraSwitch()
        XCTAssertFalse( switching.awaiting( "user_9", camera: "TR_old" ), "nothing said, nothing up" )
        _ = switching.heard( "optimizing", from: "user_9", camera: "TR_old", at: at( 0 ) )
        XCTAssertTrue( switching.awaiting( "user_9", camera: "TR_old" ), "the old camera still here" )
        XCTAssertTrue( switching.awaiting( "user_9", camera: nil ), "no camera in between: away, not off" )
        XCTAssertFalse( switching.awaiting( "user_9", camera: "TR_new" ), "a new camera has arrived" )
        // A screen holds on past that, to the frame that ends it.
        XCTAssertTrue( switching.optimizing( "user_9" ) )
    }

    func testTheFailsafeRunsFromTheMovesFirstWord() {
        var switching = CameraSwitch()
        switching.failsafe = CameraSwitch.failsafe( tune: 4 )
        _ = switching.heard( "optimizing", from: "user_3", camera: "TR_a", at: at( 0 ) )
        XCTAssertEqual( switching.nextExpiry(), at( 4 ) )

        // Said again: nothing new, its first word's camera and time kept.
        XCTAssertFalse( switching.heard( "optimizing", from: "user_3", camera: nil, at: at( 3 ) ) )
        XCTAssertEqual( switching.from( "user_3" ), "TR_a" )
        XCTAssertEqual( switching.nextExpiry(), at( 4 ) )
        XCTAssertEqual( switching.expire( at: at( 3.9 ) ), [] )
        XCTAssertEqual( switching.expire( at: at( 4 ) ), [ "user_3" ] )
        XCTAssertFalse( switching.optimizing( "user_3" ) )

        // A peer repeating itself can't keep it up, nor put up again a move a frame ended.
        _ = switching.heard( "optimizing", from: "user_7", camera: "TR_a", at: at( 10 ) )
        for second in 11 ... 13 { XCTAssertFalse( switching.heard( "optimizing", from: "user_7", camera: "TR_a", at: at( Double( second ) ) ) ) }
        XCTAssertEqual( switching.expire( at: at( 14 ) ), [ "user_7" ] )
        _ = switching.heard( "optimizing", from: "user_8", camera: "TR_a", at: at( 20 ) )
        _ = switching.shown( "user_8", camera: "TR_b" )
        XCTAssertFalse( switching.heard( "optimizing", from: "user_8", camera: "TR_b", at: at( 21 ) ) )
        XCTAssertFalse( switching.optimizing( "user_8" ) )

        // A new move after its `ready`, or after the failsafe.
        _ = switching.heard( "ready", from: "user_8", camera: "TR_b", at: at( 22 ) )
        XCTAssertTrue( switching.heard( "optimizing", from: "user_8", camera: "TR_b", at: at( 23 ) ) )
        XCTAssertEqual( switching.nextExpiry(), at( 27 ) )
    }

    func testAReadyWithNothingUpAndSomeoneLeaving() {
        var switching = CameraSwitch()
        XCTAssertFalse( switching.heard( "ready", from: "user_5", camera: "TR_x", at: at( 0 ) ) )
        XCTAssertFalse( switching.optimizing( "user_5" ) )
        _ = switching.heard( "optimizing", from: "user_6", camera: "TR_a", at: at( 0 ) )
        switching.left( "user_6" )
        XCTAssertFalse( switching.optimizing( "user_6" ) )
        _ = switching.heard( "optimizing", from: "user_2", camera: nil, at: at( 0 ) )
        XCTAssertTrue( switching.shown( "user_2", camera: "TR_any" ), "with no old camera any camera's frame ends it" )
    }

    // MARK: The group call that keeps it

    private func group() -> ( Realtime, GroupCall ) {
        let rt = Realtime( RealtimeOptions( app: "app_test", endpoint: URL( string: "https://shop.example/api/realtime" )! ) )
        return ( rt, GroupCall( owner: rt.calls, name: "room", link: nil, key: nil, microphone: false, camera: false ) )
    }

    func testAGroupCallHearsTheWordAndTellsItsPeople() {
        let ( rt, call ) = group()
        var told = 0
        call.onPeople { told += 1 }

        call.heardCameraSwitch( "optimizing", from: "user_9", camera: "TR_old" )
        XCTAssertEqual( told, 1, "the people are read again" )
        XCTAssertTrue( call.cameraSwitch( of: "user_9" ).pending )
        XCTAssertEqual( call.cameraSwitch( of: "user_9" ).from, "TR_old" )

        // Said again, and `ready`: the same switch, nobody told twice.
        call.heardCameraSwitch( "optimizing", from: "user_9", camera: nil )
        call.heardCameraSwitch( "ready", from: "user_9", camera: "TR_new" )
        XCTAssertEqual( told, 1 )
        XCTAssertEqual( call.cameraSwitch( of: "user_9" ).from, "TR_old" )
        XCTAssertFalse( call.cameraSwitch( of: "user_8" ).pending, "only the one who said it" )

        // The frame its ear hears ends it, and tells the people.
        call.cameraDrew( "user_9", camera: "TR_new" )
        XCTAssertFalse( call.cameraSwitch( of: "user_9" ).pending )
        XCTAssertEqual( told, 2 )
        _ = rt
    }

    func testAGroupCallEndsASwitchWhenTheCameraGoesOff() {
        let ( rt, call ) = group()
        call.heardCameraSwitch( "optimizing", from: "user_1", camera: "TR_a" )
        call.cameraWentOff( "user_1", camera: "TR_a", muted: false )
        XCTAssertTrue( call.cameraSwitch( of: "user_1" ).pending, "the old camera going is the move" )
        call.cameraWentOff( "user_1", camera: nil, muted: true )
        XCTAssertFalse( call.cameraSwitch( of: "user_1" ).pending, "muted: turned off" )
        _ = rt
    }

    func testAGroupCallEndsASwitchAtItsFailsafeAndHearsNothingOnceOver() {
        let ( rt, call ) = group()
        var told = 0
        call.onPeople { told += 1 }

        // Said eleven seconds ago: past its failsafe as soon as it is looked at.
        call.heardCameraSwitch( "optimizing", from: "user_3", camera: "TR_a", at: Date().addingTimeInterval( -11 ) )
        XCTAssertFalse( call.cameraSwitch( of: "user_3" ).pending )
        XCTAssertEqual( told, 2, "up, then down" )

        call.finish( "left" )
        call.heardCameraSwitch( "optimizing", from: "user_4", camera: "TR_b" )
        XCTAssertFalse( call.cameraSwitch( of: "user_4" ).pending, "an ended call hears nothing" )
        _ = rt
    }

    func testLeavingFromAnotherThreadEndsTheCallOnTheMainQueue() {
        let ( rt, call ) = group()
        let ended = expectation( description: "ended" )
        call.onEnded { reason in
            XCTAssertTrue( Thread.isMainThread, "its handlers on the main queue" )
            XCTAssertEqual( reason, "left" )
            ended.fulfill()
        }
        // A switch up, so its failsafe's look is armed when the call ends.
        call.heardCameraSwitch( "optimizing", from: "user_9", camera: "TR_old" )

        DispatchQueue.global().async { call.leave() }
        wait( for: [ ended ], timeout: 5 )
        XCTAssertEqual( call.state, .ended )
        _ = rt
    }

    func testSomeoneNotChangingIsNotOptimizing() {
        let person = GroupPerson( identity: "user_1", user: "1", info: .null, camera: true, microphone: true, speaking: false, screen: false, publish: true )
        XCTAssertFalse( person.optimizing, "the field defaults to false" )
    }
}
