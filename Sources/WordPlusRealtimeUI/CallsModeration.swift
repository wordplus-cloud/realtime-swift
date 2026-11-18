import UIKit

/// Running a group call from the phone, as the web runs it (realtime-ui's moderation-panels.tsx): the room's rules in
/// Host Controls, opened from the dock, and one person's actions in their menu, opened from the ⋯ on their tile, each
/// a menu beside its button whose rows say what they do (`CallsPopover`).
///
/// Every action is the one REST route the web uses, so the permission checks, the room updates and the record left
/// behind are identical whichever screen gave the order. Nothing here decides what someone may do — WordPress does,
/// and a refusal comes back as a refusal.
enum CallsModeration {
    /// Host Controls: the room's rules for a moderator, above the dock at its end edge. Called again, it closes.
    static func show( from screen: CallsScreen, participants: [ CallsRoomParticipant ] ) {
        // A moderator's, or anyone's who may record the call, whose Start Recording is there (the web's roomModerated).
        guard CallsEngine.shared.canModerate || screen.recording?.can == true, screen.hostControlsAnchor != nil else { return }

        screen.togglePopover( key: "room", anchor: { [weak screen] in screen?.hostControlsAnchor }, side: .above, align: .stageEnd, width: 340, room: true ) { [weak screen] in
            guard let screen else { return nil }

            return ( .room( icon: CallsIcons.shield, title: CallsTheme.string( "host_controls", fallback: "Host Controls" ) ),
                     roomEntries( screen.people, screen: screen ) )
        }
    }

    /// End for Everyone: the menu closes first, then the call asks on itself. Yes tells the room, takes everyone else
    /// out and leaves (the engine's endForEveryone); Cancel ends nothing.
    static func askEndForEveryone( from screen: CallsScreen ) {
        screen.closePopover()

        let confirm = CallsConfirm(
            title: CallsTheme.string( "end_for_everyone_question", fallback: "End the call for everyone?" ),
            message: CallsTheme.string( "end_for_everyone_note", fallback: "Everyone leaves the call, you too." ),
            confirm: CallsTheme.string( "end_for_everyone", fallback: "End for Everyone" ),
            danger: true
        ) { [weak screen] yes in
            guard yes else { return }

            CallsEngine.shared.endForEveryone { ok, error in
                guard !ok else { return }

                screen?.showError( error ?? CallsTheme.string( "end_for_everyone_failed", fallback: "The call could not be ended for everyone." ) )
            }
        }

        screen.showConfirm( confirm )
    }

    /// One person's actions, from the ⋯ on their tile or a long-press on it, below the ⋯. Nothing opens for someone
    /// who cannot moderate: the route would refuse it anyway.
    static func showFor( from screen: CallsScreen, person: CallsRoomParticipant ) {
        guard CallsEngine.shared.canModerate, moderates( person ) else { return }

        let identity = person.identity

        guard screen.personAnchor( identity ) != nil else { return }

        // Their tile's ⋯ wherever their tile is now: tiles change hands as the grid reorders.
        screen.togglePopover( key: identity, anchor: { [weak screen] in screen?.personAnchor( identity ) }, side: .below, align: .start, width: 248, room: false ) { [weak screen] in
            guard let screen, let person = screen.people.first( where: { $0.identity == identity } ) else { return nil }

            let entries = personEntries( person, screen: screen )

            guard !entries.isEmpty else { return nil }

            return ( .person( name: person.name, avatar: person.avatar, state: personState( person ) ), entries )
        }
    }

    /// Whether a moderator has anything to do on this tile, which is when it wears the ⋯: spotlight or pin it in a
    /// video call, and for anyone else their own actions. The web's tileModerated.
    static func moderates( _ person: CallsRoomParticipant ) -> Bool {
        let engine = CallsEngine.shared

        guard engine.canModerate else { return false }

        return engine.isVideo || !person.isLocal
    }

