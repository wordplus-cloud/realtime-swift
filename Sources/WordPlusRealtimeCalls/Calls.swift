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
    public init(_ code: String) { self.code = code }
    public var description: String { "CallError(\(code))" }
}

/**
 Calls between the app's users, on the realtime connection (`rt.calls`), as the browser's `calls()`: the same relay,
 the same call engine as Better Messages' apps, so a phone and a browser call each other.

     rt.calls.onIncoming { incoming in show(incoming) }       // incoming.accept() or incoming.decline()
     let call = try await rt.calls.start("support:34:42", to: "34", type: .audio)
     call.onState { state in … }

 The app's server decides who may call whom: each call and line is a token its calls route signs (`{endpoint}/calls`,
 the server package's `calls()`). Calls ring while the app is open. With `SystemCalls` started they ring a locked phone
 and a closed app too, through CallKit, as the Better Messages app's calls do.
 */
public final class RealtimeCalls: @unchecked Sendable {
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
    private var dispatch: [String: ([String: Any]) -> Void] = [:]
    private var socketListeners: [UUID: () -> Void] = [:]
    private var incomingHandlers: [(IncomingCall) -> Void] = []
    private var errorHandlers: [(String) -> Void] = []
    private var ringing: [String: IncomingCall] = [:]
    private var active: [String: Call] = [:]
    // The line and its renewal: on the module queue.
    private var line: (token: String, exp: Double)?
    private var lineRenewal: DispatchWorkItem?
    private var ringOn = true

