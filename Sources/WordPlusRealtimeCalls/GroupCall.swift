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

/// A join waiting for a place on the mesh, and going on by itself: until when it waits, and why (`busy`, `slot`, `full`
/// or `unreachable`), as the browser's group calls and streams tell it.
public struct CallWait: Equatable, Sendable {
    public let until: Date
    public let reason: String

    public init(until: Date, reason: String) {
        self.until = until
        self.reason = reason
    }

    init(_ wait: MeshWait) {
        until = wait.until
        reason = wait.reason.rawValue
    }
}

/// How a connection is, as the media server rates it.
public enum CallConnectionQuality: String, Sendable {
    case excellent
    case good
    case poor
    case lost
    case unknown

    init(_ quality: ConnectionQuality) {
        switch quality {
        case .excellent: self = .excellent
        case .good: self = .good
        case .poor: self = .poor
        case .lost: self = .lost
        default: self = .unknown
        }
    }
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
    /// How their connection is, as the media server rates it: `onPeople` fires when it changes.
    public internal(set) var quality: CallConnectionQuality = .unknown
    /// They left and may come back (a reload, a dropped connection, a move between nodes): kept in `people`, with no
    /// media, marked so, until they are back or the wait (20 s) is over. `onPersonAway` says it.
    public internal(set) var reconnecting: Bool = false
    /// Their media stopped reaching the media server while they are still in the room, as the mesh says it: `video`
    /// when only their camera stopped, `all` when their sound did too. Nil while it arrives. `onStalled` says it.
    public internal(set) var stalled: GroupStalled? = nil
    /// A host holds their microphone off (`holdMic`), or Mute Everyone does, until it is let go.
    public internal(set) var micHeld: Bool = false
}

/// What this app may do in a group call, as the media server holds it now.
public struct GroupPermissions: Equatable, Sendable {
    /// Send its camera, microphone and screen.
    public let publish: Bool
    /// Get those of the others.
    public let subscribe: Bool
    /// Host the call, as its rule's `admin` said, read from the room's token: `moderate` mutes, lets speak and removes
    /// the others. False for everyone else.
    public let admin: Bool
    /// Its microphone is held off by a host or Mute Everyone, its camera and screen still allowed: `turnOnMicrophone()`
    /// throws `mic_held` until a host lets it go (`onPermissions` again).
    public let micHeld: Bool

    init(publish: Bool, subscribe: Bool, admin: Bool = false, micHeld: Bool = false) {
        self.publish = publish
        self.subscribe = subscribe
        self.admin = admin
        self.micHeld = micHeld
    }
}

/// What a host does to someone else in a group call (`GroupCall.moderate`): `mute` turns their microphone off once,
/// which they may turn on again, `speak` lets a listener send, `listen` makes a speaker a listener, `remove` takes them
/// out (a kick: a new token takes them back in, unless the call is locked). `spotlight` puts someone, the host too, on
/// the main tiles for everyone (up to four, the room's `spotlight`), and `unspotlight` takes them off, or everyone with
/// no user.
///
/// Offered only where `GroupCall.acts` names them (a realtime server and an app's package that know them): `ban` keeps
/// them out for the minutes given, by default until the call ends, and `unban` lets them in again; `holdMic` holds their
/// microphone off until the call ends, and `releaseMic` lets it go; `rules` sets the room's rules (`RoomRules`); `ask`
/// asks them to turn on their camera or microphone; `end` ends the call for everyone.
public enum ModerationAct: String, Sendable {
    case mute
    case speak
    case listen
    case remove
    case spotlight
    case unspotlight
    case ban
    case unban
    case holdMic = "hold_mic"
    case releaseMic = "release_mic"
    case rules
    case ask
    case end

    /// The act a call must offer for it.
    var offeredAs: CallAct {
        switch self {
        case .mute: return .mute
        case .speak: return .speak
        case .listen: return .listen
        case .remove: return .remove
        case .spotlight, .unspotlight: return .spotlight
        case .ban, .unban: return .ban
        case .holdMic: return .holdMic
        case .releaseMic: return .releaseMic
        case .rules: return .rules
        case .ask: return .ask
        case .end: return .end
        }
    }
}

/// A group call's recording, as WordPlus Cloud tells it: its id, and its state (`recording`, `stopping`, `finishing`,
/// `complete` or `failed`).
public struct GroupRecording: Equatable, Sendable {
    public let id: String
    public let state: String

    public init(id: String, state: String) {
        self.id = id
        self.state = state
    }
}

/// What went wrong in a group call that goes on: `publish_failed`, what this app sends could not go out, its `source`
/// `microphone` or `camera`, or `encryption_failed`, a track could not be encrypted or decrypted, with the system's word
/// in `message`.
public struct GroupCallFailure: Equatable, Sendable {
    public let code: String
    public let source: String?
    public let message: String?

    public init(code: String, source: String? = nil, message: String? = nil) {
        self.code = code
        self.source = source
        self.message = message
    }
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

/// Someone rung into a group call, as everyone in it hears of it: `ringing`, then `answered`, `rejected`, `busy`,
/// `no_answer` or `cancelled`, the relay's words. On the main queue.
public final class CallInvite: @unchecked Sendable {
    static let states: Set<String> = ["ringing", "answered", "rejected", "busy", "no_answer", "cancelled"]

    public let id: String
    /// The group call it rings into: the id of the call it was made from.
    public let group: String
    /// Who rang, for a ring this app heard of. Nil for one it rang itself, unless the relay told of it first.
    public let from: String?
    public let to: String
    public private(set) var state: String

    private var stateHandlers = CallHandlers<String>()
    private var canceller: (() async throws -> Void)?

    init(id: String, group: String, from: String? = nil, to: String, state: String) {
        self.id = id
        self.group = group
        self.from = from
        self.to = to
        self.state = state
    }

    /// The state as it changes.
    @discardableResult
    public func onState(_ handler: @escaping (String) -> Void) -> CallListener { stateHandlers.add(handler) }

    /// Takes a handler off.
    public func off(_ listener: CallListener) {
        stateHandlers.remove(listener)
    }

    /// Whether `cancel()` can call it off now: it still rings, and this app rang it.
    public var canCancel: Bool { state == "ringing" && canceller != nil }

    /// Calls it off while it rings: from the app that rang only, `forbidden` for anyone else. Throws its code.
    public func cancel() async throws {
        guard state == "ringing" else { return }
        guard let canceller else { throw CallError("forbidden") }
        try await canceller()
    }

    /// The app that rang can call it off.
    func own(_ canceller: @escaping () async throws -> Void) {
        self.canceller = canceller
    }

