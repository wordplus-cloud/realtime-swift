# The example app

The API demo of every other guide, as a SwiftUI app: sign in as Ann (support), Ben (a customer) or Cara (the warehouse), and the app joins the same rooms as the shop web pages, so the app and a browser signed in as someone else see each other.

| What it shows | How |
|---|---|
| The order of Ben moving on, and a notice to Ben alone | the room `order:1042`, which the shop server emits to. `rt.on("notice")` for what it sends Ben ([sending](sending.md)) |
| Who is in the shop, and who is online | the presence room `shop`, and `rt.online.watch` ([presence](presence.md)) |
| The chat of Ann and Ben, with typing and its history | `chat:34:42`: `emitWithAck` for a message, `volatile` for typing, `history` when the app opens ([events](events.md)) |
| Calls with anyone in the shop, adding the third, and the daily meeting | `rt.calls.start`, `call.add`, `rt.calls.group`, on the Better Messages call screen ([calls](calls.md)) |
| Calls that ring the app closed, through CallKit, and calling back from Recents | `SystemCalls.start` at launch in `ExampleShopApp.swift`, the connection of whoever signed in last ([ringing a locked phone](calls.md#ringing-a-locked-phone)) |
| The live show of Ann: its picture, how many watch, and its chat | `rt.calls.stream("show:mugs")`, `LiveStreamVideoView` ([live streams](streams.md)) |

Its server is that of the Express example (realtime-js, `examples/express`), which signs the app in with `POST /api/token` and answers the realtime routes for its token, beside the shop web pages.

## The files

- `Example/ExampleShop/ExampleShopApp.swift`: the app, with `SystemCalls` started at launch.
- `Example/ExampleShop/Shop.swift`: signing in, the connection, the rooms and the calls, as an `ObservableObject`.
- `Example/ExampleShop/Views.swift`: the screens, with a bar of its own while the call screen is put away.
- `Example/ExampleShopUITests/ProofTests.swift`: the end-to-end test.

## Running it

```bash
cd realtime-js/examples/express && npm install && npm start   # the shop at http://localhost:3000
```

Open `Example/ExampleShop.xcodeproj` and run it in a simulator. Set `WORDPLUS_SHOP` in the scheme environment for a shop elsewhere. Sign in as someone else at the same address in a browser.

On an iPhone, pick your team under Signing and Capabilities, and set `WORDPLUS_SHOP` to the Mac's name on the network, `http://<name>.local:3000` (System Settings, General, Sharing, Local hostname). The app keeps the address, so a call that rings it closed finds the shop. A call rings the phone closed once the shop's app in WordPlus Cloud has an APNs key ([push and CallKit](shipping.md#push-and-callkit)), and the shop server runs with that app's key and secret.

## Tested end to end

`node test/native/proof.mjs ios`, in realtime-js, starts the shop and two realtime servers, signs Ann and Cara in on the shop page in Chromium, and runs `ProofTests` as Ben in the iOS Simulator:

- the order moving on, with the notice to Ben.
- presence and online status, both ways.
- typing and messages, both ways, and the chat from history after the app opens again.
- the app realtime server draining while the order moves on, with nothing lost.
- a call between the browser of Ann and the app, both ways, through the call screen, Cara added to it, and the daily meeting.
- a call from Ann ringing the app closed: the push that wakes it (a simulator has no PushKit, so the test gives it as a debug build's launch argument, into the same entry point), the app connecting as Ben and finding the call on his line, the answer the system's screen gives, and the call connected.
- the live show of Ann from her browser: its picture in the app, the app counted among those watching, the chat both ways, and its end.
