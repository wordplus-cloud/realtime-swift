import AVKit
import UIKit
import LiveKit
import LiveKitWebRTC

/// The call, still visible once the person has left the app.
///
/// iOS 15's video-call Picture in Picture takes a view controller rather than a
/// sample-buffer layer, so the window is furnished here and drawn by
/// `CallsPipRenderer` — which has to be a second render path, because the
/// Metal view the call screen uses stops the moment the app is off screen.
///
/// It enters by itself when the app is backgrounded during a video call, which
/// is the behaviour people expect from every other calling app, and it is only
/// offered when there is something to look at — PiP over a black square is
/// worse than no PiP. A group call's window shows one person of it
/// (`CallsPipFocus`), by name, and by face while they send no picture.
final class CallsPip: NSObject {
    static let shared = CallsPip()

    /// Whom a group call's window shows.
    struct Who: Equatable {
        let name: String
        let avatar: String
    }

    /// Whom it shows now, nil outside a group call.
    private(set) var who: Who?
    private let nameLabel = UILabel()
    private let face = UIImageView()
    private let faceLetters = UILabel()
    private var faceFor = ""

    /// Whether the device will do this at all. iPhones gained video-call PiP in
    /// iOS 15 but the hardware still decides.
    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    private let content = AVPictureInPictureVideoCallViewController()

    /// The call screen the window animates out of, kept so the controller can
    /// be built the moment there is a picture for it.
    private weak var source: UIView?
    private let renderer = CallsPipRenderer()

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

        layOutWho()

        // The window is cut to the picture, so a landscape camera is not shown
        // down a portrait letterbox with a black band either side of it.
        renderer.onDimensions = { [weak self] size in
            guard let self = self else { return }

            CallsLog.write("the corner window is drawing \(Int(size.width))x\(Int(size.height))")

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

    /// Whether there is a picture to put in the window: someone's face is one.
    private var hasPicture: Bool { track != nil || roomTrack != nil || who != nil }

    /// Whether a window can be had now.
    var hasContent: Bool { hasPicture }

    /// The name and the face over the picture, for a group call's window.
    private func layOutWho() {
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.shadowColor = UIColor(white: 0, alpha: 0.7)
        nameLabel.shadowOffset = CGSize(width: 0, height: 1)
        nameLabel.isHidden = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        face.contentMode = .scaleAspectFill
        face.clipsToBounds = true
        face.layer.cornerRadius = 28
        face.backgroundColor = UIColor(white: 1, alpha: 0.14)
        face.isHidden = true
        face.translatesAutoresizingMaskIntoConstraints = false

        faceLetters.font = .systemFont(ofSize: 20, weight: .semibold)
        faceLetters.textColor = .white
        faceLetters.textAlignment = .center
        faceLetters.translatesAutoresizingMaskIntoConstraints = false

        face.addSubview(faceLetters)
        content.view.addSubview(face)
        content.view.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            face.widthAnchor.constraint(equalToConstant: 56),
            face.heightAnchor.constraint(equalToConstant: 56),
            face.centerXAnchor.constraint(equalTo: content.view.centerXAnchor),
            face.centerYAnchor.constraint(equalTo: content.view.centerYAnchor),
            faceLetters.centerXAnchor.constraint(equalTo: face.centerXAnchor),
            faceLetters.centerYAnchor.constraint(equalTo: face.centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: content.view.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.view.trailingAnchor, constant: -8),
            nameLabel.bottomAnchor.constraint(equalTo: content.view.bottomAnchor, constant: -6)
        ])
    }

    private func drawWho() {
        let bare = who != nil && roomTrack == nil

        renderer.view.isHidden = bare
        face.isHidden = !bare
        nameLabel.isHidden = who == nil
        nameLabel.text = who?.name

        guard let who, faceFor != who.avatar + "\n" + who.name else { return }

        faceFor = who.avatar + "\n" + who.name
        face.image = nil
        faceLetters.text = CallsAvatars.initials(of: who.name)
        faceLetters.isHidden = false

        let wanted = faceFor

        CallsAvatars.load(who.avatar) { [weak self] image in
            DispatchQueue.main.async {
                guard let self, self.faceFor == wanted, let image else { return }

                self.face.image = image
                self.faceLetters.isHidden = true
            }
        }
    }

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

        CallsLog.write("a picture arrived while the app was away, asking for the corner window (possible=\(controller.isPictureInPicturePossible))")

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

            CallsLog.write("the corner window became possible, opening it")

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

    /// The room's video, when the call runs through one, and `who` it is of in a group call.
    func showRoom(_ track: VideoTrack?, who: Who? = nil) {
        guard track !== roomTrack || who != self.who else { return }

        self.who = who

        if track !== roomTrack {
            detachRoomTrack()

            roomTrack = track
            track?.add(videoRenderer: renderer)

            if track != nil, let previous = self.track {
                previous.remove(renderer)
                self.track = nil
            }
        }

        drawWho()
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

        who = nil
        drawWho()

        source = nil

        release()
    }
}

/// Whom a group call's window shows, as the web's pipFocus: someone in the spotlight or pinned (`first`), else a screen
/// someone else shares, else whoever speaks loudest, else who spoke last while they are still there, else the first with
/// a picture, the first other, the user. Their face stands in where they send no picture.
enum CallsPipFocus {
    struct Person: Equatable {
        let identity: String
        let isLocal: Bool
        let screen: Bool
        let camera: Bool
        let speaking: Bool
        let level: Float

        init(identity: String, isLocal: Bool = false, screen: Bool = false, camera: Bool = false, speaking: Bool = false, level: Float = 0) {
            self.identity = identity
            self.isLocal = isLocal
            self.screen = screen
            self.camera = camera
            self.speaking = speaking
            self.level = level
        }

        init(_ person: CallsRoomParticipant) {
            self.init(
                identity: person.identity, isLocal: person.isLocal, screen: person.screen != nil,
                camera: person.video != nil, speaking: person.speaking, level: person.audioLevel
            )
        }
    }

    /// A video call has a window all through, an audio call only while someone else shares a screen, which is all it
    /// would show. A call of nobody has none.
    static func offered(_ people: [Person], video: Bool) -> Bool {
        !people.isEmpty && (video || people.contains { !$0.isLocal && $0.screen })
    }

    static func pick(_ people: [Person], first: [String], last: String?) -> String? {
        func loudest(_ among: [Person]) -> Person? {
            among.filter(\.speaking).max { $0.level < $1.level }
        }

        let others = people.filter { !$0.isLocal }
        var seen = Set<String>()
        let ahead = first.compactMap { key in seen.insert(key).inserted ? people.first { $0.identity == key } : nil }

        if !ahead.isEmpty {
            return (loudest(ahead) ?? ahead.first { $0.identity == last } ?? ahead[0]).identity
        }

        return (others.first(where: \.screen)
            ?? loudest(others)
            ?? others.first { $0.identity == last }
            ?? others.first { $0.camera }
            ?? others.first
            ?? people.first)?.identity
    }
}

extension CallsPip: AVPictureInPictureControllerDelegate {
    /// The picture can stop between the app being backgrounded and the window
    /// opening — the other side turning their camera off is one moment of it —
    /// and by then the flag has been read. An empty window is closed again
    /// rather than left sitting over the call indicator.
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        CallsLog.write("the corner window opened")

        // Whatever the app state says, the window is up: it is being drawn for
        // now, and until it stops.
        renderer.wanted = true
        wantsWindow = false

        guard !hasPicture else { return }

        CallsLog.write("the corner window opened with nothing in it, closing it")

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
        CallsLog.write("the corner window would not open: \(error.localizedDescription)")

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
