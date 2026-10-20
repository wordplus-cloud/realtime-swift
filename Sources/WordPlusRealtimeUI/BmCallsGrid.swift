import UIKit
import LiveKit

/// One person, one cell.
///
/// This used to give a screen sharer two — a comment claimed the web did the
/// same, and it does not: `group-video-grid-item.tsx` renders one tile per
/// participant and puts the screen in it, with their camera inset in the
/// corner. Two tiles for one person also cost a place in a grid that has very
/// few of them on a phone.
private struct Cell {
    let person: BmCallsRoomParticipant
}

/// A call with more than two people in it.
///
/// Two shapes, because the web has two. A **video** room is a wall of pictures:
/// one tile each, laid out in as square a grid as the count allows, because a
/// phone screen is tall and a single column wastes it above four people. An
/// **audio** room has no pictures to show, so the web draws a list instead —
/// a row per person, avatar, name and their microphone — and fifty tall empty
/// rectangles would be a worse answer to the same question.
///
/// Tiles are reused rather than rebuilt: a `VideoView` owns a renderer, and
/// churning them on every roster change is how a grid starts to flicker.
final class BmCallsGrid: UIView, UIScrollViewDelegate {
    /// What a tile is shaped for when nothing has said otherwise.
    ///
    /// Every camera in a call publishes at it and a laptop's shared screen is
    /// near enough, so it stood in for every picture here. A phone sharing its
    /// own screen is about 9:19.5 — taller than it is wide — and there is no
    /// figure that covers both, so this is now the fallback and the tiles
    /// measure what they are actually drawing: see `Tile.pictureRatio`.
    static let tileRatio: CGFloat = 1.77

    /// The shortest a strip, or the narrowest a column, is allowed to be. The
    /// web's `minSecondaryHeight` and the 16:9 width that goes with it.
    static let minStrip: CGFloat = 100

    /// Long-pressing a tile is how the moderation actions are reached.
    var onPerson: ((BmCallsRoomParticipant) -> Void)?

    /// Draw the list rather than the wall. Set from the call's own type: an
    /// audio room is a room nobody is publishing video into.
    var audioRoom = false {
        didSet {
            guard audioRoom != oldValue else { return }

            tiles.forEach { $0.isRow = audioRoom }
            setNeedsLayout()
        }
    }

    /// Who on this call the site says is online, as the page's presence store
    /// sees it. The web puts every call avatar through `UserAvatar`, which
    /// wears the dot; a grid of pictures drawn from URLs knows nothing about
    /// presence unless it is told.
    var online: Set<Int> = [] {
        didSet {
            guard online != oldValue else { return }

            rebind()
        }
    }

    /// Whether the room is in broadcast mode. It decides who is pulled out
    /// large: the web's grid puts whoever may publish in the primary row while
    /// a room is broadcasting, and pinned participants at any time.
    var broadcastRoom = false {
        didSet {
            guard broadcastRoom != oldValue else { return }

            setNeedsLayout()
        }
    }

    /// A list is taller than the screen once there are enough people in it —
    /// an audio room holds fifty — so the tiles live in a scroller. A wall
    /// scrolls only when the people in it will not fit at the size the web
    /// would have drawn them.
    private let scroll = UIScrollView()

    private final class Tile: UIView, TrackDelegate {
        let video = VideoView()
        /// Someone sharing their screen is still a face worth seeing, so the
        /// web insets their camera in the corner of the same tile
        /// (`.bm-small-video`: 72px tall, 8px in, a hairline of white).
        let cameraInset = VideoView()
        let picture = UIImageView()
        let initial = UILabel()
        let label = UILabel()

        /// The web draws each of these as a *chip* — a coloured disc with a
        /// stroked glyph in it — rather than a bare mark: a red one for a
        /// microphone that is off, a translucent green one for one that is on,
        /// and an amber one for a raised hand. So each is a disc with the icon
        /// inset, which is also why they are two views and not one.
        let handChip = UIView()
        let hand = BmCallsIconView(BmCallsIcons.raiseHand)
        let micChip = UIView()
        let mic = BmCallsIconView(BmCallsIcons.micOff)
        let viewer = UILabel()

        /// The dot the web's `.bbpm-avatar::before` draws: a fifth of the
        /// picture, bottom-right, ringed in the colour behind it. It belongs to
        /// the avatar, so it goes away with it the moment there is a camera to
        /// look at instead.
        let dot = UIView()

        /// Which of the two shapes this tile is drawing. Everything is laid
        /// out by hand, so switching is a relayout and nothing else.
        var isRow = false {
            didSet {
                guard isRow != oldValue else { return }

                setNeedsLayout()
            }
        }