    /// What is on for the person now, as their menu's header says it: a raised hand, and then the first of a viewer, a
    /// microphone a moderator keeps off, and a microphone simply off.
    static func personState( _ person: CallsRoomParticipant ) -> [ CallsPopover.Pill ] {
        var state: [ CallsPopover.Pill ] = []

        if person.handRaised {
            state.append( .init( label: CallsTheme.string( "hand_raised", fallback: "Hand Raised" ), icon: CallsIcons.raiseHand, tone: .warning ) )
        }

        if !person.canPublish && !person.canAdmin {
            state.append( .init(
                label: CallsEngine.shared.isVideo
                    ? CallsTheme.string( "viewer", fallback: "Viewer" )
                    : CallsTheme.string( "listener", fallback: "Listener" ),
                icon: CallsIcons.videoOff, tone: .neutral
            ) )
        } else if person.micMuted {
            state.append( .init( label: CallsTheme.string( "muted_by_moderator", fallback: "Muted by a moderator" ), icon: CallsIcons.silenced, tone: .danger ) )
        } else if person.muted {
            state.append( .init( label: CallsTheme.string( "microphone_disabled", fallback: "Microphone Disabled" ), icon: CallsIcons.micOff, tone: .neutral ) )
        }

        return state
    }

    /// Host Controls' rows: the room's rules where the call carries them, each flipping once its request succeeds, the
    /// join alerts, lowering every hand while one is up, recording, the spotlight and End for Everyone.
    private static func roomEntries( _ people: [ CallsRoomParticipant ], screen: CallsScreen ) -> [ CallsPopover.Entry ] {
        let engine = CallsEngine.shared
        let broadcast = engine.callMode == "broadcast"

        // Whose microphones Mute Everyone mutes and lets back on: everyone else but the moderators.
        let others = people.filter { !$0.isLocal && !$0.canAdmin }.map( \.identity )

        // Someone who may record the call without moderating it has Start and Stop Recording alone.
        guard engine.canModerate else { return recordingEntries( screen, first: true ) }

        var entries: [ CallsPopover.Entry ] = []

        // The room's own rules, where the call carries them: an engine without them (the SDK's) offers none.
        if engine.carriesRoomRules {
            entries += roomRules( others: others, broadcast: broadcast )
        }

        entries.append( .row( .init(
            key: "join-alerts",
            icon: CallsIcons.userPlus,
            label: CallsTheme.string( "join_alerts", fallback: "Join Alerts" ),
            note: CallsTheme.string( "join_alerts_note", fallback: "A toast when someone joins the call, on this device." ),
            on: CallsHostPrefs.joinAlerts
        ) { done in
            CallsHostPrefs.joinAlerts.toggle()
            done()
        } ) )

        if engine.carriesHands, people.contains( where: { $0.handRaised } ) {
            entries.append( .divider )
            entries.append( .row( .init(
                key: "hands",
                icon: CallsIcons.raiseHand,
                label: CallsTheme.string( "lower_all_hands", fallback: "Lower All Hands" )
            ) { done in
                engine.groupAdmin( action: "lower_all_hands" ) { _ in done() }
            } ) )
        }

        entries += recordingEntries( screen, first: false )

        // Everyone out of the spotlight at once, while anyone is in it.
        if engine.carriesSpotlight, engine.isVideo, !CallsSpotlight.spotlit( people, spotlight: screen.spotlight ).isEmpty {
            entries.append( .divider )
            entries.append( .row( .init(
                key: "spotlight",
                icon: CallsIcons.star,
                label: CallsTheme.string( "clear_spotlight", fallback: "Clear Spotlight" ),
                note: CallsTheme.string( "clear_spotlight_note", fallback: "Everyone sees the usual tiles again." )
            ) { [weak screen] done in
                CallsSpotlight.send( nil, on: false, screen: screen, done: done )
            } ) )
        }

        // Only where the host says this user may end the call: the SDK's own calls end by the app's server (`end()`).
        if engine.canEndForEveryone {
            entries.append( .divider )
            entries.append( .row( .init(
                key: "end",
                icon: CallsIcons.logout,
                label: CallsTheme.string( "end_for_everyone", fallback: "End for Everyone" ),
                note: CallsTheme.string( "end_for_everyone_note", fallback: "Everyone leaves the call, you too." ),
                danger: true
            ) { [weak screen] done in
                done()

                guard let screen else { return }

                // After the row's own press has finished drawing.
                DispatchQueue.main.async { askEndForEveryone( from: screen ) }
            } ) )
        }

        return entries
    }

