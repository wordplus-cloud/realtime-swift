import Foundation
import AVFoundation
import LiveKitWebRTC
@_spi(WordPlusModules) import WordPlusRealtime

public enum CallType: String, Sendable {
    case audio
    case video
}

/// Where a call is: ringing (its caller waits), connecting, connected, reconnecting, or ended.
public enum CallState: String, Sendable {
    case ringing
    case connecting
    case connected
    case reconnecting
    case ended
}

/// What carries a call: straight between the two, through TURN, or a room on the mesh.
public enum CallPath: String, Sendable {
    case direct
    case relay
    case room
}

/// A refusal, by its code: `forbidden` (the app's server said no), `auth_failed`, `not_ringing`, `server` …
public struct CallError: Error, Equatable, CustomStringConvertible {
    public let code: String
    /// When a refusal ends, where the realtime server says it: a ban's end (`banned`), nil for one that ends with the call.
    public let until: Date?
    public init(_ code: String, until: Date? = nil) {
        self.code = code
        self.until = until
    }
    public var description: String { "CallError(\(code))" }
}

/// Someone this app's user may add to a call, as the app's server lists them (`rt.calls.people`).
public struct CallPerson: Equatable, Sendable {
    public let id: String
    public let name: String
    public let avatar: String?

    public init(id: String, name: String, avatar: String? = nil) {
        self.id = id
        self.name = name
        self.avatar = avatar
    }
}

/// A question for `rt.calls.may`: whether this app's user may call `to` about the call `call`.
public struct CallAsk: Equatable, Sendable {
    public let call: String
    public let to: String

    public init(call: String, to: String) {
        self.call = call
        self.to = to
    }
}

/**
 Calls between the app's users, on the realtime connection (`rt.calls`), as the browser's `calls()`: the same relay
 and the same call engine, so a phone and a browser call each other.

     rt.calls.onIncoming { incoming in show(incoming) }       // incoming.accept() or incoming.decline()
     let call = try await rt.calls.start("support:34:42", to: "34", type: .audio)
     call.onState { state in … }

 The app's server decides who may call whom: its own route checks whatever it needs and makes a token, which the app
 starts with (`rt.startCall(token)`), or each call and line is a token its calls route signs (`{endpoint}/calls`, the
 server package's `calls()`). Calls ring while the app is open. With `SystemCalls` started they ring a locked phone and a
 closed app too, through CallKit.
 */
public final class RealtimeCalls: @unchecked Sendable {
    /// This package's version, which a group call's join names to the media server (`rtc_app`, "realtime-swift/…"):
    /// the release's, as `scripts/embed-ui.sh` has it.
    public static let version = "1.1.1"

    private static let lock = NSLock()
    private static var byConnection: [ObjectIdentifier: RealtimeCalls] = [:]

    /// The calls of a connection: one for each.
    public static func of(_ rt: Realtime) -> RealtimeCalls {
        lock.lock()
        defer { lock.unlock() }
        if let found = byConnection[ObjectIdentifier(rt)] { return found }
        let calls = RealtimeCalls(rt)
        byConnection[ObjectIdentifier(rt)] = calls
        return calls
    }

    let rt: Realtime
    private var dispatch: [String: (JSONValue) -> Void] = [:]
    private var socketListeners: [UUID: () -> Void] = [:]
    private var incomingHandlers = CallHandlers<IncomingCall>()
    private var errorHandlers = CallHandlers<String>()
    private var callHandlers = CallHandlers<Call>()
    private var groupHandlers = CallHandlers<GroupCall>()
    private var ringing: [String: IncomingCall] = [:]
    private var active: [String: Call] = [:]
    // The rings into group calls this app heard of, and the group calls they ring into, by the group's id. On the main queue.
    private var invites: [String: CallInvite] = [:] { didSet { inviteOrder.removeAll { invites[$0] == nil } } }
    private var inviteOrder: [String] = []
    private var groups: [String: GroupCall] = [:]
    /// When this app was last taken out of a group call or saw it end, by its name (`afterOut`). On the main queue.
    private var outAt: [String: Date] = [:]
    // The line and its renewal: on the module queue.
    private var line: (token: String, exp: Double)?
    private var lineRenewal: DispatchWorkItem?
    private var ringOn = true

