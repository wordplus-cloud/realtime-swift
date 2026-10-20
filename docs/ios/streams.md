# Live streams

One person presents live to everyone watching: the picture, a chat beside it, reactions, and the count of who watches. In `WordPlusRealtimeCalls`, on the same media servers as the browser: an app watches a stream a browser presents, and goes live itself.

## Who is who

Your server declares streams by pattern, as it declares rooms and calls ([live streams in depth](https://docs.wordplus.cloud/apps/streams/#who-is-who)):

**Node**

```ts
realtime.streams( 'show:{id}', ( user ) => ( user === ANN ? 'host' : 'viewer' ), { reactions: true } );
```

**PHP**

```php
$realtime->streams( 'show:{id}', fn ( $user ) => ANN === $user ? 'host' : 'viewer', [ 'reactions' => true ] );
```

**Python**

```python
realtime.streams("show:{id}", lambda user: "host" if user == ANN else "viewer", reactions=True)
```

The app asks the calls route of your server, as for calls: nothing more to add.

## Drawn ready

`LiveStreamScreen` of `WordPlusRealtimeUI` is the stream as the web player draws it, full screen: the picture, Live and how many watch over it, its title, the chat with a field to write in, and a heart for reactions, which float up the picture as everyone sends them.

```swift
import WordPlusRealtimeUI

let show = try await rt.calls.stream("show:mugs")
present(LiveStreamScreen(stream: show, title: "The new mugs"), animated: true)
```

- **Closing it** leaves the stream and dismisses the screen. `leavesOnClose = false` keeps the stream for the app, and `onClose` does what the app wants in place of dismissing.
- **Its words** are English by default, and yours by key in the language of the user: `LiveStreamScreen(stream:title:appearance: .init(strings: ["live": "Live", "watching": "%d schauen zu"]))`. The keys are `live`, `watching`, `starts_soon`, `ended`, `say_something`, `send`, `read_only`, `pinned`, `react`, `close` and `not_sent`.
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

- **`state`** is `idle`, `live` or `ended`. `media` is where the app is in the room of the stream: `off`, `connecting`, `live`, `reconnecting`.
- **The main picture** is the one the host chose: a shared screen, the picture from OBS, else the camera of the host. `show.tiles` has each picture, and `player.show(show, tile: identity)` draws one of them.
- **The chat:** `messages` (the history, oldest first), `pinned`, `canWrite`, `slow`. Each message has the app user id of who wrote it, nil for a visitor.
- **`onEnded`** says why the app is out of the stream: `left`, `banned`, `kicked`.

## Going live

The app of the host shows its camera, then goes live:

```swift
try await show.preview()                // the camera and microphone, in the same LiveStreamVideoView
try await show.setCamera(false)         // or setMicrophone(_:)
try await show.goLive()
try await show.end()
```

- **The camera and microphone** need `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` in `Info.plist`, as for calls.
- **`goLive()`** with nothing on turns the camera and microphone on first.
- **What a role may not do** throws its code: `not_host`, `read_only`, `slow`, `timeout`.
- **From OBS:** `let (url, key) = try await show.ingest()`. `ingest(renew: true)` makes a new key and cuts off the old one.

## Guests on stage

A viewer raises a hand, the host invites them, and they come on stage beside the host with their camera and microphone, for everyone watching, on the web too. The screen drawn ready shows all of it. In a screen of your own:

```swift
// The app of a viewer:
try await show.hand(true)                       // show.hand(false) takes it down
show.onChange {
    joinButton.isHidden = !show.invited         // the host asks them on
    stageBadge.isHidden = !show.onStage
}
try await show.joinStage()                      // on stage, the camera and microphone live
show.leaveStage()

// The app of the host:
show.onChange { drawHands(show.hands) }         // [LiveStreamHand]: user, name, at, the oldest first
try await show.invite(show.hands[0].user!)      // or anyone watching, by their user id
try await show.unstage("34")                    // off stage, back to watching
try await show.layout(.speaker)                 // .grid, .speaker, or .spotlight with a user
```

A guest sends the camera and microphone, the picture up to 720p. A visitor who is not signed in does not come on stage (`anonymous`), and a stream whose settings say `stage: false` takes no hands (`no_stage`).

## Keeping the chat

The host, and anyone the rule made `mod`: `deleteMessage(id)`, `pin(id)`, `unpin()`, `timeout(user, seconds:)` (from a minute to a day, they go on watching), `setSlow(seconds)`, `clearChat()`, `kick(user)` (out now, they may come back) and `ban(user)`.

The show card of the API demo opens the screen drawn ready on the show of Ann: [the example app](example.md).
