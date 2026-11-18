import LiveKit
import XCTest
@testable import WordPlusRealtime
@testable @_spi(WordPlusUI) import WordPlusRealtimeCalls

/// A group call's moderation as Better Messages runs it, for apps (@wordplus/realtime-client's launch/moderation, 75ffaff,
/// its test/group-call-moderation.test.ts): what the call offers, each new act's request to the app's calls route and the
/// refusals before anything is sent, hands, the room's rules and hands from its metadata, a held microphone, asks, the
/// tiles kept for those who may come back and the stalled ones, and a refused join's code. With no server.
final class GroupModerationTests: XCTestCase {
    private final class Asked {
        var bodies: [ [ String: JSONValue ] ] = []
    }

    private func group( acts: [ CallAct ]? = nil, proofs: GroupProofs? = nil, answer: @escaping ( [ String: JSONValue ] ) -> ( Int, JSONValue? ) = { _ in ( 200, .object( [ "done": .bool( true ) ] ) ) } ) -> ( Realtime, GroupCall, Asked ) {
        let rt = Realtime( RealtimeOptions( app: "app_test", endpoint: URL( string: "https://shop.example/api/realtime" )! ) )
        let asked = Asked()
        rt.calls.routeAsked = { body in
            asked.bodies.append( body )
            return answer( body )
        }
        let call = GroupCall( owner: rt.calls, name: "meeting:7", link: nil, key: nil, microphone: false, camera: false, moderated: true, proofs: proofs, acts: acts )
        return ( rt, call, asked )
    }

    private func code( _ run: () async throws -> Any ) async -> String? {
        do {
            _ = try await run()
            return nil
        } catch let error as CallError {
            return error.code
        } catch {
            return "\( error )"
        }
    }

    private func token( _ claims: [ String: Any ] ) -> String {
        func part( _ object: Any ) -> String {
            let data = ( try? JSONSerialization.data( withJSONObject: object ) ) ?? Data()
            return data.base64EncodedString().replacingOccurrences( of: "+", with: "-" ).replacingOccurrences( of: "/", with: "_" ).replacingOccurrences( of: "=", with: "" )
        }
        return part( [ "alg": "HS256" ] ) + "." + part( claims ) + ".sig"
    }

    // MARK: What the call offers

    func testACallOffersWhatBothTheServerAndThePackageName() {
        let all = CallAct.allCases.map( \.rawValue )
        XCTAssertEqual( CallAct.allCases.map( \.rawValue ), [ "remove", "ban", "listen", "speak", "mute", "hold_mic", "release_mic", "rules", "hand", "ask", "end", "spotlight" ] )
        XCTAssertEqual( CallAct.offered( server: all, app: all ), CallAct.allCases )
        // In the protocol's order, whatever order each names them in.
        XCTAssertEqual( CallAct.offered( server: [ "end", "remove", "rules", "record" ], app: [ "rules", "end", "remove", "hand" ] ), [ .remove, .rules, .end ] )
        // A 1.1.0-era server or package names none: today's five.
        XCTAssertEqual( CallAct.offered( server: nil, app: all ), [ .remove, .listen, .speak, .mute, .spotlight ] )
        XCTAssertEqual( CallAct.offered( server: all, app: nil ), CallAct.base )
        XCTAssertEqual( CallAct.offered( server: all, app: [] ), [] )
    }

    func testARoomTheServerDoesntNameOffersNothingAndAnOldOneTheFive() {
        let ( rt, old, _ ) = group()
        defer { withExtendedLifetime( rt ) {} }
        XCTAssertEqual( old.acts, CallAct.base )
        let room = GroupCall( owner: rt.calls, name: "call:1", link: nil, key: nil, microphone: false, camera: false, acts: CallAct.allCases )
        XCTAssertEqual( room.acts, [] )
    }

    func testAnActTheCallDoesntOfferIsRefusedBeforeAnythingIsSent() async {
        let ( rt, call, asked ) = group()
        defer { withExtendedLifetime( rt ) {} }

        let ban = await code { try await call.ban( "42", minutes: 60 ) }
        let hold = await code { try await call.holdMic( "42" ) }
        let release = await code { try await call.releaseMic( "42" ) }
        let rules = await code { try await call.setRules( locked: true ) }
        let ask = await code { try await call.askToTurnOn( "42", devices: [ .camera ] ) }
        let end = await code { try await call.end() }
        let hand = await code { try await call.raiseHand() }
        XCTAssertEqual( [ ban, hold, release, rules, ask, end, hand ], Array( repeating: "not_offered", count: 7 ) )
        XCTAssertTrue( asked.bodies.isEmpty )

        // What the five of before still are.
        let removed = await code { try await call.remove( "42" ) }
        XCTAssertNil( removed )
        XCTAssertEqual( asked.bodies.count, 1 )
    }

