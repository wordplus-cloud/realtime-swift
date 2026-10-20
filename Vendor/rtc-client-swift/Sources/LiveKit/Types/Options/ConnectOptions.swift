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

/// Options used when establishing a connection.
@objcMembers
public final class ConnectOptions: NSObject, Sendable {
    /// Automatically subscribe to ``RemoteParticipant``'s tracks.
    /// Defaults to true.
    public let autoSubscribe: Bool

    /// The number of attempts to reconnect when the network disconnects.
    public let reconnectAttempts: Int

    /// The minimum delay value for reconnection attempts.
    /// Default is 0.3 seconds (TimeInterval.defaultReconnectDelay).
    ///
    /// This value serves as the starting point for the easeOutCirc reconnection curve.
    /// See `reconnectMaxDelay` for more details on how the reconnection delay is calculated.
    public let reconnectAttemptDelay: TimeInterval

    /// The maximum delay between reconnect attempts.
    /// Default is 7 seconds (TimeInterval.defaultReconnectMaxDelay).
    ///
    /// The reconnection delay uses an "easeOutCirc" curve between reconnectAttemptDelay and reconnectMaxDelay:
    /// - For all attempts except the last, the delay follows this curve
    /// - The curve grows rapidly at first and then more gradually approaches the maximum
    /// - The last attempt always uses exactly reconnectMaxDelay
    ///
    /// Example for 10 reconnection attempts with baseDelay=0.3s and maxDelay=7s:
    /// - Attempt 0: ~0.85s (already 12% of the way to max)
    /// - Attempt 1: ~2.2s (30% of the way to max)
    /// - Attempt 2: ~3.4s (45% of the way to max)
    /// - Attempt 5: ~5.9s (82% of the way to max)
    /// - Attempt 9: 7.0s (exactly maxDelay)
    ///
    /// This approach provides larger delays early in the reconnection sequence to reduce
    /// unnecessary network traffic when connections are likely to fail.
    public let reconnectMaxDelay: TimeInterval

    /// The timeout interval for the initial websocket connection.
    public let socketConnectTimeoutInterval: TimeInterval

    public let primaryTransportConnectTimeout: TimeInterval

    public let publisherTransportConnectTimeout: TimeInterval

    /// Custom ice servers
    public let iceServers: [IceServer]

    public let iceTransportPolicy: IceTransportPolicy

    /// Allows DSCP codes to be set on outgoing packets when network priority is used.
    /// Defaults to false.
    public let isDscpEnabled: Bool

    /// Enable microphone concurrently while connecting.
    public let enableMicrophone: Bool

    /// LiveKit server protocol version to use. Generally, it's not recommended to change this.
    public let protocolVersion: ProtocolVersion

    /// Client-to-client protocol version advertised to other participants.
    ///
    /// Defaults to ``ClientProtocol/v1``, which enables RPC v2 (data-stream-based payloads
    /// with no 15 KB size limit). Generally, it's not recommended to change this.
    public let clientProtocol: ClientProtocol

    /// WordPlus Mesh: how long a join on a mesh keeps trying, walking busy nodes and waiting on a held slot, before it
    /// reports its last error. A product with a waiting screen passes minutes, since a full mesh adds a server in a
    /// few. Defaults to 30 seconds.
    public let meshJoinBudget: TimeInterval

    /// WordPlus Mesh: the video codecs this device decodes in hardware (`h264`, `h265`, `vp8`, `vp9`, `av1`), named on
    /// a join to a mesh (`mesh_hwdec`), so the node gives it a track in one of them before any other the track has.
    /// Empty says nothing, and the node keeps the track's own order.
    public let meshHardwareDecoders: [String]

    /// WordPlus Mesh (1.0.3): the video codecs this device encodes in hardware, named on a join to a mesh
    /// (`mesh_hwenc`), as `meshHardwareDecoders` those it decodes: what a codec policy could have it send. Empty says
    /// nothing.
    public let meshHardwareEncoders: [String]

    /// WordPlus Mesh (1.0.3): the product placing the call, named on each join to a mesh (`rtc_app`) for its live
    /// view. A room's, as each room is joined with its own options.
    public let meshApp: MeshApp?

    /// WordPlus Mesh: called each time a join on a mesh starts to wait, with until when and why: `busy`, `slot` or
    /// `full` while the mesh holds a place for it, `unreachable` while no server of the list answers.
    @nonobjc public let onMeshWait: (@Sendable (MeshWait) -> Void)?

    override public init() {
        autoSubscribe = true
        reconnectAttempts = 10
        reconnectAttemptDelay = .defaultReconnectDelay
        reconnectMaxDelay = .defaultReconnectMaxDelay
        socketConnectTimeoutInterval = .defaultSocketConnect
        primaryTransportConnectTimeout = .defaultTransportState
        publisherTransportConnectTimeout = .defaultTransportState
        iceServers = []
        iceTransportPolicy = .all
        isDscpEnabled = false
        enableMicrophone = false
        protocolVersion = .v16
        clientProtocol = .v1
        meshJoinBudget = Mesh.joinBudget
        meshHardwareDecoders = []
        meshHardwareEncoders = []
        meshApp = nil
        onMeshWait = nil
    }

