import XCTest
@testable import WordPlusRealtime
@testable import WordPlusRealtimeCalls

/// The short ways in, in the words the browser has them: `rt.call()`, `rt.groupCall()`, `rt.stream()`, and a stream's
/// `remove()` beside `kick()`. They ask the app's calls route what the long ways ask. With no server, so a refusal there is
/// as far as each goes.
final class ShortWaysTests: XCTestCase {
    private func code( _ run: () async throws -> Void ) async -> String? {
        do {
            try await run()
            return nil
        } catch let error as CallError {
            return error.code
        } catch {
            return "\( error )"
        }
    }

    @MainActor
    func testEachAsksTheCallsRouteWhatItsLongWayAsks() async {
        let rt = Realtime( RealtimeOptions( app: "app_test", endpoint: URL( string: "https://shop.example/api/realtime" )! ) )
        var bodies: [ [ String: JSONValue ] ] = []
        rt.calls.routeAsked = { body in
            bodies.append( body )
            return ( 200, .object( [ "denied": .string( "forbidden" ) ] ) )
        }

        let placed = await code { _ = try await rt.call( "support:34:42", to: "34", type: .audio ) }
        let joined = await code { _ = try await rt.groupCall( "meeting:daily", type: .audio ) }
        let watched = await code { _ = try await rt.stream( "show:42", video: false ) }

        XCTAssertEqual( placed, "forbidden" )
        XCTAssertEqual( joined, "forbidden" )
        XCTAssertEqual( watched, "forbidden" )
        XCTAssertEqual( bodies[ 0 ][ "call" ], "support:34:42" )
        XCTAssertEqual( bodies[ 0 ][ "to" ], .number( 34 ) )
        XCTAssertEqual( bodies[ 0 ][ "type" ], "audio" )
        XCTAssertEqual( bodies[ 1 ][ "room" ], "meeting:daily" )
        XCTAssertEqual( bodies[ 2 ][ "stream" ], "show:42" )
    }
}
