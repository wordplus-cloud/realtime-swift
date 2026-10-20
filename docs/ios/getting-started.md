# Getting started with iOS

Live updates, chat, who is online and calls in an iOS app written in Swift, through WordPlus Cloud. The app joins the same rooms as your web pages, so a customer in the app and an agent in a browser see each other, and a phone and a browser call each other. Your server stays the one your website has ([Next.js](https://docs.wordplus.cloud/nextjs/getting-started/), [Laravel](https://docs.wordplus.cloud/laravel/getting-started/), [Django](https://docs.wordplus.cloud/django/getting-started/), [Express](https://docs.wordplus.cloud/express/getting-started/) …): it declares the rooms, says who may join and call, and sends.

The SDK comes as three products of one Swift package, and an app takes only what it uses:

| Product | What it gives | Needs |
|---|---|---|
| `WordPlusRealtime` | rooms, events with acks, presence, counts, history, who is online, what your server sends the user, the directory | iOS 15 or macOS 12. Nothing else |
| `WordPlusRealtimeCalls` | calls between two people, group calls, ringing someone into a call | WebRTC and LiveKit, which it brings |
| `WordPlusRealtimeUI` | The Better Messages call screen: the ring, the call, the group call grid and the controls | iOS |

The names are those of the browser: `join`, `on`, `emit`, `emitWithAck`, `volatile`, `history`, `members`, `count`, `online`, `calls.start`, `calls.group`. The [example app](example.md) is the shop of every other guide, in SwiftUI.

## 1. Your app in WordPlus Cloud

**Apps are in early access.** Ask for it on our [contact form](https://www.wordplus.cloud/contact), and we turn **Apps** on in your WordPlus Cloud account. Until then your account has no Apps page.

Use the app you made for your website (**Apps** in your WordPlus Cloud account), so the app and the site share rooms and users. A native app has no address to list: it is let in by itself.

## 2. Install

In Xcode, **File → Add Package Dependencies**, then `https://github.com/wordplus-cloud/realtime-swift`, and add the products your app uses to its target. In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/wordplus-cloud/realtime-swift", from: "1.0.0"),
],
targets: [
    .target(name: "Shop", dependencies: [
        .product(name: "WordPlusRealtime", package: "realtime-swift"),
        .product(name: "WordPlusRealtimeCalls", package: "realtime-swift"),   // for calls
        .product(name: "WordPlusRealtimeUI", package: "realtime-swift"),      // for the Better Messages call screen
    ]),
]
```

## 3. Your server knows the app user

An app has no cookie of your site, so it sends its own sign-in with every request, such as a bearer token, and your server routes read the user from it. When the app signs in, send it the user realtime settings too, so it connects with no request first:

**Node**

```ts
// Express: the user of the session in a browser, that of the token in an app.
app.use( '/api/realtime', realtime.node( ( req ) => req.session.userId ?? userFromToken( req.get( 'authorization' ) ) ) );

app.post( '/api/token', express.json(), async ( req, res ) => {
    const user = await checkSignIn( req.body );
    res.json( { token: tokenFor( user ), realtime: await realtime.config( user.id ) } );
} );
```

**PHP**

```php
// Laravel: the package routes take $request->user(). Add the middleware that signs in the tokens of your app to
// 'routes' => [ 'middleware' => [ … ] ] in config/wordplus-realtime.php. Then, at sign-in:
return [ 'token' => $user->createToken( 'app' )->plainTextToken, 'realtime' => Realtime::config( $user->id ) ];

// Plain PHP: the user of the token to respond()
$realtime->respond( $action, user_from_token( $_SERVER['HTTP_AUTHORIZATION'] ?? '' ) );
```

**Python**

```python
# Django: who the user is, by your own function
path("api/realtime/", include(wr.urls(realtime, user=lambda request: user_from_token(request.headers.get("Authorization")))))

# FastAPI: current_user reads the token
app.include_router(wr.router(realtime, current_user), prefix="/api/realtime")

# At sign-in, in any of them
return {"token": token_for(user), "realtime": realtime.config(user.id)}
```

## 4. Connect

```swift
import WordPlusRealtime

let server = URL(string: "https://shop.example.com")!
let (token, config) = try await signIn()   // your own sign-in, answering { token, realtime }

let rt = Realtime(RealtimeOptions(config: config, base: server, headers: { ["Authorization": "Bearer \(token)"] }))
rt.connect()

let order = rt.join("order:1042")
order.on("updated") { data, _ in status = data["status"]?.string ?? status }
order.on("error") { error, _ in print(error["code"]?.string ?? "") }   // forbidden, no_rule …
```

- **`RealtimeOptions(config:base:headers:)`** takes your server `config()` as it came, its routes resolved against your server address. Without one, give `app`, `endpoint` (your routes in full, `https://shop.example.com/api/realtime`) and `headers`, and the app asks your keys route first. A route at an address of its own goes in `routes`, in full: `routes: ["calls": URL(string: "https://shop.example.com/check-call")!]`. From `config()` it comes by itself.
- **One `Realtime` an app**, kept while the user is signed in. `rt.close()` at sign-out.
- **Handlers run on the main queue** (`callbackQueue` changes it), so they may update your views.
- **The connection keeps itself:** through a drop, from one realtime server to another without one, and back after the app was in the background, every room joined again with what it missed from its history.

## 5. Send

Your server sends to the room, and the app handler runs:

**Node**

```ts
await realtime.to( 'order:1042' ).emit( 'updated', { status: 'shipped' } );
```

**PHP**

```php
$realtime->to( 'order:1042' )->emit( 'updated', [ 'status' => 'shipped' ] );   // Laravel: broadcast( new OrderUpdated( $order ) )
```

**Python**

```python
realtime.to("order:1042").emit("updated", {"status": "shipped"})
```

## Next

- [Rooms](rooms.md), [presence and online status](presence.md), [sending from your server](sending.md) and [events from the app](events.md)
- [Calls](calls.md), with the Better Messages call screen
- [Encryption and your users](encryption.md)
- [Customizing the screens](customizing.md): the call screen look, a piece of your own, or its whole code
- [Shipping](shipping.md), and [the example app](example.md)
- The API reference: [WordPlusRealtime](https://docs.wordplus.cloud/reference/ios/wordplusrealtime/documentation/wordplusrealtime/), [WordPlusRealtimeCalls](https://docs.wordplus.cloud/reference/ios/wordplusrealtimecalls/documentation/wordplusrealtimecalls/) and [WordPlusRealtimeUI](https://docs.wordplus.cloud/reference/ios/wordplusrealtimeui/documentation/wordplusrealtimeui/)
- On your server side: [rooms in depth](https://docs.wordplus.cloud/apps/rooms/), [errors](https://docs.wordplus.cloud/apps/errors/) and [limits](https://docs.wordplus.cloud/apps/limits/)
