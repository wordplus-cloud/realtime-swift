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

// WordPlus Mesh (1.0.7, as rtc-client 1.0.16's room/meshStats.ts): one reading of each connection's stats, shared, so
// telling the node more of what a client sends, plays and runs on adds no load to the device.
//
// Until 1.0.7 the mesh's reports read each sender and each receiver on its own (`statistics(for:)`), and libwebrtc
// gathers the whole connection's stats to answer each one: in a call of 8, 14 receivers and the camera's senders every
// 10 s, and the hardware-drop watch's camera every 5 s, ~100 gatherings a minute that grow with every person in the call.
// Here a connection is read at most once every `readEvery`, and the encoders, the receivers, the hardware-drop watch and
// the health report each take their part of that one reading: a sender's outbound streams by its transceiver's mid (or
// its track's media source where none names a mid), a receiver's inbound stream by its track, with every entry they
// refer to (codec, transport, candidate pair, media source, the far end's reports). Rates stay right: each computes them
// between two readings by the stats' own timestamps.

/// A stats entry's members are what libwebrtc made of one reading (numbers, strings, their maps), never changed after.
extension MeshEncoders.Stat: @unchecked Sendable {}

enum MeshStats {
    /// A shared reading is reused this long: just under 2 s, so each connection is read about once a round.
    static let readEvery: TimeInterval = 1.9

    /// The fields of a stats entry that name another one.
    static let references = ["codecId", "transportId", "remoteId", "mediaSourceId", "selectedCandidatePairId",
                             "localCandidateId", "remoteCandidateId"]

    /// Those entries with every one they refer to, and what those refer to.
    static func withReferences(_ full: [String: MeshEncoders.Stat], _ picked: [MeshEncoders.Stat]) -> [MeshEncoders.Stat] {
        var out: [MeshEncoders.Stat] = []
        var seen = Set<String>()
        var queue = picked
        while !queue.isEmpty {
            let s = queue.removeFirst()
            guard seen.insert(s.id).inserted else { continue }
            out.append(s)
            for key in references {
                if let ref = s.values[key] as? String, !seen.contains(ref), let next = full[ref] {
                    queue.append(next)
                }
            }
        }
        return out
    }

    /// A sender's part of its connection's reading: its outbound streams, by its transceiver's mid, or where libwebrtc
    /// names none on them, by its track through their media source; nil when they can't be told (the same track in
    /// two senders and no mid, or none yet).
    static func forSender(_ stats: [MeshEncoders.Stat], mid: String?, trackId: String?, sendersOfTrack: Int) -> [MeshEncoders.Stat]? {
        let full = Dictionary(stats.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let outbound = stats.filter { $0.type == "outbound-rtp" }
        var picked: [MeshEncoders.Stat]
        if outbound.contains(where: { $0.values["mid"] is String }) {
            guard let mid, !mid.isEmpty else { return nil }
            picked = outbound.filter { $0.values["mid"] as? String == mid }
        } else {
            guard let trackId, sendersOfTrack == 1 else { return nil }
            let sources = Set(stats.filter { $0.type == "media-source" && $0.values["trackIdentifier"] as? String == trackId }.map(\.id))
            picked = outbound.filter { ($0.values["mediaSourceId"] as? String).map(sources.contains) ?? false }
        }
        return picked.isEmpty ? nil : withReferences(full, picked)
    }

    /// A receiver's part: its inbound stream, by its track's id.
    static func forReceiver(_ stats: [MeshEncoders.Stat], trackId: String) -> [MeshEncoders.Stat]? {
        let full = Dictionary(stats.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let picked = stats.filter { $0.type == "inbound-rtp" && $0.values["trackIdentifier"] as? String == trackId }
        return picked.isEmpty ? nil : withReferences(full, picked)
    }
}

/// The room's connections' readings, shared while on a mesh (`MeshStats`): each connection read at most once every
/// `MeshStats.readEvery` however many ask, a reading under way joined by whoever asks meanwhile.
final class MeshStatsHub: @unchecked Sendable {
    private struct Reading {
        let at: Date
        let task: Task<[MeshEncoders.Stat], Never>
    }

    private struct State {
        var readings: [ObjectIdentifier: Reading] = [:]
        /// gatherings made, for tests and the lab
        var reads = 0
    }

    private let _state = StateSync(State())

    var reads: Int { _state.read { $0.reads } }

    /// The connection's stats as entries, read at most once every `MeshStats.readEvery`.
    func read(_ transport: Transport, now: Date = Date()) async -> [MeshEncoders.Stat] {
        await read(key: ObjectIdentifier(transport), now: now) { await MeshEncoders.stats(transport.statistics()) }
    }

    /// A reading of the connection `key` names: the last one while younger than `MeshStats.readEvery` (or under way),
    /// else `gather`'s.
    func read(key: ObjectIdentifier, now: Date = Date(), gather: @escaping @Sendable () async -> [MeshEncoders.Stat]) async -> [MeshEncoders.Stat] {
        let task: Task<[MeshEncoders.Stat], Never> = _state.mutate {
            if let last = $0.readings[key], now.timeIntervalSince(last.at) < MeshStats.readEvery {
                return last.task
            }
            // a connection gone (a full reconnect makes new ones) is forgotten with its reading
            $0.readings = $0.readings.filter { now.timeIntervalSince($0.value.at) < MeshStats.readEvery }
            let task = Task { await gather() }
            $0.readings[key] = Reading(at: now, task: task)
            $0.reads += 1
            return task
        }
        return await task.value
    }

    /// A sender's part of its connection's shared reading (`MeshStats.forSender`); nil where it can't be told.
    func forSender(_ sender: RTCSender, on transport: Transport) async -> [MeshEncoders.Stat]? {
        let (mid, trackId, sendersOfTrack): (String?, String?, Int) = await RTC.run {
            let trackId = sender.raw.track?.trackId
            return (transport.mid(of: sender), trackId, trackId.map { transport.senderCount(ofTrack: $0) } ?? 0)
        }
        return await MeshStats.forSender(read(transport), mid: mid, trackId: trackId, sendersOfTrack: sendersOfTrack)
    }

    /// A receiver's part, by its media track's id.
    func forReceiver(trackId: String, on transport: Transport) async -> [MeshEncoders.Stat]? {
        await MeshStats.forReceiver(read(transport), trackId: trackId)
    }

    func clear() {
        _state.mutate { $0 = State() }
    }
}
