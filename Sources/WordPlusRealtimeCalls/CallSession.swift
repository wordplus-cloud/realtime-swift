import Foundation
import LiveKitWebRTC

/// A room on the mesh the relay hands a call to: its server (none means the relay's own) and a token for it.
struct CallRoomTicket {
    let token: String
    let server: String?

    init?(_ value: Any?) {
        guard let map = value as? [String: Any], let token = map["token"] as? String, !token.isEmpty else { return nil }
        self.token = token
        server = map["server"] as? String
    }
}

/// One side of a call between two people, on the relay: the port of the web's `calls/session.ts` that Better Messages'
/// browsers and the SDK's run, driving `CallPeer` (Better Messages' app's port of `peer.ts`) as the app's engine does.
///
/// It joins the call (as its caller, that makes it ring), builds the direct connection once both sides are there,
/// carries the sealed signals both ways, keeps the TURN credentials and the room token fresh, pulses the relay while the
/// direct path runs, and hands the call to a room on the mesh when the path can't be had. Everything on the main queue.
final class CallSession: NSObject {
    // What the call hears: the other side arrived, the connection's state, what it sends changed, the numbers, the
    // relay moved the call to a room, the call ended, and the other side asking for a device to be opened again.
    var onPeerJoined: (() -> Void)?
    var onConnection: ((CallConnection) -> Void)?
    var onRemote: (() -> Void)?
    var onStats: ((CallPeerStats) -> Void)?
    var onFallback: ((CallRoomTicket) -> Void)?
    var onEnded: ((String) -> Void)?
    var onReacquire: ((CallSource) -> Void)?

    let callId: String
    let video: Bool
    private let transport: CallTransport
    private var signaling: CallSignaling!
    private let cipher: CallCipher?
    private var peer: CallPeer?
    private var polite = true
    private var generation = -1
    private var iceServers: [LKRTCIceServer] = []
    private var lastId: String?
    private var pendingSignals: [[String: Any]] = []
    private(set) var remoteState: [String: Bool] = [:]
    private(set) var remoteStateKnown = false
    private(set) var remoteTracks: [CallSource: LKRTCMediaStreamTrack] = [:]
    private var localTracks: [CallSource: (track: LKRTCMediaStreamTrack, height: Int)] = [:]
    private var peerCaps: CallCodecCaps?
    private var remoteWanted: [String: Int]?
    private var sentView: [String: Int]?
    /// How tall this app draws the other side's camera and screen, which sets what they send.
    var viewHeights: [String: Int] = ["camera": 720, "screen_share": 1080] {
        didSet { sendView() }
    }
    private var standby: CallRoomTicket?
    private var joinedSocket = false
    private var peerLost = false
    private var iceExpiresAt: Date?
    private var renewWork: DispatchWorkItem?
    private var keepalive: Timer?
    private var pulseTicks = 0
    private var reportedAt: Date?
    private var knownCodecs: (videoSend: String?, videoRecv: String?, audioSend: String?, audioRecv: String?) = (nil, nil, nil, nil)
    private var bytesSeen = (sent: 0, recv: 0)
    private var traceLines: [String] = []
    private var traceWork: DispatchWorkItem?
    private let traceStart = Date()
    private var stopReconnect: (() -> Void)?
    private var started = false
    private(set) var ended = false
    private(set) var handedOff = false
    private(set) var peerUserId: String?
    private(set) var peerPresent = false
    private(set) var stats = CallPeerStats()

    private static let keepaliveInterval: TimeInterval = 60
    private static let stateResendTicks = 8
    private static let renewMargin: TimeInterval = 600
    private static let renewMinGap: TimeInterval = 60
    private static let iceServersBudget: TimeInterval = 2

    init(transport: CallTransport, callId: String, video: Bool, signalKey: String) {
        self.transport = transport
        self.callId = callId
        self.video = video
        cipher = CallCipher(secret: signalKey)
        super.init()
        signaling = CallSignaling(transport: transport, callId: callId) { [weak self] message in self?.serverMessage(message) }
    }

