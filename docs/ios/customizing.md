# Customizing the screens on iOS

The call screen (`WordPlusRealtimeUI`) is the Better Messages native one. Your app can change it as far as it needs to, in three steps, each going further than the last, with your AI coding agent or by hand. Or draw a screen of its own on the calls alone.

## 1. The look

```swift
CallScreen.shared.configure( .init(
    strings: [ "end_call": "Hang up", "calling": "Ringing…" ],
    tokens: [ "--wplus-color-accent": "37, 99, 235" ],     // red, green, blue, or a hex value
    tokensDark: [ "--wplus-color-accent": "96, 165, 250" ]
) )
```

| Token | What it colours |
|---|---|
| `--wplus-color-accent`, `--wplus-color-text-on-accent` | a control that is on, and what is drawn on it |
| `--wplus-color-success`, `--wplus-color-recording`, `--wplus-color-warning`, `--wplus-color-online` | answering, hanging up and a microphone off, a warning, the online dot |
| `--wplus-call-canvas` | the stage, near-black unless you set it: a camera picture is seen against it |
| `--wplus-call-tile` | the tiles of a group call |
| `--wplus-call-btn` | each control in the dock |
| `--wplus-call-dock` | the glass behind the dock |

The same names as the web call screen, so one palette serves both. Their names before, `--bm-…`, still work.

## 2. A piece of your own

Replace one piece and keep the rest of the screen:

```swift
CallScreen.shared.pieces = .init(
    // The buttons of the dock: ours by id, in their order, and your own. Hanging up stays last.
    controls: { ours, state in
        ours.filter { $0.id != "pip" } + [
            .init( id: "order", label: "Show the order", icon: CallScreen.CallControl.icons[ "alert" ]! ) { showOrder() },
        ]
    },
    // The line under the name, nil keeps ours.
    status: { state in state.phase == "ringing_out" ? "Ringing Ann…" : nil },
    // Your own view while a call rings in, full screen: answer() shows the call on our screen.
    ringing: { ring in RingView( name: ring.name, answer: ring.answer, decline: ring.decline ) },
    // A view over the tile of each person in a group call, such as a badge: the same view again stays.
    tile: { person in person.isMe ? youBadge : nil },
    // A view over a call between two, under the dock.
    stage: { state in nil }
)
```

