import XCTest
@testable @_spi(WordPlusModules) import WordPlusRealtime
@testable import WordPlusRealtimeCalls

/// Token calls against the real thing: a local realtime server and media server, an app's server with no calls rule, and
/// browsers on the web SDK as the other side, as `node scripts/token-calls-rig.mjs` keeps them up. Set
/// WORDPLUS_TOKEN_RIG to its address (TEST_RUNNER_WORDPLUS_TOKEN_RIG for xcodebuild). Without it these are skipped. The
/// microphone and camera here are refused, as a test has no app to ask for them, so this side sends nothing and the
/// browsers send to it.
@MainActor
final class TokenCallsLiveTests: XCTestCase {
    private var opened: [Realtime] = []
    private var base: URL!

    override func setUp() async throws {
        guard let value = ProcessInfo.processInfo.environment["WORDPLUS_TOKEN_RIG"], let url = URL(string: value) else {
            throw XCTSkip("WORDPLUS_TOKEN_RIG is not set: run `node scripts/token-calls-rig.mjs`")
        }
        base = url
        CallPermissions.answerAsked = { _ in false }
        _ = try await asked()
    }

    override func tearDown() async throws {
        CallPermissions.answerAsked = nil
        opened.forEach { $0.close() }
        opened = []
    }

    // MARK: - The rig

    private func request(_ path: String, as user: String? = nil, query: [String: String] = [:], body: JSONValue? = nil) async throws -> JSONValue {
        var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            // `+` means a space to the rig's URLSearchParams.
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 90
        if let user { request.setValue(user, forHTTPHeaderField: "X-User") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try body.encoded()
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONValue.parse(String(decoding: data, as: UTF8.self)), path)
    }

    private func token(_ path: String, as user: String, _ ask: [String: String]) async throws -> String {
        let answer = try await request(path, as: user, query: ask)
        return try XCTUnwrap(answer["token"]?.string, "\(answer)")
    }

    /// Runs an async function's body on the browser signed in as `user`.
    @discardableResult
    private func page(_ user: String, _ run: String) async throws -> JSONValue {
        let answer = try await request("page", body: ["as": .string(user), "run": .string(run)])
        if let error = answer["error"]?.string { XCTFail(error) }
        return answer["value"] ?? .null
    }

    private func asked() async throws -> JSONValue { try await request("asked") }

    private func connect(_ user: String) async throws -> Realtime {
        let info = try await request("api/info")
        var options = RealtimeOptions(
            app: try XCTUnwrap(info["app"]?.string),
            endpoint: base.appendingPathComponent("api/realtime"),
            headers: { ["X-User": user] },
            server: try XCTUnwrap(URL(string: try XCTUnwrap(info["server"]?.string))),
            callbackQueue: DispatchQueue(label: "live-\(user)")
        )
        options.nodeStore = MemoryNodeStore()
        let rt = Realtime(options)
        opened.append(rt)
        rt.connect()
        _ = rt.calls
        try await until("connected as \(user)") { rt.state == .connected && rt.user == user }
        return rt
    }

    private func until(_ what: String, seconds: Double = 45, _ done: @escaping @MainActor () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("timed out on: \(what)")
        throw CallError("timed_out")
    }

    private func unique(_ name: String) -> String { name + ":" + String(Int(Date().timeIntervalSince1970 * 1000)) }

    // MARK: - A call between two

    func testACallFromATokenRingsABrowserAndConnects() async throws {
        let ann = try await connect("42")
        try await page("34", "window.rings = []; return null")

        let made = try await token("api/call-token", as: "42", ["to": "34", "type": "video"])
        let call = try await ann.startCall(made)
        XCTAssertEqual(call.peer, "34")
        XCTAssertEqual(call.state, .ringing)

        let ring = try await page("34", "await until(() => rings.length === 1); return rings[0]")
        XCTAssertEqual(ring["id"]?.string, call.id)
        XCTAssertEqual(ring["from"]?.id, "42")
        XCTAssertEqual(ring["info"]?["name"], "User 42")
        XCTAssertNil(ring["info"]?["_ring"], "a browser leaves the proof out of what its app sees")

        try await page("34", "await incoming.accept().then(take); return null")
        try await until("the call connected") { call.state == .connected }
        try await until("the browser's picture arriving") { call.bytesReceived > 0 }
        try await page("34", "await until(() => call.state === 'connected'); return null")

        // The calls route was asked by the person called alone, with the proof their ring brought, and no rule exists.
        let bodies = try await asked()["bodies"]?.array ?? []
        let answer = try XCTUnwrap(bodies.first { $0["body"]?["id"]?.string == call.id && $0["body"]?["role"] == "callee" })
        XCTAssertEqual(answer["user"], "34")
        XCTAssertNotNil(answer["body"]?["ring"]?.string)
        XCTAssertFalse(bodies.contains { $0["user"] == "42" && $0["body"]?["id"]?.string == call.id }, "the caller's token asked no route")

        // What its renewal asks, which the server answers for the proof with no rule to ask.
        let renewed = try await ann.calls.authorize(call.request)
        XCTAssertNotNil(renewed["token"] as? String)
        XCTAssertEqual(renewed["member"] as? String, CallTokens.call(made)?.member)

        call.end()
        try await page("34", "await until(() => call.state === 'ended'); return null")

        // A token rings once.
        let again = try? await ann.startCall(made)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let rings = try await page("34", "return rings.length")
        XCTAssertEqual(rings, 1, "the same token rings nobody a second time")
        again?.end()
    }