    var isConnected: Bool { peer?.isUp == true }

    // MARK: - Joining

    /// Joins the call on the relay; false when it could not.
    func start(_ done: @escaping (Bool) -> Void) {
        guard !started, !ended else { return done(false) }
        started = true
        CallLog.setSink { [weak self] line in DispatchQueue.main.async { self?.trace(line) } }
        // A socket that has just come back is not joined until the rejoin says so.
        stopReconnect = transport.onReconnect { [weak self] in
            guard let self, !self.ended else { return }
            self.joinedSocket = false
            self.reviewHold()
            if self.transport.connected { self.join(resume: true) { _ in } }
        }
        join(resume: false, done)
    }

    private func join(resume: Bool, _ done: @escaping (Bool) -> Void) {
        guard !ended else { return done(false) }
        signaling.join(epoch: 0, lastId: lastId, resume: resume) { [weak self] reply in
            guard let self, !self.ended else { return done(false) }
            guard let reply else {
                if !resume { self.finish("signaling_unavailable") }
                return done(false)
            }
            guard (reply["ok"] as? Bool) != false else {
                let error = reply["error"] as? String ?? "join_failed"
                if resume, error == "call_ended" { self.finish(reply["reason"] as? String ?? "ended") }
                else if resume, ["answered_elsewhere", "no_call", "not_participant"].contains(error) { self.finish(error) }
                else if !resume { self.finish(error) }
                return done(false)
            }
            if (reply["mode"] as? String) == "sfu", let ticket = CallRoomTicket(reply["sfu"]) {
                self.handoff(ticket, why: "the join says the call is on the room")
                return done(true)
            }

            let kept = self.peer
            self.polite = (reply["role"] as? String ?? "polite") == "polite"
            self.standby = CallRoomTicket(reply["sfu"])
            if let peer = reply["peer"] as? [String: Any] {
                if let user = peer["user_id"], !(user is NSNull) { self.peerUserId = "\(user)" }
                self.peerLost = (peer["gone"] as? Bool) == true
            }
            self.joinedSocket = true
            let servers = CallSession.iceServers(from: reply["ice_servers"])
            self.iceServers = servers
            let renewed = self.setIceExpiry(reply["ice_expires_at"], soonest: 1)
            self.trace("\(resume ? "rejoin" : "join") role=\(self.polite ? "polite" : "impolite") gen=\(self.generation) peer=\(self.peerUserId ?? "?") present=\(((reply["peer"] as? [String: Any])?["present"] as? Bool) == true)")

            if let generation = (reply["generation"] as? NSNumber)?.intValue {
                if generation != self.generation, self.peer != nil {
                    self.generation = generation
                    self.rebuildPeer()
                } else {
                    self.generation = generation
                }
            }
            if ((reply["peer"] as? [String: Any])?["present"] as? Bool) == true { self.markPeerPresent() }
            self.sendCaps()
            for envelope in reply["replay"] as? [[String: Any]] ?? [] { self.signalArrived(envelope) }

            let wasHeld = self.peer?.held == true
            self.reviewHold()
            if resume, renewed, let peer = self.peer, peer === kept { peer.renewRelay(servers) }
            if resume, !wasHeld, let peer = self.peer, !self.polite, !peer.isUp { peer.restart(force: false, why: "rejoined") }
            self.startKeepalive()
            done(true)
        }
    }

    private func markPeerPresent() {
        guard !peerPresent else { return }
        peerPresent = true
        onPeerJoined?()
    }

    private func startKeepalive() {
        guard keepalive == nil, !ended else { return }
        keepalive = Timer.scheduledTimer(withTimeInterval: CallSession.keepaliveInterval, repeats: true) { [weak self] _ in self?.alive() }
    }

