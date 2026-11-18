# Calls

Calls between two people and group calls, in `WordPlusRealtimeCalls`, on the same relay and media servers as browsers: a phone and a browser call each other, and either may add someone. The Better Messages call screen, in `WordPlusRealtimeUI`, draws them with no screen code of yours. Both products are optional.

- **Calls between two people** ring on every page and app the callee has open. They take one of three paths, tried in turn: directly between the two devices, through our relays (TURN) on the ports of the web, 443 and 80, when a network blocks that, and in a room on our media servers when even the relays cannot reach. A call moves on its own, without hanging up, and takes no credits on any path.
- **Group calls** run on the WordPlus Cloud media servers, with no limit on people in a call. Up to 32 people on video at once take no credits with 1,000 connections, and 12 more for each 1,000 after them, a person on audio counting half. Each one above takes a credit a minute from your account.
- **Encrypted end to end,** with keys only your server gives out: a call between two people on every path, and the group call it becomes. A group call your server names is encrypted end to end when its rule says `encrypt` ([what WordPlus Cloud sees](https://docs.wordplus.cloud/apps/calls/#what-wordplus-cloud-sees)).
- **Calls ring a locked phone and a closed app** through CallKit, as phone calls do, once the app starts `SystemCalls` ([below](#ringing-a-locked-phone)).
- **User ids** are yours: digits or text such as `user_2abc`, up to 64 characters with no space. The SDK takes them as strings (`"34"`, `"user_2abc"`).

How a call starts, runs and ends, for the app and for your server: [how calls work](https://docs.wordplus.cloud/use-cases/how-it-works/#calls-between-two-people). What people build with them, from a support call to a meeting: [use cases](https://docs.wordplus.cloud/use-cases/overview/).

## Starting with a token from your server

Whether someone may call or join is your app's own logic. Your own route checks whatever it needs and answers a token, and the app starts with it, as a string it passes on. No rule of the server package is involved, and the person called needs no token of their own, as the ring proves your server said yes.

```swift
// A call between two. Your route answers realtime.callToken( user, to, { type } ). A token rings once, so get a new one for each call.
let call = try await rt.startCall(token)

// A group call. Your route answers realtime.groupCallToken( user, name, { admin, encrypt } ), which says what this user may do in it.
let meeting = try await rt.joinGroupCall(token)

// A live stream. Your route answers realtime.streamToken( user, name, { role } ). A token lasts ten minutes, so this asks your route again as each runs out.
let show = try await rt.joinStream(getToken: { try await streamTokenFromYourRoute() })

// Ringing someone into a call. Send call.ref to your route, which answers realtime.callToken( user, to, { into: ref } ).
let invite = try await call.add(token)
```

- **`rt.joinStream(token)`** takes one token, for a screen that won't outlast it. It throws `expired` when it would need another.
- **`call.ref`** is what your route gives `into`, and your server checks it: only someone in the call gets a token from it. `group.ref` is the same for the group call a call became, and nil for any other.
- **`call.add`** takes a token or a user id. A token made for another call throws `forbidden`.
- **A host you name in `groupCallToken`** mutes and removes people through the calls route, with what the token gave ([the host](#the-host)).
- **Refusals:** `bad_token` for what isn't a token, `forbidden` for a call or group call token made for another user, and the realtime server's own for a token that ran out. Someone taken out of a call needs a new token to come back.

Rings come in as any other, `rt.calls.onIncoming`, then `accept()`. The rules below do the same from your server's patterns, and `rt.call`, `rt.groupCall` and `rt.stream` go on working with them.

## Who may call

Your server declares calls by pattern, as it declares rooms ([calls in depth](https://docs.wordplus.cloud/apps/calls/#who-may-call)). Here a support call between two people is named `support:` and their two ids, smaller first: `support:34:42`. A meeting is named `meeting:` and its team: `meeting:daily`. The app asks your calls route (`{endpoint}/calls`) with its headers each time it places, answers or joins a call, as the browser does, and your rule answers. These rules decide:

1. A support call is only between the two people its name holds: whoever calls and whoever is called are both in it.
2. Your server asks twice, as the caller places the call (`side.role` is `caller`) and as the callee answers (`callee`). Here anyone called may answer.
3. Only placing the call is checked further: one of the two is staff, so a customer calls an agent and an agent calls a customer, but two customers never call each other.
4. A meeting is for the members of its team alone.
5. Its lead is its host (`admin`), who mutes and removes people from the web call screen ([the host](#the-host)).
6. A meeting is encrypted end to end (`encrypt`).

**Node**

```ts
realtime.calls( 'support:{a}:{b}', async ( user, withUser, { a, b }, call, side ) => {
    // 1. Both people are in the name, as text: user 34 is "34" there.
    const pair = [ a, b ];
    if ( ! pair.includes( String( user ) ) ) return false;
    if ( ! pair.includes( String( withUser ) ) ) return false;

    // 2. Anyone called may answer.
    if ( side.role === 'callee' ) return true;

    // 3. Placing it: one of the two is staff.
    const callerIsStaff = await isStaff( user );
    const calleeIsStaff = await isStaff( withUser );
    return callerIsStaff || calleeIsStaff;
} );

realtime.groupCalls( 'meeting:{id}', async ( user, { id } ) => {
    // 4. Members of the team only.
    if ( ! await isMemberOf( id, user ) ) return false;

    // 5. Its lead is its host.
    return { admin: await isLeadOf( id, user ) };
}, { encrypt: true } );   // 6. Encrypted end to end.
```

**PHP**

```php
$realtime->calls( 'support:{a}:{b}', function ( $user, $with, array $p, string $call, array $side ) {
    // 1. Both people are in the name, as text: user 34 is "34" there.
    $pair = [ $p['a'], $p['b'] ];
    if ( ! in_array( (string) $user, $pair, true ) ) {
        return false;
    }
    if ( ! in_array( (string) $with, $pair, true ) ) {
        return false;
    }

    // 2. Anyone called may answer.
    if ( 'callee' === $side['role'] ) {
        return true;
    }

    // 3. Placing it: one of the two is staff.
    $caller_is_staff = is_staff( $user );
    $callee_is_staff = is_staff( $with );
    return $caller_is_staff || $callee_is_staff;
} );

$realtime->groupCalls( 'meeting:{id}', function ( $user, array $p ) {
    // 4. Members of the team only.
    if ( ! is_member_of( $p['id'], $user ) ) {
        return false;
    }

    // 5. Its lead is its host.
    return [ 'admin' => is_lead_of( $p['id'], $user ) ];
}, [ 'encrypt' => true ] ); // 6. Encrypted end to end.
```

**Python**

```python
def may_call_support(user, with_user, p, call, side):
    # 1. Both people are in the name, as text: user 34 is "34" there.
    pair = [p["a"], p["b"]]
    if str(user) not in pair:
        return False
    if str(with_user) not in pair:
        return False

    # 2. Anyone called may answer.
    if side["role"] == "callee":
        return True

    # 3. Placing it: one of the two is staff.
    caller_is_staff = is_staff(user)
    callee_is_staff = is_staff(with_user)
    return caller_is_staff or callee_is_staff


def may_join_meeting(user, p):
    # 4. Members of the team only.
    if not is_member_of(p["id"], user):
        return False

    # 5. Its lead is its host.
    return {"admin": is_lead_of(p["id"], user)}


realtime.calls("support:{a}:{b}", may_call_support)
realtime.group_calls("meeting:{id}", may_join_meeting, encrypt=True)   # 6. Encrypted end to end.
```

- **`isStaff`, `isMemberOf` and `isLeadOf`** are your own lookups, in your own data.
- **What a rule may answer:** `false`, `true`, or an object with `info` (what the others see of the user, your `profile` name and avatar by default), and in a group call `publish` and `subscribe` (true unless said), `admin` and `hidden` (false unless said) ([who may call](https://docs.wordplus.cloud/apps/calls/#who-may-call)).

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

let call = try await rt.call("support:{pair}", to: "34", type: .video)
CallScreen.shared.show(call, name: "Ann", avatar: "https://shop.example.com/ann.jpg")

let meeting = try await rt.groupCall("meeting:daily", type: .video)
CallScreen.shared.show(meeting, title: "Daily meeting")
```

- **It is the Better Messages screen itself,** the same files as its app: the ring with Answer and Decline, the call between two with the picture of the other side and your own in the corner, the grid of a group call, and the controls (microphone, camera, turning the camera round, the speaker, picture in picture, the people of a group call, hanging up).
- **It sits in a window of its own** above the app. `CallScreen.shared.hide()` puts it away and the call goes on: show a bar of your own meanwhile, and `CallScreen.shared.restore()` brings it back. It has no button for that of its own, so a person stays on it until the call ends unless you give them one: a [button in the dock](customizing.md) that calls `hide()`, as the Example Shop has.
- **The microphone and camera:** iOS asks for them as the call opens them ([shipping](shipping.md#microphone-and-camera)).
- **A call ringing during another** is answered busy.
- **A call that becomes a group call** stays on the screen, as the group call.
- **Its words and colours:** `configure(.init(strings: [...], tokens: [...], tokensDark: [...], darkMode: false))`, the strings by the Better Messages keys (`answer`, `reject`, `end_call`, `calling`, `connecting`, `optimizing_video` over a camera changing codec …), the colours by its design tokens (`"--wplus-color-accent": "#21759b"`). The English is the default for any string left out ([customizing](customizing.md)).
- `CallScreen.shared.log` hands you the lines the screen writes, for your own log.

![The call screen on an iPhone, from its preview with no call: on the left a video call from Ann ringing in, with Answer, camera, microphone and Decline in the dock. On the right a call to Ann ringing out, with the camera, microphone, speaker and hang up](https://docs.wordplus.cloud/img/ios/call-ringing-calling.webp)

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
    Task {
        if let user = back.user {                       // a call between two
            _ = try await rt.calls.start(callName(with: user), to: user, type: back.type)
        } else if let group = back.group {              // a group call, by its name
            _ = try await rt.calls.group(group, type: back.type)
        }
    }
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
- **The caller's name** on the lock screen is the `name` in the caller's info from your server. The push carries that info sealed, and the phone opens it with the day's key, which the SDK keeps in the Keychain for this ([where the keys are kept](encryption.md#where-the-keys-are-kept)). Apple sees the call's id and name, the caller's user id and the call type, never the name of the caller.
- **Signing out:** `rt.calls.stopRinging()` takes the phone off the user's line, so a closed app no longer rings for them.
- **A ring during a call** is answered busy: CallKit takes one call at a time.
- **Not on a simulator,** which has no PushKit or CallKit, and not in mainland China, where iOS does not offer CallKit: calls ring there with the app open, as before. `SystemCalls.isAvailable` says whether CallKit runs here, and `SystemCalls.isStarted` whether `start` was called.

How the system shows the calls:

```swift
SystemCalls.start(.init(
    name: "Shop",                       // shown for a caller whose name is not known yet
    ringtone: "ring.caf",               // a sound in the app bundle, nil for the system ring
    icon: UIImage(named: "CallIcon"),   // the button that opens the app from the system call screen: 40 points, one colour
    recents: true                       // calls go to Recents, where a tap calls back
)) { await Session.shared.realtime() }

SystemCalls.setName("Ann", of: call)    // the name iOS shows for a call the app placed. The call screen sets it itself
```

## Calls of your own

The same calls, for screens you draw:

```swift
rt.calls.onIncoming { incoming in
    // incoming.from, incoming.info ["name", "avatar"], incoming.type, incoming.group (a ring into a group call)
    incoming.onOver { reason in hideRing() }                   // answered or declined, here or elsewhere, the caller gave up …
    Task { @MainActor in
        switch try await incoming.accept() {                   // or try await incoming.decline(busy: true)
        case let .call(call): show(call)
        case let .group(group): show(group)
        }
    }
}

let call = try await rt.calls.start("support:{pair}", to: "34", type: .video)
call.onState { state in label.text = state.rawValue }        // ringing, connecting, connected, reconnecting, ended
call.onRemote {                                               // what the other side sends changed
    remoteView.show(call.remoteCamera)
    screenView.show(call.remoteScreen)                        // the screen they share, nil while they share none
    cameraOffBadge.isHidden = call.remoteMedia["camera"] == true
}
call.onEnded { reason in close(reason) }                      // hangup, declined, busy, cancelled, group …

let remoteView = CallVideoView()                              // a UIView
let ownView = CallVideoView()
ownView.mirrored = true
ownView.show(call.localCamera)

call.microphone = false                                       // mute
call.camera = false                                           // stop sending the camera
call.flipCamera()                                             // the front one to the back, and back
call.end()                                                    // hangs up, or calls it off while it rings

rt.calls.onError { code in log(code) }                        // the line refused, or a group call that could not join
rt.calls.onCall { call in keepToMyRules(call) }               // every call started or answered, the call screen's too
rt.calls.onGroup { group in keepToMyRules(group) }            // every group call joined, the call screen's too
```

- **The microphone and, for a video call, the camera** open as the call begins, so iOS asks the user then ([shipping](shipping.md#microphone-and-camera)).
- **`call.remoteMedia`** says what the other side has on: `camera`, `microphone`, `screen_share` and `screen_share_audio`, each true or false, read again at each `onRemote`.
- **`call.path`** says what carries it: `.direct`, `.relay` (TURN) or `.room`, and `call.onPath` hears it change. `call.onWaiting` hears the room a call moved to wait for a place on the mesh (a `CallWait`: `until` and `reason`), and it goes on by itself. `call.peer` and `call.peerInfo` who the other side is, `call.role` whether this app is its `.caller` or `.callee`.
- **`rt.calls.incoming`** lists the calls ringing for the user now.
- **`rt.calls.onError`** hears what went wrong away from any one call: your server refused the line its calls ring on (`forbidden`, `expired` …), or a group call could not join its room (`room_failed`, and the group call ends with it).
- **Where the sound goes:** a video call starts on the speaker and an audio call at the earpiece, and a headset takes it as iOS routes it. The call screen's speaker button moves it, and with `SystemCalls` so do CallKit's screen and Control Center. A screen of your own moves it as the call screen does, with `AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)`.
- **`rt.calls.onCall` and `rt.calls.onGroup`** hear each call this app started or answered and each group call it joined, whoever asked for it, a ring answered on the call screen or a call of its that became a group call among them, so an app can keep to rules of its own, such as how long a call may last. The room a call moved to when no path carried it is still that call, and neither hears it.
- **`rt.calls.people(name)`** gives who this user may add to calls named `name`, as your server lists them (a `CallPerson`: `id`, `name` and `avatar`), none when it lists nobody or could not answer. Your server's `people` answers it ([adding people](https://docs.wordplus.cloud/apps/calls/#adding-people)).
- **`rt.calls.may(asks)`** tells whether this user may call each person about each call, `[CallAsk(call: "support:34:42", to: "42")]`, in the order asked: what a list of people asks before it offers call buttons. Nil where your server gave no answer, a route of its own that does not know the question or a failed request, and placing the call still asks the rule. Any number of questions, sent 100 a request.
- **`rt.calls.stopRinging()`** lets go of this app line: its user calls no longer ring here.
- **Taking a handler off:** each `on…` of `rt.calls`, a call, a group call and a ring gives a `CallListener`, which `off(listener)` on the same object takes off.

### A meter and the camera that opens

For a device check of your own: `call.microphoneLevel` and `group.microphoneLevel` say how loud the microphone goes out, from 0 to 1, nil while it is off. In a call between two it comes from the report of the connection, every two seconds. `call.preferCamera( front: false )` and `group.preferCamera( front: false )` choose the side the next camera opens on, and `frontCamera` says it. A camera on turns round with `flipCamera()`.

## Calls on your own signalling

A call between two people can travel by signalling other than this SDK's, and still run on its call engine and show on its call screen: Better Messages' own, or a transport of your app.

```swift
// Better Messages: a connection on its namespace, with its handshake, and its `p2pCall`.
let bm = Realtime(RealtimeOptions(app: site, endpoint: siteREST, server: URL(string: "https://cloud.better-messages.com")!,
                                  namespace: "/", auth: ["sid": .string(site), "uid": 7, "sk": .string(userKey), "v": "3.2.0"]))
bm.connect()
let call = try await bm.calls.call(over: P2PCallTransport(bm), id: "4711", role: .callee, peer: "34",
                                   peerInfo: ["name": "Ann"], type: .video, signalKey: callKey, roomServer: siteMediaServer)
CallScreen.shared.show(call, name: "Ann")
```

- **`rt.calls.call(over:id:role:peer:peerInfo:type:signalKey:mediaKey:roomServer:)`** joins a call that whoever made it on the relay already made, a site's server for Better Messages: `.caller` rings until the other side joins, `.callee` connects. `signalKey` seals the signals and never reaches the relay, `mediaKey` encrypts the room the call moves to when neither path works, and `roomServer` says where that room is when the relay hands it over by its token alone, as Better Messages' does (its site has it, from the relay's answer to `/p2p/call/create`). It throws the relay's refusal: `no_call`, `not_participant`, `call_ended`, `answered_elsewhere`, or `signaling_unavailable` when the transport answered nothing.
- **`P2PCallTransport(rt)`** is Better Messages' `p2pCall`, on a connection opened on its namespace. The connection moves between servers and comes back after a drop as on `/channels`, and the call joins again on each new socket.
- **`CallTransport`** is the protocol to carry it your own way, to a relay that answers the same ops: `connected`, `send(_:ack:)` with the op and its answer, `listen(callId:session:_:)` for one session's events, and `onReconnect(_:)` when the transport is back. The engine calls it on the main queue, and takes what it answers to the main queue itself.
- **What stays the SDK's own:** such a call adds nobody (`add` throws `not_supported`), renews no token of this SDK, and ends as `group` where the relay moves it into a group call, which its product joins its own way. Rooms, presence and calls by name are `/channels`' protocol.

## Adding people

Once a call is up, either side may ring someone else into it. Both sides go on in a group call of their own, without hanging up:

```swift
call.onGroup { group in follow(group) }                 // both sides, and the call then ends as `group`
let invite = try await call.add("43")                   // rings user 43, throws its code
invite.onState { state in label.text = state }          // answered, rejected, busy, no_answer, cancelled
try await invite.cancel()                               // calls it off while it rings
```

- **Your rule decides,** as for any call: the user calling the person about the call name, then the person taking a call from them.
- **`invite`** is the `CallInvite` rung: `invite.to`, and `invite.state`, `ringing` and then how it ended, in the words of the relay: `answered`, `rejected`, `busy`, `no_answer` or `cancelled`. `invite.onState` hears it change. A ring runs out after 45 seconds. The person comes into `group.people` once they answer.
- **`invite.cancel()`** calls it off while it rings, from the app that rang: `forbidden` for anyone else, and nothing for a ring that has ended.
- **`group.invites`** lists the rings into the group call this app heard of, its own and those of anyone else in it, and `group.onInvite` hears each new one (`invite.from` who rang, `invite.group` the call).
- **The person rung in** gets an `IncomingCall` whose `group` is set, and `accept()` answers `.group`.
- **`group.add(_:)`** rings more people in, from anyone in it. A group call your server names (`rt.calls.group`) takes nobody that way: `not_a_call`.
- **`invite.canCancel`** says whether `cancel()` can call it off now: it still rings, and this app rang it.

### On the call screen

```swift
CallScreen.shared.addPerson = true                      // Add Person in the dock, off unless you turn it on
```

- **Add Person** shows once a call is up, in a call between two and in a group call made from one, as the `add` control of the [dock](customizing.md#2-a-piece-of-your-own). It offers whom your server lists (`rt.calls.people`, your server's `people`), less anyone in the call and anyone `rt.calls.may` answers no for.
- **A press rings them** and the card stays, each row saying how its ring stands: Ringing… with Cancel for a ring of this app, then Answered, Declined, Busy, No answer or Cancelled. A person whose ring ended can be rung again. A call between two goes on as a group call under the card, on the same screen.
- **A ring that did not go out** closes the card and the screen says why.
- **Its words:** `add_person`, `add_person_loading`, `add_person_empty`, `add_person_ringing`, `add_person_answered`, `add_person_rejected`, `add_person_busy`, `add_person_no_answer`, `add_person_cancelled`, `cancel`, `call_forbidden` and `call_unavailable`.
- **Unlike the web,** the card stays open after a press, where the web closes it, and it says how each ring stands. The web offers it in a group call your server names too, where the ring is refused. Rings of people your server does not list for this user are not drawn.

## Group calls

How a group call starts, who gets in, how your server runs it and how it ends: [how group calls work](https://docs.wordplus.cloud/use-cases/how-it-works/#group-calls).

```swift
let group = try await rt.calls.group("meeting:daily", type: .video)
group.setMicrophone(true)                     // nothing is sent into a group call until asked
group.setCamera(true)
group.flipCamera()                            // the front camera to the back, and back
group.onPeople { people = group.people }      // [GroupPerson]: user, info, camera, microphone, screen, speaking, publish, optimizing, quality
group.onState { state in label.text = state.rawValue }
group.onEnded { reason in close(reason) }     // left, removed, closed, disconnected, room_failed
group.leave()
```

- **`group.me`** is this app's own user in the room, as the others see them: a `GroupPerson` with their info as your server gave it, nil until connected. A tile for oneself draws from it.
- **`group.quality`** says how this app's connection stands: `.excellent`, `.good`, `.poor`, `.lost` or `.unknown`, and `group.onQuality` hears it change. `person.quality` says the same of each person, for a mark on their tile.
- **`group.uploadJammed`** says whether the upload this app sends on is jammed: what it sends waits seconds on the person's own line, or gets no answer at all, while what is sent to it still arrives. Others may then see its video freeze or hear its sound break up, and the media server rates such a line good, so show it as poor whatever `quality` says. `group.onUploadJam` hears it change.
- **The sound comes first** on an upload too narrow for the call: the microphone comes down to 32 kbps, then the camera gets smaller a step at a time until the sound gets through, and comes back as it holds. The microphone also lets its media server ask it again for what the upload lost. Nothing to set.
- **`group.onError`** hears what goes wrong in a call that goes on: the camera or microphone could not go out (`publish_failed`, `source` says which), or a track could not be encrypted or decrypted (`encryption_failed`).
- **Joining again** after being removed, or after the call ended for everyone, works at once: `rt.calls.group` waits for the next second by itself, since the realtime server refuses a token signed in the second that happened.
- **A place on the mesh:** a join may wait for one when the servers are busy or full. `group.waiting` is a `CallWait` then, `until` when and `reason` why (`busy`, `slot`, `full` or `unreachable`), and `group.onWaiting` hears it. `group.state` stays `.connecting`, and the join goes on by itself.
- **`group.encrypted`** says whether its media is encrypted end to end: always for the group call that comes from a call, and for one your server names when its rule says `encrypt`.
- **Drawing it yourself:** a `GroupVideoView` shows anyone's camera, `view.show(person.identity, of: group)`, or the screen they share with `source: .screen`, and `view.showOwn(of: group)` this app's own camera. Audio plays by itself.
- **A camera changing codec:** a browser in the call may move its camera to the codec its computer sends best, which takes the camera away for a moment. `GroupPerson.optimizing` is true from its word until the new camera arrives, the camera is turned off, or the media server's failsafe has passed (10 seconds unless it sets another): draw a placeholder such as "Optimizing video quality..." over their picture then, not a camera turned off. The call screen does it for you, and holds its placeholder until the new camera's first frame.
- **What this app sends:** its camera, its microphone, and its screen where the app was built for it ([sharing the screen](#sharing-the-screen)). Raising a hand is the call's own where it offers `hand` ([moderating a group call](#moderating-a-group-call)).

![A group call on the call screen of an iPhone, from its preview with no cameras on: on the left by video, a tile for Ann, who is speaking, Ben with his microphone off, Cara and this phone. On the right by voice, the same four as a list. Below each, the dock with the camera or microphone, the speaker, the people of the call and leaving](https://docs.wordplus.cloud/img/ios/group-call.webp)

### The host

The host of a group call is whom its rule answers `admin: true`. In a browser, the call screen gives the host buttons on the tile of each of the others: mute, let speak, make a listener, remove ([permissions](https://docs.wordplus.cloud/apps/permissions/#group-calls)).

The call screen on iOS gives the host the same: a menu on the tile of each of the others, with Spotlight for Everyone, and Host Controls in the dock. In a screen of your own, each act has a word of its own:

```swift
group.can.admin                        // true for the host
try await group.mute("42")             // their microphone off, which they may turn on again
try await group.makeListener("42")     // a listener, who sends nothing
try await group.letSpeak("42")         // a speaker again
try await group.remove("42")           // out of the call
try await group.spotlightOn("42")      // on the main tiles for everyone, up to four
try await group.spotlightOff("42")     // off them, or everyone with no user
group.spotlit                          // who is on them, by their user ids
group.onSpotlit { users in redraw(users) }
```

Each goes through your calls route, which asks the call's rule again and takes it from the host alone. Each answers whether it changed anything, and throws its code: `forbidden` for an app that isn't the host, `not_moderated` for a room that isn't a group call your server names (a call that became one), `spotlight_full` for a fifth person in the spotlight.

Banning, holding a microphone, the room's rules, hands, asks and ending the call for everyone are in [moderating a group call](#moderating-a-group-call). Your server may do each of them too, from a route of yours that checks who asks, [below](#from-your-server) ([buttons for the host](https://docs.wordplus.cloud/use-cases/how-it-works/#buttons-for-the-host)). The app hears each change: a person muted in `onPeople`, its own right to speak in `onPermissions`, the app taken out in `onEnded` with `removed`, and the call ended for everyone with `closed`.

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
- **A listener asks to speak** by raising a hand, `try await group.raiseHand()`, where the call offers `hand`, and every host sees it in `group.hands` ([moderating a group call](#moderating-a-group-call)). With a server package from before it, a room of yours carries hands, as the browser did: `rt.join("class:7").emit("hand", ["up": true])` from the app, when the room rule lists `hand` in `emit`.

## Moderating a group call

A host runs a group call as in Better Messages, and a browser and a phone in the same call see the same thing. Some acts happen once, and some are held by the call itself, so a reload, a dropped connection or a token your route signs later does not undo them. Everything a call holds goes when it ends, or once everyone has left it for a minute, and a join after that starts a new call. A ban given minutes is the one exception: it lasts its minutes.

| Act | What it does | How long it holds |
|---|---|---|
| Mute (`mute`) | turns their microphone off once | not held: they may turn it on again |
| Mute Microphone (`holdMic`) | keeps their microphone off | until Allow Microphone (`releaseMic`), Mute or Unmute Everyone, or the end of the call |
| Make Listener, Promote (`makeListener`, `letSpeak`) | stops or allows what they send | until the other one, a switch of Broadcast Mode, or the end of the call |
| Remove (`remove`) | takes them out now, a kick | not held: a new token takes them back in, unless the call is locked |
| Ban (`ban`) | takes them out and keeps them out, whatever token they bring | for the minutes the host gives, at most a week, or until the call ends |
| Mute Everyone, Lock, Broadcast Mode (`setRules`) | the room's rules | until the call ends or everyone has left |
| Raise Hand (`raiseHand`) | a hand every host sees, those who join later too | until it is lowered or its owner leaves |
| Ask to Turn On (`askToTurnOn`) | asks someone to turn on their camera or microphone | nothing is kept, and the same ask waits 30 seconds |
| End for Everyone (`end`) | takes everyone out | clears everything the call held but a ban given minutes |

A host is never held: their microphone stays theirs, a ban of a host is refused (`forbidden`), and Lock and Broadcast Mode leave them as they are. Lock lets back in whoever was already in the call, so a reload never strands them, while someone removed stays out.

### What the call offers

`group.acts` lists the acts this call takes, as `CallAct` values: those both WordPlus Cloud and your server package name. The call screen draws a control only for an act named there, and a method for an act not named throws `not_offered` and sends nothing. With a server package from before them, `group.acts` is `CallAct.base`, the five of `mute`, `letSpeak`, `makeListener`, `remove` and the spotlight, so no control appears that would do nothing.

```swift
group.acts                                   // [.remove, .ban, .listen, .speak, .mute, .holdMic, …]
group.acts.contains(.ban)                    // show a Ban button only then
```

### The host, in a screen of your own

The call screen gives the host every act it offers: a menu on the tile of each of the others, with Remove and Ban from Calls, Mute Microphone and Allow Microphone, Ask to Turn On, and Host Controls in the dock with Mute Everyone, Lock Room, Broadcast Mode, Lower All Hands and End for Everyone. The switches follow the room, so a second host sees what the first one set. In a screen of your own, each act has a method of its own, and each goes through your calls route, which takes it from the host alone:

```swift
try await group.ban("42", minutes: 60)                // out, and kept out for an hour. No minutes: until the call ends
try await group.unban("42")                           // may join again
try await group.holdMic("42")                         // their microphone off, through a reload too
try await group.releaseMic("42")                      // theirs to turn on again
try await group.setRules(mode: .broadcast)            // only hosts send. locked: true and muted: true for the other two
let id = try await group.askToTurnOn("42", devices: [.camera])   // their app hears onAsk, this one onAskAnswer
try await group.lowerHand(of: "42")                   // their hand down. lowerAllHands() for every hand
try await group.end()                                 // everyone out, and all it held goes but a timed ban
```

- **`group.rules`** is the room's rules now, `RoomRules(mode:locked:muted:)`, and `group.onRules` hears them as the app joins and on every change, whichever host made it.
- **`group.hands`** is who has a hand up, by user id, the earliest first, and `group.onHands` hears it change.
- **`group.onAskAnswer`** hears what came of an ask: its `id`, the `answer` (`.on`, `.notNow`, `.blocked`, `.noDevice` or `.busy`) and who answered.
- **Ending the call** with `end()` takes everyone out with `closed`. `leave()` still leaves alone.

### Everyone in the call

Anyone in the call may raise a hand, and an app hears what a host did to it:

```swift
try await group.raiseHand()                   // lowerHand() lowers it. group.handRaised says whether it is up
group.onAsk { ask in                          // a host asks this user to turn on a camera or microphone
    Task { try await group.answerAsk(ask, .on) }   // to that host alone: .on, .notNow, .blocked, .noDevice, .busy
}
group.onPermissions { can in
    micButton.isEnabled = !can.micHeld        // a host holds the microphone off
}
try group.turnOnMicrophone()                  // throws mic_held while it is held. microphone = true does nothing then
```

- **A held microphone** is `group.can.micHeld`. One held while the call runs turns the microphone off, and it stays off until a host lets it go. `GroupPerson.micHeld` says the same of the others.
- **Someone who drops** stays in `people` for 20 seconds with `reconnecting` true and no media, and `group.onPersonAway` says it. Once they are back, or the wait is over, `onPeople` says it. A hang-up goes at once.
- **Media that stalls** while its person is still in the room sets their `stalled`: `.video` when only their camera stopped, `.all` when their sound did too. `group.onStalled` hears it.

### A join the call refuses

A join of a group call throws a `CallError` with its code: `banned` for someone banned, with `until` the end of a ban given minutes and nil for one until the call ends, and `locked` for someone new in a locked call. `CallScreen.refusal(error)` gives the words the web shows for both, for your app to show:

```swift
do {
    let group = try await rt.joinGroupCall(token)
    CallScreen.shared.show(group)
} catch {
    if let words = CallScreen.refusal(error) { showNotice(words) }   // nil for any other refusal
}
```

The acts go through your calls route, on proofs in the token only your server makes: `host` for a host and `member` for everyone, so raising a hand needs nothing more on your server. Your server takes the same acts with `by`, the host it acts for, and the `call.moderated` webhook tells it of each act ([moderating a group call from your server](https://docs.wordplus.cloud/apps/calls/#moderating-a-group-call)).

## Sharing the screen

iOS hands over a whole screen only through a broadcast extension, a small second target in your app, so a share waits on the app being built with one: [shipping](shipping.md#sharing-the-screen) has the steps. With it, the call screen has a button, in a call between two and in a group call. Without it, there is no button and nothing else changes. In a screen of your own:

```swift
shareButton.isHidden = !ScreenShare.isAvailable                   // the app was built with the extension

await call.setScreenShare( true )                                 // the picker of the system comes up
call.onScreenShare { sharing in shareButton.isSelected = sharing }  // it began or it stopped
await call.setScreenShare( false )
```

- **`Call` and `GroupCall`** have all of it: `setScreenShare( on )`, `sharingScreen` and `onScreenShare`. A `LiveStream` has the first two ([streams](streams.md#going-live)).
- **`setScreenShare( true )`** puts up the picker of the system, and nothing goes out until the person chooses your app there. Its answer says it was asked, not that a share began. `onScreenShare` says when it begins.
- **The person may stop it from the system,** from the red bar, and `onScreenShare` hears that as well.
- **On the other side,** a browser shows the screen as it shows one from another browser, and a phone with `call.remoteScreen` or a `GroupVideoView` of the screen.
- **A simulator** cannot run a broadcast extension, so `ScreenShare.isAvailable` is false there and only a real iPhone shows a share ([what to try on one](shipping.md#sharing-the-screen)).

## From your server

Your server sees the group calls going on and runs them, with no app open: who is in a call, muting someone, letting them speak or making them a listener, taking them out, and ending the call for everyone. Call these from a route of yours that checks the user asking is the host:

**Node**

```ts
await realtime.listCalls();                     // [ { name, people, started_at } ]
const meeting = realtime.call( 'meeting:daily' );
await meeting.get();                            // { people, started_at, list: [ { user, joined_at, camera, microphone, screen } ] }
await meeting.mute( 43, 'microphone' );         // 'camera' or 'screen' too
await meeting.permit( 43, { publish: false } ); // a listener now
await meeting.remove( 43 );                     // out now
await meeting.end();                            // out, everyone
```

**PHP**

```php
$realtime->listCalls();
$meeting = $realtime->call( 'meeting:daily' );
$meeting->get();
$meeting->mute( 43, 'microphone' );
$meeting->permit( 43, [ 'publish' => false ] );
$meeting->remove( 43 );
$meeting->end();
```

**Python**

```python
realtime.list_calls()
meeting = realtime.call("meeting:daily")
meeting.get()
meeting.mute(43, "microphone")
meeting.permit(43, publish=False)
meeting.remove(43)
meeting.end()
```

A call between two people runs between their devices, so it is not in `listCalls()`. More in [calls from your server](https://docs.wordplus.cloud/apps/calls/#from-your-server). Your server also bans, holds a microphone, sets the rules, lowers hands and asks, each with `by`, the host it acts for: [moderating a group call from your server](https://docs.wordplus.cloud/apps/calls/#moderating-a-group-call).

## Why a call ended

`call.endReason`, and the reason `onEnded` gets: the same codes as the browser ([why a call ended](https://docs.wordplus.cloud/apps/calls/#why-a-call-ended)), plus `connection_failed` when no path connected. A group call ends with `left` when the app leaves it, `removed` when your server or a host took this user out, `closed` when the call was ended for everyone, `disconnected` when the media server lets the app go for anything else (its connection did not come back), and `room_failed` when it could not join. A call that could not start throws a `CallError` with the code: `forbidden`, `no_user`, `not_included`, `auth_failed`, and for a group call `banned` (with `until`) or `locked` ([a join the call refuses](#a-join-the-call-refuses)). A host's act may throw `not_offered`, `asked_recently` or `not_in_call`, and `turnOnMicrophone()` throws `mic_held` ([errors](https://docs.wordplus.cloud/apps/errors/#calls)).