    // MARK: Each act's request

    func testEachNewActGoesThroughTheCallsRouteAsTheWebSendsIt() async throws {
        let ( rt, call, asked ) = group( acts: CallAct.allCases, proofs: GroupProofs( host: .object( [ "until": .number( 9 ), "proof": .string( "h" ) ] ), recorder: nil ) ) { body in
            switch body[ "act" ]?.string {
            case "ask": return ( 200, .object( [ "done": .bool( true ), "id": .string( "ask-1" ) ] ) )
            case "rules": return ( 200, .object( [ "done": .bool( true ), "rules": .object( [ "locked": .bool( true ) ] ) ] ) )
            default: return ( 200, .object( [ "done": .bool( true ) ] ) )
            }
        }
        defer { withExtendedLifetime( rt ) {} }

        _ = try await call.ban( "42", minutes: 90 )
        _ = try await call.ban( "42" )
        _ = try await call.unban( "42" )
        _ = try await call.holdMic( "42" )
        _ = try await call.releaseMic( "42" )
        let rules = try await call.setRules( mode: .broadcast, locked: true )
        let id = try await call.askToTurnOn( "42", devices: [ .camera, .microphone, .camera ] )
        _ = try await call.end()

        XCTAssertEqual( rules, RoomRules( mode: .broadcast, locked: true, muted: false ) )
        XCTAssertEqual( id, "ask-1" )
        let host: JSONValue = .object( [ "until": .number( 9 ), "proof": .string( "h" ) ] )
        func body( _ act: String, _ user: JSONValue, _ more: [ String: JSONValue ] = [:] ) -> [ String: JSONValue ] {
            [ "moderate": .string( "meeting:7" ), "act": .string( act ), "user": user, "host": host ].merging( more ) { _, new in new }
        }
        XCTAssertEqual( asked.bodies, [
            body( "ban", .number( 42 ), [ "minutes": .number( 90 ) ] ),
            body( "ban", .number( 42 ) ),
            body( "unban", .number( 42 ) ),
            body( "hold_mic", .number( 42 ) ),
            body( "release_mic", .number( 42 ) ),
            body( "rules", .null, [ "rules": .object( [ "mode": .string( "broadcast" ), "locked": .bool( true ) ] ) ] ),
            body( "ask", .number( 42 ), [ "devices": .array( [ .string( "camera" ), .string( "microphone" ) ] ) ] ),
            body( "end", .null ),
        ] )
    }

    func testRulesAndEndNameNobodyAndAnAskNeedsADevice() async {
        let ( rt, call, asked ) = group( acts: CallAct.allCases )
        defer { withExtendedLifetime( rt ) {} }

        let rules = await code { try await call.moderate( .rules, user: "42" ) }
        let end = await code { try await call.moderate( .end, user: "42" ) }
        let ban = await code { try await call.moderate( .ban, user: nil ) }
        let ask = await code { try await call.askToTurnOn( "42", devices: [] ) }
        XCTAssertEqual( [ rules, end, ban, ask ], [ "bad_request", "bad_request", "bad_request", "bad_request" ] )
        XCTAssertTrue( asked.bodies.isEmpty )
    }

    func testTheRoutesRefusalsComeBackByTheirCode() async {
        let ( rt, call, _ ) = group( acts: CallAct.allCases ) { body in
            body[ "act" ] == .string( "ask" ) ? ( 200, .object( [ "denied": .string( "asked_recently" ) ] ) ) : ( 200, .object( [ "denied": .string( "forbidden" ) ] ) )
        }
        defer { withExtendedLifetime( rt ) {} }

        let ask = await code { try await call.askToTurnOn( "42", devices: [ .microphone ] ) }
        let ban = await code { try await call.ban( "1" ) }
        XCTAssertEqual( ask, "asked_recently" )
        XCTAssertEqual( ban, "forbidden" )
    }

    // MARK: Hands

    func testHandsGoAsTheirOwnRequestWithTheTokensProofs() async throws {
        let member: JSONValue = .object( [ "until": .number( 5 ), "proof": .string( "m" ) ] )
        let ( rt, call, asked ) = group( acts: [ .hand ], proofs: GroupProofs( host: nil, recorder: nil, member: member ) )
        defer { withExtendedLifetime( rt ) {} }

        _ = try await call.raiseHand()
        _ = try await call.lowerHand()
        _ = try await call.lowerHand( of: "42" )
        _ = try await call.lowerAllHands()
        XCTAssertEqual( asked.bodies, [
            [ "hand": .string( "meeting:7" ), "up": .bool( true ), "member": member ],
            [ "hand": .string( "meeting:7" ), "up": .bool( false ), "member": member ],
            [ "hand": .string( "meeting:7" ), "up": .bool( false ), "user": .number( 42 ), "member": member ],
            [ "hand": .string( "meeting:7" ), "up": .bool( false ), "user": .null, "member": member ],
        ] )
    }