    /// The reply says whether the relay lost this session (join again), the call ended while the socket was away, or
    /// the call moved to a room this side wasn't told of.
    private func alive() {
        guard !ended, signaling.connected else { return }
        signaling.alive { [weak self] reply in
            guard let self, !self.ended, let reply else { return }
            if (reply["ok"] as? Bool) != false {
                if (reply["mode"] as? String) == "sfu", let ticket = CallRoomTicket(reply["sfu"]) { self.handoff(ticket, why: "the alive says the call is on the room") }
                return
            }
            switch reply["error"] as? String {
            case "call_ended": self.finish(reply["reason"] as? String ?? "ended")
            case "not_joined": self.join(resume: true) { _ in }
            default: break
            }
        }
    }

    // MARK: - The relay's events

    private func serverMessage(_ message: [String: Any]) {
        // After the hand-off the call runs in the room, but the relay still owns it: its end is heard here.
        if handedOff {
            if (message["op"] as? String) == "ended" {
                signaling.close()
                onEnded?(message["reason"] as? String ?? "ended")
            }
            return
        }
        guard !ended else { return }

        switch message["op"] as? String {
        case "ready":
            let generation = (message["generation"] as? NSNumber)?.intValue ?? 0
            if let peer = message["peer"] as? [String: Any], let user = peer["user_id"], !(user is NSNull) { peerUserId = "\(user)" }
            markPeerPresent()
            peerLost = false
            if peer != nil, generation <= self.generation {
                reviewHold()
                return
            }
            self.generation = generation
            rebuildPeer()

        case "signal":
            if peerLost {
                peerLost = false
                reviewHold()
            }
            signalArrived(message)

        case "peer_lost":
            peerLost = true
            reviewHold()
            onRemote?()

        case "peer_back":
            let wasHeld = peer?.held == true
            peerLost = false
            reviewHold()
            if !wasHeld, let peer, !polite, !peer.isUp { peer.restart(force: false, why: "the other side is back") }

        case "fallback":
            if let ticket = CallRoomTicket(message["sfu"]) ?? standby { handoff(ticket, why: "fallback from the relay") }

        case "ended":
            finish(message["reason"] as? String ?? "ended")

        default:
            break
        }
    }

    // MARK: - The connection

    private func rebuildPeer() {
        guard !ended, !handedOff else { return }
        peer?.close()
        peer = nil
        remoteState = [:]
        remoteStateKnown = false
        remoteTracks = [:]

        let media = CallMedia.shared
        guard let peer = CallPeer(polite: polite, factory: media.factory, iceServers: iceServers, relayOnly: false, caps: media.codecCaps, forcedFamilies: nil) else {
            finish("peer_failed")
            return
        }
        peer.delegate = self
        self.peer = peer
        sentView = nil
        pulseTicks = 0
        peer.start()
        if let caps = peerCaps { peer.setPeerCaps(caps) }
        for (source, local) in localTracks { peer.setLocalTrack(source: source, track: local.track, captureHeight: local.height) }
        if let wanted = remoteWanted { peer.setWanted(wanted) }
        sendState()
        sendCaps()

        // Parked for a peer or a generation this side didn't have yet: handed back in, their ids already taken.
        let pending = pendingSignals
        pendingSignals = []
        for envelope in pending { handleSignal(envelope, replayed: true) }

        reviewHold()
        onRemote?()
    }

    /// What this side sends from a source: a live track, or nil to stop sending it.
    func setLocalTrack(_ source: CallSource, _ track: LKRTCMediaStreamTrack?, height: Int = 0) {
        guard !ended else { return }
        if let track { localTracks[source] = (track, height) } else { localTracks[source] = nil }
        peer?.setLocalTrack(source: source, track: track, captureHeight: height)
        sendState()
    }

    private func sendState() {
        guard !ended, peer != nil else { return }
        var state: [String: Bool] = [:]
        for source in CallSource.order { state[source.rawValue] = localTracks[source]?.track.isEnabled == true }
        sendSignal(["kind": "state", "state": state])
    }

