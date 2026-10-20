# The API demo for iOS

The API demo as a SwiftUI app on `WordPlusRealtime`: sign in as Ann (support), Ben (a customer) or Cara (the
warehouse), then watch the order of Ben move on, see who is in the shop and who is online, and chat with typing. It joins the
same rooms as the shop web pages, so the app and a browser signed in as someone else see each other. Calls between them
and the daily meeting run on `WordPlusRealtimeCalls`, drawn by the Better Messages call screen (`WordPlusRealtimeUI`).

- `ExampleShop/Shop.swift`: signing in, the connection and the rooms (the order, presence, online status, the chat with
  acks, typing and history).
- `ExampleShop/Views.swift`: the screens.
- `ExampleShopUITests/ProofTests.swift`: the end-to-end test, with a browser on the other side.

## Running it

The app server is the Express example in realtime-js (`examples/express`), which signs the app in with
`POST /api/token` and answers its realtime routes. Locally, with a realtime server of your own:

```bash
cd ../../realtime-js && node test/native/serve.mjs   # the shop at http://localhost:17533, two realtime nodes
```

Open `ExampleShop.xcodeproj`, set `WORDPLUS_SHOP=http://localhost:17533` in the scheme environment (the app expects
`http://localhost:3000` otherwise, the Express example `npm start`), and run it in a simulator. Sign in as someone else
at the same address in a browser.

## The proof

```bash
cd ../../realtime-js && node test/native/proof.mjs ios
```

It starts the shop and the nodes, signs Ann in on the shop page in Chromium, and runs `ProofTests` as Ben: the order
moving on with the notice of Ben, presence and online status both ways, typing and messages both ways, the chat from history
after the app opens again, and the app node draining while the order moves on.