    func update(_ next: String) {
        // A ring that ended stays ended, whichever word of it arrives last.
        guard state != next, state == "ringing" else { return }
        state = next
        stateHandlers.fire(next)
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
    /// While a join waits for a place on the mesh: until when, and why. The state stays `connecting`, and the join goes on
    /// by itself. Nil at any other time.
    public private(set) var waiting: CallWait?
    public private(set) var endReason: String?
    /// Everyone else in the room.
    public private(set) var people: [GroupPerson] = []
    /// This app's own user in the room, as the others see them: their info as the app's server gave it. Nil until
    /// connected, and once it has ended. `self` on the browser's, a word Swift keeps for itself.
    public var me: GroupPerson? {
        guard state != .ended else { return nil }
        return person(room.localParticipant)
    }

    /// This app's own user for a screen to draw from the first moment: `me` once the room has connected, and what the
    /// room's token says before that, as the room knows nobody until then, and a tile with no name reads as a stranger.
    @_spi(WordPlusUI) public var own: (identity: String, info: JSONValue) {
        let joined = me
        let info = joined?.info ?? .null
        return (joined?.identity ?? tokenIdentity ?? "", info != .null ? info : owner.rt.keyring.openJSON(tokenInfo) ?? .null)
    }

    /// Who the room's token makes this app's user, from the moment the join has its place: `sub`, the identity the media
    /// server will give them, and `metadata`, their info as the app's server gave it, still sealed. On the main queue.
    private var tokenIdentity: String?
    private var tokenInfo: JSONValue = .null

    private let room: LiveKit.Room
    private let options: RoomOptions
    private unowned let owner: RealtimeCalls
    private let link: GroupOf?
    /// A group call the app's server names (`rt.calls.group(name)`), whose host acts through its calls route: not a call
    /// that became one, nor the room a call moved to.
    private let moderated: Bool
    /// What a token of the app's server gave this app to host the call or record it (`rt.joinGroupCall`), which the calls
    /// route checks. Nil for a call joined by its name, whose rule is asked instead.
    private let proofs: GroupProofs?
    /// Whether the calls route's answer said this app's user may record the call (its `record`: the rule's `record`, else
    /// its `admin`), for a call joined by its name. A call joined by a token goes by `proofs`.
    private let mayRecord: Bool
    /// Whether the room's token makes this app its host (`video.roomAdmin`, the rule's `admin`): the room's own
    /// permissions don't carry it. On the main queue.
    private var grantedAdmin = false
    private var stateHandlers = CallHandlers<GroupCallState>()
    private var waitingHandlers = CallHandlers<CallWait>()
    private var peopleHandlers = CallHandlers<Void>()
    private var permissionHandlers = CallHandlers<GroupPermissions>()
    private var inviteHandlers = CallHandlers<CallInvite>()
    private var errorHandlers = CallHandlers<GroupCallFailure>()
    private var screenHandlers = CallHandlers<Bool>()
    private var spotlightHandlers = CallHandlers<[String]>()
    private var recordingHandlers = CallHandlers<Bool>()
    private var qualityHandlers = CallHandlers<CallConnectionQuality>()
    private var endHandlers = CallHandlers<String>()
    private var microphoneOn: Bool
    private var cameraOn: Bool
    /// The codec the camera goes out in, what goes behind it and whether this device encodes it in hardware
    /// (`useCodecs`): the built-in rule until the media server's settings or policy say otherwise.
    private var cameraCodec: VideoCodec = .vp8
    private var cameraBackup: VideoCodec?
    private var cameraHardware = false
    /// What this device encodes and decodes, and whether the room is on the mesh, for the codecs the settings choose
    /// during the call. Set as the room connects.
    private var codecCaps: CallCodecCaps?
    private var onMesh = false
    /// The publish settings the running camera went out under (`GroupShapes.cameraPrint`), nil with none published, and
    /// the re-publish a revision with `applyNow` asked for, at its moment. On the main queue.
    private var cameraPrint: String?
    private var settingsRepublish: DispatchWorkItem?
    /// Cameras changing codec, by who said so (`CameraSwitch.topic`), the look that ends one at its failsafe, and the ear
    /// on each camera whose next frame ends one (`watchCameraSwitches`). On the main queue.
    private var cameraSwitch = CameraSwitch()
    private var cameraSwitchLook: DispatchWorkItem?
    private var cameraSwitchEars: [String: (track: VideoTrack, sid: String, ear: CameraNextFrame)] = [:]
    /// The microphone under its ceiling on a slow upload (`reviewMicCeiling`), its next reading, what each stream of the
    /// video going out had encoded at the last one, and the tracks asked for their statistics. On the main queue.
    private let micCeiling = CallMicCeiling(slowBelow: CallMicCeiling.roomSlowBelow, backAt: CallMicCeiling.roomBackAt)
    private var micLook: DispatchWorkItem?
    private var micFrames: [String: UInt] = [:]
    private let micLoss = CallMicLoss()
    private var micDownForLoss = false
    private var micDownAlone = false
    private let micAsked = NSHashTable<Track>.weakObjects()
    /// The picture giving way to the sound a step at a time once the microphone is down (`CallPictureSteps`), and the
    /// cap the camera is under for its codec (`GroupShapes.cameraCap`), which a step's ceiling goes beside. On the main queue.
    private let picture = CallPictureSteps()
    private var cameraCodecCap = MeshCaps()
    /// The upload this app sends on judged for a jam, from the same readings (`CallUploadJam`). On the main queue.
    private let uploadJam = CallUploadJam()
    private var jamHandlers = CallHandlers<Bool>()

    /// What the call offers (`CallAct`): the acts both the realtime server's place and the app's package name, so a
    /// screen shows a control only for those. Today's five host acts (`CallAct.base`) with a 1.1.0-era server or
    /// package, none in a room with no host acts (a call that became a group call, or the room a call moved to).
    public let acts: [CallAct]
    /// The tiles of those who left and may come back, by identity, with the look that lets each go, and when each one's
    /// bye came (`CallAway`). On the main queue.
    private var away: [String: (person: GroupPerson, look: DispatchWorkItem)] = [:]
    private var byes: [String: Date] = [:]
    private let stalls = StallWatch()
    /// The rules and hands last said, so each is said once a change. On the main queue.
    private var saidRules: RoomRules?
    private var saidHands: [String]?
    /// The microphone held as this app joined (its place's `mic_held`, or the token's sources), until the room's
    /// permissions change once it is in. On the main queue.
    private var heldAtJoin = false
    private var awayHandlers = CallHandlers<GroupPerson>()
    private var stalledHandlers = CallHandlers<GroupPerson>()
    private var rulesHandlers = CallHandlers<RoomRules>()
    private var handsHandlers = CallHandlers<[String]>()
    private var askHandlers = CallHandlers<TurnOnAsk>()
    private var askAnswerHandlers = CallHandlers<TurnOnAnswer>()

    init(owner: RealtimeCalls, name: String, link: GroupOf?, key: String?, microphone: Bool, camera: Bool, moderated: Bool = false, proofs: GroupProofs? = nil, mayRecord: Bool = false, acts: [CallAct]? = nil) {
        self.owner = owner
        self.name = name
        self.link = link
        self.moderated = moderated
        self.proofs = proofs
        self.mayRecord = mayRecord
        // A host's acts need the calls route, which a room the app's server doesn't name has none of.
        self.acts = moderated ? (acts ?? CallAct.base) : []
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
        // Whose media stopped reaching the media server, as the mesh says it (rtc-client 1.0.25).
        room.setMeshSourcesDryHandler { [weak self] dry in
            DispatchQueue.main.async { self?.readStalls(dry) }
        }
    }

    /// The state as it changes.
    @discardableResult
    public func onState(_ handler: @escaping (GroupCallState) -> Void) -> CallListener { stateHandlers.add(handler) }

    /// A join waits for a place on the mesh: until when, and why. It goes on by itself, `onState` saying `connected` then.
    @discardableResult
    public func onWaiting(_ handler: @escaping (CallWait) -> Void) -> CallListener { waitingHandlers.add(handler) }

    /// Someone arrived or left, or what they send changed: read `people`.
    @discardableResult
    public func onPeople(_ handler: @escaping () -> Void) -> CallListener { peopleHandlers.add { _ in handler() } }

    /// The room ended for this app, with the reason: `left`, `removed` (the app's server took this user out), `closed`
    /// (it ended the call for everyone), `disconnected` …
    @discardableResult
    public func onEnded(_ handler: @escaping (String) -> Void) -> CallListener { endHandlers.add(handler) }

    /// The app's server changed what this app may do (`permit`): made a speaker, it sends what `microphone` and
    /// `camera` then say. Back to listening, the media server takes down what it sent, and both turn false.
    @discardableResult
    public func onPermissions(_ handler: @escaping (GroupPermissions) -> Void) -> CallListener { permissionHandlers.add(handler) }

    /// Who a host put on the main tiles for everyone changed (`spotlight`), or was on as this app joined.
    @discardableResult
    public func onSpotlight(_ handler: @escaping ([String]) -> Void) -> CallListener { spotlightHandlers.add(handler) }

    /// The room's recording flag changed (`isRecording`), whoever started or stopped it.
    @discardableResult
    public func onRecording(_ handler: @escaping (Bool) -> Void) -> CallListener { recordingHandlers.add(handler) }

    /// Someone is rung into this group call, by anyone in it: follow them with `onState`.
    @discardableResult
    public func onInvite(_ handler: @escaping (CallInvite) -> Void) -> CallListener { inviteHandlers.add(handler) }

    /// What went wrong in a call that goes on: the camera or microphone could not go out (`publish_failed`), or a track
    /// could not be encrypted or decrypted (`encryption_failed`).
    @discardableResult
    public func onError(_ handler: @escaping (GroupCallFailure) -> Void) -> CallListener { errorHandlers.add(handler) }

    /// This app began or stopped sharing its screen: said once it did, the system's own red bar included.
    @discardableResult
    public func onScreenShare(_ handler: @escaping (Bool) -> Void) -> CallListener { screenHandlers.add(handler) }

    /// Someone left and may come back: kept in `people`, `reconnecting`, with no media, for 20 s, as Better Messages
    /// keeps the tile. Once they are back, or the wait is over, `onPeople` says it. A hang-up goes at once.
    @discardableResult
    public func onPersonAway(_ handler: @escaping (GroupPerson) -> Void) -> CallListener { awayHandlers.add(handler) }

    /// Someone's media stopped reaching the media server, or arrives again (their `stalled`).
    @discardableResult
    public func onStalled(_ handler: @escaping (GroupPerson) -> Void) -> CallListener { stalledHandlers.add(handler) }

    /// The room's rules (`rules`): said once as the room joins, then on every change, whichever host made it.
    @discardableResult
    public func onRules(_ handler: @escaping (RoomRules) -> Void) -> CallListener { rulesHandlers.add(handler) }

    /// Whose hands are up (`hands`, user ids, the earliest first): said once as the room joins, then on every change.
    @discardableResult
    public func onHands(_ handler: @escaping ([String]) -> Void) -> CallListener { handsHandlers.add(handler) }

    /// A host asks this app's user to turn on their camera or microphone: answer with `answerAsk`.
    @discardableResult
    public func onAsk(_ handler: @escaping (TurnOnAsk) -> Void) -> CallListener { askHandlers.add(handler) }

    /// Someone answered this app's ask (`askToTurnOn`).
    @discardableResult
    public func onAskAnswer(_ handler: @escaping (TurnOnAnswer) -> Void) -> CallListener { askAnswerHandlers.add(handler) }

    /// Whether this app is sharing its screen into the room.
    public var sharingScreen: Bool { room.localParticipant.isScreenShareEnabled() }

    /// Shares this phone's screen into the room, or stops. To share it needs the app's broadcast extension (`ScreenShare`),
    /// and puts up the system's picker: true says it was asked, and `onScreenShare` says when the share begins. False before
    /// the room is up, for one who may not send, and without the extension. One that could not go out is told by `onError`
    /// too (`publish_failed`, `source` `screen`).
    @discardableResult
    public func setScreenShare(_ on: Bool) async -> Bool {
        guard state == .connected || state == .reconnecting else { return false }
        guard on else {
            _ = try? await room.localParticipant.set(source: .screenShareVideo, enabled: false)
            #if os(iOS)
            if BroadcastManager.shared.isBroadcasting { BroadcastManager.shared.requestStop() }
            #endif
            return false
        }
        guard !sharingScreen else { return true }
        guard ScreenShare.isAvailable, can.publish else { return false }
        do {
            _ = try await room.localParticipant.set(source: .screenShareVideo, enabled: true)
            return true
        } catch {
            publishFailed("screen", error)
            return false
        }
    }

    /// Takes a handler off.
    public func off(_ listener: CallListener) {
        screenHandlers.remove(listener)
        stateHandlers.remove(listener)
        waitingHandlers.remove(listener)
        peopleHandlers.remove(listener)
        permissionHandlers.remove(listener)
        inviteHandlers.remove(listener)
        errorHandlers.remove(listener)
        spotlightHandlers.remove(listener)
        recordingHandlers.remove(listener)
        qualityHandlers.remove(listener)
        endHandlers.remove(listener)
        awayHandlers.remove(listener)
        stalledHandlers.remove(listener)
        rulesHandlers.remove(listener)
        handsHandlers.remove(listener)
        askHandlers.remove(listener)
        askAnswerHandlers.remove(listener)
    }

    /// Who a host put on the main tiles for everyone, in the order they were, by their user ids, as `spotlightOn` takes
    /// them: the room's state, so an app that joins later has it too. Empty while nobody is in it.
    public var spotlit: [String] { Self.users(of: spotlight) }

    /// Who a host put on the main tiles for everyone changed, or was on as this app joined, by their user ids.
    @discardableResult
    public func onSpotlit(_ handler: @escaping ([String]) -> Void) -> CallListener {
        spotlightHandlers.add { identities in handler(Self.users(of: identities)) }
    }

    /// The media server's identities as user ids (`user_<id>`), leaving out any that names no user.
    static func users(of identities: [String]) -> [String] {
        identities.compactMap { $0.hasPrefix("user_") ? String($0.dropFirst(5)) : nil }
    }

    /// The same by the media server's identity (`GroupPerson.identity`, `user_<id>`, this app's own user's too): `spotlit`
    /// names users, as a host's acts take them.
    public var spotlight: [String] { Self.spotlight(of: room.metadata) }

    /// How this app's own connection is, as the media server rates it (`onQuality` when it changes).
    public var quality: CallConnectionQuality { CallConnectionQuality(room.localParticipant.connectionQuality) }

    /// This app's own connection changed, as the media server rates it.
    @discardableResult
    public func onQuality(_ handler: @escaping (CallConnectionQuality) -> Void) -> CallListener { qualityHandlers.add(handler) }

    /// Whether the upload this app sends on is jammed: what it sends waits seconds on the person's own line, or gets no
    /// answer at all, while what is sent to it still arrives. Others may then see its video freeze or hear its sound
    /// break up, and the one who can mend it is the person: whatever else uploads on their network. While it is, a call
    /// screen shows its connection as poor whatever `quality` says, as the media server rates such a line good.
    public private(set) var uploadJammed = false

    /// This app's upload became jammed, or no longer is (`uploadJammed`).
    @discardableResult
    public func onUploadJam(_ handler: @escaping (Bool) -> Void) -> CallListener { jamHandlers.add(handler) }

    /// Sends this app's camera, or stops: as setting `camera`, in the words of a live stream and of the web.
    public func setCamera(_ on: Bool) { camera = on }

    /// Sends this app's microphone, or stops: as setting `microphone`, in the words of a live stream and of the web.
    public func setMicrophone(_ on: Bool) { microphone = on }

    /// A host turns someone's microphone off once, which they may turn on again. Throws as `moderate` does.
    public func mute(_ user: String) async throws -> Bool { try await moderate(.mute, user: user) }

    /// A host takes someone out of the call: a kick, so a new token takes them back in, unless the call is locked, which
    /// then keeps them out. The tokens signed for them before do not take them back in.
    public func remove(_ user: String) async throws -> Bool { try await moderate(.remove, user: user) }

    /// A host takes someone out and keeps them out for `minutes` (1 to 10080), by default until the call ends, whatever
    /// token they bring: their join throws `banned`. Where `acts` has `ban`; throws `forbidden` for another host.
    public func ban(_ user: String, minutes: Int? = nil) async throws -> Bool {
        try await act(.ban, user: user, minutes: minutes).done
    }

    /// A host lets someone banned from the call in again. Where `acts` has `ban`.
    public func unban(_ user: String) async throws -> Bool { try await moderate(.unban, user: user) }

    /// A host holds someone's microphone off until the call ends, or `releaseMic`, through a reload too: their
    /// `micHeld`, and their app can't turn it on. Where `acts` has `hold_mic`.
    public func holdMic(_ user: String) async throws -> Bool { try await moderate(.holdMic, user: user) }

    /// A host lets a held microphone go: the person may turn it on again. Where `acts` has `release_mic`.
    public func releaseMic(_ user: String) async throws -> Bool { try await moderate(.releaseMic, user: user) }

    /// A host sets any of the room's rules, which hold until it empties: the rules now, which every app hears as
    /// `onRules`. Broadcast Mode makes everyone but the hosts a listener and Participatory lets them speak again, each
    /// dropping who was promoted or made a listener; Mute Everyone holds every microphone but a host's, and turning it
    /// off lets them go; Lock keeps out anyone not already in. Where `acts` has `rules`.
    @discardableResult
    public func setRules(mode: RoomRules.Mode? = nil, locked: Bool? = nil, muted: Bool? = nil) async throws -> RoomRules {
        var change: [String: Any] = [:]
        if let mode { change["mode"] = mode.rawValue }
        if let locked { change["locked"] = locked }
        if let muted { change["muted"] = muted }
        let answer = try await act(.rules, user: nil, rules: change)
        var rules = self.rules
        if let mode { rules.mode = mode }
        if let locked { rules.locked = locked }
        if let muted { rules.muted = muted }
        if let told = answer.rules {
            if let mode = (told["mode"] as? String).flatMap(RoomRules.Mode.init(rawValue:)) { rules.mode = mode }
            if let locked = told["locked"] as? Bool { rules.locked = locked }
            if let muted = told["muted"] as? Bool { rules.muted = muted }
        }
        return rules
    }

    /// A host asks someone to turn on their camera or microphone: the ask's id, which their answer names
    /// (`onAskAnswer`). Throws `asked_recently` for the same ask within 30 s. Where `acts` has `ask`.
    public func askToTurnOn(_ user: String, devices: [AskDevice]) async throws -> String {
        var asked: [AskDevice] = []
        for device in devices where !asked.contains(device) { asked.append(device) }
        guard !asked.isEmpty else { throw CallError("bad_request") }
        let answer = try await act(.ask, user: user, devices: asked)
        guard let id = answer.id, !id.isEmpty else { throw CallError("server") }
        return id
    }

    /// Answers a host's ask (`onAsk`), to that host alone: what came of it, nothing more of this app's devices.
    public func answerAsk(_ ask: TurnOnAsk, _ answer: AskAnswer) async throws {
        guard let by = ask.by else { throw CallError("bad_request") }
        let data = try JSONSerialization.data(withJSONObject: ["id": ask.id, "answer": answer.rawValue])
        let options = DataPublishOptions(destinationIdentities: [Participant.Identity(from: "user_" + by)], topic: GroupRoomState.askAnswerTopic, reliable: true)
        try await room.localParticipant.publish(data: data, options: options)
    }

    /// A host ends the call for everyone: each is taken out (`onEnded` with `closed`), the tokens signed before don't
    /// take them back, and what the call held goes with it but a ban given minutes, so a join after it starts a new
    /// call. Where `acts` has `end`. `leave()` leaves alone.
    public func end() async throws -> Bool { try await moderate(.end, user: nil) }

    /// This app's user raises a hand, which stays up for every host to see (`hands`), until lowered or they leave.
    /// Where `acts` has `hand`.
    public func raiseHand() async throws -> Bool { try await handVia(true, of: .own) }

    /// This app's user lowers their hand. Where `acts` has `hand`.
    public func lowerHand() async throws -> Bool { try await handVia(false, of: .own) }

    /// A host lowers someone's hand. Where `acts` has `hand`; throws `forbidden` for anyone but a host.
    public func lowerHand(of user: String) async throws -> Bool { try await handVia(false, of: .one(user)) }

    /// A host lowers every hand. Where `acts` has `hand`; throws `forbidden` for anyone but a host.
    public func lowerAllHands() async throws -> Bool { try await handVia(false, of: .everyone) }

    private func handVia(_ up: Bool, of whose: HandOf) async throws -> Bool {
        guard moderated else { throw CallError("not_moderated") }
        guard acts.contains(.hand) else { throw CallError("not_offered") }
        return try await owner.hand(name, up: up, of: whose, host: proofs?.host, member: proofs?.member)
    }

    /// The room's rules (Broadcast Mode, Lock and Mute Everyone), as the realtime server keeps them in its metadata
    /// until the room empties: participatory, unlocked and unmuted from a server that keeps none. `onRules` when they
    /// change.
    public var rules: RoomRules { RoomRules.of(room.metadata) }

    /// Whose hands are up, by their user ids, in the order raised: room state until lowered or their owner leaves.
    public var hands: [String] { Self.users(of: GroupRoomState.hands(of: room.metadata)) }

    /// Whether this app's user has a hand up.
    public var handRaised: Bool {
        guard let me = room.localParticipant.identity?.stringValue ?? tokenIdentity else { return false }
        return GroupRoomState.hands(of: room.metadata).contains(me)
    }

    /// Sends this app's microphone, as `microphone = true`, or throws `mic_held` while a host holds it off (`can.micHeld`).
    public func turnOnMicrophone() throws {
        guard !can.micHeld else { throw CallError("mic_held") }
        microphone = true
    }

    /// A host lets a listener send their camera, microphone and screen.
    public func letSpeak(_ user: String) async throws -> Bool { try await moderate(.speak, user: user) }

    /// A host makes a speaker a listener: what they send stops.
    public func makeListener(_ user: String) async throws -> Bool { try await moderate(.listen, user: user) }

    /// A host puts someone, themselves too, on the main tiles for everyone, up to four. A fifth throws `spotlight_full`.
    public func spotlightOn(_ user: String) async throws -> Bool { try await moderate(.spotlight, user: user) }

    /// A host takes someone off the main tiles, or everyone with no user.
    public func spotlightOff(_ user: String? = nil) async throws -> Bool { try await moderate(.unspotlight, user: user) }

    /// Who is in a room's spotlight, as its metadata says (the realtime server's `spotlight`): the identities, once each,
    /// at most four, as the browser's group calls read them (spotlightOf()).
    static func spotlight(of metadata: String?) -> [String] {
        guard
            let data = metadata?.data(using: .utf8), !data.isEmpty,
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = value["spotlight"] as? [Any]
        else { return [] }
        var spotlit: [String] = []
        for case let identity as String in list where !identity.isEmpty && !spotlit.contains(identity) {
            spotlit.append(identity)
        }
        return Array(spotlit.prefix(4))
    }

    /// What this app may do in the room now: the rule of the app, or what its server changed since. Hosting is the
    /// room's token's alone (`admin`).
    public var can: GroupPermissions {
        guard state != .connecting else { return GroupPermissions(publish: true, subscribe: true, admin: grantedAdmin, micHeld: heldAtJoin) }
        return Self.permissions(room.localParticipant.permissions, admin: grantedAdmin, heldAtJoin: heldAtJoin)
    }

    /// What the media server's permissions let this app do: a microphone left out of its sources is held, and so is one
    /// held as it joined until the room's permissions change once in.
    static func permissions(_ permissions: ParticipantPermissions, admin: Bool, heldAtJoin: Bool) -> GroupPermissions {
        Self.permissions(publish: permissions.canPublish, subscribe: permissions.canSubscribe, sources: Array(permissions.canPublishSources), admin: admin, heldAtJoin: heldAtJoin)
    }

    static func permissions(publish: Bool, subscribe: Bool, sources: [Int], admin: Bool, heldAtJoin: Bool) -> GroupPermissions {
        let held = GroupRoomState.holdsMic(publish: publish, sources: sources) || (publish && heldAtJoin)
        return GroupPermissions(publish: publish, subscribe: subscribe, admin: admin, micHeld: held)
    }

    /// What a host does to someone else in the call (`ModerationAct`), through the app's calls route, which asks the
    /// call's rule again and takes it from a host alone (its `admin`). Whether it changed anything. `user` is nil only
    /// for `unspotlight`, which then takes everyone off the main tiles. Throws its code: `forbidden` for an app that
    /// isn't the host, `not_moderated` for a room that isn't a group call the app's server names (a call that became
    /// one, or the room a call moved to), `bad_request` for nobody named with any other act (`rules` and `end` name
    /// nobody), `not_offered` for an act `acts` doesn't name (nothing is sent), `spotlight_full` for a fifth person in
    /// the spotlight.
    public func moderate(_ act: ModerationAct, user: String?) async throws -> Bool {
        try await self.act(act, user: user).done
    }

    /// A host's act through the calls route, the route's whole answer: refused here for an act this call doesn't offer,
    /// as an old server or package would answer one it doesn't know with `bad_request`.
    private func act(_ act: ModerationAct, user: String?, minutes: Int? = nil, devices: [AskDevice]? = nil, rules: [String: Any]? = nil) async throws -> ModerationAnswer {
        guard moderated else { throw CallError("not_moderated") }
        let nobody = act == .unspotlight || act == .rules || act == .end
        guard user != nil || nobody else { throw CallError("bad_request") }
        guard user == nil || (act != .rules && act != .end) else { throw CallError("bad_request") }
        guard acts.contains(act.offeredAs) else { throw CallError("not_offered") }
        return try await owner.moderate(name, act: act, user: user, host: proofs?.host, minutes: minutes, devices: devices, rules: rules)
    }

    /// Starts recording the call, through the app's calls route (`{ call, record: "start" }`), which asks the call's rule
    /// again and takes it from whoever it lets record (its `record`, else its host): the recording, its id and state.
    /// Throws its code: `forbidden` for anyone else, `not_moderated` for a room that isn't a group call the app's server
    /// names, or WordPlus Cloud's refusal (`no_credits`, `not_included`, `already_recording` …). Its files go to the
    /// app's server (the server package's `recordings`). The call screen offers it to whoever `canRecord` says.
    public func startRecording() async throws -> GroupRecording {
        guard moderated else { throw CallError("not_moderated") }
        return try await owner.record(name, action: "start", recording: nil, recorder: proofs?.recorder)
    }

    /// Stops the recording `id` of the call (`{ call, record: "stop", recording }`): the recording, being stopped.
    public func stopRecording(_ id: String) async throws -> GroupRecording {
        guard moderated else { throw CallError("not_moderated") }
        return try await owner.record(name, action: "stop", recording: id, recorder: proofs?.recorder)
    }

    /// Whether the room says it is being recorded, by whoever started it: the media server's flag, which late joiners
    /// have too.
    public var isRecording: Bool { room.isRecording }

    /// Whether to offer Start Recording to this user, in a group call the app's server names whose media the recorder can
    /// read: whoever the calls route's answer said may record it (its `record`, which the server packages give whoever
    /// the call's rule answers `record`, else its host), as the browser's group calls read it. A call joined with a token
    /// of the app's server goes by that token, which says whether they may record. The call's rule is asked again as it
    /// starts.
    public var canRecord: Bool {
        guard moderated, !encrypted else { return false }
        if let proofs { return proofs.recorder != nil }
        return mayRecord
    }

    /// Whether a room's token makes its holder the host: its media grant's `roomAdmin`, which the realtime server writes
    /// from the app's rule. False for a token that can't be read.
    static func admin(of token: String) -> Bool {
        (claims(of: token)?["video"] as? [String: Any])?["roomAdmin"] as? Bool == true
    }

    /// What a room's token says, or nil for one that can't be read.
    private static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Takes who this app's user is from the room's token, before the room connects: `own`. And whether its microphone
    /// is held as it joins: the realtime server's word (`micHeld`, the place's `mic_held`), or the token's sources, which
    /// leave the microphone out. Held until the room's permissions change once in, should the room's own not carry it.
    func named(by token: String, micHeld: Bool = false) {
        let claims = Self.claims(of: token)
        let video = claims?["video"] as? [String: Any]
        let sources = video?["canPublishSources"] as? [Any] ?? []
        heldAtJoin = micHeld || GroupRoomState.holdsMic(publish: video?["canPublish"] as? Bool ?? true, sources: sources)
        // Held off: nothing turns the microphone on as it joins.
        if heldAtJoin { microphoneOn = false }
        guard let claims else { return }
        tokenIdentity = claims["sub"] as? String
        tokenInfo = (claims["metadata"] as? String).flatMap(JSONValue.parse) ?? .null
    }

    /// Whether this app's microphone is sent into the room.
    /// While a host holds it off (`can.micHeld`), true does nothing: `turnOnMicrophone()` says why.
    public var microphone: Bool {
        get { microphoneOn }
        set {
            if newValue, can.micHeld { return }
            microphoneOn = newValue
            SystemCalls.shared.microphone(newValue, group: self)
            guard state == .connected || state == .reconnecting else { return }
            Task { await publishMicrophone(newValue) }
        }
    }

    /// Whether this app's camera is sent into the room.
    public var camera: Bool {
        get { cameraOn }
        set {
            cameraOn = newValue
            guard state == .connected || state == .reconnecting else { return }
            Task { await publishCamera(newValue) }
        }
    }

    /// The microphone sent or stopped, opened and published by the media server's settings as they are now
    /// (`GroupShapes`).
    private func publishMicrophone(_ enabled: Bool) async {
        let settings = room.meshSettings
        do {
            _ = try await room.localParticipant.setMicrophone(
                enabled: enabled,
                captureOptions: GroupShapes.microphoneCapture(settings: settings),
                publishOptions: GroupShapes.microphone(encrypted: encrypted, settings: settings)
            )
        } catch {
            if enabled { publishFailed("microphone", error) }
        }
    }

    /// What this app sends could not go out. From any thread: told on the main queue, while the call goes on.
    func publishFailed(_ source: String, _ error: Error) {
        fail(GroupCallFailure(code: "publish_failed", source: source, message: "\(error)"))
    }

    private func fail(_ failure: GroupCallFailure) {
        DispatchQueue.main.async {
            guard self.state != .ended else { return }
            self.errorHandlers.fire(failure)
        }
    }

    /// Whether a track's encryption says it failed, as the browser's `EncryptionError` tells it. A key missing for a moment
    /// as someone joins says nothing yet.
    static func encryptionFailed(_ state: E2EEState) -> Bool {
        state == .encryption_failed || state == .decryption_failed || state == .internal_error
    }

    /// The camera sent or stopped, opened and published by the media server's settings as they are now: its capture,
    /// codec, layers and the tallest it may go out at in that codec (`GroupShapes`).
    func publishCamera(_ enabled: Bool) async {
        let settings = room.meshSettings
        let (codec, backup, hardware, front) = await MainActor.run { (cameraCodec, cameraBackup, cameraHardware, frontCamera) }
        let capture = GroupShapes.cameraCapture(settings: settings, front: front)
        if enabled {
            let lines = Int(min(capture.dimensions.width, capture.dimensions.height))
            let cap = GroupShapes.cameraCap(hardware: hardware, lines: lines, settings: settings)
            // beside the step the picture is at for the sound's sake, which a camera turned on later comes under too
            let step = await MainActor.run { () -> Int in
                cameraCodecCap = cap
                return picture.step
            }
            await room.setProductCameraCaps(GroupShapes.cameraCap(cap, step: step))
        }
        let publish = GroupShapes.camera(codec: codec, backup: backup, dimensions: capture.dimensions, settings: settings)
        var published = false
        do {
            _ = try await room.localParticipant.setCamera(enabled: enabled, captureOptions: capture, publishOptions: publish)
            published = true
        } catch {
            if enabled { publishFailed("camera", error) }
        }
        let print = GroupShapes.cameraPrint(settings)
        await MainActor.run { cameraPrint = enabled && published ? print : nil }
    }

    /// The camera out again with the settings it is under now, as the web moves a camera to another codec (the
    /// realtime client's switchCameraCodec): "optimizing" to everyone, so the others show the tile as being optimized
    /// rather than gone; the camera published again within `tune.republishTimeoutS`, else again in the codec it had,
    /// so it is never lost; and "ready" either way.
    private func republishCamera() async {
        guard room.connectionState == .connected, await MainActor.run(body: { cameraOn && state != .ended }) else { return }
        let before = await MainActor.run { (cameraCodec, cameraBackup, cameraHardware) }
        let timeout = TimeInterval(room.meshSettings.int("tune.republishTimeoutS") ?? 8)

        await announceCamera("optimizing")
        await unpublishCamera()
        await publishCamera(true)
        if !(await cameraPublished(within: timeout)) {
            await MainActor.run {
                cameraCodec = before.0
                cameraBackup = before.1
                cameraHardware = before.2
            }
            await unpublishCamera()
            await publishCamera(true)
            _ = await cameraPublished(within: timeout)
        }
        await announceCamera("ready")
    }

    /// The camera taken out of the room, not muted, so the next publish goes out in its new shape.
    private func unpublishCamera() async {
        for publication in room.localParticipant.localVideoTracks where publication.source == .camera {
            try? await room.localParticipant.unpublish(publication: publication)
        }
    }

    private func cameraPublished(within timeout: TimeInterval) async -> Bool {
        let until = Date().addingTimeInterval(timeout)
        while Date() < until {
            if room.localParticipant.localVideoTracks.contains(where: { $0.source == .camera && !$0.isMuted }) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    /// A word on the camera's move to everyone (`CameraSwitch.topic`), as the web says it; one that can't go out within
    /// a second doesn't hold the move up.
    private func announceCamera(_ word: String) async {
        guard let data = try? JSONSerialization.data(withJSONObject: ["state": word]) else { return }
        let room = room
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await room.localParticipant.publish(data: data, options: DataPublishOptions(topic: CameraSwitch.topic, reliable: true))
            }
            group.addTask { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            await group.next()
            group.cancelAll()
        }
    }

    /// The camera's codec and what goes behind it, as the browser's group calls take them (cameraCodecFor(),
    /// backupFor()): the media server's settings once a settings document is in use (`camera.codecRules`,
    /// `camera.codecs`, `camera.backup`), else its policy, else the built-in rule. What is already published stays as
    /// it went out.
    private func useCodecs(_ policy: MeshCodecPolicy?, settings: MeshSettings, caps: CallCodecCaps, onMesh: Bool) {
        let fromSettings = settings.rev > 0
        let list = fromSettings ? GroupShapes.cameraCodecs(settings: settings) : policy?.camera
        let backupWord = fromSettings ? settings.word("camera.backup") : policy?.backup
        let codec = CallCodecs.roomPublishCodec(caps, encrypted: encrypted, onMesh: onMesh, policy: list)
        cameraCodec = VideoCodec.from(name: codec) ?? .vp8
        cameraBackup = CallCodecs.roomBackupCodec(codec, encrypted: encrypted, policy: backupWord).flatMap { VideoCodec.from(name: $0) }
        cameraHardware = caps.families["video/" + codec.uppercased()]?.enc.hw ?? false
    }

    /// How long a camera changing codec is shown so at most: the media server's `tune.failsafeS`, from its settings
    /// once a document is in use, else from its policy.
    private static func failsafe(_ settings: MeshSettings, policy: MeshCodecPolicy?) -> TimeInterval {
        CameraSwitch.failsafe(tune: settings.rev > 0 ? settings.number("tune.failsafeS") : CameraSwitch.tune("failsafeS", of: policy))
    }

    /// The media server's settings changed during the call: the camera's codecs for its next publish and the
    /// failsafe of a camera changing codec; and a revision with `applyNow` re-publishes the camera, at this device's
    /// moment in the next minute (`MeshSettings.republishDelay`). On the main queue.
    private func settingsChanged(_ settings: MeshSettings, _ changed: Set<String>) {
        guard state != .ended, let caps = codecCaps else { return }
        let policy = room.meshCodecPolicy
        useCodecs(policy, settings: settings, caps: caps, onMesh: onMesh)
        cameraSwitch.failsafe = Self.failsafe(settings, policy: policy)
        CallCodecs.dropSettings = settings

        // a camera that went out under other publish settings than these: one published at this join, or since,
        // already has them
        guard settings.applyNow, GroupShapes.touchesPublish(changed), let print = cameraPrint, print != GroupShapes.cameraPrint(settings)
        else { return }
        settingsRepublish?.cancel()
        let delay = MeshSettings.republishDelay(identity: room.localParticipant.identity?.stringValue ?? "")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state != .ended else { return }
            self.settingsRepublish = nil
            Task { await self.republishCamera() }
        }
        settingsRepublish = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Rings someone into this group call, one made from a call between two people: they arrive in `people` once they
    /// answer. Takes a token from the app's own server, `callToken( user, to, { into: group.ref } )`, which decided they may
    /// be added, or a user id, which a rule of the app's decides. Throws its code: `not_a_call` for any other room, `forbidden`
    /// for a token made for another call, or the app's server's or the realtime server's refusal.
    @MainActor
    public func add(_ who: String) async throws -> CallInvite {
        guard let link else { throw CallError("not_a_call") }
        guard state != .ended else { throw CallError("ended") }
        return try await owner.addTo(link, who: who)
    }

    /// What the app sends its route to ring someone into this call: `realtime.callToken( user, to, { into: ref } )`. Nil for
    /// a group call that wasn't made from a call between two, which takes nobody that way.
    public var ref: String? { link.map(CallTokens.ref(of:)) }

    /// The rings into this group call this app heard of, still ringing or ended. On the main queue.
    public var invites: [CallInvite] {
        guard let link else { return [] }
        return owner.invites(of: link.id)
    }

    /// Someone is rung into this group call. On the main queue.
    func invited(_ invite: CallInvite) {
        guard state != .ended else { return }
        inviteHandlers.fire(invite)
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
        frontCamera.toggle()
        Task { _ = try? await capturer?.switchCameraPosition() }
    }

    /// Whether the camera sent is the front one, or while none is sent, the one that opens next.
    public private(set) var frontCamera = true

    /// The side the next camera opens on, while none is sent: a camera on turns round with `flipCamera()`. Nothing opens.
    public func preferCamera(front: Bool) {
        guard !cameraOn else { return }
        frontCamera = front
    }

    /// How loud this app's microphone is while it is sent, from 0 to 1, for a meter: nil while it is not.
    public var microphoneLevel: Float? {
        guard microphoneOn, room.localParticipant.isMicrophoneEnabled() else { return nil }
        return room.localParticipant.audioLevel
    }

    /// The LiveKit room, for the SDK's call screens (WordPlusRealtimeUI), which draw everyone's tracks from it.
    @_spi(WordPlusUI) public var liveKitRoom: LiveKit.Room { room }

    /// The calls it is one of, for whom the screen offers to add.
    @_spi(WordPlusUI) public var calls: RealtimeCalls { owner }

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
        // H.264 from hardware with VP8 behind it, VP8 alone in an encrypted room, until the media server's settings or
        // policy say otherwise once joined. The join names, as the browser's does, the codecs this device encodes and
        // decodes in hardware, and this package; its timeouts, reconnect waits and budget are the settings this device
        // last had from the server (the schema's defaults, the browsers', on a first call).
        let caps = CallMedia.shared.codecCaps
        let onMesh = CallCodecs.onMesh(server)
        let admin = Self.admin(of: token)
        await MainActor.run {
            grantedAdmin = admin
            codecCaps = caps
            self.onMesh = onMesh
            useCodecs(nil, settings: .none, caps: caps, onMesh: onMesh)
        }
        let connectOptions = GroupShapes.connectOptions(settings: GroupShapes.cached(server), iceServers: ice, caps: caps) { [weak self] wait in
            DispatchQueue.main.async { self?.heardWait(CallWait(wait)) }
        }
        room.setMeshSettingsHandler { [weak self] settings, changed in
            DispatchQueue.main.async { self?.settingsChanged(settings, changed) }
        }
        try await room.connect(url: server, token: token, connectOptions: connectOptions, roomOptions: options)
        let left = await MainActor.run { state == .ended }
        if left {
            await room.disconnect()
            return
        }
        let settings = room.meshSettings
        let policy = room.meshCodecPolicy
        await MainActor.run {
            useCodecs(policy, settings: settings, caps: caps, onMesh: onMesh)
            // A camera changing codec is shown so for the node's failsafe at most.
            cameraSwitch.failsafe = Self.failsafe(settings, policy: policy)
            CallCodecs.dropSettings = settings
        }
        if microphoneOn { await publishMicrophone(true) }
        if cameraOn { await publishCamera(true) }
        await MainActor.run {
            setState(.connected)
            refresh()
            // A spotlight already on as this app joins, as the room had it.
            let spotlight = self.spotlight
            if !spotlight.isEmpty { spotlightHandlers.fire(spotlight) }
            // The rules and the hands up, as the room has them: said once as it joins, then as they change.
            roomStateChanged(joining: true)
            lookAtMicCeilingNext()
        }
    }

    /// The next reading of the upload, twice within the wait the ceiling holds one for. On the main queue.
    private func lookAtMicCeilingNext() {
        micLook?.cancel()
        micLook = nil
        guard state != .ended else { return }
        let look = DispatchWorkItem { [weak self] in
            self?.reviewMicCeiling()
            self?.lookAtMicCeilingNext()
        }
        micLook = look
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: look)
    }

