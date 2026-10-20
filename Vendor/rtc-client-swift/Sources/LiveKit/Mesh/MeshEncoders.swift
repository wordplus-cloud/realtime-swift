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

    /// One stats object as libwebrtc gives it: its id, its type and its members.
    struct Stat {
        let id: String
        let type: String
        let values: [String: Any]
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
    }

    struct CodecReport: Codable, Equatable {
        var codec: String
        var encoder: String
        var layers: [Layer]
        /// the frames a second its source gives the encoder (media-source stats)
        var captured: Int?
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
    }

    /// A layer's running totals in its stats, from which `sinceLast` takes what changed between two readings.
    struct Totals: Equatable {
        var encodeTime: Double?
        var frames: Double?
        var keyFrames: Double?
        var plis: Double?
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
                             plis: pli != nil || fir != nil ? (pli ?? 0) + (fir ?? 0) : nil)
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
                                plis: since.plis))
        }
        return (out, totals)
    }

    /// One sender's report, its codec's name given (a backup's) or read from its stats; nil when it has no video layers.
    static func codecReport(_ outbound: [Outbound], named: String?) -> CodecReport? {
        guard let read = layers(of: outbound) else { return nil }
        let mime = outbound.first { !$0.mime.isEmpty }?.mime ?? ""
        let codec = (named ?? (mime.lowercased().hasPrefix("video/") ? String(mime.dropFirst(6)) : mime)).lowercased()
        let captured = outbound.compactMap(\.captured).max()
        return CodecReport(codec: codec, encoder: read.encoder, layers: read.layers, captured: captured.map { Int($0.rounded()) })
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
        report.statistics.values.map { Stat(id: $0.id, type: $0.type, values: $0.values) }
    }
}

/// WordPlus Mesh (1.0.3): reads the room's published videos' encoders every `MeshEncoders.reportEvery` while it is
/// connected to a mesh's server, and 3 s after a video is published, and sends the report when it changed; all of it
/// again after a reconnect, to a node that may hold no session of it yet.
final class MeshEncoderReporter: @unchecked Sendable, Loggable {
    private struct State {
        var task: Task<Void, Never>?
        var sent: Data?
        var totals: [ObjectIdentifier: [String: MeshEncoders.Totals]] = [:]
    }

    private let _state = StateSync(State())

    /// Connected to a mesh, or connected again after a reconnect: everything is told again at the next reading.
    func start(_ room: Room) {
        _state.mutate {
            $0.sent = nil
            guard $0.task == nil else { return }
            $0.task = Task { [weak self, weak room] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(MeshEncoders.reportEvery * 1_000_000_000))
                    guard let self, let room, !Task.isCancelled else { return }
                    await self.report(room)
                }
            }
        }
    }

    func stop() {
        _state.mutate {
            $0.task?.cancel()
            $0.task = nil
            $0.sent = nil
            $0.totals = [:]
        }
    }

    /// A new video's encoders are told within a few seconds, once they run, not at the next reading.
    func reportSoon(_ room: Room) {
        guard _state.read({ $0.task != nil }) else { return }
        Task { [weak self, weak room] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, let room else { return }
            await self.report(room)
        }
    }

    func report(_ room: Room) async {
        let (connected, providedUrl) = room._state.read { ($0.connectionState == .connected && $0.isReconnectingWithMode == nil, $0.providedUrl) }
        guard connected, providedUrl?.isMeshServer == true else { return }

        var tracks: [MeshEncoders.TrackReport] = []
        for publication in room.localParticipant.localVideoTracks {
            guard let track = publication.track as? LocalVideoTrack else { continue }
            let (transport, sender, simulcast) = track._state.read { ($0.transport, $0.rtpSender, $0.rtpSenderForCodec) }
            guard let transport else { continue }

            var senders: [(LKRTCRtpSender, String?)] = []
            if let sender { senders.append((sender, nil)) }
            senders += simulcast.map { ($0.value, $0.key.name) }

            var codecs: [MeshEncoders.CodecReport] = []
            for (sender, named) in senders {
                let stats = await MeshEncoders.stats(transport.statistics(for: sender))
                let key = ObjectIdentifier(sender)
                let read = MeshEncoders.outbound(of: stats, before: _state.read { $0.totals[key] })
                _state.mutate { $0.totals[key] = read.totals }
                if let report = MeshEncoders.codecReport(read.outbound, named: named) {
                    codecs.append(report)
                }
            }
            guard !codecs.isEmpty else { continue }
            tracks.append(MeshEncoders.TrackReport(sid: publication.sid.stringValue, codecs: codecs, mode: Self.mode(of: track)))
        }

        guard let json = MeshEncoders.json(tracks) else { return }
        let sent = _state.read { $0.sent }
        if json == sent || (tracks.isEmpty && sent == nil) { return }
        if await room.signalClient.sendMeshEncoders(json) {
            _state.mutate { $0.sent = json }
        }
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
