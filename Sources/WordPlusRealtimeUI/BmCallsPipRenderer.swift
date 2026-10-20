import AVFoundation
import CoreMedia
import LiveKit
import LiveKitWebRTC
import UIKit

/// What the corner window draws with.
///
/// The call screen draws through Metal, and `LKRTCMTLVideoView` renders from
/// `drawInMTKView:` — an `MTKView` display-link callback. A display link does
/// not fire while the app is off screen, and an app may not submit GPU work
/// from there either, so left to it the corner window holds the last frame
/// drawn before the app went away: a photograph of a call rather than a call.
///
/// A sample-buffer layer is composited by the system instead. Frames are
/// wrapped as they arrive and handed over, and the picture goes on moving while
/// everything that would have drawn it is asleep.
///
/// It takes frames from both paths — the direct connection's `LKRTCVideoTrack`
/// and a room's `VideoTrack` — because a call that fell back to LiveKit is
/// still a call someone puts in a corner.
final class BmCallsPipRenderer: NSObject {
    let view = BmCallsPipVideoView()

    /// The shape of the picture as it is drawn, rotation applied, so the window
    /// can be cut to it rather than to a guess.
    var onDimensions: ((CGSize) -> Void)?

    /// Whether frames are worth wrapping. The window is the only thing this
    /// draws for, so while the app is in front there is nothing to do — and a
    /// layer that is enqueued into while it is off screen only banks frames
    /// nobody will see.
    ///
    /// Set from the main thread and read from the decoder's, so it is held
    /// under the same lock as everything else here.
    var wanted: Bool {
        get {
            lock.lock()

            defer { lock.unlock() }

            return isWanted
        }
        set {
            lock.lock()

            let changed = isWanted != newValue

            isWanted = newValue

            lock.unlock()

            guard changed else { return }

            report(started: newValue)

            guard !newValue else { return }

            DispatchQueue.main.async { [weak self] in self?.view.clear() }
        }
    }

    private var isWanted = false
    private var format: CMVideoFormatDescription?
    private var shown: CGSize = .zero
    private let lock = NSLock()

    private var frames = 0
    private var framesAtReport = 0
    private var drawingSince: CFTimeInterval = 0
    private var reportedAt: CFTimeInterval = 0

    /// How the phone says whether the window is playing or holding a still.
    /// There is no way to look at a device's screen from here, and the corner
    /// window is a system one at that, so the count of frames that reached the
    /// layer is the evidence there is.
    private func report(started: Bool) {
        lock.lock()

        let drawn = frames
        let since = drawingSince
        let now = CACurrentMediaTime()

        frames = 0
        framesAtReport = 0
        drawingSince = started ? now : 0
        reportedAt = now

        lock.unlock()

        guard !started else {
            BmCallsLog.write("the corner window started drawing")
            return
        }

        let seconds = since > 0 ? now - since : 0

        BmCallsLog.write("the corner window stopped after \(drawn) frames in \(String(format: "%.1f", seconds))s")
    }

    // MARK: - Frames

    private func draw(_ pixels: CVPixelBuffer, rotation: Int) {
        guard wanted else { return }

        lock.lock()

        if let existing = format, !CMVideoFormatDescriptionMatchesImageBuffer(existing, imageBuffer: pixels) {
            format = nil
        }

        if format == nil {
            var built: CMVideoFormatDescription?

            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixels,
                formatDescriptionOut: &built
            )

            format = built
        }

        let description = format

        lock.unlock()

        guard let description = description else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sample: CMSampleBuffer?

        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixels,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample = sample else { return }

        // Every frame is the newest there is: a call is not a film being played
        // to a schedule, so each one is shown as it lands rather than held for
        // a presentation time.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)

            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let sideways = rotation == 90 || rotation == 270
        let size = CGSize(width: sideways ? height : width, height: sideways ? width : height)

        lock.lock()

        frames += 1

        let elapsed = CACurrentMediaTime() - reportedAt
        let due = elapsed >= 15
        let drawn = frames - framesAtReport

        if due {
            reportedAt = CACurrentMediaTime()
            framesAtReport = frames
        }

        lock.unlock()