    /// The microphone under its ceiling on a slow upload (`CallMicCeiling`, with a room's marks), as the browsers'
    /// `watchRoomMic` keeps theirs: the estimate read off the statistics of the video going out, which is what the ceiling
    /// waits for; and with no video going out, on its node's count of it lost alone, from which it stays down while it is
    /// alone. While it is down each reading asks it of the track again, so a reconnect's new sender comes down too.
    ///
    /// The same readings carry two things more, as the browsers' do. Once the microphone is down and the sound still
    /// suffers while the person talks, the camera gives way a step at a time and comes back as the sound holds
    /// (`CallPictureSteps`). And the connection it all goes out on is judged for a jam (`CallUploadJam`), told through
    /// `onUploadJam`. On the main queue.
    private func reviewMicCeiling() {
        let publications = room.localParticipant.localVideoTracks
        let video = publications.compactMap { $0.track }
        let cameras = Set(publications.filter { $0.source == .camera }.compactMap { $0.track.map(ObjectIdentifier.init) })
        let mic = room.localParticipant.localAudioTracks.first { $0.source == .microphone }?.track

        // Each track asked once: its reports run on from there.
        let fresh = (video + [mic].compactMap { $0 }).filter { !micAsked.contains($0) }
        if !fresh.isEmpty {
            for track in fresh { micAsked.add(track) }
            Task { for track in fresh { await track.set(reportStatistics: true) } }
        }

        var estimate: Int?
        var videoSending = false
        var cameraSending = false
        var heldBack = false
        var videoPackets: Int64 = 0
        var videoDelay = 0.0
        var pair: IceCandidatePairStatistics?

        // The pair a track's connection sends on.
        func selected(_ statistics: TrackStatistics) -> IceCandidatePairStatistics? {
            let id = statistics.transportStats?.selectedCandidatePairId

            return statistics.iceCandidatePair.first { $0.id == id } ?? statistics.iceCandidatePair.first { $0.nominated == true }
        }

        for track in video {
            guard let statistics = track.statistics else { continue }

            for stream in statistics.outboundRtpStream {
                let frames = stream.framesEncoded ?? 0

                if frames > micFrames[stream.id] ?? 0 {
                    videoSending = true
                    if cameras.contains(ObjectIdentifier(track)) { cameraSending = true }
                }

                micFrames[stream.id] = frames
                videoPackets += Int64(stream.packetsSent ?? 0)
                videoDelay += stream.totalPacketSendDelay ?? 0

                // A layer paused for want of viewers says nothing of the upload.
                if stream.active != false, stream.qualityLimitationReason == .bandwidth { heldBack = true }
            }

            if let its = selected(statistics) {
                pair = its
                if let available = its.availableOutgoingBitrate { estimate = Int(available) }
            }
        }

        let now = Date()
        let micOut = mic?.statistics?.outboundRtpStream.first
        // What the node says of the microphone: lost, or asked for again, which goes up the same upload.
        let heard = micLoss.hearing(
            now: now,
            sent: micOut?.packetsSent.map { Int64($0) },
            missed: mic?.statistics?.remoteInboundRtpStream.first?.packetsLost.map { $0 + Int64(micOut?.retransmittedPacketsSent ?? 0) },
            bytes: micOut?.bytesSent.map { Int64($0) + Int64(micOut?.headerBytesSent ?? 0) }
        )
        let lossy = heard.lossy
        let queued = micLoss.queued(packets: videoPackets, delay: videoDelay)

        if pair == nil, let statistics = mic?.statistics { pair = selected(statistics) }

        // A camera whose viewers want little sends little, and its estimate reads low on an open line: only video the upload holds back counts, or one it queues, or a microphone it can't carry.
        // Down for its own loss, or its video's queue, it stays down until the estimate is clear of the mark or the video stops: coming down ends them.
        // Alone, there is no estimate to read (0 stands under every mark): its loss brings it down, and having come down alone keeps it there.
        // Beside video, sound lost past what its spare copy hides is answered sooner: the video can give the room back, a line alone can't.
        let moved = videoSending
            ? micCeiling.review(now: now, estimate: estimate, videoSending: heldBack || queued || lossy || micDownForLoss || micDownAlone, downHold: heard.heavy ? CallMicCeiling.heavyHold : CallMicCeiling.hold)
            : micCeiling.review(now: now, estimate: 0, videoSending: lossy || micDownAlone)

        if moved {
            micDownAlone = micCeiling.lowered && (micDownAlone || !videoSending)
            micDownForLoss = micCeiling.lowered && (queued || lossy)
        }

        let top = (room.meshSettings.int("mic.kbps") ?? 64) * 1000
        let bitrate = micCeiling.lowered ? min(CallMicCeiling.slowBitrate, top) : top
        let bwe = estimate.map { "\($0 / 1000)k" } ?? "-"

        if moved { CallLog.write("room microphone ceiling \(bitrate / 1000)k: bwe out=\(bwe)") }

        if moved || micCeiling.lowered {
            for publication in room.localParticipant.localAudioTracks where publication.source == .microphone {
                guard let track = publication.track as? LocalAudioTrack else { continue }

                Task { await track.setMeshMaxBitrate(bitrate) }
            }
        }

        // The picture's turn comes once the microphone has given what it can: the person talking, the camera going out,
        // and the sound still lost or still waiting behind the video. A step down goes to the first step the estimate
        // says the line carries beside what the microphone puts on it, which, having just come down, is the share of
        // what it did that its new ceiling is of its old.
        let troubled = lossy || queued
        let down = moved && micCeiling.lowered
        let wire = heard.wire.map { down && top > 0 ? $0 * Double(bitrate) / Double(top) : $0 }
        let left: Double? = estimate.flatMap { estimate in wire.map { (Double(estimate) * CallPictureSteps.fit - $0) / 1000 } }
        let fitting = CallPictureSteps.fitting(camera: cameraSending, kbps: left)
        let talking = cameraSending && heard.talking
        let reading: CallPictureSteps.Reading = !talking ? .idle : !troubled ? .clean : micCeiling.lowered ? .suffering : .idle
        let stepped = (down && heard.heavy && talking && picture.giveWay(now: now, fitting: fitting)) || picture.review(now: now, reading: reading, fitting: fitting)

        if stepped {
            let caps = GroupShapes.cameraCap(cameraCodecCap, step: picture.step)

            CallLog.write("room picture for the sound: step \(picture.step): bwe out=\(bwe)")
            Task { await room.setProductCameraCaps(caps) }
        }

        guard let pair = pair else { return }

        let jam = CallUploadJam.Reading(at: now, rtt: pair.currentRoundTripTime, requests: pair.requestsSent ?? pair.consentRequestsSent, responses: pair.responsesReceived, bytesReceived: pair.bytesReceived)

        if uploadJam.review(jam) {
            uploadJammed = uploadJam.jammed
            CallLog.write(uploadJammed ? "room upload jammed" : "room upload no longer jammed")
            jamHandlers.fire(uploadJammed)
        }
    }

