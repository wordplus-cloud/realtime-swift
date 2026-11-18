import Foundation
import XCTest
@testable import WordPlusRealtime

/// A room this user is out of forgets who is in it, as the browser's (realtime-client a738a57, its test/rooms.test.ts).
final class RoomFailedTests: XCTestCase {
    private let rt = Realtime(RealtimeOptions(app: "s1", endpoint: URL(string: "https://routes.test/api/realtime")!))

    private func heldAndOut(_ code: String) -> Room {
        let room = rt.join("chat:34:42")
        rt.queue.sync { room.joined(members: [("34", .null), ("42", .null)], count: 2) }
        XCTAssertEqual(Set(room.members.keys), ["34", "42"])
        XCTAssertEqual(room.count, 2)
        rt.queue.sync { room.failed(code) }
        return room
    }

    func testARoomTheUserIsKickedOutOfForgetsItsPeople() {
        let room = heldAndOut("kicked")
        XCTAssertEqual(room.state, .failed)
        XCTAssertTrue(room.members.isEmpty)
        XCTAssertNil(room.count)
    }

    func testARoomThatFailsForgetsItsPeople() {
        let room = heldAndOut("forbidden")
        XCTAssertEqual(room.error, "forbidden")
        XCTAssertTrue(room.members.isEmpty)
        XCTAssertNil(room.count)
    }
}
