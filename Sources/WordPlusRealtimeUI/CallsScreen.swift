import UIKit
import LiveKit
import LiveKitWebRTC

/// The call, as the person sees it.
///
/// One screen for all of it — ringing out, ringing in, connecting, in progress
/// and reconnecting — because they are the same call and a phone that swaps
/// screens under someone mid-answer feels broken. What changes is which parts
/// are on show.
///
/// It lives in a window of its own above the web view rather than inside it:
/// the call has to survive the page navigating, and on a locked phone it is
/// shown before the web view exists at all.
final class CallsScreen: UIViewController {
    private let stage = LKRTCMTLVideoView()

    /// One's own camera behind a ringing call, the way the web draws it.
    private let selfStage = LKRTCMTLVideoView()
    private let roomSelfStage = VideoView()
    private let selfScrim = CallsScrim()
    /// A room's video cannot be unwrapped to an RTC track — the SDK keeps that
    /// internal — so it is drawn by the SDK's own view, laid over the stage
    /// and shown only while a room is carrying the call.
    private let roomStage = VideoView()
    private let chip = LKRTCMTLVideoView()
    /// The same corner for a room's own camera, which is a LiveKit track and
    /// is drawn the way the room stage draws its one.
    private let roomChip = VideoView()
    private let chipHolder = UIView()

    /// The other side's second picture. Someone sharing their screen with the
    /// camera still on sends two, and one replacing the other is how you end
    /// up watching a face while they point at a document.
    private let peerChip = LKRTCMTLVideoView()
    /// The same corner, for a two-person call carried by a room: LiveKit's
    /// tracks draw through LiveKit's own view.
    private let roomPeerChip = VideoView()
    private let peerChipHolder = UIView()
    private let peerSwap = CallsIconView(CallsIcons.swapVideos)

    /// Where each small tile has been dragged to, kept across the layout
    /// passes that a rotation or a keyboard brings.
    /// The tiles are as tall as their picture is, the way the web's are: it
    /// gives them `height: auto` and lets the video's own ratio decide. A fixed
    /// box cropped a landscape camera to a portrait slot and showed the middle
    /// of somebody's face.
    private var chipRatio: NSLayoutConstraint?
    private var peerChipRatio: NSLayoutConstraint?

    private var chipOffset = CGPoint.zero
    private var peerChipOffset = CGPoint.zero
    private var dragFrom = CGPoint.zero
    private var dragHome = CGRect.zero

    /// A call with more than two people is a grid rather than a stage.
    private let grid = CallsGrid()
    private var inRoom = false
    /// Whether there is a moving picture on screen. PiP over a still avatar is
    /// a window showing nothing.
    private var hasPicture = false
    private var remoteScreen: LKRTCVideoTrack?
    /// What the other side says it is actually sending.
    ///
    /// A track exists for every source from the moment the call is negotiated
    /// — the warm transceivers see to that — so a track's existence says
    /// nothing at all about whether anything is coming down it. Only the
    /// announcement does. Without this an audio call arrives with a camera
    /// track and a screen track that carry nothing, the screen takes the stage
    /// because a share is what someone means to be looked at, and the other
    /// person's picture is left in the corner behind an empty rectangle.
    ///
    /// It is the same rule the web draws by.
    private var peerStateKnown = false
    private var peerCameraOn = false
    private var peerScreenOn = false
    private var stageShowing: LKRTCVideoTrack?
    private var cornerShowing: LKRTCVideoTrack?
    private var swapped = false
    private var backgrounded = false

    /// The boxes changed, so the size asked of the other side may have too.
    var onViewChanged: (() -> Void)?
    /// A moderator's Host Controls (`.bm-host-controls`): the room's rules in a menu above the dock.
    private var hostControlsButton: CallsButton?
    private var pipButton: CallsButton?
    private var settingsButton: CallsButton?
    private var shareButton: CallsButton?
    private var canPublish = true
    var canShareScreen = false
    private(set) var roster: [CallsRoomParticipant] = []

    private let avatar = UIView()
    private let initials = UILabel()
    /// The other person's own picture, where the site can name one. Their
    /// initials on a coloured disc are the fallback, not the intention.
    private let avatarImage = UIImageView()
    /// The presence dot the web draws on the avatar of a call that rings
    /// (`.bbpm-avatar` and its `::before`): a fifth of the avatar,
    /// bottom-right, ringed in the colour behind it so it reads as separate
    /// from the picture. Not once the call is answered (`drawPresence`).
    private let presenceDot = UIView()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    /// The other side's microphone. A silence with no explanation reads as a
    /// broken call, and this is the difference between "they muted themselves"
    /// and "something went wrong".
    /// The other side's microphone being off, said the way the web says it: a
    /// struck-through microphone beside the words, on a glass card. The web
    /// puts it in the top corner of the picture when there is one and in the
    /// middle of the placeholder when there is not, so this does too.
    /// What went wrong, said on the call screen rather than behind it.
    ///
    /// Everything the engine raises — a room that would not take us, a peer
    /// that would not connect, a microphone we were refused, the reason a call
    /// ended — leaves as `emit("error")` and becomes a toast in the web view.
    /// This window covers the web view, so none of them were ever seen. The
    /// card is the web's own `.bm-placeholder-no-access-message`, and it keeps
    /// the toast's ten seconds because that is what it stands in for.
    private let errorNotice = UIView()
    private let errorNoticeIcon = CallsIconView(CallsIcons.alert)
    private let errorNoticeText = UILabel()
    private var errorNoticeTimer: Timer?

    /// Configure and Participants, drawn on the call instead of over it.
    private var panel: CallsPanel?

    /// Keeps a panel's second line current while it is up.
    private var panelTimer: Timer?

    /// The other side has dropped, said over a picture that has stopped
    /// moving. `.bm-placeholder-participant-lost-message`, which the web draws
    /// whatever else is on the stage; here it is only needed over a picture,
    /// because without one the status line already says it.
    private let lostNotice = UIView()
    private let lostNoticeIcon = CallsIconView(CallsIcons.wifiOff)
    private let lostNoticeText = UILabel()

    private let peerNotice = UIView()
    private let peerNoticeIcon = CallsIconView(CallsIcons.micOff)
    private let peerNoticeText = UILabel()
    private var peerNoticeCorner: [NSLayoutConstraint] = []
    private var peerNoticeCentred: [NSLayoutConstraint] = []
    private var peerNoticeFull: [NSLayoutConstraint] = []
    private var peerNoticeCompact: [NSLayoutConstraint] = []

    /// The identity block is laid out for a whole screen. In the band the page
    /// makes for a call — the conversation above it, the composer below — that
    /// is a hundred points more than there is, and the avatar, the name and the
    /// clock ran straight through the dock. Held so the layout can step them
    /// down the way `applyControlMetrics` steps the controls.
    private var avatarTop: NSLayoutConstraint?
    private var avatarWidth: NSLayoutConstraint?
    private var avatarHeight: NSLayoutConstraint?
    private var nameTop: NSLayoutConstraint?
    /// Where the name goes in a room. A group call has no face to hang it
    /// under — the grid is the picture — so the conversation's name becomes a
    /// line in the band above it.
    private var nameTopRoom: NSLayoutConstraint?
    private var nameLeading: NSLayoutConstraint?
    private var nameTrailing: NSLayoutConstraint?
    private var statusTop: NSLayoutConstraint?
    private var gridTop: NSLayoutConstraint?
    /// The grid's floor: the screen's in a call between two, the top of the bar in a group call (`applyBarLayout`).
    private var gridToFloor: NSLayoutConstraint?
    private var gridAboveBar: NSLayoutConstraint?
    /// Where the dock stands: the middle in a call between two, the end of the bar in a group call.
    private var dockCentred: NSLayoutConstraint?
    private var dockAtEnd: NSLayoutConstraint?
    private var controlsVisible = true
    private var identityMode: String?
    private var peerOnline = false

    private let dock = CallsDock()
    /// A group call's connection, at the start of the bar the dock sits in.
    private let connectionPill = CallsConnectionPill()
    private var answerButton: CallsButton?
    private var endButton: CallsButton?
    private var controlDiameter: CGFloat = 0

    private var muteButton: CallsButton?
    private var lockedMicButton: CallsButton?
    private var cameraButton: CallsButton?
    private var flipButton: CallsButton?
    private var speakerButton: CallsButton?
    /// A viewer's only way to ask to speak in a broadcast room. The web draws
    /// it on exactly the same condition and nowhere else.
    private var handButton: CallsButton?

    /// A call with more than two people. Not the same question as `inRoom`: a
    /// direct call the server moved into a room has a roster too, and it is
    /// still a call between two people.
    private var isGroupCall = false
    /// The room was switched to broadcast, or this side was muted by a
    /// moderator. Both are rules rather than settings, and the control that
    /// would undo them is not drawn.
    private var callMode = "participatory"
    private var micLocked = false
    /// Whether this call's roster has said yet whether a moderator keeps the
    /// microphone off, so the first word of it, a newcomer to a muted room,
    /// is not announced as a moderator's doing just now.
    private var micLockKnown = false
    private var handRaised = false
    /// The mesh is keeping the room's join waiting for a place in the call.
    private var waitingForPlace = false

    private var durationTimer: Timer?
    private var connectedAt: Date?

    private var remoteVideo: LKRTCVideoTrack?
    private var localVideo: LKRTCVideoTrack?
    private var roomLocalVideo: VideoTrack?
    private var roomPeerCamera: VideoTrack?
    private var roomPeerScreen: VideoTrack?
    /// The other side's camera changing codec in a two-person room
    /// (`CallsCameraSwitch`): the room holds it until the frame that ends
    /// it, for `applyRoomOptimizing`.
    private var roomPeerOptimizing = false
    /// Over the stage while that lasts, below the corners and the dock.
    private let roomOptimizing = CallsOptimizingView()
    /// What of the other side's stopped arriving in a two-person room
    /// (`CallsStallWatch`), for `applyRoomStalled`: their picture on the
    /// stage blurred, and the one in the corner, and "Video interrupted" with
    /// why over a camera that alone stopped.
    private var roomPeerStalled: CallsStalled?
    private let roomStalled = CallsStalledView(main: true)
    private let roomCornerStalled = CallsStalledView()
    private var selfShowing: LKRTCVideoTrack?

    private var phase = "idle"
    private var isVideoCall = false
    private var avatarURL = ""

    /// The last name this call was able to put to the person.
    ///
    /// `updateScreen` redraws the name on every state change, the page does not
    /// always have one to give on the first, and the engine blanks it before
    /// the ending is drawn — so "Unknown" appeared for a moment at both ends of
    /// a call that knew perfectly well who it was with. One screen is built per
    /// call, so what this remembers is always this call's.
    private var lastName = ""

    var onAnswer: (() -> Void)?
    var onDecline: (() -> Void)?
    var onEnd: (() -> Void)?
    var onToggleMute: ((Bool) -> Void)?
    var onToggleCamera: ((Bool) -> Void)?
    var onFlipCamera: (() -> Void)?
    var onToggleSpeaker: ((Bool) -> Void)?
    var onPeople: (() -> Void)?
    var onPictureInPicture: (() -> Void)?
    var onSettings: (() -> Void)?
    var onToggleScreenShare: ((Bool) -> Void)?

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { phase == "in_progress" && isVideoCall }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = CallsTheme.stage

        buildStage()
        buildGrid()
        buildIdentity()
        buildPeerNotice()
        buildLostNotice()
        buildControls()
        // After the dock, because it sits above it and is drawn over it.
        buildErrorNotice()

        // Not a press on the dock, a menu, Device Settings, a confirmation, the join notice or a moderator's toast:
        // those are theirs.
        view.addGestureRecognizer(CallsGroundTap(target: self, action: #selector(stageTapped)) {
            $0 is CallsDock || $0 is CallsPopover || $0 is CallsDevices || $0 is CallsPanel
                || $0 is CallsConfirm || $0 is CallsJoinPrompt || $0 is CallsHostToasts
                || $0 is CallsAskPrompt || $0 is CallsRecordingNotice || $0 is CallsRecordingPill
        })

        // The window animates out of and back into this screen, so it is
        // attached once the screen exists rather than when a call starts.
        CallsPip.shared.attach(to: view)