    private func sendCaps() {
        guard !ended else { return }
        sendSignal(["kind": "caps", "caps": CallMedia.shared.codecCaps.dictionary], needsPeer: false)
    }

    /// How tall this side shows each of the other side's video sources it has on; a source they have off is left out.
    private func sendView() {
        guard !ended, let peer, peer.isUp, remoteStateKnown else { return }
        var view: [String: Int] = [:]
        for source in ["camera", "screen_share"] where remoteState[source] == true { view[source] = viewHeights[source] ?? 720 }
        guard view != sentView else { return }
        sentView = view
        updateExpectInbound()
        trace("view sent " + view.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
        sendSignal(["kind": "view", "view": view])
    }

    /// Media is expected from the other side for a source it has on that this side hasn't asked it to stop sending.
    private func updateExpectInbound() {
        guard let peer else { return }
        var video: Set<CallSource> = []
        for source in [CallSource.camera, .screenShare] where remoteState[source.rawValue] == true {
            if let wanted = sentView?[source.rawValue], wanted <= 0 { continue }
            video.insert(source)
        }
        let audio = remoteState["microphone"] == true || remoteState["screen_share_audio"] == true
        peer.setExpectInbound(audio || !video.isEmpty)
        peer.setExpectedVideo(video)
    }

    private func sendSignal(_ body: [String: Any], needsPeer: Bool = true) {
        guard !ended, !needsPeer || peer != nil else { return }
        let generation = self.generation
        let wire = cipher?.seal(body) ?? body
        let kind = body["kind"] as? String ?? "signal"
        let sentFor = peer
        signaling.signal(generation: generation, body: wire) { [weak self] reply in
            guard let self, !self.ended else { return }
            guard let reply else { return self.trace("\(kind) sent gen=\(generation) -> failed") }
            if (reply["ok"] as? Bool) == false {
                self.trace("\(kind) sent gen=\(generation) -> refused \(reply["error"] as? String ?? "?")")
                if (reply["error"] as? String) == "stale_generation", let newer = (reply["generation"] as? NSNumber)?.intValue,
                   newer > self.generation, self.peer === sentFor, sentFor != nil {
                    self.generation = newer
                    self.rebuildPeer()
                }
            }
        }
    }

    /// A relayed signal: opened with the call's key, then handled once, in order.
    private func signalArrived(_ envelope: [String: Any]) {
        guard !ended, var body = envelope["body"] as? [String: Any] else { return }
        if CallCipher.isSealed(body) {
            guard let opened = cipher?.open(body) else { return trace("a signal could not be opened") }
            body = opened
        }
        var open = envelope
        open["body"] = body
        handleSignal(open, replayed: false)
    }

    private func handleSignal(_ envelope: [String: Any], replayed: Bool) {
        guard !ended, let body = envelope["body"] as? [String: Any] else { return }
        if !replayed, let id = envelope["id"] as? String, !id.isEmpty {
            if let last = lastId, CallSession.compareStreamIds(id, last) <= 0 { return }
            lastId = id
        }
        let signalGeneration = (envelope["generation"] as? NSNumber)?.intValue ?? 0
        if signalGeneration < generation { return }
        guard let peer, signalGeneration <= generation else {
            pendingSignals.append(envelope)
            return
        }

        switch body["kind"] as? String {
        case "state":
            remoteState = [:]
            for (key, value) in body["state"] as? [String: Any] ?? [:] { remoteState[key] = (value as? Bool) ?? false }
            remoteStateKnown = true
            updateExpectInbound()
            onRemote?()
            sendView()
        case "view":
            var wanted: [String: Int] = [:]
            for (key, value) in body["view"] as? [String: Any] ?? [:] { wanted[key] = (value as? NSNumber)?.intValue ?? 0 }
            remoteWanted = wanted
            peer.setWanted(wanted)
        case "caps":
            if let caps = CallCodecCaps.from(body["caps"] as? [String: Any]) {
                peerCaps = caps
                peer.setPeerCaps(caps)
            }
        case "reacquire":
            if let name = body["source"] as? String, let source = CallSource(rawValue: name) {
                trace("the other side says this side's \(name) sends nothing, opening it again")
                onReacquire?(source)
            }
        default:
            peer.handleSignal(body)
        }
    }

    // MARK: - Holding off, renewing, pulsing

    /// Whether a restart could reach the other side now; the peer holds its escalation while it couldn't.
    private func reviewHold() {
        guard let peer, !ended else { return }
        if !signaling.connected { joinedSocket = false }
        if !joinedSocket {
            peer.setSignalingHeld(true, why: "this side's realtime connection is down")
        } else if peerLost {
            peer.setSignalingHeld(true, why: "the relay says the other side's connection is down")
        } else {
            peer.setSignalingHeld(false, why: "both sides can be reached")
        }
    }

    /// Whether the expiry moved; the renewal is scheduled from it, not sooner than `soonest` seconds.
    @discardableResult
    private func setIceExpiry(_ value: Any?, soonest: TimeInterval) -> Bool {
        let seconds = (value as? NSNumber)?.doubleValue ?? 0
        guard seconds > 0 else { return false }
        let expires = Date(timeIntervalSince1970: seconds)
        let moved = expires != iceExpiresAt
        iceExpiresAt = expires
        scheduleRenewal(soonest: soonest)
        return moved
    }

    private func scheduleRenewal(soonest: TimeInterval) {
        renewWork?.cancel()
        renewWork = nil
        guard !ended, let expires = iceExpiresAt else { return }
        let left = expires.timeIntervalSinceNow
        let margin = min(CallSession.renewMargin, max(5, left / 4))
        let work = DispatchWorkItem { [weak self] in
            self?.renewWork = nil
            self?.renewRelay()
        }
        renewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(soonest, left - margin), execute: work)
    }

