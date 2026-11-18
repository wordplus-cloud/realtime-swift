# Changelog

## 1.1.1 - 2026-11-18

### Fixed

- The package builds with Xcode 16 again: 1.1.0's call screen stopped it with "ambiguous use of
  'init(priority:operation:)'". A call screen added to an app with `swift package wordplus-ui add` from 1.1.0 has the
  same line: add it again from 1.1.1, or change it as `CallScreen.swift` has it now.

## 1.1.0 - 2026-11-18

Every name that worked in 1.0.3 still works. This release also carries the changes made for 1.0.4, which was never
published.

### New

- **You decide who may call.** A call, a group call and a live stream start from a token your own route makes:
  `rt.startCall( token )`, `rt.joinGroupCall( token )`, `rt.joinStream( getToken: )`, `call.ref` and `call.add( token )`.
- **Shorter ways in.** `rt.call( "support:{pair}", to: "34" )`, `rt.groupCall( name )` and `rt.stream( name )`, and
  `remove( user )` on a stream with `kick( user )` the same. A room of two people by name:
  `try rt.join( "chat:{pair}", with: "34" )`, with `rt.room` and `rt.leave`.
- **Group calls moderated as in Better Messages,** the same as on the web. A host's call screen has Remove and Ban from
  Calls (for the minutes given, at most a week), Mute Microphone that holds until Allow Microphone, Ask to Turn On, and
  Host Controls with Mute Everyone, Lock Room and Broadcast Mode, whose switches follow the room, so a second host sees
  what the first one set. Everyone may raise a hand, which every host sees, those who join later too. The tile of someone
  who dropped is kept for 20 seconds, in case they come back, and media that stalls is marked. In a screen of your own: `group.acts`
  (`CallAct`), `ban( _:minutes: )`, `unban`, `holdMic`, `releaseMic`, `setRules( mode:locked:muted: )`, `rules` and
  `onRules`, `hands` and `onHands`, `raiseHand()`, `lowerHand()`, `lowerHand( of: )`, `lowerAllHands()`,
  `askToTurnOn( _:devices: )`, `onAsk`, `answerAsk`, `onAskAnswer`, `end()` for everyone, `can.micHeld` and
  `turnOnMicrophone()`, `onPersonAway`, `onStalled`, and `GroupPerson.reconnecting`, `stalled` and `micHeld`. A join
  refused throws `banned` (with `until`) or `locked`, and `CallScreen.refusal( error )` gives the words. Only the acts
  both WordPlus Cloud and your server package name are offered, so with a package from before them the screen is as it
  was. Leaving a call says goodbye first, so the others drop the tile at once.
- **Spotlight on the call screen.** Spotlight for Everyone in a group call, Pin for Me, and a host that knows and moderates its group call.
- **A fuller call screen.**
  - Device Settings from the dock in every call: the device in use opens the system's own menu, with the level of a live
    microphone and the side the next camera opens on.
  - Host Controls with Sound for Raised Hands, Join Alerts, Lower All Hands and End for Everyone.
  - A moderator asks someone to turn on their camera or microphone, and Add Person (`CallScreen.shared.addPerson`).
  - Picture in picture for group calls, a join notice with Preview and Do Not Show Again, and Show Chat as a dock button.
  - Controls at the web's size, and a group call's own tile showing your name and picture from the first moment.
- **Screen sharing** from this phone in a call, a group call and a live stream (where the app has a broadcast extension):
  `setScreenShare( on )` and `sharingScreen`; and `call.remoteScreen` for the screen the other side shares.
- **Live streams.** Viewers wait for a place when a stream is full, ask for the stage, answer an invitation, and go on
  stage with camera, microphone and Leave stage. `qualities()`, `setQuality()` and `stats()` hold the picture to a layer.
  `rt.calls.stream( name, video: false )` joins without the picture, and `show.watch()` fetches it later.
- **Who is online in UIKit:** `OnlineList`, `PersonRow`, `RowAction`, `OnlineCount`, `Avatar`, `PresenceDot`, `TypingDots`
  and `ActivityIndicator`.
- **Rooms.** `once` and `off( event )` on the connection and on a room, `volatile.emitWithAck`, several rooms joined or left
  in one request, and an error when an online-status watch is refused, so a screen no longer shows everyone offline with
  no word why.
- **Calls API.** `rt.calls.onCall` and `onGroup` hear every call started or answered, handlers can be taken off
  (`on...` gives a `CallListener`), `rt.calls.people( name )` and `rt.calls.may( ... )`, `group.me`, `group.onError`, and
  `group.waiting` (a join waiting for a place). A ring into a group call is followed to its end and can be called off
  with `cancel()`. A group call ends as `removed` or `closed` as the browser's does.
- **Your own signalling and server.** `CallTransport` is public, so a call's signalling can travel by a transport of your
  own and still run on the SDK's engine and screens; `rt.calls.call( over: ... )` joins a call on one. A connection can
  open another server namespace (`RealtimeOptions.namespace` and `auth`). Rings of your own, and a hook on each request to
  your routes.
- **Sound comes first.** While a person talks in a group call their microphone is kept clear: it comes down to 32 kbps on
  its own loss, gives way to the camera on a slow upload and in a lost or re-asked stream, and the picture steps down
  before the sound does. A direct call's camera may send 10 Mbps on a direct path.

### Changed

- The call screen takes the web's `--wplus-...` token names (it looked for `--bm-...` alone).
- A room you are kicked out of or that fails forgets its people, and a held room's token and your identity are asked for
  again before they run out.
- Joining a group call again after being removed, or after it ended for everyone, waits for the next second, as the browser does.
- The direct call's report, round trip and bandwidth estimates read the candidate pair the connection actually uses.
- The call screen's internal files and types no longer carry a product prefix; nothing an app calls changed (`CallScreen`,
  `CallScreenPreview` and their configuration are as they were).
- `RealtimeCalls.version` is `1.1.0`.

### Fixed

- A call whose caller heard its relay seconds late never connected; a direct call now holds out over a stalled socket and
  never lets an ICE restart cross an answer.
- A direct call's camera no longer sits at 30 kbps because of an audio sender with nothing to send.
- A press in a popup (Device Settings, the join notice, End for Everyone) was taken by the screen and did nothing.
- A call in the band beside a chat started under an empty strip the height of the status bar.
- A ring answered or declined on this device says it is over, so a ring an app drew goes away.