        // Backgrounded is "not shown" unless the corner window is up, and the
        // other side should stop paying for a picture nobody can see.
        for name in [ UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appVisibilityChanged(_:)),
                name: name,
                object: nil
            )
        }
    }

    @objc private func appVisibilityChanged(_ note: Notification) {
        backgrounded = note.name == UIApplication.didEnterBackgroundNotification

        onViewChanged?()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()

        fitSafeArea()
    }

    /// The safe area of the window the call is in, from the edges of the screen it really covers.
    ///
    /// Shrunk into the band a page makes beside its chat, the window kept the whole screen's safe area: UIKit went on
    /// handing the screen the status bar's 59 points at its top though the band starts under the page's header, far
    /// below the status bar, so the grid stood that much lower, an empty strip over the call. The app's own window
    /// covers the screen and knows its unsafe edges: what this window overlaps of them is its safe area, and the
    /// difference from what UIKit reports is given back as an additional inset. A window over the whole screen
    /// overlaps all of them, and is left as it was.
    private func fitSafeArea() {
        guard let window = view.window, let scene = window.windowScene,
              let host = scene.windows.first(where: { $0 !== window && $0.windowLevel == .normal && !$0.isHidden }) else { return }

        let wanted = Self.safeArea(of: window.frame, on: host.frame, edges: host.safeAreaInsets)

        let extra = additionalSafeAreaInsets
        let given = view.safeAreaInsets
        let fitted = UIEdgeInsets(
            top: wanted.top - (given.top - extra.top),
            left: wanted.left - (given.left - extra.left),
            bottom: wanted.bottom - (given.bottom - extra.bottom),
            right: wanted.right - (given.right - extra.right)
        )

        guard fitted != extra else { return }

        additionalSafeAreaInsets = fitted
    }

    /// What of a screen's unsafe `edges` a window `frame` on it overlaps: the whole of each for a window over the
    /// whole screen, none for a band under a page's header.
    static func safeArea(of frame: CGRect, on screen: CGRect, edges: UIEdgeInsets) -> UIEdgeInsets {
        UIEdgeInsets(
            top: max(0, screen.minY + edges.top - frame.minY),
            left: max(0, screen.minX + edges.left - frame.minX),
            bottom: max(0, frame.maxY - (screen.maxY - edges.bottom)),
            right: max(0, frame.maxX - (screen.maxX - edges.right))
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Before anything reads the safe area: the band's frame arrives as a layout, not as a safe area change.
        fitSafeArea()

        applyControlMetrics()
        applyIdentityMetrics()

        // Whether the dock, as wide as it is now, leaves the pill its corner.
        drawConnectionPill()

        // Its size is a share of the avatar's, so the radius cannot be set
        // once — the compact profile halves it.
        presenceDot.layer.cornerRadius = presenceDot.bounds.width / 2

        // The window's frame was set for the screen as it was. A rotation
        // changes the screen's bounds and nothing re-sets it, so the call kept
        // a portrait-shaped window on a landscape screen and the web view's
        // white showed around it. Re-applying is free when nothing moved.
        CallsScreenHost.shared.refreshFrame()

        // A rotation or a split-screen resize changes every box on the screen.
        onViewChanged?()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        coordinator.animate(alongsideTransition: { _ in
            CallsScreenHost.shared.refreshFrame()
        }, completion: { _ in
            CallsScreenHost.shared.refreshFrame()
        })
    }

    // MARK: - Building

    private func buildStage() {
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.videoContentMode = .scaleAspectFill
        // Aspect FILL paints outside the view unless the view clips, and until
        // the call could be a band there was nothing outside it to spill into
        // — the corner chips and every grid tile have always clipped for this
        // very reason. In a band a portrait camera scaled to the band's width
        // is far taller than the band, and it was drawn over the thread header
        // above and the conversation below, leaving the dock stranded in the
        // middle of a picture that had no business being there.
        stage.clipsToBounds = true
        stage.isHidden = true

        view.addSubview(stage)

        NSLayoutConstraint.activate([
            stage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stage.topAnchor.constraint(equalTo: view.topAnchor),
            stage.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // The web fills a ringing call with your own camera and lays the
        // avatar, the name and the status over a gradient on top of it
        // (`.bm-placeholder-video`, `_call-stage.scss`). Same picture, same
        // gradient, same order.
        selfStage.translatesAutoresizingMaskIntoConstraints = false
        selfStage.videoContentMode = .scaleAspectFill
        selfStage.clipsToBounds = true
        selfStage.isHidden = true

        selfScrim.translatesAutoresizingMaskIntoConstraints = false
        selfScrim.isUserInteractionEnabled = false
        selfScrim.isHidden = true

        // The same background for a call the site put in a room, which rings
        // with the room's camera rather than the direct path's. Not mirrored,
        // like every picture of one's own camera here: you see yourself the
        // way the other side does, as the web shows it.
        roomSelfStage.translatesAutoresizingMaskIntoConstraints = false
        roomSelfStage.layoutMode = .fill
        roomSelfStage.mirrorMode = .off
        roomSelfStage.isHidden = true

        view.addSubview(selfStage)
        view.addSubview(roomSelfStage)
        view.addSubview(selfScrim)

        NSLayoutConstraint.activate([
            selfStage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selfStage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            selfStage.topAnchor.constraint(equalTo: view.topAnchor),
            selfStage.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            roomSelfStage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            roomSelfStage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            roomSelfStage.topAnchor.constraint(equalTo: view.topAnchor),
            roomSelfStage.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            selfScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selfScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            selfScrim.topAnchor.constraint(equalTo: view.topAnchor),
            selfScrim.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // The chip is this side's own camera, in the corner, kept out of the
        // way of the controls and the notch.
        chipHolder.translatesAutoresizingMaskIntoConstraints = false
        chipHolder.backgroundColor = UIColor(white: 0, alpha: 0.4)
        chipHolder.layer.cornerRadius = 14
        chipHolder.clipsToBounds = true
        chipHolder.isHidden = true

        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.videoContentMode = .scaleAspectFill
        chip.delegate = self

        // Filled like every corner tile, and not mirrored: LiveKit's `.auto`
        // would mirror a front camera.
        roomChip.translatesAutoresizingMaskIntoConstraints = false
        roomChip.layoutMode = .fill
        roomChip.mirrorMode = .off
        roomChip.isHidden = true

        roomStage.translatesAutoresizingMaskIntoConstraints = false

        // Fitted, never filled, for the same reason the direct stage is: this
        // is the whole screen and not a thumbnail. A private call carried by a
        // room draws the other side here rather than on `stage`, and filling
        // cropped it to the shape of the phone — the four corners of the frame
        // were not on the screen at all. Only the corner tiles fill, which is
        // what the web and the grid both do.
        roomStage.layoutMode = .fit
        roomStage.mirrorMode = .off
        roomStage.isHidden = true

        view.addSubview(roomStage)

        roomStalled.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(roomStalled)

        roomOptimizing.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(roomOptimizing)

        NSLayoutConstraint.activate([
            roomStage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            roomStage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            roomStage.topAnchor.constraint(equalTo: view.topAnchor),
            roomStage.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            roomStalled.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            roomStalled.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            roomStalled.topAnchor.constraint(equalTo: view.topAnchor),
            roomStalled.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            roomOptimizing.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            roomOptimizing.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            roomOptimizing.topAnchor.constraint(equalTo: view.topAnchor),
            roomOptimizing.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // The second chip sits under the first, and tapping it swaps what is
        // on the stage.
        peerChipHolder.translatesAutoresizingMaskIntoConstraints = false
        peerChipHolder.backgroundColor = UIColor(white: 0, alpha: 0.4)
        peerChipHolder.layer.cornerRadius = 14
        peerChipHolder.clipsToBounds = true
        peerChipHolder.isHidden = true
        peerChipHolder.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(swapTapped))
        )

        // The web lets either small tile be dragged anywhere in the call — a
        // `.bm-draggable-handle` covering the whole of it, `cursor: move`.
        // A pan is the same thing said in the phone's language.
        chipHolder.addGestureRecognizer(
            UIPanGestureRecognizer(target: self, action: #selector(chipDragged))
        )

        peerChipHolder.addGestureRecognizer(
            UIPanGestureRecognizer(target: self, action: #selector(peerChipDragged))
        )

        peerChip.translatesAutoresizingMaskIntoConstraints = false
        peerChip.videoContentMode = .scaleAspectFill
        peerChip.delegate = self

        // The other side's picture is not a mirror.
        roomPeerChip.translatesAutoresizingMaskIntoConstraints = false
        roomPeerChip.layoutMode = .fill
        roomPeerChip.mirrorMode = .off
        roomPeerChip.isHidden = true

        // The web puts a flip glyph on this tile (`.bm-switch-videos`), which
        // is the only thing that says the tile can be tapped at all. Without
        // it the swap is a gesture nobody discovers.
        peerSwap.color = .white
        peerSwap.accessibilityLabel = CallsTheme.string("switch_videos", fallback: "Switch Videos")
        peerSwap.isAccessibilityElement = true

        roomCornerStalled.translatesAutoresizingMaskIntoConstraints = false

        peerChipHolder.addSubview(peerChip)
        peerChipHolder.addSubview(roomPeerChip)
        peerChipHolder.addSubview(roomCornerStalled)
        peerChipHolder.addSubview(peerSwap)
        view.addSubview(peerChipHolder)

        chipHolder.addSubview(chip)
        chipHolder.addSubview(roomChip)
        view.addSubview(chipHolder)

        NSLayoutConstraint.activate([
            chipHolder.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            chipHolder.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            chipHolder.widthAnchor.constraint(equalToConstant: 104),

            chip.leadingAnchor.constraint(equalTo: chipHolder.leadingAnchor),
            chip.trailingAnchor.constraint(equalTo: chipHolder.trailingAnchor),
            chip.topAnchor.constraint(equalTo: chipHolder.topAnchor),
            chip.bottomAnchor.constraint(equalTo: chipHolder.bottomAnchor),

            roomChip.leadingAnchor.constraint(equalTo: chipHolder.leadingAnchor),
            roomChip.trailingAnchor.constraint(equalTo: chipHolder.trailingAnchor),
            roomChip.topAnchor.constraint(equalTo: chipHolder.topAnchor),
            roomChip.bottomAnchor.constraint(equalTo: chipHolder.bottomAnchor),

            peerChipHolder.trailingAnchor.constraint(equalTo: chipHolder.trailingAnchor),
            peerChipHolder.topAnchor.constraint(equalTo: chipHolder.bottomAnchor, constant: 12),
            peerChipHolder.widthAnchor.constraint(equalToConstant: 104),

            peerChip.leadingAnchor.constraint(equalTo: peerChipHolder.leadingAnchor),
            peerChip.trailingAnchor.constraint(equalTo: peerChipHolder.trailingAnchor),
            peerChip.topAnchor.constraint(equalTo: peerChipHolder.topAnchor),
            peerChip.bottomAnchor.constraint(equalTo: peerChipHolder.bottomAnchor),

            roomPeerChip.leadingAnchor.constraint(equalTo: peerChipHolder.leadingAnchor),
            roomPeerChip.trailingAnchor.constraint(equalTo: peerChipHolder.trailingAnchor),
            roomPeerChip.topAnchor.constraint(equalTo: peerChipHolder.topAnchor),
            roomPeerChip.bottomAnchor.constraint(equalTo: peerChipHolder.bottomAnchor),
            roomCornerStalled.leadingAnchor.constraint(equalTo: peerChipHolder.leadingAnchor),
            roomCornerStalled.trailingAnchor.constraint(equalTo: peerChipHolder.trailingAnchor),
            roomCornerStalled.topAnchor.constraint(equalTo: peerChipHolder.topAnchor),
            roomCornerStalled.bottomAnchor.constraint(equalTo: peerChipHolder.bottomAnchor),

            peerSwap.leadingAnchor.constraint(equalTo: peerChipHolder.leadingAnchor, constant: 6),
            peerSwap.topAnchor.constraint(equalTo: peerChipHolder.topAnchor, constant: 6),
            peerSwap.widthAnchor.constraint(equalToConstant: 14),
            peerSwap.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    @objc private func chipDragged(_ pan: UIPanGestureRecognizer) {
        drag(pan, holder: chipHolder, offset: &chipOffset)
    }

    @objc private func peerChipDragged(_ pan: UIPanGestureRecognizer) {
        drag(pan, holder: peerChipHolder, offset: &peerChipOffset)
    }

    /// A tile follows the finger and stays on the screen. Somewhere it cannot
    /// be reached is not somewhere it should be draggable to, so the box it
    /// may live in is the screen less the margin it was laid out with.
    private func drag(_ pan: UIPanGestureRecognizer, holder: UIView, offset: inout CGPoint) {
        let moved = pan.translation(in: view)

        // Where the tile sits with no dragging at all. Taken once, at the
        // start: mid-gesture the frame already carries the transform being
        // applied, and reading it then walks the tile away from the finger.
        if pan.state == .began {
            dragFrom = offset
            dragHome = holder.frame.offsetBy(dx: -offset.x, dy: -offset.y)
        }

        let home = dragHome
        let room = view.bounds.insetBy(dx: 8, dy: 8)

        guard home.width > 0, room.width >= home.width, room.height >= home.height else { return }

        var next = CGPoint(x: dragFrom.x + moved.x, y: dragFrom.y + moved.y)

        next.x = min(max(next.x, room.minX - home.minX), room.maxX - home.maxX)
        next.y = min(max(next.y, room.minY - home.minY), room.maxY - home.maxY)

        holder.transform = CGAffineTransform(translationX: next.x, y: next.y)

        if pan.state == .ended || pan.state == .cancelled {
            offset = next
        }
    }

    /// Move the other side's second picture onto the stage and the stage's
    /// into the corner. The size wish follows, because a screen share that has
    /// just become the big one should be sent big.
    @objc private func swapTapped() {
        swapped = !swapped

        drawPeerVideo()
        onViewChanged?()
    }

    private func buildGrid() {
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.isHidden = true
        grid.onPerson = { [weak self] person in
            guard let self = self else { return }

            CallsModeration.showFor(from: self, person: person)
        }

        // Pin for Me from the pin on a tile, anyone's.
        grid.onPin = { [weak self] person in
            self?.togglePinForMe(person.identity)
        }

        view.addSubview(grid)

        // The strip the name and the clock live in — kept as a constant so it
        // can be given back, because a room draws neither and the tiles were
        // starting 72 points below an empty band. The bottom is tied to the
        // dock in `buildControls`, which is where the dock joins the
        // hierarchy.
        let top = grid.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 72)

        gridTop = top

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            top
        ])
    }

    /// The grid clears the strip above it, and only while something is drawn
    /// there. Its bottom is the bar's (`applyBarLayout`).
    private func applyGridMetrics() {
        gridTop?.constant = (nameLabel.isHidden && statusLabel.isHidden) ? 0 : 72
    }

    private func buildIdentity() {
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.backgroundColor = CallsTheme.accent
        avatar.layer.cornerRadius = 54
        avatar.clipsToBounds = true

        initials.translatesAutoresizingMaskIntoConstraints = false
        initials.font = .systemFont(ofSize: 40, weight: .semibold)
        initials.textColor = .white
        initials.textAlignment = .center

        avatarImage.translatesAutoresizingMaskIntoConstraints = false
        avatarImage.contentMode = .scaleAspectFill
        avatarImage.clipsToBounds = true
        avatarImage.isHidden = true

        avatar.addSubview(initials)
        avatar.addSubview(avatarImage)

        presenceDot.translatesAutoresizingMaskIntoConstraints = false
        presenceDot.backgroundColor = CallsTheme.online
        // `.bbpm-avatar::before` rings the dot in **one** pixel of the colour
        // behind it. A CALayer border is drawn *inside* the bounds, so two of
        // them ate a third of the dot and left a heavy dark arc across the
        // picture — the view is a hairline wider than the dot instead, which
        // puts the ring outside it exactly as the stylesheet does.
        presenceDot.layer.borderWidth = 1
        presenceDot.layer.borderColor = CallsTheme.stage.cgColor
        presenceDot.isUserInteractionEnabled = false
        presenceDot.isHidden = true

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        nameLabel.textColor = CallsTheme.onStage
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 16, weight: .regular)
        statusLabel.textColor = UIColor(white: 1, alpha: 0.7)
        statusLabel.textAlignment = .center

        view.addSubview(avatar)
        view.addSubview(presenceDot)
        view.addSubview(nameLabel)
        view.addSubview(statusLabel)

        let top = avatar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 96)
        let width = avatar.widthAnchor.constraint(equalToConstant: 108)
        let height = avatar.heightAnchor.constraint(equalToConstant: 108)
        let name = nameLabel.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 24)
        let status = statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8)
        let leading = nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32)
        let trailing = nameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)

        // Held rather than activated: in a room the name sits in the strip
        // above the grid instead, and the two are never both on.
        nameTopRoom = nameLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14)

        avatarTop = top
        avatarWidth = width
        avatarHeight = height
        nameTop = name
        nameLeading = leading
        nameTrailing = trailing
        statusTop = status

        NSLayoutConstraint.activate([
            avatar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            top,
            width,
            height,

            initials.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            initials.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),

            avatarImage.leadingAnchor.constraint(equalTo: avatar.leadingAnchor),
            avatarImage.trailingAnchor.constraint(equalTo: avatar.trailingAnchor),
            avatarImage.topAnchor.constraint(equalTo: avatar.topAnchor),
            avatarImage.bottomAnchor.constraint(equalTo: avatar.bottomAnchor),

            // A share of the avatar rather than a size of its own, so the
            // compact profile in `applyIdentityMetrics` scales it for free.
            // It sits outside `avatar`, which clips to its circle. The two
            // extra points are the ring, which the stylesheet adds around the
            // 20% rather than inside it, and the point of overhang is its
            // `bottom: -1px; right: -1px`.
            presenceDot.widthAnchor.constraint(equalTo: avatar.widthAnchor, multiplier: 0.2, constant: 2),
            presenceDot.heightAnchor.constraint(equalTo: presenceDot.widthAnchor),
            presenceDot.trailingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 1),
            presenceDot.bottomAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 1),

            leading,
            trailing,
            name,

            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            status
        ])
    }

    /// The identity block, sized for the stage it is actually on.
    ///
    /// The full-screen numbers need about 290 points before the dock starts,
    /// and the stacked band the page makes for a call is 40% of the area under
    /// the thread header — around 300 in total on a phone. Read on every
    /// layout, so toggling the conversation in and out re-fits it.
    private func applyIdentityMetrics() {
        let compact = view.bounds.height < 460
        let mode = inRoom ? "room" : (compact ? "compact" : "full")

        guard mode != identityMode else { return }

        identityMode = mode

        // A room draws the grid where the face would be, so the name and the
        // clock become one small line in the strip the grid leaves above it.
        if inRoom {
            nameTop?.isActive = false
            nameTopRoom?.isActive = true

            nameLeading?.constant = 72
            nameTrailing?.constant = -72
            statusTop?.constant = 2

            nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
            nameLabel.numberOfLines = 1
            statusLabel.font = .systemFont(ofSize: 13, weight: .regular)

            return
        }

        nameTopRoom?.isActive = false
        nameTop?.isActive = true

        nameLeading?.constant = 32
        nameTrailing?.constant = -32

        avatarTop?.constant = compact ? 14 : 96
        avatarWidth?.constant = compact ? 56 : 108
        avatarHeight?.constant = compact ? 56 : 108
        nameTop?.constant = compact ? 10 : 24
        statusTop?.constant = compact ? 2 : 8

        avatar.layer.cornerRadius = (compact ? 56 : 108) / 2
        initials.font = .systemFont(ofSize: compact ? 22 : 40, weight: .semibold)
        nameLabel.font = .systemFont(ofSize: compact ? 18 : 28, weight: .semibold)
        nameLabel.numberOfLines = compact ? 1 : 2
        statusLabel.font = .systemFont(ofSize: compact ? 13 : 16, weight: .regular)
    }

    /// `.bm-placeholder-no-access-message`: the same card as the peer notice —
    /// the card radius, 10 by 14 of padding, a glyph ten points from the words
    /// — on the danger colour at 0.88 with no hairline, and a 22pt alert
    /// instead of the 20pt microphone.
    ///
    /// It sits above the dock rather than in the placeholder the stylesheet
    /// puts it in, because a room call has no placeholder and a failure in one
    /// still has to be readable. That is also where the toast it replaces
    /// would have been.
    private func buildErrorNotice() {
        errorNotice.translatesAutoresizingMaskIntoConstraints = false
        errorNotice.backgroundColor = CallsTheme
            .color("danger", fallback: UIColor(red: 0.91, green: 0.25, blue: 0.25, alpha: 1))
            .withAlphaComponent(0.88)
        errorNotice.layer.cornerRadius = 12
        errorNotice.isHidden = true

        errorNoticeIcon.color = .white
        errorNoticeIcon.translatesAutoresizingMaskIntoConstraints = false

        errorNoticeText.translatesAutoresizingMaskIntoConstraints = false
        errorNoticeText.font = .systemFont(ofSize: 13)
        errorNoticeText.textColor = .white
        errorNoticeText.numberOfLines = 0
        errorNoticeText.textAlignment = .natural

        errorNotice.addSubview(errorNoticeIcon)
        errorNotice.addSubview(errorNoticeText)

        view.addSubview(errorNotice)

        NSLayoutConstraint.activate([
            errorNoticeIcon.leadingAnchor.constraint(equalTo: errorNotice.leadingAnchor, constant: 14),
            errorNoticeIcon.centerYAnchor.constraint(equalTo: errorNotice.centerYAnchor),
            errorNoticeIcon.widthAnchor.constraint(equalToConstant: 22),
            errorNoticeIcon.heightAnchor.constraint(equalToConstant: 22),

            errorNoticeText.leadingAnchor.constraint(equalTo: errorNoticeIcon.trailingAnchor, constant: 10),
            errorNoticeText.trailingAnchor.constraint(equalTo: errorNotice.trailingAnchor, constant: -14),
            errorNoticeText.topAnchor.constraint(equalTo: errorNotice.topAnchor, constant: 10),
            errorNoticeText.bottomAnchor.constraint(equalTo: errorNotice.bottomAnchor, constant: -10),

            errorNotice.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorNotice.bottomAnchor.constraint(equalTo: dock.topAnchor, constant: -12),
            // `max-width: min(100% - 32px, 420px)`.
            errorNotice.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            errorNotice.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            errorNotice.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
    }

    /// The latest message wins and restarts the ten seconds: errors in a call
    /// arrive in bursts about the same failure, and the last one is the one
    /// worth reading.
    func showError(_ message: String) {
        guard !message.isEmpty else { return }

        errorNotice.backgroundColor = CallsTheme
            .color("danger", fallback: UIColor(red: 0.91, green: 0.25, blue: 0.25, alpha: 1))
            .withAlphaComponent(0.88)
        errorNotice.layer.borderWidth = 0
        errorNoticeIcon.set(CallsIcons.alert)
        errorNoticeText.text = message
        errorNotice.isHidden = false

        errorNoticeTimer?.invalidate()
        errorNoticeTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.hideError()
        }
    }

    /// What a moderator just did to this side's microphone, for six seconds
    /// in the error notice's place, on the peer notice's glass rather than in
    /// red: it is news, not a failure. The web's useModeratorNotice, which
    /// says it in the call's status line.
    func showModeratorNotice(muted: Bool) {
        let words = muted
            ? CallsTheme.string("moderator_muted_you", fallback: "A moderator muted your microphone.")
            : CallsTheme.string("moderator_allowed_you", fallback: "A moderator allowed you to unmute your microphone.")

        // In a room, where moderators are, in the call's status line at the
        // top, as the web says it.
        if inRoom {
            showStatusLine(words, seconds: 6)
            return
        }

        errorNotice.backgroundColor = UIColor(white: 0, alpha: 0.55)
        errorNotice.layer.borderWidth = 1
        errorNotice.layer.borderColor = UIColor(white: 1, alpha: 0.08).cgColor
        errorNoticeIcon.set(muted ? CallsIcons.silenced : CallsIcons.mic)
        errorNoticeText.text = muted
            ? CallsTheme.string("moderator_muted_you", fallback: "A moderator muted your microphone.")
            : CallsTheme.string("moderator_allowed_you", fallback: "A moderator allowed you to unmute your microphone.")
        errorNotice.isHidden = false

        errorNoticeTimer?.invalidate()
        errorNoticeTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            self?.hideError()
        }
    }

    func hideError() {
        errorNoticeTimer?.invalidate()
        errorNoticeTimer = nil
        errorNotice.isHidden = true
        errorNoticeText.text = nil
    }

    /// Ask something on the call rather than over it.
    ///
    /// Configure and Participants were `UIAlertController` action sheets —
    /// which is a piece of iOS laid on top of the call, arrow and all, rather
    /// than a piece of the call. They are drawn on this screen now, in the
    /// glass the rest of it is made of, and nothing is presented over the
    /// stage: a view LiveKit believes nobody is looking at is a view it may
    /// stop feeding, which is the video that used to stop while a sheet was up.
    /// `refresh` is asked for a new second line once a second for as long as
    /// the card is up. The byte counts behind the gear are sampled every two
    /// seconds and the web counts them up on screen as they arrive; without
    /// this the card would hold whatever they read when it opened.
    func showPanel(
        title: String,
        message: String? = nil,
        rows: [CallsPanelRow],
        refresh: (() -> String?)? = nil
    ) {
        hidePanel()

        let panel = CallsPanel()

        panel.place(in: view, above: dock)
        panel.fill(title: title, message: message, entries: rows) { [weak self] in
            self?.hidePanel()
        }

        self.panel = panel

        guard let refresh = refresh else { return }

        panelTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self, let panel = self.panel else { return }

            panel.update(message: refresh())
        }
    }

    func hidePanel() {
        panelTimer?.invalidate()
        panelTimer = nil

        panel?.removeFromSuperview()
        panel = nil

        hideAddPerson()
    }

    // MARK: Add Person

    private var addPersonButton: CallsButton?
    private var addPerson: CallsAddPersonPanel?

    /// Whom the user may bring in, over the call, where the host gives them (CallsAddPerson). The same press closes it,
    /// as the web's Add Person does.
    func showAddPerson() {
        guard addPerson == nil else { return hideAddPerson() }

        closePopover()
        hideDevices()
        hidePanel()

        guard CallsAddPersonStore.current != nil else { return }

        let shown = CallsAddPersonPanel(
            close: { [weak self] in self?.hideAddPerson() },
            failed: { [weak self] error in
                self?.hideAddPerson()
                self?.showError( error )
            }
        )

        shown.place( in: view, above: dock )
        addPerson = shown
        shown.open()
        drawAddPerson()
    }

    func hideAddPerson() {
        addPerson?.removeFromSuperview()
        addPerson = nil
        addPersonButton?.isOn = false
    }

    /// Add Person once the call is up, where the host gives it, what the web asks of it, `action === 'call_in_progress'`,
    /// and of a group call its connection. An open panel stays while the call is on and draws the rings as they change: a
    /// ring moves a call between two to its group call, which connects under it.
    private func drawAddPerson() {
        let given = CallsAddPersonStore.current != nil

        addPersonButton?.isHidden = !given || phase != "in_progress"

        guard given, [ "in_progress", "connecting", "reconnecting" ].contains( phase ) else { return hideAddPerson() }

        addPersonButton?.isOn = addPerson != nil
        addPerson?.draw()
    }

    // MARK: Device Settings

    private var devices: CallsDevices?
    private var frontCamera = true
    private var microphoneOn = false
    private var cameraOn = false

    // MARK: The join notice

    private var joinPrompt: CallsJoinPrompt?
    private var joinPromptTimer: Timer?
    /// The group call has connected once under this screen: a reconnect is not a join.
    private var joinedOnce = false

    /// The notice of a group call's join, where the host asks for it (`devicesOnJoin`) and the user has not said Do Not
    /// Show Again (`joinNotice`): just connected for the first time, may send, and neither the microphone nor the camera
    /// on. Ten seconds at most.
    private func considerJoinPrompt(from previous: String) {
        guard isGroupCall, phase == "in_progress" else { return }

        let first = previous == "connecting" && !joinedOnce

        joinedOnce = true

        guard first, CallsEngine.shared.devicesOnJoin, canPublish, !microphoneOn, !cameraOn, devices == nil else { return }
        guard CallsEngine.shared.joinNotice != false else { return }

        showJoinPrompt()
    }

    func showJoinPrompt() {
        hideJoinPrompt()

        let video = isVideoCall
        // Do Not Show Again where the host keeps the user's choice, as the web's.
        let prompt = CallsJoinPrompt(video: video, never: CallsEngine.shared.joinNotice != nil)

        prompt.onPreview = { [weak self] in
            self?.showDevices(start: video ? .both : .microphone)
        }
        prompt.onDismiss = { [weak self] in self?.hideJoinPrompt() }
        prompt.onNever = { [weak self] in
            CallsEngine.shared.joinNoticeNever()
            self?.hideJoinPrompt()
        }

        prompt.place(in: view, above: dock)
        joinPrompt = prompt
        // It waits under a recording's notice, as the web's does.
        prompt.isHidden = recordingNotice != nil

        joinPromptTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.hideJoinPrompt()
        }
    }

    func hideJoinPrompt() {
        joinPromptTimer?.invalidate()
        joinPromptTimer = nil
        joinPrompt?.removeFromSuperview()
        joinPrompt = nil
    }

    // MARK: A moderator's ask (CallsAsks)

    /// The asks this user was sent, the oldest first, as the state names them.
    private var asks: [CallsTurnOnAsk] = []
    private var askPrompt: CallsAskPrompt?
    /// Why each device would not turn on, from the last press of Turn On, for the ask `askShown`.
    private var askStuck: [String: CallsAsks.Stuck] = [:]
    private var askShown = ""
    private var askTrying = false
    /// What each ask was answered already, by its id and device: an ask for both is two under one id.
    private var askTold: [String: Set<String>] = [:]

    /// A person's menu says what it offers again, as an "Asked…" runs out or an answer comes.
    func refreshPopover() {
        popover?.refresh()
    }

    private func applyAsks(_ state: [String: Any]) {
        asks = (state["asks"] as? [[String: Any]] ?? []).compactMap { one in
            guard let id = one["id"] as? String, let device = one["device"] as? String, let by = one["by"] as? String,
                  device == "camera" || device == "microphone" else { return nil }

            return CallsTurnOnAsk(id: id, device: device, by: by)
        }

        CallsAsks.answers = (state["askAnswers"] as? [[String: Any]] ?? []).compactMap { one in
            guard let id = one["id"] as? String, let from = one["from"] as? String, let device = one["device"] as? String,
                  let answer = one["answer"] as? String else { return nil }

            return CallsTurnOnAnswer(id: id, from: from, device: device, answer: answer)
        }

        if CallsEngine.shared.carriesAsks, inRoom, isGroupCall, canModerate {
            hostToasts.heard(CallsAsks.answers, people: roster)
        }

        // Turned on, from the card or the dock: said to each who asked for it, and their asks go. Put away after this
        // drawing, as the engine draws the screen again for it.
        for (device, on) in [("camera", cameraOn), ("microphone", microphoneOn)] where on {
            for ask in asks where ask.device == device {
                tellAsk(ask, "on")
                DispatchQueue.main.async { CallsEngine.shared.dismissAsk(id: ask.id, device: ask.device) }
            }
        }

        drawAskPrompt()
    }

    /// The card over the dock for the newest ask, in the join notice's place, while the call carries asks and this user
    /// may send: for its device, and the other one too where the same moderator asked for it, both while both are off.
    /// It steps aside while Device Settings is open.
    private func drawAskPrompt() {
        // It waits under a recording's notice, as the web's does.
        guard CallsEngine.shared.carriesAsks, inRoom, isGroupCall, phase == "in_progress", canPublish, devices == nil,
              recordingNotice == nil, let ask = asks.last else { return hideAskPrompt() }

        // The camera first, on a video call alone, and neither once it is on.
        let also = asks.contains { $0.by == ask.by && $0.device != ask.device }
        let wanted = ["camera", "microphone"].filter { device in
            (device == ask.device || also) && !(device == "camera" ? cameraOn : microphoneOn) && (device != "camera" || isVideoCall)
        }

        guard !wanted.isEmpty else { return hideAskPrompt() }

        // A new ask starts again from its question.
        if askShown != ask.id {
            askShown = ask.id
            askStuck = [:]
        }

        let stuckOn = wanted.first { askStuck[$0] != nil }
        let stuck = stuckOn.flatMap { askStuck[$0] }
        let named = CallsHostToasts.plain(roster.first { $0.identity == ask.by }?.name ?? "")
        let who = named.isEmpty ? CallsTheme.string("a_moderator", fallback: "A moderator") : named

        let title: String

        if let stuckOn, let stuck {
            title = CallsAsks.stuckTitle(stuckOn, stuck)
        } else if wanted.count > 1 {
            title = CallsTheme.string("ask_title_both", fallback: "%s asks you to turn on your camera and microphone").replacingOccurrences(of: "%s", with: who)
        } else if wanted[0] == "camera" {
            title = CallsTheme.string("ask_title_camera", fallback: "%s asks you to turn on your camera").replacingOccurrences(of: "%s", with: who)
        } else {
            title = CallsTheme.string("ask_title_microphone", fallback: "%s asks you to turn on your microphone").replacingOccurrences(of: "%s", with: who)
        }

        let secondary: String?

        if stuck == .blocked {
            secondary = CallsTheme.string("open_settings", fallback: "Open Settings")
        } else if stuck != nil {
            secondary = nil
        } else {
            secondary = wanted.contains("camera")
                ? CallsTheme.string("device_preview", fallback: "Preview")
                : CallsTheme.string("test_microphone", fallback: "Test Microphone")
        }

        let content = CallsAskPrompt.Content(
            title: title,
            steps: stuckOn.flatMap { device in stuck.map { CallsAsks.stuckSteps(device, $0) } } ?? [],
            camera: (stuckOn ?? wanted[0]) == "camera",
            primary: stuck == nil
                ? CallsTheme.string("ask_turn_on", fallback: "Turn On")
                : CallsTheme.string("ask_try_again", fallback: "Try Again"),
            secondary: secondary
        )

        if let shown = askPrompt, shown.content == content {
            shown.busy = askTrying
            return
        }

        let announce = askPrompt?.content.title != title

        askPrompt?.removeFromSuperview()
        hideJoinPrompt()

        let prompt = CallsAskPrompt(content)
        prompt.busy = askTrying
        prompt.onPrimary = { [weak self] in self?.turnOnAsked(wanted) }
        prompt.onSecondary = { [weak self] in
            guard let self else { return }

            if stuck == .blocked {
                if let settings = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(settings) }
            } else {
                self.showDevices(start: wanted.count > 1 ? .both : wanted[0] == "camera" ? .camera : .microphone)
            }
        }
        prompt.onNotNow = { [weak self] in self?.notNowAsked(wanted) }
        prompt.place(in: view, above: dock, announce: announce)
        askPrompt = prompt
    }

    private func hideAskPrompt() {
        askPrompt?.removeFromSuperview()
        askPrompt = nil
    }

    /// Turn On: the system asked for each device it never asked about, then each it allows turned on as the dock's button
    /// does; a device it refuses, or there is none of, is said on the card and to whoever asked.
    private func turnOnAsked(_ wanted: [String]) {
        guard !askTrying else { return }

        askTrying = true
        askPrompt?.busy = true

        CallsAsks.check(wanted) { [weak self] stuck in
            guard let self else { return }

            self.askTrying = false
            self.askStuck = stuck

            for (device, why) in stuck { self.tell(device, why.rawValue) }
            for device in wanted where stuck[device] == nil {
                if device == "camera" { self.turnCameraOn() } else { self.turnMicrophoneOn() }
            }

            self.drawAskPrompt()
        }
    }

    private func notNowAsked(_ wanted: [String]) {
        for device in wanted {
            tell(device, "not_now")

            for ask in asks where ask.device == device {
                CallsEngine.shared.dismissAsk(id: ask.id, device: ask.device)
            }
        }

        hideAskPrompt()
    }

    /// The answer, to each who asked for the device.
    private func tell(_ device: String, _ answer: String) {
        for ask in asks where ask.device == device { tellAsk(ask, answer) }
    }

    private func tellAsk(_ ask: CallsTurnOnAsk, _ answer: String) {
        guard askTold[ask.id + "|" + ask.device, default: []].insert(answer).inserted else { return }

        CallsEngine.shared.answerAsk(id: ask.id, device: ask.device, by: ask.by, answer: answer)
    }

    /// What the dock's microphone button does to turn it on.
    private func turnMicrophoneOn() {
        guard !microphoneOn, let button = muteButton else { return }

        button.isOn = false
        button.setIcon(CallsTheme.micIcon(muted: false))
        devices?.microphoneWillGoLive()
        onToggleMute?(false)
    }

    /// What the dock's camera button does to turn it on.
    private func turnCameraOn() {
        guard !cameraOn, let button = cameraButton else { return }

        button.isOn = false
        button.setIcon(CallsTheme.cameraIcon(on: true))

        guard let devices else {
            onToggleCamera?(true)
            return
        }

        devices.cameraWillGoLive { [weak self] in self?.onToggleCamera?(true) }
    }

    // MARK: A recording (CallsRecording)

    /// The group call's recording as the state names it (`recording`): nil for none, and in a call that is not a group
    /// call. Host Controls reads it for Start and Stop Recording.
    private(set) var recording: CallsRecording?
    private var recordingLate = CallsRecordingLate()
    private let recordingPill = CallsRecordingPill()
    /// Where REC stands: in the bar after the connection; in the connection's place at the bar's start, the connection
    /// stepping aside, where the dock at its smallest leaves no room beside both; at the top of the call, centred, where
    /// it leaves none even then, clear of every tile's name at the bottom of its tile. A moderator's REC, with Stop,
    /// beside a dock with Host Controls on a phone is the second; Starting recording… and Saving recording… on a phone,
    /// for their few seconds, the third.
    private enum RecordingPlace { case afterConnection, atStart, overBar }
    private var recordingPlace = RecordingPlace.afterConnection
    private var recordingAfterConnection: [NSLayoutConstraint] = []
    private var recordingAtStart: [NSLayoutConstraint] = []
    private var recordingAboveBar: [NSLayoutConstraint] = []
    /// The pill's width as last drawn, for the dock's room beside it.
    private var recordingPillWidth: CGFloat = 0
    private var recordingTimer: Timer?
    /// Until when "Saving recording…" stands after a stop.
    private var recordingSavingUntil: Date?
    private var recordingSavingTimer: Timer?
    private var recordingNotice: CallsRecordingNotice?
    private var recordingQuestion: CallsConfirm?
    private var recordingQuestionContent: [String] = []
    /// A moderator's confirm of Start or Stop, open while it fits: `start` or `stop`.
    private weak var recordingConfirm: CallsConfirm?
    private var recordingConfirming: String?
    /// The answers given on this screen, by the recording's id, until the engine says them back.
    private var recordingAnswers: [String: String] = [:]
    /// Recordings said to a screen reader as they started.
    private var recordingAnnounced: Set<String> = []

    private static let recordingGap: CGFloat = 8

    /// A recording is drawn over a group call that is joining, up or getting its connection back: someone who joins
    /// while it records hears of it with the join, before the room is up.
    private var recordingDrawn: Bool {
        isGroupCall && ["connecting", "in_progress", "reconnecting"].contains(phase)
    }

    /// What the dock leaves the pill in the bar beside the connection's own room: its width and the gap before it after
    /// the connection, what it takes more than the connection in the connection's place, and nothing over the bar.
    private var recordingRoom: CGFloat {
        guard groupBar, !recordingPill.isHidden else { return 0 }

        switch recordingPlace {
        case .afterConnection: return recordingPillWidth + Self.recordingGap
        case .atStart: return recordingPillWidth - CallsConnectionPill.size
        case .overBar: return 0
        }
    }

    /// REC stands in the connection's place, which steps aside for it.
    private var recordingTakesConnection: Bool {
        groupBar && !recordingPill.isHidden && recordingPlace == .atStart
    }

    private func applyRecording(_ state: [String: Any]) {
        var now = isGroupCall ? CallsRecording(state["recording"]) : nil

        if var shown = now, shown.answer.isEmpty, let given = recordingAnswers[shown.id] {
            shown.answer = given
            now = shown
        }

        recordingLate.see(connected: phase == "in_progress", recording: now)

        // Stopped: "Saving recording…" for a few seconds, then nothing.
        if now?.state == "stopping" {
            if recording?.state != "stopping" {
                recordingSavingUntil = Date().addingTimeInterval(CallsRecordingPill.savingSeconds)
                recordingSavingTimer?.invalidate()
                recordingSavingTimer = Timer.scheduledTimer(withTimeInterval: CallsRecordingPill.savingSeconds, repeats: false) { [weak self] _ in
                    self?.recordingSavingUntil = nil
                    self?.drawRecordingPill()
                }
            }
        } else {
            recordingSavingUntil = nil
            recordingSavingTimer?.invalidate()
            recordingSavingTimer = nil
        }

        // Said once to a screen reader, to everyone REC shows to, as it starts.
        if let now, now.state == "on", now.pillShown, recordingDrawn, !now.id.isEmpty, recordingAnnounced.insert(now.id).inserted {
            UIAccessibility.post(notification: .announcement, argument: CallsTheme.string("rec_recorded", fallback: "This call is being recorded."))
        }

        let changed = now != recording

        recording = now

        drawRecordingPill()
        drawRecordingNotice()
        drawRecordingQuestion()
        closeRecordingConfirm()

        if changed {
            // Host Controls' row turns over, and shows for whoever may record.
            drawHostControls()
            popover?.refresh()
        }
    }

    private func drawRecordingPill() {
        let saving = recordingSavingUntil.map { $0 > Date() } ?? false

        if groupBar, recordingDrawn {
            recordingPill.show(recording, saving: saving, narrow: view.bounds.width < 600)
        } else {
            recordingPill.show(nil, saving: false, narrow: false)
        }

        // The time, each second while it records.
        if !recordingPill.isHidden, recording?.state == "on" {
            if recordingTimer == nil {
                recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    self?.drawRecordingPill()
                }
            }
        } else {
            recordingTimer?.invalidate()
            recordingTimer = nil
        }

        let width = recordingPill.isHidden ? 0 : recordingPill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width

        // The dock fits itself beside it again, as wide as it is now.
        if width != recordingPillWidth {
            recordingPillWidth = width
            controlDiameter = 0
            view.setNeedsLayout()
        }

        placeRecordingPill()
    }

    /// The dock at its smallest, its controls at the 24 points applyControlMetrics steps them down to.
    private var dockNarrowest: CGFloat {
        let shown = dock.row.arrangedSubviews.filter { !$0.isHidden }
        let controls = shown.reduce(CGFloat(0)) { sum, control in
            sum + ((control as? CallsButton).map { CallsButton.stride(for: $0.tone, diameter: 24) } ?? control.bounds.width)
        }

        return controls + dock.row.spacing * CGFloat(max(0, shown.count - 1)) + dock.padding * 2
    }

    /// In the bar after the connection where the dock at its smallest leaves room for both; in the connection's place
    /// where it leaves room for REC alone; at the top of the call where it leaves none: REC is never left out for the dock.
    /// Decided from the dock at its smallest, never from its size now, which a redraw between two layouts reads before
    /// the dock has fitted itself to the last place.
    private func placeRecordingPill() {
        guard !recordingPill.isHidden else { return setRecordingPlace(.afterConnection) }

        let edges = view.safeAreaInsets.left + view.safeAreaInsets.right
        let room = view.bounds.width - edges - Self.barInset * 2 - recordingPillWidth - Self.barSpacing
        let narrowest = dockNarrowest

        setRecordingPlace(
            narrowest <= room - CallsConnectionPill.size - Self.recordingGap ? .afterConnection
                : narrowest <= room ? .atStart
                : .overBar
        )
    }

    private func setRecordingPlace(_ place: RecordingPlace) {
        guard place != recordingPlace else { return }

        NSLayoutConstraint.deactivate(recordingAfterConnection + recordingAtStart + recordingAboveBar)
        NSLayoutConstraint.activate(place == .afterConnection ? recordingAfterConnection : place == .atStart ? recordingAtStart : recordingAboveBar)
        recordingPlace = place

        // The dock's room beside it changed with it, and the connection steps aside or comes back.
        controlDiameter = 0
        view.setNeedsLayout()
    }

    /// The notice to everyone else, over the dock in the join notice's place, where the site tells people by a notice:
    /// the join notice and a moderator's ask wait under it.
    private func drawRecordingNotice() {
        guard recordingDrawn, let recording, recording.noticeShown else { return hideRecordingNotice() }

        let late = recordingLate.isLate(recording.id)
        let content = CallsRecordingNotice.Content(title: recording.noticeTitle(late: late), note: recording.noticeNote(late: late))

        if let shown = recordingNotice, shown.content == content { return }

        let announce = recordingNotice?.content.title != content.title
        let id = recording.id

        recordingNotice?.removeFromSuperview()
        hideAskPrompt()
        joinPrompt?.isHidden = true

        let notice = CallsRecordingNotice(content)

        notice.onSeen = { [weak self] in self?.answerRecording(id, "seen") }
        notice.onNever = { [weak self] in
            CallsEngine.shared.recordingNoticeNever()
            self?.answerRecording(id, "seen")
        }
        notice.place(in: view, above: dock, announce: announce)
        recordingNotice = notice
    }

    private func hideRecordingNotice() {
        guard let notice = recordingNotice else { return }

        notice.removeFromSuperview()
        recordingNotice = nil
        joinPrompt?.isHidden = false
        drawAskPrompt()
    }

    /// The question to everyone else where the site asks them to stay or leave (`ask`), or to agree with the microphone
    /// and camera off until they do (`muted`), over everything and answered before anything else: no tap outside it
    /// and no escape puts it away. Leave Call leaves as the dock's way out does.
    private func drawRecordingQuestion() {
        guard recordingDrawn, let recording, recording.asking else { return hideRecordingQuestion() }

        let note = recording.watchNote
        let content = [recording.questionLead, note, recording.questionYes]

        if recordingQuestion != nil, recordingQuestionContent == content { return }

        recordingQuestion?.dismiss()

        // Whatever was open goes first: the question is answered before anything else.
        closePopover()
        hideDevices()
        hidePanel()
        confirm?.finish(false)

        let id = recording.id
        let question = CallsConfirm(
            title: CallsTheme.string("rec_title", fallback: "This call is being recorded"),
            message: recording.questionLead,
            confirm: recording.questionYes,
            danger: false,
            cancel: CallsTheme.string("rec_leave", fallback: "Leave Call"),
            note: note.isEmpty ? nil : note,
            badge: CallsIcons.record,
            dismissible: false
        ) { [weak self] yes in
            guard let self else { return }

            self.recordingQuestion = nil
            self.recordingQuestionContent = []

            if yes {
                self.answerRecording(id, "agreed")
            } else {
                self.onEnd?()
            }
        }

        question.place(in: view)
        recordingQuestion = question
        recordingQuestionContent = content
    }

    private func hideRecordingQuestion() {
        recordingQuestion?.dismiss()
        recordingQuestion = nil
        recordingQuestionContent = []
    }

    private func answerRecording(_ id: String, _ answer: String) {
        recordingAnswers[id] = answer
        CallsEngine.shared.answerRecording(id: id, answer: answer)
    }

    /// A moderator's Start Recording or Stop Recording, asked first on the call (the web's RecordingDialog), from Host
    /// Controls or REC's Stop. Start asks with how everyone is told and the admin's settings; Stop with when it can be
    /// watched.
    func askRecording(_ which: String) {
        guard let recording, recording.can else { return }
        guard which == "start" ? recording.state == "off" : recording.state == "on" else { return }

        let question: CallsConfirm

        if which == "start" {
            question = CallsConfirm(
                title: CallsTheme.string("rec_start_question", fallback: "Start recording?"),
                message: recording.toldLead,
                confirm: CallsTheme.string("rec_start", fallback: "Start Recording"),
                danger: false,
                cancel: CallsTheme.string("rec_cancel", fallback: "Cancel"),
                note: CallsTheme.string("rec_stops_when", fallback: "It stops when the call ends, or when you press REC beside the call controls."),
                facts: recording.facts(audio: !isVideoCall),
                badge: CallsIcons.record
            ) { [weak self] yes in
                self?.recordingConfirming = nil

                guard yes else { return }

                CallsEngine.shared.startRecording { ok, error in
                    guard !ok else { return }

                    DispatchQueue.main.async {
                        self?.showError(error ?? CallsTheme.string("rec_start_failed", fallback: "The recording could not be made."))
                    }
                }
            }
        } else {
            question = CallsConfirm(
                title: CallsTheme.string("rec_stop_question", fallback: "Stop recording?"),
                message: recording.readyLead,
                confirm: CallsTheme.string("rec_stop_recording", fallback: "Stop Recording"),
                danger: true,
                cancel: CallsTheme.string("rec_cancel", fallback: "Cancel"),
                badge: CallsIcons.record
            ) { [weak self] yes in
                self?.recordingConfirming = nil

                guard yes else { return }

                CallsEngine.shared.stopRecording { ok, error in
                    guard !ok else { return }

                    DispatchQueue.main.async {
                        self?.showError(error ?? CallsTheme.string("rec_stop_failed", fallback: "The recording could not be stopped."))
                    }
                }
            }
        }

        showConfirm(question)
        recordingConfirm = question
        recordingConfirming = which
    }

    /// A confirm that no longer fits closes: Start once it records or stops, Stop once it no longer records.
    private func closeRecordingConfirm() {
        guard let which = recordingConfirming else { return }

        guard let open = recordingConfirm else {
            recordingConfirming = nil
            return
        }

        let state = recording?.state ?? "off"
        let gone = recording == nil || !recordingDrawn
            || ( which == "start" ? state != "off" : state != "on" )

        if gone {
            open.dismiss()
            recordingConfirming = nil
        }
    }

    // MARK: A moderator's toasts

    /// In the stage's top end corner, under the call's header, over the tiles and under the menus.
    private(set) lazy var hostToasts: CallsHostToasts = {
        let toasts = CallsHostToasts()
        toasts.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(toasts, aboveSubview: grid)

        NSLayoutConstraint.activate([
            toasts.topAnchor.constraint(equalTo: grid.topAnchor, constant: 14),
            toasts.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            toasts.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            toasts.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            toasts.bottomAnchor.constraint(lessThanOrEqualTo: dock.topAnchor, constant: -12),
        ])

        // 320 wide where it fits, every toast the column's width, as the web's.
        let wide = toasts.widthAnchor.constraint(equalToConstant: 320)
        wide.priority = .defaultHigh
        wide.isActive = true

        return toasts
    }()

    /// The roster or the phase moved: what a moderator is told of it.
    private func drawHostToasts() {
        let moderator = inRoom && isGroupCall && canModerate

        guard moderator || hostToastsMade else { return }

        hostToastsMade = true
        hostToasts.update(roster, connected: phase == "in_progress", moderator: moderator)
    }

    private var hostToastsMade = false

    // MARK: A question on the call

    private weak var confirm: CallsConfirm?

    /// A question in a card of the call's own over everything on it (CallsConfirm), never a system alert. One at a
    /// time: a new one answers the old one no.
    func showConfirm(_ question: CallsConfirm) {
        confirm?.finish(false)
        closePopover()
        hideDevices()
        hidePanel()

        question.place(in: view)
        confirm = question
    }

    /// Device Settings over the call, above the dock (CallsDevices): `start` runs its tests at once, as the join
    /// notice's Preview does, and `traffic` gives a call between two its counts. Called again, it closes.
    func showDevices(start: CallsDevices.Start? = nil, traffic: (() -> (received: Int, sent: Int))? = nil) {
        if let open = devices {
            open.close()
            if start == nil { return }
        }

        closePopover()
        hidePanel()
        hideJoinPrompt()

        let devices = CallsDevices(context: { [weak self] in self?.devicesContext }, traffic: traffic)

        devices.onClose = { [weak self, weak devices] in
            guard let self = self, self.devices === devices else { return }
            self.devices = nil
            // A moderator's ask comes back once the settings go.
            self.drawAskPrompt()
        }

        devices.onChooseCamera = { [weak self] front in
            guard let self = self else { return }

            if self.cameraOn {
                if front != self.frontCamera { self.onFlipCamera?() }
            } else {
                CallsEngine.shared.preferCamera(front: front)
            }
        }

        self.devices = devices
        devices.place(in: view, above: dock)
        // Where the settings stand above the dock, so a moderator's ask steps aside while they are open.
        drawAskPrompt()

        if let start = start { devices.start(start) }
    }

    func hideDevices() {
        devices?.close()
    }

    /// What Device Settings reads of the call now.
    private var devicesContext: CallsDevices.Context {
        let me = roster.first { $0.isLocal }

        return CallsDevices.Context(
            video: isVideoCall,
            group: isGroupCall,
            cameraOn: cameraOn,
            microphoneOn: microphoneOn,
            micHeld: micLocked,
            mayPublish: canPublish,
            front: frontCamera,
            peerName: lastName,
            // The roster's reading of this side, or where there is no roster (a call between two) the engine's.
            sendingLevel: microphoneOn ? (me.map { $0.audioLevel } ?? CallsEngine.shared.microphoneLevel()) : nil,
            talkingMuted: false
        )
    }

    // MARK: The moderator's menus

    private var popover: CallsPopover?
    /// What the open menu is for: `room`, or the identity of the person whose menu it is.
    private var popoverKey: String?
    private var popoverClosedAt = Date.distantPast

    /// Everyone in the room now, as the menus read them.
    var people: [CallsRoomParticipant] { roster }

    // MARK: Spotlight for Everyone and Pin for Me

    /// Who a moderator put on the main tiles for everyone, by identity, in the order they were spotlighted: the
    /// engine's state's `spotlight` in a group video call (CallsSpotlight), nobody elsewhere.
    private(set) var spotlight: [String] = []

    /// This user's own pins (Pin for Me), by identity, in the order they were pinned: on the main tiles while nobody
    /// is in the spotlight. This phone's alone, kept for the call.
    private(set) var pinnedForMe: [String] = []

    /// Pin for Me on or off for someone, from their tile's pin or their menu.
    func togglePinForMe(_ identity: String) {
        guard roster.contains(where: { $0.identity == identity }) else { return }

        pinnedForMe = CallsSpotlight.toggled(pinnedForMe, identity)
        CallsLog.write("pin for me: \(identity) \(pinnedForMe.contains(identity) ? "pinned" : "unpinned")\(spotlight.isEmpty ? "" : ", waiting for the spotlight")")
        drawSpotlight()
        showRoomInCorner()
    }

    /// The spotlight and the pins as the grid and an open menu draw them.
    private func drawSpotlight() {
        grid.spotlight = spotlight
        grid.pinned = pinnedForMe
        popover?.refresh()
    }

    /// The spotlight from the engine's state: only a group video call has main tiles, and a call over has no pins.
    private func applySpotlight(_ state: [String: Any]) {
        let next = isGroupCall && isVideoCall ? (state["spotlight"] as? [String] ?? []) : []

        if phase == "idle" { pinnedForMe = [] }

        guard next != spotlight || grid.pinned != pinnedForMe else { return }

        if next != spotlight {
            CallsLog.write("spotlight: \(next.isEmpty ? "nobody" : next.joined(separator: ", "))")
        }

        spotlight = next
        drawSpotlight()
        showRoomInCorner()
    }

    /// Where Host Controls opens: its button, while the dock shows it.
    var hostControlsAnchor: UIView? {
        guard let button = hostControlsButton, !button.isHidden else { return nil }

        return button
    }

    /// Where a person's menu opens: the ⋯ on their tile, or the tile.
    func personAnchor(_ identity: String) -> UIView? {
        grid.manageAnchor(identity)
    }

    /// A moderator's menu at its button, or closed if that one is open: as on the web, a second press on the
    /// button that opened it closes it. `anchor` is asked every frame where the button is now, nil once it is gone.
    func togglePopover(
        key: String,
        anchor: @escaping () -> UIView?,
        side: CallsPopover.Side,
        align: CallsPopover.Align,
        width: CGFloat,
        room: Bool,
        content: @escaping () -> ( CallsPopover.Head, [ CallsPopover.Entry ] )?
    ) {
        if popoverKey == key {
            closePopover()
            return
        }

        closePopover()
        hidePanel()
        hideDevices()

        let popover = CallsPopover( anchor: anchor, side: side, align: align, width: width, room: room, content: content )

        popover.onClose = { [weak self, weak popover] in
            guard let self, self.popover === popover else { return }

            self.popover = nil
            self.popoverKey = nil
            self.popoverClosedAt = Date()
            self.drawModerating()
        }

        self.popover = popover
        self.popoverKey = key
        popover.place( in: view )
        drawModerating()
    }

    func closePopover() {
        popover?.close()
    }

    /// The tile whose menu is open is outlined, and Host Controls latched while its own is.
    private func drawModerating() {
        grid.moderating = popoverKey == "room" ? nil : popoverKey
        drawHostControls()
    }

    /// Host Controls for a moderator in a room: latched while its menu is open, amber while a room rule holds
    /// (everyone muted, the room locked, broadcast mode), as the web's dock draws it.
    private func drawHostControls() {
        guard let button = hostControlsButton else { return }

        let engine = CallsEngine.shared

        // Once the room is up, as the rest of the dock past Show Chat. For anyone who may record the call too, whose
        // Start Recording is there (the web's roomModerated).
        button.isHidden = !( inRoom && isGroupCall && ( canModerate || recording?.can == true ) && phase == "in_progress" )

        if popoverKey == "room" {
            button.tone = .latch
            button.isOn = true
        } else if engine.roomMuted || engine.roomLocked || callMode == "broadcast" {
            button.tone = .warning
            button.isOn = true
        } else {
            button.tone = .control
            button.isOn = false
        }

        if button.isHidden, popoverKey == "room" { closePopover() }
    }

    // MARK: The call's status line

    private var statusLineTimer: Timer?

    /// `.bm-group-call-status`: a line of glass at the top of the call, centred, for what the call has to say for a
    /// moment.
    private lazy var statusLine: UIView = {
        let holder = UIView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.backgroundColor = UIColor( white: 0, alpha: 0.55 )
        holder.layer.cornerRadius = 12
        holder.layer.cornerCurve = .continuous
        holder.layer.borderWidth = 1
        holder.layer.borderColor = UIColor( white: 1, alpha: 0.08 ).cgColor
        holder.isUserInteractionEnabled = false
        holder.isHidden = true

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont( ofSize: 14, weight: .medium )
        label.textColor = UIColor( white: 1, alpha: 0.8 )
        label.textAlignment = .center
        label.numberOfLines = 0
        label.tag = 1
        holder.addSubview( label )

        view.addSubview( holder )

        NSLayoutConstraint.activate( [
            label.topAnchor.constraint( equalTo: holder.topAnchor, constant: 10 ),
            label.bottomAnchor.constraint( equalTo: holder.bottomAnchor, constant: -10 ),
            label.leadingAnchor.constraint( equalTo: holder.leadingAnchor, constant: 14 ),
            label.trailingAnchor.constraint( equalTo: holder.trailingAnchor, constant: -14 ),
            holder.topAnchor.constraint( equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14 ),
            holder.centerXAnchor.constraint( equalTo: view.centerXAnchor ),
            holder.leadingAnchor.constraint( greaterThanOrEqualTo: view.leadingAnchor, constant: 14 ),
            holder.trailingAnchor.constraint( lessThanOrEqualTo: view.trailingAnchor, constant: -14 ),
            holder.widthAnchor.constraint( lessThanOrEqualToConstant: 420 ),
        ] )

        return holder
    }()

    func showStatusLine( _ text: String, seconds: TimeInterval ) {
        ( statusLine.viewWithTag( 1 ) as? UILabel )?.text = text
        statusLine.isHidden = false
        view.bringSubviewToFront( statusLine )
        UIAccessibility.post( notification: .announcement, argument: text )

        statusLineTimer?.invalidate()
        statusLineTimer = Timer.scheduledTimer( withTimeInterval: seconds, repeats: false ) { [weak self] _ in
            self?.statusLine.isHidden = true
        }
    }

    /// `.bm-placeholder-participant-lost-message`: the same glass chip as the
    /// peer notice with a 24pt `wifiOff` beside the words, at the top of the
    /// stage and centred, which is where the stylesheet puts it.
    private func buildLostNotice() {
        lostNotice.translatesAutoresizingMaskIntoConstraints = false
        lostNotice.backgroundColor = UIColor(white: 0, alpha: 0.55)
        lostNotice.layer.cornerRadius = 12
        lostNotice.layer.borderWidth = 1
        lostNotice.layer.borderColor = UIColor(white: 1, alpha: 0.08).cgColor
        lostNotice.isHidden = true

        lostNoticeIcon.color = .white
        lostNoticeIcon.translatesAutoresizingMaskIntoConstraints = false

        lostNoticeText.translatesAutoresizingMaskIntoConstraints = false
        lostNoticeText.font = .systemFont(ofSize: 13)
        lostNoticeText.textColor = .white
        lostNoticeText.numberOfLines = 0
        lostNoticeText.textAlignment = .natural
        lostNoticeText.text = CallsTheme.string("reconnecting", fallback: "The other side lost connection")

        lostNotice.addSubview(lostNoticeIcon)
        lostNotice.addSubview(lostNoticeText)

        view.addSubview(lostNotice)

        NSLayoutConstraint.activate([
            lostNoticeIcon.leadingAnchor.constraint(equalTo: lostNotice.leadingAnchor, constant: 14),
            lostNoticeIcon.centerYAnchor.constraint(equalTo: lostNotice.centerYAnchor),
            lostNoticeIcon.widthAnchor.constraint(equalToConstant: 24),
            lostNoticeIcon.heightAnchor.constraint(equalToConstant: 24),

            lostNoticeText.leadingAnchor.constraint(equalTo: lostNoticeIcon.trailingAnchor, constant: 10),
            lostNoticeText.trailingAnchor.constraint(equalTo: lostNotice.trailingAnchor, constant: -14),
            lostNoticeText.topAnchor.constraint(equalTo: lostNotice.topAnchor, constant: 10),
            lostNoticeText.bottomAnchor.constraint(equalTo: lostNotice.bottomAnchor, constant: -10),

            lostNotice.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            lostNotice.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            lostNotice.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            lostNotice.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            lostNotice.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
    }

    private func buildPeerNotice() {
        // `.bm-placeholder-no-source-message` / `.bm-placeholder-participant-muted-message`:
        // black at 0.55 behind a hairline of white at 0.08, the card radius,
        // 10 by 14 of padding, and a 20pt glyph ten points from the words.
        peerNotice.translatesAutoresizingMaskIntoConstraints = false
        peerNotice.backgroundColor = UIColor(white: 0, alpha: 0.55)
        peerNotice.layer.cornerRadius = 12
        peerNotice.layer.borderWidth = 1
        peerNotice.layer.borderColor = UIColor(white: 1, alpha: 0.08).cgColor
        peerNotice.isHidden = true

        peerNoticeIcon.color = .white

        peerNoticeText.translatesAutoresizingMaskIntoConstraints = false
        peerNoticeText.font = .systemFont(ofSize: 13)
        peerNoticeText.textColor = .white
        peerNoticeText.numberOfLines = 0
        peerNoticeText.textAlignment = .natural

        peerNotice.addSubview(peerNoticeIcon)
        peerNotice.addSubview(peerNoticeText)

        view.addSubview(peerNotice)

        NSLayoutConstraint.activate([
            peerNoticeIcon.centerYAnchor.constraint(equalTo: peerNotice.centerYAnchor)
        ])

        // The sentence, for the placeholder: a 20pt glyph fourteen in, ten
        // from the words, and ten above and below them.
        peerNoticeFull = [
            peerNoticeIcon.leadingAnchor.constraint(equalTo: peerNotice.leadingAnchor, constant: 14),
            peerNoticeIcon.widthAnchor.constraint(equalToConstant: 20),
            peerNoticeIcon.heightAnchor.constraint(equalToConstant: 20),

            peerNoticeText.leadingAnchor.constraint(equalTo: peerNoticeIcon.trailingAnchor, constant: 10),
            peerNoticeText.trailingAnchor.constraint(equalTo: peerNotice.trailingAnchor, constant: -14),
            peerNoticeText.topAnchor.constraint(equalTo: peerNotice.topAnchor, constant: 10),
            peerNoticeText.bottomAnchor.constraint(equalTo: peerNotice.bottomAnchor, constant: -10)
        ]

        // Over a picture: the chip a room already draws for the same fact — a
        // 24pt disc with the glyph inset five, and no words, because over a
        // picture they say nothing the glyph does not.
        peerNoticeCompact = [
            peerNotice.widthAnchor.constraint(equalToConstant: 24),
            peerNotice.heightAnchor.constraint(equalToConstant: 24),

            peerNoticeIcon.centerXAnchor.constraint(equalTo: peerNotice.centerXAnchor),
            peerNoticeIcon.widthAnchor.constraint(equalToConstant: 14),
            peerNoticeIcon.heightAnchor.constraint(equalToConstant: 14)
        ]

        NSLayoutConstraint.activate(peerNoticeFull)

        // Over a picture it is a chip in the top corner, where the stylesheet
        // puts it; with no picture the placeholder card carries it, under the
        // name and the status.
        peerNoticeCorner = [
            peerNotice.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            peerNotice.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            peerNotice.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -14)
        ]

        peerNoticeCentred = [
            peerNotice.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            peerNotice.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 24),
            peerNotice.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            peerNotice.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16)
        ]

        NSLayoutConstraint.activate(peerNoticeCentred)
    }

    private func buildControls() {
        let mute = CallsButton(icon: CallsTheme.micIcon(muted: false), tone: .medium) { [weak self] in
            guard let self = self, let button = self.muteButton else { return }

            button.isOn = !button.isOn
            button.setIcon(CallsTheme.micIcon(muted: button.isOn))

            // Device Settings' test lets go of the microphone before the call sends it.
            if !button.isOn { self.devices?.microphoneWillGoLive() }

            self.onToggleMute?(button.isOn)
        }

        let camera = CallsButton(icon: CallsTheme.cameraIcon(on: true), tone: .medium) { [weak self] in
            guard let self = self, let button = self.cameraButton else { return }

            button.isOn = !button.isOn
            button.setIcon(CallsTheme.cameraIcon(on: !button.isOn))

            let on = !button.isOn

            // Device Settings' preview lets go of the camera before the call opens it.
            guard on, let devices = self.devices else {
                self.onToggleCamera?(on)
                return
            }

            devices.cameraWillGoLive { [weak self] in self?.onToggleCamera?(on) }
        }

        let flip = CallsButton(icon: CallsIcons.switchCamera) { [weak self] in
            self?.onFlipCamera?()
        }

        let speaker = CallsButton(icon: CallsIcons.speaker, tone: .latch) { [weak self] in
            guard let self = self, let button = self.speakerButton else { return }

            button.isOn = !button.isOn
            button.setIcon(button.isOn ? CallsIcons.speaker : CallsIcons.speakerOff)

            self.onToggleSpeaker?(button.isOn)
        }

        // Host Controls, for a moderator in a room: the room's rules in a menu
        // above the dock, as the web's dock has them. A person's own actions
        // are on the ⋯ of their tile. `onPeople` is what the engine opens it
        // with (CallsModeration.show).
        let host = CallsButton(icon: CallsIcons.shield) { [weak self] in
            self?.onPeople?()
        }

        host.isHidden = true
        host.accessibilityLabel = CallsTheme.string("host_controls", fallback: "Host Controls")
        hostControlsButton = host

        #if DEBUG
        // Nobody can gather thirty-two people to see whether the grid holds,
        // so a long press here fills the room with people who are not there.
        // Debug builds only — this cannot reach a customer's app.
        host.addGestureRecognizer(
            UILongPressGestureRecognizer(target: self, action: #selector(peopleHeld(_:)))
        )
        #endif

        // A viewer in a broadcast room cannot publish anything; putting a hand
        // up is the whole of what they can do, so it gets a control of its own
        // rather than living two taps deep in the participants sheet.
        let hand = CallsButton(icon: CallsIcons.raiseHand, tone: .latch) { [weak self] in
            guard let self = self else { return }

            CallsEngine.shared.groupAdmin(action: self.handRaised ? "lower_own_hand" : "raise_hand")
        }

        hand.isHidden = true
        hand.accessibilityLabel = CallsTheme.string("raise_hand", fallback: "Raise Hand")
        handButton = hand

        let share = CallsButton(icon: CallsIcons.screenShare, tone: .latch) { [weak self] in
            guard let self = self, let button = self.shareButton else { return }

            button.isOn = !button.isOn
            button.setIcon(button.isOn ? CallsIcons.screenShareOff : CallsIcons.screenShare)

            self.onToggleScreenShare?(button.isOn)
        }

        share.isHidden = true
        share.accessibilityLabel = CallsTheme.string("share_screen", fallback: "Share Screen")
        shareButton = share

        // Add Person, latched while its list is open: only where the host gives the screen whom to add
        // (CallsAddPerson), once the call is up.
        let add = CallsButton(icon: CallsIcons.userPlus, tone: .latch) { [weak self] in
            self?.showAddPerson()
        }

        add.isHidden = true
        add.accessibilityLabel = CallsTheme.string("add_person", fallback: "Add Person")
        addPersonButton = add

        // Device Settings, the engine's way where it gives one (onSettings, which calls showDevices), the screen's own
        // otherwise.
        let settings = CallsButton(icon: CallsIcons.settings) { [weak self] in
            guard let self = self else { return }

            if let onSettings = self.onSettings {
                onSettings()
            } else {
                self.showDevices()
            }
        }

        settings.isHidden = true
        settings.accessibilityLabel = CallsTheme.string("device_settings", fallback: "Device Settings")
        settingsButton = settings

        // Only where the device can actually do it, and only in a video call:
        // a button that opens a black square is worse than no button.
        let pip = CallsButton(icon: CallsIcons.pip, tone: .latch) { [weak self] in
            self?.onPictureInPicture?()
        }

        pip.isHidden = true
        pip.accessibilityLabel = CallsTheme.string("picture_in_picture", fallback: "Picture In Picture")
        pipButton = pip

        // Answering is part of the same dock, as it is on the web, and it is
        // simply not there once the call has been picked up.
        let answer = CallsButton(icon: CallsIcons.phone, tone: .answer) { [weak self] in
            self?.onAnswer?()
        }

        answer.isHidden = true
        answer.accessibilityLabel = CallsTheme.string("answer", fallback: "Answer")
        answerButton = answer

        let end = CallsButton(icon: CallsIcons.phone, tone: .danger) { [weak self] in
            guard let self = self else { return }

            // While it is still ringing this is the decline, afterwards it is
            // the hang up. One button, because that is what the row has room
            // for and what the web puts there.
            if self.phase == "ringing_in" {
                self.onDecline?()
            } else {
                self.onEnd?()
            }
        }

        // The handset tilted into the hang-up glyph, the same turn the
        // stylesheet gives it.
        end.rotateGlyph(degrees: 135)
        end.accessibilityLabel = CallsTheme.string("end_call", fallback: "End Call")
        endButton = end

        // Every control says what it is. VoiceOver read the whole dock as
        // "button" before this, and the device rig had to tap them by
        // coordinate for want of anything to select by. The words are the
        // web's own, from the same translation store.
        mute.accessibilityLabel = CallsTheme.string("disable_microphone", fallback: "Disable Microphone")
        camera.accessibilityLabel = CallsTheme.string("enable_camera", fallback: "Enable Camera")
        flip.accessibilityLabel = CallsTheme.string("switch_camera", fallback: "Switch Camera")
        speaker.accessibilityLabel = CallsTheme.string("speaker", fallback: "Speaker")

        // The microphone while a moderator keeps it off, in the dock where it
        // was: the silenced glyph on the amber of a restriction someone else
        // holds, rather than gone. A press says why again. The web's
        // lockedMicItem.
        let locked = CallsButton(icon: CallsIcons.silenced, tone: .warning) { [weak self] in
            self?.showModeratorNotice(muted: true)
        }

        locked.isOn = true
        locked.isHidden = true
        locked.accessibilityLabel = CallsTheme.string("moderator_muted_you", fallback: "A moderator muted your microphone.")

        muteButton = mute
        lockedMicButton = locked
        cameraButton = camera
        flipButton = flip
        speakerButton = speaker

        // Show Chat / Hide Chat, the web's `.wplus-toggle-chat`: the conversation the call stands in, beside it or not.
        // Only where the host gives a chat toggle (`onToggleChat`), on its latch while the chat shows (`setChatShown`).
        let chat = CallsButton(icon: CallsIcons.thread, tone: .latch) { [weak self] in
            self?.onToggleChat?()
        }

        chat.isHidden = onToggleChat == nil
        chatButton = chat
        drawChatButton()

        for control in [answer, chat, settings, flip, camera, mute, locked, speaker, pip, share, add, hand, host, end] {
            dock.row.addArrangedSubview(control)
        }

        // By the ids a host arranges them by (CallsPieces), in this order.
        ourControls = zip(
            [ "answer", "chat", "settings", "flip", "camera", "mute", "speaker", "pip", "share", "add", "hand", "host", "end" ],
            [ answer, chat, settings, flip, camera, mute, speaker, pip, share, add, hand, host, end ] as [UIView]
        ).map { CallsControl(id: $0.0, view: $0.1) }

        view.addSubview(dock)

        dockCentred = dock.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        dockAtEnd = dock.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Self.barInset)

        NSLayoutConstraint.activate([
            dockCentred!,
            dock.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            dock.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            // At the bottom, as the web's dock, off the home indicator.
            dock.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
        ])

        // At the start of the bar and level with the dock, as the web's bar
        // under a group call starts with it.
        view.addSubview(connectionPill)
        connectionPill.isHidden = true

        NSLayoutConstraint.activate([
            connectionPill.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Self.barInset),
            connectionPill.centerYAnchor.constraint(equalTo: dock.centerYAnchor),
        ])

        // REC after the connection, level with the dock (the web's RecordingPill), in the connection's place where the
        // dock leaves no room beside both, or at the top of the call where it leaves none even then: it is how everyone
        // in the call knows, so it is never left out (placeRecordingPill).
        view.addSubview(recordingPill)
        recordingPill.onStop = { [weak self] in self?.askRecording("stop") }

        recordingAfterConnection = [
            recordingPill.leadingAnchor.constraint(equalTo: connectionPill.trailingAnchor, constant: Self.recordingGap),
            recordingPill.centerYAnchor.constraint(equalTo: dock.centerYAnchor),
        ]
        recordingAtStart = [
            recordingPill.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Self.barInset),
            recordingPill.centerYAnchor.constraint(equalTo: dock.centerYAnchor),
        ]
        // The top of the call, centred, where the status line stands for a moment: just over the bar it covered the name
        // of the last tile.
        recordingAboveBar = [
            recordingPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            recordingPill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
        ]
        NSLayoutConstraint.activate(recordingAfterConnection)

        // A group call's tiles stop above the bar, as the web's do: its grid is
        // the stage less the bar (group-video-grid.tsx), 8 pixels of the bar's
        // padding and the tile's own gutter between the last tile and the dock.
        // The bar never goes away there, so nothing moves the tiles. A call
        // between two keeps its picture under the dock, which a tap puts away.
        gridToFloor = grid.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        gridAboveBar = grid.bottomAnchor.constraint(equalTo: dock.topAnchor, constant: -Self.barGap)
        gridToFloor?.isActive = true

        applyControlMetrics()
        applyGridMetrics()
    }

    /// The web's bar: 14 from the stage's edges, and the gap between its badge
    /// and the dock.
    private static let barInset: CGFloat = 14
    private static let barSpacing: CGFloat = 10
    /// Between the last tile and the dock: the bar's top padding, 8, and the
    /// pixel its 64-pixel minimum leaves over the dock it centres.
    private static let barGap: CGFloat = 9

    /// A group call has the web's group bar: the badge at its start, the dock at
    /// its end, and the grid above it. A call between two has its dock in the
    /// middle, over the picture.
    private var groupBar: Bool { isGroupCall && inRoom }

    private func applyBarLayout() {
        let bar = groupBar

        guard dockAtEnd?.isActive != bar else { return }

        if bar {
            dockCentred?.isActive = false
            gridToFloor?.isActive = false
            dockAtEnd?.isActive = true
            gridAboveBar?.isActive = true
        } else {
            dockAtEnd?.isActive = false
            gridAboveBar?.isActive = false
            dockCentred?.isActive = true
            gridToFloor?.isActive = true
        }

        controlDiameter = 0
        view.setNeedsLayout()
    }

    /// The stylesheet steps its controls down as the stage narrows, and the
    /// stage here is the whole screen. Read on every layout so a rotation or
    /// an iPad split is followed rather than frozen at launch.
    ///
    /// Smaller still when the row would not fit beside what the bar holds: the
    /// web folds what will not fit into More, and the controls here come down
    /// two points at a time instead, as Android's do.
    private func applyControlMetrics() {
        let shown = dock.row.arrangedSubviews.filter { !$0.isHidden }
        let edges = view.safeAreaInsets.left + view.safeAreaInsets.right
        let room = groupBar
            ? view.bounds.width - edges - Self.barInset * 2 - CallsConnectionPill.size - Self.barSpacing - recordingRoom
            : view.bounds.width - 24
        // Less the dock's own padding.
        let available = room - dock.padding * 2

        func rowWidth(_ side: CGFloat) -> CGFloat {
            shown.reduce(CGFloat(0)) { sum, control in
                sum + ((control as? CallsButton).map { CallsButton.stride(for: $0.tone, diameter: side) } ?? control.bounds.width)
            } + dock.row.spacing * CGFloat(max(0, shown.count - 1))
        }

        var diameter = CallsButton.diameter(for: view.bounds.width)

        while diameter > 24 && rowWidth(diameter) > available { diameter -= 2 }

        guard diameter != controlDiameter else { return }

        controlDiameter = diameter

        for control in dock.row.arrangedSubviews.compactMap({ $0 as? CallsButton }) {
            control.setDiameter(diameter)
        }
    }

    // MARK: - The chat beside the call

    /// The conversation the call stands in, shown or hidden by the host's own way of it (Show Chat / Hide Chat in
    /// the dock). Nil: no chat beside the call, and no button.
    var onToggleChat: (() -> Void)? {
        didSet { drawChatButton() }
    }

    private var chatButton: CallsButton?
    private var chatShown = false

    /// Whether the chat shows beside the call now: the button wears the dock's on look and says Hide Chat.
    func setChatShown(_ shown: Bool) {
        chatShown = shown
        drawChatButton()
    }

    private func drawChatButton() {
        guard let button = chatButton else { return }

        button.isHidden = onToggleChat == nil
        button.isOn = chatShown
        button.accessibilityLabel = chatShown
            ? CallsTheme.string("hide_chat", fallback: "Hide Chat")
            : CallsTheme.string("show_chat", fallback: "Show Chat")
        button.accessibilityValue = chatShown ? "1" : "0"
    }

    // MARK: - What it shows

    func show(name: String, avatar url: String, video: Bool) {
        isVideoCall = video

        // Nothing clears the card here. It used to, on the reasoning that a
        // presentation is a fresh look at the call — and on the phone that
        // wiped every message before anyone could read one: answering a call
        // raises the error while the peer is built and then presents the
        // screen again, in that order, and `present` reuses the screen it
        // already has. The card belongs to the screen, and the screen is
        // dropped when the call ends, so there is nothing left to clear.

        if !name.isEmpty { lastName = name }

        let shown = name.isEmpty ? lastName : name

        nameLabel.text = shown.isEmpty
            ? CallsTheme.string("unknown_caller", fallback: "Unknown")
            : shown
        initials.text = CallsAvatars.initials(of: shown)

        guard url != avatarURL else { return }

        avatarURL = url
        avatarImage.image = nil
        avatarImage.isHidden = true

        guard !url.isEmpty else { return }

        CallsAvatars.load(url) { [weak self] image in
            guard let self = self, self.avatarURL == url, let image = image else { return }

            self.avatarImage.image = image
            self.avatarImage.isHidden = false
        }
    }

    /// Every state the call can be in, drawn from the same dictionary the
    /// bundle gets. Called on every change, so it must be cheap and total —
    /// anything it does not set stays as it was and drifts.
    func apply(state: [String: Any]) {
        let previousPhase = phase

        phase = state["phase"] as? String ?? "idle"
        isGroupCall = state["group"] as? Bool ?? false
        callMode = state["callMode"] as? String ?? "participatory"
        waitingForPlace = state["waiting"] as? Bool ?? false

        let local = state["local"] as? [String: Any] ?? [:]
        let muted = local["muted"] as? Bool ?? false
        let camera = local["camera"] as? Bool ?? false

        microphoneOn = !muted
        cameraOn = camera
        frontCamera = local["front"] as? Bool ?? true

        peerOnline = state["peerOnline"] as? Bool ?? false

        drawPresence()
        drawSelfStage()

        muteButton?.isOn = muted
        muteButton?.setIcon(CallsTheme.micIcon(muted: muted))

        // `isOn` is the stylesheet's `bm-enable-video`: the state where the
        // camera is *not* running and the button turns it back on.
        cameraButton?.isOn = !camera
        cameraButton?.setIcon(CallsTheme.cameraIcon(on: camera))

        let ringingIn = phase == "ringing_in"

        answerButton?.isHidden = !ringingIn
        speakerButton?.isHidden = ringingIn

        // Both are offered whatever the call was placed as: a camera can be
        // switched on in the middle of an audio call, and the web offers it
        // there too. Turning it round is only worth offering once there is
        // something to turn.
        cameraButton?.isHidden = false
        flipButton?.isHidden = !camera

        // A control that says the opposite of what it does is worse than one
        // that says nothing, so these follow the state they are in.
        muteButton?.accessibilityLabel = muted
            ? CallsTheme.string("enable_microphone", fallback: "Enable Microphone")
            : CallsTheme.string("disable_microphone", fallback: "Disable Microphone")

        cameraButton?.accessibilityLabel = camera
            ? CallsTheme.string("disable_camera", fallback: "Disable Camera")
            : CallsTheme.string("enable_camera", fallback: "Enable Camera")

        endButton?.accessibilityLabel = ringingIn
            ? CallsTheme.string("reject", fallback: "Reject")
            : CallsTheme.string("end_call", fallback: "End Call")

        // Nobody rings a room and nobody answers one, so a group call never
        // shows the answer control whatever the phase says.
        if isGroupCall { answerButton?.isHidden = true }

        // A call getting its connection back is still the call: the web keeps
        // every control while the other side reads as lost, and this took
        // three of them away every time the network blinked.
        let running = phase == "in_progress" || phase == "reconnecting"

        pipButton?.isHidden = !pipOffered

        settingsButton?.isHidden = !running

        // Sharing needs the broadcast extension, which is a build-time thing:
        // a button that opens a picker with nothing in it is worse than none.
        shareButton?.isHidden = !running || !canShareScreen

        // The icon with the state, not only with the tap: a share the room
        // carries, or one stopped from the system's bar, left the button
        // offering to start what was already running.
        let sharing = local["screen"] as? Bool ?? false

        shareButton?.isOn = sharing
        shareButton?.setIcon(sharing ? CallsIcons.screenShareOff : CallsIcons.screenShare)

        applyPublishControls()
        applyRoomControls()

        // A room rule that flipped (everyone muted, the lock, broadcast mode)
        // turns over in an open Host Controls too.
        popover?.refresh()

        // Device Settings says what is live now, and a test ends once the call sends its device.
        devices?.refresh()

        // Device Settings is a call's: it goes with the call, and so does a question about it.
        if phase == "idle" || phase == "ringing_in" {
            hideDevices()
            confirm?.finish(false)
        }

        // The join notice: shown on the first connect, gone once a device is on or the call drops.
        considerJoinPrompt(from: previousPhase)

        if joinPrompt != nil, microphoneOn || cameraOn || phase != "in_progress" {
            hideJoinPrompt()
        }

        // A recording: REC in the bar, the notice over the dock, the question to stay or leave over everything. Before
        // the asks, whose card waits while the notice shows.
        applyRecording(state)

        // A moderator's asks: the card over the dock, the answers' toasts, and the asks answered by a device turned on.
        applyAsks(state)

        // Who a moderator put in the spotlight for everyone: the main tiles, ahead of this user's own pins.
        applySpotlight(state)

        // This side's own reconnect starts the moderator's count again: who is there on its return is not news.
        if phase != previousPhase { drawHostToasts() }

        let peer = state["peer"] as? [String: Any] ?? [:]
        let peerKnown = peer["known"] as? Bool ?? false
        // "The other side" is a two-person idea. In a room each tile carries
        // its own struck-through microphone and there is no one person the
        // banner could be about.
        let peerMicOff = !inRoom && phase == "in_progress" && peerKnown && !(peer["microphone"] as? Bool ?? false)

        let cameraOn = peer["camera"] as? Bool ?? false
        let screenOn = peer["screen"] as? Bool ?? false

        if peerKnown != peerStateKnown || cameraOn != peerCameraOn || screenOn != peerScreenOn {
            // A share that has just started is what the person wants to see.
            if screenOn && !peerScreenOn { swapped = false }

            peerStateKnown = peerKnown
            peerCameraOn = cameraOn
            peerScreenOn = screenOn

            drawPeerVideo()

            // What is drawn decides what size is asked for, so the wish has to
            // be said again whenever it changes.
            onViewChanged?()
        }

        peerNotice.isHidden = !peerMicOff

        // The web says "and camera" only where there is no picture to explain
        // it, and says the microphone alone in the corner of one there is.
        let peerHasPicture = cameraOn || screenOn

        peerNoticeText.text = (!peerHasPicture && isVideoCall)
            ? CallsTheme.string(
                "peer_mic_and_camera_off",
                fallback: "The microphone and camera not enabled at the other side"
            )
            : CallsTheme.string(
                "peer_mic_off",
                fallback: "The microphone is not enabled at the other side"
            )

        NSLayoutConstraint.deactivate(peerHasPicture ? peerNoticeCentred : peerNoticeCorner)
        NSLayoutConstraint.activate(peerHasPicture ? peerNoticeCorner : peerNoticeCentred)

        // Over a picture the chip carries the glyph alone, as the grid's does.
        peerNoticeText.isHidden = peerHasPicture

        NSLayoutConstraint.deactivate(peerHasPicture ? peerNoticeFull : peerNoticeCompact)
        NSLayoutConstraint.activate(peerHasPicture ? peerNoticeCompact : peerNoticeFull)

        peerNotice.backgroundColor = peerHasPicture
            ? CallsTheme.recording.withAlphaComponent(235.0 / 255.0)
            : UIColor(white: 0, alpha: 0.55)

        peerNotice.layer.cornerRadius = peerHasPicture ? 12 : 12
        peerNotice.layer.borderWidth = peerHasPicture ? 0 : 1

        // The connection is being got back.
        // `.bm-placeholder-participant-lost-message` is the web's answer: the
        // same glass chip, at the top and centred, with the call's clock still
        // running under the name — where this used to take the clock's place
        // whenever there was no picture over it. It names whose connection it
        // is: the other side's was said of this side's own bad network too.
        lostNotice.isHidden = !(phase == "reconnecting" && !inRoom)

        lostNoticeText.text = (state["trouble"] as? String) == "self"
            ? CallsTheme.string("reconnecting_self", fallback: "Reconnecting...")
            : CallsTheme.string("reconnecting", fallback: "The other side lost connection")

        statusLabel.text = statusText()

        // A room's line comes and goes with what it has to say, a wait for a
        // place starting or ending included, not with the next roster alone.
        if inRoom { drawIdentity(picture: hasPicture) }

        applyBarLayout()
        drawConnectionPill()

        if phase == "in_progress" || phase == "reconnecting" {
            // The engine has owned the start since the call went up, so the
            // figure is taken from there rather than from the first frame this
            // screen saw: a screen that timed itself started again from zero
            // every time the call came back, while the other side carried on.
            let elapsed = Double(state["durationMs"] as? Int ?? 0) / 1000
            let started = Date().addingTimeInterval(-elapsed)

            if connectedAt == nil || abs(started.timeIntervalSince(connectedAt!)) > 1 {
                connectedAt = started
            }

            if durationTimer == nil { startDuration() }
        } else {
            connectedAt = nil
            durationTimer?.bmInvalidate()
            durationTimer = nil
        }

        // A dock tapped away comes back whenever the call is not simply
        // running — trouble included, so ending it is always one tap away.
        if phase != "in_progress" { restoreControls() }

        // The host's own pieces, for the phase now (CallsPieces).
        arrangeDock()
        drawStagePiece()

        // The question to stay or leave is answered before anything else, over whatever came up since.
        if let question = recordingQuestion { view.bringSubviewToFront(question) }

        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    // MARK: - The host's pieces

    /// Ours, by the ids a host arranges them by, as buildControls made them.
    private var ourControls: [CallsControl] = []
    private var stagePiece: UIView?

    /// A host's own button the dock already shows under the same id, kept: the pieces run on every change of the call,
    /// many a second while it connects, and a host that makes its button each time (as `CallControl(id:…)` in `controls`
    /// reads) would otherwise have the whole dock taken down and built again each time. The kept one takes the new one's
    /// label, icon, latch and action.
    private func keepDocked(_ control: CallsControl, _ docked: [UIView]) -> CallsControl {
        guard let fresh = control.view as? CallsButton, !ourControls.contains(where: { $0.view === fresh }),
              let id = fresh.accessibilityIdentifier,
              let kept = docked.first(where: { $0 !== fresh && $0.accessibilityIdentifier == id }) as? CallsButton,
              kept.tone == fresh.tone else { return control }
        kept.setIcon(fresh.icon)
        kept.isOn = fresh.isOn
        kept.accessibilityLabel = fresh.accessibilityLabel
        kept.action = fresh.action
        return CallsControl(id: control.id, view: kept)
    }

    /// The dock in the host's order, its own buttons among ours; hanging up stays last, whatever it answers.
    private func arrangeDock() {
        guard let arrange = CallsPiecesStore.current.controls, !ourControls.isEmpty else { return }
        let end = ourControls.first { $0.id == "end" }
        let row = dock.row
        let docked = row.arrangedSubviews
        let shown = ( arrange(ourControls, phase).filter { $0.id != "end" } + ( end.map { [ $0 ] } ?? [] ) ).map { keepDocked($0, docked) }
        guard docked != shown.map( \.view ) else { return }
        for view in row.arrangedSubviews {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for control in shown { row.addArrangedSubview(control.view) }
        // A button of the host's is sized as ours are, at the dock's size now.
        controlDiameter = 0
        applyControlMetrics()
    }

    /// The host's view over the stage of a call between two, under the dock.
    private func drawStagePiece() {
        let own = isGroupCall ? nil : CallsPiecesStore.current.stage?(phase)
        guard own !== stagePiece else { return }
        stagePiece?.removeFromSuperview()
        stagePiece = own
        guard let own else { return }
        own.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(own, belowSubview: dock)
        NSLayoutConstraint.activate([
            own.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            own.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            own.topAnchor.constraint(equalTo: view.topAnchor),
            own.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// The host's own status line, where it gives one (CallsPieces).
    private func pieceStatus() -> String? {
        CallsPiecesStore.current.status?(phase, Int(Date().timeIntervalSince(connectedAt ?? Date())))
    }

    private func statusText() -> String {
        if let own = pieceStatus() { return own }

        // The mesh is keeping the room's join waiting for a place in the call,
        // which the web's call screen says in place of "Connecting...".
        if waitingForPlace, phase == "connecting" || (isGroupCall && phase != "in_progress") {
            return CallsTheme.string("waiting_for_place", fallback: "Waiting for a free place in the call...")
        }

        // A room is joined, not dialled: it has no ring and nothing is
        // "calling". The web's group call says it is connecting with the
        // spinner at the start of its bar alone (`connectionPill`), and its
        // status line is for the call's notices: nothing to say here.
        if isGroupCall, phase != "in_progress" {
            return ""
        }

        switch phase {
        case "ringing_out":
            return CallsTheme.string("calling", fallback: "Calling…")
        case "ringing_in":
            // The web's card names the kind of call that is coming in, and so
            // does this. `incoming_call` stays in the table for app binaries
            // older than 10 Sep, which still ask for it.
            return isVideoCall
                ? CallsTheme.string("incoming_video_call", fallback: "Incoming Video Call")
                : CallsTheme.string("incoming_audio_call", fallback: "Incoming Audio Call")
        case "connecting":
            return CallsTheme.string("connecting", fallback: "Connecting...")
        // The clock goes on through trouble, as the web's does; the chip says
        // what the trouble is.
        case "reconnecting", "in_progress":
            return durationText()
        default:
            return ""
        }
    }

    private func startDuration() {
        durationTimer?.bmInvalidate()

        durationTimer = Timer.bmScheduled(every: 1, repeats: true) { [weak self] in
            // Stopped rather than merely hidden in a room: the roster can
            // arrive after the phase has already started this, and a clock
            // nobody is shown is a second of work a call does not need.
            guard let self = self, self.phase == "in_progress" || self.phase == "reconnecting", !self.inRoom else { return }

            self.statusLabel.text = self.pieceStatus() ?? self.durationText()
        }
    }

    private func durationText() -> String {
        let seconds = Int(Date().timeIntervalSince(connectedAt ?? Date()))
        let minutes = seconds / 60
        let hours = minutes / 60

        // Padded both sides, the way the web's `msToTime` writes it, so the
        // figure does not jump a character wide as it counts.
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes % 60, seconds % 60)
        }

        return String(format: "%02d:%02d", minutes, seconds % 60)
    }

    // MARK: - Video

    /// One of the other side's two pictures. Which of them is on the stage is
    /// decided in `drawPeerVideo`, not here, so a screen share arriving does
    /// not silently take the camera's place.
    func setRemoteVideo(source: CallsSource, track: LKRTCVideoTrack?) {
        if source == .screenShare {
            remoteScreen = track

            // A share that has stopped hands the stage back. One that starts
            // does the same, but that is the announcement's to say, not the
            // track's — the track has been there since the call was
            // negotiated.
            if track == nil { swapped = false }
        } else {
            remoteVideo = track
        }

        drawPeerVideo()
        onViewChanged?()
    }

    private func drawPeerVideo() {
        // In a room the grid owns the screen and there is no one "remote" to
        // put on a stage, so a stray track must not raise it.
        if inRoom {
            detachPeerVideo()
            stage.isHidden = true
            roomStage.track = nil
            roomStage.isHidden = true
            roomPeerChip.track = nil
            peerChipHolder.isHidden = true
            roomOptimizing.show(false, picture: nil)
            roomStalled.show(blurred: false, notice: false)
            roomCornerStalled.show(blurred: false, notice: false)
            return
        }

        let onStage = stageTrack
        let inCorner = cornerTrack

        if stageShowing !== onStage {
            stageShowing?.remove(stage)
            stageShowing = onStage
            onStage?.add(stage)
        }

        if cornerShowing !== inCorner {
            cornerShowing?.remove(peerChip)
            cornerShowing = inCorner
            inCorner?.add(peerChip)
        }

        // The same two places for a two-person call carried by a room, drawn
        // through LiveKit's own views.
        let roomOnStage = roomStageTrack
        let roomInCorner = roomCornerTrack

        if roomStage.track !== roomOnStage { roomStage.track = roomOnStage }
        if roomPeerChip.track !== roomInCorner { roomPeerChip.track = roomInCorner }

        // Fitted, never filled. The web's stage is `object-fit: contain` for
        // a camera as much as for a screen — cropping the sides off someone
        // to fill a phone-shaped hole is not showing them, and a screen
        // cropped is a document read from the middle. Only the corner
        // thumbnails fill, which is what the web does too.
        stage.videoContentMode = .scaleAspectFit

        stage.isHidden = onStage == nil
        roomStage.isHidden = roomOnStage == nil
        peerChip.isHidden = inCorner == nil
        roomPeerChip.isHidden = roomInCorner == nil
        peerChipHolder.isHidden = inCorner == nil && roomInCorner == nil

        // The direct path's corner takes its shape from its first frame
        // (`videoView(_:didChangeVideoSize:)`); a room's says what it is.
        shapeRoomCorner()

        drawSelfStage()

        applyRoomOptimizing()
        applyRoomStalled()

        // The web draws the avatar, the name and the timer only where it has
        // no picture to draw instead; over a live camera it draws nothing at
        // all, and neither does this. A camera changing codec is a picture on
        // its way back, under its placeholder: not the camera turned off.
        let picture = onStage != nil || roomOnStage != nil || roomOptimizing.isUp

        avatar.isHidden = picture
        drawPresence()
        drawIdentity(picture: picture)

        let showing = roomOnStage != nil
            ? (roomOnStage === roomPeerScreen ? "their screen (room)" : "their camera (room)")
            : (onStage == nil ? "avatar" : (stageIsScreen ? "their screen" : "their camera"))

        CallsLog.write("screen: stage=\(showing) corner=\(inCorner == nil && roomInCorner == nil ? "none" : "their second picture") self=\(localVideo == nil && roomLocalVideo == nil ? "none" : "camera")")

        hasPicture = picture

        CallsPip.shared.show(onStage)

        if !inRoom { CallsPip.shared.showRoom(roomOnStage) }
    }

    /// Who spoke last in a group call: the corner window stays on them through a silence.
    private var cornerLast: String?

    /// Whether a group call has a corner window now.
    private var roomInCorner = false

    /// A group call's corner window, as the web's useGroupPip: a video call has it all through, an audio call only while
    /// someone else shares a screen. It follows the call: a new speaker, a screen shared or stopped.
    private func showRoomInCorner() {
        let was = roomInCorner
        let people = roster.map(CallsPipFocus.Person.init)
        let chosen = CallsPipFocus.offered(people, video: isVideoCall)
            ? CallsPipFocus.pick(people, first: spotlight + pinnedForMe, last: cornerLast)
            : nil
        let focus = roster.first { $0.identity == chosen }

        if focus?.speaking == true { cornerLast = focus?.identity }
        if !inRoom { cornerLast = nil }

        roomInCorner = focus != nil

        pipButton?.isHidden = !pipOffered

        guard inRoom || was else { return }

        CallsPip.shared.showRoom(focus?.screen ?? focus?.video, who: focus.map { CallsPip.Who(name: $0.name, avatar: $0.avatar) })
    }

    /// Whether the dock offers Picture In Picture.
    private var pipOffered: Bool {
        (phase == "in_progress" || phase == "reconnecting")
            && CallsPip.isSupported
            && (inRoom ? roomInCorner : hasPicture)
    }

    /// A room carries neither the name nor the clock.
    ///
    /// The web's group call is the grid and its controls and nothing else, and
    /// this drew the conversation name and a running timer in a strip across
    /// the top of it — the one place the three platforms disagreed about what
    /// a group call looks like. The name goes outright; the status stays only
    /// while the room is still being joined, because "Connecting…" is the
    /// whole of what the screen has to say then, and goes with the rest once
    /// the call is up.
    private func drawIdentity(picture: Bool) {
        defer { applyGridMetrics() }

        guard !inRoom else {
            nameLabel.isHidden = true
            // Only for something to say: waiting for a place, or the host's
            // own line.
            statusLabel.isHidden = phase == "in_progress" || statusText().isEmpty

            return
        }

        nameLabel.isHidden = picture
        statusLabel.isHidden = picture
    }

    /// How big each of the other side's pictures is actually drawn, in device
    /// pixels, so it is sent at the size it is shown rather than at 1080 into
    /// a thumbnail.
    ///
    /// Zero means "not shown", which switches that source off at the far end:
    /// a source with no box, a screen the app is not on, or a picture that is
    /// simply not there. Picture in Picture counts as shown, because it is.
    func viewHint() -> [String: Int] {
        var hint: [String: Int] = [:]

        if remoteVideo != nil {
            hint["camera"] = CallsShapes.viewStep(boxHeight(for: remoteVideo))
        }

        if remoteScreen != nil {
            // A screen is asked for at the exact pixel it is drawn at, not at
            // a rung: text is either sharp or it is not.
            hint["screen_share"] = CallsShapes.exactStep(boxHeight(for: remoteScreen))
        }

        return hint
    }

    private func boxHeight(for track: LKRTCVideoTrack?) -> Int {
        guard let track = track, !inRoom else { return 0 }

        // Backgrounded is not shown — except in the corner window, which is
        // the whole point of it.
        if backgrounded, !CallsPip.shared.isActive { return 0 }

        // The corner is hidden by its holder, not by the renderer inside it,
        // so asking the renderer would report a size for a chip nobody can
        // see.
        let box: UIView
        let visible: Bool

        if track === stageTrack {
            box = stage
            visible = !stage.isHidden
        } else if track === cornerTrack {
            box = peerChip
            visible = !peerChipHolder.isHidden
        } else {
            return 0
        }

        guard visible, box.window != nil else { return 0 }

        let bounds = box.bounds

        guard bounds.width > 0, bounds.height > 0 else { return 0 }

        // Contained in its box: the shorter of the box's height and the height
        // the box's width allows at the picture's proportions. The web assumes
        // 9:16 until it knows better and so does this.
        let shown = min(bounds.height, bounds.width * CallsScreen.defaultAspect)

        return Int(ceil(shown * UIScreen.main.scale))
    }

    private static let defaultAspect: CGFloat = 9.0 / 16.0

    private func detachPeerVideo() {
        stageShowing?.remove(stage)
        cornerShowing?.remove(peerChip)
        stageShowing = nil
        cornerShowing = nil
    }

    /// A share goes on the stage the moment it starts, because that is what
    /// the other person meant by sharing it; the swap button undoes that.
    /// The other side's camera, if the other side says it is sending one.
    private var shownRemoteVideo: LKRTCVideoTrack? {
        peerStateKnown && peerCameraOn ? remoteVideo : nil
    }

    private var shownRemoteScreen: LKRTCVideoTrack? {
        peerStateKnown && peerScreenOn ? remoteScreen : nil
    }

    private var stageIsScreen: Bool {
        shownRemoteScreen != nil && !swapped
    }

    private var stageTrack: LKRTCVideoTrack? {
        stageIsScreen ? shownRemoteScreen : shownRemoteVideo ?? shownRemoteScreen
    }

    private var cornerTrack: LKRTCVideoTrack? {
        guard remoteScreen != nil, remoteVideo != nil else { return nil }

        return stageIsScreen ? shownRemoteVideo : shownRemoteScreen
    }

    /// The other side's two pictures, when a two-person call runs through a
    /// room. Kept apart the way the direct path keeps them — a shared screen
    /// on the stage with their camera in the corner, and the swap between
    /// them — where the room used to hand over one picture, whichever was
    /// subscribed last, and blank the stage when either went away. With a
    /// roster the grid draws everyone instead (`drawPeerVideo`).
    func setRoomPeerVideo(camera: VideoTrack?, screen: VideoTrack?) {
        // The same two pictures again. The roster comes several times a
        // second while anyone in the room talks, and each one redrew the
        // stage and wrote it to the call's trace, which in a room call was
        // most of the trace. The direct path redraws for a track that changed
        // and nothing else, and so does this; a corner whose picture has only
        // now said how big it is still takes its shape.
        guard camera !== roomPeerCamera || screen !== roomPeerScreen else {
            shapeRoomCorner()

            return
        }

        // A share that has just started is what the person wants to see.
        if screen != nil && roomPeerScreen == nil { swapped = false }

        roomPeerCamera = camera
        roomPeerScreen = screen

        drawPeerVideo()
    }

    /// The other side's camera changing codec, as the room holds it: from the
    /// word until the frame that ends it (`CallsCameraSwitch`).
    func setRoomPeerOptimizing(_ optimizing: Bool) {
        guard roomPeerOptimizing != optimizing else { return }

        roomPeerOptimizing = optimizing

        drawPeerVideo()
    }

    /// The placeholder over the stage while the other side's camera changes
    /// codec, wherever their camera is the one on the stage: not over a
    /// shared screen there.
    private func applyRoomOptimizing() {
        let onStage = roomStageTrack
        let showsScreen = onStage != nil && onStage === roomPeerScreen

        roomOptimizing.show(!inRoom && roomPeerOptimizing && !showsScreen, picture: avatarImage.image)
    }

    /// What of the other side's stopped arriving, as the room judges it
    /// (`CallsStallWatch`), or nothing more.
    func setRoomPeerStalled(_ stalled: CallsStalled?) {
        guard roomPeerStalled != stalled else { return }

        roomPeerStalled = stalled

        applyRoomStalled()
    }

    /// Their camera's last frame blurred wherever it is, on the stage or in
    /// the corner, and their screen's too when nothing of theirs arrives,
    /// which the call says as "The other side lost connection" (the engine's
    /// `lost`). "Video interrupted", with why, while their camera alone
    /// stopped and the stage shows it, as the web's stage does: never over a
    /// shared screen, a still one sending nothing, nor under the placeholder
    /// of a camera changing codec.
    private func applyRoomStalled() {
        let stall = inRoom ? nil : roomPeerStalled
        let onStage = roomStageTrack
        let inCorner = roomCornerTrack
        let cameraOnStage = onStage != nil && onStage === roomPeerCamera

        roomStalled.show(blurred: onStage != nil && (stall == .all || (stall == .video && cameraOnStage)),
                         notice: stall == .video && cameraOnStage && !roomOptimizing.isUp)
        roomCornerStalled.show(blurred: inCorner != nil && (stall == .all || (stall == .video && inCorner === roomPeerCamera)),
                               notice: false)
    }

    /// Their camera away for a moment while it changes codec: it keeps its
    /// place, under the placeholder, rather than being taken for off.
    private var roomPeerCameraHeld: Bool {
        roomPeerOptimizing && roomPeerCamera == nil
    }

    /// The corner a room's second picture sits in, shaped like that picture
    /// once it says what size it is, and until then like what it is.
    private func shapeRoomCorner() {
        guard !inRoom, cornerTrack == nil, let corner = roomCornerTrack else { return }

        let size = corner.dimensions.map { CGSize(width: CGFloat($0.width), height: CGFloat($0.height)) }
            ?? (corner === roomPeerScreen ? CGSize(width: 16, height: 9) : CGSize(width: 3, height: 4))

        shape(peerChipHolder, ratio: &peerChipRatio, size: size)
    }

    private var roomStageTrack: VideoTrack? {
        if let screen = roomPeerScreen, !swapped { return screen }

        // Their camera's place, swapped onto the stage or with no screen to
        // share it: while it changes codec the stage keeps it, under the
        // placeholder, and the screen stays in the corner, as the web's stage
        // does for its `primaryVideo === 'camera'`.
        if roomPeerCameraHeld { return nil }

        return roomPeerCamera ?? roomPeerScreen
    }

    private var roomCornerTrack: VideoTrack? {
        guard let screen = roomPeerScreen else { return nil }

        // The camera held on the stage leaves the corner to the screen; held
        // in the corner, the corner waits for it.
        if roomPeerCameraHeld { return roomStageTrack === screen ? nil : screen }

        guard let camera = roomPeerCamera else { return nil }

        return roomStageTrack === screen ? camera : screen
    }

    private func applyPublishControls() {
        guard !canPublish else {
            // Total both ways: the screen outlives the call it was built for,
            // and a control hidden for a room a person was a viewer in would
            // otherwise stay hidden for the next call.
            muteButton?.isHidden = micLocked
            lockedMicButton?.isHidden = !micLocked

            return
        }

        muteButton?.isHidden = true
        lockedMicButton?.isHidden = true
        cameraButton?.isHidden = true
        flipButton?.isHidden = true
        shareButton?.isHidden = true
    }

    /// Everyone in a room call.
    func setRoster(_ participants: [CallsRoomParticipant]) {
        inRoom = !participants.isEmpty
        roster = participants

        if !inRoom { closePopover() }

        // A group call is a grid, and a grid does not fit in a PiP window, so
        // the window shows one person of it, as the web's does.
        if inRoom { hasPicture = false }

        showRoomInCorner()

        // A viewer in broadcast mode has nothing to publish, so the controls
        // that would publish it are not drawn — the web hides the same ones.
        canPublish = participants.first { $0.isLocal }?.canPublish ?? true

        let locked = participants.first { $0.isLocal }?.micMuted ?? false

        // A moderator muting this side, or letting it unmute, is said for a
        // few seconds: the locked button alone said nothing of who did it.
        if micLockKnown, locked != micLocked {
            showModeratorNotice(muted: locked)
        }

        micLocked = locked
        // Not from the tile a host draws for this side while the room is
        // joined, which knows no rule yet: a newcomer to a muted room is not
        // told a moderator just muted them.
        micLockKnown = inRoom && phase != "connecting"
        handRaised = participants.first { $0.isLocal }?.handRaised ?? false

        applyPublishControls()
        applyRoomControls()

        // An audio room is a list of people on the web, not a wall of empty
        // rectangles. Only a group audio call: the two-person room a failed
        // direct call is moved into never reaches the grid at all.
        grid.audioRoom = isGroupCall && !isVideoCall
        grid.broadcastRoom = isGroupCall && callMode == "broadcast"

        // Pin for Me on a group video call's tiles. Someone who left is unpinned, so coming back they are a tile like
        // the others.
        grid.pinsOffered = isGroupCall && isVideoCall
        pinnedForMe = CallsSpotlight.kept(pinnedForMe, people: participants)
        grid.pinned = pinnedForMe

        grid.show(participants)

        // The stage is a two-person idea. Once there is a roster the grid
        // replaces all of it, avatar included.
        if inRoom {
            stage.isHidden = true
            roomStage.isHidden = true
            chipHolder.isHidden = true
            avatar.isHidden = true
            drawPresence()
        }

        // The status moves out of the middle and into the strip above the
        // grid, and back again if this turns out to be a two-person room after
        // all.
        applyIdentityMetrics()

        // Here rather than only on the next state, because the roster is what
        // decides this is a room: without it the name and the clock stay on
        // screen until something else happens to redraw them.
        drawIdentity(picture: hasPicture)

        statusLabel.text = statusText()

        // An open menu says what is on now: a person muted, a hand lowered,
        // someone gone (their menu closes).
        popover?.refresh()

        // A microphone a moderator holds, or one's own level, in Device Settings.
        devices?.refresh()

        // A viewer has nothing to turn on.
        if !canPublish { hideJoinPrompt() }

        // A raised hand and who joined, for a moderator.
        drawHostToasts()

        // The roster is what makes the call a room.
        applyBarLayout()
        drawConnectionPill()
    }

    /// The controls a room has and a direct call does not, and the ones it
    /// takes away. The web's own conditions, one for one.
    private func applyRoomControls() {
        drawHostControls()

        // A group *audio* room is an audio room. The camera in a direct audio
        // call can be switched on half way through and the web offers it; in a
        // room that would publish video into a room nobody is watching video
        // in, and the web offers no camera there at all.
        if isGroupCall && !isVideoCall {
            cameraButton?.isHidden = true
            flipButton?.isHidden = true
        }

        // Raising a hand is the one thing a viewer in a broadcast room can do,
        // and the only condition the web draws the button on.
        let asking = isGroupCall && callMode == "broadcast" && !canPublish && !canModerate && CallsEngine.shared.offersAct("hand")

        handButton?.isHidden = !asking
        handButton?.isOn = handRaised
        handButton?.accessibilityLabel = handRaised
            ? CallsTheme.string("lower_hand", fallback: "Lower Hand")
            : CallsTheme.string("raise_hand", fallback: "Raise Hand")

        // A room is left rather than hung up, and the web says so with a door
        // rather than a handset. Both ways round, because the host keeps one
        // screen for the process and a private call after a group call would
        // otherwise still be offering the door.
        endButton?.setIcon(isGroupCall ? CallsIcons.logout : CallsIcons.phone)
        endButton?.rotateGlyph(degrees: isGroupCall ? 0 : 135)

        if isGroupCall {
            endButton?.accessibilityLabel = CallsTheme.string("exit_chat", fallback: "Exit Chat")
        }

        // Until its room is up, a group call's dock is the web's: Show Chat and
        // the way out, as it joins and while it reconnects (the web offers the
        // rest under `connectionState === 'connected'`). The room takes no
        // microphone or camera meanwhile, so their buttons would do nothing.
        // Last, over what each rule above put back.
        if isGroupCall && phase != "in_progress" {
            for button in [settingsButton, muteButton, lockedMicButton, cameraButton, flipButton, speakerButton, pipButton, shareButton, handButton, hostControlsButton] {
                button?.isHidden = true
            }
        }

        drawAddPerson()
    }

    /// A group call's connection at the start of its bar, as the web's: the
    /// spinner while the room connects or reconnects, the dot once it is up.
    /// Not where a host's own dock leaves it no room beside it.
    private func drawConnectionPill() {
        let shown = groupBar && ["connecting", "reconnecting", "in_progress"].contains(phase)

        // REC beside it, in its place, or at the top of the call where the dock leaves it no room.
        defer { placeRecordingPill() }

        guard shown else {
            connectionPill.isHidden = true
            connectionPill.reset()

            return
        }

        connectionPill.show(phase: phase, lost: roster.first { $0.isLocal }?.lost ?? false)
        // It steps aside for REC, which takes its place where the dock leaves no room beside both.
        connectionPill.isHidden = connectionPill.frame.insetBy(dx: -Self.barSpacing, dy: 0).intersects(dock.frame) || recordingTakesConnection
    }

    /// Whether this side may moderate, as the room reported it.
    private var canModerate: Bool {
        roster.first { $0.isLocal }?.canAdmin ?? false
    }

    /// While a call with one person rings, and then no more: once the call is
    /// answered they are plainly there, and a group call is no one person's to
    /// be online. Never on its own either: the dot belongs to the avatar, and
    /// the avatar is put away the moment there is a picture to look at instead.
    private func drawPresence() {
        let ringing = phase == "ringing_out" || phase == "ringing_in"

        presenceDot.isHidden = avatar.isHidden || !peerOnline || !ringing || isGroupCall
    }

    /// While a call is still ringing and there is no picture from the other
    /// side, one's own camera fills the screen — which is what the web does
    /// and what every phone does. Once the call connects the other person
    /// takes the stage and this drops back to the corner chip.
    private func drawSelfStage() {
        let ringing = phase == "ringing_out" || phase == "ringing_in"
        let behind = ringing && !inRoom && stageTrack == nil && roomStageTrack == nil
        let wanted = behind ? localVideo : nil

        // A call the site put in a room rings with the room's camera, and it
        // went to the corner instead of behind the ring.
        let roomWanted: VideoTrack? = (behind && localVideo == nil) ? roomLocalVideo : nil

        if selfShowing !== wanted {
            selfShowing?.remove(selfStage)
            selfShowing = wanted
            wanted?.add(selfStage)
        }

        if roomSelfStage.track !== roomWanted { roomSelfStage.track = roomWanted }

        selfStage.isHidden = wanted == nil
        roomSelfStage.isHidden = roomWanted == nil
        selfScrim.isHidden = wanted == nil && roomWanted == nil

        // The same face twice, once behind and once in the corner, is not
        // parity with anything — and this has to be total, or the chip stays
        // hidden for the rest of the call once the other side arrives.
        chipHolder.isHidden = wanted != nil || roomWanted != nil || (localVideo == nil && roomLocalVideo == nil) || inRoom
    }

    /// A tile's height, from the shape of what it is drawing. Clamped, because
    /// a shared screen can be far wider or far taller than anything worth
    /// putting in a corner.
    private func shape(_ holder: UIView, ratio: inout NSLayoutConstraint?, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let wanted = min(max(size.height / size.width, 0.5), 2.0)

        if let existing = ratio, abs(existing.multiplier - wanted) < 0.01 { return }

        ratio?.isActive = false

        let made = holder.heightAnchor.constraint(equalTo: holder.widthAnchor, multiplier: wanted)

        made.isActive = true
        ratio = made

        view.layoutIfNeeded()
    }

    func setLocalVideo(_ track: LKRTCVideoTrack?) {
        if let previous = localVideo { previous.remove(chip) }

        localVideo = track

        // Your own tile is already in the grid; the chip would be a second
        // copy of your face.
        if inRoom {
            drawSelfStage()
            return
        }

        track?.add(chip)

        // `drawSelfStage()` owns whether the chip is up: while a call is still
        // ringing the same camera fills the screen instead.
        drawSelfStage()
    }

    /// The room's own camera in the corner.
    ///
    /// A direct call the server moved into a room keeps this two-person
    /// screen, and the direct capture that used to fill the chip stops when
    /// the room opens: the room had published the camera, and for the rest
    /// of the call nothing drew it.
    func setRoomLocalVideo(_ track: VideoTrack?) {
        roomLocalVideo = track
        roomChip.track = track
        roomChip.isHidden = track == nil
        chip.isHidden = track != nil

        // A phone camera is the phone's own shape; the fill crops the rest.
        if track != nil {
            shape(chipHolder, ratio: &chipRatio, size: CGSize(width: 3, height: 4))
        }

        drawSelfStage()
    }

    // MARK: - Tap to hide the controls

    #if DEBUG
    @objc private func peopleHeld(_ recogniser: UILongPressGestureRecognizer) {
        guard recogniser.state == .began else { return }

        CallsEngine.shared.cycleDebugRoster()
    }
    #endif

    @objc private func stageTapped() {
        // Said out loud, as Android says it. A tap that does nothing is
        // indistinguishable from a tap that never arrived, and the two have
        // opposite fixes.
        CallsLog.write("tap: room=\(inRoom) phase=\(phase) video=\(isVideoCall) stage=\(stageTrack != nil) controls=\(controlsVisible)")

        // A press outside a menu closes the menu and nothing more: the dock
        // stays where it is.
        guard popover == nil, Date().timeIntervalSince(popoverClosedAt) > 0.4 else { return }

        guard phase == "in_progress" else { return }

        // A group call's bar stays, as the web's does: its tiles stop above it,
        // so it covers nothing to get out of the way of.
        guard !groupBar else { return }

        // A two-person room has no stage track — the grid draws everybody and
        // the stage is hidden behind it — and its picture is as much a picture
        // as one on the stage.
        guard inRoom || (isVideoCall && stageTrack != nil) else { return }

        controlsVisible.toggle()

        let alpha: CGFloat = controlsVisible ? 1 : 0

        // Before the fade rather than after it. UIKit stops hit-testing a view
        // once its alpha is under 0.01, so a dock that has finished fading out
        // is already deaf — but for the fifth of a second it takes to get
        // there it is not, and a tap landing in that window presses whatever
        // is under the finger. Said outright so both platforms answer the same
        // way: the first tap on a hidden dock brings it back and presses
        // nothing.
        dock.isUserInteractionEnabled = controlsVisible

        UIView.animate(withDuration: 0.2) {
            self.dock.alpha = alpha
            self.connectionPill.alpha = alpha
            self.nameLabel.alpha = alpha
            self.statusLabel.alpha = alpha

            self.view.layoutIfNeeded()
        }
    }

    /// Every control back, whatever the last call left them at — the screen
    /// outlives the call it was built for, and a call that ended with the dock
    /// tapped away would otherwise hand the next one a hidden dock with
    /// nothing on screen to say why or how to get it back.
    private func restoreControls() {
        guard !controlsVisible else { return }

        controlsVisible = true

        dock.alpha = 1
        connectionPill.alpha = 1
        nameLabel.alpha = 1
        statusLabel.alpha = 1

        // Back in every sense: a dock that came back deaf is worse than one
        // that stayed away.
        dock.isUserInteractionEnabled = true
    }
}

/// The window the call lives in.
///
/// Above the app's own, so the call survives whatever the web view does, and
/// on the lock screen it is what CallKit brings up.
/// The renderers say what shape they are drawing, and the corner tiles take it.
extension CallsScreen: LKRTCVideoViewDelegate {
    func videoView(_ videoView: LKRTCVideoRenderer, didChangeVideoSize size: CGSize) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if videoView === self.chip {
                self.shape(self.chipHolder, ratio: &self.chipRatio, size: size)
            } else if videoView === self.peerChip {
                self.shape(self.peerChipHolder, ratio: &self.peerChipRatio, size: size)
            }
        }
    }
}

