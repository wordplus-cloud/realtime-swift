import Foundation
import LiveKit
@_spi(WordPlusModules) import WordPlusRealtime

/// Where a group call is: connecting, connected, reconnecting, or ended.
public enum GroupCallState: String, Sendable {
    case connecting
    case connected
    case reconnecting
    case ended
}

/// Someone else in a group call: the room's name for them (`user_<id>`), their user id, what the app's server said
/// about them, opened, and what they send.
public struct GroupPerson: Equatable, Sendable {
    public let identity: String
    public let user: String?
    public let info: JSONValue
    public let camera: Bool
    public let microphone: Bool
    public let speaking: Bool
    /// Whether they share their screen: `GroupVideoView.show(identity, of: call, source: .screen)` draws it.
    public let screen: Bool
    /// Whether they may send their camera, microphone and screen: the rule of the app, or what its server changed since.
    public let publish: Bool
    /// Whether their camera is changing codec (a browser moving to the codec its computer sends best): it is away for a
    /// moment, not turned off, so a screen shows a placeholder such as "Optimizing video quality..." where the camera
    /// was rather than a camera turned off. From their word until a new camera of theirs arrives (`camera` true again
    /// with a new track), their camera is turned off, or the media server's failsafe has passed (10 seconds unless it
    /// says otherwise). False by default.
    public internal(set) var optimizing: Bool = false
}

/// What this app may do in a group call, as the media server holds it now.
public struct GroupPermissions: Equatable, Sendable {
    /// Send its camera, microphone and screen.
    public let publish: Bool
    /// Get those of the others.
    public let subscribe: Bool
}

/// Which of a person's pictures in a group call: their camera, or the screen they share.
public enum GroupVideoSource: Sendable {
    case camera
    case screen
}

/// A group call made from a call between two people: what ringing someone into it needs.
struct GroupOf {
    let id: String
    let name: String
    let type: CallType
    let pair: Any?
    let member: String?
}

/// Someone rung into a group call: `ringing`, then `accepted`, `declined`, `busy`, `missed` or `cancelled`.
public final class CallInvite: @unchecked Sendable {
    public let id: String
    public let to: String
    public private(set) var state: String

    init(id: String, to: String, state: String) {
        self.id = id
        self.to = to
        self.state = state
    }
}

/**
 A room on the mesh: a group call (`rt.calls.group(name)`), or a call between two people that became one when either
 added someone. End to end encrypted when the app's server gives the room a key (a call's rooms always): every frame is
 encrypted here with the key everyone in the room shares, as the browser's rooms do, so the mesh forwards what it can't
 read. Nothing is sent into a group call until `microphone` or `camera` say so; a call that became one goes on sending
 what it sent. `onState`, `onPeople` (someone arrived, left, or what they send or may send changed), `onPermissions`
 (the app's server changed what this app may do), `onEnded`. On the main queue.
 */
public final class GroupCall: NSObject, @unchecked Sendable {
    public let name: String
    /// The group call's id, for a call between two people that became one; nil for any other room.
    public let group: String?
    /// Whether everyone's media in it is encrypted end to end, with a key only the app's server gives out.
    public let encrypted: Bool
    public private(set) var state: GroupCallState = .connecting
    public private(set) var endReason: String?
    /// Everyone else in the room.
    public private(set) var people: [GroupPerson] = []

    private let room: LiveKit.Room
    private let options: RoomOptions
    private unowned let owner: RealtimeCalls
    private let link: GroupOf?
    private var stateHandlers: [(GroupCallState) -> Void] = []
    private var peopleHandlers: [() -> Void] = []
    private var permissionHandlers: [(GroupPermissions) -> Void] = []
    private var endHandlers: [(String) -> Void] = []
    private var microphoneOn: Bool
    private var cameraOn: Bool
    /// The codec the camera goes out in and what goes behind it (`useCodecs`): the built-in rule until the media
    /// server's policy says otherwise.
    private var cameraCodec: VideoCodec = .vp8
    private var cameraBackup: VideoCodec?
    /// Cameras changing codec, by who said so (`CameraSwitch.topic`), the look that ends one at its failsafe, and the ear
    /// on each camera whose next frame ends one (`watchCameraSwitches`). On the main queue.
    private var cameraSwitch = CameraSwitch()
    private var cameraSwitchLook: DispatchWorkItem?
    private var cameraSwitchEars: [String: (track: VideoTrack, sid: String, ear: CameraNextFrame)] = [:]

