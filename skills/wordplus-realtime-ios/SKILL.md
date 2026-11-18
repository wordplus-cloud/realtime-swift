---
name: wordplus-realtime-ios
description: Adds realtime features to an iOS (or macOS) app written in Swift with the WordPlus Cloud Swift package (WordPlusRealtime, WordPlusRealtimeCalls, WordPlusRealtimeUI), on the same rooms as the website of the app - rooms with emit, emitWithAck and volatile, presence and who is online, history so nothing is lost after the background, what the server of the app sends the user, video and audio calls between a phone and a browser, group calls, live streams, and the native call and stream screens of Better Messages, rooms sealed end to end and calls encrypted end to end. Use when Swift code imports WordPlusRealtime, WordPlusRealtimeCalls or WordPlusRealtimeUI, or when an iOS task asks for live updates, chat, presence, websockets or calls on WordPlus Cloud.
---

# The WordPlus Cloud realtime SDK for iOS

The app joins rooms its server declares, with the server routes and the token it signed in with. The server is that of the website (Node, Laravel, Django …, with `@wordplus/realtime`, `wordplus/realtime-php` or `wordplus-realtime`): it declares rooms and calls, says who may join, signs it, and sends.

## Pick the feature

| The task asks for | Use | Guide |
|---|---|---|
| Updates sent from the server | `rt.join( "order:1042" ).on( "updated" )`, `once`, `off`. The server `to( room ).emit()` | [rooms](https://docs.wordplus.cloud/ios/rooms/), [sending](https://docs.wordplus.cloud/ios/sending/) |
| A notice to one user | `rt.on( "notice" )`. The server `toUser( id ).emit()` | [sending](https://docs.wordplus.cloud/ios/sending/#to-a-user) |
| Who is in a room, or online anywhere | a presence room `members`. `rt.online.watch( ids )` | [presence](https://docs.wordplus.cloud/ios/presence/) |
| Drawing who is online and who is typing | `OnlineList`, `PersonRow`, `RowAction`, `OnlineCount`, `Avatar`, `ActivityIndicator`, fed by the app from a room's `members`: none reads a room | [presence](https://docs.wordplus.cloud/ios/presence/#the-views) |
| Chat, typing, reactions | the room `emit` list on the server. `emitWithAck`, `volatile.emit`, `volatile.emitWithAck` in the app | [events](https://docs.wordplus.cloud/ios/events/) |
| Calls, with a ring | `rt.calls.start`, `CallScreen.shared.attach( rt.calls )` | [calls](https://docs.wordplus.cloud/ios/calls/) |
| Calls, group calls and streams the app's own logic decides, from a token its route answers | `rt.startCall( token )`, `rt.joinGroupCall( token )`, `rt.joinStream( getToken: )`, `call.add( token )`, with `call.ref` for the route's `into`. The server's `callToken`, `groupCallToken`, `streamToken` | [calls](https://docs.wordplus.cloud/ios/calls/#starting-with-a-token-from-your-server) |
| Calls that ring a locked phone and a closed app, through CallKit, and Recents | `SystemCalls.start( .init( name: ) ) { await connection() }` at launch, `SystemCalls.onCallBack`, `.onContinueUserActivity( "INStartCallIntent" ) { SystemCalls.handle( $0 ) }`, the APNs key on the Apps page | [calls](https://docs.wordplus.cloud/ios/calls/#ringing-a-locked-phone), [shipping](https://docs.wordplus.cloud/ios/shipping/#push-and-callkit) |
| A meeting | `rt.calls.group( "meeting:daily" )`, `CallScreen.shared.show( group )` | [calls](https://docs.wordplus.cloud/ios/calls/#group-calls) |
| A class, a town hall, an audio room: listeners let on to speak | `publish: false` in the rule, `permit( user, { publish: true } )` on the server, `group.onPermissions`, `GroupPerson.publish` | [calls](https://docs.wordplus.cloud/ios/calls/#speakers-and-listeners) |
| A host muting, removing or ending for everyone | `admin: true` in the rule. The call screen gives the host its menus. In a screen of your own, `group.mute( "42" )`, `makeListener`, `letSpeak`, `remove`, `spotlightOn`, `spotlightOff`, through the calls route. The app hears it in `onPeople`, `onPermissions`, `onSpotlit`, `onEnded( "removed" )`, `onEnded( "closed" )` | [calls](https://docs.wordplus.cloud/ios/calls/#the-host) |
| Moderating a group call as in Better Messages: bans, a held microphone, Mute Everyone, Lock, Broadcast Mode, raised hands, asks to turn on, End for Everyone | Only acts in `group.acts` (`CallAct`), the rest throw `not_offered`. A host: `group.ban( "42", minutes: 60 )`, `unban`, `holdMic`, `releaseMic`, `setRules( mode:locked:muted: )`, `lowerHand( of: )`, `lowerAllHands()`, `askToTurnOn( "42", devices: [ .camera ] )`, `end()`. Everyone: `raiseHand()`, `lowerHand()`, `onAsk` and `answerAsk`, `can.micHeld` and `turnOnMicrophone()`. Room state: `rules`, `onRules`, `hands`, `onHands`. Tiles: `GroupPerson.reconnecting`, `stalled`, `micHeld`. A join throws `banned` (with `until`) or `locked`, and `CallScreen.refusal( error )` words it. The server takes the same acts with `by` | [calls](https://docs.wordplus.cloud/ios/calls/#moderating-a-group-call) |
| Who may be added or called, for a list of people | `rt.calls.people( name )`, `rt.calls.may( [ CallAsk( call: name, to: id ) ] )` | [calls](https://docs.wordplus.cloud/ios/calls/#calls-of-your-own) |
| Keeping to rules of the app in every call, the call screen's too | `rt.calls.onCall`, `rt.calls.onGroup`, and `off( listener )` for any handler | [calls](https://docs.wordplus.cloud/ios/calls/#calls-of-your-own) |
| Following a ring into a group call, or calling it off | `invite.onState`, `invite.canCancel`, `invite.cancel()`, `group.invites`, `group.onInvite` | [calls](https://docs.wordplus.cloud/ios/calls/#adding-people) |
| Add Person on the call screen | `CallScreen.shared.addPerson = true`, off by default | [calls](https://docs.wordplus.cloud/ios/calls/#on-the-call-screen) |
| What goes wrong in a group call, a join that waits for a place, this user's own tile | `group.onError`, `group.waiting`, `group.onWaiting`, `group.me` | [calls](https://docs.wordplus.cloud/ios/calls/#group-calls) |
| Sharing the screen on a call, a group call or a stream, and the screen the other side shares | `ScreenShare.isAvailable`, `setScreenShare( on )`, `sharingScreen`, `onScreenShare`, `call.remoteScreen` | [calls](https://docs.wordplus.cloud/ios/calls/#sharing-the-screen) |
| A live stream, its webhooks, what the server does with it | the `streams()` rule, `rt.calls.stream( name )`, the server's `stream( name )` and `stream.live`, `stream.ended` webhooks | [live streams](https://docs.wordplus.cloud/ios/streams/) |
| The connection's state | `rt.state`, `rt.onState`, `rt.on( "error" )`, `rt.on( "moved" )` | [getting started](https://docs.wordplus.cloud/ios/getting-started/#the-connection) |
| The call screen changed: its look, a piece of its own, or its whole code | `configure( .init( tokens: … ) )`, `CallScreen.shared.pieces`, `swift package wordplus-ui add` | [customizing](https://docs.wordplus.cloud/ios/customizing/) |

Prefer the Better Messages call screen (`WordPlusRealtimeUI`) unless the task asks for screens of its own. A screen the app makes itself draws the video of a group call with `GroupVideoView` (`show( person.identity, of: call )`, `showOwn( of: call )`).

A live stream (one presenting, everyone watching, with a chat): the `streams( 'show:{id}', … )` rule of the server, then `try await rt.calls.stream( name )` (`video: false` for a screen with no picture, `watch()` later) → `LiveStream` (`state`, `media`, `viewers`, `messages`, `tiles`, then `onChange`, `onMessage`, `onReactions`, `onEnded`, then `send`, `react`, `leave`, `qualities`, `setQuality`, `stats`, `audience`, `waiting` with its reason, for a viewer `canAskStage`, `hand`, `joinStage`, `declineStage`, `leaveStage`, and for the host `preview`, `setCamera`, `setMicrophone`, `setScreenShare`, `goLive`, `end`), its picture in a `LiveStreamVideoView` (`show( stream )`), or the whole of it drawn ready, `LiveStreamScreen( stream:, title: )` of `WordPlusRealtimeUI` (the picture, Live and the count, the chat and a heart, what a viewer does about the stage, full screen): [live streams](https://docs.wordplus.cloud/ios/streams/).

## Customizing the call screen

Take the first step that does what the task asks ([customizing](https://docs.wordplus.cloud/ios/customizing/)):

1. **The look:** `CallScreen.shared.configure( .init( strings:, tokens:, tokensDark: ) )`: `--wplus-color-accent` and the other colours, and those of the screen itself, `--wplus-call-canvas` (the stage), `--wplus-call-tile`, `--wplus-call-btn` (each control) and `--wplus-call-dock`, as the web names them. Their names before, `--bm-…`, still work.
2. **A piece:** `CallScreen.shared.pieces = .init( controls:, status:, ringing:, tile:, stage: )`. `controls` gets ours by id (`answer`, `flip`, `camera`, `mute`, `speaker`, `pip`, `host`, `end`, each where the screen shows it, `share` where the app has the extension, `add` with `CallScreen.shared.addPerson` on, and `settings`, a gear that opens Device Settings: no raise hand) and returns the dock buttons. `CallScreen.CallControl( id:label:icon:action: )` is one the app adds (`icon` a 24-grid path, `CallControl.icons` has ours). Hanging up stays last.
3. **The code:** `swift package --allow-writing-to-package-directory wordplus-ui add --target <App>` copies the screen into the target `WordPlusUI/`, and its tests into the unit test target `WordPlusUITests/`. Then the target drops `WordPlusRealtimeUI` and adds `LiveKit` and `LiveKitWebRTC`. Change anything in the copy. Keep `WordPlusRealtimeCalls` under it.
   - **An Xcode project** (no `Package.swift`, only Xcode runs its plugins): after `xcodebuild -resolvePackageDependencies`, run `swift run --package-path <DerivedData>/…/SourcePackages/checkouts/realtime-swift wordplus-ui add --project <folder holding the .xcodeproj> --target <App>` (`--tests <folder>` when there is no `<App>Tests/`). The same flags for `diff`, `update`, `accept`. Do not compile the plugin files yourself.

- **After each change:** build, look at every state in `CallScreenPreview` (calling, ringing in, connecting, voice, video, microphone and camera off, the other side lost, reconnecting, group calls, its Dark and RTL buttons), run the copy tests on a simulator, then try a call both ways, a group call, the camera refused, the VoiceOver labels, picture in picture.
- **When the package updates:** `wordplus-ui diff`, `update` (takes ours where the app never changed a file), merge the rest, `accept`.

## Workflow

1. **The server** already answers the realtime routes for the website. Make it read the app user from its bearer token, and return `realtime.config( user )` with the token at sign-in ([getting started](https://docs.wordplus.cloud/ios/getting-started/#3-your-server-knows-the-app-user)).
2. **Add the package** `https://github.com/wordplus-cloud/realtime-swift` (from 1.1.0), and the products the app uses.
3. **Connect once** per signed-in user: `Realtime( RealtimeOptions( config: config, base: server, headers: { [ "Authorization": "Bearer \(token)" ] } ) )`, then `rt.connect()`. `rt.close()` at sign-out.
4. **Join rooms and listen.** Send from the app only what a room `emit` lists, and everything that matters through the server.
5. **Calls:** add `NSMicrophoneUsageDescription` and `NSCameraUsageDescription`. Attach the call screen once after connecting. For calls that ring a closed app: `SystemCalls.start` in `application(_:didFinishLaunchingWithOptions:)` with a closure that gives the signed-in user's connection, the Push Notifications capability, the `voip` and `audio` background modes, and `rt.calls.stopRinging()` at sign-out.
6. **Verify** (below).

## Template

```swift
import WordPlusRealtime
import WordPlusRealtimeCalls
import WordPlusRealtimeUI

let rt = Realtime(RealtimeOptions(config: config, base: server, headers: { ["Authorization": "Bearer \(token)"] }))
rt.connect()

let order = rt.join("order:1042")
order.on("updated") { data, _ in status = data["status"]?.string ?? status }

let chat = rt.join("chat:34:42")
chat.on("message") { data, meta in add(from: meta.from, text: data["text"]?.string, id: meta.id) }
let ack = try await chat.emitWithAck("message", ["text": "Hi"])
chat.volatile.emit("typing", ["on": true])

CallScreen.shared.attach(rt.calls)
let call = try await rt.calls.start("support:{pair}", to: "34", type: .video)
CallScreen.shared.show(call, name: "Ann")
```

## Rules

- **The app holds no secret:** the WordPlus Cloud secret and local key stay on the server. The app gets keys and identity from `config()`.
- **One `Realtime` per signed-in user,** shared by the app screens.
- **Handlers run on the main queue** by default. Keep heavy work off them.
- **User ids** are the app's own, digits or text, passed as strings (`"34"`, `"user_2abc"`).
- **Calls ring a closed app only with `SystemCalls` started at launch,** and never on a simulator, which has no PushKit or CallKit. The VoIP push is for calls alone: never register PushKit for anything else.
- **HTTPS** for the server in release builds. `NSAllowsLocalNetworking` for a simulator against `localhost` only.
- **Screen share on iOS** needs a broadcast extension in the app ([shipping](https://docs.wordplus.cloud/ios/shipping/#sharing-the-screen)), and a simulator cannot run one: `ScreenShare.isAvailable` is false there, so do not write it into a test.
- **Do not write what the iOS SDK lacks:** no moderation act the call does not offer (raising a hand and ending a call for everyone from the app need `hand` and `end` in `group.acts`, which a server package from before them does not name), and no recording of a call: WordPlus Cloud has no recording route for apps yet. A live stream is not end to end encrypted.
- **Server rules written out,** as the guide writes them: a plain sentence of what each rule decides, then the rule with numbered comments, never a one-line chain of `&&`.

## Verify

- `rt.onState` reaches `.connected`. No `error` event on `rt`.
- A room the user may join sends `joined`. One they may not sends `error` with `forbidden` (or `no_rule`).
- An emit from the server reaches the app handler opened, not as a sealed string.
- `emitWithAck` returns an `Ack`. An event the room does not list throws `not_allowed`.
- Calls: the app and a browser signed in as two users. Each rings the other. `call.state` reaches `.connected`.

## The guide

[Getting started](https://docs.wordplus.cloud/ios/getting-started/) · [rooms](https://docs.wordplus.cloud/ios/rooms/) · [presence](https://docs.wordplus.cloud/ios/presence/) · [sending](https://docs.wordplus.cloud/ios/sending/) · [events](https://docs.wordplus.cloud/ios/events/) · [calls](https://docs.wordplus.cloud/ios/calls/) · [live streams](https://docs.wordplus.cloud/ios/streams/) · [encryption](https://docs.wordplus.cloud/ios/encryption/) · [customizing](https://docs.wordplus.cloud/ios/customizing/) · [shipping](https://docs.wordplus.cloud/ios/shipping/) · [the example app](https://docs.wordplus.cloud/ios/example/). The same pages are in this package `docs/ios/`.
