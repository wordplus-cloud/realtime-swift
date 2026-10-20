# Sending from your server

Your server sends to rooms and to users with its secret, the same way whether a browser or an app gets it ([sending in depth](https://docs.wordplus.cloud/apps/sending/)).

## To a room

**Node**

```ts
await realtime.to( 'order:1042' ).emit( 'updated', { status: 'shipped' } );
```

**PHP**

```php
$realtime->to( 'order:1042' )->emit( 'updated', [ 'status' => 'shipped' ] );
```

**Python**

```python
realtime.to("order:1042").emit("updated", {"status": "shipped"})
```

```swift
rt.join("order:1042").on("updated") { data, _ in status = data["status"]?.string ?? status }
```

## Not back to the app that caused it

When the app asks your server to change something, it sends its own name on the connection, `rt.tab`, and your server leaves it out of the emit: the app has already shown the change.

```swift
var request = URLRequest(url: server.appendingPathComponent("orders/1042/status"))
request.httpMethod = "POST"
request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
request.setValue(rt.tab, forHTTPHeaderField: "X-Realtime-Tab")
```

**Node**

```ts
await realtime.to( 'order:1042' ).except( req.get( 'x-realtime-tab' ) ).emit( 'updated', { status } );
```

**PHP**

```php
$realtime->to( 'order:1042' )->except( $_SERVER['HTTP_X_REALTIME_TAB'] ?? null )->emit( 'updated', [ 'status' => $status ] );
// Laravel: broadcast( new OrderUpdated( $order ) )->toOthers();
```

**Python**

```python
realtime.to("order:1042").except_tab(request.headers.get("X-Realtime-Tab")).emit("updated", {"status": status})
```

## To a user

What only one user should get, on every page and app they have open, without a room of yours:

**Node**

```ts
await realtime.toUser( 42 ).emit( 'notice', { text: 'Your order shipped' } );
```

**PHP**

```php
$realtime->toUser( 42 )->emit( 'notice', [ 'text' => 'Your order shipped' ] );
```

**Python**

```python
realtime.to_user(42).emit("notice", {"text": "Your order shipped"})
```

```swift
rt.on("notice") { data, _ in toast(data["text"]?.string ?? "") }
for await (notice, _) in rt.events("notice") { toast(notice["text"]?.string ?? "") }   // or as a sequence
```

It reaches the app while it is connected. This SDK has no push yet: an app that is closed, or long in the background, hears it next time it opens only if it was also kept in the history of a room.

## Asking the app

Your server asks the open pages and apps of a user, and waits for their replies ([a user](https://docs.wordplus.cloud/apps/sending/#a-user)):

**Node**

```ts
const replies = await realtime.user( 42 ).ask( 'cart', { why: 'checkout' } );   // [ { data, at } ]
```

The app answers the events it chooses. The question and the reply are sealed with the key of the user:

```swift
rt.answer("cart") { data, _ in ["items": .number(Double(cart.count))] }
```

## Signed out by your server

`realtime.user( 42 ).disconnect()` on your server takes the user out of everything at once. The app hears `signed_out`, then a second later asks your routes for new tokens and a new identity, so your rules decide whether the user comes back:

```swift
rt.on("signed_out") { _, _ in showSignIn() }
```

## Webhooks

What apps and pages send to rooms, and who comes online, reaches your server by webhook, as for your web pages ([webhooks](https://docs.wordplus.cloud/apps/sending/#webhooks)).
