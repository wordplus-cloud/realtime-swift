import Foundation
import LiveKitWebRTC
import Metal
import Network
#if canImport(UIKit)
import UIKit
import AVFoundation
#endif

/// How a direct call is going at this side, told to the relay on one pulse in
/// every few (the pulse reply's `qms`, 10 s by default, 0 for none: a relay
/// before it asks none and gets none), as the browser's engine tells it
/// (@wordplus/realtime-client 1.0.77, calls/quality.ts): what this side sends
/// of each source, what it plays of each source the other side sends, its
/// connection, and its machine (`CallHealthWatch`). Numbers only. The relay
/// keeps the latest reading of each side for the operator's live view of
/// calls, which judges a phone as it judges a browser.
///
/// Nothing here reads stats of its own: the peer hands every stats pass it
/// makes anyway to `tick`, which keeps the running totals and counts how long
/// a camera that is on gave no frame; `reading` says what changed since the
/// last reading and starts the window over. Called on the peer's queue.
struct CallQualityScope {
    /// This side's sources that are live, on and not paused for the other
    /// side drawing none of them; the other side's that are on and shown here.
    let sending: Set<CallSource>
    let playing: Set<CallSource>
    /// The source of a stats entry: by its mid, else by its track.
    let outbound: ([String: Any]) -> CallSource?
    let inbound: ([String: Any]) -> CallSource?
}

final class CallQualityWatch {
    struct Out {
        var kind: String
        var bytes = 0.0, packets = 0.0
        var frames: Double?, produced: Double?, capturedFps: Double?, height: Double?
        var limit: String?, cpuS: Double?, bwS: Double?, hw: Bool?
        var sendDelayS: Double?, nack: Double?, pli: Double?, remoteLost: Double?
        var codec: String?, encoder: String?, encodeS: Double?, encoded: Double?, framesSent: Double?, keyFrames: Double?
        var target: Double?, resent: Double?, huge: Double?, captureWidth: Double?, captureHeight: Double?
    }

    struct In {
        var kind: String
        var bytes = 0.0, packets = 0.0, lost = 0.0
        var frames: Double?, height: Double?, freezes: Double?, freezeS: Double?, dropped: Double?
        var jbDelayS: Double?, jbEmitted: Double?, samples: Double?, concealed: Double?, hw: Bool?
        var codec: String?, decoder: String?, decodeS: Double?
        /// The gaps between frames shown, their sum and the sum of their squares, s.
        var gaps: Double?, gapsSquared: Double?
        var pauses: Double?, pauseS: Double?, plis: Double?, nacks: Double?, stretched: Double?
        /// The network's jitter now, s: not a total.
        var jitter: Double?
    }

    struct Path {
        var rtt: Double?, out: Double?, inbound: Double?
        var sendFailed: Double?, asked: Double?, answered: Double?, switched: Double?
    }

    struct Totals {
        var at: Double
        var out: [CallSource: Out] = [:]
        var inbound: [CallSource: In] = [:]
        var path = Path()
    }

    private var base: Totals?
    private var latest: Totals?
    private var sending: Set<CallSource> = []
    private var playing: Set<CallSource> = []
    private var produced: [CallSource: (frames: Double, at: Double)] = [:]
    private var stalls: [CallSource: Double] = [:]
    /// When this side last started showing each source again after not showing it.
    private var shownAgain: [CallSource: Double] = [:]

    /// How long after this side shows a source again its first frame may still
    /// come, ending the gap this side made: the other side starts sending it
    /// again and its picture needs a key frame. A frame landing after a reading
    /// is the next one's.
    private static let resumeMs = 3000.0

    /// Encoders that run on the CPU, by the name WebRTC gives; any other it names
    /// is the device's. The name decides where there is one and
    /// `powerEfficientEncoder` where there isn't, as a group call's client reads them.
    private static let softwareEncoder = "^(libvpx|openh264|libaom|svt|ffmpeg|libx26|dav1d|rav1e|fake)"

    static func encoderHardware(_ name: String?, powerEfficient: Bool?) -> Bool? {
        guard let name = name else { return powerEfficient }

        return name.range(of: softwareEncoder, options: [.regularExpression, .caseInsensitive]) == nil
    }

