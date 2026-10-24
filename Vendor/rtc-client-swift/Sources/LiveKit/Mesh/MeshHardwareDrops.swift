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

// WordPlus Mesh (1.0.6, as @wordplus/realtime-client's calls/encoder-watch.ts in a browser): a camera's hardware encoder
// that drops frames, found while it sends, so this device's next camera goes out in software. A Windows PC's AMD encoder
// sent its camera at 3-6 frames a second of the 15 it was given (2026-10-21), and the mesh's lab gets the same of a
// Mac's VideoToolbox under heavy grain: libwebrtc takes whole frames off the camera when an encoder it doesn't trust
// overshoots, every layer at once, and names nothing that held it back. It is a device's, not a maker's. The calls that
// pick a camera's codec skip one this device remembers (`MeshHardwareDrops.codecs()`); the camera sending now isn't
// changed.

/// The codecs whose hardware encoder this device saw take a camera's frames off, remembered for a month: a driver or
/// system update may mend it.
public enum MeshHardwareDrops {
    static let defaultsKey = "wordplus-rtc.hardware-drops"
    static let rememberFor: TimeInterval = 30 * 24 * 3600

    /// Posted on the main queue when the watch finds a camera's hardware dropping frames; `userInfo["codec"]` names it.
    public static let didFind = Notification.Name("WordPlusMeshHardwareDrops")

    /// The codecs ("h264", "h265") this device saw its hardware encoder drop a camera's frames of in the last month.
    public static func codecs(now: Date = Date(), defaults: UserDefaults = .standard) -> [String] {
        let seen = defaults.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        return seen.filter { codec, at in
            codec != "vp8" && now.timeIntervalSince1970 - at >= 0 && now.timeIntervalSince1970 - at < rememberFor
        }.keys.sorted()
    }

    /// Remembers that this device's hardware encoder dropped a camera's frames in codec; VP8 never runs in hardware here.
    public static func remember(_ codec: String, now: Date = Date(), defaults: UserDefaults = .standard) {
        let codec = codec.lowercased()
        guard codec != "vp8", !codec.isEmpty else { return }
        var seen = defaults.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        seen[codec] = now.timeIntervalSince1970
        defaults.set(seen, forKey: defaultsKey)
    }

    /// Forgets every codec, for a test or a settings screen's reset.
    public static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// The rule, as encoder-watch.ts has it: over the last `readings` readings (30 s), each of them a hardware encoder's
/// (`hardwareReading`): the camera goes out in H.264 or H.265 from a layer sent in hardware, its source gives at least
/// `minCaptured` frames a second, the device names nothing that limits a layer, the hardware takes at most `maxEncodeMs`
/// a frame (not a slow device), and a hardware layer sends at least `minSent` of a target of `minTarget` or more (an
/// encoder cut off by a path gone down sends nothing and reports no target); and the layer that keeps the most has
/// encoded `share` or less of the frames its source gave in all. A software encoder short of bits drops its own layer's
/// frames alone, and a dim room's camera gives fewer frames, which every layer sends.
enum HardwareDropRule {
    static let readEvery: TimeInterval = 5
    static let readings = 6
    // the readings of a camera's first 10 s, left out: its encoder starting sends a frame or two of them
    static let warmup = 2
    static let share = 0.7
    static let minCaptured = 10.0
    static let maxEncodeMs = 25.0
    static let minTarget = 100_000.0
    static let minSent = 0.25

    /// One layer between two readings.
    struct Layer: Equatable {
        var active: Bool
        var fps: Double
        var hardware: Bool
        var limit: String
        var encodeMs: Double?
        var target: Double?
        var sentBps: Double
    }

    /// A camera's sender between two readings: its codec ("h264"), its source's frames a second, and its layers.
    struct Reading: Equatable {
        var codec: String?
        var captured: Double
        var layers: [Layer]
    }

    /// A layer's counts at a reading, from which the next takes what changed.
    struct Counts: Equatable {
        var frames: Double
        var encodeTime: Double
        var bytes: Double
        var at: Double // ms
    }

