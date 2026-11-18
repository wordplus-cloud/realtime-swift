# Encryption and your users

What the app sends and gets through WordPlus Cloud is sealed on the way: the realtime servers carry it, keep the history of a room and count its members without being able to read or change any of it. You write no encryption code. Your server holds the keys and gives the app the ones its user may have. The SDK opens everything before your handler sees it ([encryption in depth](https://docs.wordplus.cloud/apps/encryption/)).

## What is sealed

| What | Sealed with | Who can open it |
|---|---|---|
| Events to a room, from your server, pages and apps, and its history | the room key | whoever the room rule lets in |
| The `info` of a presence member | the room key | the same |
| What your server sends a user | the key of the user | that user |
| Your users in the directory, and what the people in a call see of each other | the day key | everyone your app knows |
| How the two sides of a call connect, and the media of an encrypted group call | the keys of that call | the people in it |

A room your server declares `public` is not sealed, unless it says `seal: true`: anyone with your app key may join it. The realtime servers see room names, event names, user ids, which key a value needs, and sealed values.

## Calls and live streams

| What | Encrypted end to end |
|---|---|
| A call between two people | yes, on every path: direct between the two, through our relays, or through our media servers |
| A group call that comes from a call, when someone is added | yes |
| A group call your server names (`groupCalls()`) | when its rule says `encrypt: true`. `group.encrypted` says so in the app |
| A live stream | no: its picture and its chat are for everyone watching, so they are encrypted on the way, and the media servers see them |

An encrypted call is encrypted on the phone, with a key your server makes from its local key and gives only to the people in the call: our relays and media servers carry what they cannot read ([calls](calls.md), [live streams](streams.md#what-wordplus-cloud-sees)).

## How the app gets its keys

- **At sign-in,** in your server `config()`: the key of the user, the day keys and the user identity, which `RealtimeOptions(config:base:headers:)` takes.
- **With the token of a room,** that room key, when the app joins.
- **From your keys route** (`{endpoint}/keys`), any other key an event needs, asked for once and kept.

Sealing is XChaCha20-Poly1305, through the CryptoKit ChaCha20-Poly1305 with HChaCha20 in the SDK, checked against the same test vectors as every server package.

## Where the keys are kept

- **In memory, for the connection:** the key of the user, the room keys and every key the app asked for are in `rt.keyring` while the app runs, never on disk. A new launch gets them from your server again.
- **The day keys, in the Keychain, for a closed app to ring:** a call that wakes a closed app or rings a locked phone shows the name of the caller before anything connects. Your server seals that name with the day key, so the phone needs the day key while nothing is connected. Once the app holds the line its calls ring on (`rt.calls`), the SDK keeps the three newest day keys in the Keychain, on this device only and readable after its first unlock, and adds each new one as the line is held again ([ringing a locked phone](calls.md#ringing-a-locked-phone)).
- **What a day key opens** is what everyone your app knows may read: the directory, and what the people in a call see of each other. Never the rooms, nor what your server sends one user.
- **No other key** is kept on the phone. `UserDefaults` keeps only the realtime servers the app reached, a codec a peer failed on, and the random id `SystemCalls` names this phone by ([privacy](shipping.md#privacy)).

## When someone loses access

Your server moves a room key on when it kicks someone out of the room, or when you rotate it ([when someone loses access](https://docs.wordplus.cloud/apps/encryption/#when-someone-loses-access)). The app asks for the new key by itself, with the next token of the room or the first event that needs it.

## Your users

A directory of your users on WordPlus Cloud, each profile sealed with the day key, shared by your pages and apps:

```swift
let people = try await rt.users(["34", "42"])   // ["34": { user_id: 34, name: "Ann", avatar: "…" }, …]
```

- **The app vouches for its user** when it connects, with the identity and profile your server signed (your `profile`). It may then read those of others.
- **A user is in it** once they connect, for a day after they last did.
- **Any user id** your app gives: numbers, and ids of text such as UUIDs or Auth0 ids.
