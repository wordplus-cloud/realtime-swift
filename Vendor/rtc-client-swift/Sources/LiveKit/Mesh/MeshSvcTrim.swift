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

/// WordPlus Mesh (1.0.11): a camera sent as one SVC stream (VP9, AV1) sends only the sizes up to the largest its
/// viewers ask for, while the node's settings say so (`camera.svcTrim`; better-messages-server infra/SVC-TRIM.md), as
/// the browser client does (@wordplus/rtc-client 1.0.24): 360p asked of a 720p camera in L3T3_KEY sends L2T3_KEY of half
/// the picture (180p and 360p), 180p sends L1T3 of a quarter. Each size keeps its height, so the node's layers still
/// name it. A size nobody asks for can't flap with the upload's estimate (libwebrtc's SVC allocator turns a size off and
/// on at one threshold, each time on a key frame of every size), and its bits go to the sizes watched. A mode whose
/// trimmed form the SDK can't name (L3T3, L3T3_KEY_SHIFT) goes out whole, and so does a camera whose WebRTC keeps its
/// mode. Turned off, the camera goes out whole again at once.
enum MeshSvcTrim {
    /// The mode and scale a camera's one encoding went out with before any trim: the publish's, under the live caps.
    struct Whole: Equatable {
        var mode: String
        var scale: Double?
    }

    /// The mode and scale to send, from the whole one and the largest quality asked (low 0, medium 1, high 2).
    struct Plan: Equatable {
        var mode: String
        var scale: Double?
        var sizes: Int
    }

    private struct Entry {
        var on = false
        var refused = false
        var whole: Whole?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [String: Entry] = [:]

    private static func with<T>(_ sender: LKRTCRtpSender, _ body: (inout Entry) -> T) -> T {
        let id = sender.senderId
        lock.lock()
        defer { lock.unlock() }
        var entry = table[id] ?? Entry()
        let out = body(&entry)
        table[id] = entry.on || entry.whole != nil || entry.refused ? entry : nil
        return out
    }

    /// Whether the settings trim this camera sender (the room sets it for its cameras alone).
    static func set(on: Bool, for sender: LKRTCRtpSender) {
        with(sender) { $0.on = on }
    }

    /// The live caps computed the camera's encodings again (`recomputeSenderParameters`): the whole one's scale is theirs.
    static func rebase(_ sender: LKRTCRtpSender, scale: NSNumber?) {
        with(sender) { entry in
            if entry.whole != nil { entry.whole?.scale = scale?.doubleValue }
        }
    }

    /// A mode's first `sizes` spatial layers, as the SDK names them; one size predicts across none, so L1T3 has no
    /// suffix. Nil where the SDK has no name for it.
    static func mode(_ whole: String, sizes: Int) -> String? {
        guard let m = ScalabilityMode.fromString(whole) else { return nil }
        if sizes >= m.spatial { return whole }
        let temporal = whole.dropFirst(3).prefix(1)
        let suffix = whole.dropFirst(4)
        let name = sizes == 1 ? "L1T\(temporal)" : "L\(sizes)T\(temporal)\(suffix)"
        return ScalabilityMode.fromString(name) != nil ? name : nil
    }

    /// What a camera sends for the largest quality asked: the sizes up to it, half the picture a size left out.
    static func plan(_ whole: Whole, highest: Int) -> Plan? {
        guard let m = ScalabilityMode.fromString(whole.mode) else { return nil }
        let sizes = Swift.min(m.spatial, Swift.max(1, highest + 1))
        guard sizes < m.spatial, let mode = mode(whole.mode, sizes: sizes) else {
            return Plan(mode: whole.mode, scale: whole.scale, sizes: m.spatial)
        }
        // the trim's own scale, under a live cap's when that is smaller still (the browser client's order)
        let scale = Swift.max(pow(2, Double(m.spatial - sizes)), whole.scale ?? 1)
        return Plan(mode: mode, scale: scale, sizes: sizes)
    }

    /// The mode and scale a sender's one SVC encoding should go out in for the largest quality asked, nil to leave it as
    /// it is: trimmed while on, and whole again once off after a trim.
    static func encoding(for sender: LKRTCRtpSender, current: LKRTCRtpEncodingParameters, highest: Int) -> Plan? {
        with(sender) { entry in
            guard let mode = current.scalabilityMode else { return nil }
            if !entry.on || entry.refused {
                guard let whole = entry.whole else { return nil }
                entry.whole = nil
                return Plan(mode: whole.mode, scale: whole.scale, sizes: ScalabilityMode.fromString(whole.mode)?.spatial ?? 1)
            }
            let whole = entry.whole ?? Whole(mode: mode, scale: current.scaleResolutionDownBy?.doubleValue)
            entry.whole = whole
            return plan(whole, highest: highest)
        }
    }

    /// After the change: a WebRTC that kept another mode than the one set sends this camera whole from then on. False
    /// the first time, for the caller to set it whole; true once it is whole-only already, so nothing tries again.
    static func check(_ sender: LKRTCRtpSender, asked: String) -> Bool {
        let kept = sender.parameters.encodings.first?.scalabilityMode
        guard let kept, kept != asked else { return true }
        return with(sender) { entry in
            if entry.refused { return true }
            entry.refused = true
            return false
        }
    }

    /// The mode a sender's one SVC encoding goes out in now, for the encoder report; nil for simulcast.
    static func sentMode(_ sender: LKRTCRtpSender) -> String? {
        let encodings = sender.parameters.encodings
        guard encodings.count == 1, let mode = encodings[0].scalabilityMode, ScalabilityMode.fromString(mode) != nil else { return nil }
        return mode
    }
}