    func testTheRoomsRulesAndHandsAreItsMetadata() {
        XCTAssertEqual( RoomRules.of( nil ), RoomRules() )
        XCTAssertEqual( RoomRules.of( "{\"spotlight\":[\"user_1\"]}" ), RoomRules() )
        XCTAssertEqual( RoomRules.of( "{\"rules\":{\"mode\":\"broadcast\",\"locked\":true,\"muted\":1}}" ), RoomRules( mode: .broadcast, locked: true, muted: true ) )
        XCTAssertEqual( RoomRules.of( "{\"rules\":{\"mode\":\"other\",\"locked\":\"1\",\"muted\":false}}" ), RoomRules( mode: .participatory, locked: true, muted: false ) )
        XCTAssertEqual( RoomRules.of( "not json" ), RoomRules() )

        XCTAssertEqual( GroupRoomState.hands( of: "{\"hands\":[\"user_3\",\"user_1\",\"user_3\",\"\",7]}" ), [ "user_3", "user_1" ] )
        XCTAssertEqual( GroupCall.users( of: GroupRoomState.hands( of: "{\"hands\":[\"user_3\",\"ingest\"]}" ) ), [ "3" ] )
        XCTAssertEqual( GroupRoomState.hands( of: nil ), [] )
    }

    // MARK: A held microphone

    func testAHeldMicrophoneIsReadFromTheSourcesOfPermissionsAndTokens() {
        XCTAssertFalse( GroupRoomState.holdsMic( publish: true, sources: [] ) )
        XCTAssertTrue( GroupRoomState.holdsMic( publish: true, sources: [ 1, 3, 4 ] ) )
        XCTAssertFalse( GroupRoomState.holdsMic( publish: true, sources: [ 1, 2 ] ) )
        XCTAssertTrue( GroupRoomState.holdsMic( publish: true, sources: [ "camera", "screen_share" ] ) )
        XCTAssertFalse( GroupRoomState.holdsMic( publish: true, sources: [ "camera", "microphone" ] ) )
        // A listener sends nothing: no microphone of theirs is held.
        XCTAssertFalse( GroupRoomState.holdsMic( publish: false, sources: [ 1 ] ) )
    }

    func testAMicrophoneHeldAsTheAppJoinsStaysOff() throws {
        let ( rt, call, _ ) = group( acts: CallAct.allCases )
        defer { withExtendedLifetime( rt ) {} }

        call.named( by: token( [ "sub": "user_9", "video": [ "canPublish": true, "canPublishSources": [ "camera", "screen_share" ] ] ] ) )
        XCTAssertTrue( call.can.micHeld )
        call.microphone = true
        XCTAssertFalse( call.microphone )
        XCTAssertThrowsError( try call.turnOnMicrophone() ) { XCTAssertEqual( ( $0 as? CallError )?.code, "mic_held" ) }

        // The place's word alone holds it too; a token that leaves it free, nothing.
        let ( _, said, _ ) = group()
        said.named( by: "", micHeld: true )
        XCTAssertTrue( said.can.micHeld )
        let ( _, free, _ ) = group()
        free.named( by: token( [ "sub": "user_9", "video": [ "canPublish": true ] ] ) )
        XCTAssertFalse( free.can.micHeld )
        XCTAssertNoThrow( try free.turnOnMicrophone() )
        XCTAssertTrue( free.microphone )
    }

    func testOnPermissionsSaysWhatTheMediaServerSentWithTheHold() {
        // A listener's first word as it connects is a listener's, never the connecting room's "may publish".
        let listener = GroupCall.permissions(publish: false, subscribe: true, sources: [], admin: false, heldAtJoin: true)
        XCTAssertFalse( listener.publish )
        XCTAssertFalse( listener.micHeld )
        XCTAssertTrue( GroupCall.permissions(publish: true, subscribe: true, sources: [ 1, 3 ], admin: true, heldAtJoin: false).micHeld )
        XCTAssertTrue( GroupCall.permissions(publish: true, subscribe: true, sources: [], admin: false, heldAtJoin: true).micHeld )
        XCTAssertFalse( GroupCall.permissions(publish: true, subscribe: true, sources: [], admin: false, heldAtJoin: false).micHeld )
    }

