import UIKit

/// A moderator's menu as the web draws it (realtime-ui's moderation-panels.tsx, `.bm-call-popover` and
/// `.bm-call-moderation` in _call-stage.scss): a card beside the button that opened it, on the side asked where it
/// fits or the side with more room, aligned to the button's start edge or held to the stage's end edge as the dock
/// is, no taller than that side's room (the rest scrolls), and placed again as the button moves, a tile pinned or
/// someone made a speaker. Its rows say what they do and, for the room's rules, whether they are on.
///
/// A press outside closes it and still reaches what it was on, as on the web, except the button that opened it,
/// whose own press closes it. Rows take their taps with recognizers of their own: the call screen's stage tap, which
/// puts the dock away, would cancel a plain control's touch under it.
final class CallsPopover: UIView {
    enum Side { case above, below }
    enum Align { case start, stageEnd }
    enum Tone { case danger, warning, neutral }

    /// One thing that is on for a person, as their menu's header says it.
    struct Pill {
        let label: String
        let icon: String
        let tone: Tone
    }

    enum Head {
        /// The room's menu: a badge and a title.
        case room(icon: String, title: String)
        /// A person's: their picture, their name, and what is on for them now.
        case person(name: String, avatar: String, state: [Pill])
    }

    struct Row {
        let key: String
        let icon: String
        let label: String
        var note: String? = nil
        /// A rule the room keeps, drawn with a switch that says whether it is on; nil for an action.
        var on: Bool? = nil
        var danger = false
        /// What the person asked for: promoting someone whose hand is up.
        var highlight = false
        /// Something that can't be done now (a fifth person in the spotlight): dimmed, its press doing nothing, its
        /// note saying why.
        var disabled = false
        /// The row's action, which calls `done` once its request is answered: the row spins until then.
        let run: ( _ done: @escaping () -> Void ) -> Void
    }

    enum Entry {
        case row(Row)
        case divider
    }

    private static let gap: CGFloat = 6
    private static let edge: CGFloat = 8
    // A menu held to the stage's end edge keeps the dock's own clearance from it.
    private static let dockEdge: CGFloat = 14

    private let card = UIView()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    /// Where the menu opens, asked again every frame: the grid gives a person's tile to someone else as the tiles move
    /// round (someone starts talking), so a view held from the first press would lead the menu to the wrong person.
    private let anchorFor: () -> UIView?
    private var anchor: UIView? { anchorFor() }
    private let side: Side
    private let align: Align
    private let width: CGFloat
    private let room: Bool
    private let content: () -> ( Head, [ Entry ] )?
    private var busy: Set<String> = []
    private var link: CADisplayLink?
    private var placedFor: CGRect = .null
    private var closing = false

    /// Called once the menu is gone, whichever way it went.
    var onClose: ( () -> Void )?

    /// `content` is asked again on `refresh()`: nil when there is nothing left to show, a person who left.
    init( anchor: @escaping () -> UIView?, side: Side, align: Align, width: CGFloat, room: Bool, content: @escaping () -> ( Head, [ Entry ] )? ) {
        self.anchorFor = anchor
        self.side = side
        self.align = align
        self.width = width
        self.room = room
        self.content = content

        super.init( frame: .zero )

        backgroundColor = .clear

        card.backgroundColor = UIColor( red: 22 / 255, green: 24 / 255, blue: 30 / 255, alpha: 0.97 )
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor( white: 1, alpha: 0.09 ).cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.5
        card.layer.shadowRadius = 24
        card.layer.shadowOffset = CGSize( width: 0, height: 18 )
        card.accessibilityViewIsModal = true

        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.layer.cornerRadius = 14
        scroll.layer.cornerCurve = .continuous
        scroll.clipsToBounds = true

        stack.axis = .vertical
        stack.spacing = room ? 4 : 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let padding: CGFloat = room ? 8 : 6

        scroll.addSubview( stack )
        card.addSubview( scroll )
        addSubview( card )

        NSLayoutConstraint.activate( [
            stack.topAnchor.constraint( equalTo: scroll.contentLayoutGuide.topAnchor, constant: padding ),
            stack.bottomAnchor.constraint( equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -padding ),
            stack.leadingAnchor.constraint( equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: padding ),
            stack.trailingAnchor.constraint( equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -padding ),
        ] )

        fill()
    }

