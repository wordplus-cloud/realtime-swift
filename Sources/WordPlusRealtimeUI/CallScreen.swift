import AVFoundation
import UIKit
import LiveKit
import LiveKitWebRTC
import WordPlusRealtime
@_spi(WordPlusUI) import WordPlusRealtimeCalls

/**
 Better Messages' call screen on the SDK's calls: the call ringing in, ringing out, connecting and in progress, the
 other side's picture and one's own in the corner, a group call's grid, and the controls (the microphone, the camera,
 turning it round, the speaker, picture in picture, hanging up), in a window of its own above the app. Optional, as
 the module is: an app that draws its own screens uses `RealtimeCalls` alone.

 ```swift
 CallScreen.shared.configure(.init(strings: ["end_call": "Anruf beenden"]))
 CallScreen.shared.attach(rt.calls)                         // rings for every call coming in, and shows it
 let call = try await rt.calls.start("support:34:42", to: "34", type: .video)
 CallScreen.shared.show(call)                               // a call placed from the app
 CallScreen.shared.show(try await rt.calls.group("meeting:daily"), title: "Daily meeting")
 ```

 The screens are Better Messages' native ones (the Bm* files of this module, the same files as its app's), driven as
 its call engine drives them: the state, the tracks and the roster in, what the person presses out.
 */
@MainActor
public final class CallScreen {
    public static let shared = CallScreen()

    /// The screen's words and colours.
    public struct Appearance {
        /// Its strings in the user's language, by key: `answer`, `reject`, `end_call`, `calling`, `connecting`,
        /// `enable_camera` … (the English is the default for any left out).
        public var strings: [String: String]
        /// Design tokens, Better Messages' (`--bm-color-accent: "33, 117, 155"` or a hex value), light and dark.
        public var tokens: [String: String]
        public var tokensDark: [String: String]
        public var darkMode: Bool
        /// Whether the microphone and camera wear the state they are in (true) or the action they perform.
        public var iconsReverted: Bool

        public init( strings: [String: String] = [:], tokens: [String: String] = [:], tokensDark: [String: String] = [:], darkMode: Bool = false, iconsReverted: Bool = true ) {
            self.strings = strings
            self.tokens = tokens
            self.tokensDark = tokensDark
            self.darkMode = darkMode
            self.iconsReverted = iconsReverted
        }
    }

    /// Where a call is, as the pieces are told: `ringing_in`, `ringing_out`, `connecting`, `in_progress` or
    /// `reconnecting`, whether it is a group call, and how long it has been on, in seconds.
    public struct CallState: Sendable {
        public let phase: String
        public let group: Bool
        public let seconds: Int
    }

    /// A call ringing in, for the app's own ringing view (`Pieces.ringing`).
    public struct Ringing {
        public let name: String
        public let avatar: String
        public let video: Bool
        /// Answers it: the screen then shows the call.
        public let answer: () -> Void
        /// Declines it.
        public let decline: () -> Void
    }

    /// Someone in a group call, for the app's view over their tile (`Pieces.tile`).
    public struct Person: Sendable {
        public let identity: String
        public let name: String
        public let avatar: String
        public let isMe: Bool
        public let speaking: Bool
        public let muted: Bool
        public let handRaised: Bool
    }

    /**
     A button in the call's dock: one of ours by its id (`answer`, `settings`, `flip`, `camera`, `mute`, `speaker`, `pip`,
     `share`, `hand`, `people`, `end`), or one of the app's own. Hanging up stays last, whatever the app answers.
     */
    public struct CallControl {
        public let id: String
        let view: UIView

        init( id: String, view: UIView ) {
            self.id = id
            self.view = view
        }

        /// A button of the app's own, drawn as ours are: `icon` an icon's path in a 24-point grid, as Lucide's are
        /// (`CallControl.icons` has ours by name), `label` what VoiceOver says, `latched` drawn on, as the speaker is.
        public init( id: String, label: String, icon: String, latched: Bool = false, action: @escaping () -> Void ) {
            let button = BmCallsButton( icon: icon, tone: latched ? .latch : .control, action: action )
            button.isOn = latched
            button.accessibilityLabel = label
            button.accessibilityIdentifier = "call-control-" + id
            self.init( id: id, view: button )
        }

