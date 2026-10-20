import Foundation
import LiveKitWebRTC

/// The four things a call can carry, always in this order.
///
/// The order is the wire: the caller offers one section per source in it, and
/// the answerer matches them by the mid map that travels with every
/// description, falling back to kind and order when a map is missing.
enum CallSource: String, CaseIterable {
    case camera
    case microphone
    case screenShare = "screen_share"
    case screenShareAudio = "screen_share_audio"

    var isVideo: Bool {
        self == .camera || self == .screenShare
    }

    static let order: [CallSource] = [ .camera, .microphone, .screenShare, .screenShareAudio ]
}

enum CallConnection: String {
    case connecting
    case connected
    case reconnecting
    case closed
}

enum CallQuality: String {
    case unknown
    case excellent
    case good
    case poor
    case lost
}

/// The cumulative packet counts this side has taken in and sent out, by
/// kind, and what the other side says it has sent — its RTCP sender reports,
/// `remote-outbound-rtp` — with the time (milliseconds since the epoch) the
/// last of those arrived. The last two are what tell a path that has died
/// from a peer that has stopped sending: both leave the inbound flat, only
/// the first leaves the peer's own count climbing.
struct CallPeerCounters {
    var inAudio = 0
    var inVideo = 0
    var outAudio = 0
    var outVideo = 0
    var remoteAudio = 0
    var remoteVideo = 0
    var remoteAt: Double = 0
}

/// The other side's counters as the relay handed them back with the reply
/// to this side's pulse: what it had taken in and sent out, its ICE state,
/// and when the relay took them (milliseconds since the epoch).
struct CallPeerPulse {
    let at: Double
    let ice: String
    let inAudio: Int
    let inVideo: Int
    let outAudio: Int
    let outVideo: Int
    /// When this side first saw it, by its own clock (milliseconds since the
    /// epoch). A silence is judged on this, never on `at`: that is the
    /// relay's clock, and a phone whose clock ran behind the relay's counted
    /// the peer's pulses from before a silence as sent during it.
    var seenAt: Double = 0

    static func from(_ value: Any?) -> CallPeerPulse? {
        guard let value = value as? [String: Any], let at = value["at"] as? NSNumber else { return nil }

        let inbound = value["in"] as? [String: Any] ?? [:]
        let outbound = value["out"] as? [String: Any] ?? [:]

        return CallPeerPulse(
            at: at.doubleValue,
            ice: value["ice"] as? String ?? "",
            inAudio: (inbound["a"] as? NSNumber)?.intValue ?? 0,
            inVideo: (inbound["v"] as? NSNumber)?.intValue ?? 0,
            outAudio: (outbound["a"] as? NSNumber)?.intValue ?? 0,
            outVideo: (outbound["v"] as? NSNumber)?.intValue ?? 0
        )
    }
}

struct CallPeerStats {
    var bytesSent: Int = 0
    var bytesReceived: Int = 0
    var rtt: Double? = nil
    var packetLoss: Double = 0
    var quality: CallQuality = .unknown
    var candidateLocal: String? = nil
    var candidateRemote: String? = nil
    var candidateProtocol: String? = nil
    var restarts: Int = 0
    var videoSend: String? = nil
    var videoRecv: String? = nil
    var audioSend: String? = nil
    var audioRecv: String? = nil
    /// Which encoder and decoder are actually running the video. The codec
    /// alone does not say whether it cost the CPU, and that is usually the
    /// question being asked of a call that ran hot or arrived soft.
    var videoEncoder: String? = nil
    var videoDecoder: String? = nil
    var counters = CallPeerCounters()
}

protocol CallPeerDelegate: AnyObject {
    func peerSend(_ body: [String: Any])
    func peerTrack(source: CallSource, track: LKRTCMediaStreamTrack?)
    func peerConnection(_ state: CallConnection)
    func peerStats(_ stats: CallPeerStats)
    func peerFailed(_ reason: String)
    func peerRefreshIceServers(_ done: @escaping ([LKRTCIceServer]) -> Void)
    func peerCodecBroken(family: String, direction: String)
    /// The other side's capture of this kind has stopped while the path is
    /// fine: nothing arrives, and its own reports say it sent nothing.
    func peerSilent(source: CallSource)
}

/// One direct connection to the other person.
///
/// A port of the web's `peer.ts`, kept close to it on purpose: both ends of a
/// call have to agree about who offers, which section is which camera, when a
/// candidate is worth trying and how big a picture to send. Anywhere the two
/// could drift, this follows the web rather than what would read better here.
///
/// The shape of it: the caller is **impolite** and offers first with a warm
/// section per source; the callee is **polite**, creates nothing of its own
/// and adopts the sections it is offered. An offer arriving while the impolite
/// side is making one is ignored, which is what keeps a glare from turning
/// into two half-negotiated connections.
final class CallPeer: NSObject {
    /// How a direct path that has died is left, and how fast.
    ///
    /// The measure of 19 to 21 Sep 2026 was that every failure took the same
    /// long road: three silences of eight seconds each, a plain ICE restart
    /// after the first two that changed nothing, and only then the room — 44
    /// to 46 seconds of dead call, every time, and a hand-off that still had
    /// to fetch its token. Half of those silences were not a dead path at all
    /// but a peer whose microphone had stopped, which no restart could mend.
    ///
    /// Now a silence is judged at `stallTimeout` by what the other side's own
    /// RTCP sender reports say it sent meanwhile (`remote-outbound-rtp`,
    /// arriving over the same transport), backed by the relay's pulse: the
    /// peer sent and nothing arrived is a dead path, the peer sent nothing is
    /// a dead capture. A dead capture gets a `reacquire` to the sender and no
    /// restart.
    ///
    /// The room is for a call that cannot connect directly or through TURN at
    /// all, and a call handed to it never comes back, so the path is given up
    /// on only once TURN has had a fair trial: `maxRestarts` restarts, each
    /// with fresh credentials and `restartDeadline` to bring the media back.
    /// A dead path is restarted over the relay alone, since ICE still thinks
    /// the path it has is fine; a lost connection first on every candidate,
    /// which is what finds a new direct path after a move from Wi-Fi to
    /// cellular, and then over the relay alone. libwebrtc says `disconnected`
    /// a few seconds after its checks go unanswered, so the grace on top is
    /// one second. Until 22 Sep 2026 each road had one attempt of four or five
    /// seconds, and a network change of ten seconds on one side put a call in
    /// the room for good.
    ///
    /// None of it runs while a restart could not be negotiated: this side's
    /// socket down, or the relay having said the other side's is. A deadline
    /// that runs out then proves nothing about the path, so escalation waits,
    /// for up to `signalingHoldMax`, and starts over with a fresh budget once
    /// both sides can be reached. A hold that runs out is spent until then,
    /// and the ladder runs as though there had been none. A connection that
    /// has carried media for `healthyReset` since its last trouble has its
    /// restarts back, so every incident in a long call gets the whole trial.
    /// The numbers are the web's.
    private enum Constants {
        static let maxRestarts = 2
        static let restartDeadline: TimeInterval = 8
        static let disconnectGrace: TimeInterval = 1
        static let politeRestartDelay: TimeInterval = 1.5
        static let healthyReset: TimeInterval = 30
        static let signalingHoldMax: TimeInterval = 60
        static let renewPoliteDelay: TimeInterval = 10
        static let statsInterval: TimeInterval = 2
        static let privateHold: TimeInterval = 2
        static let stallTimeout: TimeInterval = 4
        /// How long the other side's RTCP is trusted to be current: a sender
        /// report older than this says nothing about now.
        static let remoteReportAge: TimeInterval = 5
        /// A pulse the relay hands back was read at the other side's stats
        /// tick, up to this long before this side first saw it (a pulse
        /// interval here, and the two trips): a sample counts as taken after
        /// a silence began only when it was first seen that much later.
        static let pulseLag: TimeInterval = 2.5
        /// What the peer must have sent during a silence for the silence to
        /// be the path's fault rather than its capture's. libwebrtc keeps
        /// probing the bandwidth with a trickle of padding on a video section
        /// that carries no picture — about a packet a second on an audio
        /// call, measured 21 Sep 2026 — and one such packet used to be "the
        /// peer kept sending", which made a stopped microphone read as a dead
        /// path. A live microphone is fifty packets a second.
        static let silenceSentMin = 25
        /// How many samples of the peer's counts are kept for judging a silence.
        static let sampleHistory = 8
        /// How often the other side is told its capture has stopped.
        static let silentNoticeMin: TimeInterval = 30
        /// How long a restart waits for fresh credentials before going with
        /// the ones it has: a restart is the quick way out and must not sit
        /// on a slow reply.
        static let iceServersBudget: TimeInterval = 2
        /// A negotiation that never completes has nothing to notice it: ICE
        /// fails only once it has checked something, and the stall watchdog
        /// only counts on a live connection. A path that is going to come up
        /// does so inside a few seconds; one that has not by `connectRelayAt`
        /// is tried over the relay alone, with the restarts a lost connection
        /// gets, and one that has not by `connectDeadline` — both of them run
        /// out — is given up for the room. It was fourteen seconds, which left
        /// a relay allocation over TCP on 443 through a slow network six.
        static let connectRelayAt: TimeInterval = 8
        static let connectDeadline: TimeInterval = connectRelayAt + Double(maxRestarts) * restartDeadline + 2

        /// When a negotiated codec is declared dead, and how fast.
        ///
        /// The receiving half is judged on assembled frames, not packets: a
        /// frame is only counted once it is whole, and a working decoder turns
        /// the first one it is given into a picture. Three of them with nothing
        /// decoded is already conclusive, and waiting on packet counts only
        /// bought seconds of black.
        ///
        /// libwebrtc also says it outright — it names the decoder it ended up
        /// with, and a decoder that has given up on the stream is named as
        /// such. That needs no grace at all.
        ///
        /// The sending half keeps a longer one: an encoder is entitled to a
        /// moment before its first frame, and the camera it is fed from starts
        /// in its own time.
        static let codecDecodeGrace: TimeInterval = 1.2
        static let codecDecodeFrames = 3
        static let codecEncodeGrace: TimeInterval = 3
        static let codecEncodeFrames = 20
        /// An encoder that encodes nothing because it has nothing to spend is
        /// starved, not broken: libwebrtc holds every frame back from an
        /// encoder whose target has fallen to zero — the path down, or its
        /// send queue grown too long — and an encoder given a few kbps skips
        /// what it cannot afford. A target under 30 kbps counts as nothing to
        /// spend. Writing a starved encoder's codec off renegotiated a working
        /// call onto a worse one over what was the path's problem (production
        /// call 50038, 22 Sep 2026: `45c 0f 0p bandwidth 0k` on a relay with
        /// 2.7% loss and 400 ms round trips, and H264 dropped). A skipped
        /// write-off is written down at most every `starvedNoteEvery` a codec.
        static let encoderStarvedTarget = 30_000
        static let starvedNoteEvery: TimeInterval = 30

