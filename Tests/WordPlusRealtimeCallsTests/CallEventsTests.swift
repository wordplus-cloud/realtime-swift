import XCTest
@testable import WordPlusRealtime
@testable import WordPlusRealtimeCalls

/// `onCall` and `onGroup`, as the browser's calls fire `call` and `group` (realtime-client calls.ts:186, 215, 232, 358):
/// each call this app started or answered and each group call it joined, whoever asked for it, as a call screen does.
/// With no server: the route and the socket are stand-ins, and the microphone is refused.
final class CallEventsTests: XCTestCase {
    private func placed(_ socket: CallsSocket) {
        socket.answer = { event, _ in
            switch event {
            case "room", "group": return ["ok": true, "server": "wss://nowhere.invalid", "token": "room-token"]
            case "call": return ["ok": true, "role": "polite"]
            default: return ["ok": true]
            }
        }
    }

    @MainActor
    func testAGroupCallJoinedIsHeard() async throws {
        let (rt, socket, _) = standInCalls()
        placed(socket)
        var heard: [GroupCall] = []
        rt.calls.onGroup { heard.append($0) }
        await mainSettled()

        let group = try await rt.calls.group("meeting:7", type: .audio)
        XCTAssertEqual(heard.count, 1)
        XCTAssertTrue(heard.first === group)
        group.leave()
    }

    @MainActor
    func testAGroupCallRefusedIsNotHeard() async {
        let (rt, socket, _) = standInCalls()
        socket.answer = { event, _ in event == "room" ? ["ok": false, "error": "full"] : ["ok": true] }
        var heard = 0
        rt.calls.onGroup { _ in heard += 1 }
        await mainSettled()

        await XCTAssertThrowsCode("full") { _ = try await rt.calls.group("meeting:7") }
        XCTAssertEqual(heard, 0)
    }

    @MainActor
    func testARingIntoAGroupCallAnsweredIsHeardAsAGroupCall() async throws {
        let (rt, socket, _) = standInCalls()
        placed(socket)
        var calls = 0
        var groups: [GroupCall] = []
        rt.calls.onCall { _ in calls += 1 }
        rt.calls.onGroup { groups.append($0) }
        await mainSettled()

        let ring = IncomingCall(owner: rt.calls, message: ["id": "ring-1", "call": "support:34:42", "from": 34, "type": "audio", "group": "g-1"], info: .null)
        CallPermissions.answerAsked = { _ in false }
        defer { CallPermissions.answerAsked = nil }
        guard case let .group(group) = try await ring.acceptNow() else { return XCTFail("a ring into a group call answers as one") }
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(groups.first === group)
        group.leave()
    }

    @MainActor
    func testACallStartedIsHeardOnceItIsJoined() async throws {
        let (rt, socket, _) = standInCalls()
        placed(socket)
        CallPermissions.answerAsked = { _ in false }
        defer { CallPermissions.answerAsked = nil }
        var heard: [Call] = []
        rt.calls.onCall { heard.append($0) }
        await mainSettled()

        let call = try await rt.calls.start("support:34:42", to: "34", type: .audio)
        XCTAssertEqual(heard.count, 1)
        XCTAssertTrue(heard.first === call)
        call.end()
    }

    @MainActor
    func testACallAnsweredIsHeard() async throws {
        let (rt, socket, _) = standInCalls()
        placed(socket)
        CallPermissions.answerAsked = { _ in false }
        defer { CallPermissions.answerAsked = nil }
        var heard: [Call] = []
        rt.calls.onCall { heard.append($0) }
        await mainSettled()

        let ring = IncomingCall(owner: rt.calls, message: ["id": "ring-2", "call": "support:34:42", "from": 34, "type": "audio"], info: .null)
        guard case let .call(call) = try await ring.acceptNow() else { return XCTFail("a ring answers as a call") }
        XCTAssertTrue(heard.first === call)
        call.end()
    }

    @MainActor
    func testACallRefusedIsNotHeard() async {
        let (rt, socket, _) = standInCalls(route: { _ in (200, ["denied": "forbidden"]) })
        placed(socket)
        var heard = 0
        rt.calls.onCall { _ in heard += 1 }
        await mainSettled()

        await XCTAssertThrowsCode("forbidden") { _ = try await rt.calls.start("support:34:42", to: "34", type: .audio) }
        XCTAssertEqual(heard, 0)
    }

    @MainActor
    func testAHandlerTakenOffHearsNoMore() async throws {
        let (rt, socket, _) = standInCalls()
        placed(socket)
        var heard = 0
        let listener = rt.calls.onGroup { _ in heard += 1 }
        await mainSettled()

        try await rt.calls.group("meeting:7", type: .audio).leave()
        rt.calls.off(listener)
        await mainSettled()
        try await rt.calls.group("meeting:8", type: .audio).leave()
        XCTAssertEqual(heard, 1)
    }

    @MainActor
    func testTheRoomACallMovesToIsStillTheCall() async {
        let (rt, socket, _) = standInCalls()
        placed(socket)
        var heard = 0
        rt.calls.onGroup { _ in heard += 1 }
        await mainSettled()

        let room = rt.calls.handoffRoom(name: "support:34:42", ticket: CallRoomTicket(["token": "t", "server": "wss://nowhere.invalid"])!, mediaKey: nil, microphone: false, camera: false)
        await mainSettled()
        XCTAssertEqual(heard, 0)
        room.leave()
    }
}

/// That `body` throws the refusal `code`.
func XCTAssertThrowsCode(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("no refusal", file: file, line: line)
    } catch let error as CallError {
        XCTAssertEqual(error.code, code, file: file, line: line)
    } catch {
        XCTFail("\(error)", file: file, line: line)
    }
}