| Piece | What it is |
|---|---|
| `controls` | the dock buttons. Ours, by id, as the screen shows them: `answer` (a call ringing in), `flip` (while the camera is on), `camera`, `mute`, `speaker` (once the call is answered), `share` (once the call is up, where the app has the extension for [sharing the screen](calls.md#sharing-the-screen)), `add` (once the call is up, with `CallScreen.shared.addPerson` on, [Add Person](calls.md#on-the-call-screen)), `pip` (picture in picture: in a video call between two with a picture to show, in a group call by video, and in a group call by voice while someone else shares a screen), `host` (Host Controls, for a moderator in a group call) and `end`. The dock also shows `settings`, a gear, once the call is up, which opens Device Settings (the camera, the microphone and the speaker, with a test of each): `ours.filter { $0.id != "settings" }` takes it away. `CallControl( id:label:icon:latched:action: )` adds yours, drawn as ours are (`icon` a path in a 24-point grid, as the Lucide icons are) |
| `status` | the line under the name: `state.phase` is `ringing_out`, `ringing_in`, `connecting`, `in_progress` or `reconnecting`, `state.seconds` how long the call has been on |
| `ringing` | your own view for a call ringing in |
| `tile` | a view over the tile of someone in a group call. `person` has `identity`, `name`, `avatar`, `isMe`, `speaking` and `muted` |
| `stage` | a view over a call between two |

The dock has no raise hand button: a group call of the SDK has no way to send one, on the web either. A listener asks through a room of yours ([speakers and listeners](calls.md#speakers-and-listeners)), and a control of your own in `controls` can send it.

## 3. The code itself

Copy the screen into your app and change anything in it. Only the screen is copied: the calls under it stay in `WordPlusRealtimeCalls`, and keep getting their fixes.

```bash
swift package --allow-writing-to-package-directory wordplus-ui add --target Shop
```

From Xcode: right-click the project, choose **WordPlusUI** under the package plugins, and give it `add`.

**An Xcode project from a command line** (a script, or an AI agent): only Xcode runs the plugins of a project, so run the same commands from the checkout of the package:

```bash
xcodebuild -resolvePackageDependencies -project Shop.xcodeproj
PKG=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 4 -path '*SourcePackages/checkouts/*' -name 'realtime-swift' | head -1)
swift run --package-path "$PKG" wordplus-ui add --project . --target Shop
```

- **`--project`** is the folder holding the `.xcodeproj`, where `wordplus-ui.json` goes.
- **`--target`** is the app target, whose folder takes the screen.
- **The tests** go into `<target>Tests/WordPlusUITests/` when that folder is there. Otherwise give `--tests <folder>`.
- **`--module`** is the module the tests import, the name of the target by default.

`diff`, `update` and `accept` take the same flags.

- **Where it goes:** the target `WordPlusUI/` folder: `CallsScreen.swift` (the call), `CallsGrid.swift` (the grid of a group call), `CallsPanel.swift`, `CallsPip.swift` and the rest, `CallScreen.swift`, which drives them from the calls, and `CallScreenPreview.swift` ([checking a change](#checking-a-change)).
- **Its tests** go into your unit test target, under `WordPlusUITests/`. Without one, they wait in a `WordPlusUITests/` folder until you add a unit test target hosted by the app.
- **Then, in the target:** take `WordPlusRealtimeUI` out of its dependencies, since your copy is the screen now. Add `WordPlusRTC` (this package's room client) and `LiveKitWebRTC` (webrtc-xcframework), which the screen draws with. `CallScreen.shared.attach( rt.calls )` works as before.
- **Your own screen, from scratch:** `GroupVideoView` draws the camera or shared screen of someone in a group call (`show( person.identity, of: call )`), or your own camera (`showOwn( of: call )`). `CallVideoView` does the same in a call between two.

### When ours changes

Nothing changes your copy by itself.

1. `swift package --allow-writing-to-package-directory wordplus-ui diff` shows what changed in ours since you copied it, file by file, and whether you changed that file too.
2. `swift package --allow-writing-to-package-directory wordplus-ui update` takes ours into every file you never changed.
3. Merge the rest by hand, then build and try a call.
4. `swift package --allow-writing-to-package-directory wordplus-ui accept` records that yours has ours.

`wordplus-ui.json` and `.wordplus-ui/` record what you copied. Commit both.

## Checking a change

- **Every state, with no call:** `CallScreenPreview` draws the screen calling, ringing in, connecting, in a call by voice and by video, with the microphone and camera off, with the other side lost, reconnecting, in a group call by video and by voice, and with Add Person open. Its Dark and RTL buttons switch the look. It draws your pieces and your look, and your copy once you have one.

  ```swift
  window.rootViewController = UINavigationController( rootViewController: CallScreenPreview() )   // the list of states
  ```

  ```swift
  #Preview { CallScreenPreview( .video ) }     // one state, in the Xcode canvas
  ```

- **The tests:** with a copy, run its tests on a simulator after each change. They check each state of the preview, the dock buttons and their labels, and your pieces.
- **Then a real call,** both ways, and a group call.

## What must keep working

- **Every call state:** calling out, ringing in, connecting, in a call, reconnecting, ended, and a group call.
- **A camera or a microphone refused:** the call goes on, and says why.
- **VoiceOver:** every button keeps its label.
- **Picture in picture**, and the screen put away and brought back (`hide()`, `restore()`).
- **Right to left**, and a small phone and an iPad.
