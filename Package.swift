// swift-tools-version:5.9
// WordPlus Cloud's realtime SDK for iOS and macOS apps: rooms, events with acks,
// presence, live counts, history, who is online and what the app's server sends the user, on the same realtime servers
// and protocol as the browser's, sealed end to end. Calls are their own product, WordPlusRealtimeCalls, so an app that
// only uses rooms carries no WebRTC; Better Messages' call screens are another, WordPlusRealtimeUI (iOS), so an app that
// draws its own carries none of them.
import PackageDescription

let package = Package(
    name: "WordPlusRealtime",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "WordPlusRealtime", targets: ["WordPlusRealtime"]),
        .library(name: "WordPlusRealtimeCalls", targets: ["WordPlusRealtimeCalls"]),
        .library(name: "WordPlusRealtimeUI", targets: ["WordPlusRealtimeUI"]),
        // `swift package wordplus-ui add`: the call screen's code copied into the app, to change as far as it needs.
        .plugin(name: "WordPlusUI", targets: ["WordPlusUI"]),
        // The same from a command line for an Xcode project, whose command plugins only Xcode runs:
        // `swift run --package-path <this package> wordplus-ui add --project <folder> --target <App>`.
        .executable(name: "wordplus-ui", targets: ["WordPlusUITool"]),
        // The room client the calls run on, for an app that copied the call screen (`wordplus-ui add`), which draws
        // with it.
        .library(name: "LiveKit", targets: ["LiveKit"]),
    ],
    dependencies: [
        // Calls: the same libwebrtc under the rooms and the direct connection, at the version Better Messages' app
        // pins, whose call engine this is; and what the room client needs beside it, as its build lists them
        // (scripts/rtc-client.sh prints them).
        .package(url: "https://github.com/livekit/webrtc-xcframework.git", exact: "150.7871.03"),
        .package(url: "https://github.com/livekit/livekit-uniffi-xcframework.git", exact: "0.1.9"),
    ],
    targets: [
        // Each privacy manifest declares UserDefaults, where the connection keeps the realtime nodes it reached and the
        // calls a codec a peer failed on; neither tracks, and the data an app sends is the app's to declare.
        .target(name: "WordPlusRealtime", resources: [.process("PrivacyInfo.xcprivacy")]),
        .target(
            name: "WordPlusRealtimeCalls",
            dependencies: [
                "WordPlusRealtime",
                "LiveKit",
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework"),
            ],
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "WordPlusRealtimeUI",
            dependencies: [
                "WordPlusRealtimeCalls",
                "LiveKit",
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework"),
            ]
        ),
        // The rooms of group calls, calls moved to one, and live streams: the WordPlus RTC client for Swift, LiveKit's
        // Swift SDK 2.18.0 with WordPlus Mesh's patch (Vendor/rtc-client-swift, Apache License 2.0, its LICENSE and
        // NOTICE there), the client Better Messages' app runs. Its module is LiveKit's own, so an app can't also take
        // stock LiveKit. Its protocol layer is nanopb (CLiveKitProto, LiveKitNanopb) since upstream 2.17, as its build
        // lists the targets. scripts/rtc-client.sh copies a new build in.
        .target(
            name: "CLiveKitProto",
            path: "Vendor/rtc-client-swift/Sources/CLiveKitProto",
            exclude: ["LICENSE-nanopb.txt", "module.modulemap"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("include")]
        ),
        .target(name: "LiveKitNanopb", dependencies: ["CLiveKitProto"], path: "Vendor/rtc-client-swift/Sources/LiveKitNanopb"),
        .target(name: "LKObjCHelpers", path: "Vendor/rtc-client-swift/Sources/LKObjCHelpers", publicHeadersPath: "include"),
        .target(
            name: "LiveKit",
            dependencies: [
                "LKObjCHelpers",
                "LiveKitNanopb",
                "CLiveKitProto",
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework"),
                .product(name: "LiveKitUniFFI", package: "livekit-uniffi-xcframework"),
            ],
            path: "Vendor/rtc-client-swift/Sources/LiveKit",
            exclude: ["Broadcast/NOTICE"],
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        .plugin(
            name: "WordPlusUI",
            capability: .command(
                intent: .custom(verb: "wordplus-ui", description: "Copies the call screen's code into the app (add), and shows or takes what changed in ours since (diff, update, accept)."),
                permissions: [.writeToPackageDirectory(reason: "It copies the call screen's files into your target, and records them in wordplus-ui.json and .wordplus-ui/.")]
            )
        ),
        // The plugin's copies from a command line: its Copies.swift and Embedded.swift, linked into Sources/WordPlusUITool.
        .executableTarget(name: "WordPlusUITool"),
        .testTarget(name: "WordPlusRealtimeTests", dependencies: ["WordPlusRealtime"], resources: [.copy("vectors.json")]),
        // The calls' own logic with no call: a live stream's state from its chat socket's events.
        // LiveKit too: the room client's own types, as the calls are handed them (CameraSwitchTests).
        .testTarget(name: "WordPlusRealtimeCallsTests", dependencies: ["WordPlusRealtimeCalls", "LiveKit"]),
        // The call screens on a simulator, with no call (xcodebuild test, an iOS destination): their pieces.
        .testTarget(name: "WordPlusRealtimeUITests", dependencies: ["WordPlusRealtimeUI"]),
        // The live stream drawn ready, on a simulator, with a stream whose events the test gives.
        .testTarget(name: "WordPlusRealtimeStreamScreenTests", dependencies: ["WordPlusRealtimeUI", "WordPlusRealtimeCalls"]),
    ]
)