    private init(_ rt: Realtime) {
        self.rt = rt
        rt.onSocketEvent("call") { [weak self] data in
            DispatchQueue.main.async { self?.relayed(data) }
        }
        rt.onSocketEvent("line") { [weak self] data in
            guard let message = data.anyValue as? [String: Any] else { return }
            self?.onLine(message, info: data["info"] ?? .null)
        }
        // On every socket before it takes over, the line is held there too.
        rt.addHold { [weak self] socket, done in
            guard let self else { return done() }
            self.holdLine(via: socket, done)
        }
        // A connect after a drop, and a move: each call joins on the socket the app has now.
        let changed: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.socketListeners.values.forEach { $0() } }
        }
        rt.onState { state, _ in if state == .connected { changed() } }
        rt.on("moved") { _, _ in changed() }
        rt.moduleQueue.async { [weak self] in
            guard let self, let socket = rt.currentSocket else { return }
            self.holdLine(via: socket) {}
        }
    }

    /// A call ringing for this app's user, on the main queue.
    @discardableResult
    public func onIncoming(_ handler: @escaping (IncomingCall) -> Void) -> CallListener {
        let listener = CallListener()
        DispatchQueue.main.async { self.incomingHandlers.add(handler, as: listener) }
        return listener
    }

    /// What went wrong with the line (`what` is `line`): its code.
    @discardableResult
    public func onError(_ handler: @escaping (String) -> Void) -> CallListener {
        let listener = CallListener()
        DispatchQueue.main.async { self.errorHandlers.add(handler, as: listener) }
        return listener
    }

    /// A call this app started or answered, on the main queue, the call screen's too: so an app can keep to rules of its
    /// own, such as how long a call may last.
    @discardableResult
    public func onCall(_ handler: @escaping (Call) -> Void) -> CallListener {
        let listener = CallListener()
        DispatchQueue.main.async { self.callHandlers.add(handler, as: listener) }
        return listener
    }

    /// A group call this app joined by `group`, a ring into one answered, or a call of its that became one, on the main
    /// queue, the call screen's too. Not the room a call moved to when no path carried it: that is still the call.
    @discardableResult
    public func onGroup(_ handler: @escaping (GroupCall) -> Void) -> CallListener {
        let listener = CallListener()
        DispatchQueue.main.async { self.groupHandlers.add(handler, as: listener) }
        return listener
    }

    /// Takes a handler off.
    public func off(_ listener: CallListener) {
        DispatchQueue.main.async {
            self.incomingHandlers.remove(listener)
            self.errorHandlers.remove(listener)
            self.callHandlers.remove(listener)
            self.groupHandlers.remove(listener)
        }
    }

    /// The calls ringing for this app's user now. On the main queue.
    public var incoming: [IncomingCall] { Array(ringing.values) }

    /// Calls `user` about `name`, a call the app's server allows: rings their every open app and page. `{pair}` in the
    /// name is the two ids in order, so either side names the same call: `start("support:{pair}", to: "34")`. Throws its
    /// code.
    @MainActor
    public func start(_ name: String, to user: String, type: CallType = .video) async throws -> Call {
        let name = try CallName.named(name, me: rt.user, id: user)
        let id = CallSignaling.randomId(20)
        let request: [String: Any] = ["call": name, "id": id, "role": "caller", "to": RealtimeCalls.userValue(user), "type": type.rawValue]
        let grant = try await authorize(request)
        let call = Call(owner: self, id: id, name: name, type: type, role: .caller, peer: user, peerInfo: .null, request: request, grant: grant)
        active[id] = call
        // The system knows of it before it starts, which gives it the audio session (SystemCalls, when started).
        SystemCalls.shared.outgoing(call)
        try await call.begin()
        callHandlers.fire(call)
        return call
    }

    /// Starts the call in a token from the app's own server (`callToken( user, to )` there), which decided that this user
    /// may make it, and rings the person it names. The calls route isn't asked. A token rings once, so each call takes a new
    /// one. The person called needs no token of their own to answer. Throws its code: `bad_token` for what isn't a token,
    /// `forbidden` for one made for another user.
    @MainActor
    public func startCall(_ token: String) async throws -> Call {
        guard let made = CallTokens.call(token) else { throw CallError("bad_token") }
        guard !madeForAnother(made.pair[0]) else { throw CallError("forbidden") }

        // Its proof of being in the call gets it a new token through the calls route, should the call outlast this one.
        let request: [String: Any] = ["call": made.call, "id": made.id, "role": "caller", "to": RealtimeCalls.userValue(made.to), "type": made.type.rawValue, "member": made.member]
        let call = Call(owner: self, id: made.id, name: made.call, type: made.type, role: .caller, peer: made.to, peerInfo: .null, request: request, grant: made.grant)
        active[made.id] = call
        // The system knows of it before it starts, which gives it the audio session (SystemCalls, when started).
        SystemCalls.shared.outgoing(call)
        try await call.begin()
        callHandlers.fire(call)
        return call
    }

    /// A call between two people whose signalling a transport carries, the app's own (`CallTransport`) or Better Messages'
    /// (`P2PCallTransport`), on this SDK's call engine: direct between the two, through TURN when it must, or in a room
    /// on the mesh when neither works, and on the call screen as any other call (`onCall` hears it). Whoever made the call
    /// on the relay, a site's server for Better Messages, decides who is in it, and this joins it: as its `.caller` it
    /// rings until the other side joins, as its `.callee` it connects.
    ///
    /// - Parameters:
    ///   - transport: what carries the call's requests to the relay and its events back.
    ///   - id: the call on the relay, the same on both sides: a Better Messages call's is its message's id.
    ///   - role: this side's, `.caller` or `.callee`.
    ///   - peer: the other side's user id, and `peerInfo` what the app knows of them, for the call screen.
    ///   - signalKey: the key both sides seal their signals with, which the relay never sees: a Better Messages call's comes
    ///     from its site.
    ///   - mediaKey: the key the call's room encrypts its media with, should the call move to one; nil for none.
    ///   - roomServer: where that room is on the mesh, for a relay that hands it over by its token alone: a Better Messages
    ///     call's is its site's (the `server` the relay answers the site's `/p2p/call/create` with). Nil for a relay that
    ///     names it, as the SDK's own does.
    /// - Throws: the relay's refusal of the join, by its code: `no_call`, `not_participant`, `call_ended`,
    ///   `answered_elsewhere`, or `signaling_unavailable` when the transport answered nothing.
    @MainActor
    public func call(over transport: CallTransport, id: String, role: Call.Role, peer: String, peerInfo: JSONValue = .null, type: CallType = .video, signalKey: String, mediaKey: String? = nil, roomServer: String? = nil) async throws -> Call {
        var grant: [String: Any] = ["key": signalKey]
        if let mediaKey { grant["media_key"] = mediaKey }
        let call = Call(owner: self, id: id, name: id, type: type, role: role, peer: peer, peerInfo: peerInfo, request: [:], grant: grant, transport: transport, roomServer: roomServer)
        active[id] = call
        // The system knows of a call this app places before it starts, which gives it the audio session (SystemCalls).
        if role == .caller { SystemCalls.shared.outgoing(call) }
        try await call.begin()
        callHandlers.fire(call)
        return call
    }

    /// Whether a token of the app's server was made for a user other than this connection's. An app the server hasn't
    /// named yet has nobody to compare with, and the realtime server goes by the token.
    private func madeForAnother(_ user: String?) -> Bool {
        guard let me = rt.user else { return false }
        return user != Self.user(.string(me))
    }

    /// A group call `name` on the mesh, encrypted end to end when its rule says so. Nothing is sent into it until
    /// `microphone` or `camera` say so. Throws its code.
    @MainActor
    public func group(_ name: String, type: CallType = .video) async throws -> GroupCall {
        await afterOut(name)
        let grant = try await authorize(["room": name, "type": type.rawValue])
        // Whether the call's rule lets this user record it: the answer's `record`, which `canRecord` offers. The acts the
        // app's package takes: its answer's `acts`, none from a package before them.
        return try await intoRoom(
            name, token: grant["token"] as? String ?? "", mediaKey: grant["media_key"] as? String, type: type, proofs: nil,
            mayRecord: grant["record"] as? Bool == true, appActs: CallAct.names(JSONValue.from(any: grant["acts"] ?? NSNull()))
        )
    }

    /// Joins the group call in a token from the app's own server (`groupCallToken( user, name, options )` there), which
    /// decided that this user may join and what they may do in it. The calls route isn't asked. Nothing is sent into it
    /// until `microphone` or `camera` say so. Someone taken out of the call needs a new token to come back. Throws its code:
    /// `bad_token` for what isn't a token, `forbidden` for one made for another user or from before they were taken out, or
    /// another refusal of the realtime server: `banned` for someone a host banned, while the ban holds (its end in
    /// `CallError.until`, nil for a ban until the call ends), and `locked` for a locked call they weren't in, or were
    /// removed from.
    @MainActor
    public func joinGroupCall(_ token: String) async throws -> GroupCall {
        guard let made = CallTokens.groupCall(token) else { throw CallError("bad_token") }
        guard !madeForAnother(made.user) else { throw CallError("forbidden") }
        return try await intoRoom(made.room, token: made.token, mediaKey: made.mediaKey, type: made.type, proofs: made.proofs, appActs: made.acts)
    }

    /// A place in the group call's room, with its token, and the room connecting in the background. What it offers is
    /// what the realtime server's place and the app's package both name (`CallAct.offered`), and a refusal is the
    /// server's code (`banned`, `locked` …), with when a ban ends where the server says it.
    @MainActor
    private func intoRoom(_ name: String, token: String, mediaKey: String?, type: CallType, proofs: GroupProofs?, mayRecord: Bool = false, appActs: [String]? = nil) async throws -> GroupCall {
        let place = await ask("room", ["tab": .string(rt.tab), "token": .string(token)])
        guard place?["ok"]?.bool == true else { throw Self.refusedJoin(place) }
        let acts = CallAct.offered(server: CallAct.names(place?["acts"]), app: appActs)
        let room = GroupCall(owner: self, name: name, link: nil, key: mediaKey, microphone: false, camera: false, moderated: true, proofs: proofs, mayRecord: mayRecord, acts: acts)
        room.onEnded { [weak self] reason in
            if reason == "removed" || reason == "closed" { self?.outAt[name] = Date() }
        }
        SystemCalls.shared.outgoing(room, type: type)
        connect(room, place: place)
        groupHandlers.fire(room)
        return room
    }

    /// Who this app's user may add to calls named `name`, as the app's server lists them (its `calls()` rule's `people`):
    /// none when it lists nobody, or when its route gave no answer.
    public func people(_ name: String) async -> [CallPerson] {
        guard let answer = try? await route(["people": name]) else { return [] }
        return Self.people(in: JSONValue.from(any: answer))
    }

    /// Whether this app's user may call each person about each call, as the rules of the app's server answer for a
    /// caller, in the order asked: what a list of people asks before it offers call buttons. Nil where the server gave no
    /// answer (a route of the app's own that doesn't know the question, or a failed request): placing the call still asks
    /// the rule.
    public func may(_ asks: [CallAsk]) async -> [Bool?] {
        var out: [Bool?] = []
        for start in stride(from: 0, to: asks.count, by: Self.mayAtOnce) {
            let part = asks[start..<min(start + Self.mayAtOnce, asks.count)]
            let question = part.map { ["call": $0.call, "to": Self.userValue($0.to)] as [String: Any] }
            let answer = try? await route(["may": question])
            let may = answer?["may"].flatMap { JSONValue.from(any: $0).array }.flatMap { $0.count == part.count ? $0 : nil }
            for index in 0..<part.count { out.append(may.map { $0[index] == .bool(true) }) }
        }
        return out
    }

    /// Stops holding this app's line: its user's calls no longer ring here, nor on this phone with the app closed (as an
    /// app signs its user out).
    public func stopRinging() {
        let push = SystemCalls.shared.unlinePush()
        rt.moduleQueue.async { [self] in
            ringOn = false
            lineRenewal?.cancel()
            lineRenewal = nil
            var payload: [String: JSONValue] = ["tab": .string(rt.tab)]
            if let push { payload["push"] = push }
            rt.currentSocket?.emit("unline", .object(payload))
        }
    }

    // MARK: - For SystemCalls

    /// Holds the line again on the socket the connection has now: the phone's push token came or changed.
    func refreshLine() {
        rt.moduleQueue.async { [self] in
            guard ringOn, let socket = rt.currentSocket else { return }
            holdLine(via: socket) {}
        }
    }

    /// Every connection's lines again, with the phone's new push token.
    static func refreshLines() {
        lock.lock()
        let all = Array(byConnection.values)
        lock.unlock()
        all.forEach { $0.refreshLine() }
    }

    /// A ring on a line of this process, by its id. On the main queue.
    static func ringing(_ id: String) -> IncomingCall? {
        lock.lock()
        let all = Array(byConnection.values)
        lock.unlock()
        return all.lazy.compactMap { $0.ringing[id] }.first
    }

    // MARK: - Internal

    /// A ring into a group call, answered with the proof it brought: the app's server's token for this ring, then a
    /// place in its room.
    @MainActor
    func answerGroup(_ incoming: IncomingCall, group: String) async throws -> GroupCall {
        var request: [String: Any] = ["call": incoming.call, "id": incoming.id, "role": "callee", "from": RealtimeCalls.userValue(incoming.from), "type": incoming.type.rawValue, "group": group]
        if let pair = incoming.pair { request["pair"] = pair }
        if let ring = incoming.ring { request["ring"] = ring }
        let grant = try await authorize(request)
        ringing[incoming.id] = nil
        let link = GroupOf(id: group, name: incoming.call, type: incoming.type, pair: grant["pair"] ?? incoming.pair, member: grant["member"] as? String)
        return try await joinGroup(link, token: grant["token"] as? String ?? "", mediaKey: grant["media_key"] as? String, microphone: true, camera: incoming.type == .video)
    }

    /// Before joining a group call this app was just taken out of, or that just ended: the realtime server refuses a token
    /// signed in the second of that, as from before it, so the app asks its server once the next second has begun, as the
    /// browser's does (calls.ts:425-431). Someone removed who joined again at once was refused `forbidden`.
    @MainActor
    private func afterOut(_ name: String) async {
        guard let out = outAt.removeValue(forKey: name) else { return }
        let wait = Self.outWait(out: out, now: Date())
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    /// How long to wait after being out at `out`: into the next second, and a little more for the clocks to differ.
    static func outWait(out: Date, now: Date) -> TimeInterval {
        (out.timeIntervalSince1970.rounded(.down) + 1) + outMargin - now.timeIntervalSince1970
    }

    static let outMargin: TimeInterval = 0.15

    /// A place in a group call's room, with the token of the call it was made from or of the ring answered.
    @MainActor
    func joinGroup(_ link: GroupOf, token: String, mediaKey: String?, microphone: Bool, camera: Bool) async throws -> GroupCall {
        let place = await ask("group", ["tab": .string(rt.tab), "token": .string(token)])
        guard place?["ok"]?.bool == true else { throw Self.refusedJoin(place) }
        let room = GroupCall(owner: self, name: link.name, link: link, key: mediaKey, microphone: microphone, camera: camera)
        groups[link.id] = room
        room.onEnded { [weak self, weak room] _ in
            guard let self, self.groups[link.id] === room else { return }
            self.groups[link.id] = nil
            self.invites = self.invites.filter { $0.value.group != link.id }
        }
        connect(room, place: place)
        groupHandlers.fire(room)
        return room
    }

    /// The rings into the group call `group` this app heard of, in the order they were heard. On the main queue.
    func invites(of group: String) -> [CallInvite] {
        inviteOrder.compactMap { invites[$0] }.filter { $0.group == group }
    }

    /// Rings `user` into a group call, or into the call that becomes one: the app's server's token for the ring first,
    /// given for the proof that this user is in the call, and the proof the person was rung, which they get with it.
    @MainActor
    func invite(_ link: GroupOf, user: String) async throws -> CallInvite {
        let id = CallSignaling.randomId(20)
        var request: [String: Any] = ["call": link.name, "id": id, "role": "caller", "to": RealtimeCalls.userValue(user), "type": link.type.rawValue, "group": link.id]
        if let pair = link.pair { request["pair"] = pair }
        if let member = link.member { request["member"] = member }
        let grant = try await authorize(request)
        return try await ringInto(link, id: id, user: user, token: grant["token"] as? String ?? "", ring: grant["ring"] as? String)
    }

    /// Rings someone into a group call, or into the call that becomes one: with a token from the app's own server
    /// (`callToken( user, to, { into: ref } )`), which decided they may be added, or by their user id, which a rule of the
    /// app's decides. Throws `forbidden` for a token made for another call.
    @MainActor
    func addTo(_ link: GroupOf, who: String) async throws -> CallInvite {
        guard let made = CallTokens.call(who) else { return try await invite(link, user: who) }
        guard made.group == link.id else { throw CallError("forbidden") }
        return try await ringInto(link, id: made.id, user: made.to, token: made.token, ring: made.ring)
    }

    /// The ring itself, on the realtime server, with the token for it and the proof the person was rung.
    @MainActor
    private func ringInto(_ link: GroupOf, id: String, user: String, token: String, ring: String?) async throws -> CallInvite {
        var payload: [String: JSONValue] = ["tab": .string(rt.tab), "token": .string(token)]
        if let ring { payload["ring"] = .string(ring) }
        let reply = await ask("invite", payload)
        guard reply?["ok"]?.bool == true else { throw CallError(reply?["error"]?.string ?? "server") }

        // Its `ringing` may have come on the line first.
        let invite = invites[id] ?? {
            let state = reply?["state"]?.string.flatMap { CallInvite.states.contains($0) ? $0 : nil } ?? "ringing"
            let invite = CallInvite(id: id, group: link.id, to: user, state: state)
            remember(invite)
            return invite
        }()
        invite.own { [weak self, weak invite] in
            guard let self else { throw CallError("server") }
            let over = await self.ask("uninvite", ["tab": .string(self.rt.tab), "token": .string(token)])
            guard over?["ok"]?.bool == true else { throw CallError(over?["error"]?.string ?? "server") }
            guard let state = over?["state"]?.string, CallInvite.states.contains(state) else { return }
            await MainActor.run { invite?.update(state) }
        }
        return invite
    }

    /// A ring kept, and told to the group call it rings into. On the main queue.
    private func remember(_ invite: CallInvite) {
        invites[invite.id] = invite
        inviteOrder.append(invite.id)
        groups[invite.group]?.invited(invite)
    }

    /// Someone rung into a group call this app's user is in, or how that ring ended, as the relay tells it. On the main
    /// queue.
    func heardInvite(_ message: JSONValue) {
        guard
            let id = message["id"]?.string,
            let state = message["state"]?.string, CallInvite.states.contains(state),
            let group = message["group"]?.string,
            let to = Self.user(message["to"])
        else { return }
        if let known = invites[id] { return known.update(state) }
        remember(CallInvite(id: id, group: group, from: Self.user(message["from"]), to: to, state: state))
    }

    /// A room joined in the background: one that fails is left, and said so.
    @MainActor
    private func connect(_ room: GroupCall, place: JSONValue?) {
        let server = place?["server"]?.string ?? ""
        let token = place?["token"]?.string ?? ""
        let ice = place?["ice_servers"]?.anyValue as? [[String: Any]] ?? []
        // Before anyone draws it, which comes before the room has connected. The realtime server's word that it holds
        // this app's microphone off as it joins (a host's hold, or Mute Everyone).
        room.named(by: token, micHeld: place?["mic_held"]?.bool == true)
        Task {
            do {
                try await room.connect(server: server, token: token, iceServers: ice)
            } catch {
                CallLog.write("room failed: \(GroupCall.failureName(error))")
                await MainActor.run {
                    room.finish("room_failed")
                    self.fail("room_failed")
                }
            }
        }
    }

    /// The room a call moves to when neither the direct path nor TURN carries it, encrypted with the call's key.
    @MainActor
    func handoffRoom(name: String, ticket: CallRoomTicket, mediaKey: String?, microphone: Bool, camera: Bool) -> GroupCall {
        let room = GroupCall(owner: self, name: name, link: nil, key: mediaKey, microphone: microphone, camera: camera)
        connect(room, place: ["server": .string(ticket.server ?? ""), "token": .string(ticket.token)])
        return room
    }

    @MainActor
    func answer(_ incoming: IncomingCall) async throws -> Call {
        var request: [String: Any] = ["call": incoming.call, "id": incoming.id, "role": "callee", "from": RealtimeCalls.userValue(incoming.from), "type": incoming.type.rawValue]
        // A call from a token of the app's server brought the proof that this user was rung, which is all the calls route needs.
        if let ring = incoming.ring { request["ring"] = ring }
        let grant = try await authorize(request)
        let call = Call(owner: self, id: incoming.id, name: incoming.call, type: incoming.type, role: .callee, peer: incoming.from, peerInfo: incoming.info, request: request, grant: grant)
        ringing[incoming.id] = nil
        active[incoming.id] = call
        try await call.begin()
        callHandlers.fire(call)
        return call
    }

    func decline(_ incoming: IncomingCall, reason: String) async throws {
        ringing[incoming.id] = nil
        let reply = await ask("decline", ["tab": .string(rt.tab), "id": .string(incoming.id), "reason": .string(reason)])
        guard reply?["ok"]?.bool == true else { throw CallError(reply?["error"]?.string ?? "server") }
    }

    func forget(_ call: Call) {
        if active[call.id] === call { active[call.id] = nil }
    }

    /// The app's server's answer to a request (its calls route), or its refusal by code.
    func authorize(_ request: [String: Any]) async throws -> [String: Any] {
        let grant = try await route(request)
        guard let token = grant["token"] as? String, !token.isEmpty else { throw CallError("auth_failed") }
        return grant
    }

    /// The calls route's answer, a token or not, or its refusal by code: `denied`, `forbidden` for a 401 or 403 without
    /// one, `auth_failed` for no answer.
    func route(_ request: [String: Any]) async throws -> [String: Any] {
        let body = (JSONValue.from(any: request).object) ?? [:]
        let (status, answer): (Int, JSONValue?)
        if let routeAsked {
            (status, answer) = await routeAsked(body)
        } else {
            (status, answer) = await withCheckedContinuation { continuation in
                rt.postRoute("calls", body) { status, answer in continuation.resume(returning: (status, answer)) }
            }
        }
        if status == 401 || status == 403 { throw CallError(answer?["denied"]?.string ?? "forbidden") }
        guard status == 200, let grant = answer?.anyValue as? [String: Any] else { throw CallError("auth_failed") }
        if let denied = grant["denied"] as? String { throw CallError(denied) }
        return grant
    }

    /// The calls route in place of the app's server, for the tests: the request's body in, its status and answer out.
    var routeAsked: (([String: JSONValue]) async -> (Int, JSONValue?))?

    /// Whether a call's relay is there, in place of the connection's state, for the tests.
    var connectedAsked: Bool?

    /// A host's act in the group call `name`, as the app's calls route answers it (`{ moderate, act, user }`, the
    /// server package's `moderate`, `user` null for everyone out of the spotlight): whether it changed anything. `host` is
    /// the proof a token of the app's server gave, for a call joined with one. A ban's `minutes`, an ask's `devices` and
    /// the `rules` to set go with it (@wordplus/realtime-client's moderateVia): the answer's `done`, and for an ask its
    /// `id`, for the rules the rules now.
    func moderate(_ name: String, act: ModerationAct, user: String?, host: JSONValue? = nil, minutes: Int? = nil, devices: [AskDevice]? = nil, rules: [String: Any]? = nil) async throws -> ModerationAnswer {
        var request: [String: Any] = ["moderate": name, "act": act.rawValue, "user": user.map(RealtimeCalls.userValue) ?? NSNull()]
        if let host { request["host"] = host.anyValue }
        if let minutes { request["minutes"] = minutes }
        if let devices { request["devices"] = devices.map(\.rawValue) }
        if let rules { request["rules"] = rules }
        let answer = try await route(request)
        guard let done = answer["done"] as? Bool else { throw CallError("server") }
        return ModerationAnswer(done: done, id: answer["id"] as? String, rules: answer["rules"] as? [String: Any])
    }

    /// A hand in the group call `name`, through the app's calls route (`{ hand, up, user?, host?, member? }`, the server
    /// package's hand request): this user's own up or down with no `user`, or a host lowering another's (`.one`) or
    /// everyone's (`.everyone`, `user` null), with the token's proofs that this user is in the call and hosts it.
    func hand(_ name: String, up: Bool, of whose: HandOf, host: JSONValue? = nil, member: JSONValue? = nil) async throws -> Bool {
        var request: [String: Any] = ["hand": name, "up": up]
        switch whose {
        case .own: break
        case let .one(user): request["user"] = RealtimeCalls.userValue(user)
        case .everyone: request["user"] = NSNull()
        }
        if let host { request["host"] = host.anyValue }
        if let member { request["member"] = member.anyValue }
        let answer = try await route(request)
        guard let done = answer["done"] as? Bool else { throw CallError("server") }
        return done
    }

    /// The realtime server's refusal of a place in a group call, by its code: `banned` (with `until`, when the ban ends,
    /// in ms, where the server says it), `locked`, `forbidden`, `expired` …
    static func refusedJoin(_ place: JSONValue?) -> CallError {
        let code = place?["error"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "server"
        let until = place?["until"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) }
        return CallError(code, until: until)
    }

    /// The group call `name` recorded or stopped, as the app's calls route answers it (`{ call, record, recording? }`,
    /// the server package's `record`, @wordplus/realtime-client 1.0.65): the recording, its id and state. `recorder` is the
    /// proof a token of the app's server gave, for a call joined with one.
    func record(_ name: String, action: String, recording: String?, recorder: JSONValue? = nil) async throws -> GroupRecording {
        var request: [String: Any] = ["call": name, "record": action]
        if let recording { request["recording"] = recording }
        if let recorder { request["recorder"] = recorder.anyValue }
        let answer = try await route(request)
        guard
            let told = answer["recording"] as? [String: Any],
            let id = told["id"] as? String, !id.isEmpty,
            let state = told["state"] as? String
        else { throw CallError("server") }
        return GroupRecording(id: id, state: state)
    }

    /// A request on the socket the connection holds now, or on `via`; nil when it didn't answer.
    func ask(_ event: String, _ payload: [String: JSONValue], via: ModuleSocket? = nil) async -> JSONValue? {
        await withCheckedContinuation { continuation in
            rt.moduleQueue.async { [rt] in
                guard let socket = via ?? rt.currentSocket else { return continuation.resume(returning: nil) }
                socket.emit(event, .object(payload), timeout: 8) { reply in continuation.resume(returning: reply) }
            }
        }
    }

    func transport(token: @escaping () -> String) -> CallTransport {
        SdkCallTransport(calls: self, token: token)
    }

    func listen(_ key: String, _ handler: @escaping (JSONValue) -> Void) -> () -> Void {
        dispatch[key] = handler
        return { [weak self] in self?.dispatch[key] = nil }
    }

    func onSocketChange(_ listener: @escaping () -> Void) -> () -> Void {
        let id = UUID()
        socketListeners[id] = listener
        return { [weak self] in self?.socketListeners[id] = nil }
    }

    /// The relay's events for a call, to the session they name: every app on the socket hears all of them.
    private func relayed(_ message: JSONValue) {
        guard let call = message["call_id"]?.id, let session = message["session"]?.string else { return }
        dispatch["\(call):\(session)"]?(message)
    }

    // MARK: - The line, on the module queue

    /// Holds the line on a socket, asking the app's server for it when it has none or it runs out within a minute.
    private func holdLine(via socket: ModuleSocket, _ done: @escaping () -> Void) {
        // The line is `/channels`' own: on another product's namespace, its calls ring that product's way.
        guard ringOn, rt.namespace == RealtimeOptions.channels else { return done() }
        let now = Date().timeIntervalSince1970
        if let held = line, held.exp - now > 60 {
            return sendLine(held.token, via: socket, done)
        }
        Task {
            do {
                let grant = try await authorize(["line": true])
                let token = grant["token"] as? String ?? ""
                let exp = (grant["exp"] as? NSNumber)?.doubleValue ?? (Date().timeIntervalSince1970 + 3600)
                rt.moduleQueue.async { [self] in
                    line = (token, exp)
                    sendLine(token, via: socket, done)
                }
            } catch {
                // An app with no signed-in user has no line: nothing rings here.
                let code = (error as? CallError)?.code ?? "auth_failed"
                rt.moduleQueue.async { [self] in
                    line = nil
                    if code != "no_user" { fail(code) }
                    done()
                }
            }
        }
    }

    private func sendLine(_ token: String, via socket: ModuleSocket, _ done: @escaping () -> Void) {
        var payload: [String: JSONValue] = ["tab": .string(rt.tab), "token": .string(token)]
        // This phone, so its user's calls ring it with the app closed too (SystemCalls).
        if let push = SystemCalls.shared.linePush() { payload["push"] = push }
        let askedAt = Date()
        socket.emit("line", .object(payload), timeout: 8) { [self] reply in
            rt.moduleQueue.async { [self] in
                defer { done() }
                guard let reply, reply["ok"]?.bool == true else {
                    if reply?["error"]?.string == "expired" { line = nil }
                    if let reply { fail(reply["error"]?.string ?? "server") }
                    return
                }
                var ids = Set<String>()
                for ring in reply["ringing"]?.array ?? [] {
                    if let message = ring.anyValue as? [String: Any] {
                        if let id = message["id"] as? String { ids.insert(id) }
                        incomingRing(message, info: ring["info"] ?? .null)
                    }
                }
                SystemCalls.shared.lineHeld(ringing: ids, askedAt: askedAt, keyring: rt.keyring)
                scheduleLineRenewal()
            }
        }
    }

    private func scheduleLineRenewal() {
        lineRenewal?.cancel()
        guard let held = line else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.line = nil
            if let socket = self.rt.currentSocket { self.holdLine(via: socket) {} }
        }
        lineRenewal = work
        rt.moduleQueue.asyncAfter(deadline: .now() + max(30, held.exp - 600 - Date().timeIntervalSince1970), execute: work)
    }

    func fail(_ code: String) {
        DispatchQueue.main.async { self.errorHandlers.fire(code) }
    }

    func onLine(_ message: [String: Any], info: JSONValue) {
        guard let id = message["id"] as? String else { return }
        switch message["op"] as? String {
        case "incoming":
            incomingRing(message, info: info)
        case "ring_over":
            let reason = message["reason"] as? String ?? "ended"
            DispatchQueue.main.async {
                SystemCalls.shared.ringOver(id, reason: reason)
                guard let incoming = self.ringing.removeValue(forKey: id) else { return }
                incoming.over(reason)
            }
        case "invite":
            let told = JSONValue.from(any: message)
            DispatchQueue.main.async { self.heardInvite(told) }
        default:
            break
        }
    }

    /// A call ringing: shown once the caller's info opens (the app's server seals it with the day's key).
    private func incomingRing(_ message: [String: Any], info: JSONValue) {
        rt.ensureKeys(for: info) { [weak self] in
            guard let self else { return }
            let opened = self.rt.keyring.openJSON(info) ?? .null
            DispatchQueue.main.async {
                guard let id = message["id"] as? String, self.ringing[id] == nil, self.active[id] == nil else { return }
                let incoming = IncomingCall(owner: self, message: message, info: opened)
                self.ringing[id] = incoming
                // The ring a push reported to the system, now on the line; or one during a call, answered busy.
                if SystemCalls.shared.ringArrived(incoming) { return }
                self.incomingHandlers.fire(incoming)
            }
        }
    }

    /// How many questions go in one request of `may`, as the browser's (calls.ts, MAY_AT_ONCE).
    static let mayAtOnce = 100

    /// The people an answer lists, leaving out any with no valid id or name.
    static func people(in answer: JSONValue) -> [CallPerson] {
        (answer["people"]?.array ?? []).compactMap { person in
            guard let id = user(person["id"]), let name = person["name"]?.string else { return nil }
            return CallPerson(id: id, name: name, avatar: person["avatar"]?.string)
        }
    }

    /// A user as the relay names them, in the SDK's spelling, as the browser's read them (calls/users.ts, callUserOf):
    /// a whole number, or at most 64 characters with no space or control character in them. Nil for anything else, and 0
    /// is nobody.
    static func user(_ value: JSONValue?) -> String? {
        switch value {
        case let .number(number):
            guard number == number.rounded(), number != 0, abs(number) < 9_007_199_254_740_992 else { return nil }
            return String(Int64(number))
        case let .string(text):
            guard (1...64).contains(text.utf16.count), text != "0" else { return nil }
            let refused = text.unicodeScalars.contains { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7f }
            return refused ? nil : text
        default:
            return nil
        }
    }

    /// A user id as the relay takes it: a number for an id of digits, written as the number is (`42`, not `042`), and any
    /// other id as the text it is, as the realtime server reads them (a UUID, `auth0|5f7c…`).
    static func userValue(_ user: String) -> Any {
        guard let number = Int(user), String(number) == user, number != 0, abs(number) < 1 << 53 else { return user }
        return number
    }
}