    private init(_ rt: Realtime) {
        self.rt = rt
        rt.onSocketEvent("call") { [weak self] data in
            guard let message = data.anyValue as? [String: Any] else { return }
            DispatchQueue.main.async { self?.relayed(message) }
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
    public func onIncoming(_ handler: @escaping (IncomingCall) -> Void) {
        DispatchQueue.main.async { self.incomingHandlers.append(handler) }
    }

    /// What went wrong with the line (`what` is `line`): its code.
    public func onError(_ handler: @escaping (String) -> Void) {
        DispatchQueue.main.async { self.errorHandlers.append(handler) }
    }

    /// The calls ringing for this app's user now. On the main queue.
    public var incoming: [IncomingCall] { Array(ringing.values) }

    /// Calls `user` about `name`, a call the app's server allows: rings their every open app and page. Throws its code.
    @MainActor
    public func start(_ name: String, to user: String, type: CallType = .video) async throws -> Call {
        let id = CallSignaling.randomId(20)
        let request: [String: Any] = ["call": name, "id": id, "role": "caller", "to": RealtimeCalls.userValue(user), "type": type.rawValue]
        let grant = try await authorize(request)
        let call = Call(owner: self, id: id, name: name, type: type, role: .caller, peer: user, peerInfo: .null, request: request, grant: grant)
        active[id] = call
        // The system knows of it before it starts, which gives it the audio session (SystemCalls, when started).
        SystemCalls.shared.outgoing(call)
        try await call.begin()
        return call
    }

    /// A group call `name` on the mesh, encrypted end to end when its rule says so. Nothing is sent into it until
    /// `microphone` or `camera` say so. Throws its code.
    @MainActor
    public func group(_ name: String, type: CallType = .video) async throws -> GroupCall {
        let grant = try await authorize(["room": name, "type": type.rawValue])
        let place = await ask("room", ["tab": .string(rt.tab), "token": .string(grant["token"] as? String ?? "")])
        guard place?["ok"]?.bool == true else { throw CallError(place?["error"]?.string ?? "server") }
        let room = GroupCall(owner: self, name: name, link: nil, key: grant["media_key"] as? String, microphone: false, camera: false)
        SystemCalls.shared.outgoing(room, type: type)
        connect(room, place: place)
        return room
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

    /// A place in a group call's room, with the token of the call it was made from or of the ring answered.
    @MainActor
    func joinGroup(_ link: GroupOf, token: String, mediaKey: String?, microphone: Bool, camera: Bool) async throws -> GroupCall {
        let place = await ask("group", ["tab": .string(rt.tab), "token": .string(token)])
        guard place?["ok"]?.bool == true else { throw CallError(place?["error"]?.string ?? "server") }
        let room = GroupCall(owner: self, name: link.name, link: link, key: mediaKey, microphone: microphone, camera: camera)
        connect(room, place: place)
        return room
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
        var payload: [String: JSONValue] = ["tab": .string(rt.tab), "token": .string(grant["token"] as? String ?? "")]
        if let ring = grant["ring"] as? String { payload["ring"] = .string(ring) }
        let reply = await ask("invite", payload)
        guard reply?["ok"]?.bool == true else { throw CallError(reply?["error"]?.string ?? "server") }
        return CallInvite(id: id, to: user, state: reply?["state"]?.string ?? "ringing")
    }

    /// A room joined in the background: one that fails is left, and said so.
    private func connect(_ room: GroupCall, place: JSONValue?) {
        let server = place?["server"]?.string ?? ""
        let token = place?["token"]?.string ?? ""
        let ice = place?["ice_servers"]?.anyValue as? [[String: Any]] ?? []
        Task {
            do {
                try await room.connect(server: server, token: token, iceServers: ice)
            } catch {
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
        let request: [String: Any] = ["call": incoming.call, "id": incoming.id, "role": "callee", "from": RealtimeCalls.userValue(incoming.from), "type": incoming.type.rawValue]
        let grant = try await authorize(request)
        let call = Call(owner: self, id: incoming.id, name: incoming.call, type: incoming.type, role: .callee, peer: incoming.from, peerInfo: incoming.info, request: request, grant: grant)
        ringing[incoming.id] = nil
        active[incoming.id] = call
        try await call.begin()
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
        let body = (JSONValue.from(any: request).object) ?? [:]
        let (status, answer): (Int, JSONValue?) = await withCheckedContinuation { continuation in
            rt.postRoute("calls", body) { status, answer in continuation.resume(returning: (status, answer)) }
        }
        if status == 401 || status == 403 { throw CallError(answer?["denied"]?.string ?? "forbidden") }
        guard status == 200, let grant = answer?.anyValue as? [String: Any] else { throw CallError("auth_failed") }
        if let denied = grant["denied"] as? String { throw CallError(denied) }
        guard let token = grant["token"] as? String, !token.isEmpty else { throw CallError("auth_failed") }
        return grant
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

    func listen(_ key: String, _ handler: @escaping ([String: Any]) -> Void) -> () -> Void {
        dispatch[key] = handler
        return { [weak self] in self?.dispatch[key] = nil }
    }

    func onSocketChange(_ listener: @escaping () -> Void) -> () -> Void {
        let id = UUID()
        socketListeners[id] = listener
        return { [weak self] in self?.socketListeners[id] = nil }
    }

    /// The relay's events for a call, to the session they name: every app on the socket hears all of them.
    private func relayed(_ message: [String: Any]) {
        guard let call = message["call_id"], let session = message["session"] as? String else { return }
        dispatch["\(call):\(session)"]?(message)
    }

    // MARK: - The line, on the module queue

    /// Holds the line on a socket, asking the app's server for it when it has none or it runs out within a minute.
    private func holdLine(via socket: ModuleSocket, _ done: @escaping () -> Void) {
        guard ringOn else { return done() }
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

    private func fail(_ code: String) {
        DispatchQueue.main.async { self.errorHandlers.forEach { $0(code) } }
    }

    private func onLine(_ message: [String: Any], info: JSONValue) {
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
                self.incomingHandlers.forEach { $0(incoming) }
            }
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
}

/// The relay on the realtime connection: the `call` request, with the call's token, since the socket is the app's.
final class SdkCallTransport: CallTransport {
    private unowned let calls: RealtimeCalls
    private let token: () -> String

    init(calls: RealtimeCalls, token: @escaping () -> String) {
        self.calls = calls
        self.token = token
    }

    var connected: Bool { calls.rt.state == .connected }

    func send(_ payload: [String: Any], ack: (([String: Any]?) -> Void)?) {
        var body = payload
        body["tab"] = calls.rt.tab
        body["token"] = token()
        let json = JSONValue.from(any: body)
        let rt = calls.rt
        rt.moduleQueue.async {
            guard let socket = rt.currentSocket else {
                if let ack { DispatchQueue.main.async { ack(nil) } }
                return
            }
            guard let ack else { return socket.emit("call", json) }
            socket.emit("call", json, timeout: 10) { reply in
                DispatchQueue.main.async { ack(reply?.anyValue as? [String: Any]) }
            }
        }
    }

    func listen(callId: String, session: String, _ handler: @escaping ([String: Any]) -> Void) -> () -> Void {
        calls.listen("\(callId):\(session)", handler)
    }

    func onReconnect(_ listener: @escaping () -> Void) -> () -> Void {
        calls.onSocketChange(listener)
    }
}

/// A call ringing for this app's user. `onOver` (the reason) when it stops ringing: answered elsewhere, declined …
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
    /// What a ring into a group call brought for the app's server: the call's pair, and the proof this user was rung.
    let pair: Any?
    let ring: String?
    private unowned let owner: RealtimeCalls
    private var overHandlers: [(String) -> Void] = []

    init(owner: RealtimeCalls, message: [String: Any], info: JSONValue) {
        self.owner = owner
        id = message["id"] as? String ?? ""
        call = message["call"] as? String ?? ""
        from = message["from"].map { "\($0)" } ?? ""
        self.info = info
        type = (message["type"] as? String) == "audio" ? .audio : .video
        group = (message["group"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        pair = message["pair"] as? [Any]
        ring = message["ring"] as? String
    }

    /// When it stops ringing, with the reason. On the main queue.
    public func onOver(_ handler: @escaping (String) -> Void) {
        overHandlers.append(handler)
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
        SystemCalls.shared.declined(id)
        try await owner.decline(self, reason: busy ? "busy" : "declined")
    }

    func over(_ reason: String) {
        guard state == .ringing else { return }
        state = .over
        self.reason = reason
        overHandlers.forEach { $0(reason) }
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
    private let request: [String: Any]
    private var session: CallSession!
    /// The key the call's rooms encrypt their media with, and the call's two people with this user's proof of being in
    /// it, from the app's server: what a room, and ringing someone in, need.
    private var mediaKey: String?
    private var proofs: (pair: Any?, member: String?)
    /// The room carrying the call when neither path could.
    private var room: GroupCall?
    private var movingToGroup = false
    private var stateHandlers: [(CallState) -> Void] = []
    private var remoteHandlers: [() -> Void] = []
    private var endHandlers: [(String) -> Void] = []
    private var groupHandlers: [(GroupCall) -> Void] = []
    private var renewal: DispatchWorkItem?
    private var connectedOnce = false
    private var microphoneOn = true
    private var cameraOn: Bool

    @MainActor
    init(owner: RealtimeCalls, id: String, name: String, type: CallType, role: Role, peer: String, peerInfo: JSONValue, request: [String: Any], grant: [String: Any]) {
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
        session = CallSession(transport: owner.transport { [weak self] in self?.token ?? "" }, callId: id, video: type == .video, signalKey: grant["key"] as? String ?? "")
        scheduleRenewal((grant["exp"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 + 3600)

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
        session.onRemote = { [weak self] in self?.remoteHandlers.forEach { $0() } }
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
    public func onGroup(_ handler: @escaping (GroupCall) -> Void) { groupHandlers.append(handler) }

    /// Rings `user` into the call, which becomes a group call: both sides go on in a room of its own on the mesh, and
    /// `user` arrives there once they answer. Throws `not_connected` before the call is up, or a refusal's code.
    @MainActor
    public func add(_ user: String) async throws -> CallInvite {
        guard state == .connected || state == .reconnecting else { throw CallError("not_connected") }
        return try await owner.invite(groupLink, user: user)
    }

    private var groupLink: GroupOf {
        GroupOf(id: id, name: name, type: type, pair: proofs.pair, member: proofs.member)
    }

    /// Someone was added: the call goes on in the group call's room, encrypted with the call's key, with what this side
    /// sends, and the app gets it before the call ends as `group`.
    private func toGroup() {
        guard !movingToGroup, state != .ended else { return }
        movingToGroup = true
        Task { @MainActor in
            do {
                self.stopMedia()
                let group = try await self.owner.joinGroup(self.groupLink, token: self.token, mediaKey: self.mediaKey, microphone: self.microphoneOn, camera: self.cameraOn)
                self.path = .room
                SystemCalls.shared.moved(self, to: group)
                self.groupHandlers.forEach { $0(group) }
                self.finish("group")
            } catch {
                self.finish("group_failed")
            }
        }
    }

    /// Neither the direct path nor TURN carried the call: it goes on in a room on the mesh, encrypted with the call's
    /// key, as the direct path is.
    private func toRoom(_ ticket: CallRoomTicket) {
        guard room == nil, state != .ended else { return }
        path = .room
        set(.connecting)
        stopMedia()
        Task { @MainActor in
            let room = self.owner.handoffRoom(name: self.name, ticket: ticket, mediaKey: self.mediaKey, microphone: self.microphoneOn, camera: self.cameraOn)
            self.room = room
            room.onState { [weak self] state in
                switch state {
                case .connected: self?.set(.connected)
                case .reconnecting: self?.set(.reconnecting)
                default: break
                }
            }
            room.onPeople { [weak self] in self?.remoteHandlers.forEach { $0() } }
            room.onEnded { [weak self] _ in
                guard let self, self.state != .ended else { return }
                self.session.leaveAfterHandoff("room_lost")
                self.finish("room_lost")
            }
        }
    }

    /// The direct path's own microphone and camera let go: a room opens its own.
    private func stopMedia() {
        CallMedia.shared.stopCamera()
        CallMedia.shared.setMicrophoneEnabled(false)
    }

    /// The state as it changes.
    public func onState(_ handler: @escaping (CallState) -> Void) { stateHandlers.append(handler) }

    /// The other side's media or tracks changed.
    public func onRemote(_ handler: @escaping () -> Void) { remoteHandlers.append(handler) }

    /// The call ended, with the reason: `hangup`, `declined`, `busy`, `cancelled`, `connection_failed` …
    public func onEnded(_ handler: @escaping (String) -> Void) { endHandlers.append(handler) }

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
            self.remoteHandlers.forEach { $0() }
        }
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
            CallMedia.shared.startCamera(front: true) { [weak self] track in
                guard let self, self.cameraOn, self.state != .ended else { return }
                guard let track else {
                    self.cameraOn = false
                    return
                }
                self.session.setLocalTrack(.camera, track, height: CallMedia.shared.captureHeight)
                self.remoteHandlers.forEach { $0() }
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
        stateHandlers.forEach { $0(next) }
    }

    private func setPath(_ next: CallPath) {
        guard path != next else { return }
        path = next
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
        CallMedia.shared.stopCamera()
        CallMedia.shared.setMicrophoneEnabled(false)
        owner.forget(self)
        stateHandlers.forEach { $0(.ended) }
        endHandlers.forEach { $0(reason) }
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
}

/// The microphone and camera permissions, asked for once.
enum CallPermissions {
    static func microphone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func camera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}