    private func renewRelay() {
        guard !ended, peer != nil else { return }
        fetchIceServers { [weak self] servers in
            guard let self, !self.ended, let peer = self.peer else { return }
            guard !servers.isEmpty else {
                self.trace("the relay credentials could not be renewed, asking again in a minute")
                return self.scheduleRenewal(soonest: CallSession.renewMinGap)
            }
            peer.renewRelay(servers)
        }
    }

    /// Fresh credentials, and the room token with them; empty when none came.
    private func fetchIceServers(_ done: @escaping ([LKRTCIceServer]) -> Void) {
        signaling.iceServers { [weak self] reply in
            guard let self, !self.ended, let reply, (reply["ok"] as? Bool) != false else { return done([]) }
            if let ticket = CallRoomTicket(reply["sfu"]) { self.standby = ticket }
            let servers = CallSession.iceServers(from: reply["ice_servers"])
            if !servers.isEmpty {
                self.iceServers = servers
                self.setIceExpiry(reply["ice_expires_at"], soonest: CallSession.renewMinGap)
            }
            done(servers)
        }
    }

    /// This side's counters to the relay with each stats pass while the direct path runs, and its reading back.
    private func pulse() {
        guard !ended, let peer, peer.isUp, signaling.connected else { return }
        pulseTicks += 1
        if pulseTicks % CallSession.stateResendTicks == 0 { sendState() }
        signaling.pulse(peer.pulseBody()) { [weak self] reply in
            guard let self, !self.ended, self.peer === peer, let reply else { return }
            guard (reply["ok"] as? Bool) != false else {
                if (reply["error"] as? String) == "not_joined" { self.join(resume: true) { _ in } }
                return
            }
            peer.setPeerPulse(CallPeerPulse.from(reply["peer"]))
            if let ticket = CallRoomTicket(reply["sfu"]) { self.handoff(ticket, why: "the relay judged the direct path dead from both sides' counters") }
        }
    }

