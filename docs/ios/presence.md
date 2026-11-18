# Presence and online status

Two things, both live: who is in a room now (presence), and whether a user is online anywhere in your app (online status), whatever page or app they have open. What people build with them: [who is online and who is here](https://docs.wordplus.cloud/use-cases/online/).

## A presence room

Your server declares the room with `presence: true`, and its rule answers with what the others see of each member ([presence in depth](https://docs.wordplus.cloud/apps/presence/)). Here the room of everyone in the shop is named `shop`. The app asks your server to join it, and the rule decides:

1. Everyone in it is listed, and each one sees the others come and go (`presence`).
2. Only signed-in people join: a visitor who is not signed in has no user.
3. The others see the role of each member, such as `support` or `customer`.

**Node**

```ts
realtime.room( 'shop', { presence: true }, async ( user ) => {   // 1. Everyone in it is listed.
    // 2. Signed-in people only.
    if ( user === null ) return false;

    // 3. What the others see of them: their role.
    return { info: { role: await roleOf( user ) } };
} );
```

**PHP**

```php
$realtime->room( 'shop', function ( $user ) {
    // 2. Signed-in people only.
    if ( null === $user ) {
        return false;
    }

    // 3. What the others see of them: their role.
    return [ 'info' => [ 'role' => role_of( $user ) ] ];
}, [ 'presence' => true ] ); // 1. Everyone in it is listed.
```

**Python**

```python
def shop_member(user):
    # 2. Signed-in people only.
    if user is None:
        return False

    # 3. What the others see of them: their role.
    return {"info": {"role": role_of(user)}}


realtime.room("shop", shop_member, presence=True)   # 1. Everyone in it is listed.
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

- **Up to 1,000 users** watched a connection. `unwatch` stops. A watch refused or not answered is `on("error")`, with its `code`: `no_identity` for a user your server has not vouched for, `timeout` off line.
- **Your server** decides who is never shown online (`hidden`, for a "Hide my status" setting), and asks itself with `realtime.online.has( id )` ([who is online](https://docs.wordplus.cloud/apps/presence/#who-is-online-across-your-app)).

## Names and pictures

The app directory holds every signed-in user profile, from your server, sealed:

```swift
let people = try await rt.users(["34", "43"])   // ["34": { user_id, name, avatar … }]
title = people["34"]?["name"]?.string ?? ""
```

A user is in it once they connect, for a day after they last did. Ask again when someone comes online. Up to 100 a request.

## The views

`WordPlusRealtimeUI` has the web's presence parts, under their names, in UIKit: `OnlineList`, `PersonRow`, `RowAction`, `OnlineCount`, `Avatar`, `PresenceDot`, `TypingDots` and `ActivityIndicator`. They draw what you give them, and none of them reads a room or a connection, so you feed them from a room, from your own list, or from anything else:

```swift
import WordPlusRealtimeUI

let shop = rt.join("shop")
let list = OnlineList(title: "In the shop")           // the title and count, a row each, the line for nobody

func drawPeople() {
    let rows: [UIView] = shop.members.map { id, info in
        let name = info["name"]?.string ?? ""
        return PersonRow(
            avatar: Avatar(name: name, picture: info["avatar"]?.string, size: 32, presence: .online, decorative: true),
            name: name,
            sub: id == rt.user ? "You" : info["role"]?.string,
            actions: id == rt.user ? [] : [ RowAction(icon: RowAction.icons["phone"]!, label: "Call \(name)") { call(id) } ]
        )
    }
    list.count = rows.count
    list.rows = rows
}
for event in ["joined", "join", "leave"] { shop.on(event) { _, _ in drawPeople() } }

let watching = OnlineCount()                          // nothing at 0, 99+ past 99
shop.on("count") { data, _ in watching.count = data["n"]?.number.map(Int.init) ?? 0 }

let chat = rt.join("chat:34:42")
let typing = ActivityIndicator()                      // Anna typing, Anna, Bob typing, 3 typing
var writers: [String: String] = [:]
chat.on("typing") { data, meta in
    guard let id = meta.from else { return }
    writers[id] = data["on"]?.bool == true ? nameOf(id) : nil
    typing.names = Array(writers.values)
    typing.isHidden = writers.isEmpty                 // with nobody given it says "typing" alone, so hide it
}
```

- **`OnlineList(count:rows:title:empty:onClose:)`:** a close button only with `onClose`. `count` says how many are listed, and the rows do not set it, as a room may count more than it lists. It takes the size you give it, and its rows scroll.
- **`PersonRow(avatar:name:sub:actions:)`:** `avatar` an `Avatar` or a view of yours, `actions` a `RowAction` each or views of yours.
- **`RowAction(icon:label:action:)`:** `icon` a path in a 24-point grid, as the Lucide icons are (`RowAction.icons` has ours by name), and `label` what VoiceOver says.
- **`Avatar(name:picture:size:shape:presence:showOffline:dotSize:presenceColor:presenceRing:letters:decorative:)`:** the picture, or the first letters of the name with none and where it does not load. The dot shows while the person is not offline, and for offline too with `showOffline`. `decorative` where the name is beside it, so VoiceOver does not read it twice.
- **`ActivityIndicator(entries:activity:names:compact:)`:** `names` all doing `activity`, or `entries` for each their own, `.typing`, `.recording` or `.uploading`. A person typing stops being said when they send `{ "on": false }`, and it is yours to drop someone who went quiet: the web drops them after 4 seconds.
- **Their words and colours** are those of the call screen, `CallScreen.shared.configure`: `online`, `online_empty`, `close`, `presence_online`, `presence_busy`, `presence_away`, `presence_offline`, and `typing`, `typing_named`, `recording`, `recording_named`, `uploading`, `uploading_named`, where `%s` is who. The tokens are the names of the web, `--wplus-color-online`, `--wplus-color-busy`, `--wplus-color-away`, `--wplus-color-offline`, `--wplus-color-text-primary`, `--wplus-color-text-tertiary`, `--wplus-color-border`, `--wplus-color-bg-hover`, `--wplus-color-surface`, `--wplus-color-accent` and `--wplus-color-accent-hover`. With none given they follow the light or dark of the phone.
- **Not here:** the web's `overlay` on `OnlineList`, which docks it beside a chat, as a view here goes where you put it, and `AvatarStack`, `GroupAvatar`, `PresenceLabel` and `ReadBy`, which a chat draws.
