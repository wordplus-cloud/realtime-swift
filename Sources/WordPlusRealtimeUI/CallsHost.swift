import UIKit
import LiveKit
import AVFoundation

// What the call screens (the Calls* files beside this one) ask of the app they are in, answered here under the names
// they use. CallScreen fills these from the SDK's calls. An app with a call engine of its own that takes the screens'
// files answers the same names from its engine instead of this file, so the screens stay the same files in both.

/// The settings the screens read: the strings in the user's language by key, the design tokens (light and dark),
/// dark mode, and whether the microphone and camera wear their state or their action.
struct CallsConfig {
    var strings: [String: String] = [:]
    var designTokens: [String: String] = [:]
    var designTokensDark: [String: String] = [:]
    var darkMode = false
    var iconsReverted = true
}

enum CallsConfigStore {
    static var current: CallsConfig?
}

/// One of the dock's buttons as the host may arrange them: ours by their id (`answer`, `chat`, `settings`, `flip`,
/// `camera`, `mute`, `speaker`, `pip`, `share`, `add`, `hand`, `host`, `end`), with the view the screen built, or one of
/// the host's own. `chat` shows only where the host gives the screen a chat toggle (`onToggleChat`), `add` only where it
/// gives whom to add (`CallsAddPersonStore`).
struct CallsControl {
    let id: String
    let view: UIView
}

/// The pieces a host draws in place of the screens' own: each nil keeps ours.
/// CallScreen fills them from an app's `CallScreen.Pieces`.
struct CallsPieces {
    /// The dock's buttons in their order, given ours in theirs and the call's phase: the buttons to show.
    var controls: ( ( _ ours: [ CallsControl ], _ phase: String ) -> [ CallsControl ] )?
    /// The status line under the name, given the phase and the time the call has run (seconds): nil for ours.
    var status: ( ( _ phase: String, _ seconds: Int ) -> String? )?
    /// A view over someone's tile in a group call, filling it: nil for none. The same view again stays where it is.
    var tile: ( ( CallsRoomParticipant ) -> UIView? )?
    /// A view over the stage of a call between two, filling it, given the phase: nil for none.
    var stage: ( ( _ phase: String ) -> UIView? )?
}

enum CallsPiecesStore {
    static var current = CallsPieces()
}

/// The call as the screens' moderation reads it: the room's mode, whether it is locked or muted, whether this user may
/// moderate it, and the actions it sends (`raise_hand`, `mute_all`, …). On the SDK's calls CallScreen answers them from
/// a group call the app's server names, whose host (its rule's `admin`) mutes a microphone, lets speak, makes a
/// listener and removes, each through the app's calls route (`GroupCall.moderate`). Every other action answers false.
final class CallsEngine {
    static let shared = CallsEngine()

    var callMode = "participatory"
    var roomLocked = false
    var roomMuted = false
    var canModerate = false
    /// Whether the call carries the room's own rules, which Host Controls offers a moderator: Mute Everyone, Lock Room,
    /// Broadcast Mode, raised hands and their sound, Lower All Hands. The SDK's calls carry them where the call offers
    /// `rules` (`GroupCall.acts`, which the realtime server and the app's package both name), from the room's state.
    var carriesRoomRules = false

    /// The acts the call offers, by the protocol's names (`remove`, `ban`, `listen`, `speak`, `mute`, `hold_mic`,
    /// `release_mic`, `rules`, `hand`, `ask`, `end`, `spotlight`): the moderation menus show a row only for an act named
    /// here. Nil, an engine of its own that takes every row the screens have (Better Messages' app), as before.
    var offers: Set<String>?

    /// Whether the call offers an act: always where the engine names none (`offers` nil).
    func offersAct( _ act: String ) -> Bool {
        offers?.contains( act ) ?? true
    }

    /// Whether the call keeps raised hands, which a moderator lowers (Lower Hand, Lower All Hands): the SDK's where it
    /// offers `hand`, any other engine's with the room's rules.
    var carriesHands: Bool {
        offers.map { $0.contains( "hand" ) } ?? carriesRoomRules
    }

    /// Remove and Ban from Calls for a moderator, where the call offers `ban` (CallsBan): the person goes now and their
    /// joins are refused for `minutes`. CallScreen answers it from `GroupCall.ban`. Nil refuses.
    var onBan: ( ( _ identity: String, _ minutes: Int, _ completion: @escaping ( Bool ) -> Void ) -> Void )?

    func ban( identity: String, minutes: Int, completion: @escaping ( Bool ) -> Void ) {
        guard let onBan else { return completion( false ) }

        onBan( identity, minutes, completion )
    }
    /// Whether the call is a video one: the moderation menus name a camera only there, and pin and spotlight only there.
    var isVideo = true
    /// `identities`: the people Mute Everyone and its undo mean, everyone but the moderators.
    var onGroupAdmin: ( ( _ action: String, _ identity: String, _ identities: [ String ], _ completion: ( ( Bool ) -> Void )? ) -> Void )?

