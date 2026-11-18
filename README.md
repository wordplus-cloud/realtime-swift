# WordPlusRealtime for Swift

WordPlus Cloud's realtime SDK for iOS and macOS apps: rooms with events and acks, presence, live counts, history, who
is online and what the app's server sends the user, on the same realtime servers and protocol as the browser's, sealed
end to end with keys only the app's server hands out.

```swift
let rt = Realtime(RealtimeOptions(app: "s1500000007", endpoint: URL(string: "https://shop.example.com/api/realtime")!,
                                  headers: { ["Authorization": "Bearer \(session.token)"] }))
rt.connect()
let chat = rt.join("chat:34:42")
chat.on("message") { message, meta in show(message, from: meta.from) }
let ack = try await chat.emitWithAck("message", ["text": "Hi"])
chat.volatile.emit("typing", ["on": true])
rt.online.watch(["34"]).on("change") { change in dot(change) }
rt.on("notice") { notice, _ in toast(notice) }
```

The app's server answers the routes as every server package does (`{endpoint}/auth`, `/keys`): the same Express,
Laravel or Django server its web pages use. The connection goes straight to the realtime nodes and moves between them
without a drop, as the browser's does.

The API demo as a SwiftUI app, and the end-to-end proof with a browser on the other side, are in
[`Example/`](Example/README.md).

## Calls, and their screen

Calls are a product of their own, `WordPlusRealtimeCalls`, so an app that only uses rooms carries no WebRTC: calls
between two people (direct, through TURN when they must, or in a room when neither works), group calls, and someone
rung into a call. Their screen is another, `WordPlusRealtimeUI`: the native call screen of Better Messages (the ring, the
call between two, the group call's grid and the controls), the same files as the Better Messages app, so it improves
with it. Both are optional. An app that draws its own screen takes the calls alone.

```swift
import WordPlusRealtimeCalls
import WordPlusRealtimeUI

CallScreen.shared.configure(.init(strings: ["end_call": "Anruf beenden"]))
CallScreen.shared.attach(rt.calls)                    // rings for every call coming in, and shows it once answered
let call = try await rt.startCall(token)              // a token from your server, after its own check: callToken( user, to )
CallScreen.shared.show(call, name: "Ann")             // a call placed from the app
CallScreen.shared.show(try await rt.joinGroupCall(groupToken), title: "Daily meeting")   // groupCallToken( user, name )
CallScreen.shared.onAnswered = { answered in … }      // the call a ring became, for the app to follow
```

The screen sits in a window of its own above the app. `CallScreen.shared.hide()` puts it away and the call goes on, from a
button of yours in its dock, and `CallScreen.shared.restore()` brings it back. `CallScreen.shared.addPerson = true` puts Add
Person in the dock.

The same module has who is online as the web draws it, `OnlineList`, `PersonRow`, `RowAction`, `OnlineCount`, `Avatar` and
`ActivityIndicator`, from what the app gives them, with no room behind them ([the views](docs/ios/presence.md#the-views)).

## Docs

The iOS guide, on the web with every other: [docs.wordplus.cloud/ios](https://docs.wordplus.cloud/ios/getting-started/). The API reference is DocC's, from the doc comments and each module's catalog (`Sources/<module>/<module>.docc`), at [docs.wordplus.cloud/reference/ios](https://docs.wordplus.cloud/reference/ios/wordplusrealtime/documentation/wordplusrealtime/). Xcode builds it too (**Product → Build Documentation**).

[Getting started](docs/ios/getting-started.md) · [rooms](docs/ios/rooms.md) · [presence and online status](docs/ios/presence.md) · [sending from your server](docs/ios/sending.md) · [events from the app](docs/ios/events.md) · [calls](docs/ios/calls.md) · [encryption and your users](docs/ios/encryption.md) · [customizing the screens](docs/ios/customizing.md) · [shipping](docs/ios/shipping.md) · [the example app](docs/ios/example.md). For coding agents: [the skill](skills/wordplus-realtime-ios/SKILL.md).

## Tests

```bash
# The conformance vectors. The call screen is drawn with UIKit, so the target of these tests is built alone on a Mac, and
# its bundle run alone, as `swift test` would also run the three bundles it didn't build, and fail on them:
swift build --target WordPlusRealtimeTests && xcrun xctest "$(swift build --show-bin-path)/WordPlusRealtimeTests.xctest"
# with the API demo and two realtime nodes (in realtime-js: node test/native/serve.mjs):
WORDPLUS_SHOP=http://localhost:17533 WORDPLUS_CONTROL=http://127.0.0.1:17553 xcrun xctest "$(swift build --show-bin-path)/WordPlusRealtimeTests.xctest"
# calls from your server's tokens, against a local realtime server and media server, with browsers as the other side
# (WordPlus's own rig, which needs its checkouts and stays out of the release):
node scripts/token-calls-rig.mjs   # READY <address>, then:
TEST_RUNNER_WORDPLUS_TOKEN_RIG=<address> xcodebuild test -scheme WordPlusRealtime-Package -only-testing:WordPlusRealtimeCallsTests/TokenCallsLiveTests -destination 'platform=iOS Simulator,name=iPhone 16'
# the call screen's pieces, on a simulator with no call:
xcodebuild test -scheme WordPlusRealtime-Package -only-testing:WordPlusRealtimeUITests -destination 'platform=iOS Simulator,name=iPhone 16'
# the state of a stream, the ring of the system and the codecs of the rooms, on a simulator with no call:
xcodebuild test -scheme WordPlusRealtime-Package -only-testing:WordPlusRealtimeCallsTests -destination 'platform=iOS Simulator,name=iPhone 16'
# the screen the WordPlusUI plugin copies is the screen's own (after changing it: scripts/embed-ui.sh):
scripts/embed-ui.sh --check
```

The calls run on the WordPlus RTC client for Swift (`Vendor/rtc-client-swift`, LiveKit's Swift SDK with WordPlus Mesh's
patch, the `LiveKit` target, offered as the product `WordPlusRTC` and under `LiveKit`, the name it had first).
`scripts/rtc-client.sh <a build of it>` copies a new one in.

A group call sends what the media server's settings for its clients say (`GroupShapes`, the client's `MeshSettings`),
as the browsers do: the microphone's bitrate, RED (never into an encrypted room), DTX and processing, the camera's
capture, codecs, top layer and ladder, the tallest it goes out at in software, the connect's timeouts, reconnect waits
and join budget. Where the server says nothing, the defaults of the settings, the values browsers use. Its join names the
package (`realtime-swift` and `RealtimeCalls.version`, which a release keeps in step with `scripts/embed-ui.sh`'s).

MIT licence.
