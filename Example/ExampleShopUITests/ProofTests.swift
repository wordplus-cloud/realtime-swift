import XCTest

/// The proof, end to end: this app signed in as Ben, and a browser signed in
/// as Ann on the same shop, the two nodes of the realtime server behind their load balancer. In realtime-js,
/// `node test/native/proof.mjs ios` runs it: it starts the shop and the nodes (test/native/serve.mjs), opens the page of Ann
/// in Chromium, and does what this test asks of her at WORDPLUS_PROOF. Without that, it is skipped.
final class ProofTests: XCTestCase {
    private var proof: URL!
    private var shop = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["WORDPLUS_PROOF"], let url = URL(string: value), let shop = environment["WORDPLUS_SHOP"] else {
            throw XCTSkip("Run by node test/native/proof.mjs ios in realtime-js")
        }
        proof = url
        self.shop = shop
        // The browsers out of any call or room an earlier test left them in.
        try ask("clear")
    }

    /// A call that rings the app closed (SystemCalls): its push woke the app, which connects as Ben, holds his line,
    /// finds the call ringing there and answers it as the system's screen asked, and the call connects. A simulator has
    /// no PushKit or CallKit, so the push is the launch argument a debug build reads, into the same entry point, and the
    /// system's answer comes two seconds after it. The real push and the lock screen are checked on a phone.
    func testACallRingsTheAppClosed() throws {
        var app = launch(reset: true)
        app.buttons["sign-in-42"].tap()
        expect(app.staticTexts["order-live"], label: "Live")
        app.terminate()

        // Ann calls Ben, his app closed: what the realtime server pushes for that ring.
        let id = try XCTUnwrap(try ask("ring", ["to": "Ben"])["id"] as? String)
        let now = Date().timeIntervalSince1970
        let push: [String: Any] = ["aps": [String: Any](), "wp": ["v": 1, "op": "incoming", "id": id, "call": "support:34:42", "from": 34,
                                                               "type": "video", "at": now * 1000, "until": (now + 40) * 1000]]
        app = XCUIApplication()
        app.launchEnvironment["WORDPLUS_SHOP"] = shop
        app.launchArguments = ["-WordPlusSimulatedPush", try JSONSerialization.data(withJSONObject: push).base64EncodedString(),
                               "-WordPlusSimulatedAnswer", "2"]
        app.launch()

        expect(app.staticTexts["call-state"], value: "connected", timeout: 40)
        try ask("wait", ["connected": true])
        sleep(2)
        try ask("hangup")
        expect(any(app, "call-ended"), value: "hangup")
        expectGone(app.buttons["End Call"])
    }

    /// Calls between this app and the browser of Ann, both ways, on the Better Messages
    /// call screen (WordPlusRealtimeUI): each rings, is answered, connects, and ends at the hang-up of either side. It runs
    /// before the shop test, whose node drains.
    func testCallsBetweenThePhoneAndABrowser() throws {
        let app = launch(reset: true)
        app.buttons["sign-in-42"].tap()
        expect(app.staticTexts["order-live"], label: "Live")
        expect(any(app, "member-34"), value: "online")

        // Ben calls Ann: the screen rings out, her page rings, she answers, and both count the seconds.
        app.buttons["call-34"].tap()
        XCTAssertTrue(app.buttons["End Call"].waitForExistence(timeout: 15))
        expect(app.staticTexts["call-state"], value: "ringing")
        try ask("answer")
        expect(app.staticTexts["call-state"], value: "connected", timeout: 30)
        try ask("wait", ["connected": true])

        // The screen put away, the call goes on in the shop bar, and comes back from it.
        app.buttons["Toggle Chat Screen"].tap()
        XCTAssertTrue(app.buttons["back-to-call"].waitForExistence(timeout: 5))
        expectHittable(app.buttons["back-to-call"])
        app.buttons["back-to-call"].tap()
        expectHittable(app.buttons["End Call"])
        sleep(2)
        app.buttons["End Call"].tap()
        try ask("wait", ["callOver": true])
        expect(any(app, "call-ended"), value: "hangup")
        expectGone(app.buttons["End Call"])

        // Ann calls Ben: the screen rings with Answer, he answers, and her hang-up takes the screen away.
        try ask("call", ["to": "Ben"])
        XCTAssertTrue(app.buttons["Answer"].waitForExistence(timeout: 15))
        app.buttons["Answer"].tap()
        expect(app.staticTexts["call-state"], value: "connected", timeout: 30)
        try ask("wait", ["connected": true])
        sleep(3)
        try ask("hangup")
        expect(any(app, "call-ended"), value: "hangup")
        expectGone(app.buttons["End Call"])
    }

    /// Group calls, on the mesh: Ben calls Ann and adds Cara, whose browser
    /// rings and answers, and all three go on in the call room, drawn as the Better Messages grid. Then the daily
    /// meeting, joined from the app and both browsers. Run only with a mesh (MESH_URL for proof.mjs).
    func testGroupCallsWithTwoBrowsers() throws {
        guard ProcessInfo.processInfo.environment["WORDPLUS_MESH"] == "1" else { throw XCTSkip("No mesh: MESH_URL for proof.mjs") }
        let app = launch(reset: true)
        app.buttons["sign-in-42"].tap()
        expect(app.staticTexts["order-live"], label: "Live")
        expect(any(app, "member-34"), value: "online")

        // Ben calls Ann, then adds Cara from the shop bar: the call becomes a group call, and all three meet in its room.
        app.buttons["call-34"].tap()
        try ask("answer")
        expect(app.staticTexts["call-state"], value: "connected", timeout: 30)
        app.buttons["Toggle Chat Screen"].tap()
        XCTAssertTrue(app.buttons["add-43"].waitForExistence(timeout: 5))
        app.buttons["add-43"].tap()
        try ask("answer", ["as": "cara"])
        expect(app.staticTexts["group-people"], value: "2", timeout: 40)
        // The screen is back for the group call, its hang-up a room Exit Chat, as on the web.
        expectHittable(app.buttons["Exit Chat"])
        app.buttons["Exit Chat"].tap()
        expectGone(app.buttons["Exit Chat"])
        try ask("leave")
        try ask("leave", ["as": "cara"])

        // The daily meeting: both browsers join, then the app.
        try ask("meeting")
        try ask("meeting", ["as": "cara"])
        app.buttons["join-meeting"].tap()
        expect(app.staticTexts["group-people"], value: "2", timeout: 40)
        expectHittable(app.buttons["Exit Chat"])
        app.buttons["Exit Chat"].tap()
        expectGone(app.buttons["Exit Chat"])
        try ask("leave")
        try ask("leave", ["as": "cara"])
    }

    /// The shop live show, on the mesh: Ann goes live in her browser,
    /// and the app watches its picture, is counted among those watching, and talks with her in its chat. Her end
    /// reaches the app. Named to run before the shop test, whose node drains.
    func testLiveShowFromABrowser() throws {
        guard ProcessInfo.processInfo.environment["WORDPLUS_MESH"] == "1" else { throw XCTSkip("No mesh: MESH_URL for proof.mjs") }
        let app = launch(reset: true)
        app.buttons["sign-in-42"].tap()
        expect(app.staticTexts["order-live"], label: "Live")

        try ask("golive")
        let watch = app.buttons["watch-show"]
        XCTAssertTrue(watch.waitForExistence(timeout: 10))
        watch.tap()
        // The screen drawn ready (LiveStreamScreen): Live over the picture, and the picture itself.
        expect(app.staticTexts["stream-live"], label: "LIVE", timeout: 20)
        expect(any(app, "stream-picture"), value: "picture", timeout: 30)
        // Counted among those watching: the page of Cara, and this app.
        try ask("wait", ["watching": "2"])

        let stamp = String(Int(Date().timeIntervalSince1970) % 100_000)
        let fromAnn = "From the browser " + stamp, fromBen = "From iOS " + stamp
        let field = app.textFields["stream-field"]
        field.tap()
        field.typeText(fromBen)
        app.buttons["stream-send"].tap()
        try ask("wait", ["showChat": fromBen])
        try ask("showSay", ["text": fromAnn])
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fromAnn)).firstMatch.waitForExistence(timeout: 10))

        try ask("endShow")
        expect(app.staticTexts["stream-note"], label: "This stream has ended", timeout: 20)
        app.buttons["stream-close"].tap()
        XCTAssertTrue(watch.waitForExistence(timeout: 10))
    }

    func testTheShopWithABrowserAcrossAMove() throws {
        var app = launch(reset: true)
        app.buttons["sign-in-42"].tap()

        // The order of Ben is live, and moves on when Ann marks it in her browser, his notice with it.
        expect(app.staticTexts["order-live"], label: "Live")
        try ask("status", ["status": "packed"])
        expect(any(app, "step-packed"), value: "now")
        XCTAssertTrue(app.staticTexts["Your order #1042 is packed."].waitForExistence(timeout: 10))

        // Ann is in the shop and online. The page of Ann has Ben in the shop, online too.
        expect(any(app, "member-34"), value: "online")
        try ask("wait", ["member": "Ben"])
        try ask("wait", ["online": "42"])

        // The chat: Ann typing shows here, her message comes. The typing of Ben and message reach her page.
        try ask("type")
        expect(app.staticTexts["typing"], label: "Ann is typing…")
        let stamp = String(Int(Date().timeIntervalSince1970) % 100_000)
        let fromAnn = "From the browser " + stamp, fromBen = "From iOS " + stamp
        try ask("say", ["text": fromAnn])
        XCTAssertTrue(app.staticTexts[fromAnn].waitForExistence(timeout: 10))
        let field = app.textFields["message-field"]
        field.tap()
        field.typeText(fromBen)
        try ask("wait", ["typing": "Ben is typing"])
        app.buttons["send"].tap()
        try ask("wait", ["chat": fromBen])

        // Opened again, the app has the chat from the room history.
        app.terminate()
        app = launch(reset: false)
        XCTAssertTrue(app.staticTexts[fromBen].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[fromAnn].exists)
        expect(app.staticTexts["order-live"], label: "Live")

        // The node the app is on drains while Ann moves the order on: the app moves to the other node through the load
        // balancer, and goes on there.
        try ask("drain", ["status": "shipped"])
        expect(any(app, "step-shipped"), value: "now")
        try ask("status", ["status": "delivered"])
        expect(any(app, "step-delivered"), value: "now")
        let after = "After the move " + stamp
        try ask("say", ["text": after])
        XCTAssertTrue(app.staticTexts[after].waitForExistence(timeout: 10))
    }

    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["WORDPLUS_SHOP"] = shop
        if reset { app.launchEnvironment["WORDPLUS_RESET"] = "1" }
        app.launch()
        return app
    }

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Waits until the element has the value or label.
    private func expect(_ element: XCUIElement, value: String? = nil, label: String? = nil, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let format = value != nil ? "value == %@" : "label == %@"
        let wanted = expectation(for: NSPredicate(format: format, value ?? label ?? ""), evaluatedWith: element)
        if XCTWaiter().wait(for: [wanted], timeout: timeout) != .completed {
            XCTFail("\(element) has value \(String(describing: element.value)), label \(element.label); wanted \(value ?? label ?? "")", file: file, line: line)
        }
    }

    /// Waits until the element can be tapped: on the screen, in front of whatever else is.
    private func expectHittable(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let wanted = expectation(for: NSPredicate(format: "exists == true AND hittable == true"), evaluatedWith: element)
        if XCTWaiter().wait(for: [wanted], timeout: timeout) != .completed {
            XCTFail("\(element) is not hittable", file: file, line: line)
        }
    }

    /// Waits until the element is gone: the call screen, once its call ended.
    private func expectGone(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let wanted = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        if XCTWaiter().wait(for: [wanted], timeout: timeout) != .completed {
            XCTFail("\(element) is still there", file: file, line: line)
        }
    }

    /// Asks the browser of Ann to do something, or waits for it to see something. Fails unless it answers 200.
    @discardableResult
    private func ask(_ path: String, _ body: [String: Any] = [:], file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        var request = URLRequest(url: proof.appendingPathComponent(path))
        request.httpMethod = "POST"
        // The waits of the proof itself leave room for a busy machine (test/native/proof.mjs in realtime-js).
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let answered = expectation(description: path)
        var status = 0
        var answer: [String: Any] = [:]
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            answer = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            answered.fulfill()
        }.resume()
        wait(for: [answered], timeout: 125)
        XCTAssertEqual(status, 200, "\(path) \(body): \(answer)", file: file, line: line)
        return answer
    }
}