    private static func word(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }

        return text
    }

    /// A stats entry's codec by its short name: `video/H264` as "h264".
    private static func codecWord(_ entry: [String: Any]?) -> String? {
        guard let mime = word(entry?["mimeType"]) else { return nil }

        return (mime.split(separator: "/").last.map(String.init) ?? mime).lowercased()
    }

    private static func num(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber else { return nil }

        let d = n.doubleValue

        return d.isFinite ? d : nil
    }

    private static func add(_ a: Double?, _ b: Double?) -> Double? {
        guard let a = a else { return b }
        guard let b = b else { return a }

        return a + b
    }

    /// One stats pass's running totals, by source, and the selected path.
    static func totals(_ report: LKRTCStatisticsReport, scope: CallQualityScope, at: Double) -> Totals {
        totals(report.statistics.map { CallPair.Entry(id: $0.key, type: $0.value.type, values: $0.value.values) }, scope: scope, at: at)
    }

    static func totals(_ entries: [CallPair.Entry], scope: CallQualityScope, at: Double) -> Totals {
        var totals = Totals(at: at)
        var transport: [String: Any]?
        var pair: [String: Any]?
        let byId = Dictionary(entries.map { ($0.id, $0.values) }, uniquingKeysWith: { first, _ in first })

        for entry in entries {
            let v = entry.values

            switch entry.type {
            case "outbound-rtp":
                guard let kind = (v["kind"] ?? v["mediaType"]) as? String, kind == "audio" || kind == "video",
                      let source = scope.outbound(v) else { break }

                let capture = (v["mediaSourceId"] as? String).flatMap { byId[$0] }
                let remote = (v["remoteId"] as? String).flatMap { byId[$0] }
                let durations = v["qualityLimitationDurations"] as? [String: NSNumber]
                let encoder = word(v["encoderImplementation"])
                var o = totals.out[source] ?? Out(kind: kind)

                o.bytes += num(v["bytesSent"]) ?? 0
                o.packets += num(v["packetsSent"]) ?? 0
                o.frames = add(o.frames, num(v["framesSent"]) ?? num(v["framesEncoded"]))
                o.produced = o.produced ?? num(capture?["frames"])
                o.capturedFps = o.capturedFps ?? num(capture?["framesPerSecond"])
                o.height = max(o.height ?? 0, num(v["frameHeight"]) ?? 0)
                if o.height == 0 { o.height = nil }
                o.limit = (v["qualityLimitationReason"] as? String) ?? o.limit
                o.cpuS = add(o.cpuS, durations?["cpu"]?.doubleValue)
                o.bwS = add(o.bwS, durations?["bandwidth"]?.doubleValue)
                o.hw = encoderHardware(encoder, powerEfficient: (v["powerEfficientEncoder"] as? NSNumber)?.boolValue) ?? o.hw
                o.sendDelayS = add(o.sendDelayS, num(v["totalPacketSendDelay"]))
                o.nack = add(o.nack, num(v["nackCount"]))
                o.pli = add(add(o.pli, num(v["pliCount"])), num(v["firCount"]))
                o.remoteLost = add(o.remoteLost, remote.map { max(0, num($0["packetsLost"]) ?? 0) })
                o.codec = codecWord((v["codecId"] as? String).flatMap { byId[$0] }) ?? o.codec
                o.encoder = encoder ?? o.encoder
                o.encodeS = add(o.encodeS, num(v["totalEncodeTime"]))
                o.encoded = add(o.encoded, num(v["framesEncoded"]))
                o.framesSent = add(o.framesSent, num(v["framesSent"]))
                o.keyFrames = add(o.keyFrames, num(v["keyFramesEncoded"]))
                o.target = add(o.target, num(v["targetBitrate"]))
                o.resent = add(o.resent, num(v["retransmittedPacketsSent"]))
                o.huge = add(o.huge, num(v["hugeFramesSent"]))
                o.captureWidth = o.captureWidth ?? num(capture?["width"])
                o.captureHeight = o.captureHeight ?? num(capture?["height"])

                totals.out[source] = o

            case "inbound-rtp":
                guard let kind = (v["kind"] ?? v["mediaType"]) as? String, kind == "audio" || kind == "video",
                      let source = scope.inbound(v) else { break }

                var i = totals.inbound[source] ?? In(kind: kind)

                i.bytes += num(v["bytesReceived"]) ?? 0
                i.packets += num(v["packetsReceived"]) ?? 0
                i.lost += max(0, num(v["packetsLost"]) ?? 0)
                i.frames = add(i.frames, num(v["framesDecoded"]))
                i.height = max(i.height ?? 0, num(v["frameHeight"]) ?? 0)
                if i.height == 0 { i.height = nil }
                i.freezes = add(i.freezes, num(v["freezeCount"]))
                i.freezeS = add(i.freezeS, num(v["totalFreezesDuration"]))
                i.dropped = add(i.dropped, num(v["framesDropped"]))
                i.jbDelayS = add(i.jbDelayS, num(v["jitterBufferDelay"]))
                i.jbEmitted = add(i.jbEmitted, num(v["jitterBufferEmittedCount"]))
                i.samples = add(i.samples, num(v["totalSamplesReceived"]))
                // made up while the other side was silent costs nothing anyone hears
                if let concealed = num(v["concealedSamples"]) {
                    i.concealed = add(i.concealed, concealed - (num(v["silentConcealedSamples"]) ?? 0))
                }
                i.hw = (v["powerEfficientDecoder"] as? NSNumber)?.boolValue ?? i.hw
                i.codec = codecWord((v["codecId"] as? String).flatMap { byId[$0] }) ?? i.codec
                i.decoder = word(v["decoderImplementation"]) ?? i.decoder
                i.decodeS = add(i.decodeS, num(v["totalDecodeTime"]))
                i.gaps = add(i.gaps, num(v["totalInterFrameDelay"]))
                i.gapsSquared = add(i.gapsSquared, num(v["totalSquaredInterFrameDelay"]))
                i.pauses = add(i.pauses, num(v["pauseCount"]))
                i.pauseS = add(i.pauseS, num(v["totalPausesDuration"]))
                i.plis = add(i.plis, num(v["pliCount"]))
                i.nacks = add(i.nacks, num(v["nackCount"]))
                i.stretched = add(i.stretched, add(num(v["insertedSamplesForDeceleration"]), num(v["removedSamplesForAcceleration"])))
                i.jitter = num(v["jitter"]) ?? i.jitter

                totals.inbound[source] = i

            case "transport":
                if transport == nil, v["selectedCandidatePairId"] is String { transport = v }

            case "candidate-pair":
                let selected = (v["selected"] as? NSNumber)?.boolValue ?? false
                let nominated = (v["nominated"] as? NSNumber)?.boolValue ?? false

                if pair == nil, v["state"] as? String == "succeeded", selected || nominated { pair = v }

            default:
                break
            }
        }

        let selected = (transport?["selectedCandidatePairId"] as? String).flatMap { byId[$0] } ?? pair

        if let p = selected {
            totals.path = Path(
                rtt: num(p["currentRoundTripTime"]).map { ($0 * 1000).rounded() },
                out: num(p["availableOutgoingBitrate"]).map { ($0 / 1000).rounded() },
                inbound: num(p["availableIncomingBitrate"]).map { ($0 / 1000).rounded() },
                sendFailed: num(p["packetsDiscardedOnSend"]),
                asked: num(p["consentRequestsSent"]) ?? num(p["requestsSent"]),
                answered: num(p["responsesReceived"]),
                switched: num(transport?["selectedCandidatePairChanges"])
            )
        }

        return totals
    }

    func tick(_ report: LKRTCStatisticsReport, scope: CallQualityScope, at: Double) {
        note(CallQualityWatch.totals(report, scope: scope, at: at), scope: scope, at: at)
    }

    /// One pass's totals: what it changes of what the next reading says.
    func note(_ totals: Totals, scope: CallQualityScope, at: Double) {
        if latest != nil {
            for source in scope.playing where !playing.contains(source) { shownAgain[source] = at }
        }

        latest = totals
        sending = scope.sending
        playing = scope.playing

        if base == nil { base = totals }

        for (source, out) in totals.out where out.kind == "video" {
            guard let frames = out.produced else { continue }

            let last = produced[source]

            produced[source] = (frames: frames, at: at)

            guard let previous = last, scope.sending.contains(source) else { continue }

            if frames == previous.frames {
                stalls[source] = (stalls[source] ?? 0) + (at - previous.at)
            } else if stalls[source] == nil {
                stalls[source] = 0
            }
        }
    }

    /// What changed since the last reading, the window started over; nil
    /// before a pass has come after the first.
    func reading(health: [String: Any]?) -> [String: Any]? {
        guard let base = base, let latest = latest, latest.at > base.at else { return nil }

        var reading = CallQualityWatch.between(base, latest, sending: sending, playing: playing, stalls: stalls, shownAgain: shownAgain)
        var h = health ?? [:]

        if let path = CallQualityWatch.pathBetween(base, latest) { h["path"] = path }
        if !h.isEmpty { reading["health"] = h }

        self.base = latest
        stalls.removeAll()

        return reading
    }

    private static func delta(_ a: Double?, _ b: Double?) -> Double? {
        guard let a = a, let b = b, b >= a else { return nil }

        return b - a
    }

    private static func round1(_ v: Double) -> Double {
        (v * 10).rounded() / 10
    }

    static func between(_ prev: Totals, _ now: Totals, sending: Set<CallSource>, playing: Set<CallSource>, stalls: [CallSource: Double], shownAgain: [CallSource: Double] = [:]) -> [String: Any] {
        let ms = max(0, (now.at - prev.at).rounded())
        let seconds = ms / 1000
        var reading: [String: Any] = [ "ms": Int(ms) ]
        var sent: [[String: Any]] = []
        var played: [[String: Any]] = []

        if let v = now.path.rtt { reading["rtt"] = v }
        if let v = now.path.out { reading["out"] = v }
        if let v = now.path.inbound { reading["in"] = v }

        var upSent = 0.0
        var upLost = 0.0
        let order = CallSource.allCases

        for source in order {
            guard let n = now.out[source], let p = prev.out[source], seconds > 0 else { continue }

            let packets = delta(p.packets, n.packets)
            let lost = delta(p.remoteLost, n.remoteLost)

            if let packets = packets, let lost = lost {
                upSent += packets
                upLost += lost
            }

            guard sending.contains(source) else { continue }

            var t: [String: Any] = [ "kind": n.kind, "source": source.rawValue ]

            if let bytes = delta(p.bytes, n.bytes) { t["kbps"] = (bytes * 8 / seconds / 1000).rounded() }
            if let codec = n.codec { t["codec"] = codec }
            if let resent = delta(p.resent, n.resent), resent > 0, let packets = packets, packets > 0 { t["resent"] = round1(min(100, resent * 100 / packets)) }

            if n.kind == "video" {
                if let encoder = n.encoder { t["encoder"] = encoder }

                let encoded = delta(p.encoded, n.encoded)

                if let encoded = encoded, encoded > 0, let encodeS = delta(p.encodeS, n.encodeS) { t["encodeMs"] = round1(encodeS * 1000 / encoded) }
                if let encoded = encoded { t["encoded"] = encoded }
                if let framesSent = delta(p.framesSent, n.framesSent) { t["framesSent"] = framesSent }
                if let keyFrames = delta(p.keyFrames, n.keyFrames) { t["keyFrames"] = keyFrames }
                if let target = n.target, target > 0 { t["target"] = (target / 1000).rounded() }
                if let huge = delta(p.huge, n.huge), huge > 0 { t["huge"] = huge }

                // The size its capture gives, as its stats say. No frames a second:
                // a mode's are what the capture was opened at, and these stats say
                // only what it gives, which a dim room halves.
                if let width = n.captureWidth, let height = n.captureHeight, width > 0, height > 0 {
                    t["mode"] = [ "width": width, "height": height ]
                }

                if let frames = delta(p.frames, n.frames) { t["fps"] = round1(frames / seconds) }

                if let made = delta(p.produced, n.produced) { t["captured"] = round1(made / seconds) }
                else if let fps = n.capturedFps { t["captured"] = round1(fps) }

                if let height = n.height { t["height"] = height }
                if let limit = n.limit { t["limit"] = limit }
                if let cpu = delta(p.cpuS, n.cpuS) { t["cpuMs"] = (cpu * 1000).rounded() }
                if let bw = delta(p.bwS, n.bwS) { t["bwMs"] = (bw * 1000).rounded() }
                if let hw = n.hw { t["hw"] = hw }
                if let stall = stalls[source] { t["stallMs"] = stall.rounded() }
                if let pli = delta(p.pli, n.pli) { t["pli"] = pli }
            }

            if let delay = delta(p.sendDelayS, n.sendDelayS), let packets = packets, packets > 0 { t["queueMs"] = round1(delay * 1000 / packets) }
            if let nack = delta(p.nack, n.nack) { t["nack"] = nack }
            if let packets = packets, packets > 0, let lost = lost { t["lost"] = round1(min(100, lost * 100 / packets)) }

            sent.append(t)
        }

        if upSent > 0 { reading["up"] = round1(min(100, upLost * 100 / upSent)) }

        for source in order {
            guard let n = now.inbound[source], let p = prev.inbound[source], seconds > 0, playing.contains(source) else { continue }

            var t: [String: Any] = [ "kind": n.kind, "source": source.rawValue ]

            if let bytes = delta(p.bytes, n.bytes) { t["kbps"] = (bytes * 8 / seconds / 1000).rounded() }

            if let received = delta(p.packets, n.packets), let lost = delta(p.lost, n.lost), received + lost > 0 {
                t["lost"] = round1(lost * 100 / (received + lost))
            }

            if let codec = n.codec { t["codec"] = codec }

            if let delay = delta(p.jbDelayS, n.jbDelayS), let emitted = delta(p.jbEmitted, n.jbEmitted), emitted > 0 {
                t["jbMs"] = (delay * 1000 / emitted).rounded()
            }

            if n.kind == "video" {
                let frames = delta(p.frames, n.frames)

                if let frames = frames { t["fps"] = round1(frames / seconds) }
                if let height = n.height { t["height"] = height }

                var freezes = delta(p.freezes, n.freezes)
                var frozen = delta(p.freezeS, n.freezeS)
                let pauses = delta(p.pauses, n.pauses)
                let paused = delta(p.pauseS, n.pauseS)
                // A gap this side made itself, not showing the source (the other
                // side's camera off until now, or a call screen not drawing it),
                // isn't the call's: a source shown again since just before the
                // last reading owns the pauses ending in this one, or the one
                // freeze its gap came out as when too short for a pause.
                let resumed = shownAgain[source].map { $0 > prev.at - resumeMs } ?? false
                var hidden: (gaps: Double, seconds: Double?)?

                if resumed, let pauses = pauses, pauses > 0 {
                    hidden = (pauses, paused)
                } else if resumed, freezes == 1 {
                    hidden = (1, frozen)
                    freezes = 0
                    frozen = 0
                }

                if let hidden = hidden {
                    t["hiddenGaps"] = hidden.gaps

                    if let seconds = hidden.seconds { t["hiddenGapMs"] = (seconds * 1000).rounded() }
                }

                if let freezes = freezes {
                    t["freezes"] = freezes

                    if let frozen = frozen { t["freezeMs"] = (frozen * 1000).rounded() }
                }

                if let dropped = delta(p.dropped, n.dropped) { t["dropped"] = dropped }
                if let hw = n.hw { t["hw"] = hw }
                if let decoder = n.decoder { t["decoder"] = decoder }
                if let frames = frames, frames > 0, let decodeS = delta(p.decodeS, n.decodeS) { t["decodeMs"] = round1(decodeS * 1000 / frames) }

                // WebRTC adds every gap to both sums, a pause's and a freeze's too,
                // as its very length, so one hidden gap comes out exactly; several,
                // or one no total tells, leave the spread unsaid this reading.
                var gaps = delta(p.gaps, n.gaps)
                var squared = delta(p.gapsSquared, n.gapsSquared)
                var shown = frames

                if resumed {
                    if let hidden = hidden, hidden.gaps == 1, let seconds = hidden.seconds, let frames = frames, frames > 0, let sum = gaps, let sumSquared = squared {
                        gaps = sum - seconds
                        squared = sumSquared - seconds * seconds
                        shown = frames - 1
                    } else {
                        gaps = nil
                    }
                }

                if let shown = shown, shown > 1, let gaps = gaps, let squared = squared {
                    let mean = gaps / shown

                    t["unevenMs"] = (max(0, squared / shown - mean * mean).squareRoot() * 1000).rounded()
                }

                if let pauses = pauses, pauses > 0, hidden == nil {
                    t["pauses"] = pauses

                    if let paused = paused { t["pauseMs"] = (paused * 1000).rounded() }
                }

                if let plis = delta(p.plis, n.plis), plis > 0 { t["plis"] = plis }
                if let nacks = delta(p.nacks, n.nacks), nacks > 0 { t["nacks"] = nacks }
            } else if let samples = delta(p.samples, n.samples), samples > 0 {
                if let concealed = delta(p.concealed, n.concealed) { t["concealed"] = round1(min(100, concealed * 100 / samples)) }
                if let stretched = delta(p.stretched, n.stretched), stretched > 0 { t["stretched"] = round1(min(100, stretched * 100 / samples)) }
            }

            if let jitter = n.jitter, jitter >= 0.001 { t["jitterMs"] = (jitter * 1000).rounded() }

            played.append(t)
        }

        reading["sent"] = sent
        reading["played"] = played

        return reading
    }

    /// Sends that failed, checks left unanswered and switches of path.
    static func pathBetween(_ prev: Totals, _ now: Totals) -> [String: Any]? {
        var out: [String: Any] = [:]

        if let failed = delta(prev.path.sendFailed, now.path.sendFailed), failed > 0 { out["sendFailed"] = failed }

        if let asked = delta(prev.path.asked, now.path.asked), let answered = delta(prev.path.answered, now.path.answered), asked > answered {
            out["unanswered"] = asked - answered
        }

        if let switched = delta(prev.path.switched, now.path.switched), switched > 0 { out["switched"] = switched }

        return out.isEmpty ? nil : out
    }
}

