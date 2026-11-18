import Foundation
import LiveKit
import LiveKitWebRTC

/**
 Sharing this phone's screen, on a call, a group call or a live stream.

 iOS captures a whole screen only from a broadcast extension, in a process of its own, so an app has to be built with one
 before it can share (the shipping guide says how): a Broadcast Upload Extension whose bundle id is the app's with
 `.broadcast` after it, whose handler is `class SampleHandler: LKSampleHandler {}` from the `LiveKit` product, and the App
 Groups capability on both, `group.` and the app's bundle id. `RTCAppGroupIdentifier` and `RTCScreenSharingExtension` in the
 app's `Info.plist` name others. Without it `isAvailable` is false, `setScreenShare(true)` answers false and the call screen
 shows no button.

 `setScreenShare(true)` puts up the system's own picker and nothing goes out until the person chooses this app in it, so its
 answer says it was asked, and `onScreenShare` says when the share begins and when it stops, the system's own red bar included.
 */
public enum ScreenShare {
    /// Whether this app was built to share its screen: the app group of its broadcast extension is there.
    public static var isAvailable: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        availableAsked ?? CallBroadcast.isAvailable
        #else
        availableAsked ?? false
        #endif
    }

    /// What `isAvailable` answers in the tests, whose host has no extension.
    static var availableAsked: Bool?
}

#if os(iOS)
/// The screen for a call between two. ReplayKit's frames arrive from the extension over a socket in the app group, and only
/// the room client's own capturer reads that socket, so its track is made and watched: every frame it hands over carries the
/// pixel buffer the call's encoder wants. A room's share is the room client's end to end and never comes through here.
final class CallBroadcast: NSObject {
    /// Whether the app was built with the extension: the container exists only when the entitlement was granted, so this
    /// answers whether this build was signed with the group, not just whether a name was written down.
    static var isAvailable: Bool {
        guard let group = appGroup else { return false }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil
    }

    /// `group.<bundle>`, unless the build says otherwise: the same keys the room client reads.
    private static var appGroup: String? {
        if let named = Bundle.main.infoDictionary?["RTCAppGroupIdentifier"] as? String { return named }
        return Bundle.main.bundleIdentifier.map { "group." + $0 }
    }

    /// The height the frames arrive at, for the encoder's shape: a screen rotated while shared changes it.
    private(set) var captureHeight = 0

    /// Told once the first frame has arrived: until then there is nothing to send, and saying there is makes the other side
    /// wait on a black rectangle.
    var onStarted: (() -> Void)?
    /// The person stopped it from the system's own bar, which tells the app nothing else.
    var onStopped: (() -> Void)?

    /// The track the call sends, from `start`.
    private(set) var screenTrack: LKRTCVideoTrack?

    private var track: LocalVideoTrack?
    private var source: LKRTCVideoSource?
    private var capturer: LKRTCVideoCapturer?
    /// Whether the first frame has been told. A share has begun or it hasn't: `set(size:)` may record a size before any frame.
    private var announced = false

    /// The system's picker: nothing happens here until the person chooses this app in it.
    func request() {
        BroadcastManager.shared.requestActivation()
    }

    /// The call's own track, which the frames go to.
    func prepare(with factory: LKRTCPeerConnectionFactory) {
        announced = false
        // A screen source, not a camera one: libwebrtc scales the two differently, and keeps more detail in a screen.
        let videoSource = factory.videoSource(forScreenCast: true)
        source = videoSource
        capturer = LKRTCVideoCapturer(delegate: videoSource)
        screenTrack = factory.videoTrack(with: videoSource, trackId: "call-screen")
    }

    /// Makes the room client's screen track, watches it, and hands every frame to a source of the call's own.
    func start(with factory: LKRTCPeerConnectionFactory) async -> Bool {
        guard track == nil else { return true }
        BroadcastManager.shared.delegate = self
        prepare(with: factory)

        // The screen's own pixels: a phone's screen is not 16:9, and scaling it to a preset makes shared text unreadable.
        let made = await LocalVideoTrack.createBroadcastScreenCapturerTrack(
            options: ScreenShareCaptureOptions(dimensions: .h1080_169, fps: 30, appAudio: true, useBroadcastExtension: true)
        )
        // Stopped while the track was being made.
        guard screenTrack != nil else { return false }
        track = made
        made.add(videoRenderer: self)
        do {
            try await made.start()
        } catch {
            stop()
            return false
        }
        return true
    }

    func stop() {
        if BroadcastManager.shared.delegate === self { BroadcastManager.shared.delegate = nil }
        announced = false
        if let track {
            track.remove(videoRenderer: self)
            Task { try? await track.stop() }
        }
        track = nil
        source = nil
        capturer = nil
        screenTrack = nil
        captureHeight = 0
        BroadcastManager.shared.requestStop()
    }

    /// A frame of the screen, to the call's source.
    func frame(_ pixels: CVPixelBuffer, timeStampNs: Int64) {
        guard let capturer, let source else { return }
        let height = CVPixelBufferGetHeight(pixels)
        captureHeight = height
        if !announced, height > 0 {
            announced = true
            onStarted?()
        }
        source.capturer(capturer, didCapture: LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: timeStampNs))
    }
}

extension CallBroadcast: VideoRenderer {
    var isAdaptiveStreamEnabled: Bool { false }
    /// Zero says not to adapt for this: the size the other side shows it at decides.
    var adaptiveStreamSize: CGSize { .zero }

    func set(size: CGSize) {
        captureHeight = Int(size.height)
    }

    func render(frame: VideoFrame) {
        guard let buffer = frame.buffer as? CVPixelVideoBuffer else { return }
        self.frame(buffer.pixelBuffer, timeStampNs: frame.timeStampNs)
    }
}

extension CallBroadcast: BroadcastManagerDelegate {
    func broadcastManager(didChangeState isBroadcasting: Bool) {
        guard !isBroadcasting else { return }
        DispatchQueue.main.async { [weak self] in self?.onStopped?() }
    }
}
#endif