    init(owner: RealtimeCalls, name: String, link: GroupOf?, key: String?, microphone: Bool, camera: Bool) {
        self.owner = owner
        self.name = name
        self.link = link
        group = link?.id
        encrypted = !(key ?? "").isEmpty
        microphoneOn = microphone
        cameraOn = camera
        // The mesh decides who needs what and stops sending what nobody looks at. LiveKit's shared-key provider has the
        // web's defaults, so a phone and a browser in one encrypted room hear each other.
        options = RoomOptions(
            adaptiveStream: true,
            dynacast: true,
            e2eeOptions: (key ?? "").isEmpty ? nil : E2EEOptions(keyProvider: BaseKeyProvider(isSharedKey: true, sharedKey: key))
        )
        room = LiveKit.Room()
        super.init()
        room.add(delegate: self)
    }

    /// The state as it changes.
    public func onState(_ handler: @escaping (GroupCallState) -> Void) { stateHandlers.append(handler) }

    /// Someone arrived or left, or what they send changed: read `people`.
    public func onPeople(_ handler: @escaping () -> Void) { peopleHandlers.append(handler) }

    /// The room ended for this app, with the reason: `left`, `disconnected` …
    public func onEnded(_ handler: @escaping (String) -> Void) { endHandlers.append(handler) }

    /// The app's server changed what this app may do (`permit`): made a speaker, it sends what `microphone` and
    /// `camera` then say. Back to listening, the media server takes down what it sent, and both turn false.
    public func onPermissions(_ handler: @escaping (GroupPermissions) -> Void) { permissionHandlers.append(handler) }

    /// What this app may do in the room now: the rule of the app, or what its server changed since.
    public var can: GroupPermissions {
        guard state != .connecting else { return GroupPermissions(publish: true, subscribe: true) }
        let permissions = room.localParticipant.permissions
        return GroupPermissions(publish: permissions.canPublish, subscribe: permissions.canSubscribe)
    }

    /// Whether this app's microphone is sent into the room.
    public var microphone: Bool {
        get { microphoneOn }
        set {
            microphoneOn = newValue
            SystemCalls.shared.microphone(newValue, group: self)
            guard state == .connected || state == .reconnecting else { return }
            Task { _ = try? await room.localParticipant.setMicrophone(enabled: newValue) }
        }
    }

    /// Whether this app's camera is sent into the room.
    public var camera: Bool {
        get { cameraOn }
        set {
            cameraOn = newValue
            guard state == .connected || state == .reconnecting else { return }
            let options = cameraPublish
            Task { _ = try? await room.localParticipant.setCamera(enabled: newValue, publishOptions: options) }
        }
    }

    /// How the camera is published: its codec and what goes behind it.
    private var cameraPublish: VideoPublishOptions {
        VideoPublishOptions(preferredCodec: cameraCodec, preferredBackupCodec: cameraBackup)
    }

    /// The camera's codec and what goes behind it, by the media server's policy (nil: the built-in rule), as the
    /// browser's group calls take it (cameraCodecFor(), backupFor()). What is already published stays as it went out.
    private func useCodecs(_ policy: MeshCodecPolicy?, caps: CallCodecCaps, onMesh: Bool) {
        let codec = CallCodecs.roomPublishCodec(caps, encrypted: encrypted, onMesh: onMesh, policy: policy?.camera)
        cameraCodec = VideoCodec.from(name: codec) ?? .vp8
        cameraBackup = CallCodecs.roomBackupCodec(codec, encrypted: encrypted, policy: policy?.backup).flatMap { VideoCodec.from(name: $0) }
    }

    /// Rings `user` into this group call, one made from a call between two people: they arrive in `people` once they
    /// answer. Throws its code: `not_a_call` for any other room, or the app's server's or the realtime server's refusal.
    @MainActor
    public func add(_ user: String) async throws -> CallInvite {
        guard let link else { throw CallError("not_a_call") }
        guard state != .ended else { throw CallError("ended") }
        return try await owner.invite(link, user: user)
    }