    func groupAdmin( action: String, identity: String = "", identities: [ String ] = [], completion: ( ( Bool ) -> Void )? = nil ) {
        if let handler = onGroupAdmin {
            handler( action, identity, identities, completion )
        } else {
            completion?( false )
        }
    }

    /// Device Settings' tests, the user's alone (CallsDevices): the camera's preview and the microphone's level. An
    /// engine that cannot run one without disturbing its call says false, and the panel offers no test for it.
    var testsCamera = true

    /// The microphone's test records into the session as the call has it and never sets it up, so it is offered only
    /// while the session is set for recording.
    var testsMicrophone: Bool {
        let category = AVAudioSession.sharedInstance().category

        return category == .playAndRecord || category == .record
    }

    /// The level the call sends the microphone at while it does, 0…1, for Device Settings' meter where the roster
    /// has no level of this side's (a call between two): nil for none, unless a reading is given.
    var onMicrophoneLevel: ( () -> Float? )?

    func microphoneLevel() -> Float? {
        onMicrophoneLevel?()
    }

    /// The camera chosen in Device Settings while the call's own is off: the side the next camera opens on. Nothing
    /// opens here.
    var onPreferCamera: ( ( Bool ) -> Void )?

    func preferCamera( front: Bool ) {
        onPreferCamera?( front )
    }

    /// A group call is joined with the camera and the microphone off and says so over the dock (the join notice).
    var devicesOnJoin = false

    /// The user's own choice about the join notice, where the host keeps one (the web's `joinNotice`): nil keeps none,
    /// and the notice offers no Do Not Show Again; false, said with it, and the notice no longer shows.
    var joinNotice: Bool? = nil

    /// Do Not Show Again on the join notice: the host keeps the user's choice where the app keeps their settings.
    func joinNoticeNever() {}

    /// Whether this user may end the call for everyone (Host Controls' End for Everyone). The SDK's calls offer it to a
    /// host where the call offers `end`.
    var canEndForEveryone = false

    /// A moderator's asks that someone turn on their camera or microphone (CallsAsks): where the call carries them, a
    /// person's menu offers them (groupAdmin's `ask_camera`, `ask_microphone`, `ask_camera_microphone`), and the state
    /// names the asks this user was sent (`asks`: id, device, by, the oldest first) and the answers to this user's own
    /// (`askAnswers`: id, from, device, answer, the newest last). The SDK's calls carry them where the call offers `ask`.
    var carriesAsks = false

    /// What `answerAsk` and `dismissAsk` do on the SDK's calls, given by CallScreen: nil does nothing.
    var onAnswerAsk: ( ( _ id: String, _ device: String, _ by: String, _ answer: String ) -> Void )?
    var onDismissAsk: ( ( _ id: String, _ device: String ) -> Void )?

    /// This user's answer to an ask (`on`, `not_now`, `blocked`, `no_device`, `busy`), sent to whoever asked alone.
    func answerAsk( id: String, device: String, by: String, answer: String ) {
        onAnswerAsk?( id, device, by, answer )
    }

    /// The ask put away, answered: the engine takes it out of the state's `asks`.
    func dismissAsk( id: String, device: String ) {
        onDismissAsk?( id, device )
    }

    /// What `endForEveryone` does on the SDK's calls, given by CallScreen (`GroupCall.end`): nil refuses.
    var onEndForEveryone: ( ( _ completion: @escaping ( _ ok: Bool, _ error: String? ) -> Void ) -> Void )?

    /// Ends the call for everyone and leaves it: `completion` with false and the error to show where it failed.
    func endForEveryone( completion: @escaping ( _ ok: Bool, _ error: String? ) -> Void ) {
        guard let onEndForEveryone else { return completion( false, nil ) }

        onEndForEveryone( completion )
    }

    /// A group call's recording (CallsRecording), where the engine's state names one (`recording`): the screens show REC,
    /// the notice and the question to stay or leave as the site tells people, and a moderator's Start and Stop. The
    /// engine keeps this user's answer to a recording by its id (`agreed` to the question, `seen` for the notice) and
    /// holds the microphone, camera and screen off while the site asks for that and the answer is not `agreed`. The
    /// SDK's group calls name one where the app's server names the call (`CallRecordingState`), told by a notice, and
    /// keep the answers on the screen alone.
    func answerRecording( id: String, answer: String ) {}

    /// Do Not Show Again on the notice: the engine keeps the user's choice where the app keeps their settings.
    func recordingNoticeNever() {
        UserDefaults.standard.set( true, forKey: Self.recordingNoticeNeverKey )
    }

    /// Whether the notice tells this user of a recording: false after Do Not Show Again, REC alone telling them.
    var recordingNoticeShown: Bool { !UserDefaults.standard.bool( forKey: Self.recordingNoticeNeverKey ) }

    static let recordingNoticeNeverKey = "cloud.wordplus.realtime.calls.recordingNoticeNever"

