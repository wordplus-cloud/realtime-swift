import AVKit
import UIKit
import LiveKit
import LiveKitWebRTC

/// The call, still visible once the person has left the app.
///
/// iOS 15's video-call Picture in Picture takes a view controller rather than a
/// sample-buffer layer, so the window is furnished here and drawn by
/// `BmCallsPipRenderer` — which has to be a second render path, because the
/// Metal view the call screen uses stops the moment the app is off screen.
///
/// It enters by itself when the app is backgrounded during a video call, which
/// is the behaviour people expect from every other calling app, and it is only
/// offered when there is something to look at — PiP over a black square is
/// worse than no PiP.
final class BmCallsPip: NSObject {
    static let shared = BmCallsPip()

    /// Whether the device will do this at all. iPhones gained video-call PiP in
    /// iOS 15 but the hardware still decides.
    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    private let content = AVPictureInPictureVideoCallViewController()

    /// The call screen the window animates out of, kept so the controller can
    /// be built the moment there is a picture for it.
    private weak var source: UIView?
    private let renderer = BmCallsPipRenderer()

    private var controller: AVPictureInPictureController?
    private var track: LKRTCVideoTrack?
    private var roomTrack: VideoTrack?

    /// Called when the person taps the PiP window to come back.
    var onRestore: (() -> Void)?

    /// Whether the corner window is up. A backgrounded app is still showing
    /// the call when it is, which is what keeps the size wish honest.
    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    /// Whether backgrounding the app right now would open the window. Read by
    /// the log, so that a call that opened one over nothing says so.
    var opensAutomatically: Bool { controller != nil }

    /// Whether a window has been asked for and not yet given. A controller
    /// cannot answer that question the instant it is made.
    private var wantsWindow = false
    private var possible: NSKeyValueObservation?

