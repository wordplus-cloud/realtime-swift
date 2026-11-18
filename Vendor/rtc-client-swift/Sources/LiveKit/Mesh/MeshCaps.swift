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

/// WordPlus Mesh (1.0.10): the live caps over a camera's encodings (`camera.capHeight`, `camera.capFps`,
/// `camera.capKbps`; 0 for none), which the server sets for one person, a room or a kind of device, and which reach a
/// running camera at once, with no republish: no layer taller than the height (scaled down to it, or turned off when a
/// lower layer already comes near it), none faster than the frame rate, none spending more than the bitrate. The room
/// holds them over every camera it publishes, whatever its publish options, its dimensions or dynacast say after.
public struct MeshCaps: Sendable, Hashable {
    public var height: Int
    public var fps: Int
    public var kbps: Int

    public init(height: Int = 0, fps: Int = 0, kbps: Int = 0) {
        self.height = height
        self.fps = fps
        self.kbps = kbps
    }

    public var isEmpty: Bool { height <= 0 && fps <= 0 && kbps <= 0 }

    /// Both caps at once: each the stricter of the two where either sets it (the server's and the product's own,
    /// `Room.setProductCameraCaps`).
    public func combined(with other: MeshCaps) -> MeshCaps {
        func stricter(_ a: Int, _ b: Int) -> Int { a > 0 && b > 0 ? Swift.min(a, b) : Swift.max(a, b, 0) }
        return MeshCaps(height: stricter(height, other.height), fps: stricter(fps, other.fps), kbps: stricter(kbps, other.kbps))
    }

    /// A lower layer at least this share of the height covers the cap: the layer above goes off rather than being
    /// scaled down onto it.
    static let covers = 0.95

    /// Holds encodings computed for a camera of `lines` (its capture's shorter side) to the caps, in place, and answers
    /// the rids it turned off, which dynacast must leave off. A layer scaled down spends its bitrate scaled with it, as
    /// the ladder's own layers do (by the height's ratio to the power 1.5).
    @discardableResult
    func apply(to encodings: [LKRTCRtpEncodingParameters], lines: Int) -> Set<String> {
        guard !isEmpty, !encodings.isEmpty, lines > 0 else { return [] }
        var off: Set<String> = []
        if height > 0 {
            let source = Double(lines)
            let ordered = encodings.sorted { source / ($0.scaleResolutionDownBy?.doubleValue ?? 1) < source / ($1.scaleResolutionDownBy?.doubleValue ?? 1) }
            var kept: [Double] = []
            for encoding in ordered {
                let scale = Swift.max(encoding.scaleResolutionDownBy?.doubleValue ?? 1, 1)
                let layer = source / scale
                guard layer > Double(height) else {
                    kept.append(layer)
                    continue
                }
                if let rid = encoding.rid, kept.contains(where: { $0 >= Double(height) * Self.covers }) {
                    encoding.isActive = false
                    off.insert(rid)
                    continue
                }
                encoding.scaleResolutionDownBy = NSNumber(value: source / Double(height))
                if let bitrate = encoding.maxBitrateBps?.doubleValue {
                    encoding.maxBitrateBps = NSNumber(value: Int(bitrate * pow(Double(height) / layer, 1.5)))
                }
                kept.append(Double(height))
            }
        }
        if fps > 0 {
            for encoding in encodings {
                let now = encoding.maxFramerate?.intValue ?? 0
                encoding.maxFramerate = NSNumber(value: now > 0 ? Swift.min(now, fps) : fps)
            }
        }
        if kbps > 0 {
            for encoding in encodings {
                let now = encoding.maxBitrateBps?.intValue ?? 0
                encoding.maxBitrateBps = NSNumber(value: now > 0 ? Swift.min(now, kbps * 1000) : kbps * 1000)
            }
        }
        return off
    }
}

/// The rids a sender's caps turned off, by the sender's id (libwebrtc's, unique to it): dynacast's
/// `_set(subscribedQualities:)` leaves them off whatever the node asks. An entry goes when its caps are lifted; one a
/// sender left behind is a few bytes.
enum MeshCappedLayers {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [String: Set<String>] = [:]

    static func set(_ rids: Set<String>, for sender: LKRTCRtpSender) {
        let id = sender.senderId
        lock.lock()
        defer { lock.unlock() }
        table[id] = rids.isEmpty ? nil : rids
    }

    static func off(_ sender: LKRTCRtpSender) -> Set<String> {
        let id = sender.senderId
        lock.lock()
        defer { lock.unlock() }
        return table[id] ?? []
    }
}
