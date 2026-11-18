import LiveKit
import XCTest
@testable import WordPlusRealtime
@testable @_spi(WordPlusUI) import WordPlusRealtimeCalls

/// A host's acts in a group call, through the app's calls route, as the browser's group calls send them
/// (@wordplus/realtime-client 952f54f, its test/sdk-calls.test.ts) and the server packages take them (`moderate`): the
/// request's body, the answer, the refusals by their code, and the host as the room's token names it. With no server.
final class ModerationTests: XCTestCase {
    /// What the calls route was asked, in order.
    private final class Asked {
        var bodies: [ [ String: JSONValue ] ] = []
    }

    private func group( moderated: Bool = true, answer: @escaping ( [ String: JSONValue ] ) -> ( Int, JSONValue? ) ) -> ( Realtime, GroupCall, Asked ) {
        let rt = Realtime( RealtimeOptions( app: "app_test", endpoint: URL( string: "https://shop.example/api/realtime" )! ) )
        let asked = Asked()
        rt.calls.routeAsked = { body in
            asked.bodies.append( body )
            return answer( body )
        }
        let call = GroupCall( owner: rt.calls, name: "meeting:7", link: nil, key: nil, microphone: false, camera: false, moderated: moderated )
        return ( rt, call, asked )
    }

    private func code( _ run: () async throws -> Bool ) async -> String? {
        do {
            _ = try await run()
            return nil
        } catch let error as CallError {
            return error.code
        } catch {
            return "\( error )"
        }
    }

    func testAHostsActsGoThroughTheCallsRoute() async throws {
        let ( rt, call, asked ) = group { body in ( 200, .object( [ "done": .bool( body[ "act" ] != .string( "speak" ) ) ] ) ) }
        defer { withExtendedLifetime( rt ) {} }

        let muted = try await call.moderate( .mute, user: "42" )
        let spoke = try await call.moderate( .speak, user: "auth0|5f7c8e" )
        let listened = try await call.moderate( .listen, user: "42" )
        let removed = try await call.moderate( .remove, user: "42" )
        XCTAssertEqual( [ muted, spoke, listened, removed ], [ true, false, true, true ] )

        // An id of digits as the number, any other as its text, as the relay and the server packages read them.
        XCTAssertEqual( asked.bodies, [
            [ "moderate": .string( "meeting:7" ), "act": .string( "mute" ), "user": .number( 42 ) ],
            [ "moderate": .string( "meeting:7" ), "act": .string( "speak" ), "user": .string( "auth0|5f7c8e" ) ],
            [ "moderate": .string( "meeting:7" ), "act": .string( "listen" ), "user": .number( 42 ) ],
            [ "moderate": .string( "meeting:7" ), "act": .string( "remove" ), "user": .number( 42 ) ],
        ] )
    }

    func testEachActHasAWordOfItsOwn() async throws {
        let ( rt, call, asked ) = group { _ in ( 200, .object( [ "done": .bool( true ) ] ) ) }
        defer { withExtendedLifetime( rt ) {} }

        _ = try await call.mute( "42" )
        _ = try await call.remove( "42" )
        _ = try await call.letSpeak( "42" )
        _ = try await call.makeListener( "42" )
        _ = try await call.spotlightOn( "42" )
        _ = try await call.spotlightOff( "42" )
        _ = try await call.spotlightOff()

        XCTAssertEqual( asked.bodies.map { $0[ "act" ] }, [ "mute", "remove", "speak", "listen", "spotlight", "unspotlight", "unspotlight" ].map { .string( $0 ) } )
    }

    func testTheSpotlightNamesUsersAsTheActsTakeThem() {
        XCTAssertEqual( GroupCall.users( of: [ "user_34", "user_auth0|5f7c8e", "not-a-user" ] ), [ "34", "auth0|5f7c8e" ] )
    }

    func testAConnectionIsRatedInTheWordsOfACallBetweenTwo() {
        XCTAssertEqual( CallConnectionQuality( ConnectionQuality.excellent ), .excellent )
        XCTAssertEqual( CallConnectionQuality( ConnectionQuality.good ), .good )
        XCTAssertEqual( CallConnectionQuality( ConnectionQuality.poor ), .poor )
        XCTAssertEqual( CallConnectionQuality( ConnectionQuality.lost ), .lost )
        XCTAssertEqual( CallConnectionQuality( ConnectionQuality.unknown ), .unknown )
    }

