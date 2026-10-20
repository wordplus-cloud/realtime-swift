# ``WordPlusRealtime``

Rooms, events with acks, presence, counts, history, who is online and what your server sends the user, through WordPlus Cloud, sealed end to end.

## Overview

The app joins rooms your server declares, with your server's routes and the token it signed in with: the same rooms as your web pages, so the app and a browser see each other. The [iOS guide](https://docs.wordplus.cloud/ios/getting-started/) walks through it.

```swift
let rt = Realtime(RealtimeOptions(config: config, base: server, headers: { ["Authorization": "Bearer \(token)"] }))
rt.connect()

let chat = rt.join("chat:34:42")
chat.on("message") { data, meta in show(data["text"]?.string, from: meta.from) }
let ack = try await chat.emitWithAck("message", ["text": "Hi"])
chat.volatile.emit("typing", ["on": true])
```

## Topics

### Connecting

- ``Realtime``
- ``RealtimeOptions``
- ``ConnectionState``
- ``Identity``
- ``PublicGrant``

### Rooms

- ``Room``
- ``RoomState``
- ``EventMeta``
- ``Ack``
- ``VolatileEmitter``
- ``HistoryPage``
- ``HistoryEvent``

### Who is online

- ``Online``

### Data, keys and errors

- ``JSONValue``
- ``Keyring``
- ``RealtimeError``
- ``Listener``