    /// Mute Everyone, Lock Room and Broadcast Mode, each flipping once its request succeeds, and this device's sound for a
    /// raised hand, in every mode (a moderator moderates raising a hand wherever the call is moderated).
    private static func roomRules( others: [ String ], broadcast: Bool ) -> [ CallsPopover.Entry ] {
        let engine = CallsEngine.shared

        return [
            .row( .init(
                key: "room-mute",
                icon: CallsIcons.micOff,
                label: CallsTheme.string( "mute_everyone", fallback: "Mute Everyone" ),
                note: CallsTheme.string( "mute_everyone_note", fallback: "Microphones stay off until you allow them again. Cameras and screens keep going." ),
                on: engine.roomMuted
            ) { done in
                engine.groupAdmin( action: engine.roomMuted ? "unmute_all" : "mute_all", identities: others ) { _ in done() }
            } ),
            .row( .init(
                key: "room-lock",
                icon: CallsIcons.padlock,
                label: CallsTheme.string( "lock_room", fallback: "Lock Room" ),
                note: CallsTheme.string( "lock_room_note", fallback: "Nobody else can join." ),
                on: engine.roomLocked
            ) { done in
                engine.groupAdmin( action: engine.roomLocked ? "unlock_room" : "lock_room" ) { _ in done() }
            } ),
            .row( .init(
                key: "mode",
                icon: CallsIcons.megaphone,
                label: CallsTheme.string( "broadcast_mode_rule", fallback: "Broadcast Mode" ),
                note: CallsTheme.string( "broadcast_mode_note", fallback: "Only speakers can turn on a camera or microphone. Everyone else watches and can raise a hand." ),
                on: broadcast
            ) { done in
                engine.groupAdmin( action: broadcast ? "set_participatory_mode" : "set_broadcast_mode" ) { _ in done() }
            } ),
            .row( .init(
                key: "hand-sound",
                icon: CallsIcons.bell,
                label: CallsTheme.string( "hand_sound", fallback: "Sound for Raised Hands" ),
                note: CallsTheme.string( "hand_sound_note", fallback: "A short sound when someone raises a hand, on this device." ),
                on: CallsHostPrefs.handSound
            ) { done in
                CallsHostPrefs.handSound.toggle()
                done()
            } ),
        ]
    }

    /// Start Recording, or Stop Recording while it records, for whoever may record the call (the web's room panel): an
    /// act, not a rule of the room, asked first on the call once the menu has closed (CallsScreen.askRecording). Start
    /// says how everyone else will be told; a press does nothing while it starts or saves.
    private static func recordingEntries( _ screen: CallsScreen, first: Bool ) -> [ CallsPopover.Entry ] {
        guard let recording = screen.recording, recording.can else { return [] }

        let stop = recording.running
        let row = CallsPopover.Row(
            key: "record",
            icon: CallsIcons.record,
            label: stop
                ? CallsTheme.string( "rec_stop_recording", fallback: "Stop Recording" )
                : CallsTheme.string( "rec_start", fallback: "Start Recording" ),
            note: stop
                ? CallsTheme.string( "rec_stop_note", fallback: "Asks you first. It is ready to watch a few minutes later." )
                : recording.startNote,
            danger: stop
        ) { [weak screen] done in
            done()

            guard let screen else { return }

            screen.closePopover()

            // After the row's own press has finished drawing.
            DispatchQueue.main.async { screen.askRecording( stop ? "stop" : "start" ) }
        }

        return ( first ? [] : [ .divider ] ) + [ .row( row ) ]
    }

    /// Spotlight for Everyone, or why it can't be done now: with four people in the spotlight it is dimmed, its note
    /// saying so, as the web's row is.
    private static func spotlightRow( full: Bool, run: @escaping ( @escaping () -> Void ) -> Void ) -> CallsPopover.Row {
        .init(
            key: "spot",
            icon: CallsIcons.star,
            label: CallsTheme.string( "spotlight_for_everyone", fallback: "Spotlight for Everyone" ),
            note: full
                ? CallsSpotlight.fullText
                : CallsTheme.string( "spotlight_note", fallback: "Their tile is the main one for everyone in the call." ),
            disabled: full,
            run: run
        )
    }

    /// Pin for Me, this user's own and anyone's: while someone is in the spotlight, a new pin says it waits for it.
    static func pinForMeRow( _ identity: String, screen: CallsScreen, spotlit: Bool ) -> CallsPopover.Row {
        let pinned = screen.pinnedForMe.contains( identity )

        return .init(
            key: "pin-for-me",
            icon: pinned ? CallsIcons.pinOff : CallsIcons.pin,
            label: pinned
                ? CallsTheme.string( "unpin_for_me", fallback: "Unpin for Me" )
                : CallsTheme.string( "pin_for_me", fallback: "Pin for Me" ),
            note: spotlit && !pinned
                ? CallsTheme.string( "pin_for_me_waits", fallback: "On your screen once nobody is in the spotlight." )
                : nil
        ) { [weak screen] done in
            screen?.togglePinForMe( identity )
            done()
        }
    }

