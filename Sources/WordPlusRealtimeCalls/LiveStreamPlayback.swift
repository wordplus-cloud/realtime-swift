import CoreGraphics
import Foundation

// How a live stream plays here, to debug it, and the viewer's choice of picture, as the browser's stream has them
// (realtime-client sdk-calls/stream.ts:268-289, streams/playback.ts). The room client keeps no list of a sender's layers
// here, so they are worked out from the picture's size: the largest as it is, then half and a quarter.

/// A viewer's choice of picture: by the size of the view showing it (`auto`, the default), or one of its layers.
public enum LiveStreamQuality: String, Sendable {
    case auto
    case high
    case medium
    case low
}

/// A layer of a picture, as `LiveStream.qualities()` offers it: `high`, `medium` or `low`, with its size.
public struct LiveStreamLayer: Equatable, Sendable {
    public let quality: LiveStreamQuality
    public let width: Int
    public let height: Int

    public init(quality: LiveStreamQuality, width: Int, height: Int) {
        self.quality = quality
        self.width = width
        self.height = height
    }
}

/// How a live stream plays here, as `LiveStream.stats()` answers: measured on this device once a second while the room is
/// joined, and sent nowhere. Rates come from two readings, so the first says 0.
public struct LiveStreamStats: Equatable, Sendable {
    /// The media server: the address joined, and the node and region that answered, where it says.
    public struct Server: Equatable, Sendable {
        public let url: String?
        public let node: String?
        public let region: String?
        public let version: String?
    }

    /// The main picture as it arrives.
    public struct Video: Equatable, Sendable {
        public let codec: String?
        public let width: Int
        public let height: Int
        public let fps: Double
        public let kbps: Double
        /// The layer arriving, by its height; nil where the layers say no sizes.
        public let layer: LiveStreamQuality?
        public let layers: [LiveStreamLayer]
        public let lossPct: Double
        public let jitterMs: Double
        /// How long frames wait to play, on average since the last reading.
        public let bufferMs: Double
        public let dropped: Int
        public let freezes: Int
        public let frozenMs: Double
        public let nacks: Int
        public let plis: Int
        public let decoder: String?
        public let hardware: Bool?
    }

    /// The sound as it arrives.
    public struct Audio: Equatable, Sendable {
        public let codec: String?
        public let kbps: Double
        public let lossPct: Double
        public let jitterMs: Double
        public let bufferMs: Double
        /// The share of the sound made up for what didn't come, since the last reading.
        public let concealedPct: Double
    }

    /// The way it comes: `udp` or `tcp`, and whether through a relay, over which protocol.
    public struct Transport: Equatable, Sendable {
        public let `protocol`: String?
        public let relayed: Bool?
        public let relayProtocol: String?
        public let rttMs: Double?
    }

    /// The session so far. `startupMs` is from the first join to the first frame, nil until one came.
    public struct Session: Equatable, Sendable {
        public var startupMs: Double?
        public var watchedMs: Double = 0
        public var stalls = 0
        public var stalledMs: Double = 0
        public var reconnects = 0
        public var rejoins = 0
        public var errors = 0
    }

    /// Something that happened: `joining`, `joined`, `first-frame`, `stalled`, `resumed`, `reconnecting`, `reconnected`,
    /// `rejoined`, `quality`, `error`, `left`.
    public struct Event: Equatable, Sendable {
        public let at: Date
        public let kind: String
        public let detail: String?
    }

    public let at: Date
    public let server: Server?
    public let video: Video?
    public let audio: Audio?
    public let transport: Transport?
    public let session: Session
    public let events: [Event]
}

/// A sender's layers, and which of them a viewer may choose.
enum LiveStreamPicture {
    /// None above this on its shorter side may be chosen: Full HD comes only on `auto`, to a view that needs it, as the
    /// protocol has it for the browser's player (CHOSEN_MAX_SIDE).
    static let chosenMaxSide = 720

    /// The layers of a picture this size, the best first.
    static func layers(width: Int, height: Int, simulcast: Bool) -> [LiveStreamLayer] {
        guard simulcast, width > 0, height > 0 else { return [LiveStreamLayer(quality: .high, width: width, height: height)] }
        return [
            LiveStreamLayer(quality: .high, width: width, height: height),
            LiveStreamLayer(quality: .medium, width: width / 2, height: height / 2),
            LiveStreamLayer(quality: .low, width: width / 4, height: height / 4),
        ]
    }

    /// Those a viewer may choose. A layer whose size the sender doesn't say (an encoder over WHIP) stays.
    static func choosable(_ layers: [LiveStreamLayer]) -> [LiveStreamLayer] {
        layers.filter { $0.height == 0 || min($0.width, $0.height) <= chosenMaxSide }
    }