    func testACallsNameIsFilledInSoEitherSideNamesTheSameCall() throws {
        XCTAssertEqual( try CallName.named( "support:{pair}", me: "42", id: "34" ), "support:34:42" )
        XCTAssertEqual( try CallName.named( "support:{pair}", me: "34", id: "42" ), "support:34:42" )
        // As numbers when both are, 9 before 10, and as text otherwise.
        XCTAssertEqual( try CallName.named( "support:{pair}", me: "10", id: "9" ), "support:9:10" )
        XCTAssertEqual( try CallName.named( "support:{pair}", me: "user_b", id: "user_a" ), "support:user_a:user_b" )
        XCTAssertEqual( try CallName.named( "from:{me}:to:{id}", me: "42", id: "34" ), "from:42:to:34" )
        // A name with no template is as it is, with no user wanted.
        XCTAssertEqual( try CallName.named( "support:34:42", me: nil, id: "34" ), "support:34:42" )
        XCTAssertEqual( try CallName.named( "ring:{id}", me: nil, id: "34" ), "ring:34" )
        XCTAssertThrowsError( try CallName.named( "support:{pair}", me: nil, id: "34" ) ) { error in
            XCTAssertEqual( ( error as? CallError )?.code, "no_identity" )
        }
    }

    func testARefusalComesBackByItsCode() async {
        let ( rt, refused, _ ) = group { _ in ( 200, .object( [ "denied": .string( "forbidden" ) ] ) ) }
        let ( _, unauthorized, _ ) = group { _ in ( 403, nil ) }
        let ( _, unanswered, _ ) = group { _ in ( 200, .object( [ "ok": .bool( true ) ] ) ) }
        let ( _, failing, _ ) = group { _ in ( 500, nil ) }
        defer { withExtendedLifetime( rt ) {} }

        let forbidden = await code { try await refused.moderate( .remove, user: "42" ) }
        let status = await code { try await unauthorized.moderate( .remove, user: "42" ) }
        let server = await code { try await unanswered.moderate( .remove, user: "42" ) }
        let failed = await code { try await failing.moderate( .remove, user: "42" ) }
        XCTAssertEqual( forbidden, "forbidden" )
        XCTAssertEqual( status, "forbidden" )
        XCTAssertEqual( server, "server" )
        XCTAssertEqual( failed, "auth_failed" )
    }

    func testOnlyAGroupCallTheServerNamesIsModerated() async {
        // A call that became a group call, or the room a call moved to: nothing for the calls route to ask a rule about.
        let ( rt, call, asked ) = group( moderated: false ) { _ in ( 200, .object( [ "done": .bool( true ) ] ) ) }
        defer { withExtendedLifetime( rt ) {} }

        let refused = await code { try await call.moderate( .mute, user: "42" ) }
        XCTAssertEqual( refused, "not_moderated" )
        XCTAssertTrue( asked.bodies.isEmpty )
    }

    func testAHostSpotlightsSomeoneThemselvesTooAndEveryoneOutWithNobodyNamed() async throws {
        // As @wordplus/realtime-client 1.0.64 (9e757f5) and the server packages take them (realtime-js 6ecdf02).
        let ( rt, call, asked ) = group { _ in ( 200, .object( [ "done": .bool( true ) ] ) ) }
        defer { withExtendedLifetime( rt ) {} }

        _ = try await call.moderate( .spotlight, user: "42" )
        _ = try await call.moderate( .spotlight, user: "1" )
        _ = try await call.moderate( .unspotlight, user: "42" )
        _ = try await call.moderate( .unspotlight, user: nil )
        XCTAssertEqual( asked.bodies, [
            [ "moderate": .string( "meeting:7" ), "act": .string( "spotlight" ), "user": .number( 42 ) ],
            [ "moderate": .string( "meeting:7" ), "act": .string( "spotlight" ), "user": .number( 1 ) ],
            [ "moderate": .string( "meeting:7" ), "act": .string( "unspotlight" ), "user": .number( 42 ) ],
            [ "moderate": .string( "meeting:7" ), "act": .string( "unspotlight" ), "user": .null ],
        ] )

        // Nobody named is for taking everyone out alone: refused here, nothing asked.
        asked.bodies = []
        let spotlight = await code { try await call.moderate( .spotlight, user: nil ) }
        let mute = await code { try await call.moderate( .mute, user: nil ) }
        XCTAssertEqual( spotlight, "bad_request" )
        XCTAssertEqual( mute, "bad_request" )
        XCTAssertTrue( asked.bodies.isEmpty )
    }