        /// A video source the other side says is on, that this side has asked
        /// to be sent, and that has decoded nothing for this long is asked for
        /// again: the sender starts that source's encoder over, which puts a
        /// keyframe on the wire. Only when that changes nothing does the
        /// silence count as a stall and take the aggregate watchdog's way out.
        /// Audio keeps the aggregate counters moving, so a dead picture beside
        /// a working microphone was invisible for the whole call.
        static let videoStallTimeout: TimeInterval = 6
        /// How often a sender lets one of its sources be started over, and
        /// how long the encoding is held off when it is.
        static let refreshMinInterval: TimeInterval = 2
        static let refreshHold: TimeInterval = 0.5
        /// How long a sender keeps writing what a restarted source puts out.
        static let refreshWatch: TimeInterval = 12
    }

    /// What one of the other side's video streams has delivered, by the
    /// counters libwebrtc keeps on it, and the family it runs on — for the
    /// write-off when frames keep arriving and none comes out.
    private struct InboundVideo {
        let decoded: Int
        let received: Int
        let packets: Int
        let pli: Int
        let nack: Int
        let family: String?
    }

    /// What one of this side's video senders has put out, what its report
    /// says is limiting it (`?` for nothing said) and its target, nil where
    /// the report leaves it out.
    private struct OutboundVideo {
        let produced: Int?
        let encoded: Int
        let packets: Int
        let limit: String
        let target: Int?
        let family: String?
    }

    /// What a sender's video source had put out when it was asked to start
    /// over, so the frames the capture produces after the restart can be held
    /// against the frames the encoder turns them into.
    private struct RefreshWatch {
        let at: Date
        let encoded: Int
        let produced: Int?
        let family: String?
    }

    weak var delegate: CallPeerDelegate?

    let polite: Bool

    private let factory: LKRTCPeerConnectionFactory
    private var caps: CallCodecCaps
    private let forcedFamilies: [String]?
    private let queue = DispatchQueue(label: "bm.calls.peer")

    private var pc: LKRTCPeerConnection?

    private var transceivers: [CallSource: LKRTCRtpTransceiver] = [:]
    private var sourceOfMid: [String: CallSource] = [:]
    private var remoteMids: [String: CallSource] = [:]
    private var remoteTracks: [CallSource: LKRTCMediaStreamTrack] = [:]
    private var localTracks: [CallSource: LKRTCMediaStreamTrack] = [:]

    private var pendingCandidates: [LKRTCIceCandidate] = []
    private var heldPrivateCandidates: [LKRTCIceCandidate] = []
    private var privateHoldWork: DispatchWorkItem?
    private var localPublicIps = Set<String>()
    private var remotePublicIps = Set<String>()
    private var privateDecision: String?

    private var started = false
    private var makingOffer = false
    private var ignoreOffer = false
    private var restartCount = 0
    private var restartsTotal = 0
    private var restartWork: DispatchWorkItem?
    private var restartDeadlineWork: DispatchWorkItem?
    private var connectDeadlineWork: DispatchWorkItem?
    private var connectRelayWork: DispatchWorkItem?
    private var statsTimer: DispatchSourceTimer?

    /// The other side's own counts of what it sent, as a short history: its
    /// RTCP sender reports as they arrive here, and its pulses as the relay
    /// hands them back. A silence is judged on the samples taken after it
    /// began — a count that arrives with a couple of seconds' lag still holds
    /// what was sent before the silence, and read against a baseline it says
    /// "the peer kept sending" about a microphone that had just stopped.
    private var peerPulses: [CallPeerPulse] = []
    private var remoteSamples: [(audio: Int, video: Int, reportAt: Double)] = []
    private var silenceNoted: Date?
    /// When the connection last had trouble — a restart, a dead path — so its
    /// restarts can be given back once it has carried media for
    /// `healthyReset` since.
    private var troubleAt: Date?
    /// Since when escalation has waited for a restart to be negotiable again,
    /// and why.
    private var heldSince: Date?
    private var heldWhy = ""
    private var holdWork: DispatchWorkItem?
    /// Whether this episode's hold ran its `signalingHoldMax` out. A spent
    /// hold is not taken again until both sides can be reached: the engine
    /// asks on every stats tick, and the tick after the release used to hold
    /// again and cancel the restart the release had just started.
    private var holdSpent = false
    private let connectStartedAt = Date()
    /// The call's own transport policy, which a restart that is not over the
    /// relay alone goes back to.
    private var basePolicy: LKRTCIceTransportPolicy = .all
    /// One restart in flight at a time: two each counted and each armed a
    /// deadline, and the second undid the first.
    private var restarting = false
    private var lastOfferAt: Date?
    private var lastSilentNotice: [CallSource: Date] = [:]
    private var failed = false
    private var refreshWatch: [CallSource: RefreshWatch] = [:]
    private var lastOutbound: [CallSource: OutboundVideo] = [:]

    /// What the last stats line said, so the trace holds a whole call: the poll
    /// is every two seconds and only a change of state or half a minute is
    /// worth writing down.
    private var loggedIce: LKRTCIceConnectionState?
    private var loggedStatsAt: TimeInterval = 0

    private var previousInbound: [String: (lost: Int, received: Int)] = [:]
    private var codecWatch: [String: Date] = [:]
    private var brokenCodecs: Set<String> = []
    private var starvedNotedAt: [String: Date] = [:]
    private var closed = false
    private var everConnected = false
    private var inboundPackets = 0
    private var inboundChangedAt: Date?
    private var connectedAt: Date?
    private var expectInbound = false

    /// Which of the other side's video sources a picture is expected from:
    /// announced on, and not paused by a wish of this side's own.
    private var expectedVideo: Set<CallSource> = []
    /// Decoded-frame progress per expected source, whether the sender has
    /// already been asked for a fresh picture in the current silence, and
    /// what the stream had delivered when it was asked.
    private var videoProgress: [CallSource: (frames: Int, since: Date, refreshed: Bool, receivedAtAsk: Int, packetsAtAsk: Int)] = [:]
    private var refreshedAt: [CallSource: Date] = [:]
    /// What this side last told the other it may receive, for the silence lines.
    private var lastBweIn: Int?

    private var wanted: [CallSource: Int] = [:]
    private var shapedFrom: [CallSource: Int] = [:]
    private var captureHeights: [CallSource: Int] = [:]
    private var peerCaps: CallCodecCaps?

    private(set) var connection: CallConnection = .connecting
    private(set) var stats = CallPeerStats()

    init?(polite: Bool,
          factory: LKRTCPeerConnectionFactory,
          iceServers: [LKRTCIceServer],
          relayOnly: Bool,
          caps: CallCodecCaps,
          forcedFamilies: [String]?) {
        self.polite = polite
        self.factory = factory
        self.caps = caps
        self.forcedFamilies = forcedFamilies

        super.init()

        let config = LKRTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        config.iceTransportPolicy = relayOnly ? .relay : .all
        basePolicy = config.iceTransportPolicy

        // The polite side gives way in a glare by rolling its own offer back
        // and taking the other side's. A browser does that by itself;
        // libwebrtc only does it when told, and left untold it refused the
        // incoming offer with a wrong-state error — after a restart this side
        // had begun, a codec written off, anything that made it offer — and
        // the call sat through three restart deadlines before it moved to a
        // room. Harmless on the impolite side, which ignores a colliding
        // offer before it gets this far.
        config.enableImplicitRollback = true

        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        guard let connection = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            return nil
        }

