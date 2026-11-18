# Live streams

One person presents live to everyone watching: the picture, a chat beside it, reactions, and the count of who watches. In `WordPlusRealtimeCalls`, on the same media servers as the browser: an app watches a stream a browser presents, and goes live itself.

How a stream starts, who is who, how your server runs it and how it ends: [how live streams work](https://docs.wordplus.cloud/use-cases/how-it-works/#live-streams). What people build with them: [live streaming](https://docs.wordplus.cloud/use-cases/live-streaming/), [interviews and questions on stage](https://docs.wordplus.cloud/use-cases/interviews/) and [members-only streams](https://docs.wordplus.cloud/use-cases/members-only/).

## Who is who

Your server declares streams by pattern, as it declares rooms and calls ([live streams in depth](https://docs.wordplus.cloud/apps/streams/#who-is-who)). Here the show of a shop is named `show:` and the show: `show:mugs`. The app asks the calls route of your server when it opens a stream, as for calls, and your rule answers with the place of the user in it. This rule decides:

1. A show that does not exist opens for nobody.
2. Its presenter is its host: goes live, brings guests on stage, keeps the chat and ends it.
3. Everyone else watches, signed in or not. A visitor who is not signed in comes with no user, reads the chat and signs in to write.
4. Viewers send reactions.
5. Links in the chat come only from the host and those who keep the chat.

**Node**

```ts
realtime.streams( 'show:{id}', async ( user, { id } ) => {
    // 1. A show that does not exist opens for nobody.
    const show = await findShow( id );
    if ( ! show ) return false;

    // 2. Its presenter is its host.
    if ( user === show.hostId ) return 'host';

    // 3. Everyone else watches, signed in or not.
    return 'viewer';
}, {
    reactions: true,              // 4. Viewers send reactions.
    chat: { links: false },       // 5. Links only from those who keep the chat.
} );
```

**PHP**

```php
$realtime->streams( 'show:{id}', function ( $user, array $p ) {
    // 1. A show that does not exist opens for nobody.
    $show = find_show( $p['id'] );
    if ( null === $show ) {
        return false;
    }

    // 2. Its presenter is its host.
    if ( $user === $show->host_id ) {
        return 'host';
    }

    // 3. Everyone else watches, signed in or not.
    return 'viewer';
}, [
    'reactions' => true,                // 4. Viewers send reactions.
    'chat'      => [ 'links' => false ], // 5. Links only from those who keep the chat.
] );
```

**Python**

```python
def show_role(user, p):
    # 1. A show that does not exist opens for nobody.
    show = find_show(p["id"])
    if show is None:
        return False

    # 2. Its presenter is its host.
    if user == show.host_id:
        return "host"

    # 3. Everyone else watches, signed in or not.
    return "viewer"


realtime.streams("show:{id}", show_role,
                 reactions=True,           # 4. Viewers send reactions.
                 chat={"links": False})    # 5. Links only from those who keep the chat.
```

- **The answer:** `false`, a role (`host` or `viewer`), or the role with more: `info` (the name and https picture everyone sees, your `profile` by default), `chat` (`write` or `read`), `mod` (`true` for someone who keeps the chat without hosting), `src` (what the host may send: `camera`, `microphone`, `screen`) and `quality` (the best picture the host sends, `720p` or `1080p`).
- **A visitor who is not signed in** may only be a viewer. A rule that gives them more is refused with `no_user`.
- **The settings of the stream**, the third argument, are each a value or a function of the parts of its name: `stage` (guests on stage, on unless `false`), `reactions`, `people` (who sees who is watching, `mods` or `all`), and `chat`: `offline` (`open` or `closed` while it is not live), `links` and `fresh` (the chat emptied each time it goes live) ([permissions](https://docs.wordplus.cloud/apps/permissions/#live-streams)).

## Drawn ready

`LiveStreamScreen` of `WordPlusRealtimeUI` is the stream as the web player draws it, full screen: the picture, Live and how many watch over it, its title, the chat with a field to write in, and a heart for reactions, which float up the picture as everyone sends them.

```swift
import WordPlusRealtimeUI

let show = try await rt.calls.stream("show:mugs")
present(LiveStreamScreen(stream: show, title: "The new mugs"), animated: true)
```

- **Closing it** leaves the stream and dismisses the screen. `leavesOnClose = false` keeps the stream for the app, and `onClose` does what the app wants in place of dismissing.
- **Its words** are English by default, and yours by key in the language of the user: `LiveStreamScreen(stream:title:appearance: .init(strings: ["live": "Live", "watching": "%d schauen zu"]))`. The keys are `live`, `watching`, `starts_soon`, `ended`, `say_something`, `send`, `read_only`, `pinned`, `react`, `close`, `not_sent`, and for the stage `ask_stage`, `lower_hand`, `invited_title`, `invited_text`, `not_now`, `join_stage`, `leave_stage`, `camera`, `microphone` and `stage_failed`.
- **For viewers:** the host goes live from the studio on the web, or with the calls of the stream below.
- **In SwiftUI**, wrap it in a `UIViewControllerRepresentable` and show it with `fullScreenCover`, as the API demo does.

## Watching

A screen of your own, on the stream itself:

```swift
import WordPlusRealtimeCalls

let show = try await rt.calls.stream("show:mugs")

let player = LiveStreamVideoView()
player.show(show)                       // the main picture of the stream as it changes, its sound plays by itself

show.onChange {                         // the state, the count, the chat, the pictures
    stateLabel.text = show.state == .live ? "Live now" : "Not live"
    countLabel.text = "\(show.viewers) watching"
}
show.onMessage { message in add(message.name, message.text) }
try await show.send("Hello!")
show.react("❤️")
show.leave()
```

- **Reactions** are any one emoji: `show.react("🔥")`, or `.heart`, `.clap`, `.laugh`, `.wow` and `.fire` for the five the players offer. `show.onReactions` hears the ones sent since the last, by emoji, about every half second, and `LiveStreamScreen` floats each up the picture.
- **`rt.calls.stream(name, video: false)`** joins without the picture, for a screen that shows the chat or the count. `show.watch()` fetches it later, as a `LiveStreamVideoView` does by itself.
- **`rt.joinStream(getToken:)`** joins with a token from your own route, `realtime.streamToken( user, name, { role } )`, in place of a rule. It asks your route again as each token runs out, and your route may then say no. `rt.joinStream(token)` takes one token, and throws `expired` when it would need another. Both take `video: false`.
- **`state`** is `idle`, `live` or `ended`. `media` is where the app is in the room of the stream: `off`, `connecting`, `live`, `reconnecting`. While a join waits for a place on the mesh, `waiting` is a `CallWait`, `until` when and `reason` why, and `onWaiting` hears it. `media` stays as it was, and the join goes on by itself. With as many watching as the stream takes (`audience`), a viewer waits the same way, with the `reason` `full` and `until` its next try.
- **`role`** is the place your rule gave this user: `host`, `guest` or `viewer`. `viewers` and `peak` count those watching, `startedAt` is when it went live.
- **The quality of the picture:** it comes at the size of its view unless a viewer chooses. `show.qualities()` gives the layers they may choose, the best first, each `high`, `medium` or `low` with its size, and `show.setQuality(.low)` holds to one, `.auto` going back. None above 720p may be chosen, and none shows before the picture arrives. The sizes are worked out from the size of the picture, so a sender with other layers may differ from them a little.
- **`show.stats()`** says how the stream plays here, to debug it: the picture and the sound that arrive, the media server and the way they come, and the session so far (how long the picture took to start, stalls, reconnects), with the last things that happened. It is measured on the device once a second and sent nowhere.
- **The main picture** is the one the host chose: a shared screen, the picture from OBS, else the camera of the host. `show.tiles` has each picture, and `player.show(show, tile: identity)` draws one of them.
- **The chat:** `messages` (the history, oldest first), `pinned`, `canWrite`, `slow`. Each message has the app user id of who wrote it, nil for a visitor.
- **`onEnded`** says why the app is out of the stream: `left`, `banned`, `kicked`, or the code of what it could not go on with.

## Going live

The app of the host shows its camera, then goes live:

```swift
try await show.preview()                // the camera and microphone, in the same LiveStreamVideoView
try await show.setCamera(false)         // or setMicrophone(_:)
try await show.goLive()
try await show.end()
```

- **The camera and microphone** need `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` in `Info.plist`, as for calls.
- **`goLive()`** with nothing on turns the camera and microphone on first. A host may take an ended stream live again.
- **What a role may not do** throws its code: `not_host`, `read_only`, `slow`, `timeout`.
- **From OBS:** `let (url, key) = try await show.ingest()`. `ingest(renew: true)` makes a new key and cuts off the old one. The picture from the encoder takes the place of the camera.
- **The app sends** its camera, its microphone, and its screen where the app was built for it. `await show.setScreenShare( true )` asks as for a [call](calls.md#sharing-the-screen), and `show.sharingScreen` says it is shared, for a host or a guest on stage. `LiveStreamScreen` has no button for it: this is for a screen of your own. Choosing which picture the stream shows is done from the studio on the web.

## Guests on stage

A viewer raises a hand, the host invites them, and they come on stage beside the host with their camera and microphone, for everyone watching, on the web too. `LiveStreamScreen` draws what a viewer does: a signed-in viewer asks with **Ask to join on stage**, answers the invitation in a card under the title, and once on stage has their camera, their microphone, **Leave stage**, and their own camera in a corner of the picture. It asks for nothing a stream would refuse: `show.canAskStage` says whether this user may ask now. What the host does, seeing the hands and inviting, is in the studio on the web or a screen of your own. In a screen of your own:

```swift
// The app of a viewer:
try await show.hand(true)                       // show.hand(false) takes it down
show.onChange {
    handButton.isHidden = !show.canAskStage     // signed in, not the host, live, and it takes guests
    joinButton.isHidden = !show.invited         // the host asks them on
    stageBadge.isHidden = !show.onStage
}
try await show.joinStage()                      // on stage, the camera and microphone live, or show.declineStage()
show.leaveStage()                               // the cloud takes them off, and they watch again

// The app of the host:
show.onChange { drawHands(show.hands) }         // [LiveStreamHand]: user, name, at, the oldest first
try await show.invite(show.hands[0].user!)      // or anyone watching, by their user id
try await show.unstage("34")                    // off stage, back to watching
try await show.layout(.speaker)                 // .grid, .speaker, or .spotlight with a user
```

A guest sends the camera and microphone, the picture up to 720p. A visitor who is not signed in does not come on stage (`anonymous`), a stream whose settings say `stage: false` takes no hands (`no_stage`), and `joinStage()` with no invitation is `not_invited`.

## Keeping the chat

The host, and anyone the rule made `mod`: `deleteMessage(id)`, `pin(id)`, `unpin()`, `timeout(user, seconds:)` (from a minute to a day, they go on watching), `setSlow(seconds)`, `clearChat()`, `remove(user)` (out now, they may come back, and `kick(user)` is the same) and `ban(user)`. `isModerator` says whether this user keeps the chat.

A message the chat does not take throws its code: `read_only`, `slow`, `timeout`, `too_long`, `links`, `not_live`.

The show card of the API demo opens the screen drawn ready on the show of Ann: [the example app](example.md).

## From your server

Your server runs a stream as its host does, with no app open: it lists the streams live now, reads one and who watches it, writes in its chat as the shop, times out, kicks or bans someone, turns reactions off, and ends the stream. Each change reaches the app at once: a message in `onMessage`, someone put out in their `onEnded` (`kicked`, `banned`), the end in `state`.

**Node**

```ts
await realtime.listStreams();                    // [ { name, started_at, viewers } ], those live now
const show = realtime.stream( 'show:mugs' );
await show.say( 'Free shipping until midnight', { name: 'Mug Shop' } );
await show.timeout( 77, 600 );                   // no writing for 10 minutes
await show.ban( 88 );
await show.end();
```

**PHP**

```php
$realtime->listStreams();
$show = $realtime->stream( 'show:mugs' );
$show->say( 'Free shipping until midnight', 'Mug Shop' );
$show->timeout( 77, 600 );
$show->ban( 88 );
$show->end();
```

**Python**

```python
realtime.list_streams()
show = realtime.stream("show:mugs")
show.say("Free shipping until midnight", "Mug Shop")
show.timeout(77, 600)
show.ban(88)
show.end()
```

Everything your server can do with a stream, in each language: [live streams from your server](https://docs.wordplus.cloud/apps/streams/#from-your-server), and the guide of your stack ([Next.js](https://docs.wordplus.cloud/nextjs/streams/), [Express](https://docs.wordplus.cloud/express/streams/), [Laravel](https://docs.wordplus.cloud/laravel/streams/), [PHP](https://docs.wordplus.cloud/php/streams/), [Django](https://docs.wordplus.cloud/django/streams/), [FastAPI](https://docs.wordplus.cloud/fastapi/streams/), [Flask](https://docs.wordplus.cloud/flask/streams/)).

## Webhooks

Your server hears a stream go live and end, and each signed-in person who watched it, by [webhook](https://docs.wordplus.cloud/apps/sending/#webhooks):

| Event | |
|---|---|
| `stream.live`, `stream.ended` | `{ id, at, stream, started_at, ended_at }`: the stream went live, or ended, the times in milliseconds |
| `stream.joined`, `stream.left` | `{ id, at, stream, user, role, watch, joined_at }`, and on leaving `left_at` and `seconds`: a signed-in person watching or on it while it was live. Visitors are not told |

These handlers do three things:

1. As the show goes live, its followers hear of it.
2. As it ends, your server keeps how long it ran.
3. As someone stops watching, your server adds the seconds they watched while it was live.

**Node**

```ts
// 1. Live: tell its followers.
realtime.on( 'stream.live', ( { stream } ) => notifyFollowers( stream ) );
// 2. Ended: keep how long it ran.
realtime.on( 'stream.ended', ( { stream, started_at, ended_at } ) => saveShowLength( stream, started_at, ended_at ) );
// 3. Someone stopped watching: the seconds they watched.
realtime.on( 'stream.left', ( { stream, user, seconds } ) => addWatchTime( stream, user, seconds ) );
```

**PHP**

```php
// 1. Live: tell its followers.
$realtime->on( 'stream.live', fn ( array $e ) => notify_followers( $e['stream'] ) );
// 2. Ended: keep how long it ran.
$realtime->on( 'stream.ended', fn ( array $e ) => save_show_length( $e['stream'], $e['started_at'], $e['ended_at'] ) );
// 3. Someone stopped watching: the seconds they watched.
$realtime->on( 'stream.left', fn ( array $e ) => add_watch_time( $e['stream'], $e['user'], $e['seconds'] ) );
```

**Python**

```python
# 1. Live: tell its followers.
realtime.on("stream.live", lambda e: notify_followers(e["stream"]))
# 2. Ended: keep how long it ran.
realtime.on("stream.ended", lambda e: save_show_length(e["stream"], e["started_at"], e["ended_at"]))
# 3. Someone stopped watching: the seconds they watched.
realtime.on("stream.left", lambda e: add_watch_time(e["stream"], e["user"], e["seconds"]))
```

## What WordPlus Cloud sees

A live stream is not encrypted end to end. Its picture and chat are for everyone watching, so they are encrypted on the way, and the media servers of WordPlus Cloud see them, as a stream needs ([encryption](encryption.md#calls-and-live-streams)).

## Refusals

`rt.calls.stream(_:)` and the actions of the host throw a `CallError` with its code:

| Code | |
|---|---|
| `forbidden` | your rule said no, or no pattern matches the name |
| `no_user` | your rule gave a visitor who is not signed in more than the place of a viewer |
| `not_included` | the plan of your app does not include live streams |
| `banned` | this user is banned from the stream |
| `no_hours` | the account has used its credits this month, what it may borrow included: new viewers above the plan come in once credits are bought |
| `not_host` | an action of the host from someone who is not the host |
| `publish_failed` | the camera or microphone could not be sent into the stream |