    func testACallFromABrowserRingsHereAndAnswersWithNoTokenOfItsOwn() async throws {
        let ben = try await connect("34")
        var rings: [IncomingCall] = []
        ben.calls.onIncoming { rings.append($0) }
        await mainSettled()
        // The line is held as the connection comes up: a moment for its answer.
        try await Task.sleep(nanoseconds: 500_000_000)

        try await page("42", "const t = await getToken('/api/call-token', { to: 34, type: 'video', name: 'support:17' }); await rt.startCall(t).then(take); return null")
        try await until("the ring") { !rings.isEmpty }

        let incoming = rings[0]
        XCTAssertEqual(incoming.from, "42")
        XCTAssertEqual(incoming.call, "support:17")
        XCTAssertEqual(incoming.info["name"], "User 42")
        XCTAssertNil(incoming.info["_ring"], "the proof stays out of what the app sees")
        XCTAssertNotNil(incoming.ring)

        guard case let .call(call) = try await incoming.accept() else { return XCTFail("a ring between two answers as a call") }
        try await until("the call connected") { call.state == .connected }
        try await until("the browser's picture arriving") { call.bytesReceived > 0 }
        try await page("42", "await until(() => call.state === 'connected'); return null")

        let bodies = try await asked()["bodies"]?.array ?? []
        let answer = try XCTUnwrap(bodies.first { $0["body"]?["id"]?.string == call.id })
        XCTAssertEqual(answer["body"]?["ring"]?.string, incoming.ring)
        XCTAssertEqual(answer["body"]?["role"], "callee")
        XCTAssertEqual(answer["body"]?["from"], 42)

        // Its renewal proves the same.
        let renewed = try await ben.calls.authorize(call.request)
        XCTAssertNotNil(renewed["token"] as? String)

        // Hung up from the browser's side.
        try await page("42", "call.end(); return null")
        try await until("the call over") { call.state == .ended }
    }

    func testAnotherUsersTokenIsRefusedHereAndAMadeUpRingIsRefusedByTheServer() async throws {
        let cara = try await connect("56")
        await XCTAssertThrowsCode("forbidden") { _ = try await cara.startCall(try await self.token("api/call-token", as: "42", ["to": "34"])) }
        await XCTAssertThrowsCode("forbidden") { _ = try await cara.joinGroupCall(try await self.token("api/group-call-token", as: "42", ["call": "meeting:1"])) }
        await XCTAssertThrowsCode("bad_token") { _ = try await cara.startCall("not-a-token") }

        // With no rule, a ring's answer is only as good as its proof.
        let ring = IncomingCall(owner: cara.calls, message: ["id": "madeUpCallId", "call": "support:17", "from": 42, "type": "audio"], info: ["_ring": .string(String(repeating: "A", count: 43))])
        await XCTAssertThrowsCode("forbidden") { _ = try await ring.acceptNow() }
    }

    // MARK: - Ringing someone in