    /// The layer that goes to a viewer who chose `choice`: that one, or where it is above the limit the largest below it.
    /// Nil on `auto`, and where the picture has no such layer.
    static func chosen(_ choice: LiveStreamQuality, in layers: [LiveStreamLayer]) -> LiveStreamLayer? {
        guard choice != .auto, let asked = layers.first(where: { $0.quality == choice }) else { return nil }
        let allowed = choosable(layers)
        return allowed.contains(asked) ? asked : allowed.first ?? asked
    }

    /// The layer a picture this tall is: the nearest by height.
    static func layer(atHeight height: Int, in layers: [LiveStreamLayer]) -> LiveStreamQuality? {
        let sized = layers.filter { $0.height > 0 }
        guard height > 0 else { return nil }
        return sized.min { abs($0.height - height) < abs($1.height - height) }?.quality
    }

    /// The pixels a point stands for so a view this size asks for just this layer: under adaptive stream a picture comes
    /// at the size its view asks. Nil for a view not laid out yet, or a layer of no size.
    static func density(for layer: LiveStreamLayer, in view: CGSize, fills: Bool) -> Double? {
        guard layer.width > 0, layer.height > 0, view.width > 0, view.height > 0 else { return nil }
        let aspect = Double(layer.width) / Double(layer.height)
        let boxAspect = Double(view.width) / Double(view.height)
        // The height the picture is drawn at: the view's, unless it is cut to fit the width.
        let fitsByHeight = fills ? aspect < boxAspect : aspect > boxAspect
        let drawn = fitsByHeight ? Double(view.width) / aspect : Double(view.height)
        return Double(layer.height) / drawn
    }
}

/// One reading of a track's counters as the room client reports them.
struct LiveStreamRtp: Equatable {
    var bytes: UInt64 = 0
    var frames: UInt = 0
    var lost: Int64 = 0
    var received: UInt64 = 0
    var bufferDelay: Double = 0
    var emitted: UInt64 = 0
    var concealed: UInt64 = 0
    var samples: UInt64 = 0
    var freezes: UInt = 0
    var frozen: Double = 0
    var nacks: UInt = 0
    var plis: UInt = 0
    var dropped: UInt = 0
    var width: UInt = 0
    var height: UInt = 0
    var fps: Double = 0
    var jitter: Double = 0
    var codec: String?
    var decoder: String?
    var hardware: Bool?
}

/// The session's account, kept from what the stream tells it and one reading a second.
final class LiveStreamPlayback {
    static let eventsKept = 50
    /// A picture that shows no new frame this long while it should is stalled.
    static let stallAfter: TimeInterval = 2

    private(set) var session = LiveStreamStats.Session()
    private(set) var events: [LiveStreamStats.Event] = []
    var server: LiveStreamStats.Server?
    private var video: LiveStreamStats.Video?
    private var audio: LiveStreamStats.Audio?
    private var transport: LiveStreamStats.Transport?
    private var before: (video: LiveStreamRtp, audio: LiveStreamRtp, at: Date)?
    private var joiningAt: Date?
    private var joinedAt: Date?
    private var joinedOnce = false
    private var lastFrames: UInt = 0
    private var lastFrameAt: Date?
    private var stalledSince: Date?

    func note(_ kind: String, _ detail: String? = nil, at: Date = Date()) {
        events.append(LiveStreamStats.Event(at: at, kind: kind, detail: detail))
        if events.count > Self.eventsKept { events.removeFirst(events.count - Self.eventsKept) }
    }

    func joining(at: Date = Date()) {
        if joiningAt == nil { joiningAt = at }
        note("joining", at: at)
    }

    func joined(server: LiveStreamStats.Server?, at: Date = Date()) {
        self.server = server
        joinedAt = at
        lastFrames = 0
        lastFrameAt = at
        before = nil
        if joinedOnce {
            session.rejoins += 1
            note("rejoined", at: at)
        } else {
            note("joined", at: at)
        }
        joinedOnce = true
    }

    func reconnecting(at: Date = Date()) {
        session.reconnects += 1
        note("reconnecting", at: at)
    }

    func reconnected(at: Date = Date()) {
        note("reconnected", at: at)
    }

    func failed(_ code: String, at: Date = Date()) {
        session.errors += 1
        note("error", code, at: at)
    }

    func left(at: Date = Date()) {
        settle(at: at)
        guard joinedAt != nil else { return }
        session.watchedMs += at.timeIntervalSince(joinedAt ?? at) * 1000
        joinedAt = nil
        note("left", at: at)
    }