    private override init() {
        super.init()

        let stage = renderer.view

        stage.translatesAutoresizingMaskIntoConstraints = false

        // A call is not a 16:9 film, and it is not a portrait phone either — it
        // is whatever the other camera is pointing at. Until a frame says, the
        // window is the shape of the phone it is on.
        content.preferredContentSize = CGSize(width: 9, height: 16)

        content.view.backgroundColor = .black
        content.view.addSubview(stage)

        NSLayoutConstraint.activate([
            stage.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
            stage.topAnchor.constraint(equalTo: content.view.topAnchor),
            stage.bottomAnchor.constraint(equalTo: content.view.bottomAnchor)
        ])

        // The window is cut to the picture, so a landscape camera is not shown
        // down a portrait letterbox with a black band either side of it.
        renderer.onDimensions = { [weak self] size in
            guard let self = self else { return }

            BmCallsLog.write("the corner window is drawing \(Int(size.width))x\(Int(size.height))")

            self.content.preferredContentSize = size
        }

        for name in [ UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appVisibilityChanged(_:)),
                name: name,
                object: nil
            )
        }
    }

    /// Frames are only worth wrapping while the window is the thing showing
    /// them. The system opens it on `willResignActive`, which is why that is
    /// the notification watched rather than the backgrounding one.
    @objc private func appVisibilityChanged(_ note: Notification) {
        renderer.wanted = note.name == UIApplication.willResignActiveNotification && controller != nil

        if note.name == UIApplication.didBecomeActiveNotification {
            wantsWindow = false
            possible?.invalidate()
            possible = nil
        }
    }

    /// Attach to the call screen. The source view is what the window animates
    /// out of and back into, so it has to be the screen the person is looking
    /// at rather than the PiP content itself.
    func attach(to source: UIView) {
        guard Self.isSupported else { return }

        if self.source !== source { release() }

        self.source = source

        refreshController()
    }

    /// Whether there is a picture to put in the window.
    private var hasPicture: Bool { track != nil || roomTrack != nil }

    /// The controller exists only while there is something to put in the
    /// window, because its existence is what the automatic entry actually
    /// turns on.
    ///
    /// `canStartPictureInPictureAutomaticallyFromInline` is the switch for a
    /// player's inline PiP; a video-call source ignores it. A phone with that
    /// flag false still opened the window on an audio call — the log has it
    /// opening 291 ms *before* the background notification, and the delegate
    /// closing it again afterwards. Backgrounding a call the system can put in
    /// a corner is enough, and what it puts there is whatever the content view
    /// controller is drawing, black square included. So an audio call, and a
    /// video call with the other camera off, keep no controller at all and the
    /// system's own call indicator is left where it is.
    private func refreshController() {
        guard Self.isSupported else { return }

        guard hasPicture else {
            release()
            return
        }

        guard controller == nil, let source = source else { return }

        let controller = AVPictureInPictureController(
            contentSource: .init(activeVideoCallSourceView: source, contentViewController: content)
        )

        controller.delegate = self

        // Backgrounding a video call is the ordinary way into PiP; requiring a
        // button press for it would make the feature invisible.
        controller.canStartPictureInPictureAutomaticallyFromInline = true

        self.controller = controller

        // A call that was audio when the app went away, and became a video
        // call while it was gone, has no transition left to ride: the system
        // opens the window on `willResignActive` and that already happened.
        // So ask for it, and let the delegate say whether the system agreed —
        // starting from the background is not documented to work, and the log
        // is how we find out rather than guess.
        // A call that was audio when the app went away, and became a video call
        // while it was gone, has no transition left to ride: the system opens
        // the window on `willResignActive`, and that already happened.
        //
        // **Measured on an iPhone 15 Pro, iOS 26.6.1, 10 Sep.** Asking anyway
        // does nothing when the app is properly in the background:
        // `isPictureInPicturePossible` was *true*, `startPictureInPicture()`
        // was called, and neither `didStart` nor
        // `failedToStartPictureInPicture` ever fired — the system simply
        // ignores it. Apple documents no rule either way, which is why this
        // was tested rather than assumed. Foregrounding the app and leaving it
        // again opens the window normally, because by then the controller
        // exists for the transition to use.
        //
        // The ask is kept for the state in between: `.inactive` is the moment
        // of leaving, and a picture arriving *then* can still take the window.
        guard UIApplication.shared.applicationState != .active else { return }

        renderer.wanted = true
        wantsWindow = true

        BmCallsLog.write("a picture arrived while the app was away, asking for the corner window (possible=\(controller.isPictureInPicturePossible))")

        askForWindow(controller)
    }

    /// Open the window if the controller will have it, and otherwise wait
    /// until it will — a controller can answer `isPictureInPicturePossible`
    /// false until it has had a layout pass.
    private func askForWindow(_ controller: AVPictureInPictureController) {
        possible?.invalidate()
        possible = nil

        guard wantsWindow, !controller.isPictureInPictureActive else { return }

        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
            return
        }

        possible = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] controller, change in
            guard change.newValue == true, self?.wantsWindow == true else { return }

            BmCallsLog.write("the corner window became possible, opening it")

            self?.possible?.invalidate()
            self?.possible = nil

            controller.startPictureInPicture()
        }
    }

    private func release() {
        renderer.wanted = false
        wantsWindow = false

        possible?.invalidate()
        possible = nil

        guard let controller = controller else { return }

        if controller.isPictureInPictureActive { controller.stopPictureInPicture() }

        controller.delegate = nil

        self.controller = nil
    }

    /// The peer's camera, in a direct call.
    func show(_ track: LKRTCVideoTrack?) {
        guard track !== self.track else { return }

        if let previous = self.track { previous.remove(renderer) }

        self.track = track
        track?.add(renderer)

        if track != nil { detachRoomTrack() }

        refreshController()
    }

    /// The room's video, when the call runs through one.
    func showRoom(_ track: VideoTrack?) {
        guard track !== roomTrack else { return }

        detachRoomTrack()

        roomTrack = track
        track?.add(videoRenderer: renderer)

        if track != nil, let previous = self.track {
            previous.remove(renderer)
            self.track = nil
        }

        refreshController()
    }

    private func detachRoomTrack() {
        guard let previous = roomTrack else { return }

        previous.remove(videoRenderer: renderer)

        roomTrack = nil
    }

    func start() {
        guard let controller = controller, controller.isPictureInPictureActive == false else { return }

        // Nothing to show is not worth a window.
        guard hasPicture else { return }

        controller.startPictureInPicture()
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    /// The call ended: drop the track and the controller so a later call
    /// attaches to its own screen rather than a dead one.
    func detach() {
        if let previous = track { previous.remove(renderer) }

        track = nil

        detachRoomTrack()

        source = nil

        release()
    }
}

extension BmCallsPip: AVPictureInPictureControllerDelegate {
    /// The picture can stop between the app being backgrounded and the window
    /// opening — the other side turning their camera off is one moment of it —
    /// and by then the flag has been read. An empty window is closed again
    /// rather than left sitting over the call indicator.
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        BmCallsLog.write("the corner window opened")

        // Whatever the app state says, the window is up: it is being drawn for
        // now, and until it stops.
        renderer.wanted = true
        wantsWindow = false

        guard !hasPicture else { return }

        BmCallsLog.write("the corner window opened with nothing in it, closing it")

        // Not from inside the start it is answering: the transition has to
        // finish before the stop is heard.
        DispatchQueue.main.async { controller.stopPictureInPicture() }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        renderer.wanted = false
        wantsWindow = false
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        BmCallsLog.write("the corner window would not open: \(error.localizedDescription)")

        renderer.wanted = UIApplication.shared.applicationState != .active && self.controller != nil
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void
    ) {
        onRestore?()
        completion(true)
    }
}
