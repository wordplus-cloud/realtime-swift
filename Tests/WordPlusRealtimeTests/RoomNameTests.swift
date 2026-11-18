import Foundation
import XCTest
@testable import WordPlusRealtime

/// A room of two people by a name with `{pair}`, as `rt.join( 'chat:{pair}', { with: 34 } )` is on the web: both of them
/// name the same room.
final class RoomNameTests: XCTestCase {
    private var apps: [Realtime] = []

    private func app(_ user: String?) -> Realtime {
        let identity = user.map { (id: String) -> Identity in
            let claims = Data("{\"sub\":\"\(id)\"}".utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return Identity(token: "x.\(claims).y", exp: Date().timeIntervalSince1970 + 3600)
        }
        let rt = Realtime(RealtimeOptions(app: "s1", endpoint: URL(string: "https://routes.test/api/realtime")!, identity: identity))
        rt.socketAsked = FakeSocket(rt)
        apps.append(rt)
        return rt
    }

    override func tearDown() {
        apps.forEach { $0.close() }
        apps = []
        super.tearDown()
    }

    func testBothPeopleNameTheSameRoomTheSmallerIdFirst() throws {
        XCTAssertEqual(try app("42").join("chat:{pair}", with: "34").name, "chat:34:42")
        XCTAssertEqual(try app("34").join("chat:{pair}", with: "42").name, "chat:34:42")
        XCTAssertEqual(try app("9").join("chat:{pair}", with: "10").name, "chat:9:10")
        XCTAssertEqual(try app("user_b").join("chat:{pair}", with: "user_a").name, "chat:user_a:user_b")
    }

    func testTheRoomIsFoundAndLeftByTheSameWords() throws {
        let rt = app("42")
        let room = try rt.join("chat:{pair}", with: "34")

        XCTAssertTrue(try rt.room("chat:{pair}", with: "34") === room)

        try rt.leave("chat:{pair}", with: "34")
        rt.queue.sync {}
        XCTAssertNil(rt.room("chat:34:42"))
    }

    func testAppWithNoUserIsRefused() {
        XCTAssertThrowsError(try app(nil).join("chat:{pair}", with: "34")) { error in
            XCTAssertEqual((error as? RealtimeError)?.code, "no_identity")
        }
    }

    func testAnyOtherNameIsAsItIs() throws {
        XCTAssertEqual(try app(nil).join("chat:7", with: "34").name, "chat:7")
    }
}
