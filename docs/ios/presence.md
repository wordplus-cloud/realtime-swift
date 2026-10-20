# Presence and online status

Two things, both live: who is in a room now (presence), and whether a user is online anywhere in your app (online status), whatever page or app they have open.

## A presence room

Your server declares the room with `presence: true`, and its rule answers with what the others see of each member ([presence in depth](https://docs.wordplus.cloud/apps/presence/)):

**Node**

```ts
realtime.room( 'shop', { presence: true }, async ( user ) => user !== null && { info: { role: await roleOf( user ) } } );
```

**PHP**

```php
$realtime->room( 'shop', fn ( $user ) => null !== $user ? [ 'info' => [ 'role' => role_of( $user ) ] ] : false, [ 'presence' => true ] );
```

**Python**

```python
realtime.room("shop", lambda user: user is not None and {"info": {"role": role_of(user)}}, presence=True)
```

Without `info`, the info of a member is their profile from your server `profile`: their name and avatar.

```swift
let shop = rt.join("shop")
for event in ["joined", "join", "leave"] {
    shop.on(event) { _, _ in
        members = shop.members.map { id, info in Member(id: id, name: info["name"]?.string ?? "", role: info["role"]?.string ?? "") }
    }
}
```

- **`members`** is `[id: info]`: everyone listed when the app joined, kept up to date by `join` and `leave`. A user with the app open twice is one member.
- **Leaving** (`rt.leave("shop")`) takes the app out. The user leaves the list when their last page or app does. Joining again puts them back.
- **A large room** lists its first 1,000 members. `membersPage(cursor:limit:)` pages through the rest.

## Counting

A room with `count: true` on your server, or any presence room, keeps `room.count` and sends `count` (`{ n }`) when it changes, at most once a second:

```swift
let product = rt.join("product:7")
product.on("count") { data, _ in watching = data["n"]?.number.map(Int.init) ?? 0 }
```

## Who is online, across your app

A user is online while any page or app of theirs is connected with the identity your server gave it, and offline 10 seconds after the last one closes. An app sees online status only for a signed-in user.

```swift
let everyone = ["34", "42", "43"]
rt.online.watch(everyone).on("change") { change in          // { id, online, at? }: now, then every change
    online = Set(everyone.filter { rt.online.has($0) })
}
rt.online.lastSeen("43")                                      // when, in ms since 1970, for one offline
rt.online.on("count") { data in showOnline(data["n"]?.number ?? 0) }   // how many are online, live
let (ids, next) = try await rt.online.list()                  // a page of who is online
```

- **Up to 1,000 users** watched a connection. `unwatch` stops.
- **Your server** decides who is never shown online (`hidden`, for a "Hide my status" setting), and asks itself with `realtime.online.has( id )` ([who is online](https://docs.wordplus.cloud/apps/presence/#who-is-online-across-your-app)).

## Names and pictures

The app directory holds every signed-in user profile, from your server, sealed:

```swift
let people = try await rt.users(["34", "43"])   // ["34": { user_id, name, avatar … }]
title = people["34"]?["name"]?.string ?? ""
```

A user is in it once they connect, for a day after they last did. Ask again when someone comes online. Up to 100 a request.