    /// The web's person menu, in the order and on the conditions it draws it: in a video call the spotlight for
    /// everyone (or a call's pin for everyone) and Pin for Me, and for everybody else their microphone, whether they may
    /// send at all (a viewer or a speaker in broadcast mode, their camera and microphone outside it), their raised
    /// hand, and removing them.
    static func personEntries( _ person: CallsRoomParticipant, screen: CallsScreen ) -> [ CallsPopover.Entry ] {
        let engine = CallsEngine.shared
        let broadcast = engine.callMode == "broadcast"
        let video = engine.isVideo
        let identity = person.identity

        func act( _ action: String ) -> ( @escaping () -> Void ) -> Void {
            { done in engine.groupAdmin( action: action, identity: identity ) { _ in done() } }
        }

        func row( _ key: String, _ icon: String, _ string: String, _ fallback: String, _ action: String, highlight: Bool = false, note: ( key: String, fallback: String )? = nil ) -> CallsPopover.Entry {
            .row( .init( key: key, icon: icon, label: CallsTheme.string( string, fallback: fallback ), note: note.map { CallsTheme.string( $0.key, fallback: $0.fallback ) }, highlight: highlight, run: act( action ) ) )
        }

        // Whether they send anything a stop would take: their microphone, camera or screen.
        let sending = !person.muted || person.video != nil || person.screen != nil

        var entries: [ CallsPopover.Entry ] = []

        // Asking them to turn on what is off (CallsAsks), first as on the web: their microphone, unless a moderator holds
        // it off, and on a video call their camera, both in one row while both are, each in its own once one is on or
        // while one was asked for alone a moment ago. "Asked…" for a while after, with their answer under it.
        if engine.carriesAsks, !person.isLocal, person.canPublish {
            let microphone = person.muted && !person.micMuted
            let camera = video && person.video == nil
            let both = microphone && camera && CallsAsks.isAsked( identity, "camera" ) == CallsAsks.isAsked( identity, "microphone" )
            let asks: [ [ String ] ] = both ? [ [ "camera", "microphone" ] ] : ( microphone ? [ [ "microphone" ] ] : [] ) + ( camera ? [ [ "camera" ] ] : [] )

            for devices in asks {
                let asked = devices.allSatisfy { CallsAsks.isAsked( identity, $0 ) }
                let label = asked
                    ? CallsTheme.string( "ask_asked", fallback: "Asked…" )
                    : devices.count > 1
                        ? CallsTheme.string( "ask_turn_on_both", fallback: "Ask to Turn On Camera and Microphone" )
                        : devices[ 0 ] == "camera"
                            ? CallsTheme.string( "ask_turn_on_camera", fallback: "Ask to Turn On Camera" )
                            : CallsTheme.string( "ask_turn_on_microphone", fallback: "Ask to Turn On Microphone" )

                entries.append( .row( .init(
                    key: "ask-" + devices.joined( separator: "-" ),
                    icon: devices.contains( "camera" ) ? CallsIcons.video : CallsIcons.mic,
                    label: label,
                    note: asked ? CallsAsks.answered( identity, devices, name: CallsHostToasts.plain( person.name ) ) : nil
                ) { [weak screen] done in
                    guard !asked else { return done() }

                    let after = CallsAsks.answers.count

                    engine.groupAdmin( action: devices.count > 1 ? "ask_camera_microphone" : "ask_" + devices[ 0 ], identity: identity ) { ok in
                        if ok {
                            CallsAsks.record( identity, devices, after: after )

                            // "Asked…" runs out: the menu says what it offers again.
                            DispatchQueue.main.asyncAfter( deadline: .now() + CallsAsks.askedSeconds + 0.1 ) { [weak screen] in screen?.refreshPopover() }
                        }

                        done()
                        screen?.refreshPopover()
                    }
                } ) )
            }
        }

        // An audio roster pins and spotlights nobody: it has no main tiles. Spotlight for Everyone where the call carries
        // it, in place of the pin for everyone of before, which a call without a spotlight keeps; and the moderator's
        // own Pin for Me (CallsSpotlight).
        if video {
            let spotlit = CallsSpotlight.spotlit( screen.people, spotlight: screen.spotlight )

            if engine.carriesSpotlight {
                entries.append( spotlit.contains( identity )
                    ? .row( .init(
                        key: "spot",
                        icon: CallsIcons.close,
                        label: CallsTheme.string( "remove_spotlight", fallback: "Remove Spotlight" )
                    ) { [weak screen] done in
                        CallsSpotlight.send( identity, on: false, screen: screen, done: done )
                    } )
                    : .row( spotlightRow( full: spotlit.count >= CallsSpotlight.most ) { [weak screen] done in
                        CallsSpotlight.send( identity, on: true, screen: screen, done: done )
                    } ) )
            } else if engine.offers == nil {
                entries.append( person.isPinned
                    ? row( "pin", CallsIcons.pinOff, "unpin_participant", "Unpin Participant", "unpin_participant" )
                    : row( "pin", CallsIcons.pin, "pin_participant", "Pin Participant", "pin_participant" ) )
            }

            entries.append( .row( pinForMeRow( identity, screen: screen, spotlit: !spotlit.isEmpty ) ) )
        }

        guard !person.isLocal else { return entries }

        // `micMuted` is the moderator's own doing, which Allow Microphone undoes. A mute holds the microphone off until
        // then: where it is off already, the row says that, as "Mute Microphone" reads as if it were on. Each where the
        // call offers it: a hold (`hold_mic`) and its release (`release_mic`), else a mute once (`mute`), which a
        // microphone already off has no use for.
        if person.canPublish {
            if person.micMuted {
                if engine.offersAct( "release_mic" ) {
                    entries.append( row( "mic", CallsIcons.mic, "allow_microphone", "Allow Microphone", "unmute_mic" ) )
                }
            } else if person.muted {
                if engine.offersAct( "hold_mic" ) {
                    entries.append( row( "mic", CallsIcons.micOff, "keep_microphone_off", "Keep Microphone Off", "mute_mic",
                                         note: ( "keep_microphone_off_note", "They cannot turn it on until you allow it." ) ) )
                }
            } else if engine.offersAct( "hold_mic" ) || engine.offersAct( "mute" ) {
                entries.append( row( "mic", CallsIcons.micOff, "mute_microphone", "Mute Microphone", "mute_mic" ) )
            }
        }

        if broadcast {
            // In broadcast mode by promoting and demoting.
            if !person.canAdmin {
                if person.canPublish {
                    if engine.offersAct( "listen" ) {
                        entries.append( row( "speaker", CallsIcons.arrowDown, "demote_to_viewer", "Demote to Viewer", "demote_participant" ) )
                    }
                } else if engine.offersAct( "speak" ) {
                    entries.append( row( "speaker", CallsIcons.arrowUp, "promote_to_speaker", "Promote to Speaker", "promote_participant", highlight: person.handRaised ) )
                }
            }
        } else if person.canPublish, !engine.offersAct( "listen" ) {
            // Nothing to stop them with.
        } else if !person.canPublish, !engine.offersAct( "speak" ) {
            // Nothing to let them speak with.
        } else if person.canPublish {
            // Outside it, on a video call, said as what it does to them: their camera and microphone (and screen)
            // stopped, or kept off where none is on, or let back on. An audio call has no camera to name, and keeps
            // viewer and speaker.
            if !video {
                entries.append( row( "speaker", CallsIcons.arrowDown, "demote_to_viewer", "Demote to Viewer", "mute_participant" ) )
            } else if sending {
                entries.append( row( "speaker", CallsIcons.videoOff, "stop_camera_mic", "Stop Camera & Mic", "mute_participant" ) )
            } else {
                entries.append( row( "speaker", CallsIcons.videoOff, "keep_camera_mic_off", "Keep Camera & Mic Off", "mute_participant",
                                     note: ( "keep_camera_mic_off_note", "They cannot turn them on until you allow them." ) ) )
            }
        } else {
            entries.append( video
                ? row( "speaker", CallsIcons.video, "allow_camera_mic", "Allow Camera & Mic", "unmute_participant", highlight: person.handRaised )
                : row( "speaker", CallsIcons.arrowUp, "promote_to_speaker", "Promote to Speaker", "unmute_participant", highlight: person.handRaised ) )
        }

        if person.handRaised, engine.offersAct( "hand" ) {
            entries.append( row( "hand", CallsIcons.raiseHand, "lower_hand", "Lower Hand", "lower_hand" ) )
        }

        // Taking them out: Remove from Call, a kick, and where the call offers it Remove and Ban from Calls, which asks
        // for how long first (CallsBan).
        let removes = engine.offersAct( "remove" )
        let bans = engine.offersAct( "ban" ) && engine.onBan != nil && !person.canAdmin

        if removes || bans { entries.append( .divider ) }

        if removes {
            entries.append( .row( .init(
                key: "kick",
                icon: CallsIcons.userX,
                label: CallsTheme.string( "remove_from_call", fallback: "Remove from Call" ),
                danger: true,
                run: act( "remove_participant" )
            ) ) )
        }

        if bans {
            entries.append( .row( .init(
                key: "ban",
                icon: CallsIcons.userX,
                label: CallsTheme.string( "remove_and_ban", fallback: "Remove and Ban from Calls…" ),
                danger: true
            ) { [weak screen] done in
                done()

                guard let screen else { return }

                // After the row's own press has finished drawing.
                DispatchQueue.main.async { CallsBan.ask( person, from: screen ) }
            } ) )
        }

        return entries
    }
}