public extension Realtime {
    /// Calls between the app's users, on this connection.
    var calls: RealtimeCalls { RealtimeCalls.of(self) }

    /// Calls `user` about `name`, which your server's `calls()` rule owns: rings their every open tab and device. `{pair}`
    /// in the name is the two ids in order, so either side names the same call: `rt.call("support:{pair}", to: "34")`.
    @MainActor
    func call(_ name: String, to user: String, type: CallType = .video) async throws -> Call {
        try await calls.start(name, to: user, type: type)
    }

    /// Joins the group call `name`, which your server's `groupCalls()` rule owns.
    @MainActor
    func groupCall(_ name: String, type: CallType = .video) async throws -> GroupCall {
        try await calls.group(name, type: type)
    }

    /// Joins the live stream `name`, as your server's `streams()` rule makes this user its host, a guest or a viewer.
    /// `video: false` for an app that shows only the chat or the details.
    @MainActor
    func stream(_ name: String, video: Bool = true) async throws -> LiveStream {
        try await calls.stream(name, video: video)
    }

    /// Starts a call with a token from your own server (`realtime.callToken( user, to )` there), and rings the person it
    /// names on every tab and device they have open. A token rings once, so get a new one for each call. Throws its code.
    @MainActor
    func startCall(_ token: String) async throws -> Call {
        try await calls.startCall(token)
    }

