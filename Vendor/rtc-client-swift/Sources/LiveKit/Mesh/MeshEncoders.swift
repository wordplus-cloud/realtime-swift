/*
 * Copyright 2026 The WordPlus RTC client authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

internal import LiveKitWebRTC

// WordPlus Mesh (1.0.3, as rtc-client 1.0.10 and 1.0.11's room/meshEncoders.ts): which encoder each published video
// runs on, hardware or software, and how each layer encodes, told to the node for its live view (2026-10-18; and
// 2026-10-19, after a call where many people sent few frames a second), so a call's people show how each one
// publishes. Only the device knows it, in its senders' stats:
// `encoderImplementation` ("SimulcastEncoderAdapter (VideoToolbox, VideoToolbox, VideoToolbox)", one encoder a layer
// from the smallest up) and `powerEfficientEncoder`, each layer's frames, height and what holds it back, and its
// totals of encode time, key frames made and key frames asked for, from which a reading takes what changed since the
// last. Read every `reportEvery` while connected, sent when it changed and again after a reconnect, in a signal
// request with no message of LiveKit's and the JSON in `field`: a node before 1.0.35 handles it as nothing. Only to
// a mesh's servers.

enum MeshEncoders {
    static let reportEvery: TimeInterval = 10

    /// The signal request field the report goes in (WordPlus Mesh's `MeshEncodersFieldNumber`).
    static let field: UInt64 = 1001

    /// One stats object as libwebrtc gives it: its id, its type and its members, and when it was read (µs).
    struct Stat {
        let id: String
        let type: String
        let values: [String: Any]
        var timestampUs: Double = 0
    }

    struct Layer: Codable, Equatable {
        var rid: String
        var encoder: String?
        var hw: Bool?
        /// while it encodes: its frames a second, its height, and what holds it back ("cpu", "bandwidth", "other")
        var fps: Int?
        var height: Int?
        var limit: String?
        /// since the last reading: ms of encoding a frame, key frames made, key frames asked for (PLI, FIR)
        var encodeMs: Double?
        var keyFrames: Int?
        var plis: Int?
        /// since the last reading (1.0.7, rtc-client 1.0.16): frames it encoded and sent (sent fewer than encoded: its
        /// sending queue held them), and the bitrate its encoder aims at now, kbit/s
        var encoded: Int?
        var sent: Int?
        var target: Int?
    }

    /// How long a codec's encoder was held back since the last reading, ms, by what (1.0.7).
    struct Limits: Codable, Equatable {
        var cpu: Int?
        var bandwidth: Int?
        var other: Int?
    }

    struct CodecReport: Codable, Equatable {
        var codec: String
        var encoder: String
        var layers: [Layer]
        /// the frames a second its source gives the encoder (media-source stats)
        var captured: Int?
        /// what its sending did since the last reading, its layers together (1.0.7, `sendingOf`): the frames its
        /// source gave, the ms its encoder was held back by each cause, the ms a packet waited in its sending queue on
        /// average, the share of its packets sent again (%), and its oversized frames
        var frames: Int?
        var limitMs: Limits?
        var queueMs: Double?
        var resent: Double?
        var huge: Int?
    }

    /// The mode a capture was opened at: its size and the frames a second asked of the device.
    struct Mode: Codable, Equatable {
        var width: Int
        var height: Int
        var fps: Int?
    }

    struct TrackReport: Codable, Equatable {
        var sid: String
        var codecs: [CodecReport]
        var mode: Mode?
        /// since the last reading (1.0.7): the times its source stopped giving frames by itself (the camera, its driver
        /// or the system held it, not the person: `SourceWatch`), and the ms it gave none
        var stalls: Int?
        var stallMs: Int?
    }

    /// A layer's running totals in its stats, from which `sinceLast` takes what changed between two readings; and
    /// (1.0.7) framesSent, packetsSent, totalPacketSendDelay, retransmittedPacketsSent, hugeFramesSent,
    /// qualityLimitationDurations, and its media source's frames.
    struct Totals: Equatable {
        var encodeTime: Double?
        var frames: Double?
        var keyFrames: Double?
        var plis: Double?
        var sent: Double?
        var packets: Double?
        var sendDelay: Double?
        var resent: Double?
        var huge: Double?
        var limits: [String: Double]?
        var sourceFrames: Double?
    }

    /// What a layer sent between two readings (1.0.7), which its codec's sending sums (`sendingOf`).
    struct Sent: Equatable {
        var encoded: Int?
        var sent: Int?
        var packets: Double?
        /// s its packets waited in the sending queue, summed
        var sendDelay: Double?
        var resent: Double?
        var huge: Double?
        /// s its encoder was held back, by what ("cpu", "bandwidth", "other")
        var limits: [String: Double]?
        /// frames its source gave (the media source's own total)
        var sourceFrames: Double?
    }

    struct Outbound {
        var rid: String
        var height: Int
        var encoder: String?
        var powerEfficient: Bool?
        var active: Bool
        var fps: Double?
        var limit: String?
        var captured: Double?
        var mime: String
        var encodeMs: Double?
        var keyFrames: Int?
        var plis: Int?
        /// the bitrate its encoder aims at now, bit/s, and what it sent since the last reading (1.0.7)
        var target: Double?
        var sent = Sent()
    }

    private static let software = try! NSRegularExpression(pattern: "^(libvpx|openh264|libaom|svt|ffmpeg|libx26|dav1d|rav1e|fake)",
                                                           options: [.caseInsensitive])

    /// Whether an encoder named so runs in hardware: nil when the device named none.
    static func encoderHardware(_ name: String?, powerEfficient: Bool?) -> Bool? {
        guard let name, !name.isEmpty else { return powerEfficient }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return software.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) == nil
    }

    /// The encoders a SimulcastEncoderAdapter names, in its streams' order; the name itself for any other.
    static func adapterEncoders(_ name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let prefix = "SimulcastEncoderAdapter"
        guard trimmed.hasPrefix(prefix) else { return [trimmed] }
        let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("("), rest.hasSuffix(")") else { return [trimmed] }
        return rest.dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// What a layer did between two readings of its totals: the time it took to encode a frame, in ms, and the key
    /// frames it made and was asked for. Nothing from a first reading, nor from a total the device doesn't keep or
    /// that went back (a sender started over).
    static func sinceLast(_ prev: Totals?, _ now: Totals) -> (encodeMs: Double?, keyFrames: Int?, plis: Int?) {
        guard let prev else { return (nil, nil, nil) }
        func delta(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b, b >= a else { return nil }
            return b - a
        }
        var encodeMs: Double?
        if let frames = delta(prev.frames, now.frames), frames > 0, let time = delta(prev.encodeTime, now.encodeTime) {
            encodeMs = ((time / frames) * 10000).rounded() / 10
        }
        return (encodeMs, delta(prev.keyFrames, now.keyFrames).map { Int($0) }, delta(prev.plis, now.plis).map { Int($0) })
    }

    /// What a layer sent between two readings of its totals (1.0.7, rtc-client 1.0.16's `sinceLast`): the frames it
    /// encoded and sent, its packets, how long they waited to go, those sent again, its oversized frames, how long its
    /// encoder was held back and by what, and the frames its source gave. Nothing from a first reading, nor from a total
    /// the device doesn't keep or that went back.
    static func sentSince(_ prev: Totals?, _ now: Totals) -> Sent {
        guard let prev else { return Sent() }
        func delta(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b, b >= a else { return nil }
            return b - a
        }
        var out = Sent(encoded: delta(prev.frames, now.frames).map { Int($0) },
                       sent: delta(prev.sent, now.sent).map { Int($0) },
                       packets: delta(prev.packets, now.packets),
                       sendDelay: delta(prev.sendDelay, now.sendDelay),
                       resent: delta(prev.resent, now.resent),
                       huge: delta(prev.huge, now.huge),
                       sourceFrames: delta(prev.sourceFrames, now.sourceFrames))
        if let before = prev.limits, let after = now.limits {
            var limits: [String: Double] = [:]
            for key in ["cpu", "bandwidth", "other"] {
                if let d = delta(before[key], after[key]), d > 0 { limits[key] = d }
            }
            out.limits = limits
        }
        return out
    }

    /// What a codec's sending did since the last reading, its layers summed (1.0.7, rtc-client 1.0.16's `sendingOf`):
    /// the frames its source gave, the ms its encoder was held back by each cause (the layer held back most: they share
    /// one encoder's adapter), the ms a packet waited to go on average, the share sent again (%) and its oversized
    /// frames. Each only where there is something.
    static func sendingOf(_ sent: [Sent]) -> (frames: Int?, limitMs: Limits?, queueMs: Double?, resent: Double?, huge: Int?) {
        var packets = 0.0, delay = 0.0, resent = 0.0, huge = 0.0
        var frames: Double?
        var held: [String: Int] = [:]
        for s in sent {
            packets += s.packets ?? 0
            delay += s.sendDelay ?? 0
            resent += s.resent ?? 0
            huge += s.huge ?? 0
            if let f = s.sourceFrames { frames = max(frames ?? 0, f) }
            for key in ["cpu", "bandwidth", "other"] {
                let ms = Int(((s.limits?[key] ?? 0) * 1000).rounded())
                if ms > (held[key] ?? 0) { held[key] = ms }
            }
        }
        let limits = held.isEmpty ? nil : Limits(cpu: held["cpu"], bandwidth: held["bandwidth"], other: held["other"])
        var queueMs: Double?
        var resentShare: Double?
        if packets > 0 {
            queueMs = (delay * 10000 / packets).rounded() / 10
            if resent > 0 { resentShare = (resent * 1000 / packets).rounded() / 10 }
        }
        return (frames.map { Int($0) }, limits, queueMs, resentShare, huge > 0 ? Int(huge) : nil)
    }

    private static let ridOrder = ["q", "h", "f"]

    /// Whether a layer encodes now: the adapter names the encoders of those alone, and a layer the server paused
    /// (dynacast) can still read active for a moment after it stopped, so its frames decide where it says them.
    private static func sending(_ o: Outbound) -> Bool {
        o.active && (o.fps == nil || o.fps! > 0)
    }

    /// One sender's layers, each with its own encoder where the adapter's list matches the layers that encode, or the
    /// one encoder every one of them runs on; a device that names none still gets its layers' frames and size told,
    /// its encoder "".
    static func layers(of outbound: [Outbound]) -> (encoder: String, layers: [Layer])? {
        guard !outbound.isEmpty else { return nil }
        let named = outbound.first { $0.encoder?.isEmpty == false }
        func order(_ o: Outbound) -> Int {
            ridOrder.firstIndex(of: o.rid) ?? ridOrder.count + o.height
        }
        let sorted = outbound.enumerated().sorted { a, b in
            let (x, y) = (order(a.element), order(b.element))
            return x != y ? x < y : (a.element.height != b.element.height ? a.element.height < b.element.height : a.offset < b.offset)
        }.map(\.element)
        let list = named?.encoder.map(adapterEncoders) ?? []
        let activeIndices = sorted.indices.filter { sending(sorted[$0]) }
        let one = !list.isEmpty && Set(list).count == 1

        let layers = sorted.indices.map { i -> Layer in
            let o = sorted[i]
            var encoder: String?
            if one {
                encoder = list[0]
            } else if !list.isEmpty, list.count == activeIndices.count, let at = activeIndices.firstIndex(of: i) {
                encoder = list[at]
            } else if !list.isEmpty, list.count == sorted.count {
                encoder = list[i]
            }
            var layer = Layer(rid: o.rid)
            if let encoder {
                layer.encoder = String(encoder.prefix(80))
                layer.hw = encoderHardware(encoder, powerEfficient: list.count == 1 ? o.powerEfficient : nil)
            }
            // what it encodes now, what holds it back, and how it encodes since the last reading
            if sending(o), let fps = o.fps {
                layer.fps = Int(fps.rounded())
                if o.height > 0 { layer.height = o.height }
                if let limit = o.limit, limit != "none" { layer.limit = limit }
                layer.encodeMs = o.encodeMs
                layer.keyFrames = o.keyFrames
                layer.plis = o.plis
                // 1.0.7: frames encoded and sent since the last reading (fewer sent: its queue held them) and what it
                // aims at
                layer.encoded = o.sent.encoded
                layer.sent = o.sent.sent
                if let target = o.target, target > 0 { layer.target = Int((target / 1000).rounded()) }
            }
            return layer
        }
        return (String((named?.encoder ?? "").prefix(200)), layers)
    }

    /// A sender's video layers from its stats, with what changed since `before` (its layers' totals at the last
    /// reading, by rid), and its totals now.
    static func outbound(of stats: [Stat], before: [String: Totals]?) -> (outbound: [Outbound], totals: [String: Totals]) {
        let byId = Dictionary(stats.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func str(_ v: Any?) -> String? { v as? String }
        var out: [Outbound] = []
        var totals: [String: Totals] = [:]
        for s in stats where s.type == "outbound-rtp" && str(s.values["kind"]) == "video" {
            let codec = str(s.values["codecId"]).flatMap { byId[$0] }
            let source = str(s.values["mediaSourceId"]).flatMap { byId[$0] }
            let rid = str(s.values["rid"]) ?? ""
            let pli = num(s.values["pliCount"])
            let fir = num(s.values["firCount"])
            let now = Totals(encodeTime: num(s.values["totalEncodeTime"]),
                             frames: num(s.values["framesEncoded"]),
                             keyFrames: num(s.values["keyFramesEncoded"]),
                             plis: pli != nil || fir != nil ? (pli ?? 0) + (fir ?? 0) : nil,
                             sent: num(s.values["framesSent"]),
                             packets: num(s.values["packetsSent"]),
                             sendDelay: num(s.values["totalPacketSendDelay"]),
                             resent: num(s.values["retransmittedPacketsSent"]),
                             huge: num(s.values["hugeFramesSent"]),
                             limits: (s.values["qualityLimitationDurations"] as? [String: Any])?.compactMapValues { num($0) },
                             sourceFrames: num(source?.values["frames"]))
            totals[rid] = now
            let since = sinceLast(before?[rid], now)
            out.append(Outbound(rid: rid,
                                height: Int(num(s.values["frameHeight"]) ?? 0),
                                encoder: str(s.values["encoderImplementation"]),
                                powerEfficient: (s.values["powerEfficientEncoder"] as? NSNumber)?.boolValue,
                                active: (s.values["active"] as? NSNumber)?.boolValue ?? true,
                                fps: num(s.values["framesPerSecond"]),
                                limit: str(s.values["qualityLimitationReason"]),
                                captured: num(source?.values["framesPerSecond"]),
                                mime: str(codec?.values["mimeType"]) ?? "",
                                encodeMs: since.encodeMs,
                                keyFrames: since.keyFrames,
                                plis: since.plis,
                                target: num(s.values["targetBitrate"]),
                                sent: sentSince(before?[rid], now)))
        }
        return (out, totals)
    }

    /// One sender's report, its codec's name given (a backup's) or read from its stats; nil when it has no video layers.
    static func codecReport(_ outbound: [Outbound], named: String?) -> CodecReport? {
        guard let read = layers(of: outbound) else { return nil }
        let mime = outbound.first { !$0.mime.isEmpty }?.mime ?? ""
        let codec = (named ?? (mime.lowercased().hasPrefix("video/") ? String(mime.dropFirst(6)) : mime)).lowercased()
        let captured = outbound.compactMap(\.captured).max()
        // 1.0.7: what its sending did since the last reading
        let sending = sendingOf(outbound.map(\.sent))
        return CodecReport(codec: codec, encoder: read.encoder, layers: read.layers, captured: captured.map { Int($0.rounded()) },
                           frames: sending.frames, limitMs: sending.limitMs, queueMs: sending.queueMs, resent: sending.resent,
                           huge: sending.huge)
    }

    /// The report as a node reads it: `{"tracks":[...]}`, its keys sorted so two readings that say the same compare
    /// equal.
    static func json(_ tracks: [TrackReport]) -> Data? {
        struct Body: Encodable { let tracks: [TrackReport] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Body(tracks: tracks))
    }

    static func stats(_ report: LKRTCStatisticsReport) -> [Stat] {
        report.statistics.values.map { Stat(id: $0.id, type: $0.type, values: $0.values, timestampUs: $0.timestamp_us) }
    }
}

/// WordPlus Mesh (1.0.7, as rtc-client 1.0.16's `sourceStalls`): whether a published video's source stopped giving
/// frames by itself, the camera, its driver or the system holding it (another app took the camera, a call or the
/// system's pressure interrupted it), never the person (a muted track isn't watched). The browser says so in its
/// track's mute events; a native capturer says nothing alike, so it is read from the connection's shared readings: the
/// source's own frame count (media-source `frames`) not moving between two readings while the track is on. A reading
/// every 10 s: a stop shorter than that between two readings goes unseen, one longer is counted from the reading before.
struct SourceWatch: Equatable {
    var frames: Double?
    var at: Double?
    var stalls = 0
    var ms = 0.0
    var stalledAt: Double?

    /// A reading of the source's frame count at `at` (ms); `on`: the track is on (unmuted), else the watch starts over.
    mutating func read(frames now: Double?, at: Double, on: Bool) {
        guard on, let now else {
            self = SourceWatch(stalls: stalls, ms: ms)
            return
        }
        defer { frames = now; self.at = at }
        guard let before = frames, let then = self.at, at > then else { return }
        if now <= before {
            if stalledAt == nil {
                stalls += 1
                stalledAt = then
            }
        } else if let since = stalledAt {
            ms += max(0, then - since)
            stalledAt = nil
        }
    }

    /// Whether it stopped since it was last asked, or is stopped now.
    var stalled: Bool { stalls > 0 || stalledAt != nil }

    /// The stops since it was last asked and their ms, one still going on counted to `now`, the rest in the next.
    mutating func take(now: Double) -> (stalls: Int, ms: Int) {
        let total = ms + (stalledAt.map { max(0, now - $0) } ?? 0)
        let out = (stalls, Int(total.rounded()))
        stalls = 0
        ms = 0
        if stalledAt != nil { stalledAt = now }
        return out
    }
}

/// WordPlus Mesh (1.0.3; 1.0.7 as rtc-client 1.0.16's `meshReportTick`): the reports to a mesh node while connected.
/// Every `MeshEncoders.reportEvery` a look, and the reports go when the node's pace says (`setPace`: 10 s in a small
/// call, less often in a big room, never at 0), or at once when what happened can't wait: a thermal state serious or
/// worse, a device plugged in or out (MeshHealthWatch), its own camera stopping by itself (SourceWatch), a freeze in
/// what it plays; and 3 s after a video is published. One message a reading (`sendMeshReports`): the encoders when they
/// changed, what it receives, the device and the app; all of it again after a reconnect, to a node that may hold no
/// session of it yet. Every reading is its part of the connections' shared readings (MeshStatsHub).
final class MeshEncoderReporter: @unchecked Sendable, Loggable {
    private struct State {
        var task: Task<Void, Never>?
        var sent: Data?
        /// each sender's totals at the last reading, by its id (`RTCSender.senderId`, 1.0.7: upstream 2.18 wraps the
        /// WebRTC objects in values)
        var totals: [String: [String: MeshEncoders.Totals]] = [:]
        /// each received track's totals at the last reading (MeshReceivers, 1.0.6), by its media track's id, one a
        /// receiver
        var receivers: [String: MeshReceivers.Totals] = [:]
        /// 1.0.8: the turn-on (`RemoteTrackPublication.meshOnAt`) whose gap a reading told, by the same id
        var resumes: [String: Double] = [:]
        /// 1.0.7: the node's pace (ms), when the reports last went, the freezes in what it plays at the last look, and
        /// each published video's source by its media track's id
        var every = Int(MeshEncoders.reportEvery * 1000)
        var reportedAt: Date?
        var freezesSeen: Double?
        var sources: [String: SourceWatch] = [:]
    }

    private let _state = StateSync(State())

    /// The connections' readings, shared by these reports and the hardware-drop watch (1.0.7).
    let stats = MeshStatsHub()

    /// The device and the app, from the system's own notifications (1.0.7).
    let health = MeshHealthWatch()

    /// Connected to a mesh, or connected again after a reconnect: everything is told again at the next reading, the
    /// device too, to a node that may know nothing of it.
    func start(_ room: Room) {
        health.start()
        health.tellMachineAgain()
        _state.mutate {
            $0.sent = nil
            $0.reportedAt = nil
            guard $0.task == nil else { return }
            $0.task = Task { [weak self, weak room] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(MeshEncoders.reportEvery * 1_000_000_000))
                    guard let self, let room, !Task.isCancelled else { return }
                    await self.tick(room)
                }
            }
        }
    }

    func stop() {
        health.stop()
        stats.clear()
        _state.mutate {
            $0.task?.cancel()
            $0 = State()
        }
    }

    /// The node's pace for the reports, ms (0: none), as it says in its signal response (`Mesh.reportsField`).
    func setPace(_ every: Int) {
        _state.mutate { $0.every = max(0, every) }
    }

    /// A new video's encoders are told within a few seconds, once they run, not at the next reading.
    func reportSoon(_ room: Room) {
        guard _state.read({ $0.task != nil && $0.every > 0 }) else { return }
        Task { [weak self, weak room] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, let room else { return }
            await self.report(room)
        }
    }

    private func onMesh(_ room: Room) -> Bool {
        room._state.read { $0.connectionState == .connected && $0.isReconnectingWithMode == nil && $0.providedUrl?.isMeshServer == true }
    }

    /// A look every `MeshEncoders.reportEvery`: the sources and the freezes from the connections' shared readings, and
    /// the reports when they are due or something can't wait. A look between two reports costs a reading of each
    /// connection, which the reports then share; the next report says everything since the last that went.
    func tick(_ room: Room, now: Date = Date()) async {
        let (every, reportedAt) = _state.read { ($0.every, $0.reportedAt) }
        guard every > 0, onMesh(room) else { return }
        let urgent = await troubled(room)
        let due = reportedAt.map { now.timeIntervalSince($0) * 1000 >= Double(every) - MeshEncoders.reportEvery * 500 } ?? true
        guard due || urgent else { return }
        _state.mutate { $0.reportedAt = now }
        await report(room)
    }

    /// Whether something since the last report can't wait for the next one; also keeps each published video's source
    /// watch and the freezes seen up to date, from the connections' shared readings.
    func troubled(_ room: Room) async -> Bool {
        var urgent = health.troubled()
        let transport = room._state.read { $0.transport }
        // the publisher is read only for a video it publishes (a stream's viewer publishes none)
        if let publisher = transport?.publisher, !room.localParticipant.localVideoTracks.isEmpty {
            let published = await stats.read(publisher)
            let at = Date().timeIntervalSince1970 * 1000
            for publication in room.localParticipant.localVideoTracks {
                guard let track = publication.track as? LocalVideoTrack else { continue }
                let id = track.mediaTrack.trackId
                let source = published.first { $0.type == "media-source" && $0.values["trackIdentifier"] as? String == id }
                let frames = (source?.values["frames"] as? NSNumber)?.doubleValue
                let stalled = _state.mutate { state -> Bool in
                    var watch = state.sources[id] ?? SourceWatch()
                    watch.read(frames: frames, at: at, on: !track.isMuted)
                    state.sources[id] = watch
                    return watch.stalled
                }
                urgent = urgent || stalled
            }
        }
        // a freeze in what it plays
        if let subscriber = transport?.subscriber {
            let freezes = await stats.read(subscriber).filter { $0.type == "inbound-rtp" }
                .compactMap { ($0.values["freezeCount"] as? NSNumber)?.doubleValue }.reduce(0, +)
            let before = _state.mutate { state -> Double? in
                defer { state.freezesSeen = freezes }
                return state.freezesSeen
            }
            urgent = urgent || before.map { freezes > $0 } ?? false
        }
        return urgent
    }

    /// The reading's reports in one message: the encoders when they changed, what it receives, the device and the app.
    func report(_ room: Room) async {
        guard onMesh(room) else { return }
        let encoders = await readEncoders(room)
        let receivers = await readReceivers(room)
        // the device and the app, with each connection's path from its shared reading
        let transport = room._state.read { $0.transport }
        var paths: [String: [MeshEncoders.Stat]] = [:]
        if let publisher = transport?.publisher { paths["pub"] = await stats.read(publisher) }
        if let subscriber = transport?.dedicatedSubscriber { paths["sub"] = await stats.read(subscriber) }
        let device = health.reading(paths: paths)

        let sent = _state.read { $0.sent }
        let changed = encoders.json != sent && (!encoders.tracks.isEmpty || sent != nil) ? encoders.json : nil
        let went = await room.signalClient.sendMeshReports(encoders: changed,
                                                           receivers: receivers.isEmpty ? nil : MeshReceivers.json(receivers),
                                                           health: device.isEmpty ? nil : MeshHealth.json(device))
        if went, let changed {
            _state.mutate { $0.sent = changed }
        }
    }

    /// The published videos' encoders, each sender's its part of the publisher's shared reading (or its own reading
    /// where the part can't be told), with its source's stops since the last report.
    private func readEncoders(_ room: Room) async -> (tracks: [MeshEncoders.TrackReport], json: Data?) {
        var tracks: [MeshEncoders.TrackReport] = []
        for publication in room.localParticipant.localVideoTracks {
            guard let track = publication.track as? LocalVideoTrack else { continue }
            let (transport, sender, simulcast) = track._state.read { ($0.transport, $0.rtpSender, $0.rtpSenderForCodec) }
            guard let transport else { continue }

            var senders: [(RTCSender, String?)] = []
            if let sender { senders.append((sender, nil)) }
            senders += simulcast.map { ($0.value, $0.key.name) }

            var codecs: [MeshEncoders.CodecReport] = []
            for (sender, named) in senders {
                var entries = await stats.forSender(sender, on: transport)
                if entries == nil { entries = await MeshEncoders.stats(transport.statistics(for: sender)) }
                let key = sender.senderId
                let read = MeshEncoders.outbound(of: entries ?? [], before: _state.read { $0.totals[key] })
                _state.mutate { $0.totals[key] = read.totals }
                if let report = MeshEncoders.codecReport(read.outbound, named: named) {
                    codecs.append(report)
                }
            }
            guard !codecs.isEmpty else { continue }
            var report = MeshEncoders.TrackReport(sid: publication.sid.stringValue, codecs: codecs, mode: Self.mode(of: track))
            // its source stopping by itself since the last report (SourceWatch)
            let id = track.mediaTrack.trackId
            let stalled = _state.mutate { $0.sources[id]?.take(now: Date().timeIntervalSince1970 * 1000) }
            if let stalled, stalled.stalls > 0 || stalled.ms > 0 {
                report.stalls = stalled.stalls
                report.stallMs = stalled.ms
            }
            tracks.append(report)
        }
        return (tracks, MeshEncoders.json(tracks))
    }

    /// WordPlus Mesh (1.0.6, rtc-client 1.0.15's `reportMeshReceivers`): what each received track is like where it
    /// plays (MeshReceivers), at the reports' readings: every one that received anything since the last, numbers only;
    /// each its part of the subscriber's shared reading (1.0.7).
    private func readReceivers(_ room: Room) async -> [MeshReceivers.Track] {
        var tracks: [MeshReceivers.Track] = []
        var seen = Set<String>()
        for participant in room.remoteParticipants.values {
            for (sid, publication) in participant.trackPublications {
                guard let track = publication.track else { continue }
                let (transport, receiver) = track._state.read { ($0.transport, $0.rtpReceiver) }
                guard let transport, let receiver else { continue }
                let key = track.mediaTrack.trackId
                var inbound = await stats.forReceiver(trackId: key, on: transport).flatMap { MeshReceivers.inbound($0) }
                if inbound == nil { inbound = await MeshReceivers.inbound(transport.statistics(for: receiver)) }
                guard let inbound else { continue }
                seen.insert(key)
                let now = MeshReceivers.totals(inbound.values, at: inbound.at, readAt: Date().timeIntervalSince1970 * 1000)
                let video = track.kind == .video
                // 1.0.8: when this device last turned it back on itself, unless a reading told that gap already
                let onAt = (publication as? RemoteTrackPublication)?.meshOnAt
                let told = _state.read { $0.resumes[key] }
                let read = MeshReceivers.reading(sid: sid.stringValue, video: video, prev: _state.read { $0.receivers[key] }, now: now,
                                                 height: video ? MeshReceivers.height(inbound.values) : nil,
                                                 resumedAt: onAt != told ? onAt : nil)
                _state.mutate {
                    $0.receivers[key] = now
                    if read?.hiddenGaps != nil, let onAt { $0.resumes[key] = onAt }
                }
                if let read { tracks.append(read) }
            }
        }
        // receivers gone since are forgotten, not kept for the room's lifetime
        _state.mutate {
            $0.receivers = $0.receivers.filter { seen.contains($0.key) }
            $0.resumes = $0.resumes.filter { seen.contains($0.key) }
        }
        return tracks
    }

    /// The mode the capture was opened at: the size it captures and the frames a second asked of it, where its
    /// capturer says (a camera, or frames an app hands it).
    static func mode(of track: LocalVideoTrack) -> MeshEncoders.Mode? {
        guard let dimensions = track.capturer.dimensions else { return nil }
        var fps: Int?
        if let camera = track.capturer as? CameraCapturer {
            fps = camera.options.fps
        } else if let buffer = track.capturer as? BufferCapturer {
            fps = buffer.options.fps
        }
        return MeshEncoders.Mode(width: Int(dimensions.width), height: Int(dimensions.height), fps: fps)
    }
}