/// Spotlight for Everyone and Pin for Me, as the web's calls/spotlight.tsx has them. A moderator puts up to four people
/// on the main tiles for everyone in a group video call: the room's state (the engine's state's `spotlight`), so it
/// outlives a reconnect and whoever joins later sees it, each such tile labeled Spotlight. Anyone pins someone for
/// themselves (Pin for Me, this phone alone), which shows while nobody is in the spotlight: a spotlight comes first, and
/// the pins wait for it to end. A moderator's pin from an older app (the person's `isPinned`) is a spotlight too, as
/// everyone already saw it as one.
enum CallsSpotlight {
    /// How many can be in the spotlight at once, as the call's server keeps it.
    static let most = 4

    /// A fifth person refused, in the call's own words.
    static var fullText: String {
        CallsTheme.string( "spotlight_full", fallback: "Up to four people can be in the spotlight." )
    }

    /// Who is in the spotlight, by identity, in the order they were spotlighted: the room's spotlight for those in the
    /// call now, then anyone an older app pinned for everyone.
    static func spotlit( _ people: [ CallsRoomParticipant ], spotlight: [ String ] ) -> [ String ] {
        var spotlit: [ String ] = []

        for identity in spotlight where !spotlit.contains( identity ) && people.contains( where: { $0.identity == identity } ) {
            spotlit.append( identity )
        }

        for person in people where person.isPinned && !spotlit.contains( person.identity ) {
            spotlit.append( person.identity )
        }

        return spotlit
    }