    /// Everyone else in the room, read again, their info opened with the app's keys.
    private func refresh() {
        // The cameras whose next frame ends a switch, with the tracks read here.
        watchCameraSwitches()
        let here = room.remoteParticipants.values.compactMap(person)
        // The tiles kept for those who may come back, unless the room has them again.
        let kept = away.values.map(\.person).filter { kept in !here.contains { $0.identity == kept.identity } }
        people = (here + kept).sorted { $0.identity < $1.identity }
        peopleHandlers.fire()
    }

    /// The rules and the hands, each said when it changed, or as the room joins. On the main queue.
    func roomStateChanged(joining: Bool = false) {
        guard state != .ended else { return }
        let rules = self.rules
        if joining || rules != saidRules {
            saidRules = rules
            rulesHandlers.fire(rules)
        }
        let hands = GroupRoomState.hands(of: room.metadata)
        if joining || hands != saidHands {
            saidHands = hands
            handsHandlers.fire(Self.users(of: hands))
            // A tile's raised hand is room state too.
            refresh()
        }
    }

    /// Someone left: their tile kept, marked reconnecting and with no media, while they may come back, else gone now
    /// (`CallAway`). On the main queue.
    func departed(_ person: GroupPerson, reason: Int?, now: Date = Date()) {
        guard state != .ended else { return }
        let identity = person.identity
        let wait = CallAway.awayFor(reason, onMesh: onMesh, byeAt: byes[identity], now: now)
        forgetAway(identity)
        cameraSwitch.left(identity)
        // whatever was said of their media went with their session
        readStalls(room.meshSourcesDry)
        guard wait > 0 else { return refresh() }
        var kept = GroupPerson(identity: identity, user: person.user, info: person.info, camera: false, microphone: false, speaking: false, screen: false, publish: person.publish)
        kept.quality = person.quality
        kept.micHeld = person.micHeld
        kept.reconnecting = true
        let look = DispatchWorkItem { [weak self] in self?.awayOver(identity) }
        away[identity] = (kept, look)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: look)
        refresh()
        awayHandlers.fire(kept)
    }