    /// Leaves the room. From any thread: the call ends on the main queue, where its state lives.
    public func leave() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.leave() }
            return
        }
        SystemCalls.shared.endingHere(group: self)
        finish("left")
    }

    /// Turns the camera round, the front one to the back and back, while it is sent.
    public func flipCamera() {
        guard cameraOn, state != .ended else { return }
        let capturer = ( room.localParticipant.firstCameraVideoTrack as? LocalVideoTrack )?.capturer as? CameraCapturer
        Task { _ = try? await capturer?.switchCameraPosition() }
    }

    /// The LiveKit room, for the SDK's call screens (WordPlusRealtimeUI), which draw everyone's tracks from it.
    @_spi(WordPlusUI) public var liveKitRoom: LiveKit.Room { room }

    /// Someone's picture as the room has it, for `GroupVideoView`: none when they don't send it.
    func videoTrack(of identity: String, source: GroupVideoSource) -> VideoTrack? {
        let participant = room.remoteParticipants.values.first { $0.identity?.stringValue == identity }
        let wanted: Track.Source = source == .screen ? .screenShareVideo : .camera
        let publication = participant?.trackPublications.values.first { $0.source == wanted && !$0.isMuted }
        return publication?.track as? VideoTrack
    }

    /// This app's own camera, while it is sent.
    var ownCameraTrack: VideoTrack? {
        let publication = room.localParticipant.trackPublications.values.first { $0.source == .camera && !$0.isMuted }
        return publication?.track as? VideoTrack
    }

    /// Joins the room at its place: the mesh's address, a token for it, and TURN for the way there.
    func connect(server: String, token: String, iceServers: [[String: Any]]) async throws {
        let ice = iceServers.compactMap { entry -> IceServer? in
            let urls = (entry["urls"] as? [String]) ?? (entry["urls"] as? String).map { [$0] } ?? []
            guard !urls.isEmpty else { return nil }
            return IceServer(urls: urls, username: entry["username"] as? String, credential: entry["credential"] as? String)
        }
        // H.264 from hardware with VP8 behind it, VP8 alone in an encrypted room, until the media server's policy says
        // otherwise once joined. The join names, as the browser's does, the codecs this device encodes and decodes in
        // hardware (the room client's own join budget, 30 s).
        let caps = CallMedia.shared.codecCaps
        let onMesh = CallCodecs.onMesh(server)
        await MainActor.run { useCodecs(nil, caps: caps, onMesh: onMesh) }
        let connectOptions = ConnectOptions(
            iceServers: ice,
            meshJoinBudget: 30,
            meshHardwareDecoders: CallCodecs.hardwareDecoders(caps),
            onMeshWait: nil,
            meshHardwareEncoders: CallCodecs.hardwareEncoders(caps)
        )
        try await room.connect(url: server, token: token, connectOptions: connectOptions, roomOptions: options)
        let left = await MainActor.run { state == .ended }
        if left {
            await room.disconnect()
            return
        }
        if let policy = room.meshCodecPolicy {
            await MainActor.run { useCodecs(policy, caps: caps, onMesh: onMesh) }
        }
        // A camera changing codec is shown so for the node's failsafe at most.
        let failsafe = CameraSwitch.failsafe(tune: CameraSwitch.tune("failsafeS", of: room.meshCodecPolicy))
        await MainActor.run { cameraSwitch.failsafe = failsafe }
        if microphoneOn { _ = try? await room.localParticipant.setMicrophone(enabled: true) }
        if cameraOn {
            let publish = await MainActor.run { cameraPublish }
            _ = try? await room.localParticipant.setCamera(enabled: true, publishOptions: publish)
        }
        await MainActor.run {
            setState(.connected)
            refresh()
        }
    }

    /// Everyone else in the room, read again, their info opened with the app's keys.
    private func refresh() {
        // The cameras whose next frame ends a switch, with the tracks read here.
        watchCameraSwitches()
        let keyring = owner.rt.keyring
        people = room.remoteParticipants.values.compactMap { participant in
            guard let identity = participant.identity?.stringValue else { return nil }
            let user = identity.hasPrefix("user_") ? String(identity.dropFirst(5)) : nil
            let sealed = participant.metadata.flatMap(JSONValue.parse) ?? .null
            let tracks = participant.trackPublications.values
            // The camera of theirs that has arrived here, which ends a switch once it is not the old one.
            let arrived = tracks.first { $0.source == .camera && !$0.isMuted && $0.track != nil }?.sid.stringValue
            return GroupPerson(
                identity: identity,
                user: user,
                info: keyring.openJSON(sealed) ?? .null,
                camera: tracks.contains { $0.source == .camera && !$0.isMuted },
                microphone: tracks.contains { $0.source == .microphone && !$0.isMuted },
                speaking: participant.isSpeaking,
                screen: tracks.contains { $0.source == .screenShareVideo && !$0.isMuted },
                publish: participant.permissions.canPublish,
                optimizing: cameraSwitch.awaiting(identity, camera: arrived)
            )
        }.sorted { $0.identity < $1.identity }
        peopleHandlers.forEach { $0() }
    }

    private func setState(_ next: GroupCallState) {
        guard state != next, state != .ended else { return }
        state = next
        stateHandlers.forEach { $0(next) }
    }

    /// A camera changing codec, said by the web's call screen before it takes the camera down and after it is up again
    /// (`CameraSwitch`). On the main queue.
    func heardCameraSwitch(_ word: String, from identity: String, camera: String?, at now: Date = Date()) {
        guard state != .ended else { return }
        let changed = cameraSwitch.heard(word, from: identity, camera: camera, at: now)
        // `ready` changes which frame ends the switch, if not the switch.
        watchCameraSwitches()
        if changed { refresh() }
        lookAtCameraSwitches()
    }

    /// Their camera taken out of the room, or muted: turned off, unless it is the move taking the old camera down. On
    /// the main queue.
    func cameraWentOff(_ identity: String, camera: String?, muted: Bool) {
        guard state != .ended else { return }
        let ended = muted ? cameraSwitch.muted(identity) : camera.map { cameraSwitch.unpublished(identity, camera: $0) } ?? false
        if ended { lookAtCameraSwitches() }
    }

    /// A frame of `identity`'s camera `camera`, heard by its ear. On the main queue.
    func cameraDrew(_ identity: String, camera: String) {
        guard state != .ended else { return }
        if cameraSwitch.shown(identity, camera: camera) {
            refresh()
        } else {
            watchCameraSwitches()
        }
        lookAtCameraSwitches()
    }

    /// Takes down a switch whose new camera never came, at its failsafe (the node's, from the first word of the move),
    /// and looks again while any is up.
    private func lookAtCameraSwitches() {
        cameraSwitchLook?.cancel()
        cameraSwitchLook = nil
        let now = Date()
        if !cameraSwitch.expire(at: now).isEmpty { refresh() }
        guard state != .ended, let next = cameraSwitch.nextExpiry() else { return }
        let look = DispatchWorkItem { [weak self] in self?.lookAtCameraSwitches() }
        cameraSwitchLook = look
        let wait = max(0.1, next.timeIntervalSince(now))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: look)
    }

    /// Each switch up listens for the next frame of the camera that ends it (`CameraSwitch.watches`): a new camera's
    /// first, or after `ready` any camera's next. Heard on the track itself rather than in a view, so a switch ends once
    /// and for all, and a renderer that stalls or a tile drawn again later can't bring it back. On the main queue.
    private func watchCameraSwitches() {
        guard cameraSwitch.anyUp || !cameraSwitchEars.isEmpty else { return }
        var wanted: [String: (track: VideoTrack, sid: String)] = [:]
        if state != .ended, cameraSwitch.anyUp {
            for participant in room.remoteParticipants.values {
                guard let identity = participant.identity?.stringValue, cameraSwitch.optimizing(identity) else { continue }
                let publication = participant.trackPublications.values.first { $0.source == .camera && !$0.isMuted }
                guard
                    let sid = publication?.sid.stringValue,
                    let track = publication?.track as? VideoTrack,
                    cameraSwitch.watches(identity, camera: sid)
                else { continue }
                wanted[identity] = (track, sid)
            }
        }
        for (identity, ear) in cameraSwitchEars where wanted[identity]?.track !== ear.track || wanted[identity]?.sid != ear.sid {
            ear.track.remove(videoRenderer: ear.ear)
            cameraSwitchEars[identity] = nil
        }
        for (identity, want) in wanted where cameraSwitchEars[identity] == nil {
            let ear = CameraNextFrame { [weak self] in self?.cameraDrew(identity, camera: want.sid) }
            want.track.add(videoRenderer: ear)
            cameraSwitchEars[identity] = (want.track, want.sid, ear)
        }
    }

    /// Someone's camera changing codec as this room holds it, for the SDK's call screens, which draw their placeholder
    /// while it is up: whether a switch is up for `identity` (until the frame that ends it, the camera turned off or
    /// the failsafe), and the camera publication that was up when it was said. `GroupPerson.optimizing` is the same
    /// switch, ended as soon as the new camera arrives.
    @_spi(WordPlusUI) public func cameraSwitch(of identity: String) -> (pending: Bool, from: String?) {
        (cameraSwitch.optimizing(identity), cameraSwitch.from(identity))
    }

    /// Ends the room for this app. On the main queue, where its state, its handlers and its camera switches live: a
    /// caller elsewhere (`leave()` from any thread) is moved there.
    func finish(_ reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.finish(reason) }
            return
        }
        guard state != .ended else { return }
        cameraSwitchLook?.cancel()
        cameraSwitchLook = nil
        for ear in cameraSwitchEars.values { ear.track.remove(videoRenderer: ear.ear) }
        cameraSwitchEars.removeAll()
        endReason = reason
        state = .ended
        Task { await room.disconnect() }
        stateHandlers.forEach { $0(.ended) }
        endHandlers.forEach { $0(reason) }
    }
}