    /// The main tiles, by identity, in their order: the spotlight while anyone is in it, else this user's own pins, and
    /// in broadcast mode with either the speakers.
    static func main( _ people: [ CallsRoomParticipant ], spotlight: [ String ], pinned: [ String ], broadcast: Bool ) -> [ String ] {
        let spotlit = spotlit( people, spotlight: spotlight )

        guard spotlit.isEmpty else { return spotlit }

        var main = pinned.filter { identity in people.contains( where: { $0.identity == identity } ) }

        if broadcast {
            for person in people where ( person.canPublish || person.canAdmin ) && !main.contains( person.identity ) {
                main.append( person.identity )
            }
        }

        return main
    }

    /// Pin for Me's pins once the people changed: someone who leaves is unpinned, so coming back they are a tile like
    /// the others.
    static func kept( _ pinned: [ String ], people: [ CallsRoomParticipant ] ) -> [ String ] {
        pinned.filter { identity in people.contains( where: { $0.identity == identity } ) }
    }

    /// A pin put on or taken off, the others kept in the order they were pinned.
    static func toggled( _ pinned: [ String ], _ identity: String ) -> [ String ] {
        pinned.contains( identity ) ? pinned.filter { $0 != identity } : pinned + [ identity ]
    }

    /// A moderator's spotlight act through the engine, `done` once it is answered. A refusal is shown on the call, the
    /// route's own words where it gave some (a fifth person: "Up to four people can be in the spotlight.").
    static func send( _ identity: String?, on: Bool, screen: CallsScreen?, done: @escaping () -> Void ) {
        CallsEngine.shared.spotlight( identity: identity, on: on ) { [weak screen] ok, error in
            done()

            guard !ok else { return }

            screen?.showError( error ?? CallsTheme.string( "spotlight_failed", fallback: "The call server could not do this. Please try again." ) )
        }
    }
}