    /// The wait for someone away is over: gone, unless the room is getting its own connection back, which doesn't know
    /// who is in it until it is, so the wait starts over.
    private func awayOver(_ identity: String) {
        guard state != .ended, let entry = away[identity] else { return }
        if state == .reconnecting {
            let look = DispatchWorkItem { [weak self] in self?.awayOver(identity) }
            away[identity] = (entry.person, look)
            DispatchQueue.main.asyncAfter(deadline: .now() + CallAway.wait, execute: look)
            return
        }
        away[identity] = nil
        refresh()
    }

    /// Someone kept away is back in the room: their tile is theirs again.
    func back(_ identity: String) {
        forgetAway(identity)
        byes[identity] = nil
    }

    private func forgetAway(_ identity: String) {
        away[identity]?.look.cancel()
        away[identity] = nil
    }

    /// Someone said they hang up (`realtime-bye`): a departure soon after goes at once, and a tile already kept goes
    /// now. On the main queue.
    func heardBye(from identity: String, at now: Date = Date()) {
        guard state != .ended else { return }
        byes[identity] = now
        guard away[identity] != nil, !room.remoteParticipants.values.contains(where: { $0.identity?.stringValue == identity }) else { return }
        forgetAway(identity)
        refresh()
    }

    /// The people kept away, by identity, for the tests.
    var awayIdentities: [String] { away.keys.sorted() }

