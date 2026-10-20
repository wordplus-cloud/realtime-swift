import Foundation
import AVFoundation
import LiveKitWebRTC

/// The camera and the microphone, and the one factory everything is built from.
///
/// The factory is shared for the app's life: it owns the encoders, the decoders
/// and the audio device, and a second one would mean a second audio device
/// fighting the first over the same session. The encoder factory is the
/// subclass that advertises H265, so HEVC can actually be offered.
final class CallMedia {
    static let shared = CallMedia()

    /// libwebrtc's own warnings, kept for the app's life like the factory
    /// they are started with. A stall that happens inside the stack — an
    /// encoder returning errors, frames thrown away for their timestamps, an
    /// allocation that pauses a stream — is visible nowhere else.
    private let webrtcLogger = LKRTCCallbackLogger()

    private(set) lazy var factory: LKRTCPeerConnectionFactory = {
        // Every build: libwebrtc calls this back for every warning it writes,
        // and the call's trace on the server is where they go. `CallLog`
        // caps and collapses them, so a stack that has gone wrong costs the
        // phone a few lines a minute rather than one per frame.
        self.webrtcLogger.severity = .warning
        self.webrtcLogger.start { message in CallLog.webrtc(message) }

        return LKRTCPeerConnectionFactory(
            encoderFactory: CallVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory()
        )
    }()

    private var videoSource: LKRTCVideoSource?
    private var capturer: LKRTCCameraVideoCapturer?
    private var audioSource: LKRTCAudioSource?

    private(set) var cameraTrack: LKRTCVideoTrack?
    private(set) var microphoneTrack: LKRTCAudioTrack?

    private(set) var usingFrontCamera = true
    private(set) var captureHeight = 1080

    /// Whether frames are actually coming out of the camera. The track outlives
    /// a stop — it is the same object the peer connection and the preview hold
    /// — so its existence says nothing about whether the capture behind it is
    /// running, and a start that trusted the track alone would hand back a
    /// camera that has been switched off.
    private var capturing = false

    /// How many times the camera has been stopped, so a start can tell that a
    /// stop overtook it. The capturer works through one queue, so a stop asked
    /// for while a start is still opening the device runs after it and the
    /// camera ends up off — but the start's completion reaches the main queue
    /// after the stop did and used to set `capturing` regardless. The next
    /// start then took the stopped capture for a running one and handed it
    /// back as it was: a quick off and on, or a hang-up during the preview an
    /// answer starts, and the next camera was a black picture.
    private var stops = 0

    /// Whether the camera is running right now. The one caller needs to tell a
    /// camera somebody switched off apart from one iOS took away.
    var isCapturing: Bool { capturing }

    private init() {}

    /// The device this app runs on can encode 1080p in hardware, and the
    /// picture is scaled down per source afterwards from the wish the other
    /// side sends. Capturing small would put a ceiling on that.
    private static let captureWidth = 1920
    private static let captureFramerate = 30

    var codecCaps: CallCodecCaps {
        CallCodecs.probe(
            factory: factory,
            encoders: CallVideoEncoderFactory().supportedCodecs(),
            decoders: LKRTCDefaultVideoDecoderFactory().supportedCodecs(),
            forced: nil
        )
    }

    func startMicrophone() -> LKRTCAudioTrack {
        if let track = microphoneTrack { return track }

        // Echo cancellation, noise suppression and gain are the audio
        // processing module's own, asked for here rather than left to default.
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: [
                "googEchoCancellation": "true",
                "googAutoGainControl": "true",
                "googNoiseSuppression": "true",
                "googHighpassFilter": "true"
            ],
            optionalConstraints: nil
        )

        let source = factory.audioSource(with: constraints)
        let track = factory.audioTrack(with: source, trackId: "bm-audio")

        audioSource = source
        microphoneTrack = track

