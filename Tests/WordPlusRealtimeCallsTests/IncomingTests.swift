import XCTest
@testable import WordPlusRealtime
@testable import WordPlusRealtimeCalls

/// A ring answered or declined on this device says it is over, as the browser's do since @wordplus/realtime-client
/// a738a57 (calls.ts, Incoming), so a ring the app drew goes when the app answers through the API. With no server: the
/// route refuses, and the socket isn't there.
final class IncomingTests: XCTestCase {
    private let rt = Realtime(RealtimeOptions(app: "app_test", endpoint: URL(string: "https://shop.example/api/realtime")!))

    private func ringing() -> (IncomingCall, () -> [String]) {
        rt.calls.routeAsked = { _ in (200, .object(["denied": .string("forbidden")])) }
        let incoming = IncomingCall(owner: rt.calls, message: ["id": "ring-1", "call": "support:34:42", "from": 34, "type": "video"], info: .null)
        var over: [String] = []
        incoming.onOver { over.append($0) }
        return (incoming, { over })
    }

    @MainActor
    func testARingAnsweredHereSaysItIsOverEvenWhenItsCallIsRefused() async {
        let (incoming, over) = ringing()
        _ = try? await incoming.accept()
        XCTAssertEqual(incoming.state, .answered)
        XCTAssertEqual(over(), ["answered"])
    }

    func testARingDeclinedHereSaysItIsOver() async {
        let (incoming, over) = ringing()
        try? await incoming.decline()
        XCTAssertEqual(incoming.state, .declined)
        XCTAssertEqual(over(), ["declined"])
    }

    func testARingAnsweredBusySaysSo() async {
        let (incoming, over) = ringing()
        try? await incoming.decline(busy: true)
        XCTAssertEqual(over(), ["busy"])
    }

    func testARingSaysItIsOverOnce() async {
        let (incoming, over) = ringing()
        incoming.over("cancelled")
        try? await incoming.decline()
        XCTAssertEqual(incoming.state, .over)
        XCTAssertEqual(over(), ["cancelled"])

        let (declined, overToo) = ringing()
        try? await declined.decline()
        declined.over("cancelled")
        XCTAssertEqual(overToo(), ["declined"])
    }
}

/// Handlers taken off again (`off`), as the browser's calls have them (realtime-client calls.ts). With no server.
final class CallHandlersTests: XCTestCase {
    private let rt = Realtime(RealtimeOptions(app: "app_test", endpoint: URL(string: "https://shop.example/api/realtime")!))

    func testHandlersRunInTheOrderTheyCameAndOneTakenOffHearsNoMore() {
        var handlers = CallHandlers<Int>()
        var heard: [String] = []
        handlers.add { heard.append("a\($0)") }
        let b = handlers.add { heard.append("b\($0)") }
        handlers.add { heard.append("c\($0)") }
        handlers.fire(1)
        handlers.remove(b)
        handlers.fire(2)
        XCTAssertEqual(heard, ["a1", "b1", "c1", "a2", "c2"])
    }

    func testAHandlerMayTakeItselfOffAsItRuns() {
        var handlers = CallHandlers<Void>()
        var heard = 0
        var mine: CallListener?
        mine = handlers.add { _ in heard += 1 }
        handlers.fire()
        handlers.remove(mine!)
        handlers.fire()
        XCTAssertEqual(heard, 1)
    }

    func testARingsHandlerTakenOffHearsNothing() {
        let incoming = IncomingCall(owner: rt.calls, message: ["id": "ring-1", "call": "support:34:42", "from": 34, "type": "video"], info: .null)
        var over: [String] = []
        let listener = incoming.onOver { over.append($0) }
        incoming.off(listener)
        incoming.over("cancelled")
        XCTAssertEqual(over, [])
    }

    func testAGroupCallsHandlerTakenOffHearsNothing() {
        let group = GroupCall(owner: rt.calls, name: "meeting:7", link: nil, key: nil, microphone: false, camera: false)
        var ended: [String] = [], kept: [String] = []
        let listener = group.onEnded { ended.append($0) }
        group.onEnded { kept.append($0) }
        group.off(listener)
        let finished = expectation(description: "finished")
        DispatchQueue.main.async {
            group.finish("left")
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(ended, [])
        XCTAssertEqual(kept, ["left"])
    }

    func testTheCallsHandlersComeOffOnTheMainQueueInTheOrderAsked() {
        var errors: [String] = []
        let taken = rt.calls.onError { errors.append("taken " + $0) }
        rt.calls.onError { errors.append("kept " + $0) }
        rt.calls.off(taken)
        // Refused on the line, as the connection's queue says it.
        let told = expectation(description: "told")
        DispatchQueue.main.async {
            self.rt.calls.fail("forbidden")
            DispatchQueue.main.async { told.fulfill() }
        }
        wait(for: [told], timeout: 5)
        XCTAssertEqual(errors, ["kept forbidden"])
    }
}
