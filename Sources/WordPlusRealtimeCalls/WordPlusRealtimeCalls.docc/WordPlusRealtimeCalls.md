# ``WordPlusRealtimeCalls``

Calls between two people and group calls on WordPlus Cloud, which ring on every page and app the callee has open: a phone and a browser call each other.

## Overview

Calls run directly between the two, through TURN when a network needs it, or in a room on WordPlus Cloud's media servers, and become a group call when either side adds someone. Your server decides who may call whom. The call screen of Better Messages, in `WordPlusRealtimeUI`, draws them. This module is for an app that draws its own. The [calls guide](https://docs.wordplus.cloud/ios/calls/) has more.

```swift
rt.calls.onIncoming { incoming in
    Task { @MainActor in
        if case let .call(call) = try await incoming.accept() { show(call) }
    }
}
let call = try await rt.calls.start("support:34:42", to: "34", type: .video)
call.onState { state in label.text = state.rawValue }
```

## Topics

### Calls

- ``RealtimeCalls``
- ``Call``
- ``IncomingCall``
- ``CallType``
- ``CallState``
- ``CallPath``
- ``CallError``

### Group calls

- ``GroupCall``
- ``GroupCallState``
- ``GroupPerson``
- ``CallInvite``

### Video

- ``CallVideoView``
- ``CallVideoTrack``