    // MARK: Asks

    func testAnAskComesFromTheServerAloneAndItsAnswerFromThePersonAsked() {
        let ( rt, call, _ ) = group( acts: CallAct.allCases )
        defer { withExtendedLifetime( rt ) {} }
        var asks: [ TurnOnAsk ] = []
        var answers: [ TurnOnAnswer ] = []
        call.onAsk { asks.append( $0 ) }
        call.onAskAnswer { answers.append( $0 ) }

        let ask = Data( "{\"id\":\"a1\",\"devices\":[\"camera\",\"microphone\",\"camera\",\"screen\"],\"by\":\"user_42\"}".utf8 )
        call.received( ask, from: nil, topic: "realtime-ask" )
        // One a person sent is never an ask.
        call.received( ask, from: "user_5", topic: "realtime-ask" )
        call.received( Data( "{\"id\":\"a2\",\"devices\":[],\"by\":42}".utf8 ), from: nil, topic: "realtime-ask" )
        call.received( Data( "{\"id\":\"a3\",\"devices\":[\"microphone\"],\"by\":42}".utf8 ), from: nil, topic: "realtime-ask" )
        XCTAssertEqual( asks, [ TurnOnAsk( id: "a1", devices: [ .camera, .microphone ], by: "42" ), TurnOnAsk( id: "a3", devices: [ .microphone ], by: "42" ) ] )

        call.received( Data( "{\"id\":\"a1\",\"answer\":\"not_now\"}".utf8 ), from: "user_7", topic: "realtime-ask-answer" )
        call.received( Data( "{\"id\":\"a1\",\"answer\":\"maybe\"}".utf8 ), from: "user_7", topic: "realtime-ask-answer" )
        call.received( Data( "{\"id\":\"a1\",\"answer\":\"on\"}".utf8 ), from: nil, topic: "realtime-ask-answer" )
        XCTAssertEqual( answers, [ TurnOnAnswer( id: "a1", answer: .notNow, from: "7" ) ] )
        XCTAssertEqual( AskAnswer.allCases.map( \.rawValue ), [ "on", "not_now", "blocked", "no_device", "busy" ] )
    }

    // MARK: Those who drop, and stalled media

    func testATileIsKeptFor20SecondsByTheReasonItLeft() {
        let now = Date()
        XCTAssertEqual( CallAway.awayFor( nil, onMesh: true, now: now ), 20 )
        XCTAssertEqual( CallAway.awayFor( 0, onMesh: true, now: now ), 20 )
        // A hang-up on the mesh goes at once; off it it may be a full reconnect.
        XCTAssertEqual( CallAway.awayFor( 1, onMesh: true, now: now ), 0 )
        XCTAssertEqual( CallAway.awayFor( 1, onMesh: false, now: now ), 6 )
        for reason in [ 2, 3, 8, 9 ] { XCTAssertEqual( CallAway.awayFor( reason, onMesh: true, now: now ), 20, "\( reason )" ) }
        // Removed, the room closed, a timeout: gone.
        for reason in [ 4, 5, 6, 7, 10 ] { XCTAssertEqual( CallAway.awayFor( reason, onMesh: true, now: now ), 0, "\( reason )" ) }
        // A bye within 30 s: gone at once.
        XCTAssertEqual( CallAway.awayFor( 9, onMesh: true, byeAt: now.addingTimeInterval( -29 ), now: now ), 0 )
        XCTAssertEqual( CallAway.awayFor( 9, onMesh: true, byeAt: now.addingTimeInterval( -31 ), now: now ), 20 )
    }

    func testSomeoneWhoDropsIsKeptReconnectingAndAByeLetsThemGo() {
        let ( rt, call, _ ) = group()
        defer { withExtendedLifetime( rt ) {} }
        var away: [ GroupPerson ] = []
        call.onPersonAway { away.append( $0 ) }
        let ann = GroupPerson( identity: "user_3", user: "3", info: .object( [ "name": .string( "Ann" ) ] ), camera: true, microphone: true, speaking: true, screen: false, publish: true )

        call.departed( ann, reason: 9 )
        XCTAssertEqual( call.awayIdentities, [ "user_3" ] )
        XCTAssertEqual( away.count, 1 )
        let kept = call.people.first
        XCTAssertEqual( kept?.identity, "user_3" )
        XCTAssertEqual( kept?.reconnecting, true )
        XCTAssertEqual( kept?.camera, false )
        XCTAssertEqual( kept?.microphone, false )
        XCTAssertEqual( kept?.info, ann.info )

        // Their bye: gone now, and a departure soon after goes at once.
        call.heardBye( from: "user_3" )
        XCTAssertEqual( call.awayIdentities, [] )
        XCTAssertTrue( call.people.isEmpty )
        call.departed( ann, reason: 9 )
        XCTAssertEqual( call.awayIdentities, [] )
        XCTAssertEqual( away.count, 1 )

        // Removed: gone at once. Back in the room: theirs again.
        call.departed( GroupPerson( identity: "user_4", user: "4", info: .null, camera: false, microphone: false, speaking: false, screen: false, publish: true ), reason: 4 )
        XCTAssertEqual( call.awayIdentities, [] )
        call.departed( GroupPerson( identity: "user_5", user: "5", info: .null, camera: false, microphone: false, speaking: false, screen: false, publish: true ), reason: 2 )
        call.back( "user_5" )
        XCTAssertEqual( call.awayIdentities, [] )
    }