    func testARefGetsATokenThatRingsSomeoneIn() async throws {
        let ann = try await connect("42")
        try await page("34", "window.rings = []; return null")
        try await page("56", "window.rings = []; return null")

        let call = try await ann.startCall(try await token("api/call-token", as: "42", ["to": "34", "type": "video"]))
        try await page("34", "await until(() => rings.length === 1); await incoming.accept().then(take); return null")
        try await until("the call connected") { call.state == .connected }

        var groups: [GroupCall] = []
        call.onGroup { groups.append($0) }

        // The app's route takes the ref, which the server checks against its own proof: only this user's call has one.
        let refused = try await request("api/call-token", as: "77", query: ["to": "56", "into": call.ref])
        XCTAssertNil(refused["token"], "someone not in the call gets no token from its ref")

        let added = try await token("api/call-token", as: "42", ["to": "56", "into": call.ref])
        XCTAssertEqual(CallTokens.call(added)?.group, call.id)
        let invite = try await call.add(added)
        XCTAssertEqual(invite.to, "56")
        XCTAssertEqual(invite.group, call.id)

        let ring = try await page("56", "await until(() => rings.length === 1); return rings[0]")
        XCTAssertEqual(ring["group"]?.string, call.id)
        XCTAssertEqual(ring["from"]?.id, "42")

        try await until("the call became a group call") { !groups.isEmpty }
        let group = groups[0]
        XCTAssertEqual(group.group, call.id)
        XCTAssertTrue(group.encrypted, "a call's rooms always are")
        XCTAssertEqual(group.ref, call.ref)
        try await until("the call ended as a group") { call.endReason == "group" }

        try await page("56", "window.group = await incoming.accept(); return null")
        try await until("the group call connected") { group.state == .connected }
        try await until("everyone in the room") { Set(group.people.compactMap(\.user)) == ["34", "56"] }
        try await until("the ring answered") { invite.state == "answered" }
        XCTAssertEqual(group.me?.info["name"], "User 42")

        // Someone else rung in by a token made from the group's ref.
        let again = try await token("api/call-token", as: "42", ["to": "77", "into": try XCTUnwrap(group.ref)])
        try await page("77", "window.rings = []; return null")
        let second = try await group.add(again)
        XCTAssertEqual(second.to, "77")
        try await page("77", "await until(() => rings.length === 1); await incoming.decline(); return null")
        try await until("the second ring declined") { second.state == "rejected" }

        group.leave()
        try await page("34", "group.leave(); return null")
        try await page("56", "group.leave(); return null")
    }

    // MARK: - A group call

    func testAGroupCallJoinsFromATokenAndItsHostActsThroughItsProof() async throws {
        let name = unique("meeting")
        let ann = try await connect("42")

        let plain = try await ann.joinGroupCall(try await token("api/group-call-token", as: "42", ["call": name + ":plain"]))
        try await until("connected") { plain.state == .connected }
        XCTAssertFalse(plain.can.admin)
        XCTAssertFalse(plain.canRecord)
        await XCTAssertThrowsCode("forbidden") { _ = try await plain.mute("34") }
        await XCTAssertThrowsCode("forbidden") { _ = try await plain.startRecording() }
        plain.leave()

        let group = try await ann.joinGroupCall(try await token("api/group-call-token", as: "42", ["call": name, "admin": "1"]))
        XCTAssertEqual(group.name, name)
        XCTAssertFalse(group.encrypted)
        try await until("connected") { group.state == .connected }
        XCTAssertTrue(group.can.admin, "the room's token says so")
        // Recording is held in this release: the server package signs no recorder proof, even for the host.
        XCTAssertFalse(group.canRecord, "recording is held, so the token carries no recorder proof")
        XCTAssertEqual(group.me?.info["name"], "User 42")

        try await page("34", "window.group = await rt.joinGroupCall(await getToken('/api/group-call-token', { call: '\(name)' })); group.on('ended', (r) => window.endedAs = r); await group.setMicrophone(true); return null")
        try await until("the browser in the room") { group.people.first?.user == "34" }
        XCTAssertEqual(group.people.first?.info["name"], "User 34")

        // The route takes the proof from the token, with no rule to ask.
        let spotlit = try await group.spotlightOn("34")
        XCTAssertTrue(spotlit)
        try await until("the spotlight") { group.spotlit == ["34"] }
        let muted = try await group.mute("34")
        XCTAssertTrue(muted)
        let bodies = try await asked()["bodies"]?.array ?? []
        let act = try XCTUnwrap(bodies.last { $0["body"]?["act"] == "mute" })
        XCTAssertNotNil(act["body"]?["host"]?["proof"]?.string)

        // Recording is held: with no recorder proof, the calls route refuses it before anything reaches the cloud.
        do {
            let recording = try await group.startRecording()
            _ = try? await group.stopRecording(recording.id)
            XCTFail("recording is held in this release, so it must not start")
        } catch let error as CallError {
            print("recording answered \(error.code), as it is held")
        }

        let removed = try await group.remove("34")
        XCTAssertTrue(removed)
        let reason = try await page("34", "await until(() => window.endedAs); return window.endedAs")
        XCTAssertEqual(reason, "removed")
        try await until("the browser gone") { group.people.isEmpty }
        group.leave()
    }