extension GroupCall: RoomDelegate {
    public func room(_ room: LiveKit.Room, participantDidConnect participant: RemoteParticipant) {
        DispatchQueue.main.async { self.refresh() }
    }

    public func room(_ room: LiveKit.Room, participantDidDisconnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue
        DispatchQueue.main.async {
            // Gone: their switch goes with them.
            if let identity { self.cameraSwitch.left(identity) }
            self.refresh()
        }
    }

    /// The web's call screen says its camera is changing codec, and when it is back (`CameraSwitch.topic`).
    public func room(_ room: LiveKit.Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        guard
            topic == CameraSwitch.topic,
            let participant,
            let identity = participant.identity?.stringValue,
            let word = CameraSwitch.state(of: data)
        else { return }
        let camera = participant.videoTracks.first { $0.source == .camera && !$0.isMuted }?.sid.stringValue
        DispatchQueue.main.async { self.heardCameraSwitch(word, from: identity, camera: camera) }
    }

    public func room(_ room: LiveKit.Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        DispatchQueue.main.async { self.refresh() }
    }

    public func room(_ room: LiveKit.Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        DispatchQueue.main.async { self.refresh() }
    }

    public func room(_ room: LiveKit.Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        // A camera muted while it was changing codec: turned off, which no move does.
        let identity = participant is RemoteParticipant && trackPublication.source == .camera && isMuted
            ? participant.identity?.stringValue
            : nil
        DispatchQueue.main.async {
            if let identity { self.cameraWentOff(identity, camera: nil, muted: true) }
            self.refresh()
        }
    }