final class CallsScreenHost {
    static let shared = CallsScreenHost()

    private var window: UIWindow?
    private var framed: CGRect?
    private(set) var screen: CallsScreen?

    var isShowing: Bool { window != nil }

    /// Everything below touches a window, a view controller or a layer, and
    /// the callers are as often LiveKit's capture and room queues, or
    /// Capacitor's plugin queue, as they are the main thread. The hop lives
    /// here, once, instead of at sixteen call sites — which is what was
    /// missing when the first captured frame of a screen share walked from
    /// `render(frame:)` straight into `apply(state:)` and out through
    /// `setNeedsUpdateOfHomeIndicatorAutoHidden()`, and BoardServices trapped
    /// the process.
    ///
    /// Already on the main thread it runs inline, so nothing that used to
    /// happen before the next turn of the run loop now happens after it.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// A read whose answer the caller needs now rather than next turn. UIKit
    /// says only the main thread may ask, so off it this answers nil and the
    /// caller decides what to do — the alternative is the same trap in a
    /// quieter place.
    func read<T>(_ block: (CallsScreen) -> T) -> T? {
        guard Thread.isMainThread, let screen = screen else { return nil }

        return block(screen)
    }

    /// Whether the page has a box for the call. The dock's chat button means
    /// "show me the conversation" when it does and "put the call away" when it
    /// does not, which is the difference between the web's toggle and a
    /// minimise.
    var isFramed: Bool { framed != nil }