    /// A host sees someone let on as it happens. The browser sends nothing all along, so only the change itself can say so.
    func testAHostSeesSomeoneLetOnAsItHappens() async throws {
        let name = unique("class")
        let ann = try await connect("42")
        let group = try await ann.joinGroupCall(try await token("api/group-call-token", as: "42", ["call": name, "admin": "1", "type": "audio"]))
        try await until("connected") { group.state == .connected }

        try await page("34", "window.group = await rt.joinGroupCall(await getToken('/api/group-call-token', { call: '\(name)', publish: '0', type: 'audio' })); return null")
        try await until("the listener in the room") { group.people.first?.user == "34" }
        XCTAssertEqual(group.people.first?.publish, false)

        let letOn = try await group.letSpeak("34")
        XCTAssertTrue(letOn)
        try await until("let on, as the host sees it", seconds: 3) { group.people.first?.publish == true }

        let putBack = try await group.makeListener("34")
        XCTAssertTrue(putBack)
        try await until("put back, as the host sees it", seconds: 3) { group.people.first?.publish == false }

        group.leave()
        try await page("34", "group.leave(); return null")
    }

    func testSomeoneTakenOutNeedsANewTokenToComeBack() async throws {
        let name = unique("class")
        let ben = try await connect("34")
        try await page("42", "window.group = await rt.joinGroupCall(await getToken('/api/group-call-token', { call: '\(name)', admin: '1' })); return null")

        let old = try await token("api/group-call-token", as: "34", ["call": name])
        // Into the next second: the realtime server goes by when a token was signed, to the second.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let group = try await ben.joinGroupCall(old)
        try await until("connected") { group.state == .connected }
        try await page("42", "await until(() => group.people().length === 1); await group.remove(34); return null")
        try await until("taken out") { group.endReason == "removed" }

        try await Task.sleep(nanoseconds: 1_100_000_000)
        var code: String?
        do {
            let back = try await ben.joinGroupCall(old)
            back.leave()
        } catch let error as CallError {
            code = error.code
        }
        print("a token from before answered \(code ?? "nothing")")
        XCTAssertNotNil(code, "the token from before does not bring them back")

        let fresh = try await ben.joinGroupCall(try await token("api/group-call-token", as: "34", ["call": name]))
        try await until("back in") { fresh.state == .connected }
        fresh.leave()
        try await page("42", "group.leave(); return null")
    }

    func testAnEncryptedGroupCallFromATokenHasEveryoneInItsRoom() async throws {
        let name = unique("private")
        let ann = try await connect("42")
        let group = try await ann.joinGroupCall(try await token("api/group-call-token", as: "42", ["call": name, "encrypt": "1", "type": "audio"]))
        XCTAssertTrue(group.encrypted)
        XCTAssertFalse(group.canRecord)
        try await until("connected") { group.state == .connected }

        try await page("34", "window.group = await rt.joinGroupCall(await getToken('/api/group-call-token', { call: '\(name)', encrypt: '1', type: 'audio' })); await group.setMicrophone(true); return group.encrypted")
        try await until("the browser's microphone in the room") { group.people.first?.user == "34" && group.people.first?.microphone == true }
        group.leave()
        try await page("34", "group.leave(); return null")
    }

    // MARK: - A live stream

    func testAStreamJoinsFromAFunctionAndGoesLiveFromABrowser() async throws {
        let name = unique("show")
        let ben = try await connect("34")

        // No rule: the SDK's own route starts nothing.
        await XCTAssertThrowsCode("forbidden") { _ = try await ben.stream(name) }

        try await page("42", "window.show = await rt.joinStream(() => getToken('/api/stream-token', { stream: '\(name)', role: 'host' })); return show.role")
        let before = try await asked()["streamAsks"]?.int ?? 0

        var asks = 0
        let show = try await ben.joinStream(getToken: { [self] in
            asks += 1
            return try await token("api/stream-token", as: "34", ["stream": name])
        })
        XCTAssertEqual(show.name, name)
        XCTAssertEqual(show.role, .viewer)
        XCTAssertEqual(asks, 1)
        let after = try await asked()["streamAsks"]?.int
        XCTAssertEqual(after, before + 1)

        try await page("42", "await show.preview({ camera: true, microphone: true }); await show.goLive(); return null")
        try await until("the stream live") { show.state == .live }
        try await until("the picture coming") { show.media == .live }

        show.leave()
        try await page("42", "await show.end(); show.leave(); return null")
    }