        pc = connection
    }

    /// Nothing starts until the owner has finished wiring itself up.
    ///
    /// Warm transceivers make libwebrtc ask for a negotiation of its own
    /// accord, and the offer that answer produces is handed to `delegate` —
    /// which the caller of an initializer cannot have set yet, because the
    /// initializer has not returned. The offer was made, the local description
    /// applied, and the description given to nobody, so the other side sat
    /// waiting for an offer that had already happened and the call fell back
    /// to a room twenty seconds later.
    func start() {
        guard !started, !closed else { return }

        started = true

        // On the peer's own queue, not the caller's, so that making the
        // sections and ordering them is one thing rather than two.
        //
        // `addTransceiver` calls `peerConnectionShouldNegotiate`, which puts
        // `negotiate()` on this queue. Run from outside it, that offer was
        // built and set while the creation loop was still going — before the
        // ordering pass at the end of it had run. The offer then went out in
        // libwebrtc's own order and the peer answered its first entry, which
        // is how a call between two devices that both do H265 in hardware
        // opened on H264 with H265 last in its own offer.
        //
        // Async, the creation and the ordering are one block on a serial
        // queue, and the `negotiate()` the creation triggers lands behind it.
        if !polite {
            queue.async { [weak self] in self?.addWarmTransceivers() }
        }

        startStatsLoop()
        armConnectDeadline()
    }

    /// One line for the call's trace: never SDP, addresses or names.
    private func trace(_ line: String) {
        CallLog.write(line)
    }

    /// The end of the direct path here, once. The reason goes to the trace
    /// before the engine hears it, because the engine's hand-off tears this
    /// down and the line would otherwise never be written.
    private func fail(_ reason: String, why: String) {
        guard !closed, !failed else { return }

        failed = true

        trace("giving the direct path up: \(reason) (\(why))")

        delegate?.peerFailed(reason)
    }

    /// A connection that never happens has nothing to notice it.
    ///
    /// Every other way out of a broken call runs through ICE: a restart, a
    /// disconnection, a stall. All of them need the connection to have started
    /// — ICE reaches `failed` only after it has checked something, and the
    /// stall watchdog only counts once media is expected on a live connection.
    /// A negotiation that never completes reaches none of that, so without
    /// this the call sits on screen showing nothing, for as long as the person
    /// is willing to look at it, and the server is never told to move it.
    ///
    /// A connection that has not come up in `connectRelayAt` is tried over
    /// the relay alone before it is given up on: a path that ICE cannot find
    /// in eight seconds is not going to be found, and a relay allocation
    /// takes one or two.
    private func armConnectDeadline() {
        // A hold lets both of these go by: the ladder starts over when it
        // lifts (`releaseHold`).
        let relay = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            self.connectRelayWork = nil

            guard !self.closed, !self.everConnected, self.heldSince == nil, !self.restarting, self.restartDeadlineWork == nil else { return }

            self.trace("no connection after \(Int(Constants.connectRelayAt * 1000))ms, trying the relay alone")
            self.restart(force: true, why: "no connection", relay: true)
        }

        connectRelayWork = relay

        queue.asyncAfter(deadline: .now() + Constants.connectRelayAt, execute: relay)

        armConnectFailure(after: Constants.connectDeadline)
    }

    private func armConnectFailure(after delay: TimeInterval) {
        connectDeadlineWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            self.connectDeadlineWork = nil

            guard !self.closed, !self.everConnected, self.heldSince == nil else { return }

            self.fail("ice_failed", why: "no connection after \(Int(Date().timeIntervalSince(self.connectStartedAt) * 1000))ms")
        }

        connectDeadlineWork = work

        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func clearConnectDeadline() {
        connectDeadlineWork?.cancel()
        connectDeadlineWork = nil
        connectRelayWork?.cancel()
        connectRelayWork = nil
    }

    /// The relay's copy of the other side's latest counters, from the reply
    /// to this side's pulse: a second witness beside the RTCP sender reports
    /// for the question of whether the peer is sending.
    func setPeerPulse(_ pulse: CallPeerPulse?) {
        queue.async { [weak self] in
            guard let self = self, var pulse = pulse else { return }

            if let last = self.peerPulses.last, last.at == pulse.at { return }

            pulse.seenAt = Date().timeIntervalSince1970 * 1000

            self.peerPulses.append(pulse)

            if self.peerPulses.count > Constants.sampleHistory { self.peerPulses.removeFirst() }
        }
    }

    /// This side's counters for the relay, as the last stats pass read them.
    /// Read on the peer's own queue, where the stats are written; the engine
    /// asks from the main thread, and nothing on the queue ever waits on it.
    func pulseBody() -> [String: Any] {
        queue.sync {
            let counters = stats.counters

            return [
                "ice": CallPeer.name(of: pc?.iceConnectionState ?? .new),
                "in": [ "a": counters.inAudio, "v": counters.inVideo ],
                "out": [ "a": counters.outAudio, "v": counters.outVideo ]
            ]
        }
    }

    /// Whether the connection is up, by ICE's own word.
    var isUp: Bool {
        isConnected
    }

    private static func name(of state: LKRTCIceConnectionState) -> String {
        switch state {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return "count"
        @unknown default: return "unknown"
        }
    }

    /// The caller's sections, made before anything is negotiated so the offer
    /// carries all four whether or not a camera is on yet. The callee makes
    /// none: libwebrtc only matches offered sections against transceivers it
    /// created for sending, so a set made here would be answered with four
    /// fresh receive-only ones and offered back — eight sections a side.
    private func addWarmTransceivers() {
        guard let pc = pc else { return }

        for source in CallSource.order {
            let encoding = LKRTCRtpEncodingParameters()
            encoding.isActive = true

            if source.isVideo {
                encoding.maxBitrateBps = NSNumber(value: source == .screenShare
                    ? CallShapes.screenCeiling(1080)
                    : CallShapes.cameraMaxBitrate)
            } else {
                encoding.maxBitrateBps = NSNumber(value: CallShapes.audioCeiling(source))
            }

            let with = LKRTCRtpTransceiverInit()
            with.direction = .sendRecv
            with.sendEncodings = [encoding]

            guard let transceiver = pc.addTransceiver(of: source.isVideo ? .video : .audio, init: with) else { continue }

            transceivers[source] = transceiver

            if !transceiver.mid.isEmpty {
                sourceOfMid[transceiver.mid] = source
            }

            if source.isVideo {
                CallCodecs.apply(
                    order: CallCodecs.offerOrder(own: caps, screen: source == .screenShare, forced: forcedFamilies),
                    to: transceiver,
                    factory: factory
                )
            }
        }
    }

    // MARK: - What this side sends

    func setLocalTrack(source: CallSource, track: LKRTCMediaStreamTrack?, captureHeight: Int) {
        queue.async { [weak self] in
            guard let self = self, !self.closed else { return }

            if let track = track {
                self.localTracks[source] = track
                self.captureHeights[source] = captureHeight

                // A hint of zero was the other side saying "I am not drawing
                // this" — true until this moment, because nothing was being
                // sent. Keeping it would switch the sender off the instant the
                // track arrived, and the other side would never see a picture
                // to raise the hint for. It goes, and their next hint shapes
                // the sender properly.
                if self.wanted[source] == 0 {
                    self.wanted.removeValue(forKey: source)
                }
            } else {
                self.localTracks.removeValue(forKey: source)
                self.captureHeights.removeValue(forKey: source)
            }

            guard let transceiver = self.transceivers[source] else { return }

            transceiver.sender.track = track

            // Shaped whether the track came or went: a track taken away
            // makes the encoding inactive for the pause, and its coming back
            // is then a change libwebrtc acts on.
            if source.isVideo {
                self.applyWanted(source)
            }
        }
    }

    /// The other side says how big it draws each of our video sources, in
    /// device pixels; 0 means it is not showing it at all.
    func setWanted(_ view: [String: Int]) {
        queue.async { [weak self] in
            guard let self = self, !self.closed else { return }

            for source in [CallSource.camera, .screenShare] {
                guard let raw = view[source.rawValue] else { continue }

                let height = max(0, raw)

                if self.wanted[source] == height { continue }

                self.wanted[source] = height
                self.applyWanted(source)
            }
        }
    }

    /// What the other side can encode and decode. Every video sender picks its
    /// codec from that and this side's own abilities.
    func setPeerCaps(_ caps: CallCodecCaps) {
        queue.async { [weak self] in
            guard let self = self, !self.closed else { return }

            self.peerCaps = caps

            for source in CallSource.order where source.isVideo {
                self.applyWanted(source)
            }
        }
    }

    /// This side's own abilities, narrowed because a codec was caught carrying
    /// nothing. Every video section is ordered again without it and the call is
    /// offered again: a sender takes its codec from the order in the
    /// description it was given, and neither this side nor a browser peer can
    /// be moved any other way once a call is running. A peer that *can* switch
    /// a live sender has already been told by the caps that went out with this.
    func setOwnCaps(_ caps: CallCodecCaps) {
        queue.async { [weak self] in
            guard let self = self, !self.closed else { return }

            self.caps = caps

            for source in CallSource.order where source.isVideo {
                if let transceiver = self.transceivers[source] {
                    let order = self.polite
                        ? CallCodecs.answerOrder(own: caps, peer: self.peerCaps, screen: source == .screenShare, forced: self.forcedFamilies)
                        : CallCodecs.offerOrder(own: caps, screen: source == .screenShare, forced: self.forcedFamilies)

                    CallCodecs.apply(order: order, to: transceiver, factory: self.factory)
                }

                self.applyWanted(source)
            }

            self.negotiate()
        }
    }

    /// Whether media is expected from the other side right now. The stall
    /// watchdog must not fire on a silence this side asked for.
    func setExpectInbound(_ expected: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }

            if self.expectInbound != expected {
                self.inboundChangedAt = Date()
                self.trace("expect inbound=\(expected)")
            }

            self.expectInbound = expected
        }
    }

    /// Which video sources a picture is expected from right now. A source that
    /// stops being expected drops its clock, and one that starts being expected
    /// starts it from now, so a camera just turned on gets the whole grace
    /// before it is asked for again.
    func setExpectedVideo(_ sources: Set<CallSource>) {
        queue.async { [weak self] in
            guard let self = self else { return }

            for source in Array(self.videoProgress.keys) where !sources.contains(source) {
                self.videoProgress.removeValue(forKey: source)
            }

            self.expectedVideo = sources
        }
    }

    private var isConnected: Bool {
        guard let pc = pc else { return false }

        return pc.iceConnectionState == .connected || pc.iceConnectionState == .completed
    }

    private var negotiated: Bool {
        guard let pc = pc else { return false }

        return pc.localDescription != nil && pc.remoteDescription != nil
    }

    private func applyWanted(_ source: CallSource) {
        guard !closed, negotiated, let transceiver = transceivers[source] else { return }

        let sender = transceiver.sender
        let params = sender.parameters

        guard let encoding = params.encodings.first else { return }

        if !source.isVideo {
            let ceiling = CallShapes.audioCeiling(source)

            if encoding.maxBitrateBps?.intValue == ceiling { return }

            encoding.maxBitrateBps = NSNumber(value: ceiling)
            sender.parameters = params

            return
        }

        let capture = captureHeights[source] ?? CallShapes.defaultTrackHeight
        let want = wanted[source]

        let family = chosenFamily(for: source, params: params)
        let fast = family.map { CallCodecs.fastDirection(sender: caps, receiver: peerCaps, family: $0) } ?? false

        let shape = source == .screenShare
            ? CallShapes.screen(wanted: want, captureHeight: capture, fast: fast)
            : CallShapes.camera(wanted: want, captureHeight: capture)

        // A source with no track is an inactive encoding, not an idle active
        // one. The pause is then a real allocation change held for as long as
        // the camera is off, and the camera coming back is another one —
        // which is what makes libwebrtc probe for bandwidth again. Measured
        // 16 Sep 2026, this phone → Firefox: a camera switched off and on
        // again sent not one packet for thirty seconds and through two
        // encoder restarts, because the estimate had fallen to what audio
        // alone justifies and nothing it did changed its allocation; the one
        // write that changed it brought the picture back at once.
        let active = shape.active && transceiver.sender.track != nil

        // Nothing to say means nothing to write.
        //
        // Several paths reach here inside the first second of a call — a track
        // attaching, caps arriving from either side, negotiation completing —
        // and each used to write whether or not anything had changed. On
        // Android the same omission was the whole of the codec lottery: a
        // write that touches the scale or the frame rate makes libwebrtc
        // rebuild the encoder, seven of them in 750 ms, and the codec the call
        // kept was wherever the rebuilding stopped. The audio path above has
        // always had this guard.
        if encoding.isActive == active,
           encoding.maxBitrateBps?.intValue == shape.maxBitrate,
           encoding.scaleResolutionDownBy?.doubleValue == shape.scale,
           encoding.maxFramerate?.intValue == shape.maxFramerate,
           shapedFrom[source] == capture {
            return
        }

        encoding.isActive = active
        encoding.maxBitrateBps = NSNumber(value: shape.maxBitrate)
        encoding.scaleResolutionDownBy = NSNumber(value: shape.scale)
        encoding.maxFramerate = shape.maxFramerate.map { NSNumber(value: $0) }

        // Text must stay readable when the link is short: the screen encoder
        // gives up frames before it gives up pixels. The camera keeps
        // libwebrtc's own balance.
        if source == .screenShare {
            params.degradationPreference = NSNumber(value: LKRTCDegradationPreference.maintainResolution.rawValue)
        }

        // The scale is relative to the capture, so the size it was worked out
        // from is remembered: a shared window the other person resizes changes
        // the capture underneath, and nothing else would notice.
        shapedFrom[source] = capture

        sender.parameters = params
    }

    /// The family this side should send this source with, among the ones the
    /// negotiation actually left available.
    private func chosenFamily(for source: CallSource, params: LKRTCRtpParameters) -> String? {
        let negotiated = params.codecs.compactMap { codec -> String? in
            let mime = "video/" + codec.name

            return CallCodecs.families.first { $0.lowercased() == mime.lowercased() }
        }

        guard !negotiated.isEmpty else { return nil }

        let order = CallCodecs.answerOrder(own: caps, peer: peerCaps, screen: source == .screenShare, forced: forcedFamilies)

        return order.first { family in negotiated.contains { $0.lowercased() == family.lowercased() } }
    }

    // MARK: - Negotiation

    private func midMap() -> [String: String] {
        var map: [String: String] = [:]

        for (source, transceiver) in transceivers where !transceiver.mid.isEmpty {
            map[transceiver.mid] = source.rawValue
        }

        return map
    }

    private func negotiate() {
        guard !closed, let pc = pc else { return }

        // The polite side never opens: it answers what it is offered.
        if polite && pc.remoteDescription == nil { return }

        makingOffer = true

        pc.offer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] offer, error in
            guard let self = self else { return }

            self.queue.async {
                guard let offer = offer, error == nil, !self.closed else {
                    self.makingOffer = false
                    return
                }

                pc.setLocalDescription(offer) { error in
                    self.queue.async {
                        self.makingOffer = false

                        // Only the offer this set, while it is still the one
                        // on the table. An offer from the other side can be
                        // handled between the two hops, and rolled this one
                        // back: what `localDescription` then held was the last
                        // answer, with the old ICE credentials, and it went out
                        // as though it were this side's word on the restart.
                        guard !self.closed, error == nil, pc.signalingState == .haveLocalOffer,
                              let local = pc.localDescription, local.type == .offer else { return }

                        self.sendDescription(local)
                    }
                }
            }
        }
    }

    private func sendDescription(_ description: LKRTCSessionDescription) {
        delegate?.peerSend([
            "kind": "sdp",
            "description": [
                "type": CallPeer.name(of: description.type),
                "sdp": description.sdp
            ],
            "mids": midMap()
        ])
    }

    private static func name(of type: LKRTCSdpType) -> String {
        switch type {
        case .offer: return "offer"
        case .prAnswer: return "pranswer"
        case .answer: return "answer"
        case .rollback: return "rollback"
        @unknown default: return "offer"
        }
    }

    private static func type(of name: String) -> LKRTCSdpType {
        switch name.lowercased() {
        case "answer": return .answer
        case "pranswer": return .prAnswer
        case "rollback": return .rollback
        default: return .offer
        }
    }

    /// Signals are handled one at a time and in order: negotiation depends on
    /// it, and a candidate applied before its description is a candidate lost.
    func handleSignal(_ body: [String: Any]) {
        queue.async { [weak self] in
            self?.processSignal(body)
        }
    }

    private func processSignal(_ body: [String: Any]) {
        guard !closed, let pc = pc, let kind = body["kind"] as? String else { return }

        if kind == "sdp" {
            guard let description = body["description"] as? [String: Any],
                  let typeName = description["type"] as? String,
                  let sdp = description["sdp"] as? String else { return }

            let type = CallPeer.type(of: typeName)
            let collision = type == .offer && (makingOffer || pc.signalingState != .stable)

            ignoreOffer = !polite && collision

            if ignoreOffer { return }

            if let mids = body["mids"] as? [String: String] {
                applyRemoteMids(mids)
            }

            // Lines for payload types the description does not declare go
            // first, whatever else happens to it: libwebrtc refuses a
            // description that carries them (see the helper).
            let cleaned = CallSdp.withoutOrphanPayloads(sdp)

            if cleaned != sdp {
                trace("the \(typeName) arrived with lines for payload types it does not declare, dropped before applying it")
            }

            let rewritten = CallSdp.withStereoOpus(cleaned)

            let group = DispatchGroup()
            var applied = false

            group.enter()
            pc.setRemoteDescription(LKRTCSessionDescription(type: type, sdp: rewritten)) { error in
                applied = error == nil
                group.leave()
            }

            // Bounded, always. Signals are handled one at a time and in order,
            // so a callback that never comes back would stop every signal
            // after it — the call would simply stop progressing with no error
            // anywhere. Ten seconds is far longer than this takes and far
            // shorter than a person will wait.
            _ = group.wait(timeout: .now() + 10)

            // A description this side rewrote for stereo must never cost the
            // call: anything libwebrtc will not take is retried as it arrived,
            // less the lines it cannot take at all.
            if !applied {
                group.enter()
                pc.setRemoteDescription(LKRTCSessionDescription(type: type, sdp: cleaned)) { error in
                    applied = error == nil
                    group.leave()
                }
                _ = group.wait(timeout: .now() + 10)
            }

            guard applied, !closed else { return }

            flushCandidates()

            if type == .offer {
                // When the other side last offered, for the polite side of a
                // dead path: an offer arriving after it switched to the relay
                // is the other side's restart, which it answers rather than
                // restarting into.
                lastOfferAt = Date()

                adoptOfferedSections()
                answer()
            }

            return
        }

        if kind == "candidate" {
            guard let candidate = body["candidate"] as? [String: Any],
                  let line = candidate["candidate"] as? String, !line.isEmpty else { return }

            let ice = LKRTCIceCandidate(
                sdp: line,
                sdpMLineIndex: Int32(candidate["sdpMLineIndex"] as? Int ?? 0),
                sdpMid: candidate["sdpMid"] as? String
            )

            let parsed = CallCandidateInfo.parse(line)

            if let parsed = parsed, parsed.type == "srflx", !parsed.address.isEmpty {
                remotePublicIps.insert(parsed.address)
                reviewHeldCandidates()
            }

            if let parsed = parsed, parsed.type == "host", parsed.isPrivate {
                holdPrivateCandidate(ice)
                return
            }

            addRemoteCandidate(ice)
            return
        }

        if kind == "refresh", let name = body["source"] as? String, let source = CallSource(rawValue: name) {
            refreshSource(source)
        }
    }

    /// The other side has seen nothing from one of this side's video sources
    /// for a while and asks for a fresh picture. The encoder is stopped and
    /// started again through the encoding's active flag, which libwebrtc
    /// answers with a keyframe. A source that is off, or that the other side
    /// itself asked to be paused, has nothing to start over.
    private func refreshSource(_ source: CallSource) {
        guard !closed, source.isVideo, let transceiver = transceivers[source],
              let track = transceiver.sender.track, track.readyState == .live,
              wanted[source] != 0 else { return }

        let now = Date()

        if let last = refreshedAt[source], now.timeIntervalSince(last) < Constants.refreshMinInterval { return }

        refreshedAt[source] = now

        // What the source had put out so far, so the frames the capture
        // produces from here can be held against the frames that get
        // encoded: an encoder that takes the capture and turns none of it
        // into frames is dead, and it is this end that can see so.
        let before = lastOutbound[source]

        refreshWatch[source] = RefreshWatch(at: now, encoded: before?.encoded ?? 0, produced: before?.produced, family: before?.family)

        trace("starting the \(source.rawValue) encoder over, the other side sees no picture")

        let sender = transceiver.sender

        // Held off for a moment, not flipped: off and on in the same breath
        // is no net change to the bandwidth allocation, and it is that change
        // libwebrtc probes on. Measured 16 Sep 2026: the flip restarted
        // nothing, a held change did.
        let pause = sender.parameters

        guard let paused = pause.encodings.first else { return }

        paused.isActive = false
        sender.parameters = pause

        queue.asyncAfter(deadline: .now() + Constants.refreshHold) { [weak self] in
            guard let self = self, !self.closed, self.transceivers[source] === transceiver, self.wanted[source] != 0 else { return }

            let resume = sender.parameters

            guard let resumed = resume.encodings.first else { return }

            resumed.isActive = true
            sender.parameters = resume
        }
    }

    /// The sections a remote offer created become this side's transceivers,
    /// matched to sources by the mid map that travelled with it, by kind and
    /// order without one. Direction sendrecv, so the answer carries this
    /// side's media too, and the local tracks go in before it is made.
    private func adoptOfferedSections() {
        guard let pc = pc else { return }

        for transceiver in pc.transceivers {
            let mid = transceiver.mid

            guard !mid.isEmpty, sourceOfMid[mid] == nil else { continue }

            let isVideo = transceiver.mediaType == .video
            let mapped = remoteMids[mid]

            let source: CallSource?

            if let mapped = mapped, transceivers[mapped] == nil, mapped.isVideo == isVideo {
                source = mapped
            } else {
                source = CallSource.order.first { $0.isVideo == isVideo && transceivers[$0] == nil }
            }

            guard let picked = source else { continue }

            transceivers[picked] = transceiver
            sourceOfMid[mid] = picked

            transceiver.setDirection(.sendRecv, error: nil)

            if isVideo {
                CallCodecs.apply(
                    order: CallCodecs.answerOrder(own: caps, peer: peerCaps, screen: picked == .screenShare, forced: forcedFamilies),
                    to: transceiver,
                    factory: factory
                )
            }

            if let track = localTracks[picked] {
                transceiver.sender.track = track
            }
        }
    }

    private func answer() {
        guard let pc = pc, !closed else { return }

        let group = DispatchGroup()
        var applied = false

        group.enter()
        pc.answer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, error in
            guard let answer = answer, error == nil else {
                group.leave()
                return
            }

            pc.setLocalDescription(answer) { error in
                applied = error == nil
                group.leave()
            }
        }

        _ = group.wait(timeout: .now() + 10)

        // An answer that did not apply leaves the last description in place,
        // and sending that would hand the other side something it did not ask
        // for.
        guard !closed, applied, let local = pc.localDescription, local.type == .answer else { return }

        sendDescription(local)

        // Adopted sections carry no ceiling of their own; they get one the
        // same way a wish does, now that the answer is in.
        for source in CallSource.order {
            applyWanted(source)
        }
    }

    private func applyRemoteMids(_ mids: [String: String]) {
        var parsed: [String: CallSource] = [:]

        for (mid, name) in mids {
            if let source = CallSource(rawValue: name) { parsed[mid] = source }
        }

        remoteMids = parsed
    }

    // MARK: - Candidates

    private func addRemoteCandidate(_ candidate: LKRTCIceCandidate) {
        guard !closed, let pc = pc else { return }

        if pc.remoteDescription == nil {
            pendingCandidates.append(candidate)
            return
        }

        pc.add(candidate) { _ in }
    }

    private func flushCandidates() {
        let pending = pendingCandidates
        pendingCandidates = []

        for candidate in pending {
            pc?.add(candidate) { _ in }
        }
    }

    /// A private host address is worth trying only when both sides are behind
    /// the same public address — otherwise it belongs to a stranger's network
    /// and pairing it wastes the connectivity check. Held briefly, because the
    /// public addresses usually arrive a moment later.
    private func holdPrivateCandidate(_ candidate: LKRTCIceCandidate) {
        if privateDecision == "drop" { return }

        if privateDecision == "keep" {
            addRemoteCandidate(candidate)
            return
        }

        heldPrivateCandidates.append(candidate)
        reviewHeldCandidates()

        guard privateHoldWork == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            self.privateHoldWork = nil
            self.decidePrivateCandidates("keep")
        }

        privateHoldWork = work
        queue.asyncAfter(deadline: .now() + Constants.privateHold, execute: work)
    }

    private func reviewHeldCandidates() {
        guard privateDecision == nil, !localPublicIps.isEmpty, !remotePublicIps.isEmpty else { return }

        let shared = remotePublicIps.contains { localPublicIps.contains($0) }

        decidePrivateCandidates(shared ? "keep" : "drop")
    }

    private func decidePrivateCandidates(_ decision: String) {
        guard privateDecision == nil else { return }

        privateDecision = decision

        privateHoldWork?.cancel()
        privateHoldWork = nil

        let held = heldPrivateCandidates
        heldPrivateCandidates = []

        if decision == "keep" {
            for candidate in held { addRemoteCandidate(candidate) }
        }
    }

    // MARK: - ICE state and restarts

    private func setConnection(_ state: CallConnection) {
        guard connection != state else { return }

        connection = state
        delegate?.peerConnection(state)
    }

    private func clearRestartTimers() {
        restartWork?.cancel()
        restartWork = nil
        restartDeadlineWork?.cancel()
        restartDeadlineWork = nil
    }

    /// A restart the ICE state asked for. The polite side waits a moment
    /// longer so the two do not restart into each other. The first of an
    /// incident goes out on every candidate, relay ones included, because the
    /// usual cause is one side moving to another network, where a new direct
    /// path is often there to be found; any after it go over the relay alone.
    /// An attempt already in flight is left to its own deadline.
    private func scheduleRestart(after delay: TimeInterval, why: String) {
        guard restartWork == nil, !restarting, restartDeadlineWork == nil else { return }

        let wait = polite ? delay + Constants.politeRestartDelay : delay

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            self.restartWork = nil
            self.restart(force: false, why: why, relay: self.restartCount > 0)
        }

        restartWork = work
        queue.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// Whether escalation is waiting for a restart to be negotiable again.
    /// For the engine, off the peer's queue.
    var held: Bool {
        queue.sync { heldSince != nil }
    }

    /// Told by the engine on every stats tick and whenever either side's
    /// presence changes. While this side's socket is down, or the relay has
    /// said the other side's is, no offer can reach the other side: a restart
    /// made then counted as a failed attempt, and a network change of ten
    /// seconds on one side ran the budget out and put the call in the room
    /// for good. Held, nothing escalates; released, the ladder starts over.
    func setSignalingHeld(_ held: Bool, why: String) {
        queue.async { [weak self] in
            guard let self = self, !self.closed, !self.failed else { return }

            guard held else {
                // Both sides reachable ends the episode: the next time one of
                // them is not is a new one, with a hold of its own.
                self.holdSpent = false

                if self.heldSince != nil { self.releaseHold(why) }

                return
            }

            guard self.heldSince == nil else { return }

            // This episode had its hold and it ran out. Held again, the
            // restart the release started was cancelled on the next stats
            // tick, and a phone that had lost every connection sat on
            // "Reconnecting…" for good, its camera, its microphone and the
            // system's call all up. Not held, the ladder runs as though there
            // had been no hold: the restarts, then the room or the end.
            guard !self.holdSpent else { return }

            self.heldSince = Date()
            self.heldWhy = why
            self.clearRestartTimers()
            self.trace("escalation held: \(why)")

            // Not for ever: a side that stays out of reach this long is not
            // coming back through the relay, and the old road — the room, or
            // the end of the call — is what is left.
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }

                self.holdWork = nil

                guard self.heldSince != nil else { return }

                self.holdSpent = true
                self.releaseHold("still out of reach after \(Int(Constants.signalingHoldMax))s, not held again until both sides can be reached")
            }

            self.holdWork = work
            self.queue.asyncAfter(deadline: .now() + Constants.signalingHoldMax, execute: work)
        }
    }

    private func releaseHold(_ why: String) {
        let heldFor = heldSince.map { Date().timeIntervalSince($0) } ?? 0

        heldSince = nil
        heldWhy = ""
        holdWork?.cancel()
        holdWork = nil

        // What was tried while the other side could not hear it says nothing
        // about the path, so the restarts are all there again.
        restartCount = 0
        trace("escalation released after \(String(format: "%.1f", heldFor))s: \(why)")

        guard !closed, !failed else { return }

        if !everConnected {
            armConnectFailure(after: Double(Constants.maxRestarts) * Constants.restartDeadline + 2)
        }

        if !isConnected {
            scheduleRestart(after: 0, why: holdSpent ? "the hold ran out" : "the other side can be reached again")
        }
    }

    /// Fresh credentials inside a short budget, or the ones already held.
    /// Asking used to inherit the socket's full retry budget — twenty-four
    /// seconds inside a restart that was supposed to be the quick way out.
    private func freshIceServers(_ done: @escaping ([LKRTCIceServer]) -> Void) {
        var settled = false

        let budget = DispatchWorkItem { [weak self] in
            guard let self = self, !settled else { return }

            settled = true
            self.trace("fresh ice servers did not arrive in \(Int(Constants.iceServersBudget * 1000))ms, restarting with the ones held")
            done([])
        }

        queue.asyncAfter(deadline: .now() + Constants.iceServersBudget, execute: budget)

        delegate?.peerRefreshIceServers { [weak self] servers in
            guard let self = self else { return }

            self.queue.async {
                guard !settled else { return }

                settled = true
                budget.cancel()
                done(servers)
            }
        }
    }

    /// Relay candidates only, with credentials fresh enough to allocate on.
    private func useRelayOnly() {
        freshIceServers { [weak self] servers in
            guard let self = self, !self.closed, let pc = self.pc else { return }

            let config = pc.configuration

            if !servers.isEmpty { config.iceServers = servers }

            config.iceTransportPolicy = .relay

            if !pc.setConfiguration(config) {
                self.trace("warn: could not switch to relay only")
            }
        }
    }

    /// One attempt to bring the media back. `force` restarts a connection ICE
    /// still calls connected, which is what a dead path is; `relay` takes it
    /// over the relay alone, and otherwise it goes out on every candidate the
    /// call was set up with, the relay's among them; `giveUp` is the reason
    /// handed on once the restarts have run out. One at a time: two restarts
    /// in flight each counted and each armed a deadline, and the second undid
    /// the first.
    func restart(force: Bool, why: String = "asked", relay: Bool = false, giveUp: String? = nil) {
        queue.async { [weak self] in
            guard let self = self, !self.closed, !self.failed, let pc = self.pc else { return }
            if self.isConnected && !force { return }
            if self.restarting { return }

            if self.heldSince != nil {
                self.trace("restart (\(why)) waits: \(self.heldWhy)")
                return
            }

            self.troubleAt = Date()

            if self.restartCount >= Constants.maxRestarts {
                self.fail(giveUp ?? (self.everConnected ? "ice_lost" : "ice_failed"), why: "\(why), \(self.restartCount) restarts did not bring the media back")
                return
            }

            self.restarting = true
            self.restartCount += 1
            self.restartsTotal += 1

            // Fresh TURN credentials first: the old ones may be what expired.
            self.freshIceServers { servers in
                self.restarting = false

                guard !self.closed else { return }

                let config = pc.configuration

                if !servers.isEmpty { config.iceServers = servers }

                // Back to the call's own policy when this one is not over the
                // relay alone: a restart that went relay-only used to leave
                // the connection so for the rest of the call.
                config.iceTransportPolicy = relay ? .relay : self.basePolicy

                if !pc.setConfiguration(config) {
                    self.trace("warn: could not apply ice servers for the restart")
                }

                self.trace("ice restart #\(self.restartsTotal) (\(why)), \(self.restartCount) of \(Constants.maxRestarts)\(relay ? " over the relay alone" : " on every candidate") servers=\(servers.isEmpty ? "held" : "fresh")")

                pc.restartIce()

                self.watchAttempt("restart #\(self.restartsTotal)", giveUp: giveUp)
            }
        }
    }

    /// The deadline an attempt has to bring the media back. A connection
    /// still down is restarted again over the relay alone, and so is one that
    /// came back carrying nothing; the restarts running out is the room.
    private func watchAttempt(_ what: String, giveUp: String?) {
        restartDeadlineWork?.cancel()

        let startedAt = Date()
        let inboundThen = inboundPackets

        let deadline = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            self.restartDeadlineWork = nil

            guard !self.closed, !self.failed, self.heldSince == nil else { return }

            if !self.isConnected {
                self.restart(force: false, why: "\(what) did not connect in \(Int(Constants.restartDeadline * 1000))ms", relay: true, giveUp: giveUp)
            } else if self.expectInbound && self.inboundPackets == inboundThen {
                self.restart(force: true, why: "\(what) connected and brought nothing in \(Int(Constants.restartDeadline * 1000))ms", relay: true, giveUp: "path_dead")
            } else {
                self.trace("\(what) brought the media back in \(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
            }
        }

        restartDeadlineWork = deadline
        queue.asyncAfter(deadline: .now() + Constants.restartDeadline, execute: deadline)
    }

    /// New TURN credentials, before the ones the connection holds run out. An
    /// allocation is refreshed with the credentials it was made with, and the
    /// TURN server refuses those once they have expired, so a call relayed
    /// for longer than their life (six hours by default) lost its relay
    /// mid-call. Every later restart takes the new ones. A path that runs
    /// through this side's own relay candidate is moved onto fresh allocations
    /// now, while the old one still carries it, and that restart is not an
    /// attempt: it counts as none. The polite side waits a little, so two
    /// relayed sides do not offer into each other, and an offer from the other
    /// side meanwhile has renewed this side's allocations already.
    func renewRelay(_ servers: [LKRTCIceServer]) {
        queue.async { [weak self] in
            guard let self = self, !self.closed, !self.failed, let pc = self.pc, !servers.isEmpty else { return }

            let config = pc.configuration

            config.iceServers = servers

            if !pc.setConfiguration(config) {
                self.trace("warn: could not apply the renewed ice servers")
                return
            }

            let relayed = self.stats.candidateLocal == "relay"

            self.trace("relay credentials renewed\(relayed ? ", moving this side's relay onto fresh allocations" : "")")

            guard relayed else { return }

            let startedAt = Date()

            self.queue.asyncAfter(deadline: .now() + (self.polite ? Constants.renewPoliteDelay : 0)) { [weak self] in
                guard let self = self, !self.closed, !self.failed, self.heldSince == nil, !self.restarting, self.isConnected, let pc = self.pc else { return }

                if let offered = self.lastOfferAt, offered >= startedAt {
                    self.trace("the other side restarted meanwhile, which moved this side's relay too")
                    return
                }

                self.restartsTotal += 1
                self.trace("ice restart #\(self.restartsTotal) (the relay credentials are about to run out), not counted as an attempt")

                pc.restartIce()
            }
        }
    }

    /// The verdict on a silence that began at `since`: `stallTimeout` with
    /// nothing arriving from a peer that has something on. What it means
    /// depends on what the peer itself says it did meanwhile — its RTCP
    /// sender reports travel over the same transport, and the relay's pulse
    /// carries the same counts by another road.
    ///
    /// Only samples taken after the silence began count: a sender report
    /// says what was sent up to the moment it was sent, and a pulse what was
    /// read up to `pulseLag` before it arrived, so the first sample of each
    /// after `since` is the baseline and growth past it is sending during
    /// the silence. Two such samples are needed either way; with fewer the
    /// verdict waits a tick, up to twice `stallTimeout`, after which a
    /// silence nobody can account for is treated as a dead path. Returns
    /// whether a verdict was reached.
    private func judgeSilence(now: Date, since: Date, counters: CallPeerCounters) -> Bool {
        let quiet = now.timeIntervalSince(since)
        let sinceMs = since.timeIntervalSince1970 * 1000
        let nowMs = now.timeIntervalSince1970 * 1000
        let reports = remoteSamples.filter { $0.reportAt >= sinceMs }
        let pulses = peerPulses.filter { $0.seenAt - Constants.pulseLag * 1000 >= sinceMs }

        let byReports = reports.count >= 2
            ? (reports[reports.count - 1].audio - reports[0].audio) + (reports[reports.count - 1].video - reports[0].video)
            : 0
        let byPulses = pulses.count >= 2
            ? (pulses[pulses.count - 1].outAudio - pulses[0].outAudio) + (pulses[pulses.count - 1].outVideo - pulses[0].outVideo)
            : 0

        let reportFresh = counters.remoteAt > 0 && nowMs - counters.remoteAt <= Constants.remoteReportAge * 1000
        let pulseFresh = peerPulses.last.map { nowMs - $0.seenAt <= Constants.remoteReportAge * 1000 } ?? false
        let peerAlive = reportFresh || pulseFresh
        let seconds = String(format: "%.1f", quiet)

        if byReports >= Constants.silenceSentMin || byPulses >= Constants.silenceSentMin {
            trace("no inbound for \(seconds)s while the peer sent \(byReports >= Constants.silenceSentMin ? "\(byReports) packets by its own reports" : "\(byPulses) packets by the relay's pulses") during it: the path is dead")
            pathDead("nothing arrives while the peer sends")

            return true
        }

        if reports.count >= 2 || pulses.count >= 2 {
            // The transport is fine — the peer's word keeps coming — and it
            // sent nothing during the silence. That is its capture, and no
            // restart mends a microphone. It is told, and the call goes on.
            let source: CallSource = !expectedVideo.isEmpty && counters.inVideo == 0 ? .camera : .microphone
            let last = lastSilentNotice[source] ?? .distantPast

            let trickle = max(byReports, byPulses)

            trace("no inbound for \(seconds)s and the peer sent \(trickle > 0 ? "nothing but \(trickle) padding packets" : "nothing") during it (\(reports.count >= 2 ? "by its own reports" : "by the relay's pulses")): its \(source.rawValue) stopped, not the path")

            if now.timeIntervalSince(last) >= Constants.silentNoticeMin {
                lastSilentNotice[source] = now
                delegate?.peerSilent(source: source)
            }

            return true
        }

        if !peerAlive {
            // Nothing at all, not even RTCP: the transport is gone whatever
            // ICE still thinks, and libwebrtc's own `disconnected` is a few
            // seconds behind this.
            trace("no inbound for \(seconds)s and no word from the peer at all: the transport is dead")
            pathDead("nothing arrives, not even the peer's reports")

            return true
        }

        if quiet >= Constants.stallTimeout * 2 {
            trace("no inbound for \(seconds)s and the peer's word does not settle it (\(reports.count) reports, \(pulses.count) pulses since): treating the path as dead")
            pathDead("nothing arrives and the silence cannot be accounted for")

            return true
        }

        if silenceNoted == nil {
            silenceNoted = now
            trace("no inbound for \(seconds)s, waiting for the peer's word on it (\(reports.count) reports, \(pulses.count) pulses since)")
        }

        return false
    }

    /// A dead path is restarted over the relay alone, with fresh credentials,
    /// until the restarts run out, and then it is the room. An attempt in
    /// flight is judged by its own deadline. Only the impolite side restarts
    /// at once: the polite one switches to the relay and gives the offer a
    /// moment to arrive, restarting itself only if none does, so the two do
    /// not restart into each other — and an offer that did arrive is this
    /// side's attempt too, watched on the same deadline.
    private func pathDead(_ why: String) {
        guard !closed, !failed else { return }

        if heldSince != nil {
            trace("the path looks dead (\(why)), and no restart can be negotiated now: \(heldWhy)")
            return
        }

        if restarting || restartDeadlineWork != nil || restartWork != nil { return }

        troubleAt = Date()

        if restartCount >= Constants.maxRestarts {
            fail("path_dead", why: "\(why), after \(restartCount) restarts over the relay")
            return
        }

        if !polite {
            restart(force: true, why: why, relay: true, giveUp: "path_dead")
            return
        }

        let startedAt = Date()

        useRelayOnly()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            self.restartWork = nil

            guard !self.closed, !self.failed, self.heldSince == nil else { return }

            if let offered = self.lastOfferAt, offered >= startedAt {
                self.restartCount += 1
                self.trace("the other side restarted over the relay, this side answered (restart \(self.restartCount) of \(Constants.maxRestarts))")
                self.watchAttempt("the other side's restart", giveUp: "path_dead")
                return
            }

            self.restart(force: true, why: "\(why), no restart came from the other side", relay: true, giveUp: "path_dead")
        }

        restartWork = work
        queue.asyncAfter(deadline: .now() + Constants.politeRestartDelay, execute: work)
    }

    // MARK: - Stats

    private func startStatsLoop() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Constants.statsInterval, repeating: Constants.statsInterval)
        timer.setEventHandler { [weak self] in self?.collectStats() }
        timer.resume()

        statsTimer = timer
    }

    private func collectStats() {
        guard !closed, let pc = pc else { return }

        pc.statistics { [weak self] report in
            guard let self = self else { return }

            self.queue.async {
                guard !self.closed else { return }

                self.readStats(report)
            }
        }
    }

    /// A codec that negotiated and then carried nothing.
    ///
    /// The two sides of it look alike in the statistics and show up nowhere
    /// else: a receiver taking packets that no frame ever comes out of, and a
    /// sender handing frames to an encoder that emits none. Both mean the call
    /// is running on something one end cannot actually do, and both are only
    /// visible from the end it is happening at.
    private func reviewCodecs(_ report: LKRTCStatisticsReport) {
        let now = Date()

        func watch(_ key: String, dead: Bool, ready: Bool, grace: TimeInterval) -> Bool {
            guard dead else {
                codecWatch.removeValue(forKey: key)

                return false
            }

            guard ready else { return false }

            guard let since = codecWatch[key] else {
                codecWatch[key] = now

                return false
            }

            return now.timeIntervalSince(since) > grace
        }

        for (_, entry) in report.statistics {
            let values = entry.values

            guard values["kind"] as? String == "video",
                  let codecId = values["codecId"] as? String,
                  let mime = report.statistics[codecId]?.values["mimeType"] as? String,
                  let family = CallCodecs.families.first(where: { $0.caseInsensitiveCompare(mime) == .orderedSame })
            else { continue }

            if entry.type == "inbound-rtp" {
                let frames = (values["framesReceived"] as? NSNumber)?.intValue ?? 0
                let decoded = (values["framesDecoded"] as? NSNumber)?.intValue ?? 0
                let implementation = (values["decoderImplementation"] as? String ?? "").lowercased()
                let gaveUp = implementation.contains("null") || implementation.contains("fallback")

                if decoded == 0, frames > 0, gaveUp {
                    codecBroken(family: family, direction: CallCodecs.decode)

                    continue
                }

                // Keyed by family as well as stream, so the clock measures how
                // long *this family* has been failing rather than how long the
                // stream has: a stream's reported codec moves about while a
                // call settles, and a clock that starts on one codec and
                // expires on another writes off whichever happened to be
                // showing. The write-off persists, so that costs the device a
                // good codec for every later call.
                if watch("dec:" + entry.id + ":" + family, dead: decoded == 0, ready: frames >= Constants.codecDecodeFrames, grace: Constants.codecDecodeGrace) {
                    codecBroken(family: family, direction: CallCodecs.decode)
                }

                continue
            }

            guard entry.type == "outbound-rtp", (values["active"] as? NSNumber)?.boolValue != false,
                  let sourceId = values["mediaSourceId"] as? String,
                  let produced = (report.statistics[sourceId]?.values["frames"] as? NSNumber)?.intValue
            else { continue }

            let encoded = (values["framesEncoded"] as? NSNumber)?.intValue ?? 0
            let key = "enc:" + entry.id + ":" + family

            if watch(key, dead: encoded == 0, ready: produced >= Constants.codecEncodeFrames, grace: Constants.codecEncodeGrace) {
                let limit = values["qualityLimitationReason"] as? String ?? "?"
                let target = (values["targetBitrate"] as? NSNumber)?.intValue

                if CallPeer.encoderStarved(limit: limit, target: target) {
                    // Judged again from the start, once it has something to
                    // spend and still encodes nothing.
                    codecWatch.removeValue(forKey: key)
                    noteStarved(family: family, why: CallPeer.encoderLimit(limit: limit, target: target))
                } else {
                    codecBroken(family: family, direction: CallCodecs.encode, why: CallPeer.encoderLimit(limit: limit, target: target))
                }
            }
        }
    }

    /// Whether an encoder is being starved rather than failing: it has been
    /// given next to nothing to spend, a target under `encoderStarvedTarget`.
    /// A limitation of `bandwidth` is not that on its own: libwebrtc goes on
    /// naming bandwidth for an encoder it has scaled down, and one that died
    /// after being scaled down once, with a target of hundreds of kbps, was
    /// never written off and the call kept a camera that sent nothing.
    private static func encoderStarved(limit: String, target: Int?) -> Bool {
        guard let spend = spendable(limit: limit, target: target) else { return false }

        return spend < Constants.encoderStarvedTarget
    }

    /// The target an encoder has to spend: the one it reports, or the zero a
    /// missing one stands for. libwebrtc leaves the target out of the report
    /// while it is zero, and an encoder cut off by a path that went down
    /// names no limitation, so a missing target counts as zero only beside a
    /// limitation the report names; with neither there is nothing to judge
    /// but the frames.
    private static func spendable(limit: String, target: Int?) -> Int? {
        return target ?? (limit != "?" ? 0 : nil)
    }

    private static func encoderLimit(limit: String, target: Int?) -> String {
        return "limited by \(limit), target \(kbps(spendable(limit: limit, target: target)))"
    }

    private func noteStarved(family: String, why: String) {
        let now = Date()

        if let last = starvedNotedAt[family], now.timeIntervalSince(last) < Constants.starvedNoteEvery { return }

        starvedNotedAt[family] = now
        trace("\(family.replacingOccurrences(of: "video/", with: "")) encodes nothing, but its encoder is starved (\(why)): not written off")
    }

    private func codecBroken(family: String, direction: String, why: String = "") {
        guard !closed, brokenCodecs.insert(family + ":" + direction).inserted else { return }

        CallLog.write("codec \(family) carried nothing to \(direction == CallCodecs.decode ? "decode" : "encode")\(why.isEmpty ? "" : " (\(why))"), dropping it")

        delegate?.peerCodecBroken(family: family, direction: direction)
    }

    private func readStats(_ report: LKRTCStatisticsReport) {
        reviewCodecs(report)

        var bytesSent = 0
        var bytesReceived = 0
        var lost = 0
        var received = 0
        var inbound = 0
        var rtt: Double?
        var stats = CallPeerStats()

        // Counted apart from the total, because "is this call still sending my
        // voice" is a question the total cannot answer on a video call: the
        // picture drowns the microphone a hundred to one, and the codec name
        // below says only what *would* carry it.
        //
        // Both kinds, so that they have to add up: a single figure that quietly
        // counted everything would answer the question with the wrong number
        // and look right doing it.
        var audioSent = 0
        var videoSent = 0

        // A section with no media of its own — a camera that is off, an unused
        // screen share — still names a codec, and would otherwise be reported
        // as what the call is running on.
        let codecName: ([String: Any]) -> String? = { values in
            let moving = [ "framesEncoded", "framesDecoded", "packetsSent", "packetsReceived" ]
                .compactMap { values[$0] as? NSNumber }
                .contains { $0.intValue > 0 }

            guard moving, let codecId = values["codecId"] as? String,
                  let codec = report.statistics[codecId]?.values["mimeType"] as? String else { return nil }

            return codec.components(separatedBy: "/").last
        }

        // Packets alone do not make a video section the one carrying the call:
        // an idle screen share sends padding and RTCP and would win the last
        // write. Frames do, so the busiest section is the one reported.
        var videoSendFrames = 0
        var videoRecvFrames = 0

        // Each inbound video stream by the source it carries: a section's mid
        // is the same on both ends, so this side's own map answers, with the
        // track's id standing in where a stream names no mid.
        var inboundVideo: [CallSource: InboundVideo] = [:]
        // And what this side's own video senders have put out, so a source
        // the other side was asked to start over can be read from both ends.
        var outboundVideo: [CallSource: OutboundVideo] = [:]
        // The bandwidth estimates on the selected pair: what this side
        // believes it may send, and what it tells the other side it may
        // receive. A picture that stops after a pause and comes back for a
        // moment on a parameter write is what a collapsed estimate looks
        // like, and these are the only numbers that show it.
        var bweOut: Int?
        var bweIn: Int?

        // The family a stream runs on, by the codec entry it names.
        let familyOf: ([String: Any]) -> String? = { values in
            guard let codecId = values["codecId"] as? String,
                  let mime = report.statistics[codecId]?.values["mimeType"] as? String else { return nil }

            return CallCodecs.families.first { $0.caseInsensitiveCompare(mime) == .orderedSame }
        }

        var counters = CallPeerCounters()

        for (_, entry) in report.statistics {
            let values = entry.values

            switch entry.type {
            case "outbound-rtp":
                bytesSent += (values["bytesSent"] as? NSNumber)?.intValue ?? 0

                // `kind` is what the newer stats call it and `mediaType` what
                // the older ones do; a section answering to neither would be
                // counted as both without this.
                switch (values["kind"] ?? values["mediaType"]) as? String {
                case "audio":
                    audioSent += (values["bytesSent"] as? NSNumber)?.intValue ?? 0
                    counters.outAudio += (values["packetsSent"] as? NSNumber)?.intValue ?? 0
                case "video":
                    videoSent += (values["bytesSent"] as? NSNumber)?.intValue ?? 0
                    counters.outVideo += (values["packetsSent"] as? NSNumber)?.intValue ?? 0
                default: break
                }

                if values["kind"] as? String == "video" {
                    let frames = (values["framesEncoded"] as? NSNumber)?.intValue ?? 0

                    if frames > videoSendFrames, let name = codecName(values) {
                        videoSendFrames = frames
                        stats.videoSend = name
                        stats.videoEncoder = values["encoderImplementation"] as? String
                    }

                    // By mid where the stats carry one, else by the media
                    // source's track id, which is this side's own track: the
                    // outbound entries here name no mid, and every restarted
                    // camera read "no stream" for it.
                    let mid = values["mid"] as? String ?? ""
                    let sourceId = values["mediaSourceId"] as? String ?? ""
                    let trackId = report.statistics[sourceId]?.values["trackIdentifier"] as? String
                    let source = sourceOfMid[mid] ?? localTracks.first { trackId != nil && $0.value.trackId == trackId }?.key

                    if let source = source {
                        outboundVideo[source] = OutboundVideo(
                            produced: (report.statistics[sourceId]?.values["frames"] as? NSNumber)?.intValue,
                            encoded: frames,
                            packets: (values["packetsSent"] as? NSNumber)?.intValue ?? 0,
                            limit: values["qualityLimitationReason"] as? String ?? "?",
                            target: (values["targetBitrate"] as? NSNumber)?.intValue,
                            family: familyOf(values)
                        )
                    }
                } else if values["kind"] as? String == "audio", let name = codecName(values) {
                    stats.audioSend = name
                }

            case "inbound-rtp":
                bytesReceived += (values["bytesReceived"] as? NSNumber)?.intValue ?? 0
                inbound += (values["packetsReceived"] as? NSNumber)?.intValue ?? 0

                if values["kind"] as? String == "video" {
                    counters.inVideo += (values["packetsReceived"] as? NSNumber)?.intValue ?? 0

                    let frames = (values["framesDecoded"] as? NSNumber)?.intValue ?? 0

                    if frames > videoRecvFrames, let name = codecName(values) {
                        videoRecvFrames = frames
                        stats.videoRecv = name
                        stats.videoDecoder = values["decoderImplementation"] as? String
                    }

                    let mid = values["mid"] as? String ?? ""
                    let trackId = values["trackIdentifier"] as? String
                    let source = sourceOfMid[mid] ?? remoteTracks.first { trackId != nil && $0.value.trackId == trackId }?.key

                    if let source = source {
                        inboundVideo[source] = InboundVideo(
                            decoded: frames,
                            received: (values["framesReceived"] as? NSNumber)?.intValue ?? 0,
                            packets: (values["packetsReceived"] as? NSNumber)?.intValue ?? 0,
                            pli: (values["pliCount"] as? NSNumber)?.intValue ?? 0,
                            nack: (values["nackCount"] as? NSNumber)?.intValue ?? 0,
                            family: familyOf(values)
                        )
                    }
                } else if values["kind"] as? String == "audio" {
                    counters.inAudio += (values["packetsReceived"] as? NSNumber)?.intValue ?? 0

                    if let name = codecName(values) { stats.audioRecv = name }
                }

                let previous = previousInbound[entry.id] ?? (lost: 0, received: 0)
                let currentLost = (values["packetsLost"] as? NSNumber)?.intValue ?? 0
                let currentReceived = (values["packetsReceived"] as? NSNumber)?.intValue ?? 0

                lost += max(0, currentLost - previous.lost)
                received += max(0, currentReceived - previous.received)

                previousInbound[entry.id] = (lost: currentLost, received: currentReceived)

            case "remote-outbound-rtp":
                // The other side's own count of what it sent, carried in its
                // RTCP sender reports over the same transport; the timestamp
                // is when the last of those arrived here, in microseconds.
                let sent = (values["packetsSent"] as? NSNumber)?.intValue ?? 0

                switch values["kind"] as? String {
                case "audio": counters.remoteAudio += sent
                case "video": counters.remoteVideo += sent
                default: break
                }

                let at = entry.timestamp_us / 1000

                if at > counters.remoteAt { counters.remoteAt = at }

            case "candidate-pair":
                let state = values["state"] as? String
                let selected = (values["selected"] as? NSNumber)?.boolValue ?? false
                let nominated = (values["nominated"] as? NSNumber)?.boolValue ?? false

                guard state == "succeeded", selected || nominated else { break }

                if let value = values["currentRoundTripTime"] as? NSNumber { rtt = value.doubleValue }
                if let value = values["availableOutgoingBitrate"] as? NSNumber { bweOut = value.intValue }
                if let value = values["availableIncomingBitrate"] as? NSNumber { bweIn = value.intValue }

                if let localId = values["localCandidateId"] as? String, let local = report.statistics[localId] {
                    stats.candidateLocal = local.values["candidateType"] as? String
                    stats.candidateProtocol = (local.values["relayProtocol"] as? String) ?? (local.values["protocol"] as? String)
                }

                if let remoteId = values["remoteCandidateId"] as? String, let remote = report.statistics[remoteId] {
                    stats.candidateRemote = remote.values["candidateType"] as? String
                }

            default:
                break
            }
        }

        let now = Date()

        // The other side's sender reports, one sample per report that
        // arrived, for judging a silence on what was sent during it.
        if counters.remoteAt > 0, remoteSamples.last?.reportAt != counters.remoteAt {
            remoteSamples.append((audio: counters.remoteAudio, video: counters.remoteVideo, reportAt: counters.remoteAt))

            if remoteSamples.count > Constants.sampleHistory { remoteSamples.removeFirst() }
        }

        if inbound > inboundPackets {
            inboundPackets = inbound
            inboundChangedAt = now
            silenceNoted = nil
        } else if inbound < inboundPackets {
            // Backwards, which a packet count cannot go: this is the sum over
            // whichever inbound streams exist now, and a renegotiation can give
            // the other side new streams whose counters start again at zero.
            // Held as a high-water mark that was fatal on Android — the sum
            // could never reach the old total again, so the watchdog fired
            // every eight seconds and each restart put the count back down. A
            // drop is a new stream: the new baseline.
            inboundPackets = inbound
            inboundChangedAt = now
            silenceNoted = nil
        } else if isConnected, expectInbound, let connectedAt = connectedAt {
            let since = max(inboundChangedAt ?? connectedAt, connectedAt)

            // The counters are taken before the verdict so it reads the
            // peer's reports of this very silence; a verdict that could not
            // be reached yet leaves the clock running and is asked again
            // next tick.
            if now.timeIntervalSince(since) >= Constants.stallTimeout {
                self.stats.counters = counters

                if judgeSilence(now: now, since: since, counters: counters) {
                    inboundChangedAt = now
                    silenceNoted = nil
                }
            }
        }

        // A connection that has carried media for `healthyReset` since its
        // last trouble has its restarts back: the next incident, an hour or a
        // day into the call, gets the whole trial rather than what the last
        // one left of it.
        //
        // "Carried media" is inbound that moved within `stallTimeout`, and a
        // side with nothing on sends nothing to move: with the other side's
        // microphone muted and its camera off the restarts never came back,
        // however long the call stayed up. Connected with nothing inbound
        // expected counts as healthy.
        let inboundHealthy = !expectInbound || inboundChangedAt.map { now.timeIntervalSince($0) < Constants.stallTimeout } ?? false

        if restartCount > 0, isConnected, let trouble = troubleAt, now.timeIntervalSince(trouble) >= Constants.healthyReset, inboundHealthy {
            trace(expectInbound
                ? "media has flowed for \(Int(Constants.healthyReset))s since the last trouble, the restarts are back"
                : "connected for \(Int(Constants.healthyReset))s since the last trouble with nothing inbound expected, the restarts are back")
            restartCount = 0
        }

        lastBweIn = bweIn
        lastOutbound = outboundVideo
        reviewVideoSources(now, inboundVideo)

        // A source this side was asked to start over says what it has put out
        // since, tick by tick for a while: the difference between an encoder
        // that came back and one that did not is on this end — and this end
        // acts on it. A capture that has produced twenty frames since the
        // restart while the encoder turned out none is an encoder that is
        // dead for this family, which is written off and the call offered
        // again without it — unless the encoder says it is starved, which is
        // the path's problem.
        for (source, at) in refreshedAt where now.timeIntervalSince(at) <= Constants.refreshWatch {
            let stream = outboundVideo[source]

            trace("\(source.rawValue) \(String(format: "%.1f", now.timeIntervalSince(at)))s after the restart: \(CallPeer.describe(stream)) bwe out=\(CallPeer.kbps(bweOut))")

            guard let watch = refreshWatch[source], let stream = stream, now.timeIntervalSince(at) >= Constants.codecEncodeGrace else { continue }

            let encodedSince = stream.encoded - watch.encoded

            guard let produced = stream.produced, let producedThen = watch.produced, let family = stream.family else { continue }

            let producedSince = produced - producedThen

            if producedSince >= Constants.codecEncodeFrames, encodedSince == 0 {
                let why = CallPeer.encoderLimit(limit: stream.limit, target: stream.target)
                let name = family.replacingOccurrences(of: "video/", with: "")

                refreshWatch.removeValue(forKey: source)

                if CallPeer.encoderStarved(limit: stream.limit, target: stream.target) {
                    trace("the \(source.rawValue) encoder took \(producedSince) frames since the restart and encoded none, starved (\(why)): \(name) is not written off")
                } else {
                    trace("the \(source.rawValue) encoder took \(producedSince) frames since the restart and encoded none (\(why)): \(name) is dead here")
                    codecBroken(family: family, direction: CallCodecs.encode, why: why)
                }
            }
        }

        let packetLoss = (lost + received) > 0 ? Double(lost) / Double(lost + received) : 0

        stats.bytesSent = bytesSent
        stats.bytesReceived = bytesReceived
        stats.rtt = rtt
        stats.packetLoss = packetLoss
        stats.restarts = restartsTotal
        stats.counters = counters

        if !isConnected {
            stats.quality = everConnected ? .lost : .unknown
        } else if packetLoss < 0.02 && (rtt == nil || rtt! < 0.15) {
            stats.quality = .excellent
        } else if packetLoss < 0.05 && (rtt == nil || rtt! < 0.3) {
            stats.quality = .good
        } else {
            stats.quality = .poor
        }

        self.stats = stats

        // A call that reports nothing moving is a call nobody can hear, and on
        // this side the only place that said so was a statistics sheet nobody
        // opens — Android has written this line for a while and it is how the
        // mute was caught at all.
        //
        // Every change of ICE state, and a line every half minute otherwise.
        let ice = pc?.iceConnectionState
        let at = Date().timeIntervalSince1970

        if ice != loggedIce || at - loggedStatsAt > 30 {
            loggedIce = ice
            loggedStatsAt = at

            // What each inbound video stream has delivered: frames decoded of
            // frames assembled, packets, and the keyframe and retransmission
            // requests this side has made — the difference between a sender
            // that sends nothing and a receiver that cannot make a picture of
            // what arrives.
            let video = inboundVideo
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue)=\(CallPeer.describe($0.value))" }
                .joined(separator: " ")
            let sent = outboundVideo
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue)=\(CallPeer.describe($0.value))" }
                .joined(separator: " ")

            CallLog.write(
                "stats ice=\(ice.map { "\($0.rawValue)" } ?? "none") sent=\(bytesSent) " +
                    "a=\(audioSent) v=\(videoSent) recv=\(bytesReceived) " +
                    "audioSend=\(stats.audioSend ?? "null") videoSend=\(stats.videoSend ?? "null") " +
                    "audioRecv=\(stats.audioRecv ?? "null") videoRecv=\(stats.videoRecv ?? "null") " +
                    "rtt=\(rtt.map { String(format: "%.3f", $0) } ?? "null") " +
                    "loss=\(String(format: "%.3f", packetLoss)) " +
                    "bwe out=\(CallPeer.kbps(bweOut)) in=\(CallPeer.kbps(bweIn))" +
                    (video.isEmpty ? "" : " in[\(video)]") +
                    (sent.isEmpty ? "" : " out[\(sent)]")
            )
        }

        delegate?.peerStats(stats)
    }

    /// Frames decoded of frames assembled, packets, and the keyframe and
    /// retransmission requests this side has made of a stream.
    private static func describe(_ stream: InboundVideo?) -> String {
        guard let s = stream else { return "no stream" }

        return "\(s.decoded)/\(s.received)f \(s.packets)p pli\(s.pli) nack\(s.nack)"
    }

    /// Frames the capture produced, frames encoded, packets sent, what the
    /// encoder says is holding it back (none / bandwidth / cpu / other) and
    /// the bitrate it is aiming at. A capture that has stopped and an encoder
    /// that turns out nothing read the same in every count but the first.
    private static func describe(_ stream: OutboundVideo?) -> String {
        guard let s = stream else { return "no stream" }

        return "\(s.produced.map(String.init) ?? "?")c \(s.encoded)f \(s.packets)p \(s.limit) \(kbps(spendable(limit: s.limit, target: s.target)))"
    }

    private static func kbps(_ bps: Int?) -> String {
        guard let bps = bps else { return "?" }

        return "\(bps / 1000)k"
    }

    /// A video source that is expected and decodes nothing. Once it has been
    /// quiet for `videoStallTimeout` the sender is asked for a fresh picture;
    /// when that brings nothing for as long again, what the silence is made
    /// of decides what is done about it. A source that delivers a frame
    /// starts over, and one that stops being expected is forgotten
    /// (`setExpectedVideo`), so a camera the other side switched off is never
    /// asked for.
    private func reviewVideoSources(_ now: Date, _ inbound: [CallSource: InboundVideo]) {
        guard isConnected, let connectedAt = connectedAt else { return }

        for source in expectedVideo where source.isVideo {
            let stream = inbound[source]
            let frames = stream?.decoded ?? 0

            guard var progress = videoProgress[source] else {
                videoProgress[source] = (frames: frames, since: now, refreshed: false, receivedAtAsk: 0, packetsAtAsk: 0)
                continue
            }

            // Moving, or a fresh stream counting from zero again: not a silence.
            if frames != progress.frames {
                videoProgress[source] = (frames: frames, since: now, refreshed: false, receivedAtAsk: 0, packetsAtAsk: 0)
                continue
            }

            let quiet = now.timeIntervalSince(max(progress.since, connectedAt))

            // Every tick of a silence is written with what the stream has
            // delivered, because the numbers are the whole diagnosis: packets
            // still climbing with no frame assembled is a receiver that cannot
            // make a picture of what arrives; nothing climbing is a sender that
            // has stopped.
            if quiet >= Constants.statsInterval {
                trace("\(source.rawValue) silent \(String(format: "%.1f", quiet))s: \(CallPeer.describe(stream)) bwe in=\(CallPeer.kbps(lastBweIn))")
            }

            if quiet <= Constants.videoStallTimeout { continue }

            progress.since = now

            if !progress.refreshed {
                progress.refreshed = true
                progress.receivedAtAsk = stream?.received ?? 0
                progress.packetsAtAsk = stream?.packets ?? 0
                videoProgress[source] = progress

                trace("no picture from \(source.rawValue) for \(Int(Constants.videoStallTimeout * 1000))ms, asking for a fresh one")

                delegate?.peerSend([ "kind": "refresh", "source": source.rawValue ])
                continue
            }

            progress.refreshed = false
            videoProgress[source] = progress

            // Three kinds of silence need three different answers, and an
            // ICE restart, which every one of them used to get, mends none.
            let assembled = (stream?.received ?? 0) - progress.receivedAtAsk
            let packets = (stream?.packets ?? 0) - progress.packetsAtAsk

            if assembled > 0, let family = stream?.family {
                // Whole frames keep arriving and none comes out: the decoder
                // is what stopped, so the family is written off here and the
                // call offered again without it. The old predicate needed a
                // decoder that had never produced a frame, and one that had
                // decoded hundreds and then froze was left to the room.
                trace("still no picture from \(source.rawValue) after asking, while \(assembled) frames arrived whole: the \(family.replacingOccurrences(of: "video/", with: "")) decoder is dead here")
                codecBroken(family: family, direction: CallCodecs.decode)
                continue
            }

            if packets > 0 {
                // Packets arrive and no frame is ever whole: the path is
                // losing too much to carry a picture.
                trace("still no picture from \(source.rawValue) after asking: \(packets) packets arrived and no frame was whole, the path is losing too much")
                pathDead("the \(source.rawValue) arrives too broken to decode")
                continue
            }

            // Nothing arrived for this source at all while the connection is
            // up and the sender was asked twice: its capture or encoder is
            // what stopped. The sender's own watch writes off an encoder that
            // takes frames and turns out none; a capture that produces none is
            // told to open the device again.
            trace("still no picture from \(source.rawValue) after asking and nothing arrived for it at all: the sender's \(source.rawValue) stopped, not the path")

            let last = lastSilentNotice[.camera] ?? .distantPast

            if source == .camera, now.timeIntervalSince(last) >= Constants.silentNoticeMin {
                lastSilentNotice[.camera] = now
                delegate?.peerSilent(source: .camera)
            }
        }
    }

    // MARK: - Teardown

    func close() {
        queue.sync {
            guard !closed else { return }

            closed = true

            clearRestartTimers()
            clearConnectDeadline()

            holdWork?.cancel()
            holdWork = nil
            holdSpent = false

            privateHoldWork?.cancel()
            privateHoldWork = nil

            heldPrivateCandidates = []
            pendingCandidates = []

            statsTimer?.cancel()
            statsTimer = nil

            remoteTracks.removeAll()

            pc?.close()
            pc = nil
        }

        setConnection(.closed)
    }
}

