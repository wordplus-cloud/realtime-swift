import Foundation
import LiveKit
#if canImport(UIKit)
import UIKit
#endif

/// What a group call sends, by the media server's settings for its clients (the room client's `MeshSettings`, from the
/// mesh's settings document): each key as the server gives it, and where it says nothing the schema's default, which
/// is what the browsers send. Before the join, the settings this device last had from the same server, else the
/// defaults.
enum GroupShapes {
    /// The settings a connect to `server` starts with: the ones its last call ended with, at most 7 days old.
    static func cached(_ server: String) -> MeshSettings {
        URL(string: server).flatMap { MeshSettings.cached(for: $0) } ?? .none
    }

    /// The microphone at `mic.kbps`, with `mic.dtx` and `mic.red`. Never RED into an encrypted room, which the web's
    /// room client leaves RED out of by itself: the media server can't unwrap a payload it can't read, and the room
    /// client sends RED wherever it is asked to.
    ///
    /// And with `resend`, the room client's word that its node may ask the microphone again for what its upload lost, in
    /// RED too, where a node otherwise leaves a lost packet to RED's spare copy, which restores one lost alone and no run
    /// of them. What is sent again goes up the same upload: a call's microphone says so because the call watches it
    /// (`GroupCall.reviewMicCeiling`) and makes that room, as the browsers' engine does (realtime-client's `micPublish`).
    static func microphone(encrypted: Bool, settings: MeshSettings) -> AudioPublishOptions {
        AudioPublishOptions(
            encoding: AudioEncoding(maxBitrate: (settings.int("mic.kbps") ?? 64) * 1000),
            dtx: settings.bool("mic.dtx") ?? true,
            red: (settings.bool("mic.red") ?? true) && !encrypted,
            resend: true
        )
    }

    /// The microphone's processing: `mic.echoCancellation`, `mic.autoGainControl`, `mic.noiseSuppression`.
    static func microphoneCapture(settings: MeshSettings) -> AudioCaptureOptions {
        AudioCaptureOptions(
            echoCancellation: settings.bool("mic.echoCancellation") ?? AudioCaptureOptions.defaultEchoCancellation,
            autoGainControl: settings.bool("mic.autoGainControl") ?? AudioCaptureOptions.defaultAutoGainControl,
            noiseSuppression: settings.bool("mic.noiseSuppression") ?? AudioCaptureOptions.defaultNoiseSuppression
        )
    }

    /// The camera opened at `camera.captureHeight` lines, 16:9, and `camera.captureFps`, on the side asked.
    static func cameraCapture(settings: MeshSettings, front: Bool = true) -> CameraCaptureOptions {
        let lines = settings.int("camera.captureHeight") ?? 1080
        let dimensions: Dimensions = lines < 450 ? .h360_169 : lines < 630 ? .h540_169 : lines < 900 ? .h720_169 : .h1080_169
        return CameraCaptureOptions(position: front ? .front : .back, dimensions: dimensions, fps: settings.int("camera.captureFps") ?? 30)
    }

    /// The camera by the lines it is captured at, the shorter side, so a phone held upright counts the same. From 720
    /// lines the top layer at `camera.topKbps.<codec>.<1080|720>` and `camera.fps`, and under it the layers of
    /// `camera.ladder.1080` or `camera.ladder.720` (each at its own frame rate, where the library's own lower layers
    /// run at 20, which a tile shows as stutter). Below 720 lines, the library's own layers. `camera.degradation` says
    /// what the encoder gives up first.
    static func camera(codec: VideoCodec, backup: VideoCodec?, dimensions: Dimensions, settings: MeshSettings) -> VideoPublishOptions {
        let lines = Int(min(dimensions.width, dimensions.height))
        let degradation = degradation(settings.word("camera.degradation"))
        // an SVC codec's layers as `camera.svcMode` says them; any other codec goes out in simulcast
        let svc = svcMode(codec, settings: settings)

        guard lines >= 720 else {
            return VideoPublishOptions(preferredCodec: codec, preferredBackupCodec: backup, degradationPreference: degradation, scalabilityMode: svc)
        }

        let full = lines >= 1080
        let size = full ? "1080" : "720"
        let ownKbps = codec == .vp8 ? (full ? 4000 : 2000) : (full ? 3500 : 1800)
        let top = VideoEncoding(maxBitrate: (settings.int("camera.topKbps.\(codec.name).\(size)") ?? ownKbps) * 1000,
                                maxFps: settings.int("camera.fps") ?? 30)
        let ladder = settings.layers(full ? "camera.ladder.1080" : "camera.ladder.720") ?? []
        // only the layers under the top one: a ladder's layer as tall as the camera would stand in for it
        let layers = ladder.filter { $0.height < lines }.map { layer($0) }

        return VideoPublishOptions(encoding: top, simulcastLayers: layers, preferredCodec: codec, preferredBackupCodec: backup,
                                   degradationPreference: degradation, scalabilityMode: svc)
    }