    /// Joins a group call with a token from your own server (`realtime.groupCallToken( user, name, options )` there), which
    /// says what this user may do in it. Someone taken out of the call needs a new token to come back. Throws its code.
    @MainActor
    func joinGroupCall(_ token: String) async throws -> GroupCall {
        try await calls.joinGroupCall(token)
    }

    /// Joins a live stream as your own server says (`realtime.streamToken( user, name, options )` there). A token lasts ten
    /// minutes, so `getToken` gets one from your route: it is asked again as each runs out, and your route may then say no.
    /// `video: false` for an app that shows only the chat or the details. Throws its code.
    @MainActor
    func joinStream(getToken: @escaping () async throws -> String, video: Bool = true) async throws -> LiveStream {
        try await calls.joinStream(getToken: getToken, video: video)
    }

    /// Joins a live stream with one token from your own server, for a screen that won't outlast it: `expired` once it needs
    /// another. `joinStream(getToken:)` is for anything longer.
    @MainActor
    func joinStream(_ token: String, video: Bool = true) async throws -> LiveStream {
        try await calls.joinStream(token, video: video)
    }
}

/// The relay on the realtime connection: the `call` request, with the call's token, since the socket is the app's.
final class SdkCallTransport: CallTransport {
    private unowned let calls: RealtimeCalls
    private let token: () -> String