    func testAFifthPersonIsTheRoutesRefusal() async {
        let ( rt, call, _ ) = group { _ in ( 200, .object( [ "denied": .string( "spotlight_full" ) ] ) ) }
        defer { withExtendedLifetime( rt ) {} }

        let full = await code { try await call.moderate( .spotlight, user: "42" ) }
        XCTAssertEqual( full, "spotlight_full" )
    }

    func testTheSpotlightIsTheRoomsMetadata() {
        // Strings alone, once each, in their order, at most four, as the browser's spotlightOf() reads them.
        XCTAssertEqual( GroupCall.spotlight( of: #"{"spotlight":["user_4","user_9","user_2","user_4","",5,"user_5","user_6"]}"# ), [ "user_4", "user_9", "user_2", "user_5" ] )
        XCTAssertEqual( GroupCall.spotlight( of: #"{"spotlight":[],"other":1}"# ), [] )
        XCTAssertEqual( GroupCall.spotlight( of: #"{"spotlight":"user_4"}"# ), [] )
        XCTAssertEqual( GroupCall.spotlight( of: #"{"layout":"grid"}"# ), [] )
        XCTAssertEqual( GroupCall.spotlight( of: "not json" ), [] )
        XCTAssertEqual( GroupCall.spotlight( of: "" ), [] )
        XCTAssertEqual( GroupCall.spotlight( of: nil ), [] )

        // A room not joined yet has none.
        let ( rt, call, _ ) = group { _ in ( 200, nil ) }
        defer { withExtendedLifetime( rt ) {} }
        XCTAssertEqual( call.spotlight, [] )
    }

    func testAGroupCallIsRecordedAndStoppedThroughTheCallsRoute() async throws {
        // As @wordplus/realtime-client 1.0.65 (c44a6fb) asks it and the server packages take it (realtime-js dd6e20d).
        let ( rt, call, asked ) = group { body in
            body[ "record" ] == .string( "start" )
                ? ( 200, .object( [ "recording": .object( [ "id": .string( "rec_0123456789" ), "state": .string( "recording" ) ] ) ] ) )
                : ( 200, .object( [ "recording": .object( [ "id": .string( "rec_0123456789" ), "state": .string( "stopping" ) ] ) ] ) )
        }
        defer { withExtendedLifetime( rt ) {} }

        let started = try await call.startRecording()
        let stopped = try await call.stopRecording( "rec_0123456789" )
        XCTAssertEqual( started, GroupRecording( id: "rec_0123456789", state: "recording" ) )
        XCTAssertEqual( stopped, GroupRecording( id: "rec_0123456789", state: "stopping" ) )
        XCTAssertEqual( asked.bodies, [
            [ "call": .string( "meeting:7" ), "record": .string( "start" ) ],
            [ "call": .string( "meeting:7" ), "record": .string( "stop" ), "recording": .string( "rec_0123456789" ) ],
        ] )
    }

    func testTheRoomsFlagSaysARecordingRunsAndWhoIsOfferedIt() async {
        let ( rt, call, _ ) = group { _ in ( 200, nil ) }
        let ( _, unnamed, _ ) = group( moderated: false ) { _ in ( 200, nil ) }
        defer { withExtendedLifetime( rt ) {} }

        // Nothing yet, and nobody who is not the host is offered it.
        XCTAssertFalse( call.isRecording )
        XCTAssertFalse( call.canRecord )
        XCTAssertFalse( unnamed.canRecord )

        let heard = expectation( description: "the room's flag is heard" )
        var told: [ Bool ] = []
        let listener = call.onRecording { on in
            told.append( on )
            heard.fulfill()
        }
        call.room( call.liveKitRoom, didUpdateIsRecording: true )
        await fulfillment( of: [ heard ], timeout: 5 )
        XCTAssertEqual( told, [ true ] )

        // Taken off, it hears no more.
        call.off( listener )
        call.room( call.liveKitRoom, didUpdateIsRecording: false )
        await Task.yield()
        XCTAssertEqual( told, [ true ] )
    }

    func testARecordingRefusedComesBackByItsCode() async {
        let ( rt, spent, _ ) = group { _ in ( 200, .object( [ "denied": .string( "no_credits" ) ] ) ) }
        let ( _, recording, _ ) = group { _ in ( 200, .object( [ "denied": .string( "already_recording" ) ] ) ) }
        let ( _, member, _ ) = group { _ in ( 200, .object( [ "denied": .string( "forbidden" ) ] ) ) }
        let ( _, unanswered, _ ) = group { _ in ( 200, .object( [ "recording": .object( [ "state": .string( "recording" ) ] ) ] ) ) }
        let ( _, unnamed, asked ) = group( moderated: false ) { _ in ( 200, nil ) }
        defer { withExtendedLifetime( rt ) {} }

        func code( _ run: () async throws -> GroupRecording ) async -> String? {
            do {
                _ = try await run()
                return nil
            } catch {
                return ( error as? CallError )?.code
            }
        }
        let credits = await code { try await spent.startRecording() }
        let already = await code { try await recording.startRecording() }
        let forbidden = await code { try await member.stopRecording( "rec_0123456789" ) }
        let server = await code { try await unanswered.startRecording() }
        let notModerated = await code { try await unnamed.startRecording() }
        XCTAssertEqual( [ credits, already, forbidden, server, notModerated ], [ "no_credits", "already_recording", "forbidden", "server", "not_moderated" ] )
        XCTAssertTrue( asked.bodies.isEmpty )
    }

    @MainActor
    func testARoomEndsWithWhatTheAppsServerDid() async {
        // As the browser's group calls say them (@wordplus/realtime-client a738a57, disconnectedBy).
        XCTAssertEqual( GroupCall.endReason( .participantRemoved ), "removed" )
        XCTAssertEqual( GroupCall.endReason( .roomDeleted ), "closed" )
        XCTAssertEqual( GroupCall.endReason( .serverShutdown ), "disconnected" )
        XCTAssertEqual( GroupCall.endReason( nil ), "disconnected" )

        // The room's word reaching `onEnded`.
        let ( rt, call, _ ) = group { _ in ( 200, nil ) }
        defer { withExtendedLifetime( rt ) {} }
        let ended = expectation( description: "ended" )
        call.onEnded { reason in
            XCTAssertEqual( reason, "removed" )
            ended.fulfill()
        }
        call.room( LiveKit.Room(), didDisconnectWithError: LiveKitError( .participantRemoved ) )
        await fulfillment( of: [ ended ], timeout: 5 )
        XCTAssertEqual( call.endReason, "removed" )
    }

    func testTheHostIsTheRoomTokensAdmin() {
        func token( _ claims: [ String: Any ] ) -> String {
            let payload = try! JSONSerialization.data( withJSONObject: claims ).base64EncodedString()
                .replacingOccurrences( of: "+", with: "-" ).replacingOccurrences( of: "/", with: "_" ).replacingOccurrences( of: "=", with: "" )
            return "eyJhbGciOiJIUzI1NiJ9." + payload + ".c2lnbmF0dXJl"
        }

        XCTAssertTrue( GroupCall.admin( of: token( [ "sub": "user_1", "video": [ "room": "meeting:7", "roomJoin": true, "roomAdmin": true ] ] ) ) )
        XCTAssertFalse( GroupCall.admin( of: token( [ "sub": "user_2", "video": [ "room": "meeting:7", "roomJoin": true ] ] ) ) )
        XCTAssertFalse( GroupCall.admin( of: token( [ "sub": "user_2" ] ) ) )
        XCTAssertFalse( GroupCall.admin( of: "not a token" ) )

        // Before its room's token, nobody hosts it.
        let ( rt, call, _ ) = group { _ in ( 200, nil ) }
        defer { withExtendedLifetime( rt ) {} }
        XCTAssertEqual( call.can, GroupPermissions( publish: true, subscribe: true, admin: false ) )
    }
}