    /// Starts (`start`) or stops a group call's recording: `completion` with false and the error to show where it
    /// failed. CallScreen answers it from `GroupCall.startRecording` and `stopRecording`. Nil refuses, as nothing records.
    var onRecord: ( ( _ start: Bool, _ completion: @escaping ( _ ok: Bool, _ error: String? ) -> Void ) -> Void )?

    /// A moderator's Start and Stop: `completion` with false and the error to show where it failed.
    func startRecording( completion: @escaping ( _ ok: Bool, _ error: String? ) -> Void ) {
        guard let onRecord else { return completion( false, nil ) }

        onRecord( true, completion )
    }

    func stopRecording( completion: @escaping ( _ ok: Bool, _ error: String? ) -> Void ) {
        guard let onRecord else { return completion( false, nil ) }

        onRecord( false, completion )
    }

    /// Spotlight for Everyone (CallsSpotlight): where the call carries it, a moderator's person menu offers Spotlight for
    /// Everyone and Remove Spotlight in place of Pin Participant, and Host Controls Clear Spotlight while anyone is in
    /// it, each through `spotlight`. Whoever is in it is the state's `spotlight` (identities, in the order they were
    /// spotlighted), which the grid follows wherever an engine names one. The SDK's group calls carry it: CallScreen
    /// says so while one shows, and answers `onSpotlight` from `GroupCall.moderate`.
    var carriesSpotlight = false

    /// What `spotlight` does on the SDK's calls, given by CallScreen: nil does nothing.
    var onSpotlight: ( ( _ identity: String?, _ on: Bool, _ completion: @escaping ( _ ok: Bool, _ error: String? ) -> Void ) -> Void )?

    /// Puts `identity` in the spotlight for everyone (`on`), takes them out of it, or takes everyone out (nil and not
    /// on): `completion` with false and the error to show where it failed.
    func spotlight( identity: String?, on: Bool, completion: @escaping ( _ ok: Bool, _ error: String? ) -> Void ) {
        guard let onSpotlight else { return completion( false, nil ) }

        onSpotlight( identity, on, completion )
    }

    /// A debug build's way through the roster's layouts, for an engine that has one; nothing here.
    func cycleDebugRoster() {}
}

/// Where the screens' lines go: the app's own log, when it gives one (CallScreen.log).
enum CallsLog {
    static var sink: ( ( String ) -> Void )?

    static func write( _ message: String ) {
        sink?( message )
    }
}

/// What a track carries.
enum CallsSource: String, CaseIterable {
    case camera
    case microphone
    case screenShare = "screen_share"
    case screenShareAudio = "screen_share_audio"

    var isVideo: Bool {
        self == .camera || self == .screenShare
    }

    static let order: [CallsSource] = [ .camera, .microphone, .screenShare, .screenShareAudio ]
}

/// Someone in a group call, as the grid and the panel draw them.
struct CallsRoomParticipant {
    let identity: String
    let name: String
    let avatar: String
    let isLocal: Bool
    let video: VideoTrack?
    let screen: VideoTrack?
    let speaking: Bool
    let audioLevel: Float
    let muted: Bool
    /// Muted by a moderator: a rule, so the control that would undo it is not offered.
    let micMuted: Bool
    let handRaised: Bool
    /// Pinned for everyone by a moderator's Pin Participant, where the call has no spotlight or an older app pinned
    /// them: shown as a spotlight (CallsSpotlight).
    let isPinned: Bool
    let canPublish: Bool
    let canAdmin: Bool
    /// `participant` or `viewer`.
    let mode: String
    /// The room says this person has lost their connection to it.
    let lost: Bool
    /// Their camera is changing codec (`CallsCameraSwitch`): the tile keeps
    /// the "Optimizing video quality..." placeholder up, never the look of a
    /// camera turned off, until the room hears the frame that ends it, the
    /// camera turned off or the failsafe.
    var optimizing = false
    /// Away for a moment and held for a return: the tile wears the "Reconnecting..." veil.
    var reconnecting = false
    /// What of theirs stopped arriving while they are still in the call, nil for nothing: the tile blurs it and says
    /// so. The SDK's calls judge none yet.
    var stalled: CallsStalled? = nil
}

/// What of someone's stopped arriving while they are still in a room call: their camera alone, or everything.
enum CallsStalled: String {
    case video
    case all
}

/// The picture sizes a view asks the sender for: the rungs a sender sends at.
enum CallsShapes {
    static let viewSteps = [ 180, 360, 540, 720, 1080, 1440, 2160 ]

    static func viewStep( _ height: Int ) -> Int {
        guard height > 0 else { return 0 }

        return viewSteps.first { $0 >= height } ?? viewSteps[ viewSteps.count - 1 ]
    }

    /// A screen at the pixel it is drawn at, rounded up to an even one.
    static func exactStep( _ height: Int ) -> Int {
        guard height > 0 else { return 0 }

        return Int( ceil( Double( height ) / 2 ) ) * 2
    }
}