    public func room(_ room: LiveKit.Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        // A camera turned off while it was changing codec, other than by the move itself.
        let identity = participant.identity?.stringValue
        let camera = publication.source == .camera ? publication.sid.stringValue : nil
        DispatchQueue.main.async {
            if let identity, let camera { self.cameraWentOff(identity, camera: camera, muted: false) }
            self.refresh()
        }
    }

    public func room(_ room: LiveKit.Room, participant: Participant, didUpdateMetadata metadata: String?) {
        DispatchQueue.main.async { self.refresh() }
    }

    public func room(_ room: LiveKit.Room, participant: Participant, didUpdatePermissions permissions: ParticipantPermissions) {
        let local = participant is LocalParticipant
        DispatchQueue.main.async {
            guard self.state != .ended else { return }
            guard local else { return self.refresh() }
            // The media server took down what it sent: nothing is sent again on a reconnect.
            if !permissions.canPublish {
                self.microphoneOn = false
                self.cameraOn = false
            }
            let can = GroupPermissions(publish: permissions.canPublish, subscribe: permissions.canSubscribe)
            self.permissionHandlers.forEach { $0(can) }
        }
    }

    public func room(_ room: LiveKit.Room, didStartReconnectWithMode reconnectMode: ReconnectMode) {
        DispatchQueue.main.async { self.setState(.reconnecting) }
    }

    public func room(_ room: LiveKit.Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        DispatchQueue.main.async { self.setState(.connected) }
    }

    public func room(_ room: LiveKit.Room, didDisconnectWithError error: LiveKitError?) {
        DispatchQueue.main.async { self.finish("disconnected") }
    }
}

/// The next frame a camera's track delivers, heard once and told on the main queue: what ends a camera switch
/// (`GroupCall.watchCameraSwitches`). It is no view, and says so to adaptive stream, so it never counts as someone
/// looking: the app's own views decide what is sent. Taken off its track on the main queue, never from a frame's own
/// thread.
final class CameraNextFrame: NSObject, VideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var heard = false
    private let onFrame: () -> Void

    init(_ onFrame: @escaping () -> Void) {
        self.onFrame = onFrame
    }

    var isAdaptiveStreamEnabled: Bool { false }

    var adaptiveStreamSize: CGSize { .zero }

    func render(frame: VideoFrame) {
        lock.lock()
        let first = !heard
        heard = true
        lock.unlock()
        guard first else { return }
        DispatchQueue.main.async(execute: onFrame)
    }
}
