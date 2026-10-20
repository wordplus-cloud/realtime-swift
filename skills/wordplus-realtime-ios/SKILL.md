---
name: wordplus-realtime-ios
description: Adds realtime features to an iOS (or macOS) app written in Swift with the WordPlus Cloud Swift package (WordPlusRealtime, WordPlusRealtimeCalls, WordPlusRealtimeUI), on the same rooms as the website of the app - rooms with emit, emitWithAck and volatile, presence and who is online, history so nothing is lost after the background, what the server of the app sends the user, video and audio calls between a phone and a browser, group calls, and the native call screen of Better Messages, all sealed end to end. Use when Swift code imports WordPlusRealtime, WordPlusRealtimeCalls or WordPlusRealtimeUI, or when an iOS task asks for live updates, chat, presence, websockets or calls on WordPlus Cloud.
---

# The WordPlus Cloud realtime SDK for iOS

The app joins rooms its server declares, with the server routes and the token it signed in with. The server is that of the website (Node, Laravel, Django …, with `@wordplus/realtime`, `wordplus/realtime-php` or `wordplus-realtime`): it declares rooms and calls, says who may join, signs it, and sends.

## Pick the feature

| The task asks for | Use | Guide |
|---|---|---|
| Updates sent from the server | `rt.join( "order:1042" ).on( "updated" )`. The server `to( room ).emit()` | [rooms](https://docs.wordplus.cloud/ios/rooms/), [sending](https://docs.wordplus.cloud/ios/sending/) |
| A notice to one user | `rt.on( "notice" )`. The server `toUser( id ).emit()` | [sending](https://docs.wordplus.cloud/ios/sending/#to-a-user) |
| Who is in a room, or online anywhere | a presence room `members`. `rt.online.watch( ids )` | [presence](https://docs.wordplus.cloud/ios/presence/) |
| Chat, typing, reactions | the room `emit` list on the server. `emitWithAck`, `volatile.emit` in the app | [events](https://docs.wordplus.cloud/ios/events/) |
| Calls, with a ring | `rt.calls.start`, `CallScreen.shared.attach( rt.calls )` | [calls](https://docs.wordplus.cloud/ios/calls/) |
| Calls that ring a locked phone and a closed app, through CallKit, and Recents | `SystemCalls.start( .init( name: ) ) { await connection() }` at launch, `SystemCalls.onCallBack`, `.onContinueUserActivity( "INStartCallIntent" ) { SystemCalls.handle( $0 ) }`, the APNs key on the Apps page | [calls](https://docs.wordplus.cloud/ios/calls/#ringing-a-locked-phone), [shipping](https://docs.wordplus.cloud/ios/shipping/#push-and-callkit) |
| A meeting | `rt.calls.group( "meeting:daily" )`, `CallScreen.shared.show( group )` | [calls](https://docs.wordplus.cloud/ios/calls/#group-calls) |
| A class, a town hall, an audio room: listeners let on to speak | `publish: false` in the rule, `permit( user, { publish: true } )` on the server, `group.onPermissions`, `GroupPerson.publish` | [calls](https://docs.wordplus.cloud/ios/calls/#speakers-and-listeners) |
| The call screen changed: its look, a piece of its own, or its whole code | `configure( .init( tokens: … ) )`, `CallScreen.shared.pieces`, `swift package wordplus-ui add` | [customizing](https://docs.wordplus.cloud/ios/customizing/) |

Prefer the Better Messages call screen (`WordPlusRealtimeUI`) unless the task asks for screens of its own. A screen the app makes itself draws the video of a group call with `GroupVideoView` (`show( person.identity, of: call )`, `showOwn( of: call )`).

A live stream (one presenting, everyone watching, with a chat): the `streams( 'show:{id}', … )` rule of the server, then `try await rt.calls.stream( name )` → `LiveStream` (`state`, `media`, `viewers`, `messages`, `tiles`, then `onChange`, `onMessage`, `onReactions`, `onEnded`, then `send`, `react`, `leave`, and for the host `preview`, `setCamera`, `setMicrophone`, `goLive`, `end`), its picture in a `LiveStreamVideoView` (`show( stream )`), or the whole of it drawn ready, `LiveStreamScreen( stream:, title: )` of `WordPlusRealtimeUI` (the picture, Live and the count, the chat and a heart, full screen): [live streams](https://docs.wordplus.cloud/ios/streams/).

## Customizing the call screen

Take the first step that does what the task asks ([customizing](https://docs.wordplus.cloud/ios/customizing/)):

1. **The look:** `CallScreen.shared.configure( .init( strings:, tokens:, tokensDark: ) )`: `--bm-color-accent` and the other colours, and those of the screen itself, `--bm-call-canvas` (the stage), `--bm-call-tile`, `--bm-call-btn` (each control) and `--bm-call-dock`, as the web names them.
2. **A piece:** `CallScreen.shared.pieces = .init( controls:, status:, ringing:, tile:, stage: )`. `controls` gets ours by id (`answer`, `settings`, `flip`, `camera`, `mute`, `speaker`, `pip`, `share`, `hand`, `people`, `end`) and returns the dock buttons. `CallScreen.CallControl( id:label:icon:action: )` is one the app adds (`icon` a 24-grid path, `CallControl.icons` has ours). Hanging up stays last.
3. **The code:** `swift package --allow-writing-to-package-directory wordplus-ui add --target <App>` copies the screen into the target `WordPlusUI/`, and its tests into the unit test target `WordPlusUITests/`. Then the target drops `WordPlusRealtimeUI` and adds `LiveKit` and `LiveKitWebRTC`. Change anything in the copy. Keep `WordPlusRealtimeCalls` under it.
   - **An Xcode project** (no `Package.swift`, only Xcode runs its plugins): after `xcodebuild -resolvePackageDependencies`, run `swift run --package-path <DerivedData>/…/SourcePackages/checkouts/realtime-swift wordplus-ui add --project <folder holding the .xcodeproj> --target <App>` (`--tests <folder>` when there is no `<App>Tests/`). The same flags for `diff`, `update`, `accept`. Do not compile the plugin files yourself.

- **After each change:** build, look at every state in `CallScreenPreview` (calling, ringing in, connecting, voice, video, microphone and camera off, the other side lost, reconnecting, group calls, its Dark and RTL buttons), run the copy tests on a simulator, then try a call both ways, a group call, the camera refused, the VoiceOver labels, picture in picture.
- **When the package updates:** `wordplus-ui diff`, `update` (takes ours where the app never changed a file), merge the rest, `accept`.

## Workflow

1. **The server** already answers the realtime routes for the website. Make it read the app user from its bearer token, and return `realtime.config( user )` with the token at sign-in ([getting started](https://docs.wordplus.cloud/ios/getting-started/#3-your-server-knows-the-app-user)).
2. **Add the package** `https://github.com/wordplus-cloud/realtime-swift` (from 1.0.0), and the products the app uses.
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
let call = try await rt.calls.start("support:34:42", to: "34", type: .video)
CallScreen.shared.show(call, name: "Ann")
```

## Rules

- **The app holds no secret:** the WordPlus Cloud secret and local key stay on the server. The app gets keys and identity from `config()`.
- **One `Realtime` per signed-in user,** shared by the app screens.
- **Handlers run on the main queue** by default. Keep heavy work off them.
- **User ids** are the app's own, digits or text, passed as strings (`"34"`, `"user_2abc"`).
- **Calls ring a closed app only with `SystemCalls` started at launch,** and never on a simulator, which has no PushKit or CallKit. The VoIP push is for calls alone: never register PushKit for anything else.
- **HTTPS** for the server in release builds. `NSAllowsLocalNetworking` for a simulator against `localhost` only.

## Verify

- `rt.onState` reaches `.connected`. No `error` event on `rt`.
- A room the user may join sends `joined`. One they may not sends `error` with `forbidden` (or `no_rule`).
- An emit from the server reaches the app handler opened, not as a sealed string.
- `emitWithAck` returns an `Ack`. An event the room does not list throws `not_allowed`.
- Calls: the app and a browser signed in as two users. Each rings the other. `call.state` reaches `.connected`.

## The guide

[Getting started](https://docs.wordplus.cloud/ios/getting-started/) · [rooms](https://docs.wordplus.cloud/ios/rooms/) · [presence](https://docs.wordplus.cloud/ios/presence/) · [sending](https://docs.wordplus.cloud/ios/sending/) · [events](https://docs.wordplus.cloud/ios/events/) · [calls](https://docs.wordplus.cloud/ios/calls/) · [encryption](https://docs.wordplus.cloud/ios/encryption/) · [customizing](https://docs.wordplus.cloud/ios/customizing/) · [shipping](https://docs.wordplus.cloud/ios/shipping/) · [the example app](https://docs.wordplus.cloud/ios/example/). The same pages are in this package `docs/ios/`.
