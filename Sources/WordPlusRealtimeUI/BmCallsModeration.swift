import UIKit

/// Running a group call from the phone.
///
/// Every action is the one REST route the web uses, so the permission checks,
/// the room updates and the record left behind are identical whichever screen
/// gave the order. Nothing here decides what someone may do — WordPress does,
/// and a refusal comes back as a refusal.
///
/// It is a list rather than a row of icons because a phone in a call already
/// has a full control row, and moderation is not something anyone does twice a
/// minute. It is drawn **on** the call screen rather than presented over it:
/// an action sheet is a piece of iOS laid on top of a call, and it took the
/// stage with it — see `BmCallsPanel`.
enum BmCallsModeration {
    /// The people, and what can be done about them.
    static func show(from screen: BmCallsScreen, participants: [BmCallsRoomParticipant]) {
        let engine = BmCallsEngine.shared
        let moderator = engine.canModerate

        var rows: [BmCallsPanelRow] = []

        // Your own hand first: it is the one thing everybody in the room can
        // do, and in broadcast mode it is the only way to ask to speak.
        if let me = participants.first(where: { $0.isLocal }) {
            if me.handRaised {
                rows.append(row("lower_hand", "Lower Hand") { engine.groupAdmin(action: "lower_own_hand") })
            } else {
                rows.append(row("raise_hand", "Raise Hand") { engine.groupAdmin(action: "raise_hand") })
            }
        }

        if moderator {
            // One of each pair, on the state the room is actually in. Muting
            // everyone is a rule the site keeps and the join route reports it
            // back, so a moderator walking into a room somebody else muted is
            // offered the way out of it — which is the whole reason both used
            // to be listed. The web draws this the same way now.
            if engine.roomMuted {
                rows.append(row("unmute_all", "Unmute All") { engine.groupAdmin(action: "unmute_all") })
            } else {
                rows.append(row("mute_all", "Mute All") { engine.groupAdmin(action: "mute_all") })
            }

            if engine.roomLocked {
                rows.append(row("unlock_room", "Unlock Room") { engine.groupAdmin(action: "unlock_room") })
            } else {
                rows.append(row("lock_room", "Lock Room") { engine.groupAdmin(action: "lock_room") })
            }

            if engine.callMode == "broadcast" {
                // Only worth offering while there is a hand to lower, which is
                // the web's own condition.
                if participants.contains(where: { $0.handRaised }) {
                    rows.append(row("lower_all_hands", "Lower All Hands") { engine.groupAdmin(action: "lower_all_hands") })
                }

                rows.append(row("participatory_mode", "Switch to Participatory Mode") { engine.groupAdmin(action: "set_participatory_mode") })
            } else {
                rows.append(row("broadcast_mode", "Switch to Broadcast Mode") { engine.groupAdmin(action: "set_broadcast_mode") })
            }

            // Everyone, each opening their own short list — this side included,
            // because pinning yourself is one of the things the web's own tile
            // controls offer.
            for person in participants {
                rows.append(BmCallsPanelRow(title: person.name) { [weak screen] in
                    guard let screen = screen else { return }

                    showPerson(from: screen, person: person)
                })
            }
        }

        guard !rows.isEmpty else { return }

        screen.showPanel(
            title: BmCallsTheme.string("participants", fallback: "Participants"),
            rows: rows
        )
    }

    /// One person's actions, reached by long-pressing their tile. Nothing
    /// opens for someone who cannot moderate: the route would refuse it
    /// anyway, and a menu of actions that all fail is worse than no menu.
    static func showFor(from screen: BmCallsScreen, person: BmCallsRoomParticipant) {
        guard BmCallsEngine.shared.canModerate else { return }

        showPerson(from: screen, person: person)
    }

    /// The web's own tile controls, in the order and on the conditions it
    /// draws them: pin for anyone, and for everybody else the broadcast right,
    /// the microphone, kicking, and — in a broadcast room — the promotion.
    private static func showPerson(from screen: BmCallsScreen, person: BmCallsRoomParticipant) {
        let engine = BmCallsEngine.shared
        let broadcast = engine.callMode == "broadcast"

        var rows: [BmCallsPanelRow] = []

        if person.isPinned {
            rows.append(row("unpin_participant", "Unpin Participant") {
                engine.groupAdmin(action: "unpin_participant", identity: person.identity)
            })
        } else {
            rows.append(row("pin_participant", "Pin Participant") {
                engine.groupAdmin(action: "pin_participant", identity: person.identity)
            })
        }

        if !person.isLocal {
            // In a broadcast room the right to publish is what promoting and
            // demoting are for, and offering both pairs would be two ways to
            // say the same thing. The web draws this pair only outside it.
            if !broadcast {
                if person.canPublish {
                    rows.append(row("block_broadcast", "Block Broadcast") {
                        engine.groupAdmin(action: "demote_participant", identity: person.identity)
                    })
                } else {
                    rows.append(row("allow_broadcast", "Allow Broadcast") {
                        engine.groupAdmin(action: "promote_participant", identity: person.identity)
                    })
                }
            }

            // `micMuted` is the moderator's own doing, which is what this
            // undoes. Somebody who simply has not switched their microphone on
            // is not muted by anyone.
            if person.canPublish {
                if person.micMuted {
                    rows.append(row("unmute_microphone", "Unmute Microphone") {
                        engine.groupAdmin(action: "unmute_mic", identity: person.identity)
                    })
                } else {
                    rows.append(row("mute_microphone", "Mute Microphone") {
                        engine.groupAdmin(action: "mute_mic", identity: person.identity)
                    })
                }
            }

            if person.handRaised {
                rows.append(row("lower_hand", "Lower Hand") {
                    engine.groupAdmin(action: "lower_hand", identity: person.identity)
                })
            }

            if broadcast, !person.canAdmin {
                if person.canPublish {
                    rows.append(row("demote_to_viewer", "Demote to Viewer") {
                        engine.groupAdmin(action: "demote_participant", identity: person.identity)
                    })
                } else {
                    rows.append(row("promote_to_speaker", "Promote to Speaker") {
                        engine.groupAdmin(action: "promote_participant", identity: person.identity)
                    })
                }
            }

            rows.append(BmCallsPanelRow(
                title: BmCallsTheme.string("kick_user", fallback: "Kick User"),
                destructive: true
            ) {
                engine.groupAdmin(action: "remove_participant", identity: person.identity)
            })
        }

        screen.showPanel(title: person.name, rows: rows)
    }

    private static func row(_ key: String, _ fallback: String, run: @escaping () -> Void) -> BmCallsPanelRow {
        BmCallsPanelRow(title: BmCallsTheme.string(key, fallback: fallback), run: run)
    }
}