    func testStalledMediaIsJudgedFromTheMeshsListAsTheWebJudgesIt() {
        let watch = StallWatch()
        let streams: [ StallWatch.Stream ] = [
            .init( who: "user_1", camera: true, id: "TR_c1", expected: true ),
            .init( who: "user_1", camera: false, id: "TR_m1", expected: true ),
            .init( who: "user_2", camera: false, id: "TR_m2", expected: true ),
            .init( who: "user_3", camera: true, id: "TR_c3", expected: false ),
        ]
        // Their camera alone: video.
        XCTAssertEqual( watch.read( streams, dry: [ "TR_c1" ] ), [ "user_1": .some( .video ) ] )
        // Their sound too, and someone who sends sound alone: all. A muted camera that stopped is nothing.
        XCTAssertEqual( watch.read( streams, dry: [ "TR_c1", "TR_m1", "TR_m2", "TR_c3" ] ), [ "user_1": .some( .all ), "user_2": .some( .all ) ] )
        XCTAssertEqual( watch.of( "user_1" ), .all )
        // A microphone stopped under a camera that still comes is nothing.
        XCTAssertEqual( watch.read( streams, dry: [ "TR_m1" ] ), [ "user_1": nil, "user_2": nil ] as [ String: GroupStalled? ] )
        XCTAssertEqual( watch.read( streams, dry: [ "TR_m2" ] ), [ "user_2": .some( .all ) ] )
        XCTAssertEqual( watch.clear(), [ "user_2": nil ] as [ String: GroupStalled? ] )
    }

    // MARK: Refused joins and tokens

    func testARefusedJoinIsTheServersCodeWithWhenABanEnds() {
        let banned = RealtimeCalls.refusedJoin( .object( [ "ok": .bool( false ), "error": .string( "banned" ), "until": .number( 1_800_000_000_000 ) ] ) )
        XCTAssertEqual( banned.code, "banned" )
        XCTAssertEqual( banned.until, Date( timeIntervalSince1970: 1_800_000_000 ) )
        let untilEnd = RealtimeCalls.refusedJoin( .object( [ "ok": .bool( false ), "error": .string( "banned" ) ] ) )
        XCTAssertEqual( untilEnd, CallError( "banned" ) )
        XCTAssertEqual( RealtimeCalls.refusedJoin( .object( [ "ok": .bool( false ), "error": .string( "locked" ) ] ) ).code, "locked" )
        XCTAssertEqual( RealtimeCalls.refusedJoin( nil ).code, "server" )
    }

    func testAGroupCallTokenNamesItsActsAndTheMembersProof() {
        let made = CallTokens.groupCall( base64( [
            "token": "jwt", "room": "meeting:7", "user": 42,
            "member": [ "until": 99, "proof": "member|meeting:7|42|99" ],
            "acts": [ "remove", "hand", "rules" ],
        ] ) )
        XCTAssertEqual( made?.acts, [ "remove", "hand", "rules" ] )
        XCTAssertEqual( made?.proofs.member?[ "proof" ]?.string, "member|meeting:7|42|99" )
        // A token from a package before them: no acts, so today's five.
        let old = CallTokens.groupCall( base64( [ "token": "jwt", "room": "meeting:7" ] ) )
        XCTAssertNil( old?.acts )
        XCTAssertNil( old?.proofs.member )
    }

    private func base64( _ object: [ String: Any ] ) -> String {
        let data = ( try? JSONSerialization.data( withJSONObject: object ) ) ?? Data()
        return data.base64EncodedString().replacingOccurrences( of: "+", with: "-" ).replacingOccurrences( of: "/", with: "_" ).replacingOccurrences( of: "=", with: "" )
    }
}