        /// Our icons by name, for an app's own button.
        public static let icons: [String: String] = [
            "phone": BmCallsIcons.phone, "mic": BmCallsIcons.mic, "micOff": BmCallsIcons.micOff, "video": BmCallsIcons.video,
            "videoOff": BmCallsIcons.videoOff, "settings": BmCallsIcons.settings, "users": BmCallsIcons.users,
            "raiseHand": BmCallsIcons.raiseHand, "screenShare": BmCallsIcons.screenShare, "speaker": BmCallsIcons.speaker,
            "pip": BmCallsIcons.pip, "alert": BmCallsIcons.alert,
        ]
    }

    /**
     The app's own pieces in place of ours, the rest of the screen as it is. Each nil keeps
     ours.

     ```swift
     CallScreen.shared.pieces = .init(
         controls: { ours, state in
             ours.filter { $0.id != "pip" } + [ .init( id: "notes", label: "Call notes", icon: CallScreen.CallControl.icons[ "alert" ]! ) { openNotes() } ]
         },
         status: { state in state.phase == "ringing_out" ? "Ringing Ann…" : nil },
         ringing: { ring in RingView( name: ring.name, answer: ring.answer, decline: ring.decline ) }
     )
     ```
     */
    public struct Pieces {
        /// The dock's buttons, given ours in their order and where the call is: the buttons to show.
        public var controls: ( ( [ CallControl ], CallState ) -> [ CallControl ] )?
        /// The status line under the name: nil for ours.
        public var status: ( ( CallState ) -> String? )?
        /// The app's own view for a call ringing in, full screen, in place of ours.
        public var ringing: ( ( Ringing ) -> UIView )?
        /// A view over someone's tile in a group call, filling it (a badge, a frame): the same view again stays.
        public var tile: ( ( Person ) -> UIView? )?
        /// A view over a call between two, filling the screen under the dock: the same view again stays.
        public var stage: ( ( CallState ) -> UIView? )?

        public init(
            controls: ( ( [ CallControl ], CallState ) -> [ CallControl ] )? = nil,
            status: ( ( CallState ) -> String? )? = nil,
            ringing: ( ( Ringing ) -> UIView )? = nil,
            tile: ( ( Person ) -> UIView? )? = nil,
            stage: ( ( CallState ) -> UIView? )? = nil
        ) {
            self.controls = controls
            self.status = status
            self.ringing = ringing
            self.tile = tile
            self.stage = stage
        }
    }

    /// The app's own pieces, from the screen's next change on.
    public var pieces = Pieces() {
        didSet { installPieces() }
    }

    /// The pieces as the screens ask for them (BmCallsPieces).
    private func installPieces() {
        let pieces = self.pieces
        let group: () -> Bool = { [weak self] in
            if case .group? = self?.showing { return true }
            return false
        }
        BmCallsPiecesStore.current = BmCallsPieces(
            controls: pieces.controls.map { arrange in
                { ours, phase in
                    MainActor.assumeIsolated {
                        arrange( ours.map { CallControl( id: $0.id, view: $0.view ) }, CallState( phase: phase, group: group(), seconds: 0 ) )
                            .map { BmCallsControl( id: $0.id, view: $0.view ) }
                    }
                }
            },
            status: pieces.status.map { status in
                { phase, seconds in MainActor.assumeIsolated { status( CallState( phase: phase, group: group(), seconds: seconds ) ) } }
            },
            tile: pieces.tile.map { tile in
                { who in
                    tile( Person( identity: who.identity, name: who.name, avatar: who.avatar, isMe: who.isLocal, speaking: who.speaking,
                                  muted: who.muted, handRaised: who.handRaised ) )
                }
            },
            stage: pieces.stage.map { stage in
                { phase in MainActor.assumeIsolated { stage( CallState( phase: phase, group: group(), seconds: 0 ) ) } }
            }
        )
    }

    /// The app's own ringing view, in a window of its own above the app, while a call rings in.
    private var ringWindow: UIWindow?