    /// What this side ran the call on, for the call's record: when it changes, and its counts every twenty seconds.
    private func report(_ stats: CallPeerStats, force: Bool = false) {
        if !force, let last = reportedAt, Date().timeIntervalSince(last) < 20 { return }
        reportedAt = Date()
        if let v = stats.videoSend { knownCodecs.videoSend = v }
        if let v = stats.videoRecv { knownCodecs.videoRecv = v }
        if let v = stats.audioSend { knownCodecs.audioSend = v }
        if let v = stats.audioRecv { knownCodecs.audioRecv = v }
        bytesSeen = (max(bytesSeen.sent, stats.bytesSent), max(bytesSeen.recv, stats.bytesReceived))
        #if os(iOS)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        signaling.report([
            "browser": "app", "platform": platform, "client": platform,
            "path": stats.candidateLocal == "relay" || stats.candidateRemote == "relay" ? "relay" : "direct",
            "candidate": ["local": stats.candidateLocal ?? "", "remote": stats.candidateRemote ?? "", "protocol": stats.candidateProtocol ?? ""],
            "restarts": stats.restarts,
            "video": ["send": knownCodecs.videoSend ?? "", "recv": knownCodecs.videoRecv ?? ""],
            "audio": ["send": knownCodecs.audioSend ?? "", "recv": knownCodecs.audioRecv ?? ""],
            "impl": ["enc": stats.videoEncoder ?? "", "dec": stats.videoDecoder ?? ""],
            "bytes": ["sent": bytesSeen.sent, "recv": bytesSeen.recv],
        ])
    }

    // MARK: - The trace

    /// One line of this side's account, batched to the call's trace every two seconds; never SDP, addresses or names.
    func trace(_ line: String) {
        guard !ended || handedOff, !signaling.isClosed else { return }
        guard traceLines.count < 200 else { return }
        traceLines.append(String(format: "+%.3f ", Date().timeIntervalSince(traceStart)) + line)
        guard traceWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.traceWork = nil
            self?.flushTrace()
        }
        traceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func flushTrace() {
        guard !traceLines.isEmpty, !signaling.isClosed else { return }
        let lines = traceLines
        traceLines = []
        signaling.trace(lines) { _ in }
    }

    // MARK: - The end

    /// The direct path is left for a room on the mesh, with its token in hand.
    private func handoff(_ ticket: CallRoomTicket, why: String) {
        guard !ended else { return }
        trace("handing off to the room: \(why)")
        flushTrace()
        handedOff = true
        teardown(keepListening: true)
        onFallback?(ticket)
    }

    /// A call handed off to a room ends through the room, which the relay doesn't see: it is told.
    func leaveAfterHandoff(_ reason: String) {
        trace("room: leaving (\(reason))")
        flushTrace()
        signaling.leaveNow(reason)
        signaling.close()
        CallLog.setSink(nil)
    }

    /// Hangs up here: the last numbers and lines, then the leave.
    func end(_ reason: String) {
        guard !ended else { return }
        if let peer { report(peer.stats, force: true) }
        trace("ended: \(reason)")
        flushTrace()
        signaling.leave(reason)
        teardown()
    }

    private func finish(_ reason: String) {
        guard !ended else { return }
        trace("ended: \(reason)")
        flushTrace()
        teardown()
        onEnded?(reason)
    }

    private func teardown(keepListening: Bool = false) {
        ended = true
        stopReconnect?()
        stopReconnect = nil
        renewWork?.cancel()
        renewWork = nil
        keepalive?.invalidate()
        keepalive = nil
        peer?.close()
        peer = nil
        if !keepListening {
            // The leave and the last trace are already on their way: the socket keeps listening until they are.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [signaling] in signaling?.close() }
            CallLog.setSink(nil)
        }
    }

    // MARK: - Reading the relay

    static func iceServers(from value: Any?) -> [LKRTCIceServer] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            let urls: [String]
            if let many = entry["urls"] as? [String] { urls = many } else if let one = entry["urls"] as? String { urls = [one] } else { return nil }
            guard !urls.isEmpty else { return nil }
            if let username = entry["username"] as? String, let credential = entry["credential"] as? String {
                return LKRTCIceServer(urlStrings: urls, username: username, credential: credential)
            }
            return LKRTCIceServer(urlStrings: urls)
        }
    }

    /// Stream ids are `<ms>-<seq>`; the later one is the greater.
    static func compareStreamIds(_ a: String, _ b: String) -> Int {
        let left = a.split(separator: "-").map { Int($0) ?? 0 }
        let right = b.split(separator: "-").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let x = index < left.count ? left[index] : 0
            let y = index < right.count ? right[index] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}