    /// Whose media stopped reaching the media server, as the mesh says it now: each sender whose verdict changed,
    /// told. On the main queue.
    func readStalls(_ dry: Set<String>) {
        guard state != .ended else { return }
        var streams: [StallWatch.Stream] = []
        for participant in room.remoteParticipants.values {
            guard let who = participant.identity?.stringValue else { continue }
            for publication in participant.trackPublications.values {
                guard publication.source == .camera || publication.source == .microphone, publication.track != nil else { continue }
                let remote = publication as? RemoteTrackPublication
                // muted on their side, turned off here (a hidden tile) or paused for this app's download: held back
                let expected = publication.isSubscribed && !publication.isMuted && (remote?.isEnabled ?? true) && publication.streamState != .paused
                streams.append(.init(who: who, camera: publication.source == .camera, id: publication.sid.stringValue, expected: expected))
            }
        }
        let changed = stalls.read(streams, dry: dry)
        guard !changed.isEmpty else { return }
        refresh()
        for who in changed.keys {
            guard let person = people.first(where: { $0.identity == who && !$0.reconnecting }) else { continue }
            stalledHandlers.fire(person)
        }
    }

    /// What came over the room on a topic of the SDK's: the realtime server's ask (sent with no participant: never one a
    /// person sent), an answer to this app's ask from the person asked, someone's bye. On the main queue.
    func received(_ data: Data, from identity: String?, topic: String) {
        guard state != .ended else { return }
        switch topic {
        case GroupRoomState.byeTopic:
            if let identity { heardBye(from: identity) }
        case GroupRoomState.askTopic:
            guard identity == nil, let ask = GroupRoomState.ask(data) else { return }
            askHandlers.fire(ask)
        case GroupRoomState.askAnswerTopic:
            guard let identity, let answer = GroupRoomState.answer(data, from: identity) else { return }
            askAnswerHandlers.fire(answer)
        default:
            break
        }
    }

