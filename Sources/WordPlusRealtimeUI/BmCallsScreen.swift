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
final class BmCallsScreen: UIViewController {
    private let stage = LKRTCMTLVideoView()

    /// One's own camera behind a ringing call, the way the web draws it.
    private let selfStage = LKRTCMTLVideoView()
    private let roomSelfStage = VideoView()
    private let selfScrim = BmCallsScrim()
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
    private let peerSwap = BmCallsIconView(BmCallsIcons.swapVideos)

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
    private let grid = BmCallsGrid()
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
    private var peopleButton: BmCallsButton?
    private var pipButton: BmCallsButton?
    private var settingsButton: BmCallsButton?
    private var shareButton: BmCallsButton?
    private var canPublish = true
    var canShareScreen = false
    private(set) var roster: [BmCallsRoomParticipant] = []

    private let avatar = UIView()
    private let initials = UILabel()
    /// The other person's own picture, where the site can name one. Their
    /// initials on a coloured disc are the fallback, not the intention.
    private let avatarImage = UIImageView()
    /// The presence dot the web draws on every call avatar (`.bbpm-avatar` and
    /// its `::before`): a fifth of the avatar, bottom-right, ringed in the
    /// colour behind it so it reads as separate from the picture.
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
    private let errorNoticeIcon = BmCallsIconView(BmCallsIcons.alert)
    private let errorNoticeText = UILabel()
    private var errorNoticeTimer: Timer?

    /// Configure and Participants, drawn on the call instead of over it.
    private var panel: BmCallsPanel?

    /// Keeps a panel's second line current while it is up.
    private var panelTimer: Timer?

    /// The other side has dropped, said over a picture that has stopped
    /// moving. `.bm-placeholder-participant-lost-message`, which the web draws
    /// whatever else is on the stage; here it is only needed over a picture,
    /// because without one the status line already says it.
    private let lostNotice = UIView()
    private let lostNoticeIcon = BmCallsIconView(BmCallsIcons.wifiOff)
    private let lostNoticeText = UILabel()

    private let peerNotice = UIView()
    private let peerNoticeIcon = BmCallsIconView(BmCallsIcons.micOff)
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
    private var controlsVisible = true
    private var identityMode: String?
    private var peerOnline = false

    private let dock = BmCallsDock()
    private var answerButton: BmCallsButton?
    private var endButton: BmCallsButton?
    private var minimiseButton: BmCallsButton?
    private var controlDiameter: CGFloat = 0

    private var muteButton: BmCallsButton?
    private var cameraButton: BmCallsButton?
    private var flipButton: BmCallsButton?
    private var speakerButton: BmCallsButton?
    /// A viewer's only way to ask to speak in a broadcast room. The web draws
    /// it on exactly the same condition and nowhere else.
    private var handButton: BmCallsButton?

    /// A call with more than two people. Not the same question as `inRoom`: a
    /// direct call the server moved into a room has a roster too, and it is
    /// still a call between two people.
    private var isGroupCall = false
    /// The room was switched to broadcast, or this side was muted by a
    /// moderator. Both are rules rather than settings, and the control that
    /// would undo them is not drawn.
    private var callMode = "participatory"
    private var micLocked = false
    private var handRaised = false

    private var durationTimer: Timer?
    private var connectedAt: Date?

    private var remoteVideo: LKRTCVideoTrack?
    private var localVideo: LKRTCVideoTrack?
    private var roomLocalVideo: VideoTrack?
    private var roomPeerCamera: VideoTrack?
    private var roomPeerScreen: VideoTrack?
    /// The other side's camera changing codec in a two-person room
    /// (`BmCallsCameraSwitch`): the room holds it until the frame that ends
    /// it, for `applyRoomOptimizing`.
    private var roomPeerOptimizing = false
    /// Over the stage while that lasts, below the corners and the dock.
    private let roomOptimizing = BmCallsOptimizingView()
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
    var onMinimise: (() -> Void)?
    var onPeople: (() -> Void)?
    var onPictureInPicture: (() -> Void)?
    var onSettings: (() -> Void)?
    var onToggleScreenShare: ((Bool) -> Void)?

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { phase == "in_progress" && isVideoCall }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = BmCallsTheme.stage