        return track
    }

    /// Whether the microphone is heard.
    ///
    /// This is what mute is. Taking the track off the sender is not: measured
    /// on Android across a mute, the same arrangement went on sending Opus at
    /// thirty-five kilobits a second and the other side went on hearing the
    /// room — while the control read muted, the other side was told so, and
    /// drew the crossed-out microphone over the picture. This side was written
    /// the same way.
    ///
    /// A disabled track is silence at the source, before any of it reaches a
    /// sender — whichever section ends up carrying it, and however many times
    /// the peer is rebuilt underneath. It is also what a browser does for the
    /// same control, so every end of a call behaves the same way.
    func setMicrophoneEnabled(_ enabled: Bool) {
        microphoneTrack?.isEnabled = enabled
    }

    /// The microphone opened again, on the other side's word that it sends
    /// nothing: a fresh source and a fresh track, for the sender to take in
    /// place of the ones that went quiet. The old ones are let go of, so the
    /// audio device is asked for a capture it can start over rather than one
    /// it believes is already running.
    func restartMicrophone() -> LKRTCAudioTrack {
        let wasEnabled = microphoneTrack?.isEnabled ?? true

        microphoneTrack = nil
        audioSource = nil

        let track = startMicrophone()

        track.isEnabled = wasEnabled

        return track
    }

    func startCamera(front: Bool = true, done: @escaping (LKRTCVideoTrack?) -> Void) {
        if let track = cameraTrack, capturing, front == usingFrontCamera {
            done(track)
            return
        }

        let source = videoSource ?? factory.videoSource()
        let capturer = self.capturer ?? LKRTCCameraVideoCapturer(delegate: source)

        videoSource = source
        self.capturer = capturer

        let track = cameraTrack ?? factory.videoTrack(with: source, trackId: "bm-video")
        cameraTrack = track

        guard let device = CallMedia.device(front: front),
              let format = CallMedia.format(for: device),
              let fps = CallMedia.framerate(for: format) else {
            done(nil)
            return
        }

        usingFrontCamera = front

        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        captureHeight = Int(min(dimensions.width, dimensions.height))

        let asked = stops

        capturer.startCapture(with: device, format: format, fps: fps) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                // Stopped since it was asked for: the camera is off whatever
                // this start says, and whoever stopped it decided what comes
                // next. Neither marked running nor handed out.
                guard self.stops == asked else {
                    CallLog.write("camera start overtaken by a stop, left off")
                    return
                }

                self.capturing = error == nil

                done(error == nil ? track : nil)
            }
        }
    }

    func flipCamera(done: @escaping (LKRTCVideoTrack?) -> Void) {
        capturer?.stopCapture { [weak self] in
            // `stopCapture` answers on the capture queue, and everything the
            // start touches — the source, the capturer, the flag — belongs to
            // the main one.
            DispatchQueue.main.async {
                guard let self = self else { return }

                self.capturing = false

                self.startCamera(front: !self.usingFrontCamera, done: done)
            }
        }
    }

    func stopCamera() {
        stops += 1
        capturing = false

        capturer?.stopCapture()
    }

    func stopAll() {
        stops += 1
        capturing = false

        capturer?.stopCapture()
        capturer = nil
        videoSource = nil
        cameraTrack = nil
        audioSource = nil
        microphoneTrack = nil
    }

    private static func device(front: Bool) -> AVCaptureDevice? {
        let position: AVCaptureDevice.Position = front ? .front : .back

        return LKRTCCameraVideoCapturer.captureDevices().first { $0.position == position }
            ?? LKRTCCameraVideoCapturer.captureDevices().first
    }

    /// The format closest to 1080p that the camera actually offers, preferring
    /// the pixel format libwebrtc likes best.
    private static func format(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = LKRTCCameraVideoCapturer.supportedFormats(for: device)

        var best: AVCaptureDevice.Format?
        var bestDistance = Int.max

        for format in formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let distance = abs(Int(dimensions.width) - captureWidth)

            let pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let preferred = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

            if distance < bestDistance || (distance == bestDistance && preferred) {
                best = format
                bestDistance = distance
            }
        }

        return best
    }

    private static func framerate(for format: AVCaptureDevice.Format) -> Int? {
        let highest = format.videoSupportedFrameRateRanges.map { Int($0.maxFrameRate) }.max()

        guard let highest = highest else { return nil }

        return min(highest, captureFramerate)
    }
}