    /// A host's moderation "exactly as BM", against a realtime server with held acts (better-messages-server
    /// calls/held-acts) and the server package that names them (realtime-js launch/moderation): what the call offers, the
    /// room's rules from its state, a raised hand, an ask and its answer, a held microphone let go, a ban that keeps a new
    /// token out, a lock that keeps a newcomer out, and End. Skipped with an older server or package, which name no acts.
    func testAHostModeratesAsBetterMessagesDoes() async throws {
        let name = unique("moderated")
        let ann = try await connect("42")
        let group = try await ann.joinGroupCall(try await token("api/group-call-token", as: "42", ["call": name, "admin": "1"]))
        try await until("connected") { group.state == .connected }
        guard group.acts == CallAct.allCases else { throw XCTSkip("the rig's server or package names no acts: \(group.acts)") }
        var rulesHeard: [RoomRules] = []
        var answers: [TurnOnAnswer] = []
        group.onRules { rulesHeard.append($0) }
        group.onAskAnswer { answers.append($0) }

        try await page("34", "window.asks = []; window.group = await rt.joinGroupCall(await getToken('/api/group-call-token', { call: '\(name)' })); group.on('ask', (a) => asks.push(a)); group.on('ended', (r) => window.endedAs = r); return null")
        try await until("the browser in the room") { group.people.first?.user == "34" }

        // The room's rules, from its state: the browser's microphone held by Mute Everyone.
        let rules = try await group.setRules(locked: true, muted: true)
        XCTAssertEqual(rules, RoomRules(mode: .participatory, locked: true, muted: true))
        try await until("the rules from the room") { group.rules.locked && group.rules.muted }
        XCTAssertEqual(rulesHeard.last, RoomRules(mode: .participatory, locked: true, muted: true))
        let held = try await page("34", "await until(() => group.can.micHeld === true); return group.rules")
        XCTAssertEqual(held["locked"], .bool(true))
        try await until("their microphone held, as the host sees it") { group.people.first?.micHeld == true }

        // Released for them alone.
        _ = try await group.releaseMic("34")
        try await page("34", "await until(() => !group.can.micHeld); return null")

        // A hand, kept in the room's state, and lowered by the host.
        try await page("34", "await group.raiseHand(); return null")
        try await until("the hand up") { group.hands == ["34"] }
        _ = try await group.lowerAllHands()
        try await until("the hands down") { group.hands.isEmpty }

        // An ask, from the server to the browser alone, and its answer to this host.
        let ask = try await group.askToTurnOn("34", devices: [.camera])
        let devices = try await page("34", "await until(() => asks.length > 0); await group.answerAsk(asks[0], 'not_now'); return asks[0].devices")
        XCTAssertEqual(devices, .array([.string("camera")]))
        try await until("the answer") { answers.first?.id == ask }
        XCTAssertEqual(answers.first?.answer, .notNow)
        XCTAssertEqual(answers.first?.from, "34")

        // Locked: a newcomer is refused.
        let cleo = try await connect("56")
        let cleoToken = try await token("api/group-call-token", as: "56", ["call": name])
        await XCTAssertThrowsCode("locked") { _ = try await cleo.joinGroupCall(cleoToken) }

        // Banned for five minutes: out now, and a new token is refused with when it ends.
        _ = try await group.ban("34", minutes: 5)
        let reason = try await page("34", "await until(() => window.endedAs); return window.endedAs")
        XCTAssertEqual(reason, "removed")
        let refused = try await page("34", "try { await rt.joinGroupCall(await getToken('/api/group-call-token', { call: '\(name)' })); return 'joined' } catch (e) { return { code: e.code, until: e.until ?? null } }")
        XCTAssertEqual(refused["code"], .string("banned"))
        // The join's refusal names when the ban ends only where the server says it (`until`), which WP1's doesn't yet.
        print("a banned join's until: \(refused["until"] ?? .null)")

        // End for everyone: this host's room closes too.
        _ = try? await group.unban("34")
        _ = try await group.end()
        try await until("ended") { group.state == .ended }
        XCTAssertEqual(group.endReason, "closed")
    }

    func testAStreamJoinsFromOneToken() async throws {
        let ben = try await connect("34")
        let show = try await ben.joinStream(try await token("api/stream-token", as: "34", ["stream": unique("show"), "role": "host"]), video: false)
        XCTAssertEqual(show.role, .host)
        XCTAssertFalse(show.video)
        show.leave()
    }
}