    /// A reading of a hardware encoder that nothing the device names holds back: the frames a second of the layer that
    /// keeps the most, and its source's; nil for any other.
    static func hardwareReading(_ r: Reading) -> (best: Double, captured: Double)? {
        guard r.codec == "h264" || r.codec == "h265", r.captured >= minCaptured else { return nil }
        let sent = r.layers.filter(\.active)
        guard sent.contains(where: \.hardware) else { return nil }
        guard sent.contains(where: { $0.hardware && ($0.target ?? 0) >= minTarget && $0.sentBps >= ($0.target ?? 0) * minSent }) else {
            return nil
        }
        if sent.contains(where: { ($0.limit != "none" && !$0.limit.isEmpty) || ($0.hardware && ($0.encodeMs ?? 0) > maxEncodeMs) }) {
            return nil
        }
        return (sent.map(\.fps).max() ?? 0, r.captured)
    }

    /// Whether readings, the last `readings` of them, are a hardware encoder taking the whole camera's frames off.
    static func dropsFrames(_ list: [Reading]) -> Bool {
        guard list.count >= readings else { return false }
        let read = list.suffix(readings).map(hardwareReading)
        guard read.allSatisfy({ $0 != nil }) else { return false }
        let kept = read.reduce(0) { $0 + $1!.best }, given = read.reduce(0) { $0 + $1!.captured }
        return kept <= given * share
    }

    /// A camera sender's reading from its stats against the counts of the one before (nil the first time). rids: its
    /// encodings', lowest first, which a SimulcastEncoderAdapter names its encoders in; maxFps: the most frames a second
    /// they send (0: none said), over which the source's frames aren't the encoder's to send.
    static func read(_ stats: [MeshEncoders.Stat], at: Double, before: [String: Counts]?, rids: [String],
                     maxFps: Double = 0) -> (reading: Reading?, counts: [String: Counts])
    {
        let byId = Dictionary(stats.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func str(_ v: Any?) -> String? { v as? String }
        var counts: [String: Counts] = [:]
        var layers: [Layer] = []
        var codec: String?
        var captured = 0.0
        for s in stats where s.type == "outbound-rtp" && str(s.values["kind"]) == "video" {
            let rid = str(s.values["rid"]) ?? ""
            let now = Counts(frames: num(s.values["framesEncoded"]) ?? 0, encodeTime: num(s.values["totalEncodeTime"]) ?? 0,
                             bytes: num(s.values["bytesSent"]) ?? 0, at: at)
            counts[rid] = now
            if let mime = str(s.values["codecId"]).flatMap({ byId[$0] }).flatMap({ str($0.values["mimeType"]) })?.lowercased(),
               mime.hasPrefix("video/")
            {
                codec = String(mime.dropFirst(6))
            }
            captured = max(captured, str(s.values["mediaSourceId"]).flatMap { byId[$0] }.flatMap { num($0.values["framesPerSecond"]) } ?? 0)
            guard let was = before?[rid], at > was.at else { continue }
            let encoded = max(0, now.frames - was.frames)
            let implementation = str(s.values["encoderImplementation"]) ?? ""
            let names = MeshEncoders.adapterEncoders(implementation)
            let name = names.count > 1 ? (rids.firstIndex(of: rid).flatMap { $0 < names.count ? names[$0] : nil } ?? "") : implementation
            let target = num(s.values["targetBitrate"])
            layers.append(Layer(active: (s.values["active"] as? NSNumber)?.boolValue ?? true,
                                fps: encoded * 1000 / (at - was.at),
                                hardware: MeshEncoders.encoderHardware(name, powerEfficient: names.count > 1 ? nil :
                                    (s.values["powerEfficientEncoder"] as? NSNumber)?.boolValue) ?? false,
                                limit: str(s.values["qualityLimitationReason"]) ?? "",
                                encodeMs: encoded > 0 ? (now.encodeTime - was.encodeTime) * 1000 / encoded : nil,
                                target: target.flatMap { $0 > 0 ? $0 : nil },
                                sentBps: max(0, now.bytes - was.bytes) * 8 * 1000 / (at - was.at)))
        }
        if maxFps > 0 { captured = min(captured, maxFps) }
        return (before != nil && !layers.isEmpty ? Reading(codec: codec, captured: captured, layers: layers) : nil, counts)
    }
}

/// Watches the room's published camera (its primary codec's sender, not a backup's) while connected, on any server: a
/// reading every `readEvery`, and once its hardware is seen dropping frames, remembers the codec and tells
/// (`MeshHardwareDrops.didFind`). A new sender, a camera muted or gone, or a path that went down starts the readings
/// over; a sender found dropping isn't read again.
final class MeshHardwareDropWatch: @unchecked Sendable, Loggable {
    private struct State {
        var task: Task<Void, Never>?
        /// the camera's sender, by its id (`RTCSender.senderId`, 1.0.7)
        var watched: String?
        var counts: [String: HardwareDropRule.Counts]?
        var warmup = HardwareDropRule.warmup
        var last: [HardwareDropRule.Reading] = []
        var found: Set<String> = []
    }