        buildStage()
        buildGrid()
        buildIdentity()
        buildPeerNotice()
        buildLostNotice()
        buildControls()
        // After the dock, because it sits above it and is drawn over it.
        buildErrorNotice()

        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(stageTapped)))

        // The window animates out of and back into this screen, so it is
        // attached once the screen exists rather than when a call starts.
        BmCallsPip.shared.attach(to: view)

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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        applyControlMetrics()
        applyIdentityMetrics()

        // Its size is a share of the avatar's, so the radius cannot be set
        // once — the compact profile halves it.
        presenceDot.layer.cornerRadius = presenceDot.bounds.width / 2

        // The window's frame was set for the screen as it was. A rotation
        // changes the screen's bounds and nothing re-sets it, so the call kept
        // a portrait-shaped window on a landscape screen and the web view's
        // white showed around it. Re-applying is free when nothing moved.
        BmCallsScreenHost.shared.refreshFrame()

        // A rotation or a split-screen resize changes every box on the screen.
        onViewChanged?()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        coordinator.animate(alongsideTransition: { _ in
            BmCallsScreenHost.shared.refreshFrame()
        }, completion: { _ in
            BmCallsScreenHost.shared.refreshFrame()
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

        roomOptimizing.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(roomOptimizing)

        NSLayoutConstraint.activate([
            roomStage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            roomStage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            roomStage.topAnchor.constraint(equalTo: view.topAnchor),
            roomStage.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
        peerSwap.accessibilityLabel = BmCallsTheme.string("switch_videos", fallback: "Switch Videos")
        peerSwap.isAccessibilityElement = true

        peerChipHolder.addSubview(peerChip)
        peerChipHolder.addSubview(roomPeerChip)
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

            BmCallsModeration.showFor(from: self, person: person)
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
    /// there. Nothing is reserved at the bottom — the dock is drawn over the
    /// grid, the way the web draws its own.
    private func applyGridMetrics() {
        gridTop?.constant = (nameLabel.isHidden && statusLabel.isHidden) ? 0 : 72
    }

    private func buildIdentity() {
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.backgroundColor = BmCallsTheme.accent
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
        presenceDot.backgroundColor = BmCallsTheme.online
        // `.bbpm-avatar::before` rings the dot in **one** pixel of the colour
        // behind it. A CALayer border is drawn *inside* the bounds, so two of
        // them ate a third of the dot and left a heavy dark arc across the
        // picture — the view is a hairline wider than the dot instead, which
        // puts the ring outside it exactly as the stylesheet does.
        presenceDot.layer.borderWidth = 1
        presenceDot.layer.borderColor = BmCallsTheme.stage.cgColor
        presenceDot.isUserInteractionEnabled = false
        presenceDot.isHidden = true

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        nameLabel.textColor = BmCallsTheme.onStage
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
        // clock become one small line in the strip the grid leaves above it —
        // inset past the minimise button, which shares that strip.
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
        errorNotice.backgroundColor = BmCallsTheme
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

        errorNoticeText.text = message
        errorNotice.isHidden = false

        errorNoticeTimer?.invalidate()
        errorNoticeTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
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
        rows: [BmCallsPanelRow],
        refresh: (() -> String?)? = nil
    ) {
        hidePanel()

        let panel = BmCallsPanel()

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
        lostNoticeText.text = BmCallsTheme.string("reconnecting", fallback: "The other side lost connection")

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
        // name and the status. The corner is free for it now that the chevron
        // has moved to the bottom edge, which is also the stylesheet's.
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
        let mute = BmCallsButton(icon: BmCallsTheme.micIcon(muted: false), tone: .medium) { [weak self] in
            guard let self = self, let button = self.muteButton else { return }

            button.isOn = !button.isOn
            button.setIcon(BmCallsTheme.micIcon(muted: button.isOn))

            self.onToggleMute?(button.isOn)
        }

        let camera = BmCallsButton(icon: BmCallsTheme.cameraIcon(on: true), tone: .medium) { [weak self] in
            guard let self = self, let button = self.cameraButton else { return }

            button.isOn = !button.isOn
            button.setIcon(BmCallsTheme.cameraIcon(on: !button.isOn))

            self.onToggleCamera?(!button.isOn)
        }

        let flip = BmCallsButton(icon: BmCallsIcons.switchCamera) { [weak self] in
            self?.onFlipCamera?()
        }

        let speaker = BmCallsButton(icon: BmCallsIcons.speaker, tone: .latch) { [weak self] in
            guard let self = self, let button = self.speakerButton else { return }

            button.isOn = !button.isOn
            button.setIcon(button.isOn ? BmCallsIcons.speaker : BmCallsIcons.speakerOff)

            self.onToggleSpeaker?(button.isOn)
        }

        // Only in a room: there is nothing to moderate in a call between two
        // people, and nobody to list.
        let people = BmCallsButton(icon: BmCallsIcons.users) { [weak self] in
            self?.onPeople?()
        }

        people.isHidden = true
        people.accessibilityLabel = BmCallsTheme.string("participants", fallback: "Participants")
        peopleButton = people

        #if DEBUG
        // Nobody can gather thirty-two people to see whether the grid holds,
        // so a long press here fills the room with people who are not there.
        // Debug builds only — this cannot reach a customer's app.
        people.addGestureRecognizer(
            UILongPressGestureRecognizer(target: self, action: #selector(peopleHeld(_:)))
        )
        #endif

        // A viewer in a broadcast room cannot publish anything; putting a hand
        // up is the whole of what they can do, so it gets a control of its own
        // rather than living two taps deep in the participants sheet.
        let hand = BmCallsButton(icon: BmCallsIcons.raiseHand, tone: .latch) { [weak self] in
            guard let self = self else { return }

            BmCallsEngine.shared.groupAdmin(action: self.handRaised ? "lower_own_hand" : "raise_hand")
        }

        hand.isHidden = true
        hand.accessibilityLabel = BmCallsTheme.string("raise_hand", fallback: "Raise Hand")
        handButton = hand

        let share = BmCallsButton(icon: BmCallsIcons.screenShare, tone: .latch) { [weak self] in
            guard let self = self, let button = self.shareButton else { return }

            button.isOn = !button.isOn
            button.setIcon(button.isOn ? BmCallsIcons.screenShareOff : BmCallsIcons.screenShare)

            self.onToggleScreenShare?(button.isOn)
        }

        share.isHidden = true
        share.accessibilityLabel = BmCallsTheme.string("share_screen", fallback: "Share Screen")
        shareButton = share

        let settings = BmCallsButton(icon: BmCallsIcons.settings) { [weak self] in
            self?.onSettings?()
        }

        settings.isHidden = true
        settings.accessibilityLabel = BmCallsTheme.string("configure", fallback: "Configure")
        settingsButton = settings

        // Only where the device can actually do it, and only in a video call:
        // a button that opens a black square is worse than no button.
        let pip = BmCallsButton(icon: BmCallsIcons.pip, tone: .latch) { [weak self] in
            self?.onPictureInPicture?()
        }

        pip.isHidden = true
        pip.accessibilityLabel = BmCallsTheme.string("picture_in_picture", fallback: "Picture In Picture")
        pipButton = pip

        // Answering is part of the same dock, as it is on the web, and it is
        // simply not there once the call has been picked up.
        let answer = BmCallsButton(icon: BmCallsIcons.phone, tone: .answer) { [weak self] in
            self?.onAnswer?()
        }

        answer.isHidden = true
        answer.accessibilityLabel = BmCallsTheme.string("answer", fallback: "Answer")
        answerButton = answer

        let end = BmCallsButton(icon: BmCallsIcons.phone, tone: .danger) { [weak self] in
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
        end.accessibilityLabel = BmCallsTheme.string("end_call", fallback: "End Call")
        endButton = end

        // Every control says what it is. VoiceOver read the whole dock as
        // "button" before this, and the device rig had to tap them by
        // coordinate for want of anything to select by. The words are the
        // web's own, from the same translation store.
        mute.accessibilityLabel = BmCallsTheme.string("disable_microphone", fallback: "Disable Microphone")
        camera.accessibilityLabel = BmCallsTheme.string("enable_camera", fallback: "Enable Camera")
        flip.accessibilityLabel = BmCallsTheme.string("switch_camera", fallback: "Switch Camera")
        speaker.accessibilityLabel = BmCallsTheme.string("speaker", fallback: "Speaker")

        muteButton = mute
        cameraButton = camera
        flipButton = flip
        speakerButton = speaker

        for control in [answer, settings, flip, camera, mute, speaker, pip, share, hand, people, end] {
            dock.row.addArrangedSubview(control)
        }

        // By the ids a host arranges them by (BmCallsPieces), in this order.
        ourControls = zip(
            [ "answer", "settings", "flip", "camera", "mute", "speaker", "pip", "share", "hand", "people", "end" ],
            [ answer, settings, flip, camera, mute, speaker, pip, share, hand, people, end ] as [UIView]
        ).map { BmCallsControl(id: $0.0, view: $0.1) }

        let minimise = BmCallsButton(icon: BmCallsIcons.chevronDown) { [weak self] in
            self?.onMinimise?()
        }

        // It is the web's "Toggle Chat Screen" wherever the page has made room
        // for the call, and a minimise everywhere else — the label follows in
        // `apply(state:)`.
        minimise.accessibilityLabel = BmCallsTheme.string("toggle_chat_screen", fallback: "Toggle Chat Screen")
        minimiseButton = minimise

        view.addSubview(dock)
        view.addSubview(minimise)

        NSLayoutConstraint.activate([
            dock.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dock.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            dock.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            // Clear of the chevron, which sits under this row.
            dock.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -(10 + 22 + 8)),

            // Where the stylesheet puts it — `bottom: 0; left: 50%; width:
            // 44px; height: 20px`, with the controls row above. It was a
            // full-size control in the top start corner, which is the
            // muted-microphone chip's corner.
            minimise.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // Off the very edge: flush against it, a 22pt target sits in the
            // home-indicator strip and is hard to hit. The size is the
            // button's own business — see `setTab`.
            minimise.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),

        ])

        // The grid fills its box and the dock is drawn over it, the way the
        // web draws its own — `position: absolute; bottom: 0` with a gradient
        // behind it. Tied to the dock's top instead, every tile resized each
        // time the dock was tapped away and back, and a control that comes and
        // goes should not move the picture it is sitting on.
        grid.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor).isActive = true

        applyControlMetrics()
        applyGridMetrics()
    }

    /// The stylesheet steps its controls down as the stage narrows, and the
    /// stage here is the whole screen. Read on every layout so a rotation or
    /// an iPad split is followed rather than frozen at launch.
    private func applyControlMetrics() {
        let diameter = BmCallsButton.diameter(for: view.bounds.width)

        guard diameter != controlDiameter else { return }

        controlDiameter = diameter

        for control in dock.row.arrangedSubviews.compactMap({ $0 as? BmCallsButton }) {
            control.setDiameter(diameter)
        }

        // The chevron is not a dock control and is not sized like one: the
        // stylesheet gives it 44 by 22 at the bottom edge.
        minimiseButton?.setTab(width: 44, height: 22)
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
            ? BmCallsTheme.string("unknown_caller", fallback: "Unknown")
            : shown
        initials.text = BmCallsScreen.initials(of: shown)

        guard url != avatarURL else { return }

        avatarURL = url
        avatarImage.image = nil
        avatarImage.isHidden = true

        guard !url.isEmpty else { return }

        BmCallsAvatars.load(url) { [weak self] image in
            guard let self = self, self.avatarURL == url, let image = image else { return }

            self.avatarImage.image = image
            self.avatarImage.isHidden = false
        }
    }

    /// Every state the call can be in, drawn from the same dictionary the
    /// bundle gets. Called on every change, so it must be cheap and total —
    /// anything it does not set stays as it was and drifts.
    func apply(state: [String: Any]) {
        phase = state["phase"] as? String ?? "idle"
        isGroupCall = state["group"] as? Bool ?? false
        callMode = state["callMode"] as? String ?? "participatory"

        let local = state["local"] as? [String: Any] ?? [:]
        let muted = local["muted"] as? Bool ?? false
        let camera = local["camera"] as? Bool ?? false

        peerOnline = state["peerOnline"] as? Bool ?? false

        // Every avatar in a room wears the dot too, the way the web's do —
        // the grid draws its pictures from URLs and has no presence of its own.
        grid.online = Set((state["online"] as? [Int]) ?? [])

        drawPresence()
        drawSelfStage()

        muteButton?.isOn = muted
        muteButton?.setIcon(BmCallsTheme.micIcon(muted: muted))

        // `isOn` is the stylesheet's `bm-enable-video`: the state where the
        // camera is *not* running and the button turns it back on.
        cameraButton?.isOn = !camera
        cameraButton?.setIcon(BmCallsTheme.cameraIcon(on: camera))

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
            ? BmCallsTheme.string("enable_microphone", fallback: "Enable Microphone")
            : BmCallsTheme.string("disable_microphone", fallback: "Disable Microphone")

        cameraButton?.accessibilityLabel = camera
            ? BmCallsTheme.string("disable_camera", fallback: "Disable Camera")
            : BmCallsTheme.string("enable_camera", fallback: "Enable Camera")

        endButton?.accessibilityLabel = ringingIn
            ? BmCallsTheme.string("reject", fallback: "Reject")
            : BmCallsTheme.string("end_call", fallback: "End Call")

        // Nobody rings a room and nobody answers one, so a group call never
        // shows the answer control whatever the phase says.
        if isGroupCall { answerButton?.isHidden = true }

        // A call getting its connection back is still the call: the web keeps
        // every control while the other side reads as lost, and this took
        // three of them away every time the network blinked.
        let running = phase == "in_progress" || phase == "reconnecting"

        pipButton?.isHidden = !running
            || !BmCallsPip.isSupported
            || !hasPicture

        settingsButton?.isHidden = !running

        // Sharing needs the broadcast extension, which is a build-time thing:
        // a button that opens a picker with nothing in it is worse than none.
        shareButton?.isHidden = !running || !canShareScreen

        // The icon with the state, not only with the tap: a share the room
        // carries, or one stopped from the system's bar, left the button
        // offering to start what was already running.
        let sharing = local["screen"] as? Bool ?? false

        shareButton?.isOn = sharing
        shareButton?.setIcon(sharing ? BmCallsIcons.screenShareOff : BmCallsIcons.screenShare)

        applyPublishControls()
        applyRoomControls()

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
            ? BmCallsTheme.string(
                "peer_mic_and_camera_off",
                fallback: "The microphone and camera not enabled at the other side"
            )
            : BmCallsTheme.string(
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
            ? BmCallsTheme.recording.withAlphaComponent(235.0 / 255.0)
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
            ? BmCallsTheme.string("reconnecting_self", fallback: "Reconnecting...")
            : BmCallsTheme.string("reconnecting", fallback: "The other side lost connection")

        statusLabel.text = statusText()

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

        // The host's own pieces, for the phase now (BmCallsPieces).
        arrangeDock()
        drawStagePiece()

        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    // MARK: - The host's pieces

    /// Ours, by the ids a host arranges them by, as buildControls made them.
    private var ourControls: [BmCallsControl] = []
    private var stagePiece: UIView?

    /// A host's own button the dock already shows under the same id, kept: the pieces run on every change of the call,
    /// many a second while it connects, and a host that makes its button each time (as `CallControl(id:…)` in `controls`
    /// reads) would otherwise have the whole dock taken down and built again each time. The kept one takes the new one's
    /// label, icon, latch and action.
    private func keepDocked(_ control: BmCallsControl, _ docked: [UIView]) -> BmCallsControl {
        guard let fresh = control.view as? BmCallsButton, !ourControls.contains(where: { $0.view === fresh }),
              let id = fresh.accessibilityIdentifier,
              let kept = docked.first(where: { $0 !== fresh && $0.accessibilityIdentifier == id }) as? BmCallsButton,
              kept.tone == fresh.tone else { return control }
        kept.setIcon(fresh.icon)
        kept.isOn = fresh.isOn
        kept.accessibilityLabel = fresh.accessibilityLabel
        kept.action = fresh.action
        return BmCallsControl(id: control.id, view: kept)
    }

    /// The dock in the host's order, its own buttons among ours; hanging up stays last, whatever it answers.
    private func arrangeDock() {
        guard let arrange = BmCallsPiecesStore.current.controls, !ourControls.isEmpty else { return }
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
        let own = isGroupCall ? nil : BmCallsPiecesStore.current.stage?(phase)
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

    /// The host's own status line, where it gives one (BmCallsPieces).
    private func pieceStatus() -> String? {
        BmCallsPiecesStore.current.status?(phase, Int(Date().timeIntervalSince(connectedAt ?? Date())))
    }

    private func statusText() -> String {
        if let own = pieceStatus() { return own }

        // A room is joined, not dialled: it has no ring and nothing is
        // "calling". Until the connection is up it is connecting, and after
        // that the clock runs the same as anywhere else.
        if isGroupCall, phase != "in_progress" {
            return BmCallsTheme.string("connecting", fallback: "Connecting...")
        }

        switch phase {
        case "ringing_out":
            return BmCallsTheme.string("calling", fallback: "Calling…")
        case "ringing_in":
            // The web's card names the kind of call that is coming in, and so
            // does this. `incoming_call` stays in the table for app binaries
            // older than 10 Sep, which still ask for it.
            return isVideoCall
                ? BmCallsTheme.string("incoming_video_call", fallback: "Incoming Video Call")
                : BmCallsTheme.string("incoming_audio_call", fallback: "Incoming Audio Call")
        case "connecting":
            return BmCallsTheme.string("connecting", fallback: "Connecting...")
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
    func setRemoteVideo(source: BmCallsSource, track: LKRTCVideoTrack?) {
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

        BmCallsLog.write("screen: stage=\(showing) corner=\(inCorner == nil && roomInCorner == nil ? "none" : "their second picture") self=\(localVideo == nil && roomLocalVideo == nil ? "none" : "camera")")

        hasPicture = picture

        BmCallsPip.shared.show(onStage)
        BmCallsPip.shared.showRoom(roomOnStage)
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
            statusLabel.isHidden = phase == "in_progress"

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
            hint["camera"] = BmCallsShapes.viewStep(boxHeight(for: remoteVideo))
        }

        if remoteScreen != nil {
            // A screen is asked for at the exact pixel it is drawn at, not at
            // a rung: text is either sharp or it is not.
            hint["screen_share"] = BmCallsShapes.exactStep(boxHeight(for: remoteScreen))
        }

        return hint
    }

    private func boxHeight(for track: LKRTCVideoTrack?) -> Int {
        guard let track = track, !inRoom else { return 0 }

        // Backgrounded is not shown — except in the corner window, which is
        // the whole point of it.
        if backgrounded, !BmCallsPip.shared.isActive { return 0 }

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
        let shown = min(bounds.height, bounds.width * BmCallsScreen.defaultAspect)

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
    /// word until the frame that ends it (`BmCallsCameraSwitch`).
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

            return
        }

        muteButton?.isHidden = true
        cameraButton?.isHidden = true
        flipButton?.isHidden = true
        shareButton?.isHidden = true
    }

    /// Everyone in a room call.
    func setRoster(_ participants: [BmCallsRoomParticipant]) {
        inRoom = !participants.isEmpty
        roster = participants

        peopleButton?.isHidden = !inRoom

        // A group call is a grid, and a grid does not fit in a PiP window —
        // there is no single "the other person" to show there.
        if inRoom {
            hasPicture = false
            BmCallsPip.shared.showRoom(nil)
        }

        // A viewer in broadcast mode has nothing to publish, so the controls
        // that would publish it are not drawn — the web hides the same ones.
        canPublish = participants.first { $0.isLocal }?.canPublish ?? true
        micLocked = participants.first { $0.isLocal }?.micMuted ?? false
        handRaised = participants.first { $0.isLocal }?.handRaised ?? false

        applyPublishControls()
        applyRoomControls()

        // An audio room is a list of people on the web, not a wall of empty
        // rectangles. Only a group audio call: the two-person room a failed
        // direct call is moved into never reaches the grid at all.
        grid.audioRoom = isGroupCall && !isVideoCall
        grid.broadcastRoom = isGroupCall && callMode == "broadcast"

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
    }

    /// The controls a room has and a direct call does not, and the ones it
    /// takes away. The web's own conditions, one for one.
    private func applyRoomControls() {
        // "Participants" carries the head count, because the button is the
        // only place in a grid of faces where the number is stated.
        peopleButton?.accessibilityLabel = roster.isEmpty
            ? BmCallsTheme.string("participants", fallback: "Participants")
            : "\(BmCallsTheme.string("participants", fallback: "Participants")) (\(roster.count))"

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
        let asking = isGroupCall && callMode == "broadcast" && !canPublish && !canModerate

        handButton?.isHidden = !asking
        handButton?.isOn = handRaised
        handButton?.accessibilityLabel = handRaised
            ? BmCallsTheme.string("lower_hand", fallback: "Lower Hand")
            : BmCallsTheme.string("raise_hand", fallback: "Raise Hand")

        // A room is left rather than hung up, and the web says so with a door
        // rather than a handset. Both ways round, because the host keeps one
        // screen for the process and a private call after a group call would
        // otherwise still be offering the door.
        endButton?.setIcon(isGroupCall ? BmCallsIcons.logout : BmCallsIcons.phone)
        endButton?.rotateGlyph(degrees: isGroupCall ? 0 : 135)

        if isGroupCall {
            endButton?.accessibilityLabel = BmCallsTheme.string("exit_chat", fallback: "Exit Chat")
        }
    }

    /// Whether this side may moderate, as the room reported it.
    private var canModerate: Bool {
        roster.first { $0.isLocal }?.canAdmin ?? false
    }

    /// Never on its own: the dot belongs to the avatar, and the avatar is put
    /// away the moment there is a picture to look at instead.
    private func drawPresence() {
        presenceDot.isHidden = avatar.isHidden || !peerOnline
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

        BmCallsEngine.shared.cycleDebugRoster()
    }
    #endif

    @objc private func stageTapped() {
        // Said out loud, as Android says it. A tap that does nothing is
        // indistinguishable from a tap that never arrived, and the two have
        // opposite fixes.
        BmCallsLog.write("tap: room=\(inRoom) phase=\(phase) video=\(isVideoCall) stage=\(stageTrack != nil) controls=\(controlsVisible)")

        guard phase == "in_progress" else { return }

        // A room has no stage track — the grid draws everybody and the stage
        // is hidden behind it — so the test that asks whether there is a
        // picture to get out of the way of said no to every group call, and
        // the dock could not be put away in the one layout with the least room
        // to spare. A grid of faces is as much a picture as one face is.
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
        minimiseButton?.isUserInteractionEnabled = controlsVisible

        UIView.animate(withDuration: 0.2) {
            self.dock.alpha = alpha
            self.nameLabel.alpha = alpha
            self.statusLabel.alpha = alpha

            // The chevron belongs to the same row and goes with it. Left
            // behind, it was the one control still floating over a picture the
            // controls had just got out of the way of.
            self.minimiseButton?.alpha = alpha

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
        nameLabel.alpha = 1
        statusLabel.alpha = 1
        minimiseButton?.alpha = 1

        // Back in every sense: a dock that came back deaf is worse than one
        // that stayed away.
        dock.isUserInteractionEnabled = true
        minimiseButton?.isUserInteractionEnabled = true
    }

    private static func initials(of name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)

        let letters = parts.compactMap { $0.first }.map { String($0).uppercased() }

        return letters.isEmpty ? "?" : letters.joined()
    }
}

/// The window the call lives in.
///
/// Above the app's own, so the call survives whatever the web view does, and
/// on the lock screen it is what CallKit brings up.
/// The renderers say what shape they are drawing, and the corner tiles take it.
extension BmCallsScreen: LKRTCVideoViewDelegate {
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

final class BmCallsScreenHost {
    static let shared = BmCallsScreenHost()

    private var window: UIWindow?
    private var framed: CGRect?
    private(set) var screen: BmCallsScreen?

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
    func read<T>(_ block: (BmCallsScreen) -> T) -> T? {
        guard Thread.isMainThread, let screen = screen else { return nil }

        return block(screen)
    }

    /// Whether the page has a box for the call. The chevron means "show me the
    /// conversation" when it does and "put the call away" when it does not,
    /// which is the difference between the web's toggle and a minimise.
    var isFramed: Bool { framed != nil }

    func present(configure: @escaping (BmCallsScreen) -> Void) {
        onMain { self.presentOnMain(configure: configure) }
    }

    private func presentOnMain(configure: (BmCallsScreen) -> Void) {
        if let screen = screen {
            configure(screen)
            window?.isHidden = false
            return
        }

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return
        }

        let screen = BmCallsScreen()
        let window = UIWindow(windowScene: scene)

        window.rootViewController = screen
        window.windowLevel = .alert + 1

        // Not clear: a moment where the window is larger than the view it
        // holds — the half-beat of a rotation — would otherwise show the page
        // behind it, which is white.
        window.backgroundColor = BmCallsTheme.stage

        configure(screen)
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

    func setFrame(_ rect: CGRect?) {
        onMain {
            self.framed = rect

            self.applyFrame()
        }
    }

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

    func update(_ block: @escaping (BmCallsScreen) -> Void) {
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
    private var remoteVideo: [BmCallsSource: LKRTCVideoTrack] = [:]
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

    func setRemoteVideo(source: BmCallsSource, track: LKRTCVideoTrack?) {
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
    /// (`BmCallsCameraSwitch`).
    private var roomPeerOptimizing = false

    func setRoomPeerOptimizing(_ optimizing: Bool) {
        onMain {
            self.roomPeerOptimizing = optimizing
            self.screen?.setRoomPeerOptimizing(optimizing)
        }
    }

    /// A screen made after the pictures were handed over is given them.
    private func replayPictures(to screen: BmCallsScreen) {
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
        }
    }
}
