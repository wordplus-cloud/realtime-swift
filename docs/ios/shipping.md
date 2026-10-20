# Shipping

## Your server address

Builds point at your server in full, over HTTPS: App Transport Security refuses plain HTTP. While you develop, the simulator reaches your Mac at `localhost`. Allow it in the app Info.plist for debug builds only:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

Your app in WordPlus Cloud needs no address for the app: a native app is let in by itself. The key and secret stay on your server. The app gets what it needs from your server `config()` at sign-in.

## Microphone and camera

An app with calls says why it uses them, in Info.plist. iOS shows it the first time a call opens them, and stops the app without it:

| Key | Such as |
|---|---|
| `NSMicrophoneUsageDescription` | Your microphone is heard by the person you call. |
| `NSCameraUsageDescription` | Your camera is shown to the person you call. |

The simulator has no camera: try video calls on a device.

## In the background

- **Rooms:** iOS suspends an app soon after it leaves the screen, and its connection with it. Coming back, the SDK connects again and each room gets what it missed from its history, so nothing your rooms keep is lost.
- **A call going on** when the user leaves the app keeps its sound with the **Audio, AirPlay, and Picture in Picture** background mode (`UIBackgroundModes`: `audio`), which also lets the call screen picture in picture show it. iOS stops the camera of an app in the background unless Apple grants it the multitasking camera access entitlement.
- **Calls ring a closed or suspended app** with `SystemCalls`, through a VoIP push and CallKit (below).

## Push and CallKit

What a call ringing a locked phone and a closed app needs ([calls](calls.md#ringing-a-locked-phone)):

1. **In Xcode, Signing & Capabilities:** add **Push Notifications**, and in **Background Modes** tick **Voice over IP** and **Audio, AirPlay, and Picture in Picture** (`UIBackgroundModes`: `voip`, `audio`).
2. **An APNs key:** in your Apple Developer account, open **Certificates, Identifiers & Profiles**, then **Keys**, add a key with **Apple Push Notifications service (APNs)** ticked, and download its `.p8` file. Apple lets you download it once. One key serves every app of your team.
3. **On the account's Apps page,** open **Phone calls** for the app and give the key's **Key ID**, your **Team ID** and the `.p8` file. WordPlus Cloud keeps the key encrypted and never shows it again, and the page says when Apple refused a push.

- **Development and production:** a build from Xcode gets development push tokens, an App Store or TestFlight build production ones. The SDK reads which from the build and says so with the token, so both ring with the same key.
- **Every VoIP push rings,** as iOS requires of an app that registers for them: WordPlus Cloud sends one only for a call, and the SDK reports each to CallKit before anything else.
- **App Review** asks for a reason to use VoIP pushes and CallKit: the app places and takes calls.

## Privacy

- **The privacy manifests:** `WordPlusRealtime` and `WordPlusRealtimeCalls` each bring their own, which declares UserDefaults (reason `CA92.1`: the connection keeps the realtime servers it reached, the calls a codec a peer failed on) and no tracking. LiveKit, under the calls, brings its own.
- **Your App Store privacy details** describe what your app collects, as for any of its features: the SDK sends WordPlus Cloud the user id, the rooms they join, and the data your app sends, sealed with keys WordPlus Cloud does not hold. The history of a room keeps that sealed data for as long as its rule says.

## Encryption

App Store Connect asks whether the app uses encryption, and the Info.plist `ITSAppUsesNonExemptEncryption` records your answer. What the SDK uses:

- **Rooms:** XChaCha20-Poly1305, through the ChaCha20-Poly1305 of CryptoKit, with HChaCha20 in the code of the SDK itself.
- **Calls:** the WebRTC DTLS-SRTP, and for group calls the LiveKit end-to-end frame encryption.
- **The connection:** TLS, through URLSession.

## Versions

The package carries the room client its calls run on: the WordPlus RTC client for Swift, which is LiveKit's Swift SDK 2.16.0 with WordPlus Mesh's changes, as the Better Messages app runs it. It takes LiveKit's WebRTC build at the exact version that app is tested with. The room client's module is `LiveKit`, so an app can't also add LiveKit's own Swift SDK. An app that draws with LiveKit takes the package's `LiveKit` product instead.
