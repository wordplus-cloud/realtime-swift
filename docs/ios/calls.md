# Calls

Calls between two people and group calls, in `WordPlusRealtimeCalls`, on the same relay and media servers as browsers: a phone and a browser call each other, and either may add someone. The Better Messages call screen, in `WordPlusRealtimeUI`, draws them with no screen code of yours. Both products are optional.

- **Calls between two people** ring on every page and app the callee has open, and run directly between the two, through TURN when a network needs it, or in a room on the WordPlus Cloud media servers when nothing else works.
- **Group calls** run on the WordPlus Cloud media servers, with no limit on people in a call. Up to 32 people on video at once take no credits with 1,000 connections, and 12 more for each 1,000 after them, a person on audio counting half. Each one above takes a credit a minute from your account.
- **Encrypted end to end**, with keys only your server gives out ([what WordPlus Cloud sees](https://docs.wordplus.cloud/apps/calls/#what-wordplus-cloud-sees)).
- **Calls ring a locked phone and a closed app** through CallKit, as phone calls do, once the app starts `SystemCalls` ([below](#ringing-a-locked-phone)).
- **User ids** are yours: digits or text such as `user_2abc`, up to 64 characters with no space. The SDK takes them as strings (`"34"`, `"user_2abc"`).

## Who may call

Your server declares calls by pattern, as it declares rooms ([calls in depth](https://docs.wordplus.cloud/apps/calls/#who-may-call)):

**Node**

```ts
realtime.calls( 'support:{a}:{b}', ( user, withUser, { a, b } ) => [ a, b ].includes( String( user ) ) && [ a, b ].includes( String( withUser ) ) );
realtime.groupCalls( 'meeting:{id}', ( user ) => isStaff( user ), { encrypt: true } );
```

**PHP**

```php
$realtime->calls( 'support:{a}:{b}', fn ( $user, $with, array $p ) => ! array_diff( [ $user, $with ], [ $p['a'], $p['b'] ] ) );
$realtime->groupCalls( 'meeting:{id}', fn ( $user ) => is_staff( $user ), [ 'encrypt' => true ] );
```

**Python**

```python
realtime.calls("support:{a}:{b}", lambda user, with_user, p: {str(user), str(with_user)} <= {p["a"], p["b"]})
realtime.group_calls("meeting:{id}", lambda user, p: is_staff(user), encrypt=True)
```

The app asks your calls route (`{endpoint}/calls`) with its headers, as the browser does.

## The call screen

```swift
import WordPlusRealtimeCalls
import WordPlusRealtimeUI

CallScreen.shared.attach(rt.calls)   // rings for every call coming in, and shows it once answered
CallScreen.shared.onAnswered = { answered in
    switch answered {
    case let .call(call): follow(call)          // the call a ring became
    case let .group(group): follow(group)       // or the group call it rang into
    }
}

let call = try await rt.calls.start("support:34:42", to: "34", type: .video)
CallScreen.shared.show(call, name: "Ann", avatar: "https://shop.example.com/ann.jpg")

let meeting = try await rt.calls.group("meeting:daily", type: .video)
CallScreen.shared.show(meeting, title: "Daily meeting")
```

- **It is the Better Messages screen itself,** the same files as its app: the ring with Answer and Decline, the call between two with the picture of the other side and your own in the corner, the grid of a group call, and the controls (microphone, camera, turning the camera round, the speaker, picture in picture, hanging up).
- **It sits in a window of its own** above the app. Its chevron puts it away and the call goes on: show a bar of your own meanwhile, and `CallScreen.shared.restore()` brings it back. `hide()` puts it away from your code.
- **A call ringing during another** is answered busy.
- **A call that becomes a group call** stays on the screen, as the group call.
- **Its words and colours:** `configure(.init(strings: [...], tokens: [...], tokensDark: [...], darkMode: false))`, the strings by the Better Messages keys (`answer`, `reject`, `end_call`, `calling`, `connecting` …), the colours by its design tokens (`"--bm-color-accent": "#21759b"`). The English is the default for any string left out.
- `CallScreen.shared.log` hands you the lines the screen writes, for your own log.

## Ringing a locked phone

`SystemCalls` makes the app's calls phone calls to iOS, as the Better Messages app's are. A call rings a locked phone and a closed app with CallKit's own screen. It is answered and hung up from the lock screen, a watch, a car or headphones, goes on with the app in the background, and lands in Recents, where a tap calls back.

Start it when the app launches, before anything else, because a call can wake the app with nothing else running:

```swift
import WordPlusRealtimeCalls

// AppDelegate, application(_:didFinishLaunchingWithOptions:)
SystemCalls.start(.init(name: "Shop")) {
    await Session.shared.realtime()      // the signed-in user's connection, or nil when nobody is signed in
}

// A call tapped in Recents, or asked of Siri: your app places it, naming it as your server allows.
SystemCalls.onCallBack { back in
    guard let user = back.user else { return }
    Task { try await rt.calls.start(callName(with: user), to: user, type: back.type) }
}
```

```swift
// SwiftUI: the activity Recents and Siri hand the app
.onContinueUserActivity("INStartCallIntent") { SystemCalls.handle($0) }
```

- **How a closed app rings:** the phone goes with the user's line, so their calls ring it. A call sends it a VoIP push, CallKit rings at once, and your closure gives a connection. The SDK holds the line on it, and the call goes on as if it had come in while the app was open.
- **Answered on the lock screen,** the call arrives in `SystemCalls.onAnswered { answered in … }`. The call screen (`WordPlusRealtimeUI`) shows it by itself.
- **With the app open,** a call rings on the app's own screen, as before, and CallKit's ring comes too. Answered on either, it is answered once.
- **The key:** WordPlus Cloud sends the push with your APNs key, which you add to the app on the account's Apps page, under Phone calls ([shipping](shipping.md#push-and-callkit)). WordPlus Cloud keeps it, and the realtime servers get only short-lived tokens made from it.
- **The caller's name** on the lock screen is the `name` in the caller's info from your server. The push carries that info sealed, and the phone opens it with the day's key, which the SDK keeps in the Keychain. Apple sees the call's id and name, the caller's user id and the call type, never the name.
- **Signing out:** `rt.calls.stopRinging()` takes the phone off the user's line, so a closed app no longer rings for them.
- **A ring during a call** is answered busy: CallKit takes one call at a time.
- **Not on a simulator,** which has no PushKit or CallKit, and not in mainland China, where iOS does not offer CallKit: calls ring there with the app open, as before.

## Calls of your own

The same calls, for screens you draw:

```swift
rt.calls.onIncoming { incoming in
    // incoming.from, incoming.info ["name", "avatar"], incoming.type, incoming.group (a ring into a group call)
    incoming.onOver { reason in hideRing() }                   // answered elsewhere, the caller gave up …
    Task { @MainActor in
        switch try await incoming.accept() {                   // or try await incoming.decline(busy: true)
        case let .call(call): show(call)
        case let .group(group): show(group)
        }
    }
}

let call = try await rt.calls.start("support:34:42", to: "34", type: .video)
call.onState { state in label.text = state.rawValue }        // ringing, connecting, connected, reconnecting, ended
call.onRemote { remoteView.show(call.remoteCamera) }          // what the other side sends changed
call.onEnded { reason in close(reason) }                      // hangup, declined, busy, cancelled, group …

let remoteView = CallVideoView()                              // a UIView
let ownView = CallVideoView()
ownView.mirrored = true
ownView.show(call.localCamera)

call.microphone = false                                       // mute
call.camera = false                                           // stop sending the camera
call.flipCamera()                                             // the front one to the back, and back
call.end()                                                    // hangs up, or calls it off while it rings
```

- **The microphone and, for a video call, the camera** open as the call begins, so iOS asks the user then ([shipping](shipping.md#microphone-and-camera)).
- **`call.path`** says what carries it: `.direct`, `.relay` (TURN) or `.room`. `call.peer` and `call.peerInfo` who the other side is.
- **`rt.calls.stopRinging()`** lets go of this app line: its user calls no longer ring here.

## Adding people

Once a call is up, either side may ring someone else into it. Both sides go on in a group call of their own, without hanging up:

```swift
call.onGroup { group in follow(group) }                // both sides, and the call then ends as `group`
let invite = try await call.add("43")                   // rings user 43, throws its code
```

- **Your rule decides,** as for any call: the user calling the person about the call name, then the person taking a call from them.
- **The person rung in** gets an `IncomingCall` whose `group` is set, and `accept()` answers `.group`.
- **`group.add(_:)`** rings more people in, from anyone in it. A group call your server names (`rt.calls.group`) takes nobody that way: `not_a_call`.

## Group calls

```swift
let group = try await rt.calls.group("meeting:daily", type: .video)
group.microphone = true                       // nothing is sent into a group call until asked
group.camera = true
group.onPeople { people = group.people }      // [GroupPerson]: user, info, camera, microphone, screen, speaking, publish
group.onState { state in label.text = state.rawValue }
group.onEnded { reason in close(reason) }
group.leave()
```

- **`group.encrypted`** says whether its media is encrypted end to end: always for the group call that comes from a call, and for one your server names when its rule says `encrypt`.
- **Drawing it yourself:** a `GroupVideoView` shows anyone's camera, `view.show(person.identity, of: group)`, or their shared screen with `source: .screen`, and `view.showOwn(of: group)` this app's own camera. Audio plays by itself.

### Speakers and listeners

A class, a town hall or an audio room: your rule makes the listeners (`publish: false`), and your server lets one speak while the call runs, with `realtime.call( "class:7" ).permit( user, { publish: true } )` ([speakers and listeners](https://docs.wordplus.cloud/apps/calls/#speakers-and-listeners)). The app hears it:

```swift
group.onPermissions { can in
    group.microphone = can.publish   // let on: it speaks. Back to listening: the media server took it down already
}
let speakers = group.people.filter(\.publish)
```

- **`group.can`** is what the app may do now, `GroupPermissions(publish:subscribe:)`: what your rule said, then what your server changed.
- **Back to listening,** `microphone` and `camera` turn false, and nothing is sent again on a reconnect.
- **Everyone sees who may speak:** `GroupPerson.publish`, with `onPeople` when it changes.

## Why a call ended

`call.endReason`, and the reason `onEnded` gets: the same codes as the browser ([why a call ended](https://docs.wordplus.cloud/apps/calls/#why-a-call-ended)), plus `connection_failed` when no path connected. A call that could not start throws a `CallError` with the code: `forbidden`, `no_user`, `not_included`, `auth_failed` ([errors](https://docs.wordplus.cloud/apps/errors/#calls)).
