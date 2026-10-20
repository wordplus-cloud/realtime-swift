import UIKit
import LiveKit

// What Better Messages' native call screens (the Bm* files beside this one, moved from its bm-calls plugin at
// 5c61cf0d, unchanged) ask of the app they are in, answered here under the names they use, so they stay the same files
// as Better Messages' and a fix travels between the two as it is.
// CallScreen fills these from the SDK's calls; Better Messages' app fills its own from its engine.

/// The settings the screens read: the strings in the user's language by key, the design tokens (light and dark),
/// dark mode, and whether the microphone and camera wear their state or their action.
struct BmCallsConfig {
    var strings: [String: String] = [:]
    var designTokens: [String: String] = [:]
    var designTokensDark: [String: String] = [:]
    var darkMode = false
    var iconsReverted = true
}

enum BmCallsConfigStore {
    static var current: BmCallsConfig?
}

/// One of the dock's buttons as the host may arrange them: ours by their id (`answer`, `settings`, `flip`, `camera`,
/// `mute`, `speaker`, `pip`, `share`, `hand`, `people`, `end`), with the view the screen built, or one of the host's own.
struct BmCallsControl {
    let id: String
    let view: UIView
}

/// The pieces a host draws in place of the screens' own: each nil keeps ours.
/// CallScreen fills them from an app's `CallScreen.Pieces`; Better Messages' app gives none.
struct BmCallsPieces {
    /// The dock's buttons in their order, given ours in theirs and the call's phase: the buttons to show.
    var controls: ( ( _ ours: [ BmCallsControl ], _ phase: String ) -> [ BmCallsControl ] )?
    /// The status line under the name, given the phase and the time the call has run (seconds): nil for ours.
    var status: ( ( _ phase: String, _ seconds: Int ) -> String? )?
    /// A view over someone's tile in a group call, filling it: nil for none. The same view again stays where it is.
    var tile: ( ( BmCallsRoomParticipant ) -> UIView? )?
    /// A view over the stage of a call between two, filling it, given the phase: nil for none.
    var stage: ( ( _ phase: String ) -> UIView? )?
}

enum BmCallsPiecesStore {
    static var current = BmCallsPieces()
}

/// The call as the screens' moderation reads it: the room's mode, whether it is locked or muted, whether this user may
/// moderate it, and the actions it sends (`raise_hand`, `mute_all`, …). An app on the SDK's calls has no moderation:
/// the actions answer false and none is offered.
final class BmCallsEngine {
    static let shared = BmCallsEngine()

    var callMode = "participatory"
    var roomLocked = false
    var roomMuted = false
    var canModerate = false
    var onGroupAdmin: ( ( _ action: String, _ identity: String, _ completion: ( ( Bool ) -> Void )? ) -> Void )?

    func groupAdmin( action: String, identity: String = "", completion: ( ( Bool ) -> Void )? = nil ) {
        if let handler = onGroupAdmin {
            handler( action, identity, completion )
        } else {
            completion?( false )
        }
    }

    /// A debug build's way through the roster's layouts in Better Messages; nothing here.
    func cycleDebugRoster() {}
}

/// Where the screens' lines go: the app's own log, when it gives one (CallScreen.log).
enum BmCallsLog {
    static var sink: ( ( String ) -> Void )?

    static func write( _ message: String ) {
        sink?( message )
    }
}

/// What a track carries.
enum BmCallsSource: String, CaseIterable {
    case camera
    case microphone
    case screenShare = "screen_share"
    case screenShareAudio = "screen_share_audio"

    var isVideo: Bool {
        self == .camera || self == .screenShare
    }

    static let order: [BmCallsSource] = [ .camera, .microphone, .screenShare, .screenShareAudio ]
}

/// Someone in a group call, as the grid and the panel draw them.
struct BmCallsRoomParticipant {
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
    let isPinned: Bool
    let canPublish: Bool
    let canAdmin: Bool
    /// `participant` or `viewer`.
    let mode: String
    /// The room says this person has lost their connection to it.
    let lost: Bool
}

/// The picture sizes a view asks the sender for: the same rungs Better Messages' engine sends at.
enum BmCallsShapes {
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