extension CallSession: CallPeerDelegate {
    func peerSend(_ body: [String: Any]) {
        DispatchQueue.main.async { self.sendSignal(body) }
    }

    func peerTrack(source: CallSource, track: LKRTCMediaStreamTrack?) {
        DispatchQueue.main.async {
            self.remoteTracks[source] = track
            self.onRemote?()
        }
    }

    func peerConnection(_ state: CallConnection) {
        DispatchQueue.main.async {
            guard !self.ended else { return }
            self.trace("connection \(state.rawValue)")
            if state == .connected {
                // A rebuilt or restarted connection starts from full size on the other side: it is told again.
                self.sentView = nil
                self.sendView()
            }
            self.onConnection?(state)
        }
    }

    func peerStats(_ stats: CallPeerStats) {
        DispatchQueue.main.async {
            guard !self.ended else { return }
            self.stats = stats
            self.reviewHold()
            self.pulse()
            self.report(stats)
            self.onStats?(stats)
        }
    }

    /// The direct path won't happen: the relay is told, and moves both sides to a room, at once with the token held
    /// from the join, or with the one its answer brings.
    func peerFailed(_ reason: String) {
        DispatchQueue.main.async {
            guard !self.ended else { return }
            self.trace("direct path given up: \(reason)")
            let standby = self.standby.flatMap { CallSession.roomTokenUsable($0.token) ? $0 : nil }
            self.signaling.failed(reason) { [weak self] reply in
                guard let self, !self.ended, standby == nil else { return }
                if let reply, (reply["ok"] as? Bool) != false, let ticket = CallRoomTicket(reply["sfu"]) {
                    self.handoff(ticket, why: "\(reason), with the room token from the answer")
                } else {
                    self.finish("connection_failed")
                }
            }
            if let standby { self.handoff(standby, why: "\(reason), with the room token held from the join") }
        }
    }

    func peerRefreshIceServers(_ done: @escaping ([LKRTCIceServer]) -> Void) {
        DispatchQueue.main.async {
            // A restart goes on with what it has after a short wait.
            var settled = false
            DispatchQueue.main.asyncAfter(deadline: .now() + CallSession.iceServersBudget) {
                guard !settled else { return }
                settled = true
                done([])
            }
            self.fetchIceServers { servers in
                guard !settled else { return }
                settled = true
                done(servers)
            }
        }
    }

    func peerCodecBroken(family: String, direction: String) {
        DispatchQueue.main.async {
            guard CallCodecs.markBroken(family: family, direction: direction) else { return }
            let caps = CallMedia.shared.codecCaps
            self.sendSignal(["kind": "caps", "caps": caps.dictionary])
            self.peer?.setOwnCaps(caps)
        }
    }

    func peerSilent(source: CallSource) {
        DispatchQueue.main.async {
            guard !self.ended, self.peer != nil else { return }
            self.trace("telling the other side its \(source.rawValue) sends nothing")
            self.sendSignal(["kind": "reacquire", "source": source.rawValue])
        }
    }

    /// Whether a room token will still be taken a moment from now, by the expiry it carries.
    static func roomTokenUsable(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return false }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard let exp = claims["exp"] as? NSNumber else { return true }
        return exp.doubleValue - Date().timeIntervalSince1970 > 60
    }
}
