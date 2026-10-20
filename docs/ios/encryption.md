# Encryption and your users

What the app sends and gets through WordPlus Cloud is sealed on the way: the realtime servers carry it, keep the history of a room and count its members without being able to read or change any of it. You write no encryption code. Your server holds the keys and gives the app the ones its user may have. The SDK opens everything before your handler sees it ([encryption in depth](https://docs.wordplus.cloud/apps/encryption/)).

## What is sealed

| What | Sealed with | Who can open it |
|---|---|---|
| Events to a room, from your server, pages and apps, and its history | the room key | whoever the room rule lets in |
| The `info` of a presence member | the room key | the same |
| What your server sends a user | the key of the user | that user |
| Your users in the directory, and what the people in a call see of each other | the day key | everyone your app knows |
| The negotiation of a call, and the media of a group call | the keys of that call | the people in it |

The realtime servers see room names, event names, user ids, which key a value needs, and sealed values.

## How the app gets its keys

- **At sign-in,** in your server `config()`: the key of the user, the day keys and the user identity, which `RealtimeOptions(config:base:headers:)` takes.
- **With the token of a room,** that room key, when the app joins.
- **From your keys route** (`{endpoint}/keys`), any other key an event needs, asked for once and kept.

The keys are kept in memory only, in `rt.keyring`, never on disk: a new launch gets them from your server again. Sealing is XChaCha20-Poly1305, through the CryptoKit ChaCha20-Poly1305 with HChaCha20 in the SDK, checked against the same test vectors as every server package.

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
