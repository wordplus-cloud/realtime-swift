/*
 * Copyright 2026 LiveKit
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

@objcMembers
public final class AudioPublishOptions: NSObject, TrackPublishOptions, Sendable {
    public let name: String?

    /// preferred encoding parameters
    public let encoding: AudioEncoding?

    public let dtx: Bool

    public let red: Bool

    public let streamName: String?

    public let preConnect: Bool

    /// WordPlus Mesh (1.0.15, rtc-client 1.0.27's `resend`): the server may ask this track again for what its upload
    /// lost, in RED too. The offers sent list `nack` for its Opus (`Transport.listAudioNack`), which a mesh node
    /// answers whatever its own rule for RED; another server ignores the line. Off by default: a microphone in RED
    /// isn't asked again, as what was sent again on a narrow upload once took the camera's room. For a product whose
    /// engine makes that room.
    public let resend: Bool

    public init(name: String? = nil,
                encoding: AudioEncoding? = nil,
                dtx: Bool = true,
                red: Bool = true,
                streamName: String? = nil,
                preConnect: Bool = false,
                resend: Bool = false)
    {
        self.name = name
        self.encoding = encoding
        self.dtx = dtx
        self.red = red
        self.streamName = streamName
        self.preConnect = preConnect
        self.resend = resend
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return name == other.name &&
            encoding == other.encoding &&
            dtx == other.dtx &&
            red == other.red &&
            streamName == other.streamName &&
            preConnect == other.preConnect &&
            resend == other.resend
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(encoding)
        hasher.combine(dtx)
        hasher.combine(red)
        hasher.combine(streamName)
        hasher.combine(preConnect)
        hasher.combine(resend)
        return hasher.finalize()
    }
}

// Internal
extension AudioPublishOptions {
    func toFeatures() -> Set<Livekit_AudioTrackFeature> {
        Set([
            !dtx ? .tfNoDtx : nil,
            preConnect ? .tfPreconnectBuffer : nil,
        ].compactMap(\.self))
    }
}

extension AudioPublishOptions {
    func withPreconnect(_ enabled: Bool) -> AudioPublishOptions {
        AudioPublishOptions(
            name: name,
            encoding: encoding,
            dtx: dtx,
            red: red,
            streamName: streamName,
            preConnect: enabled,
            resend: resend,
        )
    }
}
