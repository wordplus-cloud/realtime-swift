# Events from the app

The app sends events to the rooms it is in, straight through WordPlus Cloud, with no request to your server: chat messages, typing, read ticks, reactions. A room rule says which events may be sent to it ([events in depth](https://docs.wordplus.cloud/apps/events/)), and what people build with them is in [chat](https://docs.wordplus.cloud/use-cases/chat/).

Here the chat of two people is named `chat:` and their two ids, smaller first: `chat:34:42`. The app asks your server to join it, and the rule decides:

1. Only the two people in the name join their chat.
2. They may send `message`, `typing`, `reaction` and `read` to it, and nothing else (`emit`).
3. Each `message` and `reaction` reaches your server by webhook, for your server to keep (`webhook`).
4. The room keeps its last 50 events (`history`), for an app that comes back after a drop.

**Node**

```ts
realtime.room( 'chat:{a}:{b}', {
    emit: [ 'message', 'typing', 'reaction', 'read' ],   // 2. What the two may send.
    webhook: [ 'message', 'reaction' ],                   // 3. What reaches your server.
    history: 50,                                          // 4. The last 50 events kept.
}, ( user, { a, b } ) => {
    // 1. The two people in the name, as text: user 34 is "34" there.
    const pair = [ a, b ];
    return pair.includes( String( user ) );
} );
```

**PHP**

```php
$realtime->room( 'chat:{a}:{b}', function ( $user, array $p ) {
    // 1. The two people in the name, as text: user 34 is "34" there.
    $pair = [ $p['a'], $p['b'] ];
    return in_array( (string) $user, $pair, true );
}, [
    'emit'    => [ 'message', 'typing', 'reaction', 'read' ], // 2. What the two may send.
    'webhook' => [ 'message', 'reaction' ],                   // 3. What reaches your server.
    'history' => 50,                                          // 4. The last 50 events kept.
] );
```

**Python**

```python
def in_chat(user, p):
    # 1. The two people in the name, as text: user 34 is "34" there.
    pair = [p["a"], p["b"]]
    return str(user) in pair


realtime.room("chat:{a}:{b}", in_chat,
              emit=["message", "typing", "reaction", "read"],   # 2. What the two may send.
              webhook=["message", "reaction"],                  # 3. What reaches your server.
              history=50)                                       # 4. The last 50 events kept.
```

## Sending

```swift
let chat = rt.join("chat:34:42")

chat.emit("message", ["text": "Hi"])                                  // sent, nothing waited for
let ack = try await chat.emitWithAck("message", ["text": "Hi"])       // WordPlus Cloud took it: ack.id, ack.at
chat.volatile.emit("typing", ["on": true])                            // dropped rather than queued while off line, never kept
try await chat.emitWithAck("message", ["text": "Hi"], timeout: 5)     // an ack waited for 5 seconds at most

struct Message: Codable { let text: String }
try await chat.emitWithAck("message", Message(text: "Hi"))            // any Encodable
```

- **Everyone in the room** gets it, the other pages and devices of the sender too. This app does not.
- **`emitWithAck`** returns once WordPlus Cloud has checked the event, kept it (when the room keeps history) and sent it on, with the kept event `id` and time. It throws a `RealtimeError` with its `code`: `not_allowed` (the rule does not list it), `forbidden` (not in the room), `rate_limited`, `too_large`, `bad_event`, `timeout`, or `offline` while the connection is down.
- **Before the room is joined,** an emit waits for it, except a `volatile.emit`, which is dropped.
- **`volatile.emitWithAck`** waits for the room, then for WordPlus Cloud to take the event and send it on. It is never kept, so `ack.id` is empty.
- **`meta.from`** on the other side is this app user, as your server vouched for them: an app cannot send as someone else.
- **Binary:** `JSONValue.binary(Data)` anywhere in the data, sealed as binary.
- **Limits:** 1 MB an event (kept in history up to 64 KB), 50 a second a connection, in bursts of up to 100.

## Hearing them

```swift
chat.on("message") { data, meta in add(from: meta.from ?? "", text: data["text"]?.string ?? "", id: meta.id) }
chat.on("typing") { data, _ in typing = data["on"]?.bool == true }
```

A message the app sent with `emitWithAck` does not come back to it: add it from the ack, with `ack.id`, so it is not shown twice when your server page or the room history has it too.

## Keeping the conversation

The conversation is for your app to keep, on your server, as Better Messages keeps its own in the WordPress database. A room keeps its events for 5 minutes, for apps that reconnect. Your server gets the events the rule names in `webhook` and saves them by `event_id`, the id the app saw as `meta.id`, and a route of yours gives them back a page at a time, with the user token ([keeping the conversation](https://docs.wordplus.cloud/apps/events/#keeping-the-conversation)):

```swift
// What was said before: the conversation your server keeps, then what the room has that it may not have yet.
chat.on("joined") { _, _ in
    Task { @MainActor in
        var request = URLRequest(url: server.appendingPathComponent("chat/34/42/messages"))   // ?before=<id> for the page before
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        for m in JSONValue.parse(String(decoding: data, as: UTF8.self))?["messages"]?.array ?? [] {   // { messages: [ { id, from, text, at, reactions } ], more }
            add(from: m["from"]?.id ?? "", text: m["text"]?.string ?? "", id: m["id"]?.string)
        }
        for e in try await chat.history(limit: 50).events where e.event == "message" {
            add(from: e.meta.from ?? "", text: e.data["text"]?.string ?? "", id: e.meta.id)
        }
    }
}
```

- **One id for each message,** whichever way it came, so `add` keeps the first.
- **The events do not go through your server** before they are sent on, so check there anything that matters.
- **A gap:** an app back after the 5 minutes a room keeps its events, or after more came than it keeps, gets what the room still had, then `error` on the room with `code` `gap`, still joined. Some events are lost to it, and your server page, loaded at every `joined` as above, brings them back.

## Talking with the web chat

The Better Messages chat on your web pages (`<chat-room>`) sends these events, so an app that sends the same reads with it, both ways:

| Event | Data | |
|---|---|---|
| `message` | `{ text }` | with an ack. Your server keeps it |
| `typing` | `{ on }` | volatile |
| `read` | `{ id }`, the newest message seen | volatile, for the sender ticks |
| `reaction` | `{ id, key }`, `key` empty to take it back | with an ack. Your server keeps it |