/// How the phone running a direct call is doing, for its quality readings, in
/// the words a browser's engine uses (calls/health.ts): iOS's thermal state
/// for the CPU pressure a browser reports (the same four states, nominal to
/// critical: how hard the system is holding the device back), the time the
/// app was in the background, a battery, audio routes changing, and the
/// machine (on a Mac, the thermal state and the machine alone). Each from a
/// notification the system posts anyway; nothing runs a timer. Started once a
/// relay asks for readings, on the main thread.
final class CallHealthWatch {
    private static let rank: [String: Int] = [ "nominal": 0, "fair": 1, "serious": 2, "critical": 3 ]

    private var worst: String?
    private var pressure: String?
    private var pressureAt = 0.0
    private var cpuMs = 0.0
    private var hiddenMs = 0.0
    private var hiddenAt: Double?
    private var devices = 0
    private var observers: [NSObjectProtocol] = []
    private var batteryWas = false
    private var path: NWPathMonitor?
    private lazy var machine: [String: Any] = CallHealthWatch.describeMachine()

    /// The network it is on, by the system's word on its path, for the call's
    /// report; nil before it has said, and on anything else.
    var network: String? {
        guard let current = path?.currentPath, current.status == .satisfied else { return nil }

        if current.usesInterfaceType(.wifi) { return "wifi" }
        if current.usesInterfaceType(.cellular) { return "cellular" }
        if current.usesInterfaceType(.wiredEthernet) { return "ethernet" }

        return nil
    }