    private func showRing( _ view: UIView ) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return }
        let window = UIWindow( windowScene: scene )
        let controller = UIViewController()
        view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview( view )
        NSLayoutConstraint.activate( [
            view.leadingAnchor.constraint( equalTo: controller.view.leadingAnchor ),
            view.trailingAnchor.constraint( equalTo: controller.view.trailingAnchor ),
            view.topAnchor.constraint( equalTo: controller.view.topAnchor ),
            view.bottomAnchor.constraint( equalTo: controller.view.bottomAnchor ),
        ] )
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        ringWindow = window
    }

    private func hideRing() {
        ringWindow?.isHidden = true
        ringWindow = nil
    }

    /// What is on the screen.
    private enum Showing {
        case ringing( IncomingCall )
        case call( Call )
        case group( GroupCall )
    }

    private var showing: Showing?
    private var title = ""
    private var avatar = ""
    private var isVideo = true
    private var speaker = false

    private init() {
        BmCallsConfigStore.current = BmCallsConfig()
    }

    /// The words and colours the screen draws with.
    public func configure( _ appearance: Appearance ) {
        BmCallsConfigStore.current = BmCallsConfig(
            strings: appearance.strings,
            designTokens: appearance.tokens,
            designTokensDark: appearance.tokensDark,
            darkMode: appearance.darkMode,
            iconsReverted: appearance.iconsReverted
        )
    }

    /// The lines the screen writes, for the app's own log.
    public var log: ( ( String ) -> Void )? {
        get { BmCallsLog.sink }
        set { BmCallsLog.sink = newValue }
    }

    /// A call answered from the screen, once it is on: the call between two, or the group call it rang into.
    public var onAnswered: ( ( IncomingCall.Answered ) -> Void )?

    /// Shows every call ringing for this user, and the call once answered: from this screen, or with `SystemCalls`
    /// started, from the system's (the lock screen, a watch, a car). A call ringing during another is answered busy.
    public func attach( _ calls: RealtimeCalls ) {
        calls.onIncoming { [weak self] incoming in
            Task { @MainActor in self?.ring( incoming ) }
        }
        guard !answersFromSystem else { return }
        answersFromSystem = true
        SystemCalls.onAnswered { [weak self] answered in
            guard let self else { return }
            self.hideRing()
            switch answered {
            case .call( let call ):
                self.title = call.peerInfo[ "name" ]?.string ?? ""
                self.avatar = call.peerInfo[ "avatar" ]?.string ?? ""
                self.isVideo = call.type == .video
                self.bind( call )
            case .group( let group ):
                self.bind( group )
            }
            self.onAnswered?( answered )
        }
    }

    private var answersFromSystem = false

    /// Shows a call placed from the app: ringing out, then connecting and in progress, until it ends.
    public func show( _ call: Call, name: String? = nil, avatar: String? = nil ) {
        title = name ?? call.peerInfo[ "name" ]?.string ?? ""
        self.avatar = avatar ?? call.peerInfo[ "avatar" ]?.string ?? ""
        isVideo = call.type == .video
        // The same name on the system's screen and in Recents (SystemCalls, when started).
        SystemCalls.setName( title, of: call )
        bind( call )
    }

    /// Shows a group call, its grid of everyone in it.
    public func show( _ group: GroupCall, title: String = "", video: Bool = true ) {
        self.title = title
        avatar = ""
        isVideo = video
        SystemCalls.setName( title, of: group )
        bind( group )
    }

    /// Takes the screen away, the call going on: `restore()` brings it back.
    public func hide() {
        BmCallsScreenHost.shared.hide()
    }

    /// The screen of the call going on, again.
    public func restore() {
        guard showing != nil else { return }
        present()
        publish()
    }

    // MARK: - Ringing

    private func ring( _ incoming: IncomingCall ) {
        if showing != nil {
            Task { try? await incoming.decline( busy: true ) }
            return
        }
        title = incoming.info[ "name" ]?.string ?? ""
        avatar = incoming.info[ "avatar" ]?.string ?? ""
        isVideo = incoming.type == .video
        showing = .ringing( incoming )
        incoming.onOver { [weak self] _ in
            Task { @MainActor in
                guard let self, case .ringing( let ringing )? = self.showing, ringing === incoming else { return }
                self.close()
            }
        }
        // The app's own ringing view, where it gives one; the call's screen comes with the answer.
        if let ringing = pieces.ringing {
            showRing( ringing( Ringing(
                name: title, avatar: avatar, video: isVideo,
                answer: { [weak self] in self?.answer() },
                decline: { [weak self] in
                    guard case .ringing( let incoming )? = self?.showing else { return }
                    Task { try? await incoming.decline() }
                    self?.close()
                }
            ) ) )
            return
        }
        present()
        publish()
    }

    private func answer() {
        guard case .ringing( let incoming )? = showing else { return }
        hideRing()
        Task { @MainActor in
            do {
                let answered = try await incoming.accept()
                switch answered {
                case .call( let call ): self.bind( call )
                case .group( let group ): self.bind( group )
                }
                self.onAnswered?( answered )
            } catch {
                BmCallsScreenHost.shared.update { $0.showError( BmCallsTheme.string( "call_unavailable", fallback: "This call could not be connected" ) ) }
                self.close()
            }
        }
    }

    // MARK: - A call between two

    private func bind( _ call: Call ) {
        showing = .call( call )
        call.onState { [weak self] _ in Task { @MainActor in self?.publish() } }
        call.onRemote { [weak self] in Task { @MainActor in self?.publishTracks(); self?.publish() } }
        call.onGroup { [weak self] group in Task { @MainActor in self?.bind( group ) } }
        call.onEnded { [weak self] reason in
            Task { @MainActor in
                guard let self, case .call( let shown )? = self.showing, shown === call, reason != "group" else { return }
                self.close()
            }
        }
        present()
        publishTracks()
        publish()
    }

    // MARK: - A group call

    private func bind( _ group: GroupCall ) {
        showing = .group( group )
        group.onState { [weak self] _ in Task { @MainActor in self?.publish() } }
        group.onPeople { [weak self] in Task { @MainActor in self?.publishRoster(); self?.publish() } }
        group.onEnded { [weak self] _ in
            Task { @MainActor in
                guard let self, case .group( let shown )? = self.showing, shown === group else { return }
                self.close()
            }
        }
        present()
        publishRoster()
        publish()
    }

    // MARK: - The screen

    private func present() {
        let name = title
        let avatar = avatar
        let video = isVideo
        BmCallsScreenHost.shared.present { [weak self] screen in
            guard let self else { return }
            screen.onAnswer = { [weak self] in self?.answer() }
            screen.onDecline = { [weak self] in
                guard case .ringing( let incoming )? = self?.showing else { return }
                Task { try? await incoming.decline() }
                self?.close()
            }
            screen.onEnd = { [weak self] in self?.end() }
            screen.onToggleMute = { [weak self] muted in self?.setMicrophone( !muted ) }
            screen.onToggleCamera = { [weak self] on in self?.setCamera( on ) }
            screen.onFlipCamera = { [weak self] in self?.flipCamera() }
            screen.onToggleSpeaker = { [weak self] on in self?.setSpeaker( on ) }
            screen.onMinimise = { [weak self] in self?.hide() }
            screen.onPictureInPicture = { BmCallsPip.shared.start() }
            screen.canShareScreen = false
            screen.onPeople = { [weak screen] in
                guard let screen else { return }
                BmCallsModeration.show( from: screen, participants: screen.roster )
            }
            screen.show( name: name, avatar: avatar, video: video )
            screen.apply( state: self.state )
        }
    }

    private func close() {
        showing = nil
        hideRing()
        BmCallsPip.shared.stop()
        BmCallsScreenHost.shared.setLocalVideo( nil )
        BmCallsScreenHost.shared.setRoomLocalVideo( nil )
        BmCallsScreenHost.shared.setRemoteVideo( source: .camera, track: nil )
        BmCallsScreenHost.shared.setRemoteVideo( source: .screenShare, track: nil )
        BmCallsScreenHost.shared.setRoomPeerVideo( camera: nil, screen: nil )
        BmCallsScreenHost.shared.dismiss()
    }

    private func end() {
        switch showing {
        case .ringing( let incoming )?: Task { try? await incoming.decline() }
        case .call( let call )?: call.end()
        case .group( let group )?: group.leave()
        case nil: break
        }
        close()
    }

    private func setMicrophone( _ on: Bool ) {
        switch showing {
        case .call( let call )?: call.microphone = on
        case .group( let group )?: group.microphone = on
        default: break
        }
        publish()
    }

    private func setCamera( _ on: Bool ) {
        switch showing {
        case .call( let call )?: call.camera = on
        case .group( let group )?: group.camera = on
        default: break
        }
        publishTracks()
        publish()
    }

    private func flipCamera() {
        switch showing {
        case .call( let call )?: call.flipCamera()
        case .group( let group )?: group.flipCamera()
        default: break
        }
    }

    private func setSpeaker( _ on: Bool ) {
        speaker = on
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort( on ? .speaker : .none )
    }

    /// The screen's state, as Better Messages' engine writes it.
    private var state: [String: Any] {
        var phase = "idle"
        var group = false
        var microphone = true
        var camera = false
        var peer: [String: Any] = [ "known": false ]

        switch showing {
        case .ringing?:
            phase = "ringing_in"
        case .call( let call )?:
            switch call.state {
            case .ringing: phase = call.role == .caller ? "ringing_out" : "connecting"
            case .connecting: phase = "connecting"
            case .connected: phase = "in_progress"
            case .reconnecting: phase = "reconnecting"
            case .ended: phase = "idle"
            }
            microphone = call.microphone
            camera = call.camera
            let media = call.remoteMedia
            peer = [
                "camera": media[ "camera" ] ?? false,
                "microphone": media[ "microphone" ] ?? false,
                "screen": media[ "screen_share" ] ?? false,
                "known": !media.isEmpty,
            ]
        case .group( let room )?:
            group = true
            switch room.state {
            case .connecting: phase = "connecting"
            case .connected: phase = "in_progress"
            case .reconnecting: phase = "reconnecting"
            case .ended: phase = "idle"
            }
            microphone = room.microphone
            camera = room.camera
        case nil:
            break
        }

        return [
            "phase": phase,
            "trouble": phase == "reconnecting" ? "peer" : NSNull(),
            "type": isVideo ? "video" : "audio",
            "group": group,
            "peer": peer,
            "local": [ "muted": !microphone, "camera": camera, "screen": false, "front": true, "route": speaker ? "speaker" : "" ],
            "callMode": group ? "participatory" : NSNull(),
            "roomLocked": false,
            "roomMuted": false,
            "canModerate": false,
            "handRaised": false,
            "online": [ Int ](),
            "peerOnline": false,
        ]
    }

    private func publish() {
        let state = self.state
        BmCallsScreenHost.shared.update { $0.apply( state: state ) }
    }

    /// A call between two's pictures: direct, libwebrtc's tracks; carried by a room, LiveKit's.
    private func publishTracks() {
        guard case .call( let call )? = showing else { return }
        if let room = call.carryingRoom {
            let other = room.liveKitRoom.remoteParticipants.values.first
            BmCallsScreenHost.shared.setRoomPeerVideo( camera: Self.track( other, .camera ), screen: Self.track( other, .screenShareVideo ) )
            BmCallsScreenHost.shared.setRoomLocalVideo( Self.track( room.liveKitRoom.localParticipant, .camera ) )
            BmCallsScreenHost.shared.setRemoteVideo( source: .camera, track: nil )
            BmCallsScreenHost.shared.setLocalVideo( nil )
        } else {
            BmCallsScreenHost.shared.setRemoteVideo( source: .camera, track: call.remoteCamera?.rtcTrack )
            BmCallsScreenHost.shared.setLocalVideo( call.camera ? call.localCamera?.rtcTrack : nil )
        }
    }

    /// A group call's people, this side first, as the grid draws them.
    private func publishRoster() {
        guard case .group( let group )? = showing else { return }
        let room = group.liveKitRoom
        let info = Dictionary( group.people.map { ( $0.identity, $0.info ) }, uniquingKeysWith: { first, _ in first } )
        var people: [BmCallsRoomParticipant] = []
        let me = room.localParticipant
        people.append( Self.participant( me, info: nil, local: true ) )
        for participant in room.remoteParticipants.values.sorted( by: { ( $0.identity?.stringValue ?? "" ) < ( $1.identity?.stringValue ?? "" ) } ) {
            people.append( Self.participant( participant, info: info[ participant.identity?.stringValue ?? "" ], local: false ) )
        }
        BmCallsScreenHost.shared.setRoomLocalVideo( Self.track( me, .camera ) )
        BmCallsScreenHost.shared.update { $0.setRoster( people ) }
    }

    private static func participant( _ participant: Participant, info: JSONValue?, local: Bool ) -> BmCallsRoomParticipant {
        let microphone = participant.trackPublications.values.first { $0.source == .microphone }
        return BmCallsRoomParticipant(
            identity: participant.identity?.stringValue ?? "",
            name: info?[ "name" ]?.string ?? participant.name ?? "",
            avatar: info?[ "avatar" ]?.string ?? "",
            isLocal: local,
            video: track( participant, .camera ),
            screen: track( participant, .screenShareVideo ),
            speaking: participant.isSpeaking,
            audioLevel: participant.audioLevel,
            muted: microphone == nil || microphone?.isMuted == true,
            micMuted: false,
            handRaised: false,
            isPinned: false,
            canPublish: true,
            canAdmin: false,
            mode: "participant",
            lost: false
        )
    }

    private static func track( _ participant: Participant?, _ source: Track.Source ) -> VideoTrack? {
        guard let participant else { return nil }
        let publication = participant.trackPublications.values.first { $0.source == source && !$0.isMuted }
        return publication?.track as? VideoTrack
    }
}
