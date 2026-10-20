# Rooms

A room is a name the app joins to get its events: `order:1042`, `chat:34:42`, `shop`. Your server declares your rooms once, by pattern, with what each keeps and allows, and answers for each user who asks to join ([rooms in depth](https://docs.wordplus.cloud/apps/rooms/), with Node, PHP and Python side by side):

**Node**

```ts
realtime.room( 'order:{id}', { history: 20 }, async ( user, { id } ) => ( await findOrder( id ) )?.userId === user );
```

**PHP**

```php
$realtime->room( 'order:{id}', fn ( $user, array $p ) => find_order( $p['id'] )?->user_id === $user, [ 'history' => 20 ] );
```

**Python**

```python
realtime.room("order:{id}", lambda user, p: (order := find_order(p["id"])) is not None and order.user_id == user, history=20)
```

The app asks your auth route for every room it joins in the same moment in one request, with the headers your `RealtimeOptions` give, and keeps each token until 10 minutes before it expires.

## Joining

```swift
let order = rt.join("order:1042")

order.on("updated") { data, meta in
    status = data["status"]?.string ?? status   // meta: from, id, at, replayed
}
order.on("joined") { _, _ in live = true }
order.on("error") { error, _ in print(error["code"]?.string ?? "") }   // forbidden, no_rule, full, expired …

order.state            // .joining, .joined, .failed, .left
try await order.ready()   // waits until joined, throws its error
rt.leave("order:1042")    // or order.leave()
```

- **`join` gives the same room for the same name**, and `rt.room(name)` the one joined, or nil.
- **Events reach a handler opened:** you never handle sealed values. Data is a `JSONValue` (`data["status"]?.string`, `.number`, `.bool`, `.array`, `.object`, `.data` for binary).
- **`meta.from`** is the user who sent it from a page or an app, as your server vouched for them, or nil for your server. `meta.id` and `meta.at` are the kept event id and time.
- **The events of the room itself:** `joined`, `join` and `leave` (the members of a presence room), `count` (`{ n }`), `error` (`{ code }`) and `kicked`. Nobody can send them.
- **`onAny`** hears every event of the room, `(event, data, meta)`. `off(listener)` removes a handler.

## As async sequences, decoded

```swift
struct OrderUpdate: Decodable { let status: String }

for await (update, meta) in order.events("updated", as: OrderUpdate.self) {
    status = update.status
}
```

`events(_:)` gives the `JSONValue`s. `events(_:as:)` decodes each into your type, and skips one that does not decode. The sequence ends when its task is cancelled, and its handler with it.

## History, and nothing lost on a reconnect

A room keeps its events for 5 minutes at most, for recovery. Your app keeps its own records, such as the messages of a chat, from the [webhook](events.md#keeping-the-conversation).

- **A reconnect gets what it missed:** back within the history span, the app gets the events it missed first, in order, with `meta.replayed`, then the new ones. That holds after a drop, a move between servers, and the app coming back from the background.
- **Paging back,** oldest first, at most 100 a page:

```swift
let page = try await chat.history(limit: 50)                                   // the newest 50
let older = try await chat.history(before: page.events.first?.meta.id, limit: 50)
for event in page.events { show(event.event, event.data, event.meta) }        // page.more: there is older
```

`history` throws `no_history` for a room that keeps none.

## Rooms anyone may join

A room your server declares `public` may be joined signed in or not: `config()` gives the app its grants (`grants` in `RealtimeOptions`), so it joins with no request to your server.