    private let _state = StateSync(State())

    func start(_ room: Room) {
        _state.mutate {
            guard $0.task == nil else { return }
            $0.task = Task { [weak self, weak room] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(HardwareDropRule.readEvery * 1_000_000_000))
                    guard let self, let room, !Task.isCancelled else { return }
                    await self.read(room)
                }
            }
        }
    }

    func stop() {
        _state.mutate {
            $0.task?.cancel()
            $0 = State()
        }
    }

    private func over(_ watched: String?) {
        _state.mutate {
            $0.watched = watched
            $0.counts = nil
            $0.warmup = HardwareDropRule.warmup
            $0.last = []
        }
    }

    func read(_ room: Room) async {
        let camera = room.localParticipant.localVideoTracks.compactMap { $0.track as? LocalVideoTrack }.first { $0.source == .camera }
        let (transport, sender) = camera?._state.read { ($0.transport, $0.rtpSender) } ?? (nil, nil)
        guard let camera, let transport, let sender, !camera.isMuted else {
            return over(nil)
        }
        // 1.0.7: upstream 2.18's WebRTC objects are read on its RTC executor
        let mediaTrack = camera.mediaTrack
        guard await RTC.run({ mediaTrack.raw.readyState == .live }) else {
            return over(nil)
        }
        let key = sender.senderId
        if _state.read({ $0.found.contains(key) }) { return }
        if _state.read({ $0.watched }) != key { over(key) }
        // a reading across a path gone down reads the frames the path took, not the encoder's
        guard await transport.isConnected else { return over(key) }

        // 1.0.7: its part of the publisher's shared reading (MeshStatsHub), with the encoders' reports; its own reading
        // where the part can't be told
        var stats = await room._meshEncoders.stats.forSender(sender, on: transport)
        var at = stats?.first { $0.type == "outbound-rtp" }.map { $0.timestampUs / 1000 }
        if stats == nil || at == nil {
            let report = await transport.statistics(for: sender)
            stats = MeshEncoders.stats(report)
            at = report.timestamp_us / 1000
        }
        let (rids, maxFps): ([String], Double) = await RTC.run {
            let encodings = sender.raw.parameters.encodings
            return (encodings.map { $0.rid ?? "" },
                    encodings.filter(\.isActive).compactMap { $0.maxFramerate?.doubleValue }.max() ?? 0)
        }
        let read = HardwareDropRule.read(stats ?? [], at: at ?? 0,
                                         before: _state.read { $0.watched == key ? $0.counts : nil }, rids: rids, maxFps: maxFps)
        let (drops, codec): (Bool, String?) = _state.mutate {
            guard $0.watched == key else { return (false, nil) }
            $0.counts = read.counts
            guard let reading = read.reading else { return (false, nil) }
            if $0.warmup > 0 {
                $0.warmup -= 1
                return (false, nil)
            }
            $0.last.append(reading)
            if $0.last.count > HardwareDropRule.readings { $0.last.removeFirst() }
            guard HardwareDropRule.dropsFrames($0.last), let codec = reading.codec else { return (false, nil) }
            $0.found.insert(key)
            return (true, codec)
        }
        guard drops, let codec else { return }
        MeshHardwareDrops.remember(codec)
        log("hardware \(codec) encoder takes the camera's frames off: the next camera goes out in software", .warning)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: MeshHardwareDrops.didFind, object: nil, userInfo: ["codec": codec])
        }
    }
}