    public convenience init(autoSubscribe: Bool = true,
                            reconnectAttempts: Int = 10,
                            reconnectAttemptDelay: TimeInterval = .defaultReconnectDelay,
                            reconnectMaxDelay: TimeInterval = .defaultReconnectMaxDelay,
                            socketConnectTimeoutInterval: TimeInterval = .defaultSocketConnect,
                            primaryTransportConnectTimeout: TimeInterval = .defaultTransportState,
                            publisherTransportConnectTimeout: TimeInterval = .defaultTransportState,
                            iceServers: [IceServer] = [],
                            iceTransportPolicy: IceTransportPolicy = .all,
                            isDscpEnabled: Bool = false,
                            enableMicrophone: Bool = false,
                            protocolVersion: ProtocolVersion = .v16,
                            clientProtocol: ClientProtocol = .v1)
    {
        self.init(autoSubscribe: autoSubscribe,
                  reconnectAttempts: reconnectAttempts,
                  reconnectAttemptDelay: reconnectAttemptDelay,
                  reconnectMaxDelay: reconnectMaxDelay,
                  socketConnectTimeoutInterval: socketConnectTimeoutInterval,
                  primaryTransportConnectTimeout: primaryTransportConnectTimeout,
                  publisherTransportConnectTimeout: publisherTransportConnectTimeout,
                  iceServers: iceServers,
                  iceTransportPolicy: iceTransportPolicy,
                  isDscpEnabled: isDscpEnabled,
                  enableMicrophone: enableMicrophone,
                  protocolVersion: protocolVersion,
                  clientProtocol: clientProtocol,
                  meshJoinBudget: Mesh.joinBudget,
                  meshHardwareDecoders: [],
                  onMeshWait: nil)
    }

    /// WordPlus Mesh: the same with the mesh's own options, which a join on a mesh's servers acts on.
    @nonobjc public init(autoSubscribe: Bool = true,
                         reconnectAttempts: Int = 10,
                         reconnectAttemptDelay: TimeInterval = .defaultReconnectDelay,
                         reconnectMaxDelay: TimeInterval = .defaultReconnectMaxDelay,
                         socketConnectTimeoutInterval: TimeInterval = .defaultSocketConnect,
                         primaryTransportConnectTimeout: TimeInterval = .defaultTransportState,
                         publisherTransportConnectTimeout: TimeInterval = .defaultTransportState,
                         iceServers: [IceServer] = [],
                         iceTransportPolicy: IceTransportPolicy = .all,
                         isDscpEnabled: Bool = false,
                         enableMicrophone: Bool = false,
                         protocolVersion: ProtocolVersion = .v16,
                         clientProtocol: ClientProtocol = .v1,
                         meshJoinBudget: TimeInterval,
                         meshHardwareDecoders: [String],
                         onMeshWait: (@Sendable (MeshWait) -> Void)?,
                         meshHardwareEncoders: [String] = [],
                         meshApp: MeshApp? = nil)
    {
        self.meshJoinBudget = meshJoinBudget
        self.meshHardwareDecoders = meshHardwareDecoders
        self.meshHardwareEncoders = meshHardwareEncoders
        self.meshApp = meshApp
        self.onMeshWait = onMeshWait
        self.autoSubscribe = autoSubscribe
        self.reconnectAttempts = reconnectAttempts
        self.reconnectAttemptDelay = reconnectAttemptDelay
        self.reconnectMaxDelay = max(reconnectMaxDelay, reconnectAttemptDelay)
        self.socketConnectTimeoutInterval = socketConnectTimeoutInterval
        self.primaryTransportConnectTimeout = primaryTransportConnectTimeout
        self.publisherTransportConnectTimeout = publisherTransportConnectTimeout
        self.iceServers = iceServers
        self.iceTransportPolicy = iceTransportPolicy
        self.isDscpEnabled = isDscpEnabled
        self.enableMicrophone = enableMicrophone
        self.protocolVersion = protocolVersion
        self.clientProtocol = clientProtocol
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return autoSubscribe == other.autoSubscribe &&
            reconnectAttempts == other.reconnectAttempts &&
            reconnectAttemptDelay == other.reconnectAttemptDelay &&
            reconnectMaxDelay == other.reconnectMaxDelay &&
            socketConnectTimeoutInterval == other.socketConnectTimeoutInterval &&
            primaryTransportConnectTimeout == other.primaryTransportConnectTimeout &&
            publisherTransportConnectTimeout == other.publisherTransportConnectTimeout &&
            iceServers == other.iceServers &&
            iceTransportPolicy == other.iceTransportPolicy &&
            isDscpEnabled == other.isDscpEnabled &&
            enableMicrophone == other.enableMicrophone &&
            protocolVersion == other.protocolVersion &&
            clientProtocol == other.clientProtocol &&
            meshJoinBudget == other.meshJoinBudget &&
            meshHardwareDecoders == other.meshHardwareDecoders &&
            meshHardwareEncoders == other.meshHardwareEncoders &&
            meshApp == other.meshApp &&
            (onMeshWait == nil) == (other.onMeshWait == nil)
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(autoSubscribe)
        hasher.combine(reconnectAttempts)
        hasher.combine(reconnectAttemptDelay)
        hasher.combine(reconnectMaxDelay)
        hasher.combine(socketConnectTimeoutInterval)
        hasher.combine(primaryTransportConnectTimeout)
        hasher.combine(publisherTransportConnectTimeout)
        hasher.combine(iceServers)
        hasher.combine(iceTransportPolicy)
        hasher.combine(isDscpEnabled)
        hasher.combine(enableMicrophone)
        hasher.combine(protocolVersion)
        return hasher.finalize()
    }
}