    /// One reading: the main picture and its sound, nil for what isn't arriving. `pictured`, whether a picture should be
    /// showing new frames now.
    func read(video v: LiveStreamRtp?, audio a: LiveStreamRtp?, layers: [LiveStreamLayer], transport: LiveStreamStats.Transport?, pictured: Bool, at: Date = Date()) {
        let was = before
        let seconds = was.map { max(at.timeIntervalSince($0.at), 0.001) }
        video = v.map { Self.video($0, before: was?.video, seconds: seconds, layers: layers) }
        audio = a.map { Self.audio($0, before: was?.audio, seconds: seconds) }
        self.transport = transport
        before = (v ?? LiveStreamRtp(), a ?? LiveStreamRtp(), at)
        watchFrames(v?.frames ?? 0, pictured: pictured, at: at)
    }

    private func watchFrames(_ frames: UInt, pictured: Bool, at: Date) {
        if frames > lastFrames {
            if lastFrames == 0, session.startupMs == nil, let joiningAt {
                session.startupMs = at.timeIntervalSince(joiningAt) * 1000
                note("first-frame", at: at)
            }
            lastFrames = frames
            lastFrameAt = at
            settle(at: at, resumed: true)
        } else if !pictured {
            lastFrameAt = at
            settle(at: at)
        } else if lastFrames > 0, stalledSince == nil, let lastFrameAt, at.timeIntervalSince(lastFrameAt) >= Self.stallAfter {
            stalledSince = lastFrameAt
            session.stalls += 1
            note("stalled", at: at)
        }
    }

    private func settle(at: Date, resumed: Bool = false) {
        guard let since = stalledSince else { return }
        session.stalledMs += at.timeIntervalSince(since) * 1000
        stalledSince = nil
        if resumed { note("resumed", at: at) }
    }

    func snapshot(at: Date = Date()) -> LiveStreamStats {
        var now = session
        if let joinedAt { now.watchedMs += at.timeIntervalSince(joinedAt) * 1000 }
        if let stalledSince { now.stalledMs += at.timeIntervalSince(stalledSince) * 1000 }
        return LiveStreamStats(at: at, server: server, video: video, audio: audio, transport: transport, session: now, events: events)
    }

    private static func kbps(_ bytes: UInt64, _ before: UInt64?, _ seconds: Double?) -> Double {
        guard let before, let seconds, bytes >= before else { return 0 }
        return Double(bytes - before) * 8 / seconds / 1000
    }

    /// The share lost since the last reading, as a percentage.
    private static func loss(_ now: LiveStreamRtp, _ before: LiveStreamRtp?) -> Double {
        guard let before else { return 0 }
        let lost = max(0, now.lost - before.lost)
        let got = now.received >= before.received ? now.received - before.received : 0
        let all = Double(lost) + Double(got)
        return all > 0 ? Double(lost) / all * 100 : 0
    }

    private static func buffer(_ now: LiveStreamRtp, _ before: LiveStreamRtp?) -> Double {
        guard let before, now.emitted > before.emitted else { return 0 }
        return (now.bufferDelay - before.bufferDelay) / Double(now.emitted - before.emitted) * 1000
    }

    private static func video(_ now: LiveStreamRtp, before: LiveStreamRtp?, seconds: Double?, layers: [LiveStreamLayer]) -> LiveStreamStats.Video {
        LiveStreamStats.Video(
            codec: now.codec,
            width: Int(now.width),
            height: Int(now.height),
            fps: now.fps,
            kbps: kbps(now.bytes, before?.bytes, seconds),
            layer: LiveStreamPicture.layer(atHeight: Int(now.height), in: layers),
            layers: layers,
            lossPct: loss(now, before),
            jitterMs: now.jitter * 1000,
            bufferMs: buffer(now, before),
            dropped: Int(now.dropped),
            freezes: Int(now.freezes),
            frozenMs: now.frozen * 1000,
            nacks: Int(now.nacks),
            plis: Int(now.plis),
            decoder: now.decoder,
            hardware: now.hardware
        )
    }

    private static func audio(_ now: LiveStreamRtp, before: LiveStreamRtp?, seconds: Double?) -> LiveStreamStats.Audio {
        var concealedPct = 0.0
        if let before, now.samples > before.samples, now.concealed >= before.concealed {
            concealedPct = Double(now.concealed - before.concealed) / Double(now.samples - before.samples) * 100
        }
        return LiveStreamStats.Audio(
            codec: now.codec,
            kbps: kbps(now.bytes, before?.bytes, seconds),
            lossPct: loss(now, before),
            jitterMs: now.jitter * 1000,
            bufferMs: buffer(now, before),
            concealedPct: concealedPct
        )
    }
}