        if due {
            // The count is the window's own, not a running total: a rate is the
            // thing being asked for, and a total that keeps climbing looks like
            // one until the interval slips.
            BmCallsLog.write("the corner window drew \(drawn) frames in the last \(String(format: "%.0f", elapsed))s")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.view.rotation = rotation
            self.view.show(sample)

            guard size != .zero, size != self.shown else { return }

            self.shown = size

            self.onDimensions?(size)
        }
    }

    /// A frame the decoder handed over in its own memory rather than a pixel
    /// buffer — software-decoded VP8, VP9 and AV1 arrive this way. It is packed
    /// into the two-plane form the display layer takes.
    private func pixels(from buffer: any LKRTCI420BufferProtocol) -> CVPixelBuffer? {
        let width = Int(buffer.width)
        let height = Int(buffer.height)

        guard width > 0, height > 0 else { return nil }

        var created: CVPixelBuffer?

        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes as CFDictionary,
            &created
        ) == kCVReturnSuccess, let pixels = created else { return nil }

        CVPixelBufferLockBaseAddress(pixels, [])

        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }

        if let plane = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
            let source = Int(buffer.strideY)
            let run = min(stride, source)

            for row in 0 ..< height {
                memcpy(plane.advanced(by: row * stride), buffer.dataY.advanced(by: row * source), run)
            }
        }

        if let plane = CVPixelBufferGetBaseAddressOfPlane(pixels, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
            let columns = Int(buffer.chromaWidth)
            let rows = Int(buffer.chromaHeight)
            let strideU = Int(buffer.strideU)
            let strideV = Int(buffer.strideV)
            let bytes = plane.assumingMemoryBound(to: UInt8.self)

            for row in 0 ..< rows {
                let line = bytes.advanced(by: row * stride)
                let u = buffer.dataU.advanced(by: row * strideU)
                let v = buffer.dataV.advanced(by: row * strideV)

                for column in 0 ..< columns {
                    line[column * 2] = u[column]
                    line[column * 2 + 1] = v[column]
                }
            }
        }

        return pixels
    }
}

// MARK: - The direct connection

extension BmCallsPipRenderer: LKRTCVideoRenderer {
    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard wanted, let frame = frame else { return }

        let rotation: Int

        switch frame.rotation {
        case ._90: rotation = 90
        case ._180: rotation = 180
        case ._270: rotation = 270
        default: rotation = 0
        }

        if let buffer = frame.buffer as? LKRTCCVPixelBuffer {
            draw(buffer.pixelBuffer, rotation: rotation)
            return
        }

        // `toI420` on a buffer that is already I420 hands back the same one,
        // so this costs nothing where there is nothing to convert.
        guard let pixels = pixels(from: frame.buffer.toI420()) else { return }

        draw(pixels, rotation: rotation)
    }
}

// MARK: - A call that runs through a room

extension BmCallsPipRenderer: VideoRenderer {
    var isAdaptiveStreamEnabled: Bool { false }

    var adaptiveStreamSize: CGSize { .zero }

    func set(size: CGSize) {}

    func render(frame: VideoFrame) {
        guard wanted else { return }

        let rotation: Int

        switch frame.rotation {
        case ._90: rotation = 90
        case ._180: rotation = 180
        case ._270: rotation = 270
        default: rotation = 0
        }

        if let buffer = frame.buffer as? CVPixelVideoBuffer {
            draw(buffer.pixelBuffer, rotation: rotation)
            return
        }

        guard let buffer = frame.buffer as? I420VideoBuffer, let pixels = buffer.toPixelBuffer() else { return }

        draw(pixels, rotation: rotation)
    }
}

/// The view the corner window is made of: one sample-buffer layer, turned to
/// stand the picture up when the frames arrive on their side.
final class BmCallsPipVideoView: UIView {
    private let display = AVSampleBufferDisplayLayer()

    var rotation: Int = 0 {
        didSet {
            guard rotation != oldValue else { return }

            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .black

        display.videoGravity = .resizeAspect

        layer.addSublayer(display)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ sample: CMSampleBuffer) {
        if #available(iOS 17.0, *) {
            if display.sampleBufferRenderer.status == .failed { display.sampleBufferRenderer.flush() }

            display.sampleBufferRenderer.enqueue(sample)

            return
        }

        if display.status == .failed { display.flush() }

        display.enqueue(sample)
    }

    func clear() {
        display.flushAndRemoveImage()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // A layer is rotated about its own centre, so it is given the box it
        // will occupy once turned rather than the one it is turned from —
        // otherwise a sideways picture is drawn to the window's width and then
        // swung out of it.
        let sideways = rotation == 90 || rotation == 270
        let size = sideways
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        display.bounds = CGRect(origin: .zero, size: size)
        display.position = CGPoint(x: bounds.midX, y: bounds.midY)
        display.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180))

        CATransaction.commit()
    }
}