    private static func now() -> Double { Date().timeIntervalSince1970 * 1000 }

    private static func name(of state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "nominal"
        }
    }

    var started: Bool { !observers.isEmpty }

    func start() {
        guard observers.isEmpty else { return }

        let center = NotificationCenter.default
        let at = CallHealthWatch.now()

        worst = nil
        pressure = nil
        pressureAt = at
        cpuMs = 0
        hiddenMs = 0
        hiddenAt = nil
        devices = 0

        pressureChanged(CallHealthWatch.name(of: ProcessInfo.processInfo.thermalState), at: at)

        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pressureChanged(CallHealthWatch.name(of: ProcessInfo.processInfo.thermalState), at: CallHealthWatch.now())
        })
        #if canImport(UIKit)
        hiddenAt = UIApplication.shared.applicationState == .background ? at : nil
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.visibilityChanged(hidden: true, at: CallHealthWatch.now())
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.visibilityChanged(hidden: false, at: CallHealthWatch.now())
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.devices += 1
        })

        batteryWas = UIDevice.current.isBatteryMonitoringEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif

        let monitor = NWPathMonitor()

        monitor.start(queue: .global(qos: .utility))
        path = monitor
    }

    func stop() {
        guard !observers.isEmpty else { return }

        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = batteryWas
        #endif
        path?.cancel()
        path = nil
    }

    private func pressureChanged(_ state: String, at: Double) {
        guard let rank = CallHealthWatch.rank[state] else { return }

        accountPressure(at: at)
        pressure = state

        if worst == nil || rank > (CallHealthWatch.rank[worst!] ?? 0) { worst = state }
    }

    private func accountPressure(at: Double) {
        if let p = pressure, (CallHealthWatch.rank[p] ?? 0) >= 2 { cpuMs += at - pressureAt }

        pressureAt = at
    }

    private func visibilityChanged(hidden: Bool, at: Double) {
        if hidden, hiddenAt == nil {
            hiddenAt = at
        } else if !hidden, let since = hiddenAt {
            hiddenMs += at - since
            hiddenAt = nil
        }
    }

    /// What happened since the last reading, and the counters started over;
    /// read on the main thread, where the notifications land.
    func reading(at: Double) -> [String: Any] {
        guard started else { return [:] }

        accountPressure(at: at)

        var out: [String: Any] = [ "machine": machine ]

        if let w = worst, w != "nominal" { out["cpu"] = w }
        if cpuMs > 0 { out["cpuMs"] = cpuMs.rounded() }

        let hidden = hiddenMs + (hiddenAt.map { at - $0 } ?? 0)

        if hidden > 0 { out["hiddenMs"] = hidden.rounded() }

        #if canImport(UIKit)
        switch UIDevice.current.batteryState {
        case .unplugged: out["battery"] = true
        case .charging, .full: out["battery"] = false
        default: break
        }
        #endif

        if devices > 0 { out["devices"] = devices }

        // what carries on starts the next reading as it is now
        worst = pressure
        cpuMs = 0
        hiddenMs = 0
        hiddenAt = hiddenAt == nil ? nil : at
        devices = 0

        return out
    }

    /// Its cores, its memory rounded to whole gigabytes, and its graphics.
    private static func describeMachine() -> [String: Any] {
        var out: [String: Any] = [
            "cores": ProcessInfo.processInfo.activeProcessorCount,
            "memGb": (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()
        ]

        if let gpu = MTLCreateSystemDefaultDevice()?.name { out["gpu"] = String(gpu.prefix(60)) }

        return out
    }
}