        private var avatarUrl = ""
        private(set) var person: BmCallsRoomParticipant?
        private(set) var showsScreen = false

        /// Width over height of the picture on show, once the track has said —
        /// zero until then, which means "no better answer than `tileRatio`".
        ///
        /// The shape is not known when the tile is built: the dimensions
        /// arrive with the stream, and for a phone turned over mid-call they
        /// arrive again. So the tile is told rather than asked once. The
        /// Android tile learns exactly the same thing from its renderer's
        /// `onFrameResolutionChanged`.
        private(set) var pictureRatio: CGFloat = 0

        /// What the grid does when that answer changes. A row's height is
        /// worked out by the grid, not by the tile, so a new shape has to
        /// reach further up than `setNeedsLayout` on self.
        var onShape: (() -> Void)?

        /// The track whose shape is being followed, held weakly: the room owns
        /// it and a tile must not keep a dead one alive.
        private weak var watched: Track?

        override init(frame: CGRect) {
            super.init(frame: frame)

            backgroundColor = BmCallsTheme.tile
            layer.cornerRadius = 10
            clipsToBounds = true

            // Nothing in the grid is mirrored, one's own camera included: you
            // see yourself the way the others do, as the web's grid shows it.
            // A `VideoView` mirrors a local front camera unless told not to.
            video.mirrorMode = .off
            video.isHidden = true

            cameraInset.mirrorMode = .off
            cameraInset.isHidden = true
            cameraInset.layoutMode = .fill
            cameraInset.clipsToBounds = true
            cameraInset.layer.cornerRadius = 8
            cameraInset.layer.borderWidth = 1
            cameraInset.layer.borderColor = UIColor(white: 1, alpha: 0.16).cgColor
            cameraInset.backgroundColor = .black
            cameraInset.alpha = 0.85

            picture.contentMode = .scaleAspectFill
            picture.clipsToBounds = true
            picture.isHidden = true

            initial.font = .systemFont(ofSize: 28, weight: .semibold)
            initial.textColor = .white
            initial.textAlignment = .center

            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .white
            label.textAlignment = .center

            handChip.backgroundColor = BmCallsTheme.warning
            handChip.isHidden = true
            handChip.clipsToBounds = true
            hand.color = UIColor(red: 0.067, green: 0.075, blue: 0.094, alpha: 1)
            handChip.addSubview(hand)

            micChip.isHidden = true
            micChip.clipsToBounds = true
            mic.color = .white
            micChip.addSubview(mic)

            viewer.font = .systemFont(ofSize: 10, weight: .bold)
            viewer.textColor = UIColor(white: 1, alpha: 0.72)
            viewer.textAlignment = .center
            viewer.backgroundColor = UIColor(white: 1, alpha: 0.1)
            viewer.clipsToBounds = true
            viewer.isHidden = true

            dot.backgroundColor = BmCallsTheme.online
            // One point of it, in the tile's own colour, and drawn around the
            // dot rather than into it — see `place(_:on:size:)`.
            dot.layer.borderWidth = 1
            dot.layer.borderColor = BmCallsTheme.tile.cgColor
            dot.isUserInteractionEnabled = false
            dot.isHidden = true

            addSubview(video)
            addSubview(cameraInset)
            addSubview(picture)
            addSubview(initial)
            addSubview(dot)
            addSubview(label)
            addSubview(handChip)
            addSubview(micChip)
            addSubview(viewer)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// A dropped tile takes its renderer with it: leaving the track
        /// attached keeps a view alive that nothing will ever draw again.
        func release() {
            watch(nil)
            video.track = nil
            cameraInset.track = nil
            person = nil
        }

        /// The info line of a row. What sits above it is the picture, and how
        /// much room that gets is the grid's to decide — see `layoutList`.
        static let rowHeight: CGFloat = 56

        /// Follow this track's shape, and stop following the last one.
        private func watch(_ track: VideoTrack?) {
            if watched !== track {
                watched?.remove(delegate: self)
                watched = track
                track?.add(delegate: self)
            }

            // Asked as well as told: a track that was already carrying a
            // picture when it was handed over has its dimensions now, and no
            // event is coming to say so.
            apply(track?.dimensions)
        }

        private func apply(_ dimensions: Dimensions?) {
            var ratio: CGFloat = 0

            if let dimensions, dimensions.width > 0, dimensions.height > 0 {
                ratio = CGFloat(dimensions.width) / CGFloat(dimensions.height)
            }

            guard pictureRatio != ratio else { return }

            pictureRatio = ratio

            setNeedsLayout()
            onShape?()
        }

        /// The SDK's own report that the picture changed shape — a phone
        /// turned over swaps its two sides. It arrives off the main thread.
        func track(_ track: VideoTrack, didUpdateDimensions dimensions: Dimensions?) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.watched === track else { return }

                self.apply(dimensions)
            }
        }

