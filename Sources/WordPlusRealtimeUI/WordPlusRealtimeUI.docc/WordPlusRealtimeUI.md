# ``WordPlusRealtimeUI``

Better Messages' native call screen on WordPlus Cloud's calls: the ring, the call between two, the group call's grid and the controls, with no screen code of yours.

## Overview

The screen is the same files as Better Messages' app, so it improves with it. It sits in a window of its own above the app; its chevron puts it away while the call goes on. The [calls guide](https://docs.wordplus.cloud/ios/calls/#the-call-screen) has more.

```swift
CallScreen.shared.attach(rt.calls)
let call = try await rt.calls.start("support:34:42", to: "34", type: .video)
CallScreen.shared.show(call, name: "Ann")
```

## Topics

### The screen

- ``CallScreen``