// MARK: - The peer connection's own events

extension CallPeer: LKRTCPeerConnectionDelegate {
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {
        queue.async { [weak self] in self?.negotiate() }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        queue.async { [weak self] in
            guard let self = self, !self.closed else { return }

            if let parsed = CallCandidateInfo.parse(candidate.sdp), parsed.type == "srflx", !parsed.address.isEmpty {
                self.localPublicIps.insert(parsed.address)
                self.reviewHeldCandidates()
            }

            var payload: [String: Any] = [ "candidate": candidate.sdp, "sdpMLineIndex": Int(candidate.sdpMLineIndex) ]

            if let mid = candidate.sdpMid { payload["sdpMid"] = mid }

            self.delegate?.peerSend([ "kind": "candidate", "candidate": payload ])
        }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        queue.async { [weak self] in
            guard let self = self, !self.closed else { return }

            // From the event itself, not the stats tick two seconds later: a
            // state that comes and goes inside one tick used to leave no line.
            self.trace("ice \(CallPeer.name(of: newState))")

            switch newState {
            // The restarts are not given back here but once media has flowed
            // for `healthyReset`: a connection that comes up and drops again
            // at once is one that cannot be kept, and it used to be restarted
            // for ever.
            case .connected, .completed:
                self.everConnected = true
                self.clearConnectDeadline()
                self.connectedAt = Date()
                self.inboundChangedAt = self.connectedAt
                self.clearRestartTimers()
                self.setConnection(.connected)

                for source in CallSource.order { self.applyWanted(source) }

            case .disconnected:
                self.setConnection(.reconnecting)
                self.scheduleRestart(after: Constants.disconnectGrace, why: "ice disconnected")

            case .failed:
                self.setConnection(.reconnecting)
                self.scheduleRestart(after: 0, why: "ice failed")

            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange state: LKRTCPeerConnectionState) {
        guard state == .failed else { return }

        queue.async { [weak self] in
            guard let self = self, !self.closed else { return }

            self.trace("connection state failed")
            self.setConnection(.reconnecting)
            self.scheduleRestart(after: 0, why: "connection failed")
        }
    }

    /// A track arrived. Both callbacks are taken because they fire at
    /// different moments — `didAddReceiver` when the section is negotiated,
    /// `didStartReceivingOn` when media actually starts — and which one comes
    /// first depends on the other side. Taking one and missing the other is a
    /// call where the picture never appears.
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {
        adopt(track: transceiver.receiver.track, isVideo: transceiver.mediaType == .video, mid: transceiver.mid)
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd receiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        let track = receiver.track
        let isVideo = track?.kind == "video"

        // A receiver knows nothing about its mid, so the transceiver it
        // belongs to is looked up for one.
        let mid = pc?.transceivers.first { $0.receiver.receiverId == receiver.receiverId }?.mid ?? ""

        adopt(track: track, isVideo: isVideo, mid: mid)
    }

    /// The source of an incoming track is the mid map's answer, or a guess by
    /// kind and order: camera before screen, microphone before screen audio.
    private func adopt(track: LKRTCMediaStreamTrack?, isVideo: Bool, mid: String) {
        queue.async { [weak self] in
            guard let self = self, !self.closed, let track = track else { return }

            let source: CallSource

            if let mapped = self.remoteMids[mid], mapped.isVideo == isVideo {
                source = mapped
            } else if isVideo {
                source = self.remoteTracks[.camera] != nil ? .screenShare : .camera
            } else {
                source = self.remoteTracks[.microphone] != nil ? .screenShareAudio : .microphone
            }

            // The same track can arrive twice, once from each callback.
            if self.remoteTracks[source]?.trackId == track.trackId { return }

            self.remoteTracks[source] = track
            self.delegate?.peerTrack(source: source, track: track)
        }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
}