    func present(configure: @escaping (CallsScreen) -> Void) {
        onMain { self.presentOnMain(configure: configure) }
    }

    private func presentOnMain(configure: (CallsScreen) -> Void) {
        if let screen = screen {
            configure(screen)
            screen.setChatShown(chatShown)
            window?.isHidden = false
            return
        }

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return
        }

        let screen = CallsScreen()
        let window = UIWindow(windowScene: scene)

        window.rootViewController = screen
        window.windowLevel = .alert + 1

        // Not clear: a moment where the window is larger than the view it
        // holds — the half-beat of a rotation — would otherwise show the page
        // behind it, which is white.
        window.backgroundColor = CallsTheme.stage

        configure(screen)
        screen.setChatShown(chatShown)
        replayPictures(to: screen)

        window.makeKeyAndVisible()

        self.window = window

        applyFrame()
        self.screen = screen
    }

    /// Where the screen sits: a rectangle in window coordinates for the band
    /// inside the page, or nil for the whole screen.
    ///
    /// A `UIWindow` with a partial frame lets everything outside it through to
    /// the window underneath, which is how the thread and the composer below
    /// the band stay the web view's. The band must also give up being the key
    /// window — a key window with no text field in it keeps the keyboard away
    /// from the one that has.
    /// Put the window back over the screen it is actually on. Idempotent:
    /// setting a frame to what it already is changes nothing.
    func refreshFrame() {
        onMain { self.applyFrame() }
    }

    /// `chat`: the page shows the conversation beside the call (the band), which Show Chat / Hide Chat in the dock
    /// says. With no frame the chat is not shown.
    func setFrame(_ rect: CGRect?, chat: Bool = false) {
        onMain {
            self.framed = rect
            self.chatShown = rect != nil && chat
            self.screen?.setChatShown(self.chatShown)

            self.applyFrame()
        }
    }

    /// Whether the page shows the chat beside the call, as it last said.
    private var chatShown = false

    private func applyFrame() {
        guard let window = window, let scene = window.windowScene else { return }

        guard let rect = framed else {
            window.frame = scene.screen.bounds

            // Geometry only. Putting a window on screen is `present`'s job and
            // taking it off is `hide`'s — this runs on every layout pass, and
            // an unconditional `makeKeyAndVisible` here undid the minimise a
            // frame after it happened: leaving the conversation took the box
            // away, the call was put in the bar, and the next layout threw it
            // straight back over the whole app. Which is what "the button back
            // to the messages list does not work" looked like.
            if !window.isHidden { window.makeKeyAndVisible() }

            return
        }

        let host = scene.windows.first { $0 !== window && $0.windowLevel == .normal }

        // A call that nearly fills the page *is* a full-screen call, and should
        // be given the whole screen rather than the page's idea of it.
        //
        // The page's own content starts below the status bar and, in landscape,
        // inside the safe area on both sides — so a call taking "all" of the
        // page still left the web view's white showing around it: a strip at
        // the top with the clock invisible against it, and bands down either
        // side and along the bottom once the phone was turned. A band with the
        // conversation above it is a different thing and keeps its rectangle.
        let bounds = scene.screen.bounds
        let fills = rect.width >= bounds.width * 0.8 && rect.height >= bounds.height * 0.8

        window.frame = fills ? bounds : rect

        host?.makeKey()
    }

    func update(_ block: @escaping (CallsScreen) -> Void) {
        onMain {
            guard let screen = self.screen else { return }

            block(screen)
        }
    }

    // MARK: The pictures, kept for a screen that does not exist yet

    /// Every picture the call has handed the screen, held here as well.
    ///
    /// A picture arrives once — a track on connect, a camera when it opens —
    /// and `update` drops what it is given while there is no screen to give it
    /// to. A call answered on the lock screen with the app killed has none: no
    /// scene to put one in until the app is opened. The screen that opened
    /// then got the call's state and nothing else, so the other side's camera
    /// was never drawn and, in a room, neither was this side's own.
    private var localVideo: LKRTCVideoTrack?
    private var roomLocalVideo: VideoTrack?
    private var remoteVideo: [CallsSource: LKRTCVideoTrack] = [:]
    private var roomPeerVideo: (camera: VideoTrack?, screen: VideoTrack?) = (nil, nil)

    func setLocalVideo(_ track: LKRTCVideoTrack?) {
        onMain {
            self.localVideo = track
            self.screen?.setLocalVideo(track)
        }
    }

    func setRoomLocalVideo(_ track: VideoTrack?) {
        onMain {
            self.roomLocalVideo = track
            self.screen?.setRoomLocalVideo(track)
        }
    }

    func setRemoteVideo(source: CallsSource, track: LKRTCVideoTrack?) {
        onMain {
            self.remoteVideo[source] = track
            self.screen?.setRemoteVideo(source: source, track: track)
        }
    }

    func setRoomPeerVideo(camera: VideoTrack?, screen: VideoTrack?) {
        onMain {
            self.roomPeerVideo = (camera, screen)
            self.screen?.setRoomPeerVideo(camera: camera, screen: screen)
        }
    }

    /// The other side of a two-person room changing its camera's codec
    /// (`CallsCameraSwitch`).
    private var roomPeerOptimizing = false

    func setRoomPeerOptimizing(_ optimizing: Bool) {
        onMain {
            self.roomPeerOptimizing = optimizing
            self.screen?.setRoomPeerOptimizing(optimizing)
        }
    }

    /// What of the other side's stopped arriving in a two-person room
    /// (`CallsStallWatch`).
    private var roomPeerStalled: CallsStalled?

    func setRoomPeerStalled(_ stalled: CallsStalled?) {
        onMain {
            self.roomPeerStalled = stalled
            self.screen?.setRoomPeerStalled(stalled)
        }
    }

    /// A screen made after the pictures were handed over is given them.
    private func replayPictures(to screen: CallsScreen) {
        if let track = localVideo { screen.setLocalVideo(track) }
        if let track = roomLocalVideo { screen.setRoomLocalVideo(track) }

        for (source, track) in remoteVideo {
            screen.setRemoteVideo(source: source, track: track)
        }

        if roomPeerVideo.camera != nil || roomPeerVideo.screen != nil {
            screen.setRoomPeerVideo(camera: roomPeerVideo.camera, screen: roomPeerVideo.screen)
        }

        if roomPeerOptimizing {
            screen.setRoomPeerOptimizing(true)
        }

        if let roomPeerStalled {
            screen.setRoomPeerStalled(roomPeerStalled)
        }
    }

    func hide() {
        onMain { self.window?.isHidden = true }
    }

    func dismiss() {
        onMain {
            self.framed = nil
            self.window?.isHidden = true
            self.window?.rootViewController = nil
            self.window = nil
            self.screen = nil

            // The call is over, and so are its pictures.
            self.localVideo = nil
            self.roomLocalVideo = nil
            self.remoteVideo = [:]
            self.roomPeerVideo = (nil, nil)
            self.roomPeerOptimizing = false
            self.roomPeerStalled = nil
        }
    }
}