    required init?( coder: NSCoder ) { fatalError( "init(coder:) has not been implemented" ) }

    /// Over the whole of `host`, its card beside the anchor, and placed again every frame the anchor moves.
    func place( in host: UIView ) {
        frame = host.bounds
        autoresizingMask = [ .flexibleWidth, .flexibleHeight ]
        host.addSubview( self )
        measure()

        card.alpha = 0
        card.transform = CGAffineTransform( translationX: 0, y: isAbove ? 4 : -4 ).scaledBy( x: 0.98, y: 0.98 )

        UIView.animate( withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.14, delay: 0, options: [ .curveEaseOut ] ) {
            self.card.alpha = 1
            self.card.transform = .identity
        }

        let link = CADisplayLink( target: self, selector: #selector( follow ) )
        link.add( to: .main, forMode: .common )
        self.link = link

        UIAccessibility.post( notification: .screenChanged, argument: card )
    }

    /// The rows again, from what is on now: after a request is answered, or the room or the person changed.
    func refresh() {
        guard !closing else { return }

        let before = drawn

        fill()

        // Placed again only when its rows changed, and so perhaps its height.
        guard drawn != before, !closing else { return }

        placedFor = .null
        measure()
    }

    func close() {
        guard !closing else { return }

        closing = true
        link?.invalidate()
        link = nil

        UIView.animate( withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.1, animations: {
            self.card.alpha = 0
        }, completion: { _ in
            self.removeFromSuperview()
        } )

        onClose?()
    }

    override func hitTest( _ point: CGPoint, with event: UIEvent? ) -> UIView? {
        if !closing, card.frame.contains( point ) {
            return super.hitTest( point, with: event )
        }

        // Outside the card: the menu goes, and the press reaches what it was on. The button that opened it is left
        // to close it, or it would close here and open again under the same press.
        if !closing, event?.type == .touches, let anchor, anchor.window != nil {
            let onAnchor = anchor.bounds.contains( convert( point, to: anchor ) )

            if !onAnchor {
                DispatchQueue.main.async { [weak self] in self?.close() }
            }
        }

        return nil
    }

    // MARK: Placing

    private var isAbove = false

    @objc private func follow() {
        guard let anchor, anchor.window != nil, superview != nil else {
            close()
            return
        }

        let now = anchor.convert( anchor.bounds, to: self )

        guard now != placedFor else { return }

        measure()
    }

    private func measure() {
        guard let anchor else { return }

        // Clear of the status bar and the home indicator both.
        let stage = bounds.inset( by: UIEdgeInsets( top: safeAreaInsets.top, left: 0, bottom: safeAreaInsets.bottom, right: 0 ) )
        let a = anchor.convert( anchor.bounds, to: self )
        let shownWidth = min( width, stage.width - Self.edge * 2 )

        let fitting = stack.systemLayoutSizeFitting(
            CGSize( width: shownWidth - ( room ? 16 : 12 ), height: 0 ),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let height = fitting.height + ( room ? 16 : 12 )

        let above = a.minY - stage.minY - Self.gap - Self.edge
        let below = stage.maxY - a.maxY - Self.gap - Self.edge
        let up = side == .above ? ( height <= above || above >= below ) : ( height > below && above > below )
        let roomShown = max( 80, up ? above : below )
        let shown = min( height, roomShown )

        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let left: CGFloat

        switch align {
        case .stageEnd:
            left = rtl ? Self.dockEdge : max( Self.edge, stage.width - shownWidth - Self.dockEdge )
        case .start:
            let wanted = rtl ? a.maxX - shownWidth : a.minX
            left = max( Self.edge, min( stage.width - shownWidth - Self.edge, wanted ) )
        }

        let top = up ? a.minY - Self.gap - shown : a.maxY + Self.gap

        isAbove = up
        placedFor = a
        card.bounds = CGRect( x: 0, y: 0, width: shownWidth, height: shown )
        card.center = CGPoint( x: left + shownWidth / 2, y: top + shown / 2 )
        card.layer.shadowPath = UIBezierPath( roundedRect: card.bounds, cornerRadius: 14 ).cgPath
        scroll.frame = card.bounds
        scroll.isScrollEnabled = height > shown
    }

    // MARK: Drawing

    /// What the rows said when they were last drawn: the roster comes again many times a second while someone talks,
    /// and the menu is drawn again only when what it says has changed.
    private var drawn = ""

    private func fill() {
        guard let ( head, entries ) = content() else {
            close()
            return
        }

        let said = fingerprint( head, entries )

        guard said != drawn else { return }

        drawn = said
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        stack.addArrangedSubview( headView( head ) )

        for entry in entries {
            switch entry {
            case .divider:
                stack.addArrangedSubview( divider() )
            case .row( let row ):
                stack.addArrangedSubview( rowView( row ) )
            }
        }
    }

    private func fingerprint( _ head: Head, _ entries: [ Entry ] ) -> String {
        var parts: [ String ] = []

        switch head {
        case let .room( icon, title ): parts.append( "room|\( icon )|\( title )" )
        case let .person( name, avatar, state ): parts.append( "person|\( name )|\( avatar )|" + state.map { "\( $0.label ),\( $0.tone )" }.joined( separator: ";" ) )
        }

        for entry in entries {
            switch entry {
            case .divider: parts.append( "-" )
            case .row( let row ):
                parts.append( [ row.key, row.icon, row.label, row.note ?? "", String( describing: row.on ), "\( row.danger )", "\( row.highlight )", "\( row.disabled )", "\( busy.contains( row.key ) )" ].joined( separator: "|" ) )
            }
        }

        return parts.joined( separator: "\n" )
    }

    private func headView( _ head: Head ) -> UIView {
        let holder = UIView()
        let line = UIStackView()

        line.translatesAutoresizingMaskIntoConstraints = false
        line.axis = .horizontal
        line.alignment = .center
        line.spacing = room ? 14 : 10

        switch head {
        case let .room( icon, title ):
            let badge = UIView()
            badge.backgroundColor = CallsTheme.accent.withAlphaComponent( 0.2 )
            badge.layer.cornerRadius = 10
            badge.layer.cornerCurve = .continuous

            let glyph = CallsIconView( icon )
            glyph.color = CallsTheme.accent
            glyph.translatesAutoresizingMaskIntoConstraints = false
            badge.addSubview( glyph )

            NSLayoutConstraint.activate( [
                badge.widthAnchor.constraint( equalToConstant: 34 ),
                badge.heightAnchor.constraint( equalToConstant: 34 ),
                glyph.widthAnchor.constraint( equalToConstant: 18 ),
                glyph.heightAnchor.constraint( equalToConstant: 18 ),
                glyph.centerXAnchor.constraint( equalTo: badge.centerXAnchor ),
                glyph.centerYAnchor.constraint( equalTo: badge.centerYAnchor ),
            ] )

            line.addArrangedSubview( badge )
            line.addArrangedSubview( titleLabel( title ) )
            line.addArrangedSubview( UIView() )

        case let .person( name, avatar, state ):
            let picture = UIImageView()
            picture.contentMode = .scaleAspectFill
            picture.clipsToBounds = true
            picture.layer.cornerRadius = 16
            picture.backgroundColor = UIColor( white: 1, alpha: 0.12 )
            picture.translatesAutoresizingMaskIntoConstraints = false

            let initial = UILabel()
            initial.text = name.first.map { String( $0 ).uppercased() } ?? ""
            initial.font = .systemFont( ofSize: 14, weight: .semibold )
            initial.textColor = .white
            initial.textAlignment = .center
            initial.translatesAutoresizingMaskIntoConstraints = false
            picture.addSubview( initial )

            NSLayoutConstraint.activate( [
                picture.widthAnchor.constraint( equalToConstant: 32 ),
                picture.heightAnchor.constraint( equalToConstant: 32 ),
                initial.centerXAnchor.constraint( equalTo: picture.centerXAnchor ),
                initial.centerYAnchor.constraint( equalTo: picture.centerYAnchor ),
            ] )

            if !avatar.isEmpty {
                CallsAvatars.load( avatar ) { [weak picture, weak initial] image in
                    guard let image else { return }

                    picture?.image = image
                    initial?.isHidden = true
                }
            }

            let who = UIStackView()
            who.axis = .vertical
            who.alignment = .leading
            who.spacing = 4
            who.addArrangedSubview( titleLabel( name ) )

            if !state.isEmpty {
                let pills = UIStackView( arrangedSubviews: state.map( pillView ) )
                pills.axis = .horizontal
                pills.spacing = 4
                pills.alignment = .center
                who.addArrangedSubview( pills )
            }

            line.addArrangedSubview( picture )
            line.addArrangedSubview( who )
        }

        holder.addSubview( line )

        let rule = UIView()
        rule.backgroundColor = UIColor( white: 1, alpha: 0.07 )
        rule.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview( rule )

        let inset = room ? UIEdgeInsets( top: 6, left: 10, bottom: 12, right: 10 ) : UIEdgeInsets( top: 8, left: 8, bottom: 10, right: 8 )

        NSLayoutConstraint.activate( [
            line.topAnchor.constraint( equalTo: holder.topAnchor, constant: inset.top ),
            line.leadingAnchor.constraint( equalTo: holder.leadingAnchor, constant: inset.left ),
            line.trailingAnchor.constraint( equalTo: holder.trailingAnchor, constant: -inset.right ),
            rule.topAnchor.constraint( equalTo: line.bottomAnchor, constant: inset.bottom ),
            rule.leadingAnchor.constraint( equalTo: holder.leadingAnchor ),
            rule.trailingAnchor.constraint( equalTo: holder.trailingAnchor ),
            rule.heightAnchor.constraint( equalToConstant: 1 ),
            rule.bottomAnchor.constraint( equalTo: holder.bottomAnchor, constant: -4 ),
        ] )

        return holder
    }

    private func titleLabel( _ text: String ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont( ofSize: 14, weight: .semibold )
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority( .defaultLow, for: .horizontal )
        return label
    }

    private func pillView( _ pill: Pill ) -> UIView {
        let view = UIView()
        view.layer.cornerRadius = 10

        let fg: UIColor
        switch pill.tone {
        case .danger:
            view.backgroundColor = CallsTheme.recording.withAlphaComponent( 0.2 )
            fg = UIColor( red: 1, green: 150 / 255, blue: 140 / 255, alpha: 1 )
        case .warning:
            view.backgroundColor = CallsTheme.warning.withAlphaComponent( 0.2 )
            fg = CallsTheme.warning
        case .neutral:
            view.backgroundColor = UIColor( white: 1, alpha: 0.1 )
            fg = UIColor( white: 1, alpha: 0.78 )
        }

        let glyph = CallsIconView( pill.icon )
        glyph.color = fg
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = pill.label
        label.font = .systemFont( ofSize: 11, weight: .semibold )
        label.textColor = fg
        label.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview( glyph )
        view.addSubview( label )

        NSLayoutConstraint.activate( [
            view.heightAnchor.constraint( equalToConstant: 20 ),
            glyph.leadingAnchor.constraint( equalTo: view.leadingAnchor, constant: 6 ),
            glyph.centerYAnchor.constraint( equalTo: view.centerYAnchor ),
            glyph.widthAnchor.constraint( equalToConstant: 11 ),
            glyph.heightAnchor.constraint( equalToConstant: 11 ),
            label.leadingAnchor.constraint( equalTo: glyph.trailingAnchor, constant: 4 ),
            label.trailingAnchor.constraint( equalTo: view.trailingAnchor, constant: -8 ),
            label.centerYAnchor.constraint( equalTo: view.centerYAnchor ),
        ] )

        return view
    }

    private func divider() -> UIView {
        let holder = UIView()
        let line = UIView()
        line.backgroundColor = UIColor( white: 1, alpha: 0.08 )
        line.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview( line )

        NSLayoutConstraint.activate( [
            line.heightAnchor.constraint( equalToConstant: 1 ),
            line.topAnchor.constraint( equalTo: holder.topAnchor, constant: 4 ),
            line.bottomAnchor.constraint( equalTo: holder.bottomAnchor, constant: -4 ),
            line.leadingAnchor.constraint( equalTo: holder.leadingAnchor, constant: 8 ),
            line.trailingAnchor.constraint( equalTo: holder.trailingAnchor, constant: -8 ),
        ] )

        return holder
    }

    private func rowView( _ row: Row ) -> UIView {
        let view = CallsPopoverRow( row: row, room: room, busy: busy.contains( row.key ) )

        view.onPress = { [weak self] in
            guard let self, !row.disabled, !self.busy.contains( row.key ) else { return }

            self.busy.insert( row.key )
            self.refresh()

            row.run { [weak self] in
                guard let self else { return }

                self.busy.remove( row.key )
                self.refresh()
            }
        }

        return view
    }
}

/// One row: its glyph (on a tile of its own in the room's menu), what it does and, below, how; and for a rule of the
/// room, its switch.
private final class CallsPopoverRow: UIView {
    var onPress: ( () -> Void )?
    private var dims = false

    init( row: CallsPopover.Row, room: Bool, busy: Bool ) {
        super.init( frame: .zero )

        let danger = UIColor( red: 1, green: 150 / 255, blue: 140 / 255, alpha: 1 )
        let on = row.on == true

        layer.cornerRadius = room ? 11 : 9
        layer.cornerCurve = .continuous
        backgroundColor = row.highlight ? CallsTheme.warning.withAlphaComponent( 0.14 ) : .clear

        isAccessibilityElement = true
        accessibilityLabel = [ row.label, row.note ].compactMap { $0 }.joined( separator: ". " )
        accessibilityTraits = .button
        if let state = row.on { accessibilityValue = state ? "1" : "0" }
        if busy || row.disabled { accessibilityTraits.insert( .notEnabled ) }

        // A row that can't be done now, as the web's `aria-disabled` row: dimmed, and its press shows nothing.
        if row.disabled { alpha = 0.55 }
        dims = row.disabled

        let icon = UIView()
        icon.translatesAutoresizingMaskIntoConstraints = false

        if room {
            icon.layer.cornerRadius = 10
            icon.layer.cornerCurve = .continuous
            icon.backgroundColor = on ? CallsTheme.accent.withAlphaComponent( 0.2 ) : UIColor( white: 1, alpha: 0.07 )
        }

        let glyphColor: UIColor = row.danger ? danger
            : row.highlight ? CallsTheme.warning
            : on ? CallsTheme.accent
            : UIColor( white: 1, alpha: 0.7 )

        if busy {
            let spinner = UIActivityIndicatorView( style: .medium )
            spinner.color = glyphColor
            spinner.startAnimating()
            spinner.translatesAutoresizingMaskIntoConstraints = false
            icon.addSubview( spinner )
            NSLayoutConstraint.activate( [
                spinner.centerXAnchor.constraint( equalTo: icon.centerXAnchor ),
                spinner.centerYAnchor.constraint( equalTo: icon.centerYAnchor ),
            ] )
        } else {
            let glyph = CallsIconView( row.icon )
            glyph.color = glyphColor
            glyph.translatesAutoresizingMaskIntoConstraints = false
            icon.addSubview( glyph )
            NSLayoutConstraint.activate( [
                glyph.widthAnchor.constraint( equalToConstant: 16 ),
                glyph.heightAnchor.constraint( equalToConstant: 16 ),
                glyph.centerXAnchor.constraint( equalTo: icon.centerXAnchor ),
                glyph.centerYAnchor.constraint( equalTo: icon.centerYAnchor ),
            ] )
        }

        let label = UILabel()
        label.text = row.label
        label.font = .systemFont( ofSize: 13, weight: .medium )
        label.textColor = row.danger ? danger : .white
        label.numberOfLines = 0

        let text = UIStackView( arrangedSubviews: [ label ] )
        text.axis = .vertical
        text.spacing = room ? 3 : 2
        text.translatesAutoresizingMaskIntoConstraints = false

        if let note = row.note, !note.isEmpty {
            let line = UILabel()
            line.text = note
            line.font = .systemFont( ofSize: 11.5 )
            line.textColor = UIColor( white: 1, alpha: 0.55 )
            line.numberOfLines = 0
            text.addArrangedSubview( line )
        }

        addSubview( icon )
        addSubview( text )

        let inset = room ? UIEdgeInsets( top: 10, left: 10, bottom: 12, right: 10 ) : UIEdgeInsets( top: 6, left: 8, bottom: 6, right: 8 )
        let iconSize: CGFloat = room ? 34 : 20

        var constraints = [
            heightAnchor.constraint( greaterThanOrEqualToConstant: 36 ),
            icon.widthAnchor.constraint( equalToConstant: iconSize ),
            icon.heightAnchor.constraint( equalToConstant: iconSize ),
            icon.leadingAnchor.constraint( equalTo: leadingAnchor, constant: inset.left ),
            text.leadingAnchor.constraint( equalTo: icon.trailingAnchor, constant: room ? 14 : 10 ),
            text.bottomAnchor.constraint( lessThanOrEqualTo: bottomAnchor, constant: -inset.bottom ),
            icon.bottomAnchor.constraint( lessThanOrEqualTo: bottomAnchor, constant: -inset.bottom ),
        ]

        if room {
            // The text starts level with the tile's top, the switch level with the title.
            constraints += [
                icon.topAnchor.constraint( equalTo: topAnchor, constant: inset.top ),
                text.topAnchor.constraint( equalTo: topAnchor, constant: inset.top ),
            ]
        } else {
            constraints += [
                icon.centerYAnchor.constraint( equalTo: centerYAnchor ),
                text.topAnchor.constraint( greaterThanOrEqualTo: topAnchor, constant: inset.top ),
                text.centerYAnchor.constraint( equalTo: centerYAnchor ),
            ]
        }

        if row.on != nil {
            let toggle = CallsSwitch( on: on )
            toggle.translatesAutoresizingMaskIntoConstraints = false
            addSubview( toggle )
            constraints += [
                toggle.trailingAnchor.constraint( equalTo: trailingAnchor, constant: -inset.right ),
                toggle.topAnchor.constraint( equalTo: topAnchor, constant: inset.top ),
                text.trailingAnchor.constraint( lessThanOrEqualTo: toggle.leadingAnchor, constant: -14 ),
            ]
        } else {
            constraints.append( text.trailingAnchor.constraint( lessThanOrEqualTo: trailingAnchor, constant: -inset.right ) )
        }

        NSLayoutConstraint.activate( constraints )

        addGestureRecognizer( UITapGestureRecognizer( target: self, action: #selector( pressed ) ) )
    }

    required init?( coder: NSCoder ) { fatalError( "init(coder:) has not been implemented" ) }

    override func accessibilityActivate() -> Bool {
        pressed()
        return true
    }

    @objc private func pressed() {
        guard !dims else { return }

        // The press shown for a moment, as the web's row lights under the pointer.
        let was = backgroundColor
        backgroundColor = UIColor( white: 1, alpha: 0.08 )
        UIView.animate( withDuration: 0.25, delay: 0.05, options: [ .allowUserInteraction ] ) { self.backgroundColor = was }

        onPress?()
    }
}

/// On or off, for a rule of the room: `.bm-call-moderation-switch`, 34 by 20 with a 14 point knob.
private final class CallsSwitch: UIView {
    init( on: Bool ) {
        super.init( frame: .zero )

        backgroundColor = on ? CallsTheme.accent : UIColor( white: 1, alpha: 0.2 )
        layer.cornerRadius = 10
        isUserInteractionEnabled = false

        let knob = UIView()
        knob.backgroundColor = .white
        knob.layer.cornerRadius = 7
        knob.layer.shadowColor = UIColor.black.cgColor
        knob.layer.shadowOpacity = 0.35
        knob.layer.shadowRadius = 1.5
        knob.layer.shadowOffset = CGSize( width: 0, height: 1 )
        knob.translatesAutoresizingMaskIntoConstraints = false
        addSubview( knob )

        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let start: CGFloat = on ? 17 : 3

        NSLayoutConstraint.activate( [
            widthAnchor.constraint( equalToConstant: 34 ),
            heightAnchor.constraint( equalToConstant: 20 ),
            knob.widthAnchor.constraint( equalToConstant: 14 ),
            knob.heightAnchor.constraint( equalToConstant: 14 ),
            knob.topAnchor.constraint( equalTo: topAnchor, constant: 3 ),
            rtl ? knob.trailingAnchor.constraint( equalTo: trailingAnchor, constant: -start )
                : knob.leadingAnchor.constraint( equalTo: leadingAnchor, constant: start ),
        ] )
    }

    required init?( coder: NSCoder ) { fatalError( "init(coder:) has not been implemented" ) }
}