        /// The picture's own rectangle inside a box, centred — the whole box
        /// until a frame has said what shape it is.
        ///
        /// `VideoView` in `.fit` already letterboxes inside whatever frame it
        /// is given, so this changes nothing about the picture; what it moves
        /// is the *view*, so the tile's own ground shows around a share
        /// instead of a black band the width of the row. The web hugs the
        /// picture the same way and the Android tile has `fitted()`.
        func fitted(_ box: CGRect) -> CGRect {
            guard pictureRatio > 0, box.width > 0, box.height > 0 else { return box }

            let shape = box.width / box.height

            if abs(shape - pictureRatio) < 0.001 { return box }

            if pictureRatio > shape {
                let height = box.width / pictureRatio

                return CGRect(x: box.minX, y: box.midY - height / 2, width: box.width, height: height)
            }

            let width = box.height * pictureRatio

            return CGRect(x: box.midX - width / 2, y: box.minY, width: width, height: box.height)
        }

        fileprivate func bind(_ cell: Cell, online: Set<Int>) {
            let who = cell.person
            // A shared screen is what the person meant to be looked at, so it
            // takes the tile — and their camera goes in the corner of the same
            // tile rather than being lost, exactly as the web's item does.
            let sharing = who.screen != nil
            let shown = sharing ? who.screen : who.video

            person = who
            showsScreen = sharing

            if video.track !== shown { video.track = shown }

            // And what shape it is, which decides how much of the list a
            // shared screen gets and how wide a cell holding one has to be.
            watch(shown)

            // The web fits, it does not crop. `.bm-group-call-input-video-inner
            // video` is `object-fit: contain`, and the `cover` variant beside
            // it is behind a `.bm-cover-video` class nothing ever sets — so a
            // grid tile letterboxes and shows the whole frame. Filling here
            // cut the sides off every portrait phone camera in the grid.
            video.layoutMode = .fit

            video.isHidden = shown == nil

            let inset = (sharing && !isRow) ? who.video : nil

            if cameraInset.track !== inset { cameraInset.track = inset }

            cameraInset.isHidden = inset == nil

            handChip.isHidden = !who.handRaised

            // Someone who may not publish is a viewer, and the web says so on
            // the tile rather than leaving an unexplained empty square.
            let isViewer = !who.canPublish

            label.text = who.name

            // A muted person is worth marking, because in a grid the absence
            // of a speaking ring reads the same as silence. Marked the way the
            // web marks it: the struck-through microphone, and the word. The
            // list says it both ways — the web's audio row draws a microphone
            // whether it is on or off, so silence is never the absence of a
            // mark.
            if isRow {
                micChip.isHidden = isViewer
                mic.set(who.muted ? BmCallsIcons.micOff : BmCallsIcons.mic)

                // Red for off, translucent green for on — the two states the
                // web's `bm-mic-disabled` / `bm-mic-enabled` chips carry.
                micChip.backgroundColor = who.muted
                    ? BmCallsTheme.recording.withAlphaComponent(0.92)
                    : BmCallsTheme.success.withAlphaComponent(0.22)

                mic.color = who.muted ? .white : BmCallsTheme.success
            } else {
                micChip.isHidden = !who.muted
                mic.set(BmCallsIcons.micOff)
                micChip.backgroundColor = BmCallsTheme.recording.withAlphaComponent(0.92)
                mic.color = .white
            }

            viewer.isHidden = !isViewer
            // Two words for the same rule, because the web uses two: someone
            // who cannot publish is a viewer of a video room and a listener to
            // an audio one.
            viewer.text = (isRow
                ? BmCallsTheme.string("listener", fallback: "Listener")
                : BmCallsTheme.string("viewer", fallback: "Viewer")).uppercased()

            if who.speaking {
                // The web scales its glow with how loudly the person is
                // talking, clamped so that a whisper is still visible and a
                // shout does not take over the tile. Same curve here.
                let level = min(max(who.audioLevel * 100 * 5, 15), 90) / 100

                layer.borderWidth = CGFloat(1 + level * 3)
                layer.borderColor = BmCallsTheme.accent.cgColor
            } else {
                layer.borderWidth = 0
            }

            // In a row the avatar always shows: the screen sits above the info
            // line rather than in place of it.
            let covered = isRow ? false : shown != nil

            initial.isHidden = covered || !who.avatar.isEmpty
            picture.isHidden = covered || who.avatar.isEmpty
            initial.text = who.name.first.map { String($0).uppercased() } ?? "?"

            // `user_<id>` is the only thing LiveKit knows anyone by, and it is
            // what the page's presence list is keyed on too.
            let userId = Int(who.identity.replacingOccurrences(of: "user_", with: "")) ?? 0

            dot.isHidden = covered || userId == 0 || !online.contains(userId)

            if avatarUrl != who.avatar {
                avatarUrl = who.avatar
                picture.image = nil

                BmCallsAvatars.load(who.avatar) { [weak self] image in
                    guard let self = self, self.avatarUrl == who.avatar else { return }

                    self.picture.image = image
                    self.picture.isHidden = image == nil || (!self.isRow && !self.video.isHidden)
                    self.initial.isHidden = image != nil || (!self.isRow && !self.video.isHidden)
                }
            }

            // The host's own view over the tile, where it gives one (BmCallsPieces): the same view again stays.
            let own = BmCallsPiecesStore.current.tile?(who)
            if own !== piece {
                piece?.removeFromSuperview()
                piece = own
                if let own { addSubview(own) }
            }

            setNeedsLayout()
        }

