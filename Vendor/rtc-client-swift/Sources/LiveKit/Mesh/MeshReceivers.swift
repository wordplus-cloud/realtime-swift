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

// WordPlus Mesh (1.0.6, as rtc-client 1.0.15's room/meshReceivers.ts): what each received track is like where it plays,
// told to the node for its live view (2026-10-21: monitoring a call's quality without anyone watching it). The node
// knows what it sends a viewer; only the device knows whether the picture freezes, how many frames it shows and whether
// the sound breaks up, in its receivers' stats: framesDecoded, frameHeight, freezeCount and totalFreezesDuration,
// framesDropped, concealedSamples less silentConcealedSamples over totalSamplesReceived, packetsLost, and
// jitterBufferDelay over jitterBufferEmittedCount. Numbers only.
//
// Read at the encoders' readings (every `MeshEncoders.reportEvery`), each reading what changed since the one before,
// and sent in a signal request with no message of LiveKit's and the JSON in `field`: a node before 1.0.46 handles it as
// nothing. Only to a mesh's servers.

enum MeshReceivers {
    /// The signal request field the report goes in (WordPlus Mesh's `MeshReceiversFieldNumber`).
    static let field: UInt64 = 1002

    /// A received track's running totals in its inbound-rtp stats, from which `reading` takes what changed.
    struct Totals: Equatable {
        var at: Double
        var packets: Double
        var lost: Double
        var frames: Double?
        var freezes: Double?
        var freezeSeconds: Double?
        var dropped: Double?
        var samples: Double?
        var concealed: Double?
        var jitterDelay: Double?
        var jitterEmitted: Double?
        /// 1.0.7 (rtc-client 1.0.16): totalDecodeTime, the gaps between frames shown (their sum and sum of squares, s),
        /// pauses (5 s or more), key frames and retransmissions asked for, samples stretched and squeezed; and two that
        /// aren't totals: the network's jitter now (s) and whether the decoder is the device's (powerEfficientDecoder)
        var decodeTime: Double?
        var gaps: Double?
        var gapsSquared: Double?
        var pauses: Double?
        var pauseSeconds: Double?
        var plis: Double?
        var nacks: Double?
        var stretched: Double?
        var jitter: Double?
        var hwDec: Bool?
        /// 1.0.8 (rtc-client 1.0.17): this device's clock at the reading (ms since 1970), the one it turns tracks off
        /// and on by: the stats' own timestamps run on WebRTC's clock
        var readAt: Double?
    }

    /// 1.0.8: how long after this device turns a video back on its first frame may still come, ending the gap it made
    /// (the node resumes it and its sender sends a key frame), ms. A frame landing after a reading is the next reading's.
    static let resumeMs: Double = 3000

    /// One received track over a reading, as the node reads it (its `MeshPlayed`): a total the device doesn't keep is
    /// left out.
    struct Track: Codable, Equatable {
        var sid: String
        var kind: String
        var fps: Double?
        var height: Int?
        var freezes: Int?
        var freezeMs: Int?
        var dropped: Int?
        var concealed: Double?
        var lost: Double?
        var jbMs: Int?
        /// since the last reading (1.0.7), a video's: ms of decoding a frame and whether its decoder is hardware, how
        /// unevenly its frames were shown (the spread of the gaps between them, ms), pauses of 5 s or more and their ms,
        /// the key frames and retransmissions it asked for; a sound's: the share of what it played stretched or
        /// squeezed to keep in time (%); both: the network's jitter, ms
        var decodeMs: Double?
        var hwDec: Bool?
        var unevenMs: Int?
        var pauses: Int?
        var pauseMs: Int?
        var plis: Int?
        var nacks: Int?
        var stretched: Double?
        var jitterMs: Int?
        /// 1.0.8, a video's: the gaps this device made itself by turning it off (its view hidden or gone) and their ms,
        /// told apart from pauses and freezes and left out of unevenMs
        var hiddenGaps: Int?
        var hiddenGapMs: Int?
    }