    init(calls: RealtimeCalls, token: @escaping () -> String) {
        self.calls = calls
        self.token = token
    }

    var connected: Bool { calls.connectedAsked ?? (calls.rt.state == .connected) }

    func send(_ payload: JSONValue, ack: ((JSONValue?) -> Void)?) {
        var body = payload.object ?? [:]
        body["tab"] = .string(calls.rt.tab)
        body["token"] = .string(token())
        let json = JSONValue.object(body)
        let rt = calls.rt
        // The engine takes the answer to the main queue.
        rt.moduleQueue.async {
            guard let socket = rt.currentSocket else {
                ack?(nil)
                return
            }
            guard let ack else { return socket.emit("call", json) }
            socket.emit("call", json, timeout: 10, ack: ack)
        }
    }

    func listen(callId: String, session: String, _ handler: @escaping (JSONValue) -> Void) -> () -> Void {
        calls.listen("\(callId):\(session)", handler)
    }

    func onReconnect(_ listener: @escaping () -> Void) -> () -> Void {
        calls.onSocketChange(listener)
    }
}

/// A call ringing for this app's user. `onOver` (the reason) when it stops ringing: answered or declined, here or
/// elsewhere, the caller gave up …
public final class IncomingCall: @unchecked Sendable {
    public enum State: String, Sendable { case ringing, answered, declined, over }