        /// The host's view over this tile (BmCallsPieces).
        private var piece: UIView?

        override func layoutSubviews() {
            super.layoutSubviews()

            if isRow { layoutRow() } else { layoutTile() }

            if let piece {
                piece.frame = bounds
                bringSubviewToFront(piece)
            }
        }

        private func layoutTile() {
            video.frame = bounds

            // `.bm-small-video`: eight points in from the bottom-right corner,
            // no taller than 72, and never more than a third of the tile it is
            // sitting in.
            let height = min(72, bounds.height / 3)
            let width = min(height * 16 / 9, bounds.width / 3)

            cameraInset.frame = CGRect(
                x: bounds.width - width - 8,
                y: bounds.height - height - 8,
                width: width,
                height: height
            )

            let size: CGFloat = 56

            picture.frame = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
            picture.layer.cornerRadius = size / 2

            initial.frame = bounds

            // A fifth of the picture, which is what the stylesheet asks for.
            place(dot, on: picture.frame, size: (size * 0.2).rounded())

            // Where the stylesheet puts them, which is not where these were.
            //
            //   .bm-group-call-input-video-inner-info  bottom: 0; padding: 8px;
            //                                          padding-inline-end: 40px
            //   .bm-caller-status                      bottom: 8px; end: 8px
            //   .bm-hand-raised-status                 top: 8px; end: 8px
            //   .bm-viewer-badge                       top: 8px; end: 8px
            //
            // So the name runs along the bottom from the start edge, and the
            // crossed-out microphone sits at the end of the same line with the
            // name held clear of it. This had the name centred on the bottom
            // edge — where the dock lands on it — and the microphone alone in
            // the top corner.
            let chip: CGFloat = 24
            let pad: CGFloat = 8

            label.textAlignment = .natural
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.frame = CGRect(
                x: pad,
                y: bounds.height - pad - chip,
                width: max(0, bounds.width - pad * 2 - chip - pad),
                height: chip
            )

            chipFrame(handChip, icon: hand, rect: CGRect(x: bounds.width - chip - pad, y: pad, width: chip, height: chip))
            chipFrame(
                micChip,
                icon: mic,
                rect: CGRect(x: bounds.width - chip - pad, y: bounds.height - chip - pad, width: chip, height: chip)
            )

            // Under the hand, which shares the top end corner with it — the
            // stylesheet drops one of them to `top: 40px` when both are up.
            pill(viewer, right: bounds.width - pad, centreY: pad + chip + pad + 9)
        }

        /// Bottom-right of the avatar and a point past it, so the picture can
        /// go on clipping itself to a circle.
        ///
        /// `size` is the dot the stylesheet asks for; the view is a point
        /// wider on each side so the hairline ring lands *around* it rather
        /// than eating into it, which is what a CALayer border would do.
        private func place(_ view: UIView, on avatar: CGRect, size: CGFloat) {
            let outer = size + 2

            view.frame = CGRect(x: avatar.maxX - outer + 1, y: avatar.maxY - outer + 1, width: outer, height: outer)
            view.layer.cornerRadius = outer / 2
        }

        /// A disc with the glyph inset, the way the stylesheet's call chip is
        /// drawn — the icon view fills whatever it is given, so the padding has
        /// to be a frame rather than a margin.
        private func chipFrame(_ chip: UIView, icon: UIView, rect: CGRect) {
            chip.frame = rect
            chip.layer.cornerRadius = rect.height / 2

            let inset = rect.height <= 24 ? CGFloat(5) : CGFloat(6)

            icon.frame = chip.bounds.insetBy(dx: inset, dy: inset)
        }

