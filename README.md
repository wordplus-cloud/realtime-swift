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
rung into a call. Their screen is another, `WordPlusRealtimeUI`: Better Messages' native call screen (the ring, the
call between two, the group call's grid and the controls), the same files as Better Messages' app, so it improves
with it. Both are optional; an app that draws its own screen takes the calls alone.

```swift
import WordPlusRealtimeCalls
import WordPlusRealtimeUI

CallScreen.shared.configure(.init(strings: ["end_call": "Anruf beenden"]))
CallScreen.shared.attach(rt.calls)                    // rings for every call coming in, and shows it once answered
let call = try await rt.calls.start("support:34:42", to: "34", type: .video)
CallScreen.shared.show(call, name: "Ann")             // a call placed from the app
CallScreen.shared.show(try await rt.calls.group("meeting:daily"), title: "Daily meeting")
CallScreen.shared.onAnswered = { answered in … }      // the call a ring became, for the app to follow
```

The screen sits in a window of its own above the app. Its chevron puts it away and the call goes on;
`CallScreen.shared.restore()` brings it back.

## Docs

The iOS guide, on the web with every other: [docs.wordplus.cloud/ios](https://docs.wordplus.cloud/ios/getting-started/). The API reference is DocC's, from the doc comments and each module's catalog (`Sources/<module>/<module>.docc`), at [docs.wordplus.cloud/reference/ios](https://docs.wordplus.cloud/reference/ios/wordplusrealtime/documentation/wordplusrealtime/); Xcode builds it too (**Product → Build Documentation**).

[Getting started](docs/ios/getting-started.md) · [rooms](docs/ios/rooms.md) · [presence and online status](docs/ios/presence.md) · [sending from your server](docs/ios/sending.md) · [events from the app](docs/ios/events.md) · [calls](docs/ios/calls.md) · [encryption and your users](docs/ios/encryption.md) · [customizing the screens](docs/ios/customizing.md) · [shipping](docs/ios/shipping.md) · [the example app](docs/ios/example.md). For coding agents: [the skill](skills/wordplus-realtime-ios/SKILL.md).

## Tests

```bash
# The conformance vectors. The call screen is UIKit's, so the tests' target is built alone on a Mac:
swift build --target WordPlusRealtimeTests && swift test --skip-build
# with the API demo and two realtime nodes (in realtime-js: node test/native/serve.mjs):
WORDPLUS_SHOP=http://localhost:17533 WORDPLUS_CONTROL=http://127.0.0.1:17553 swift test --skip-build
# the call screen's pieces, on a simulator with no call:
xcodebuild test -scheme WordPlusRealtime-Package -only-testing:WordPlusRealtimeUITests -destination 'platform=iOS Simulator,name=iPhone 16'
# a stream's state, the system's ring and the rooms' codecs, on a simulator with no call:
xcodebuild test -scheme WordPlusRealtime-Package -only-testing:WordPlusRealtimeCallsTests -destination 'platform=iOS Simulator,name=iPhone 16'
# the screen the WordPlusUI plugin copies is the screen's own (after changing it: scripts/embed-ui.sh):
scripts/embed-ui.sh --check
```

The calls run on the WordPlus RTC client for Swift (`Vendor/rtc-client-swift`, LiveKit's Swift SDK with WordPlus Mesh's
patch, the `LiveKit` target). `scripts/rtc-client.sh <a build of it>` copies a new one in.

MIT licence.