    public let id: String
    /// The app's name for the call, such as `support:34:42`.
    public let call: String
    /// Who calls, and what the app's server said about them, opened.
    public let from: String
    public let info: JSONValue
    public let type: CallType
    /// The group call it rings into, for a ring into one; nil for a call between two people.
    public let group: String?
    public private(set) var state: State = .ringing
    public private(set) var reason: String?
    /// What a ring brought for the app's server: for one into a group call the call's pair, and the proof this user was
    /// rung, which a call from a token of the app's server carries inside the caller's info.
    let pair: Any?
    let ring: String?
    private unowned let owner: RealtimeCalls
    private var overHandlers = CallHandlers<String>()

    init(owner: RealtimeCalls, message: [String: Any], info: JSONValue) {
        self.owner = owner
        id = message["id"] as? String ?? ""
        call = message["call"] as? String ?? ""
        from = message["from"].map { "\($0)" } ?? ""
        let opened = Self.opened(info)
        self.info = opened.info
        type = (message["type"] as? String) == "audio" ? .audio : .video
        group = (message["group"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        pair = message["pair"] as? [Any]
        ring = opened.ring ?? message["ring"] as? String
    }

    /// The caller's info as the app sees it, and the proof it carried. That proof is for the calls route alone, and not
    /// part of what the app said about the caller.
    static func opened(_ info: JSONValue) -> (info: JSONValue, ring: String?) {
        guard var fields = info.object, let ring = fields["_ring"]?.string else { return (info, nil) }
        fields["_ring"] = nil
        return (fields.isEmpty ? .null : .object(fields), ring)
    }

    /// When it stops ringing, with the reason. On the main queue.
    @discardableResult
    public func onOver(_ handler: @escaping (String) -> Void) -> CallListener {
        overHandlers.add(handler)
    }

    /// Takes a handler off. On the main queue.
    public func off(_ listener: CallListener) {
        overHandlers.remove(listener)
    }

    /// What answering gives: the call, or for a ring into a group call (`group`) the GroupCall.
    public enum Answered {
        case call(Call)
        case group(GroupCall)
    }

    /// Answers: the call, connecting, or the group call it rings into. Throws its code, such as `forbidden` when the
    /// app's server said no.
    @MainActor
    public func accept() async throws -> Answered {
        guard state == .ringing else { throw CallError(reason ?? "not_ringing") }
        // Through the system's own answer when it rings there too (SystemCalls), so it is answered once.
        if let answered = try await SystemCalls.shared.answer(self) { return answered }
        return try await acceptNow()
    }

    /// The answer itself, from the app or from the system's screen.
    @MainActor
    func acceptNow() async throws -> Answered {
        guard state == .ringing else { throw CallError(reason ?? "not_ringing") }
        state = .answered
        // It rings no more, wherever it shows.
        overHandlers.fire("answered")
        CallAudio.configure(video: type == .video)
        let answered: Answered = try await {
            if let group { return .group(try await owner.answerGroup(self, group: group)) }
            return .call(try await owner.answer(self))
        }()
        SystemCalls.shared.answered(id, answered)
        return answered
    }

    /// Turns it down, or says this user is busy: it ends for the caller, and stops ringing everywhere else.
    public func decline(busy: Bool = false) async throws {
        guard state == .ringing else { return }
        state = .declined
        let reason = busy ? "busy" : "declined"
        overHandlers.fire(reason)
        SystemCalls.shared.declined(id)
        try await owner.decline(self, reason: reason)
    }

    func over(_ reason: String) {
        guard state == .ringing else { return }
        state = .over
        self.reason = reason
        overHandlers.fire(reason)
    }
}

/**
 A call between two people: straight between them, through TURN when no direct path works. The app's microphone and,
 for a video call, camera go on it as the call connects; `microphone` and `camera` switch them. `onState`, `onRemote`
 (what the other side sends changed), `onEnded` (the reason). Everything on the main queue.
 */
public final class Call: @unchecked Sendable {
    public enum Role: String, Sendable { case caller, callee }

    public let id: String
    public let name: String
    public let type: CallType
    public let role: Role
    /// The other side: their user id, and what the app's server said about them (a callee has the caller's).
    public let peer: String
    public let peerInfo: JSONValue
    public private(set) var state: CallState
    public private(set) var path: CallPath?
    public private(set) var endReason: String?
    /// What the other side has on: `camera`, `microphone`, `screen_share`, `screen_share_audio`.
    public var remoteMedia: [String: Bool] { session.remoteState }
    /// Whether the other side's media is arriving: the connection is up and carrying it.
    public private(set) var bytesReceived = 0

    private unowned let owner: RealtimeCalls
    private var token: String
    /// What asks the calls route for a new token as this one runs out.
    let request: [String: Any]
    private(set) var session: CallSession!
    /// The key the call's rooms encrypt their media with, and the call's two people with this user's proof of being in
    /// it, from the app's server: what a room, and ringing someone in, need.
    private var mediaKey: String?
    private var proofs: (pair: Any?, member: String?)
    /// The room carrying the call when neither path could.
    private var room: GroupCall?
    private var movingToGroup = false
    private var stateHandlers = CallHandlers<CallState>()
    private var pathHandlers = CallHandlers<CallPath>()
    private var waitingHandlers = CallHandlers<CallWait>()
    private var remoteHandlers = CallHandlers<Void>()
    private var endHandlers = CallHandlers<String>()
    private var groupHandlers = CallHandlers<GroupCall>()
    private var screenHandlers = CallHandlers<Bool>()
    private var sharing = false
    #if os(iOS)
    private var broadcast: CallBroadcast?
    #endif
    private var renewal: DispatchWorkItem?
    private var connectedOnce = false
    private var microphoneOn = true
    private var cameraOn: Bool
    private var preferFront = true
    /// Carried by a transport of the app's own (`RealtimeCalls.call(over:…)`): no token of the SDK's to renew, and no
    /// group call of the SDK's to add people in.
    private let carried: Bool
    /// Where the call's room is on the mesh, for a relay that hands one over by its token alone.
    private let roomServer: String?

    @MainActor
    init(owner: RealtimeCalls, id: String, name: String, type: CallType, role: Role, peer: String, peerInfo: JSONValue, request: [String: Any], grant: [String: Any], transport: CallTransport? = nil, roomServer: String? = nil) {
        self.owner = owner
        self.id = id
        self.name = name
        self.type = type
        self.role = role
        self.peer = peer
        self.peerInfo = peerInfo
        self.request = request
        token = grant["token"] as? String ?? ""
        mediaKey = grant["media_key"] as? String
        proofs = (grant["pair"], grant["member"] as? String)
        state = role == .caller ? .ringing : .connecting
        cameraOn = type == .video
        carried = transport != nil
        self.roomServer = roomServer
        session = CallSession(transport: transport ?? owner.transport { [weak self] in self?.token ?? "" }, callId: id, video: type == .video, signalKey: grant["key"] as? String ?? "")
        if !carried { scheduleRenewal((grant["exp"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 + 3600) }

        session.onPeerJoined = { [weak self] in
            if self?.state == .ringing { self?.set(.connecting) }
        }
        session.onConnection = { [weak self] connection in
            guard let self else { return }
            switch connection {
            case .connected:
                self.connectedOnce = true
                self.set(.connected)
            case .reconnecting:
                self.set(.reconnecting)
            case .connecting where self.state != .ringing:
                self.set(self.connectedOnce ? .reconnecting : .connecting)
            default:
                break
            }
        }
        session.onRemote = { [weak self] in self?.remoteHandlers.fire() }
        session.onStats = { [weak self] stats in
            guard let self else { return }
            self.bytesReceived = stats.bytesReceived
            if stats.candidateLocal != nil || stats.candidateRemote != nil {
                self.setPath(stats.candidateLocal == "relay" || stats.candidateRemote == "relay" ? .relay : .direct)
            }
        }
        session.onReacquire = { [weak self] source in self?.reacquire(source) }
        session.onFallback = { [weak self] ticket in self?.toRoom(ticket) }
        // Someone was added: the relay ends the call between two people as `group`, and it goes on in the group's room.
        session.onEnded = { [weak self] reason in
            if reason == "group" { self?.toGroup() } else { self?.finish(reason) }
        }
    }

    /// Someone was added and the call goes on as a group call there: hand it to the app before the call ends as `group`.
    @discardableResult
    public func onGroup(_ handler: @escaping (GroupCall) -> Void) -> CallListener { groupHandlers.add(handler) }

    /// Rings someone into the call, which becomes a group call: both sides go on in a room of its own on the mesh, and they
    /// arrive there once they answer. Takes a token from the app's own server, `callToken( user, to, { into: call.ref } )`,
    /// which decided they may be added, or a user id, which a rule of the app's decides. Throws its code: `not_connected`
    /// before the call is up, `forbidden` for a token made for another call, or a refusal of the app's server or the realtime
    /// server. `not_supported` for a call on a transport of the app's own, whose product adds people its own way.
    @MainActor
    public func add(_ who: String) async throws -> CallInvite {
        guard !carried else { throw CallError("not_supported") }
        guard state == .connected || state == .reconnecting else { throw CallError("not_connected") }
        return try await owner.addTo(groupLink, who: who)
    }

    /// What the app sends its route to ring someone into this call: `realtime.callToken( user, to, { into: ref } )`.
    public var ref: String { CallTokens.ref(of: groupLink) }

    private var groupLink: GroupOf {
        GroupOf(id: id, name: name, type: type, pair: proofs.pair, member: proofs.member)
    }

    /// Someone was added: the call goes on in the group call's room, encrypted with the call's key, with what this side
    /// sends, and the app gets it before the call ends as `group`.
    private func toGroup() {
        guard !movingToGroup, state != .ended else { return }
        // A group call of another product's is that product's to join: the call ends as `group`, and the app follows it.
        guard !carried else { return finish("group") }
        movingToGroup = true
        Task { @MainActor in
            do {
                self.stopMedia()
                let group = try await self.owner.joinGroup(self.groupLink, token: self.token, mediaKey: self.mediaKey, microphone: self.microphoneOn, camera: self.cameraOn)
                self.setPath(.room)
                SystemCalls.shared.moved(self, to: group)
                self.groupHandlers.fire(group)
                self.finish("group")
            } catch {
                self.finish("group_failed")
            }
        }
    }

    /// Neither the direct path nor TURN carried the call: it goes on in a room on the mesh, encrypted with the call's
    /// key, as the direct path is.
    func toRoom(_ ticket: CallRoomTicket) {
        guard room == nil, state != .ended else { return }
        setPath(.room)
        set(.connecting)
        stopMedia()
        Task { @MainActor in
            let room = self.owner.handoffRoom(name: self.name, ticket: ticket.at(self.roomServer), mediaKey: self.mediaKey, microphone: self.microphoneOn, camera: self.cameraOn)
            self.room = room
            room.onState { [weak self] state in
                switch state {
                case .connected: self?.set(.connected)
                case .reconnecting: self?.set(.reconnecting)
                default: break
                }
            }
            room.onWaiting { [weak self] wait in self?.waitingHandlers.fire(wait) }
            room.onPeople { [weak self] in self?.remoteHandlers.fire() }
            room.onEnded { [weak self] _ in
                guard let self, self.state != .ended else { return }
                self.session.leaveAfterHandoff("room_lost")
                self.finish("room_lost")
            }
        }
    }

    /// The direct path's own microphone and camera let go: a room opens its own.
    private func stopMedia() {
        stopSharing()
        CallMedia.shared.stopCamera()
        CallMedia.shared.setMicrophoneEnabled(false)
    }

    /// The state as it changes.
    @discardableResult
    public func onState(_ handler: @escaping (CallState) -> Void) -> CallListener { stateHandlers.add(handler) }

    /// What carries the call changed: `direct`, `relay` or `room`.
    @discardableResult
    public func onPath(_ handler: @escaping (CallPath) -> Void) -> CallListener { pathHandlers.add(handler) }

    /// The room the call moved to waits for a place on the mesh: until when, and why. The state stays `connecting`, and
    /// it goes on by itself.
    @discardableResult
    public func onWaiting(_ handler: @escaping (CallWait) -> Void) -> CallListener { waitingHandlers.add(handler) }

    /// The other side's media or tracks changed.
    @discardableResult
    public func onRemote(_ handler: @escaping () -> Void) -> CallListener { remoteHandlers.add { _ in handler() } }

    /// This app began or stopped sharing its screen: said once it did, the system's own red bar included.
    @discardableResult
    public func onScreenShare(_ handler: @escaping (Bool) -> Void) -> CallListener { screenHandlers.add(handler) }

    /// The call ended, with the reason: `hangup`, `declined`, `busy`, `cancelled`, `connection_failed` …
    @discardableResult
    public func onEnded(_ handler: @escaping (String) -> Void) -> CallListener { endHandlers.add(handler) }

    /// Takes a handler off.
    public func off(_ listener: CallListener) {
        stateHandlers.remove(listener)
        pathHandlers.remove(listener)
        waitingHandlers.remove(listener)
        remoteHandlers.remove(listener)
        endHandlers.remove(listener)
        groupHandlers.remove(listener)
        screenHandlers.remove(listener)
    }

    /// Whether this app is sharing its screen on the call: frames are going out.
    public var sharingScreen: Bool { room?.sharingScreen ?? sharing }

    /// Shares this phone's screen, or stops. To share it needs the app's broadcast extension (`ScreenShare`), and puts up the
    /// system's picker: true says it was asked, and `onScreenShare` says when the share begins. False before the call is up,
    /// and without the extension.
    @MainActor
    @discardableResult
    public func setScreenShare(_ on: Bool) async -> Bool {
        guard state == .connected || state == .reconnecting else { return false }
        if let room { return await room.setScreenShare(on) }
        guard on else {
            stopSharing()
            return false
        }
        guard ScreenShare.isAvailable else { return false }
        #if os(iOS)
        if broadcast != nil { return true }
        let share = CallBroadcast()
        broadcast = share
        share.onStarted = { [weak self, weak share] in
            guard let self, let share, let track = share.screenTrack else { return }
            let height = share.captureHeight
            DispatchQueue.main.async { self.startedSharing(track, height: height) }
        }
        share.onStopped = { [weak self] in self?.stopSharing() }
        guard await share.start(with: CallMedia.shared.factory) else {
            broadcast = nil
            return false
        }
        share.request()
        return true
        #else
        return false
        #endif
    }

    /// The first frame arrived: the screen on the call, and said.
    func startedSharing(_ track: LKRTCVideoTrack, height: Int) {
        guard !sharing, state != .ended else { return }
        sharing = true
        session.setLocalTrack(.screenShare, track, height: height)
        screenHandlers.fire(true)
    }

    /// The screen off the call, and its capture let go. A broadcast outlives the call that started it unless told.
    private func stopSharing() {
        #if os(iOS)
        broadcast?.stop()
        broadcast = nil
        #endif
        guard sharing else { return }
        sharing = false
        session.setLocalTrack(.screenShare, nil)
        screenHandlers.fire(false)
    }

    /// Whether this side's microphone is heard.
    public var microphone: Bool {
        get { microphoneOn }
        set {
            microphoneOn = newValue
            CallMedia.shared.setMicrophoneEnabled(newValue)
            if let track = CallMedia.shared.microphoneTrack { session.setLocalTrack(.microphone, newValue ? track : nil) }
            SystemCalls.shared.microphone(newValue, call: self)
        }
    }

    /// Whether this side's camera is sent.
    public var camera: Bool {
        get { cameraOn }
        set {
            cameraOn = newValue
            if newValue { startCamera() } else {
                session.setLocalTrack(.camera, nil)
                CallMedia.shared.stopCamera()
            }
        }
    }

    /// The other side's camera, to draw (CallVideoView).
    public var remoteCamera: CallVideoTrack? {
        (session.remoteTracks[.camera] as? LKRTCVideoTrack).map(CallVideoTrack.init)
    }

    /// The screen the other side shares, to draw (CallVideoView), while it comes: `remoteMedia["screen_share"]` says they
    /// share one. As the browser's `remote.screen`.
    public var remoteScreen: CallVideoTrack? {
        (session.remoteTracks[.screenShare] as? LKRTCVideoTrack).map(CallVideoTrack.init)
    }

    /// This side's camera, for its own picture.
    public var localCamera: CallVideoTrack? {
        CallMedia.shared.cameraTrack.map(CallVideoTrack.init)
    }

    /// Hangs up, or calls it off while it still rings (`cancelled`).
    public func end() {
        guard state != .ended else { return }
        SystemCalls.shared.endingHere(call: self)
        let reason = state == .ringing ? "cancelled" : "hangup"
        if room != nil { session.leaveAfterHandoff(reason) } else { session.end(reason) }
        finish(reason)
    }

    /// Turns the camera round, the front one to the back and back, while it is sent.
    public func flipCamera() {
        guard cameraOn, state != .ended else { return }
        if let room {
            room.flipCamera()
            return
        }
        CallMedia.shared.flipCamera { [weak self] track in
            guard let self, let track, self.cameraOn, self.state != .ended else { return }
            self.session.setLocalTrack(.camera, track, height: CallMedia.shared.captureHeight)
            self.remoteHandlers.fire()
        }
    }

    /// Whether the camera sent is the front one, or while none is sent, the one that opens next.
    public var frontCamera: Bool {
        if let room { return room.frontCamera }
        return cameraOn ? CallMedia.shared.usingFrontCamera : preferFront
    }

    /// The side the next camera opens on, while none is sent: a camera on turns round with `flipCamera()`. Nothing opens.
    public func preferCamera(front: Bool) {
        preferFront = front
        room?.preferCamera(front: front)
    }

    /// How loud this app's microphone is while it is sent, from 0 to 1, for a meter: nil while it is not. In a call between
    /// two it is read off the connection's report, every two seconds.
    public var microphoneLevel: Float? {
        if let room { return room.microphoneLevel }
        guard microphoneOn else { return nil }
        return session.stats.microphoneLevel.map { Float($0) }
    }

    /// Joins the call: as its caller, that makes it ring. The microphone and camera are opened as it is joined.
    @MainActor
    func begin() async throws {
        await openMedia()
        let joined = await withCheckedContinuation { continuation in session.start { continuation.resume(returning: $0) } }
        if !joined {
            finish(endReason ?? "not_started")
            throw CallError(endReason ?? "not_started")
        }
    }

    @MainActor
    private func openMedia() async {
        if await CallPermissions.microphone() {
            let track = CallMedia.shared.startMicrophone()
            CallMedia.shared.setMicrophoneEnabled(microphoneOn)
            session.setLocalTrack(.microphone, track)
        }
        if cameraOn { startCamera() }
    }

    private func startCamera() {
        Task { @MainActor in
            guard await CallPermissions.camera() else {
                self.cameraOn = false
                return
            }
            CallMedia.shared.startCamera(front: self.preferFront) { [weak self] track in
                guard let self, self.cameraOn, self.state != .ended else { return }
                guard let track else {
                    self.cameraOn = false
                    return
                }
                self.session.setLocalTrack(.camera, track, height: CallMedia.shared.captureHeight)
                self.remoteHandlers.fire()
            }
        }
    }

    private func reacquire(_ source: CallSource) {
        guard state != .ended else { return }
        if source == .microphone {
            let track = CallMedia.shared.restartMicrophone()
            CallMedia.shared.setMicrophoneEnabled(microphoneOn)
            session.setLocalTrack(.microphone, microphoneOn ? track : nil)
        } else if source == .camera, cameraOn {
            CallMedia.shared.stopCamera()
            startCamera()
        }
    }

    private func set(_ next: CallState) {
        guard state != next, state != .ended else { return }
        state = next
        stateHandlers.fire(next)
    }

    func setPath(_ next: CallPath) {
        guard path != next else { return }
        path = next
        pathHandlers.fire(next)
    }

    /// The token asked for again ten minutes before it runs out, so a join after a long drop still has one.
    private func scheduleRenewal(_ exp: Double) {
        renewal?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state != .ended else { return }
            Task {
                do {
                    let grant = try await self.owner.authorize(self.request)
                    await MainActor.run {
                        self.token = grant["token"] as? String ?? self.token
                        self.scheduleRenewal((grant["exp"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 + 3600)
                    }
                } catch {
                    await MainActor.run { self.scheduleRenewal(Date().timeIntervalSince1970 + 660) }
                }
            }
        }
        renewal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(30, exp - 600 - Date().timeIntervalSince1970), execute: work)
    }

    private func finish(_ reason: String) {
        guard state != .ended else { return }
        endReason = reason
        state = .ended
        renewal?.cancel()
        room?.leave()
        stopSharing()
        CallMedia.shared.stopCamera()
        CallMedia.shared.setMicrophoneEnabled(false)
        owner.forget(self)
        stateHandlers.fire(.ended)
        endHandlers.fire(reason)
    }
}

/// A video track of a call, for CallVideoView.
public struct CallVideoTrack {
    let track: LKRTCVideoTrack
}

// What the SDK's call screens (WordPlusRealtimeUI) draw from, behind `@_spi(WordPlusUI)`: a direct call's libwebrtc
// tracks, and the room a call moved to, whose tracks are LiveKit's. Not the SDK's API: an app draws with CallVideoView.
extension CallVideoTrack {
    @_spi(WordPlusUI) public var rtcTrack: LKRTCVideoTrack { track }
}

extension Call {
    /// The room carrying this call after neither the direct path nor TURN could: nil while it is direct.
    @_spi(WordPlusUI) public var carryingRoom: GroupCall? { room }

    /// The calls it is one of, for whom the screen offers to add.
    @_spi(WordPlusUI) public var calls: RealtimeCalls { owner }
}

/// The microphone and camera permissions, asked for once.
enum CallPermissions {
    /// What the system would answer, for the tests, which have no app to ask for.
    static var answerAsked: ((AVMediaType) -> Bool)?

    static func microphone() async -> Bool {
        if let answerAsked { return answerAsked(.audio) }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func camera() async -> Bool {
        if let answerAsked { return answerAsked(.video) }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}