        /// The listener badge: a pill sized to its own word, ending at `right`.
        @discardableResult
        private func pill(_ label: UILabel, right: CGFloat, centreY: CGFloat) -> CGFloat {
            let width = min(140, label.intrinsicContentSize.width + 16)

            label.frame = CGRect(x: right - width, y: centreY - 9, width: width, height: 18)
            label.layer.cornerRadius = 9

            return width
        }

        /// `[ avatar ] name … [ listener ] [ hand ] [ mic ]`, over the screen
        /// when there is one — the web's audio row, in the same order.
        private func layoutRow() {
            let info = CGRect(
                x: 0,
                y: bounds.height - Tile.rowHeight,
                width: bounds.width,
                height: Tile.rowHeight
            )

            // The picture at its own shape rather than stretched across the
            // row. A phone's shared screen is taller than it is wide and would
            // otherwise sit as a narrow strip down the middle of a black band
            // the full width of the row.
            video.frame = fitted(CGRect(x: 0, y: 0, width: bounds.width, height: info.minY))

            let size: CGFloat = 40

            picture.frame = CGRect(x: 10, y: info.midY - size / 2, width: size, height: size)
            picture.layer.cornerRadius = size / 2

            initial.frame = picture.frame

            place(dot, on: picture.frame, size: (size * 0.2).rounded())

            var right = bounds.width - 10
            let chip: CGFloat = 28

            if !micChip.isHidden {
                chipFrame(micChip, icon: mic, rect: CGRect(x: right - chip, y: info.midY - chip / 2, width: chip, height: chip))
                right -= chip + 6
            }

            if !handChip.isHidden {
                chipFrame(handChip, icon: hand, rect: CGRect(x: right - chip, y: info.midY - chip / 2, width: chip, height: chip))
                right -= chip + 6
            }

            if !viewer.isHidden {
                right -= pill(viewer, right: right, centreY: info.midY) + 6
            }

            label.textAlignment = .natural
            label.font = .systemFont(ofSize: 14, weight: .semibold)
            label.frame = CGRect(
                x: picture.frame.maxX + 10,
                y: info.midY - 10,
                width: max(0, right - picture.frame.maxX - 10),
                height: 20
            )
        }
    }

    private var tiles: [Tile] = []
    private var cells: [Cell] = []
    /// How many of them are the web's "primary" row — pinned, or speaking in a
    /// broadcast. They are the first cells, so a count is all the layout needs.
    private var primaryCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)

        scroll.showsVerticalScrollIndicator = false
        scroll.isScrollEnabled = false
        scroll.alwaysBounceVertical = false
        scroll.delegate = self

        addSubview(scroll)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Redraw for whoever is in the room now.
    func show(_ participants: [BmCallsRoomParticipant]) {
        isHidden = participants.isEmpty

        if participants.isEmpty {
            tiles.forEach {
                $0.release()
                $0.removeFromSuperview()
            }

            tiles = []
            cells = []
            primaryCount = 0
            return
        }

        var built: [Cell]

        if audioRoom {
            // The web's own order for a list: whoever is sharing first, then
            // everyone with a microphone on, then the rest. A row that jumps
            // about is unreadable, so within each group the roster's order is
            // kept as it is.
            let sharing = participants.filter { $0.screen != nil }
            let talking = participants.filter { $0.screen == nil && !$0.muted }
            let quiet = participants.filter { $0.screen == nil && $0.muted }

            built = (sharing + talking + quiet).map { Cell(person: $0) }
            primaryCount = 0
        } else {
            // The web's own split. Whoever is pinned goes in the primary row,
            // and so does anyone who may publish while the room is
            // broadcasting — those are the people the room is there to watch.
            let primary = participants.filter { $0.isPinned || (broadcastRoom && ($0.canPublish || $0.canAdmin)) }
            let taken = Set(primary.map { $0.identity })
            let rest = participants.filter { !taken.contains($0.identity) }

            // And its order for the rest: anyone with a picture first, then
            // whoever is talking, then everybody else — a phone shows very few
            // tiles, so what is in them matters more than anywhere else.
            let seen = rest.filter { $0.video != nil || $0.screen != nil }
            let heard = rest.filter { $0.video == nil && $0.screen == nil && $0.speaking }
            let quiet = rest.filter { $0.video == nil && $0.screen == nil && !$0.speaking }

            // And your own tile last, wherever the ordering above left it.
            // The web moves it to the end of the page for the same reason —
            // you know what you look like, and the screen is for the people
            // you are talking to. It arrives first in the roster, so without
            // this a call between two people put you on top and them
            // underneath, which is the wrong way round on every platform.
            //
            // Not out of the primary row: a pinned tile, or a speaker in a
            // broadcast room, is what the room came to watch and stays where
            // it is. The web guards the same way.
            let ordered = seen + heard + quiet

            built = (primary + ordered.filter { !$0.isLocal } + ordered.filter { $0.isLocal })
                .map { Cell(person: $0) }

            primaryCount = primary.count
        }

        cells = built

        while tiles.count < cells.count {
            let tile = Tile()

            tile.isRow = audioRoom

            // A picture reporting its shape changes how much room its tile
            // wants, and that is worked out here rather than in the tile.
            tile.onShape = { [weak self] in self?.setNeedsLayout() }

            tile.addGestureRecognizer(
                UILongPressGestureRecognizer(target: self, action: #selector(tileHeld(_:)))
            )

            tiles.append(tile)
            scroll.addSubview(tile)
        }

        // Anyone who left takes their renderer with them.
        while tiles.count > cells.count {
            let tile = tiles.removeLast()

            tile.release()
            tile.removeFromSuperview()
        }

        rebind()
    }

    /// Redraw what is already there. Presence moves while a call runs and
    /// nobody joins or leaves when it does.
    private func rebind() {
        for (index, cell) in cells.enumerated() where index < tiles.count {
            tiles[index].isRow = audioRoom
            tiles[index].bind(cell, online: online)
        }

        setNeedsLayout()
    }

    /// Stop paying for the tiles nobody can see.
    ///
    /// The SDK's adaptive stream decides a `VideoView` is worth receiving from
    /// `didLayout && !isHidden && isEnabled` — it has no idea whether the view
    /// is actually on screen, so a tile scrolled below the fold goes on being
    /// subscribed and decoded. (The web does not have this problem: LiveKit's
    /// browser SDK watches an `IntersectionObserver`, which is what makes its
    /// own sideways paging free.)
    ///
    /// `isEnabled` is the SDK's own hook for exactly this — "useful for
    /// performance optimizations with UICollectionViewCell etc." — and turning
    /// it off both pauses the renderer and drops the subscription, so the
    /// server stops sending within the adaptive stream's 0.3 s tick.
    private func cullOffscreen() {
        let visible = CGRect(origin: scroll.contentOffset, size: scroll.bounds.size)

        for tile in tiles {
            // A pinned tile lives outside the scroller and is always on show.
            let shown = tile.superview === scroll ? tile.frame.intersects(visible) : true

            tile.video.isEnabled = shown
            tile.cameraInset.isEnabled = shown
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        cullOffscreen()
    }

    @objc private func tileHeld(_ recogniser: UILongPressGestureRecognizer) {
        guard
            recogniser.state == .began,
            let tile = recogniser.view as? Tile,
            let person = tile.person
        else { return }

        onPerson?(person)
    }

    /// Laid out by hand rather than with constraints: the shape changes with
    /// the head count, and rebuilding a constraint set on every join is both
    /// slower and easier to get wrong than arithmetic.
    override func layoutSubviews() {
        super.layoutSubviews()

        scroll.frame = bounds

        guard !tiles.isEmpty else {
            scroll.contentSize = bounds.size
            return
        }

        if audioRoom {
            layoutList()
            return
        }

        layoutWall()
    }

    /// The web's `group-video-grid.tsx`, on a phone.
    ///
    /// Two bands. Whoever is pinned — or, in a broadcast, whoever may speak —
    /// fills a single column down everything but the last hundred points;
    /// everybody else shares that hundred-point strip. With nobody pinned in
    /// an ordinary room there is no primary band at all and the rest take the
    /// whole area, which is the common case on a phone.
    private func layoutWall() {
        let strip: CGFloat = 100
        let primary = min(primaryCount, tiles.count)
        let rest = Array(tiles.dropFirst(primary))

        // The primary band sits *outside* the scroller. The web keeps it still
        // and pages the strip beneath it sideways, and a pinned tile that
        // scrolled away with the strip would be the opposite of pinned.
        for tile in tiles.prefix(primary) where tile.superview !== self {
            addSubview(tile)
        }

        for tile in rest where tile.superview !== scroll {
            scroll.addSubview(tile)
        }

        var box = CGRect(origin: .zero, size: bounds.size)
        var beside = false

        if primary > 0 {
            // A picture taller than it is wide cannot be handed the whole
            // width: the band is then mostly the ground either side of it.
            // Somebody sharing a phone is exactly that — about 9:19.5 — and
            // the stack was the only division this had, so pinning their share
            // drew it as a narrow strip down the middle of a very wide band
            // with everyone else squashed into a hundred points underneath.
            //
            // A tall band stands beside the rest instead, keeping its own
            // shape and taking only the width that shape needs; the others
            // have what is left, as a column rather than a strip. Only on a
            // screen wider than it is tall — a phone turned on its side —
            // only when there is room for a tile either side of the division,
            // and only when there is anybody to stand beside: with everyone
            // pinned the band is the whole call and takes the whole screen.
            // The web divides on the same four tests.
            let shape = tallest(tiles.prefix(primary))
            let minStrip = Self.minStrip * Self.tileRatio

            beside = shape < 1
                && !rest.isEmpty
                && bounds.width > bounds.height
                && bounds.width > minStrip * 2

            // `isMobile()` in the web: the primary row is one column of them,
            // however many there are.
            let height = (beside || rest.isEmpty ? bounds.height : bounds.height - strip) / CGFloat(primary)

            let width = beside
                ? min(max(bounds.height / CGFloat(primary) * shape, minStrip), bounds.width - minStrip)
                : bounds.width

            for (index, tile) in tiles.prefix(primary).enumerated() {
                tile.frame = inset(CGRect(x: 0, y: CGFloat(index) * height, width: width, height: height))
            }

            box = beside
                ? CGRect(x: width, y: 0, width: bounds.width - width, height: bounds.height)
                : CGRect(x: 0, y: bounds.height - strip, width: bounds.width, height: strip)
        }

        scroll.frame = box

        guard !rest.isEmpty else {
            scroll.contentSize = box.size
            scroll.isScrollEnabled = false

            return
        }

        if primary > 0 && !beside {
            // One row running off to the right, which is where the web's own
            // strip puts the overflow — `overflow-x: auto`, no pager.
            let width = stripWidth(box.size, ratio: widest(rest))

            for (index, tile) in rest.enumerated() {
                tile.frame = inset(CGRect(x: CGFloat(index) * width, y: 0, width: width, height: box.height))
            }

            scroll.contentSize = CGSize(width: CGFloat(rest.count) * width, height: box.height)
        } else {
            // Beside a tall band this is a column and not a strip, so it is
            // laid out as a wall too — which is what the web does with it.
            let shape = wallShape(count: rest.count, box: box.size, ratio: widest(rest))
            let width = box.width / CGFloat(shape.columns)
            let height = box.height / CGFloat(shape.rows)

            for (index, tile) in rest.enumerated() {
                tile.frame = inset(CGRect(
                    x: CGFloat(index % shape.columns) * width,
                    y: CGFloat(index / shape.columns) * height,
                    width: width,
                    height: height
                ))
            }

            // With no band above it the web pages sideways too; a full-height
            // wall scrolls down instead, which is the gesture people already
            // make here. Either way each tile keeps the size the web would
            // have drawn it at.
            let drawn = Int(ceil(Double(rest.count) / Double(shape.columns)))

            scroll.contentSize = CGSize(width: box.width, height: max(box.height, CGFloat(drawn) * height))
        }

        scroll.isScrollEnabled = scroll.contentSize.width > box.width || scroll.contentSize.height > box.height

        cullOffscreen()
    }

    /// How wide one tile is in the strip under a pinned speaker.
    ///
    /// Not the strip divided by the people in it. A strip is one tile tall and
    /// the web lays it out by how many tiles fit across it, paging sideways
    /// past that:
    ///
    ///     itemWidth = stripHeight × ratio
    ///     columns   = ceil(width / itemWidth)
    ///
    /// So one person beside a pinned speaker gets a third of the width, not
    /// all of it, and the strip looks the same whether one person is in it or
    /// nine.
    ///
    /// The ratio is the widest picture in the strip rather than 16:9, because
    /// a cell has to hold whatever lands in it — a screen shared from a laptop
    /// is wider than a camera, and one shared from a phone is narrower.
    private func stripWidth(_ box: CGSize, ratio: CGFloat) -> CGFloat {
        let item = box.height * ratio

        guard item > 0 else { return box.width }

        let columns = max(1, Int(ceil(box.width / item)))

        return box.width / CGFloat(columns)
    }

    /// The widest picture among these tiles, and `tileRatio` when none of them
    /// has said what shape it is yet.
    ///
    /// The widest, because a cell has to hold whichever picture lands in it
    /// and the widest is the one that needs the most room. The web works the
    /// same figure out under the same name, `maxRatio`.
    private func widest<S: Sequence>(_ of: S) -> CGFloat where S.Element == Tile {
        of.reduce(Self.tileRatio) { max($0, $1.pictureRatio) }
    }

    /// The tallest — the smallest ratio — for the band a pinned tile is drawn
    /// in, because that is the shape the band has to make room for. The web's
    /// `minRatio`. A tile that has not reported is left out of the reckoning
    /// rather than counted as 16:9.
    private func tallest<S: Sequence>(_ of: S) -> CGFloat where S.Element == Tile {
        of.reduce(Self.tileRatio) { $1.pictureRatio > 0 ? min($0, $1.pictureRatio) : $0 }
    }

    /// The arrangement that makes the pictures biggest.
    ///
    /// Every column count is a candidate. Each one implies a number of rows,
    /// and so a cell of `width / columns` by `height / rows`; the picture
    /// letterboxed into that cell — which is what the renderer draws — has an
    /// area. The largest area wins. One loop, no special cases, and it answers
    /// for any number of people on any screen.
    ///
    /// The picture, not a 16:9 one: `ratio` is what is actually being drawn,
    /// because a phone sharing its screen publishes something taller than it
    /// is wide and a cell shaped for a camera has no room for it.
    ///
    /// It is why two people stack on a phone held upright and sit side by side
    /// on its side, without either being written down: at 402 by 874 one column
    /// of two fits a 402-wide picture and two columns of one fit a 201-wide
    /// one, and turning the phone reverses it exactly.
    ///
    /// What it replaces was `ceil(sqrt(count))` walked down until the tiles
    /// cleared a minimum, and then `if count == 2 { one column }` on top of
    /// that — at every size, which is what the web says too. That is why a
    /// phone turned on its side showed two very wide letterboxes with a small
    /// avatar in each.
    ///
    /// The minimum stays as a ceiling on how many tiles may share a screen: a
    /// phone showing nine faces is showing nine thumbnails. Anything past what
    /// fits scrolls, as it did before.
    private func wallShape(count: Int, box: CGSize, ratio: CGFloat) -> (columns: Int, rows: Int) {
        guard count > 0, box.width > 0, box.height > 0 else { return (1, 1) }

        let minHeight = Self.minStrip
        let minWidth = minHeight * ratio

        let mostColumns = min(count, max(1, Int(box.width / minWidth)))
        let mostRows = max(1, Int(box.height / minHeight))

        var best = (columns: 1, rows: count)
        var bestArea: CGFloat = -1

        for columns in 1...mostColumns {
            let needed = Int(ceil(Double(count) / Double(columns)))
            let rows = min(needed, mostRows)

            let cellWidth = box.width / CGFloat(columns)
            let cellHeight = box.height / CGFloat(rows)

            // The picture inside the cell, letterboxed the way the renderer
            // letterboxes it. The cell's own area would pick the arrangement
            // with the least dead space rather than the biggest faces.
            let drawn = min(cellWidth, cellHeight * ratio)
            let area = drawn * (drawn / ratio)

            if area > bestArea {
                bestArea = area
                best = (columns, rows)
            }
        }

        return best
    }

    /// The gap between tiles, taken out of the cell rather than added to it,
    /// so the arithmetic above stays the web's.
    private func inset(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: 2, dy: 2)
    }

    /// One row per person down the page, the web's 10-point margin and
    /// 8-point gap, scrolling when there are more people than fit.
    ///
    /// Somebody sharing their screen takes the stage.
    ///
    /// An audio call has no pictures in it, so this is a list of rows — and a
    /// share used to be squeezed into the sharer's row as a band of at most
    /// 320 points, drawn as a 16:9 picture whatever it actually was. That was
    /// tolerable while a share was a laptop's. A phone's is about 9:19.5, and
    /// the same band drew it as a sliver a seventh of the row wide with the
    /// rest of the row black, under a screenful of list nothing was using.
    ///
    /// So a sharing row takes the height the roster does not need, the way the
    /// web's `flex: 1 1 auto` does, and keeps a floor of 45% of the screen
    /// when the roster is long enough to want all of it — the list scrolls
    /// rather than squeezing the thing everyone is looking at. Two people
    /// sharing at once halve the stage between them, which falls out of the
    /// arithmetic rather than being written down.
    private func layoutList() {
        let inset: CGFloat = 10
        let gap: CGFloat = 8
        let width = max(0, bounds.width - inset * 2)

        // A list has no primary band, so nothing belongs outside the scroller.
        for tile in tiles where tile.superview !== scroll {
            scroll.addSubview(tile)
        }

        let sharing = tiles.filter { $0.showsScreen }.count
        let rows = CGFloat(tiles.count - sharing) * Tile.rowHeight
        let gaps = CGFloat(max(0, tiles.count - 1)) * gap
        let spare = bounds.height - inset * 2 - rows - gaps

        var stage: CGFloat = 0

        if sharing > 0 {
            stage = max(spare / CGFloat(sharing), max(bounds.height * 0.45, Tile.rowHeight + 60))
        }

        var top = inset

        for tile in tiles {
            let height = tile.showsScreen ? stage : Tile.rowHeight

            tile.frame = CGRect(x: inset, y: top, width: width, height: height)

            top += height + gap
        }

        scroll.contentSize = CGSize(width: bounds.width, height: max(bounds.height, top - gap + inset))
        scroll.isScrollEnabled = scroll.contentSize.height > bounds.height

        cullOffscreen()
    }
}