    /// The bye, as Better Messages' call screen sends it: never held long, as the hang-up goes on whatever becomes of
    /// it. It goes over the data channel and the leave over the signal connection, and the media server drops a bye the
    /// leave overtakes, so a sent bye gets 200 ms before the leave.
    private static func sayBye(_ room: LiveKit.Room) async {
        let sent = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                do {
                    try await room.localParticipant.publish(data: Data("1".utf8), options: DataPublishOptions(topic: GroupRoomState.byeTopic, reliable: true))
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if sent { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    /// Someone in the room as `people` and `me` tell them.
    private func person(_ participant: Participant) -> GroupPerson? {
        guard let identity = participant.identity?.stringValue else { return nil }
        let user = identity.hasPrefix("user_") ? String(identity.dropFirst(5)) : nil
        let sealed = participant.metadata.flatMap(JSONValue.parse) ?? .null
        let tracks = participant.trackPublications.values
        // The camera of theirs that has arrived here, which ends a switch once it is not the old one.
        let arrived = tracks.first { $0.source == .camera && !$0.isMuted && $0.track != nil }?.sid.stringValue
        return GroupPerson(
            identity: identity,
            user: user,
            info: owner.rt.keyring.openJSON(sealed) ?? .null,
            camera: tracks.contains { $0.source == .camera && !$0.isMuted },
            microphone: tracks.contains { $0.source == .microphone && !$0.isMuted },
            speaking: participant.isSpeaking,
            screen: tracks.contains { $0.source == .screenShareVideo && !$0.isMuted },
            publish: participant.permissions.canPublish,
            optimizing: cameraSwitch.awaiting(identity, camera: arrived),
            quality: CallConnectionQuality(participant.connectionQuality),
            stalled: participant is LocalParticipant ? nil : stalls.of(identity),
            micHeld: GroupRoomState.holdsMic(publish: participant.permissions.canPublish, sources: Array(participant.permissions.canPublishSources))
        )
    }

    private func setState(_ next: GroupCallState) {
        guard state != next, state != .ended else { return }
        state = next
        if next != .connecting { waiting = nil }
        stateHandlers.fire(next)
    }

    /// A join waiting for a place on the mesh, as the room client tells it. On the main queue.
    func heardWait(_ wait: CallWait) {
        guard state == .connecting else { return }
        waiting = wait
        waitingHandlers.fire(wait)
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
        // A hang-up from a room still up tells the others first (the bye), so they drop this tile at once.
        let bye = reason == "left" && state == .connected
        for entry in away.values { entry.look.cancel() }
        away.removeAll()
        byes.removeAll()
        stalls.clear()
        cameraSwitchLook?.cancel()
        cameraSwitchLook = nil
        settingsRepublish?.cancel()
        settingsRepublish = nil
        micLook?.cancel()
        micLook = nil
        uploadJammed = false
        for ear in cameraSwitchEars.values { ear.track.remove(videoRenderer: ear.ear) }
        cameraSwitchEars.removeAll()
        endReason = reason
        state = .ended
        waiting = nil
        let room = room
        Task {
            if bye { await Self.sayBye(room) }
            await room.disconnect()
        }
        stateHandlers.fire(.ended)
        endHandlers.fire(reason)
    }
}

extension GroupCall: RoomDelegate {
    public func room(_ room: LiveKit.Room, participantDidConnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue
        DispatchQueue.main.async {
            // Someone kept away is back: their tile is theirs again.
            if let identity { self.back(identity) }
            self.refresh()
        }
    }

    public func room(_ room: LiveKit.Room, participant: Participant, didUpdateConnectionQuality quality: ConnectionQuality) {
        let local = participant is LocalParticipant
        DispatchQueue.main.async {
            guard self.state != .ended else { return }
            if local { self.qualityHandlers.fire(CallConnectionQuality(quality)) } else { self.refresh() }
        }
    }

    public func room(_ room: LiveKit.Room, participantDidDisconnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue
        let reason = participant.disconnectReason
        DispatchQueue.main.async {
            guard let identity else { return self.refresh() }
            // Gone, or away and maybe coming back (CallAway): their switch goes with them either way.
            let person = self.person(participant) ?? GroupPerson(identity: identity, user: nil, info: .null, camera: false, microphone: false, speaking: false, screen: false, publish: false)
            self.departed(person, reason: reason)
        }
    }

    /// The web's call screen says its camera is changing codec, and when it is back (`CameraSwitch.topic`). The
    /// realtime server's asks, an answer to this app's, and someone's bye (`received`).
    public func room(_ room: LiveKit.Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        if topic == GroupRoomState.askTopic || topic == GroupRoomState.askAnswerTopic || topic == GroupRoomState.byeTopic {
            let identity = participant?.identity?.stringValue
            DispatchQueue.main.async { self.received(data, from: identity, topic: topic) }
            return
        }
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

    public func room(_ room: LiveKit.Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        guard publication.source == .screenShareVideo else { return }
        DispatchQueue.main.async { self.screenHandlers.fire(true) }
    }

    public func room(_ room: LiveKit.Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        guard publication.source == .screenShareVideo else { return }
        DispatchQueue.main.async { self.screenHandlers.fire(false) }
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

    /// A host's spotlight, kept in the room's metadata by the realtime server (its `spotlight`).
    public func room(_ room: LiveKit.Room, didUpdateMetadata metadata: String?) {
        let spotlight = GroupCall.spotlight(of: metadata)
        DispatchQueue.main.async {
            guard self.state != .ended else { return }
            self.spotlightHandlers.fire(spotlight)
            // The room's rules and the hands up, kept beside it.
            self.roomStateChanged()
        }
    }

    /// The media server says a recording of the room began or ended (`isRecording`).
    public func room(_ room: LiveKit.Room, didUpdateIsRecording isRecording: Bool) {
        DispatchQueue.main.async {
            guard self.state != .ended else { return }
            self.recordingHandlers.fire(isRecording)
        }
    }

    public func room(_ room: LiveKit.Room, participant: Participant, didUpdatePermissions permissions: ParticipantPermissions) {
        let local = participant is LocalParticipant
        DispatchQueue.main.async {
            guard self.state != .ended else { return }
            guard local else { return self.refresh() }
            // The room's permissions say it from here on: a change once in, not the first word as it connects.
            if self.state == .connected || self.state == .reconnecting { self.heldAtJoin = false }
            // The media server took down what it sent: nothing is sent again on a reconnect.
            if !permissions.canPublish {
                self.microphoneOn = false
                self.cameraOn = false
            }
            let can = GroupCall.permissions(permissions, admin: self.grantedAdmin, heldAtJoin: self.heldAtJoin)
            // A host holds the microphone off: it stops, and once let go the person turns it on again themselves.
            if can.micHeld, self.microphoneOn {
                self.microphoneOn = false
                SystemCalls.shared.microphone(false, group: self)
                Task { await self.publishMicrophone(false) }
            }
            self.permissionHandlers.fire(can)
        }
    }

    public func room(_ room: LiveKit.Room, trackPublication: TrackPublication, didUpdateE2EEState state: E2EEState) {
        guard GroupCall.encryptionFailed(state) else { return }
        fail(GroupCallFailure(code: "encryption_failed", message: state.toString()))
    }

    public func room(_ room: LiveKit.Room, didStartReconnectWithMode reconnectMode: ReconnectMode) {
        DispatchQueue.main.async { self.setState(.reconnecting) }
    }

    public func room(_ room: LiveKit.Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        DispatchQueue.main.async { self.setState(.connected) }
    }

    public func room(_ room: LiveKit.Room, didDisconnectWithError error: LiveKitError?) {
        let reason = GroupCall.endReason(error?.type)
        DispatchQueue.main.async { self.finish(reason) }
    }

    /// Why the room let this app go, as `onEnded` says it: `removed` when the app's server took it out (`remove`, the
    /// media server's PARTICIPANT_REMOVED), `closed` when it ended the call for everyone (`end`, ROOM_DELETED), else
    /// `disconnected`, as the browser's group calls say them (realtime-client a738a57, disconnectedBy).
    static func endReason(_ type: LiveKitErrorType?) -> String {
        switch type {
        case .participantRemoved: return "removed"
        case .roomDeleted: return "closed"
        default: return "disconnected"
        }
    }

    /// What kind of error kept a room from joining, for a call's account: its code alone, as its message may name the server.
    static func failureName(_ error: Error) -> String {
        (error as? LiveKitError).map { "error \($0.type.rawValue)" } ?? "\(type(of: error))"
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