    private static func num(_ v: Any?) -> Double? {
        guard let d = (v as? NSNumber)?.doubleValue, d.isFinite else { return nil }
        return d
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    /// A receiver's totals from its inbound-rtp stats' members, read at `at` (ms), and at `readAt` on this device's
    /// clock (1.0.8).
    static func totals(_ values: [String: Any], at: Double, readAt: Double? = nil) -> Totals {
        let concealed = num(values["concealedSamples"])
        return Totals(at: at,
                      packets: num(values["packetsReceived"]) ?? 0,
                      lost: max(0, num(values["packetsLost"]) ?? 0),
                      frames: num(values["framesDecoded"]),
                      freezes: num(values["freezeCount"]),
                      freezeSeconds: num(values["totalFreezesDuration"]),
                      dropped: num(values["framesDropped"]),
                      samples: num(values["totalSamplesReceived"]),
                      // concealment while the other side was silent costs nothing anyone hears
                      concealed: concealed.map { $0 - (num(values["silentConcealedSamples"]) ?? 0) },
                      jitterDelay: num(values["jitterBufferDelay"]),
                      jitterEmitted: num(values["jitterBufferEmittedCount"]),
                      decodeTime: num(values["totalDecodeTime"]),
                      gaps: num(values["totalInterFrameDelay"]),
                      gapsSquared: num(values["totalSquaredInterFrameDelay"]),
                      pauses: num(values["pauseCount"]),
                      pauseSeconds: num(values["totalPausesDuration"]),
                      plis: num(values["pliCount"]),
                      nacks: num(values["nackCount"]),
                      stretched: stretched(values),
                      jitter: num(values["jitter"]),
                      hwDec: (values["powerEfficientDecoder"] as? NSNumber)?.boolValue,
                      readAt: readAt)
    }

    /// Samples inserted to slow the sound down and removed to speed it up, together.
    private static func stretched(_ values: [String: Any]) -> Double? {
        let inserted = num(values["insertedSamplesForDeceleration"])
        let removed = num(values["removedSamplesForAcceleration"])
        guard inserted != nil || removed != nil else { return nil }
        return (inserted ?? 0) + (removed ?? 0)
    }

    /// The height of the picture a receiver decodes now, from its inbound-rtp stats' members.
    static func height(_ values: [String: Any]) -> Int? {
        num(values["frameHeight"]).map { Int($0) }
    }

    /// What a received track did between two readings of its totals; nothing from a first reading, or from totals that
    /// went back (a receiver started over). `resumedAt` (1.0.8) is when this device last turned the video back on after
    /// turning it off itself (`RemoteTrackPublication.meshOnAt`), unless a reading told that gap already.
    static func reading(sid: String, video: Bool, prev: Totals?, now: Totals, height: Int? = nil, resumedAt: Double? = nil) -> Track? {
        guard let prev, now.at > prev.at, now.packets >= prev.packets else { return nil }
        let seconds = (now.at - prev.at) / 1000
        func delta(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b, b >= a else { return nil }
            return b - a
        }
        var out = Track(sid: sid, kind: video ? "video" : "audio")
        let received = now.packets - prev.packets
        let lost = max(0, now.lost - prev.lost)
        if received + lost > 0 {
            out.lost = round1(lost * 100 / (received + lost))
        }
        if let delay = delta(prev.jitterDelay, now.jitterDelay), let emitted = delta(prev.jitterEmitted, now.jitterEmitted), emitted > 0 {
            out.jbMs = Int((delay * 1000 / emitted).rounded())
        }
        if video {
            if let frames = delta(prev.frames, now.frames) {
                out.fps = round1(frames / seconds)
            }
            if let height, height > 0 {
                out.height = height
            }
            var freezes = delta(prev.freezes, now.freezes)
            var frozen = delta(prev.freezeSeconds, now.freezeSeconds)
            let pauses = delta(prev.pauses, now.pauses)
            let paused = delta(prev.pauseSeconds, now.pauseSeconds)
            // 1.0.8 (rtc-client 1.0.17): a gap this device made itself, turning the video off (its view hidden or
            // gone), isn't the call's (2026-10-24: the live view's "paused 1× 16.1 s" and "stutters ±870 ms" after a
            // browser's tab switch). A video turned back on since just before the last reading owns the pauses ending
            // in this one, or the one freeze its gap came out as when it was too short for a pause; they're told apart
            // as hiddenGaps.
            let resumed = resumedAt.map { $0 > (prev.readAt ?? prev.at) - resumeMs } ?? false
            var hidden: (gaps: Double, seconds: Double?)?
            if resumed, let pauses, pauses > 0 {
                hidden = (pauses, paused)
            } else if resumed, freezes == 1 {
                hidden = (1, frozen)
                freezes = 0
                frozen = 0
            }
            if let hidden {
                out.hiddenGaps = Int(hidden.gaps)
                if let seconds = hidden.seconds {
                    out.hiddenGapMs = Int((seconds * 1000).rounded())
                }
            }
            if let freezes {
                out.freezes = Int(freezes)
                if let frozen {
                    out.freezeMs = Int((frozen * 1000).rounded())
                }
            }
            if let dropped = delta(prev.dropped, now.dropped) {
                out.dropped = Int(dropped)
            }
            // 1.0.7: how it decodes, how evenly it shows, what it asked for (each only where there's something to say)
            let frames = delta(prev.frames, now.frames)
            if let frames, frames > 0, let decode = delta(prev.decodeTime, now.decodeTime) {
                out.decodeMs = round1(decode * 1000 / frames)
            }
            out.hwDec = now.hwDec
            var gaps = delta(prev.gaps, now.gaps)
            var squared = delta(prev.gapsSquared, now.gapsSquared)
            var shown = frames
            if resumed {
                // WebRTC adds every gap to both sums, a pause's and a freeze's too, as its very length
                // (VideoQualityObserver2), so one hidden gap comes out exactly; several, or one no total tells, leave
                // the spread unsaid this reading
                if let hidden, hidden.gaps == 1, let seconds = hidden.seconds, let frames, let g = gaps, let s = squared {
                    gaps = g - seconds
                    squared = s - seconds * seconds
                    shown = frames - 1
                } else {
                    gaps = nil
                }
            }
            if let shown, shown > 1, let gaps, let squared {
                let mean = gaps / shown
                out.unevenMs = Int((max(0, squared / shown - mean * mean).squareRoot() * 1000).rounded())
            }
            if hidden == nil, let pauses, pauses > 0 {
                out.pauses = Int(pauses)
                if let paused {
                    out.pauseMs = Int((paused * 1000).rounded())
                }
            }
            if let plis = delta(prev.plis, now.plis), plis > 0 { out.plis = Int(plis) }
            if let nacks = delta(prev.nacks, now.nacks), nacks > 0 { out.nacks = Int(nacks) }
        } else {
            let samples = delta(prev.samples, now.samples)
            if let samples, samples > 0, let concealed = delta(prev.concealed, now.concealed) {
                out.concealed = round1(concealed * 100 / samples)
            }
            if let samples, samples > 0, let stretched = delta(prev.stretched, now.stretched), stretched > 0 {
                out.stretched = round1(stretched * 100 / samples)
            }
        }
        if let jitter = now.jitter, jitter >= 0.001 {
            out.jitterMs = Int((jitter * 1000).rounded())
        }
        return out
    }

    /// The report as a node reads it: `{"tracks":[...]}`.
    static func json(_ tracks: [Track]) -> Data? {
        struct Body: Encodable { let tracks: [Track] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Body(tracks: tracks))
    }

    /// A receiver's inbound-rtp from its own stats report: its members and when it was read, in ms.
    static func inbound(_ report: LKRTCStatisticsReport) -> (values: [String: Any], at: Double)? {
        guard let s = report.statistics.values.first(where: { $0.type == "inbound-rtp" }) else { return nil }
        return (s.values, s.timestamp_us / 1000)
    }

    /// The same from its part of the connection's shared reading (1.0.7, `MeshStats.forReceiver`).
    static func inbound(_ stats: [MeshEncoders.Stat]) -> (values: [String: Any], at: Double)? {
        guard let s = stats.first(where: { $0.type == "inbound-rtp" }) else { return nil }
        return (s.values, s.timestampUs / 1000)
    }
}