    /// The scalability mode of a camera in an SVC codec (VP9, AV1), `camera.svcMode`; nil for any other codec.
    static func svcMode(_ codec: VideoCodec, settings: MeshSettings) -> ScalabilityMode? {
        guard codec == .vp9 || codec == .av1 else { return nil }
        return ScalabilityMode.fromString(settings.word("camera.svcMode")) ?? .L3T3_KEY
    }

    /// The tallest camera this device sends in the codec it encodes it in, `camera.maxHeight.hw` or
    /// `camera.maxHeight.sw`, as a cap for the room client (`Room.setProductCameraCaps`): none when the capture is no
    /// taller.
    static func cameraCap(hardware: Bool, lines: Int, settings: MeshSettings) -> MeshCaps {
        let most = settings.int(hardware ? "camera.maxHeight.hw" : "camera.maxHeight.sw") ?? lines
        return MeshCaps(height: most < lines ? most : 0)
    }

    /// That cap with the ceiling a step of the picture puts on the camera for the sound's sake (`CallPictureSteps`):
    /// the stricter of each, and the cap alone at step 0.
    static func cameraCap(_ cap: MeshCaps, step: Int) -> MeshCaps {
        guard let caps = CallPictureSteps.caps(step) else { return cap }
        return cap.combined(with: MeshCaps(height: caps.height, fps: caps.fps, kbps: caps.kbps))
    }

    /// The camera's codec list for this device: the first of `camera.codecRules` whose given fields all match it (no
    /// browser, Apple's graphics, an iPhone, iPad or Mac), else `camera.codecs`.
    static func cameraCodecs(settings: MeshSettings) -> [String]? {
        #if os(iOS)
        let os = "ios"
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone"
        #else
        let os = "mac"
        let device = "desktop"
        #endif
        for rule in settings.codecRules("camera.codecRules") ?? [] {
            if let ruleOS = rule.os, ruleOS != os { continue }
            if rule.browser != nil { continue }
            if let gpu = rule.gpu, gpu != "apple" { continue }
            if let kind = rule.device, kind != device { continue }
            return rule.camera
        }
        return settings.names("camera.codecs")
    }

    /// The connect's options the settings own: the signal connection's and the media connection's timeouts, the
    /// reconnect waits, relay-only ICE and how long the join may wait for a place on the mesh.
    static func connectOptions(settings: MeshSettings, iceServers: [IceServer], caps: CallCodecCaps, onMeshWait: (@Sendable (MeshWait) -> Void)? = nil) -> ConnectOptions {
        ConnectOptions(
            socketConnectTimeoutInterval: Double(settings.int("connect.signalTimeoutMs") ?? 20000) / 1000,
            primaryTransportConnectTimeout: Double(settings.int("connect.pcTimeoutMs") ?? 20000) / 1000,
            publisherTransportConnectTimeout: Double(settings.int("connect.pcTimeoutMs") ?? 20000) / 1000,
            iceServers: iceServers,
            iceTransportPolicy: settings.word("ice.transportPolicy") == "relay" ? .relay : .all,
            meshJoinBudget: Double(settings.int("connect.joinBudgetMs") ?? 300_000) / 1000,
            meshHardwareDecoders: CallCodecs.hardwareDecoders(caps),
            onMeshWait: onMeshWait,
            meshHardwareEncoders: CallCodecs.hardwareEncoders(caps),
            meshApp: MeshApp(name: "realtime-swift", version: RealtimeCalls.version),
            meshReconnectDelays: settings.reconnectDelays
        )
    }

    /// The camera's publish settings in one string (`camera.*` of the publish class), to tell whether a running camera
    /// went out under the ones in force now.
    static func cameraPrint(_ settings: MeshSettings) -> String {
        settings.values.filter { $0.key.hasPrefix("camera.") && MeshSettings.keyClass($0.key) == .publish }
            .map { "\($0.key)=\(String(describing: $0.value))" }.sorted().joined(separator: ";")
    }

    /// Whether a change touches what a camera or screen takes at its next publish: what a revision with `applyNow`
    /// re-publishes for.
    static func touchesPublish(_ keys: Set<String>) -> Bool {
        keys.contains { MeshSettings.keyClass($0) == .publish }
    }

    /// The degradation preference a word names, the library's own for `default`.
    static func degradation(_ word: String?) -> DegradationPreference {
        switch word {
        case "balanced": return .balanced
        case "maintain-framerate": return .maintainFramerate
        case "maintain-resolution": return .maintainResolution
        default: return .auto
        }
    }

    private static func layer(_ layer: MeshLayer) -> VideoParameters {
        let width = 16 * layer.height / 9
        return VideoParameters(dimensions: Dimensions(width: Int32(width + width % 2), height: Int32(layer.height)),
                               encoding: VideoEncoding(maxBitrate: layer.kbps * 1000, maxFps: layer.fps))
    }
}