/// What else a group call's client tells its node on a join, for a direct call's
/// report, as the browser's engine says it (calls/session.ts): this package and its
/// version, the kind of device, the network, and the video codecs it encodes and
/// decodes in hardware.
enum CallClientInfo {
    /// By the engine's own probe, once: the report comes every 20 s, and what the
    /// device does in hardware stays what it is. On the main thread, as the report.
    private static var hardware: (enc: String, dec: String)?

    static func report(media: CallMedia, network: String?) -> [String: Any] {
        let hw = hardware ?? {
            let caps = media.codecCaps

            return (enc: hardwareFamilies(caps, encoding: true), dec: hardwareFamilies(caps, encoding: false))
        }()

        hardware = hw

        #if canImport(UIKit)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone"
        #else
        let device = "desktop"
        #endif

        var out: [String: Any] = [ "lib": "realtime-swift " + RealtimeCalls.version, "device": device ]

        if let network = network { out["network"] = network }
        if !hw.enc.isEmpty { out["hwEnc"] = hw.enc }
        if !hw.dec.isEmpty { out["hwDec"] = hw.dec }

        return out
    }

    /// The families a probe says run in hardware, as short names ("h264,vp9").
    static func hardwareFamilies(_ caps: CallCodecCaps, encoding: Bool) -> String {
        CallCodecs.families.filter { family in
            guard let pair = caps.families[family] else { return false }

            let score = encoding ? pair.enc : pair.dec

            return score.ok && score.hw
        }.map { $0.dropFirst("video/".count).lowercased() }.joined(separator: ",")
    }
}
