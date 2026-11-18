import AVFoundation
import UIKit
import LiveKit
import LiveKitWebRTC
import WordPlusRealtime
@_spi(WordPlusUI) import WordPlusRealtimeCalls

/**
 The call screen on the SDK's calls: the call ringing in, ringing out, connecting and in progress, the
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

 The screens are the Calls* files of this module, driven as a call engine drives them: the state, the tracks and the
 roster in, what the person presses out.
 */
@MainActor
public final class CallScreen {
    public static let shared = CallScreen()

    /// The screen's words and colours.
    public struct Appearance {
        /// Its strings in the user's language, by key: `answer`, `reject`, `end_call`, `calling`, `connecting`,
        /// `enable_camera`, `optimizing_video` (over a camera changing codec) … (the English is the default for any
        /// left out).
        public var strings: [String: String]
        /// Design tokens, as the web's call screen names them (`--wplus-color-accent: "33, 117, 155"` or a hex value),
        /// light and dark.
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
     A button in the call's dock: one of ours by its id (`answer`, `chat`, `settings`, `flip`, `camera`, `mute`,
     `speaker`, `pip`, `share`, `add`, `host`, `end`), or one of the app's own. Hanging up stays last, whatever the app
     answers. `chat` is hidden here: these calls have no chat beside them, and `hand`: these calls raise no hand.
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
            let button = CallsButton( icon: icon, tone: latched ? .latch : .control, action: action )
            button.isOn = latched
            button.accessibilityLabel = label
            button.accessibilityIdentifier = "call-control-" + id
            self.init( id: id, view: button )
        }

        /// Our icons by name, for an app's own button.
        public static let icons: [String: String] = [
            "phone": CallsIcons.phone, "mic": CallsIcons.mic, "micOff": CallsIcons.micOff, "video": CallsIcons.video,
            "videoOff": CallsIcons.videoOff, "settings": CallsIcons.settings, "users": CallsIcons.users,
            "raiseHand": CallsIcons.raiseHand, "screenShare": CallsIcons.screenShare, "speaker": CallsIcons.speaker,
            "pip": CallsIcons.pip, "alert": CallsIcons.alert,
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

    /// Add Person in the dock, once a call is up, as the web's `add`: whom the app's server lists (`rt.calls.people`), each
    /// rung into the call on a press, which goes on as a group call. In a call between two, and in a group call made from
    /// one: a group call the app's server names takes nobody that way. Off unless an app turns it on.
    public var addPerson = false {
        didSet {
            offerAddPerson()
            publish()
        }
    }

    /// The pieces as the screens ask for them (CallsPieces).
    private func installPieces() {
        let pieces = self.pieces
        let group: () -> Bool = { [weak self] in
            if case .group? = self?.showing { return true }
            return false
        }
        CallsPiecesStore.current = CallsPieces(
            controls: pieces.controls.map { arrange in
                { ours, phase in
                    MainActor.assumeIsolated {
                        arrange( ours.map { CallControl( id: $0.id, view: $0.view ) }, CallState( phase: phase, group: group(), seconds: 0 ) )
                            .map { CallsControl( id: $0.id, view: $0.view ) }
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
    /// The recording of the group call on the screen, as this app knows it.
    private var recording = CallRecordingState()
    /// A host's asks to this user, one a device (`id`, `device`, `by` the host's identity), the oldest first; the answers
    /// to this user's own (`id`, `from`, `device`, `answer`); and the device of each ask this user sent, by its id.
    private var asksIn: [ [ String: String ] ] = []
    private var askAnswers: [ [ String: String ] ] = []
    private var askedHere: [ String: String ] = [:]
    /// The ring this screen is answering, until its call comes with the answer.
    private var answering: IncomingCall?
    private var title = ""
    private var avatar = ""
    private var isVideo = true {
        // The moderation menus read it from the engine.
        didSet { CallsEngine.shared.isVideo = isVideo }
    }
    private var speaker = false

    private init() {
        CallsConfigStore.current = CallsConfig()
    }

    /// The words and colours the screen draws with.
    public func configure( _ appearance: Appearance ) {
        CallsConfigStore.current = CallsConfig(
            strings: appearance.strings,
            designTokens: appearance.tokens,
            designTokensDark: appearance.tokensDark,
            darkMode: appearance.darkMode,
            iconsReverted: appearance.iconsReverted
        )
    }

    /// The lines the screen writes, for the app's own log.
    public var log: ( ( String ) -> Void )? {
        get { CallsLog.sink }
        set { CallsLog.sink = newValue }
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
        CallsScreenHost.shared.hide()
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
        incoming.onOver { [weak self] reason in
            Task { @MainActor in
                guard let self, case .ringing( let ringing )? = self.showing, ringing === incoming,
                      CallScreen.ringGoes( reason: reason, answeringHere: self.answering === incoming ) else { return }
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

    /// Whether a ring's end takes its screen away: not one this screen is answering, whose call comes with the answer.
    /// One the app answered through the API goes, as its screen is the app's to show (`show( call )`).
    static func ringGoes( reason: String, answeringHere: Bool ) -> Bool {
        reason != "answered" || !answeringHere
    }

    private func answer() {
        guard case .ringing( let incoming )? = showing else { return }
        hideRing()
        answering = incoming
        Task { @MainActor in
            defer { self.answering = nil }
            do {
                let answered = try await incoming.accept()
                switch answered {
                case .call( let call ): self.bind( call )
                case .group( let group ): self.bind( group )
                }
                self.onAnswered?( answered )
            } catch {
                CallsScreenHost.shared.update { $0.showError( CallsTheme.string( "call_unavailable", fallback: "This call could not be connected" ) ) }
                self.close()
            }
        }
    }

    // MARK: - A call between two

    private func bind( _ call: Call ) {
        showing = .call( call )
        call.onState { [weak self] _ in Task { @MainActor in self?.publish() } }
        call.onRemote { [weak self] in Task { @MainActor in self?.publishTracks(); self?.publish() } }
        call.onScreenShare { [weak self] _ in Task { @MainActor in self?.publish() } }
        call.onWaiting { [weak self] _ in Task { @MainActor in self?.publish() } }
        call.onGroup { [weak self] group in Task { @MainActor in self?.bind( group ) } }
        call.onEnded { [weak self] reason in
            Task { @MainActor in
                guard let self, case .call( let shown )? = self.showing, shown === call, reason != "group" else { return }
                self.close()
            }
        }
        offerAddPerson()
        present()
        publishTracks()
        publish()
    }

    // MARK: - Add Person

    /// The rings made from the screen and heard in a group call. A call between two lists none of its own, so the first
    /// ring is kept here over it becoming a group call.
    private var rung: [ CallInvite ] = []
    private var heardRings: Set<String> = []

    private func hear( _ invite: CallInvite ) {
        guard heardRings.insert( invite.id ).inserted else { return }
        invite.onState { [weak self] _ in Task { @MainActor in self?.publish() } }
    }

    private var rings: [ CallInvite ] {
        var all = rung
        if case .group( let group )? = showing {
            all += group.invites.filter { invite in !rung.contains { $0.id == invite.id } }
        }
        return all
    }

    /// The name of the call on the screen and who is in it, where it can add people.
    private var adding: ( name: String, calls: RealtimeCalls, inCall: Set<String> )? {
        switch showing {
        case .call( let call )?: return ( call.name, call.calls, [ call.peer ] )
        case .group( let group )? where group.group != nil: return ( group.name, group.calls, Set( group.people.compactMap( \.user ) ) )
        default: return nil
        }
    }

    /// What the screen's Add Person asks (CallsAddPerson), from the call on it.
    private func offerAddPerson() {
        guard addPerson, adding != nil else {
            CallsAddPersonStore.current = nil
            return
        }
        CallsAddPersonStore.current = CallsAddPerson(
            people: { [weak self] done in
                MainActor.assumeIsolated {
                    guard let adding = self?.adding else { return done( [] ) }
                    Task { @MainActor in
                        let listed = await adding.calls.people( adding.name )
                        let may = await adding.calls.may( listed.map { CallAsk( call: adding.name, to: $0.id ) } )
                        done( Self.offered( listed, may: may, inCall: adding.inCall ) )
                    }
                }
            },
            add: { [weak self] person, done in
                MainActor.assumeIsolated {
                    // `_ =`: as the closure's only expression, Xcode 16 took the task for what it returns, and found
                    // Task's initializers ambiguous.
                    _ = Task { @MainActor in
                        do {
                            let invite: CallInvite
                            switch self?.showing {
                            case .call( let call )?: invite = try await call.add( person.id )
                            case .group( let group )?: invite = try await group.add( person.id )
                            default: return done( nil )
                            }
                            self?.rung.append( invite )
                            self?.hear( invite )
                            done( nil )
                        } catch {
                            done( Self.addFailure( error ) )
                        }
                    }
                }
            },
            rings: { [weak self] in
                MainActor.assumeIsolated {
                    self?.rings.map { CallsAddPerson.Ring( id: $0.id, to: $0.to, state: $0.state, canCancel: $0.canCancel ) } ?? []
                }
            },
            cancel: { [weak self] id, done in
                MainActor.assumeIsolated {
                    guard let invite = self?.rings.first( where: { $0.id == id } ) else { return done( nil ) }
                    Task { @MainActor in
                        do {
                            try await invite.cancel()
                            done( nil )
                        } catch {
                            done( Self.addFailure( error ) )
                        }
                    }
                }
            }
        )
    }

    /// Whom Add Person offers: those the app's server lists, less any its rule answers no for (an answer of none keeps
    /// them, and the ring still asks the rule) and anyone in the call.
    static func offered( _ listed: [ CallPerson ], may: [ Bool? ], inCall: Set<String> ) -> [ CallsAddPerson.Person ] {
        zip( listed, may + Array( repeating: nil, count: max( 0, listed.count - may.count ) ) ).compactMap { person, may in
            may == false || inCall.contains( person.id ) ? nil : CallsAddPerson.Person( id: person.id, name: person.name, avatar: person.avatar ?? "" )
        }
    }

    /// A ring that did not go out, as the web says a call that did not.
    static func addFailure( _ error: Error ) -> String {
        ( error as? CallError )?.code == "forbidden"
            ? CallsTheme.string( "call_forbidden", fallback: "You cannot make this call" )
            : CallsTheme.string( "call_unavailable", fallback: "This call could not be connected" )
    }

    // MARK: - A group call

    private func bind( _ group: GroupCall ) {
        showing = .group( group )
        group.onState { [weak self] _ in Task { @MainActor in self?.publishRoster(); self?.publish() } }
        group.onPeople { [weak self] in Task { @MainActor in self?.publishRoster(); self?.publish() } }
        group.onPermissions { [weak self] _ in Task { @MainActor in self?.publishRoster(); self?.publish() } }
        group.onSpotlight { [weak self] _ in Task { @MainActor in self?.publish() } }
        group.onScreenShare { [weak self] _ in Task { @MainActor in self?.publish() } }
        group.onWaiting { [weak self] _ in Task { @MainActor in self?.publish() } }
        // The room's rules and the hands up are the room's: a switch moves when the room says it, whichever host pressed.
        group.onRules { [weak self] _ in Task { @MainActor in self?.publishRoster(); self?.publish() } }
        group.onHands { [weak self] _ in Task { @MainActor in self?.publishRoster(); self?.publish() } }
        group.onStalled { [weak self] _ in Task { @MainActor in self?.publishRoster() } }
        group.onPersonAway { [weak self] _ in Task { @MainActor in self?.publishRoster() } }
        // A host's ask to this user, one a device, and the answers to this user's own.
        asksIn = []
        askAnswers = []
        askedHere = [:]
        group.onAsk { [weak self] ask in
            Task { @MainActor in
                guard let self else { return }
                for device in ask.devices {
                    self.asksIn.append( [ "id": ask.id, "device": device.rawValue, "by": "user_" + ( ask.by ?? "" ) ] )
                }
                self.publish()
            }
        }
        group.onAskAnswer { [weak self] answer in
            Task { @MainActor in
                guard let self, let device = self.askedHere[ answer.id ] else { return }
                self.askAnswers.append( [ "id": answer.id, "from": "user_" + ( answer.from ?? "" ), "device": device, "answer": answer.answer.rawValue ] )
                self.publish()
            }
        }
        offer( group )
        // What could not go out in a call that goes on, as the web's `error` of a group call is shown.
        group.onError { failure in
            Task { @MainActor in
                let said = Self.failure( failure )
                CallsScreenHost.shared.update { $0.showError( said ) }
            }
        }
        // REC for everyone, late joiners too, from the room's flag.
        recording = CallRecordingState( flag: group.isRecording, now: Self.now() )
        group.onRecording { [weak self] on in
            Task { @MainActor in
                self?.recording.flagged( on, now: Self.now() )
                self?.publish()
            }
        }
        // How the rings into it stand, for Add Person: the first one came with the call it was made from.
        group.invites.forEach( hear )
        group.onInvite { [weak self] invite in
            Task { @MainActor in
                self?.hear( invite )
                self?.publish()
            }
        }
        offerAddPerson()
        // Spotlight for Everyone and Remove Spotlight in a host's person menu, Clear Spotlight in Host Controls, each
        // through the app's calls route (`spotlight`, `unspotlight`), a host's own tile too, where the call offers it
        // (`offer`). A fifth person is said in the call's words.
        CallsEngine.shared.onSpotlight = { [weak self] identity, on, completion in
            MainActor.assumeIsolated {
                guard case .group( let shown )? = self?.showing, shown === group else { return completion( false, nil ) }
                let user = identity.flatMap( Self.user( of: ) )
                guard user != nil || ( identity == nil && !on ) else { return completion( false, nil ) }
                Task { @MainActor in
                    do {
                        _ = try await group.moderate( on ? .spotlight : .unspotlight, user: user )
                        completion( true, nil )
                    } catch let error as CallError where error.code == "spotlight_full" {
                        completion( false, CallsSpotlight.fullText )
                    } catch {
                        completion( false, nil )
                    }
                }
            }
        }
        // A host's menus (CallsModeration) and everyone's hand, each act through the app's calls route, which asks the
        // call's rule again: false where it was refused, or the call doesn't offer it.
        CallsEngine.shared.onGroupAdmin = { [weak self] action, identity, _, completion in
            MainActor.assumeIsolated {
                guard let self, case .group( let shown )? = self.showing, shown === group else {
                    completion?( false )
                    return
                }
                Task { @MainActor in
                    let done = await self.run( action, identity: identity, on: group )
                    completion?( done )
                }
            }
        }
        // Remove and Ban from Calls, for the minutes asked (CallsBan).
        CallsEngine.shared.onBan = group.acts.contains( .ban ) ? { [weak self] identity, minutes, completion in
            MainActor.assumeIsolated {
                guard case .group( let shown )? = self?.showing, shown === group, let user = Self.user( of: identity ) else { return completion( false ) }
                Task { @MainActor in completion( ( try? await group.ban( user, minutes: minutes ) ) != nil ) }
            }
        } : nil
        // End for Everyone: the call ends for everyone, and this user leaves it.
        CallsEngine.shared.onEndForEveryone = { [weak self] completion in
            MainActor.assumeIsolated {
                guard case .group( let shown )? = self?.showing, shown === group else { return completion( false, nil ) }
                Task { @MainActor in
                    do {
                        _ = try await group.end()
                        completion( true, nil )
                        self?.end()
                    } catch {
                        completion( false, nil )
                    }
                }
            }
        }
        // This user's answer to a host's ask, to that host alone, and the ask put away.
        CallsEngine.shared.onAnswerAsk = { [weak self] id, device, by, answer in
            MainActor.assumeIsolated {
                guard case .group( let shown )? = self?.showing, shown === group, let said = AskAnswer( rawValue: answer ),
                      let asked = AskDevice( rawValue: device ) else { return }
                let ask = TurnOnAsk( id: id, devices: [ asked ], by: Self.user( of: by ) )
                Task { try? await group.answerAsk( ask, said ) }
            }
        }
        CallsEngine.shared.onDismissAsk = { [weak self] id, device in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.asksIn.removeAll { $0[ "id" ] == id && $0[ "device" ] == device }
                self.publish()
            }
        }
        // A host's Start Recording and REC's Stop, through the app's calls route, each saying so on the screen.
        CallsEngine.shared.onRecord = { [weak self] start, completion in
            MainActor.assumeIsolated {
                guard let self, case .group( let shown )? = self.showing, shown === group else { return completion( false, nil ) }
                self.record( start, of: group, completion: completion )
            }
        }
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

    /// Starts or stops the call's recording: `starting` or `stopping` until the app's calls route answers. A refusal
    /// (`forbidden`, `no_credits`, `not_included`, `already_recording`, `not_on_mesh` …) is the screen's words, the code
    /// being the app's to read where it calls `startRecording` itself.
    private func record( _ start: Bool, of group: GroupCall, completion: @escaping ( Bool, String? ) -> Void ) {
        let stopping = recording.own?.id
        guard start || stopping != nil else { return completion( false, nil ) }
        recording.ask( start ? "starting" : "stopping" )
        publish()
        Task { @MainActor in
            do {
                if start {
                    recording.started( try await group.startRecording(), now: Self.now() )
                } else if let stopping {
                    _ = try await group.stopRecording( stopping )
                    recording.stopped()
                }
                publish()
                completion( true, nil )
            } catch {
                CallsLog.write( "the recording was refused: \( ( error as? CallError )?.code ?? "\( error )" )" )
                recording.refused()
                publish()
                completion( false, nil )
            }
        }
    }

    private static func now() -> Int { Int( Date().timeIntervalSince1970 ) }

    /// What went wrong in a group call that goes on, in the call's words.
    static func failure( _ failure: GroupCallFailure ) -> String {
        switch ( failure.code, failure.source ) {
        case ( "publish_failed", "camera" ):
            return CallsTheme.string( "camera_not_sent", fallback: "Your camera could not be sent." )
        case ( "publish_failed", "microphone" ):
            return CallsTheme.string( "microphone_not_sent", fallback: "Your microphone could not be sent." )
        case ( "encryption_failed", _ ):
            return CallsTheme.string( "call_not_encrypted", fallback: "Part of this call could not be encrypted." )
        default:
            return CallsTheme.string( "call_trouble", fallback: "Something went wrong in this call." )
        }
    }

    /// A host's actions on a person in the screens' words, as the SDK's group calls take them (realtime-ui's
    /// use-group-call.ts): Remove from Call, Stop Camera & Mic and Demote to listening, Allow Camera & Mic and Promote to
    /// speaking, and Mute Microphone, which holds it (`hold_mic`) where the call offers that, else mutes it once, and
    /// Allow Microphone, which lets a hold go.
    static func act( for action: String, offered: [ CallAct ] ) -> ModerationAct? {
        switch action {
        case "remove_participant": return .remove
        case "mute_participant", "demote_participant": return .listen
        case "unmute_participant", "promote_participant": return .speak
        case "mute_mic": return offered.contains( .holdMic ) ? .holdMic : .mute
        case "unmute_mic": return .releaseMic
        default: return nil
        }
    }

    /// The room's rules in the screens' words (Host Controls): Mute Everyone, Lock Room and Broadcast Mode, each way.
    static func rule( for action: String ) -> ( mode: RoomRules.Mode?, locked: Bool?, muted: Bool? )? {
        switch action {
        case "mute_all": return ( nil, nil, true )
        case "unmute_all": return ( nil, nil, false )
        case "lock_room": return ( nil, true, nil )
        case "unlock_room": return ( nil, false, nil )
        case "set_broadcast_mode": return ( .broadcast, nil, nil )
        case "set_participatory_mode": return ( .participatory, nil, nil )
        default: return nil
        }
    }

    /// The devices an ask in the screens' words is for: each goes as an ask of its own, as an answer names no device.
    static func devices( for action: String ) -> [ AskDevice ]? {
        switch action {
        case "ask_camera": return [ .camera ]
        case "ask_microphone": return [ .microphone ]
        case "ask_camera_microphone": return [ .camera, .microphone ]
        default: return nil
        }
    }

    /// One of the screens' actions on the group call: whether it went through.
    private func run( _ action: String, identity: String, on group: GroupCall ) async -> Bool {
        do {
            if let rule = Self.rule( for: action ) {
                _ = try await group.setRules( mode: rule.mode, locked: rule.locked, muted: rule.muted )
                return true
            }
            switch action {
            case "raise_hand": return try await group.raiseHand()
            case "lower_own_hand": return try await group.lowerHand()
            case "lower_all_hands": return try await group.lowerAllHands()
            default: break
            }
            guard let user = Self.user( of: identity ) else { return false }
            if action == "lower_hand" { return try await group.lowerHand( of: user ) }
            if let devices = Self.devices( for: action ) {
                for device in devices {
                    askedHere[ try await group.askToTurnOn( user, devices: [ device ] ) ] = device.rawValue
                }
                return true
            }
            guard let act = Self.act( for: action, offered: group.acts ) else { return false }
            _ = try await group.moderate( act, user: user )
            return true
        } catch {
            CallsLog.write( "\( action ) was refused: \( ( error as? CallError )?.code ?? "\( error )" )" )
            return false
        }
    }

    /// What the call offers, told to the screens: each menu row where its act is, the room's rules, the asks, the
    /// spotlight and End for Everyone (a host's, where `end` is).
    private func offer( _ group: GroupCall ) {
        let engine = CallsEngine.shared
        engine.offers = Set( group.acts.map( \.rawValue ) )
        engine.carriesRoomRules = group.acts.contains( .rules )
        engine.carriesAsks = group.acts.contains( .ask )
        engine.carriesSpotlight = group.acts.contains( .spotlight )
    }

    /// Words for a join of a group call that was refused, for the app to show: `locked`, "This call is locked", and
    /// `banned`, until when where the server says it; nil for any other refusal.
    public static func refusal( _ error: Error ) -> String? {
        guard let error = error as? CallError else { return nil }
        switch error.code {
        case "locked":
            return CallsTheme.string( "call_locked", fallback: "This call is locked" )
        case "banned":
            guard let until = error.until else {
                return CallsTheme.string( "banned_until_end", fallback: "A moderator removed you from this call until it ends" )
            }
            let when = DateFormatter.localizedString( from: until, dateStyle: .medium, timeStyle: .short )
            return CallsTheme.string( "banned_until", fallback: "A moderator removed you from the calls of this conversation until %s" )
                .replacingOccurrences( of: "%s", with: when )
        default:
            return nil
        }
    }

    /// The user a tile is, by the room's name for them (`user_<id>`): nil for any other.
    static func user( of identity: String ) -> String? {
        identity.hasPrefix( "user_" ) && identity.count > 5 ? String( identity.dropFirst( 5 ) ) : nil
    }

    // MARK: - The screen

    private func present() {
        let name = title
        let avatar = avatar
        let video = isVideo
        // What Device Settings asks of the call: how loud it sends, and the side the next camera opens on.
        CallsEngine.shared.onMicrophoneLevel = { [weak self] in
            switch self?.showing {
            case .call( let call )?: return call.microphoneLevel
            case .group( let group )?: return group.microphoneLevel
            default: return nil
            }
        }
        CallsEngine.shared.onPreferCamera = { [weak self] front in
            switch self?.showing {
            case .call( let call )?: call.preferCamera( front: front )
            case .group( let group )?: group.preferCamera( front: front )
            default: break
            }
            self?.publish()
        }
        CallsScreenHost.shared.present { [weak self] screen in
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
            screen.onPictureInPicture = { CallsPip.shared.start() }
            // A share needs the app's broadcast extension (`ScreenShare`): with none, no button.
            screen.canShareScreen = ScreenShare.isAvailable
            screen.onToggleScreenShare = { [weak self] on in self?.shareScreen( on ) }
            screen.onPeople = { [weak screen] in
                guard let screen else { return }
                CallsModeration.show( from: screen, participants: screen.roster )
            }
            screen.show( name: name, avatar: avatar, video: video )
            screen.apply( state: self.state )
        }
    }

    private func close() {
        showing = nil
        CallsEngine.shared.onMicrophoneLevel = nil
        CallsEngine.shared.onPreferCamera = nil
        CallsEngine.shared.canModerate = false
        CallsEngine.shared.onGroupAdmin = nil
        CallsEngine.shared.carriesSpotlight = false
        CallsEngine.shared.onSpotlight = nil
        CallsEngine.shared.onRecord = nil
        CallsEngine.shared.offers = nil
        CallsEngine.shared.carriesRoomRules = false
        CallsEngine.shared.carriesAsks = false
        CallsEngine.shared.canEndForEveryone = false
        CallsEngine.shared.onBan = nil
        CallsEngine.shared.onEndForEveryone = nil
        CallsEngine.shared.onAnswerAsk = nil
        CallsEngine.shared.onDismissAsk = nil
        CallsEngine.shared.callMode = "participatory"
        CallsEngine.shared.roomLocked = false
        CallsEngine.shared.roomMuted = false
        asksIn = []
        askAnswers = []
        askedHere = [:]
        recording = CallRecordingState()
        CallsAddPersonStore.current = nil
        rung = []
        heardRings = []
        hideRing()
        // A window for a call that has ended is a picture nobody can close, and the next call's screen brings its own.
        CallsPip.shared.detach()
        CallsScreenHost.shared.setLocalVideo( nil )
        CallsScreenHost.shared.setRoomLocalVideo( nil )
        CallsScreenHost.shared.setRemoteVideo( source: .camera, track: nil )
        CallsScreenHost.shared.setRemoteVideo( source: .screenShare, track: nil )
        CallsScreenHost.shared.setRoomPeerVideo( camera: nil, screen: nil )
        CallsScreenHost.shared.dismiss()
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

    /// The screen's state, as a call engine writes it.
    private var state: [String: Any] {
        var phase = "idle"
        var group = false
        var microphone = true
        var camera = false
        var frontCamera = true
        var peer: [String: Any] = [ "known": false ]
        var host = false
        var spotlight: [ String ] = []
        var waiting = false
        var recorded: [String: Any]?
        var rules = RoomRules()
        var handRaised = false

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
            frontCamera = call.frontCamera
            waiting = call.carryingRoom?.waiting != nil
            let media = call.remoteMedia
            peer = [
                // A camera changing codec is away for a second under its placeholder, not turned off: no "camera off"
                // notice for it.
                "camera": ( media[ "camera" ] ?? false ) || peerOptimizing( call ),
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
            frontCamera = room.frontCamera
            host = room.can.admin
            spotlight = room.spotlight
            waiting = room.waiting != nil
            // Recording is held out of this release: nothing offers Start Recording, and REC shows only the room's flag.
            recorded = recording.state( can: false )
            rules = room.rules
            handRaised = room.handRaised
        case nil:
            break
        }

        // Host Controls' switches, as the room has the rules now.
        let engine = CallsEngine.shared
        engine.callMode = rules.mode.rawValue
        engine.roomLocked = rules.locked
        engine.roomMuted = rules.muted

        return [
            "phase": phase,
            "trouble": phase == "reconnecting" ? "peer" : NSNull(),
            "type": isVideo ? "video" : "audio",
            "group": group,
            "waiting": waiting,
            "recording": recorded ?? NSNull(),
            "peer": peer,
            "local": [ "muted": !microphone, "camera": camera, "screen": sharingScreen, "front": frontCamera, "route": speaker ? "speaker" : "" ],
            "callMode": group ? rules.mode.rawValue : NSNull(),
            "roomLocked": rules.locked,
            "roomMuted": rules.muted,
            "canModerate": host,
            "spotlight": spotlight,
            "handRaised": handRaised,
            "asks": asksIn,
            "askAnswers": askAnswers,
            "online": [ Int ](),
            "peerOnline": false,
        ]
    }

    private func publish() {
        let state = self.state
        CallsScreenHost.shared.update { $0.apply( state: state ) }
    }

    private var sharingScreen: Bool {
        switch showing {
        case .call( let call )?: return call.sharingScreen
        case .group( let group )?: return group.sharingScreen
        default: return false
        }
    }

    /// The dock's Share Screen: iOS puts up its own picker, and the button says what the call says once it has answered.
    private func shareScreen( _ on: Bool ) {
        Task { @MainActor in
            switch showing {
            case .call( let call )?: await call.setScreenShare( on )
            case .group( let group )?: await group.setScreenShare( on )
            default: break
            }
            publish()
        }
    }

    /// A call between two's pictures: direct, libwebrtc's tracks; carried by a room, LiveKit's.
    private func publishTracks() {
        guard case .call( let call )? = showing else { return }
        if let room = call.carryingRoom {
            let other = room.liveKitRoom.remoteParticipants.values.first
            CallsScreenHost.shared.setRoomPeerVideo( camera: Self.track( other, .camera ), screen: Self.track( other, .screenShareVideo ) )
            // Its camera changing codec, as the room holds it (`GroupCall.cameraSwitch(of:)`): the stage draws the
            // placeholder until the frame that ends it.
            CallsScreenHost.shared.setRoomPeerOptimizing( peerOptimizing( call ) )
            CallsScreenHost.shared.setRoomLocalVideo( Self.track( room.liveKitRoom.localParticipant, .camera ) )
            CallsScreenHost.shared.setRemoteVideo( source: .camera, track: nil )
            CallsScreenHost.shared.setRemoteVideo( source: .screenShare, track: nil )
            CallsScreenHost.shared.setLocalVideo( nil )
        } else {
            CallsScreenHost.shared.setRoomPeerOptimizing( false )
            CallsScreenHost.shared.setRemoteVideo( source: .camera, track: call.remoteCamera?.rtcTrack )
            CallsScreenHost.shared.setRemoteVideo( source: .screenShare, track: call.remoteScreen?.rtcTrack )
            CallsScreenHost.shared.setLocalVideo( call.camera ? call.localCamera?.rtcTrack : nil )
        }
    }

    /// Whether the other side of a call carried by a room is changing its camera's codec.
    private func peerOptimizing( _ call: Call ) -> Bool {
        guard let room = call.carryingRoom, let other = room.liveKitRoom.remoteParticipants.values.first else { return false }
        return room.cameraSwitch( of: other.identity?.stringValue ?? "" ).pending
    }

    /// A group call's people, this side first, as the grid draws them.
    private func publishRoster() {
        guard case .group( let group )? = showing else { return }
        let room = group.liveKitRoom
        let known = Dictionary( group.people.map { ( $0.identity, $0 ) }, uniquingKeysWith: { first, _ in first } )
        var people: [CallsRoomParticipant] = []
        let me = room.localParticipant
        // A host (its rule's `admin`) moderates the others through the app's calls route, and ends the call for everyone
        // where it offers `end`.
        let can = group.can
        CallsEngine.shared.canModerate = can.admin
        CallsEngine.shared.canEndForEveryone = can.admin && group.acts.contains( .end )
        // Whose hands are up, and whether a held microphone is marked on a tile: only where the call holds one.
        let hands = Set( group.hands.map { "user_" + $0 } )
        let holds = group.acts.contains( .holdMic )
        // This user's own tile by the name and picture the app's server gave them, as the others see them, from the first
        // moment: the room knows nobody until it has connected. Its own held microphone is the dock's locked one.
        let own = group.own
        people.append( Self.participant( me, identity: own.identity, info: own.info, local: true, publish: can.publish, admin: can.admin,
                                         micHeld: can.micHeld, hand: group.handRaised ) )
        for participant in room.remoteParticipants.values.sorted( by: { ( $0.identity?.stringValue ?? "" ) < ( $1.identity?.stringValue ?? "" ) } ) {
            let identity = participant.identity?.stringValue ?? ""
            let person = known[ identity ]
            var tile = Self.participant( participant, info: person?.info, local: false, publish: participant.permissions.canPublish,
                                         micHeld: holds && person?.micHeld == true, hand: hands.contains( identity ) )
            // A camera changing codec, as the room holds it: the tile draws its placeholder until the frame that ends
            // it. Media that stopped reaching the media server, as the mesh says it: blurred and said.
            tile.optimizing = group.cameraSwitch( of: tile.identity ).pending
            tile.stalled = person?.stalled.flatMap { CallsStalled( rawValue: $0.rawValue ) }
            people.append( tile )
        }
        // Those who left and may come back, kept for 20 s with no media, saying Reconnecting...
        for person in group.people where person.reconnecting && !people.contains( where: { $0.identity == person.identity } ) {
            people.append( Self.away( identity: person.identity, info: person.info, publish: person.publish, hand: hands.contains( person.identity ) ) )
        }
        CallsScreenHost.shared.setRoomLocalVideo( Self.track( me, .camera ) )
        CallsScreenHost.shared.update { $0.setRoster( people ) }
    }

    /// Someone in a group call as the grid draws them: `publish`, whether they may send (a listener may not), and `admin`,
    /// whether they host it, which only this side knows of itself.
    private static func participant( _ participant: Participant, identity: String? = nil, info: JSONValue?, local: Bool, publish: Bool = true, admin: Bool = false,
                                     micHeld: Bool = false, hand: Bool = false ) -> CallsRoomParticipant {
        let microphone = participant.trackPublications.values.first { $0.source == .microphone }
        return CallsRoomParticipant(
            identity: identity ?? participant.identity?.stringValue ?? "",
            name: info?[ "name" ]?.string ?? participant.name ?? "",
            avatar: info?[ "avatar" ]?.string ?? "",
            isLocal: local,
            video: track( participant, .camera ),
            screen: track( participant, .screenShareVideo ),
            speaking: participant.isSpeaking,
            audioLevel: participant.audioLevel,
            muted: microphone == nil || microphone?.isMuted == true,
            micMuted: micHeld,
            handRaised: hand,
            isPinned: false,
            canPublish: publish,
            canAdmin: admin,
            mode: "participant",
            lost: false
        )
    }

    /// Someone who left and may come back (`GroupPerson.reconnecting`): their tile with no media, wearing the
    /// "Reconnecting..." veil, until they are back or the wait is over.
    static func away( identity: String, info: JSONValue, publish: Bool, hand: Bool = false ) -> CallsRoomParticipant {
        var tile = CallsRoomParticipant(
            identity: identity,
            name: info[ "name" ]?.string ?? "",
            avatar: info[ "avatar" ]?.string ?? "",
            isLocal: false,
            video: nil,
            screen: nil,
            speaking: false,
            audioLevel: 0,
            muted: true,
            micMuted: false,
            handRaised: hand,
            isPinned: false,
            canPublish: publish,
            canAdmin: false,
            mode: "participant",
            lost: false
        )
        tile.reconnecting = true
        return tile
    }

    private static func track( _ participant: Participant?, _ source: Track.Source ) -> VideoTrack? {
        guard let participant else { return nil }
        let publication = participant.trackPublications.values.first { $0.source == source && !$0.isMuted }
        return publication?.track as? VideoTrack
    }
}

/// A group call's recording as the screens read it (`state["recording"]`, CallsRecording), from what this app knows of
/// it: the one it started, by its id, and the room's flag for one anyone else started, which names no id. So a host who
/// did not start it sees REC and has no Stop: the calls route stops a recording by its id, and nothing hands the id to
/// them. Everyone else is told by the notice, the screens' default.
struct CallRecordingState {
    /// The recording this app started, until it is stopped.
    private(set) var own: GroupRecording?
    /// `starting` or `stopping` while the app's calls route answers: "" otherwise.
    private(set) var asked = ""
    /// The room says it is being recorded.
    private(set) var flag = false
    /// When it started, or when this app heard of it, in seconds since 1970.
    private(set) var since = 0
    /// This app's recording, stopped, while the room still says it records.
    private var stopping: String?
    /// Which recording of someone else's this is in this call, for the answers kept by its id.
    private var run = 0

    init( flag: Bool = false, now: Int = 0 ) {
        flagged( flag, now: now )
    }

    mutating func ask( _ what: String ) {
        asked = what
    }

    mutating func started( _ recording: GroupRecording, now: Int ) {
        own = recording
        asked = ""
        since = now
    }

    /// The route said no: what was on stays on.
    mutating func refused() {
        asked = ""
    }

    mutating func stopped() {
        if flag { stopping = own?.id }
        own = nil
        asked = ""
    }

    /// The room's flag changed. Off ends whatever this app knew, whoever stopped it.
    mutating func flagged( _ on: Bool, now: Int ) {
        guard on != flag else { return }
        flag = on
        if on {
            if own == nil {
                run += 1
                since = now
            }
        } else {
            own = nil
            stopping = nil
            since = 0
        }
    }

    /// The state's `recording`, `can` whether this user may start one: none for someone who may not, while nothing records.
    func state( can: Bool ) -> [String: Any]? {
        var one: [String: Any] = [ "tell": "notice", "notice": CallsEngine.shared.recordingNoticeShown ]
        if asked == "starting" {
            one[ "state" ] = "starting"
            one[ "can" ] = can
            one[ "mine" ] = true
        } else if let own {
            one[ "state" ] = asked == "stopping" ? "stopping" : "on"
            one[ "id" ] = own.id
            one[ "since" ] = since
            one[ "can" ] = can
            one[ "mine" ] = true
        } else if let stopping {
            one[ "state" ] = "stopping"
            one[ "id" ] = stopping
            one[ "can" ] = can
            one[ "mine" ] = true
        } else if flag {
            one[ "state" ] = "on"
            one[ "id" ] = "room-\( run )"
            one[ "since" ] = since
            one[ "can" ] = false
        } else if can {
            one[ "state" ] = "off"
            one[ "can" ] = true
        } else {
            return nil
        }
        return one
    }
}
