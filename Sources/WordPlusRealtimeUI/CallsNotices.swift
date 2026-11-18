import UIKit
import AVFoundation

/// The notice of a group call's join, as the web's JoinPrompt draws it (realtime-ui's device-panel.tsx,
/// `.wplus-call-join-prompt`): the call was joined with the microphone and the camera off, the dock's buttons turn them
/// on, and Preview (Test Microphone on an audio call) opens Device Settings with the tests running. Where the host keeps
/// the user's choice (`never`), Do Not Show Again beside Preview puts it away for good, × for this call alone. It opens
/// nothing by itself and covers nothing of the call but its own card.
final class CallsJoinPrompt: UIView {
    var onPreview: ( () -> Void )?
    var onDismiss: ( () -> Void )?
    var onNever: ( () -> Void )?

    private let icon = UIView()
    private let text = UIStackView()
    private let button = CallsDevicePill( title: "", fill: CallsTheme.accent, ink: CallsTheme.onAccent, height: 32 )
    private let actions = UIStackView()
    private let close = UIControl()
    private var wide: [ NSLayoutConstraint ] = []
    private var narrow: [ NSLayoutConstraint ] = []

    init( video: Bool, never: Bool = false ) {
        super.init( frame: .zero )

        backgroundColor = UIColor( red: 22 / 255, green: 24 / 255, blue: 30 / 255, alpha: 0.96 )
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor( white: 1, alpha: 0.09 ).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize( width: 0, height: 12 )

        icon.backgroundColor = CallsTheme.recording.withAlphaComponent( 0.18 )
        icon.layer.cornerRadius = 16
        icon.translatesAutoresizingMaskIntoConstraints = false
        let glyph = CallsIconView( CallsIcons.micOff )
        glyph.color = CallsTheme.recording
        icon.addSubview( glyph )

        let title = UILabel()
        title.text = video
            ? CallsTheme.string( "join_both_off", fallback: "Microphone and camera are off" )
            : CallsTheme.string( "join_microphone_off", fallback: "Microphone is off" )
        title.font = .systemFont( ofSize: 13.5, weight: .semibold )
        title.textColor = .white
        title.numberOfLines = 0

        let note = UILabel()
        note.text = video
            ? CallsTheme.string( "join_turn_both_on", fallback: "Turn them on with the buttons below when you are ready." )
            : CallsTheme.string( "join_turn_one_on", fallback: "Turn it on with the button below when you are ready." )
        note.font = .systemFont( ofSize: 12 )
        note.textColor = UIColor( white: 1, alpha: 0.62 )
        note.numberOfLines = 0

        text.addArrangedSubview( title )
        text.addArrangedSubview( note )
        text.axis = .vertical
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false

        let words = video
            ? CallsTheme.string( "device_preview", fallback: "Preview" )
            : CallsTheme.string( "test_microphone", fallback: "Test Microphone" )
        button.setTitle( words )
        button.addTarget( self, action: #selector( previewTapped ), for: .touchUpInside )
        button.setContentHuggingPriority( .required, for: .horizontal )
        button.setContentCompressionResistancePriority( .required, for: .horizontal )

        actions.axis = .horizontal
        actions.spacing = 6
        actions.alignment = .center
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.addArrangedSubview( button )

        if never {
            let pill = CallsDevicePill( title: CallsTheme.string( "join_never", fallback: "Do Not Show Again" ), fill: .clear, ink: UIColor( white: 1, alpha: 0.72 ), height: 32 )
            pill.addTarget( self, action: #selector( neverTapped ), for: .touchUpInside )
            pill.setContentHuggingPriority( .required, for: .horizontal )
            pill.setContentCompressionResistancePriority( .required, for: .horizontal )
            actions.addArrangedSubview( pill )
        }

        close.layer.cornerRadius = 14
        close.translatesAutoresizingMaskIntoConstraints = false
        let cross = CallsIconView( CallsIcons.close )
        cross.color = UIColor( white: 1, alpha: 0.6 )
        close.addSubview( cross )
        close.isAccessibilityElement = true
        close.accessibilityLabel = CallsTheme.string( "dismiss", fallback: "Dismiss" )
        close.accessibilityTraits = .button
        close.addTarget( self, action: #selector( closeTapped ), for: .touchUpInside )

        addSubview( icon )
        addSubview( text )
        addSubview( actions )
        addSubview( close )

        NSLayoutConstraint.activate( [
            icon.widthAnchor.constraint( equalToConstant: 32 ),
            icon.heightAnchor.constraint( equalToConstant: 32 ),
            icon.leadingAnchor.constraint( equalTo: leadingAnchor, constant: 12 ),
            glyph.widthAnchor.constraint( equalToConstant: 16 ),
            glyph.heightAnchor.constraint( equalToConstant: 16 ),
            glyph.centerXAnchor.constraint( equalTo: icon.centerXAnchor ),
            glyph.centerYAnchor.constraint( equalTo: icon.centerYAnchor ),
            text.leadingAnchor.constraint( equalTo: icon.trailingAnchor, constant: 12 ),
            text.topAnchor.constraint( equalTo: topAnchor, constant: 10 ),
            close.widthAnchor.constraint( equalToConstant: 28 ),
            close.heightAnchor.constraint( equalToConstant: 28 ),
            close.trailingAnchor.constraint( equalTo: trailingAnchor, constant: -8 ),
            cross.widthAnchor.constraint( equalToConstant: 16 ),
            cross.heightAnchor.constraint( equalToConstant: 16 ),
            cross.centerXAnchor.constraint( equalTo: close.centerXAnchor ),
            cross.centerYAnchor.constraint( equalTo: close.centerYAnchor ),
        ] )

        // One row: icon, text, the buttons and the ×, all centred.
        wide = [
            icon.centerYAnchor.constraint( equalTo: centerYAnchor ),
            text.bottomAnchor.constraint( equalTo: bottomAnchor, constant: -10 ),
            actions.leadingAnchor.constraint( equalTo: text.trailingAnchor, constant: 12 ),
            actions.centerYAnchor.constraint( equalTo: centerYAnchor ),
            close.leadingAnchor.constraint( equalTo: actions.trailingAnchor, constant: 12 ),
            close.centerYAnchor.constraint( equalTo: centerYAnchor ),
        ]

        // Narrow, the web's narrow layout: the buttons on a second row under the text, the × at the top.
        narrow = [
            icon.centerYAnchor.constraint( equalTo: text.centerYAnchor ),
            text.trailingAnchor.constraint( equalTo: close.leadingAnchor, constant: -12 ),
            close.topAnchor.constraint( equalTo: topAnchor, constant: 8 ),
            actions.topAnchor.constraint( equalTo: text.bottomAnchor, constant: 8 ),
            actions.leadingAnchor.constraint( equalTo: text.leadingAnchor ),
            actions.bottomAnchor.constraint( equalTo: bottomAnchor, constant: -10 ),
        ]
    }

    required init?( coder: NSCoder ) { fatalError( "init(coder:) has not been implemented" ) }

    /// Over the dock, where the hint of a muted talker stands.
    func place( in host: UIView, above dock: UIView ) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview( self )

        let compact = host.bounds.width < 520

        NSLayoutConstraint.activate( ( compact ? narrow : wide ) + [
            centerXAnchor.constraint( equalTo: host.centerXAnchor ),
            bottomAnchor.constraint( equalTo: dock.topAnchor, constant: -12 ),
            leadingAnchor.constraint( greaterThanOrEqualTo: host.leadingAnchor, constant: 12 ),
            trailingAnchor.constraint( lessThanOrEqualTo: host.trailingAnchor, constant: -12 ),
            widthAnchor.constraint( lessThanOrEqualToConstant: 560 ),
        ] )

        if compact {
            let fill = widthAnchor.constraint( equalTo: host.widthAnchor, constant: -24 )
            fill.priority = .defaultHigh
            fill.isActive = true

            // The buttons one under the other where the row under the text cannot hold both, as the web's wrap.
            let room = min( host.bounds.width - 24, 560 ) - 56 - 12
            if actions.systemLayoutSizeFitting( UIView.layoutFittingCompressedSize ).width > room {
                actions.axis = .vertical
                actions.alignment = .leading
                actions.spacing = 4
            }
        }

        UIAccessibility.post( notification: .announcement, argument: ( text.arrangedSubviews.first as? UILabel )?.text )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath( roundedRect: bounds, cornerRadius: 14 ).cgPath
    }

    @objc private func previewTapped() { onPreview?() }
    @objc private func closeTapped() { onDismiss?() }
    @objc private func neverTapped() { onNever?() }
}

/// The two switches a moderator keeps on this device, as the web keeps them (host-toasts.tsx): the sound of a raised
/// hand, on unless turned off, and the toasts of who joined, off unless turned on.
enum CallsHostPrefs {
    static let handSoundKey = "wordplus-call-hand-sound"
    static let joinAlertsKey = "wordplus-call-join-alerts"

    static var handSound: Bool {
        get { UserDefaults.standard.string( forKey: handSoundKey ) != "0" }
        set { UserDefaults.standard.set( newValue ? "1" : "0", forKey: handSoundKey ) }
    }

    static var joinAlerts: Bool {
        get { UserDefaults.standard.string( forKey: joinAlertsKey ) == "1" }
        set { UserDefaults.standard.set( newValue ? "1" : "0", forKey: joinAlertsKey ) }
    }
}

/// A question asked on the call, in a card of its own (the web's confirm dialog): a title, what it means, Cancel and
/// the answer, the danger one filled red. A tap outside the card is Cancel.
///
/// A recording's questions (realtime-ui's recording.tsx, CallDialog) add a badge before the title, a note under what it
/// means, the start's facts as rows, and their own word for No ("Leave Call"); the question to everyone else in the call
/// is answered before anything else, so a tap outside it and Escape do nothing (`dismissible` false).
final class CallsConfirm: UIView {
    private let card = UIView()
    private var answer: ( ( Bool ) -> Void )?
    private let dismissible: Bool

    init(
        title: String,
        message: String,
        confirm: String,
        danger: Bool,
        cancel cancelWord: String? = nil,
        note: String? = nil,
        facts: [ ( String, String ) ] = [],
        badge: String? = nil,
        dismissible: Bool = true,
        extra: UIView? = nil,
        answer: @escaping ( Bool ) -> Void
    ) {
        self.answer = answer
        self.dismissible = dismissible

        super.init( frame: .zero )

        backgroundColor = UIColor( white: 0, alpha: 0.5 )

        card.backgroundColor = UIColor( red: 22 / 255, green: 24 / 255, blue: 30 / 255, alpha: 1 )
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor( white: 1, alpha: 0.09 ).cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.5
        card.layer.shadowRadius = 24
        card.layer.shadowOffset = CGSize( width: 0, height: 18 )
        card.translatesAutoresizingMaskIntoConstraints = false
        card.accessibilityViewIsModal = true

        let heading = UILabel()
        heading.text = title
        heading.font = .systemFont( ofSize: 16, weight: .semibold )
        heading.textColor = .white
        heading.numberOfLines = 0
        heading.accessibilityTraits = .header

        let body = UILabel()
        body.text = message
        body.font = .systemFont( ofSize: 13.5 )
        body.textColor = UIColor( white: 1, alpha: 0.7 )
        body.numberOfLines = 0

        // The title with the recording's red badge before it, as the web's dialog head.
        let head: UIView

        if let badge {
            let disc = UIView()
            disc.backgroundColor = CallsTheme.recording.withAlphaComponent( 0.18 )
            disc.layer.cornerRadius = 14
            disc.translatesAutoresizingMaskIntoConstraints = false
            let glyph = CallsIconView( badge )
            glyph.color = CallsTheme.recording
            disc.addSubview( glyph )

            NSLayoutConstraint.activate( [
                disc.widthAnchor.constraint( equalToConstant: 28 ),
                disc.heightAnchor.constraint( equalToConstant: 28 ),
                glyph.widthAnchor.constraint( equalToConstant: 16 ),
                glyph.heightAnchor.constraint( equalToConstant: 16 ),
                glyph.centerXAnchor.constraint( equalTo: disc.centerXAnchor ),
                glyph.centerYAnchor.constraint( equalTo: disc.centerYAnchor ),
            ] )

            let row = UIStackView( arrangedSubviews: [ disc, heading ] )
            row.axis = .horizontal
            row.spacing = 10
            row.alignment = .center
            head = row
        } else {
            head = heading
        }

        // The start's facts, a label and its value on each row (the web's `wplus-call-dialog-facts`).
        var rows: [ UIView ] = []

        for ( label, value ) in facts {
            let name = UILabel()
            name.text = label
            name.font = .systemFont( ofSize: 12.5 )
            name.textColor = UIColor( white: 1, alpha: 0.55 )
            name.setContentHuggingPriority( .required, for: .horizontal )
            name.setContentCompressionResistancePriority( .required, for: .horizontal )

            let shown = UILabel()
            shown.text = value
            shown.font = .systemFont( ofSize: 12.5, weight: .medium )
            shown.textColor = UIColor( white: 1, alpha: 0.88 )
            shown.textAlignment = .right
            shown.numberOfLines = 0

            let row = UIStackView( arrangedSubviews: [ name, shown ] )
            row.axis = .horizontal
            row.spacing = 12
            row.alignment = .firstBaseline
            rows.append( row )
        }

        let footnote = UILabel()
        footnote.text = note
        footnote.font = .systemFont( ofSize: 12 )
        footnote.textColor = UIColor( white: 1, alpha: 0.55 )
        footnote.numberOfLines = 0

        let cancel = CallsDevicePill( title: cancelWord ?? CallsTheme.string( "cancel", fallback: "Cancel" ), height: 40 )
        cancel.addTarget( self, action: #selector( cancelTapped ), for: .touchUpInside )

        let yes = CallsDevicePill(
            title: confirm,
            fill: danger ? CallsTheme.recording : CallsTheme.accent,
            ink: danger ? .white : CallsTheme.onAccent,
            height: 40
        )
        yes.addTarget( self, action: #selector( yesTapped ), for: .touchUpInside )

        let buttons = UIStackView( arrangedSubviews: [ cancel, yes ] )
        buttons.axis = .horizontal
        buttons.spacing = 8
        buttons.distribution = .fillEqually

        let stack = UIStackView( arrangedSubviews: [ head, body ] )
        stack.axis = .vertical
        stack.spacing = 6

        if badge != nil { stack.setCustomSpacing( 10, after: head ) }

        if !rows.isEmpty {
            let list = UIStackView( arrangedSubviews: rows )
            list.axis = .vertical
            list.spacing = 6
            stack.setCustomSpacing( 12, after: body )
            stack.addArrangedSubview( list )
        }

        if note?.isEmpty == false {
            stack.setCustomSpacing( 10, after: stack.arrangedSubviews.last ?? body )
            stack.addArrangedSubview( footnote )
        }

        // A form of the question's own (Remove and Ban's how long, CallsBan), under what it means.
        if let extra {
            stack.setCustomSpacing( 14, after: stack.arrangedSubviews.last ?? body )
            stack.addArrangedSubview( extra )
        }

        stack.setCustomSpacing( 18, after: stack.arrangedSubviews.last ?? body )
        stack.addArrangedSubview( buttons )
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview( stack )
        addSubview( card )

        NSLayoutConstraint.activate( [
            stack.topAnchor.constraint( equalTo: card.topAnchor, constant: 20 ),
            stack.bottomAnchor.constraint( equalTo: card.bottomAnchor, constant: -16 ),
            stack.leadingAnchor.constraint( equalTo: card.leadingAnchor, constant: 20 ),
            stack.trailingAnchor.constraint( equalTo: card.trailingAnchor, constant: -20 ),
            card.centerXAnchor.constraint( equalTo: centerXAnchor ),
            card.centerYAnchor.constraint( equalTo: centerYAnchor ),
            card.widthAnchor.constraint( lessThanOrEqualToConstant: 360 ),
            card.leadingAnchor.constraint( greaterThanOrEqualTo: leadingAnchor, constant: 24 ),
            card.trailingAnchor.constraint( lessThanOrEqualTo: trailingAnchor, constant: -24 ),
        ] )

        let fill = card.widthAnchor.constraint( equalToConstant: 360 )
        fill.priority = .defaultHigh
        fill.isActive = true

        // Off the card alone: Cancel and the answer are the card's.
        addGestureRecognizer( CallsGroundTap( target: self, action: #selector( backdropTapped( _: ) ) ) { [weak self] in $0 === self?.card } )
    }

    required init?( coder: NSCoder ) { fatalError( "init(coder:) has not been implemented" ) }

    func place( in host: UIView ) {
        frame = host.bounds
        autoresizingMask = [ .flexibleWidth, .flexibleHeight ]
        host.addSubview( self )

        alpha = 0
        UIView.animate( withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.14 ) { self.alpha = 1 }
        UIAccessibility.post( notification: .screenChanged, argument: card )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.layer.shadowPath = UIBezierPath( roundedRect: card.bounds, cornerRadius: 16 ).cgPath
    }

    override func accessibilityPerformEscape() -> Bool {
        // A question that must be answered keeps the escape gesture from anything under it.
        if dismissible { finish( false ) }
        return true
    }

    @objc private func backdropTapped( _ tap: UITapGestureRecognizer ) {
        guard dismissible, !card.frame.contains( tap.location( in: self ) ) else { return }
        finish( false )
    }

    @objc private func cancelTapped() { finish( false ) }
    @objc private func yesTapped() { finish( true ) }

    /// Answered once, whichever way.
    func finish( _ yes: Bool ) {
        guard let answer else { return }

        self.answer = nil
        removeFromSuperview()
        answer( yes )
    }

    /// Put away unanswered: the question no longer fits (the recording stopped, the call went).
    func dismiss() {
        answer = nil
        removeFromSuperview()
    }
}

/// A moderator's toasts, as the web's useHostToasts tells them (realtime-ui's host-toasts.tsx): a raised hand, with a
/// chime unless Sound for Raised Hands is off, and who joined where Join Alerts is on. Who was in the room as this side
/// connected is not news, nor is this side's own reconnect, nor a tile back from reconnecting, which never left the
/// roster. A hand again within a minute, or someone back within two, is not news either. Each person is in one toast at
/// most, three stand at a time, newest first from the top, in the stage's top end corner. Members get none.
final class CallsHostToasts: UIView {
    struct Toast {
        let id: Int
        let kind: Kind
        var people: [ ( identity: String, name: String, avatar: String ) ]
        /// For `answer`: what the person asked did, and whether with both devices, asked for both at once.
        var answer: CallsTurnOnAnswer? = nil
        var both = false
    }

    enum Kind { case hand, join, answer }

    static let handSeconds: TimeInterval = 10
    static let joinSeconds: TimeInterval = 5
    static let answerSeconds: TimeInterval = 8
    static let joinsTogether: TimeInterval = 3
    static let most = 3
    static let handAgain: TimeInterval = 60
    static let rejoin: TimeInterval = 120

    private let stack = UIStackView()
    private(set) var toasts: [ Toast ] = []
    private var seen: [ String: Bool ]?
    private var leftAt: [ String: Date ] = [:]
    private var handAt: [ String: Date ] = [:]
    private var nextId = 1
    private var lastJoin: ( id: Int, at: Date )?
    private var timers: [ Int: Timer ] = [:]

    override init( frame: CGRect ) {
        super.init( frame: frame )

        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview( stack )

        NSLayoutConstraint.activate( [
            stack.topAnchor.constraint( equalTo: topAnchor ),
            stack.leadingAnchor.constraint( equalTo: leadingAnchor ),
            stack.trailingAnchor.constraint( equalTo: trailingAnchor ),
            stack.bottomAnchor.constraint( lessThanOrEqualTo: bottomAnchor ),
        ] )
    }

    required init?( coder: NSCoder ) { fatalError( "init(coder:) has not been implemented" ) }

    deinit {
        timers.values.forEach { $0.invalidate() }
    }

    /// Touches outside the toasts reach the call under them.
    override func point( inside point: CGPoint, with event: UIEvent? ) -> Bool {
        stack.arrangedSubviews.contains { $0.frame.contains( convert( point, to: stack ) ) }
    }

    /// The roster again: `connected` while the call is in progress (a reconnect starts the count again), `moderator`
    /// while this side moderates a group call.
    func update( _ people: [ CallsRoomParticipant ], connected: Bool, moderator: Bool ) {
        guard connected, moderator else {
            seen = nil

            if !moderator, !toasts.isEmpty { show( [] ) }

            return
        }

        let before = seen
        var now: [ String: Bool ] = [:]

        for person in people where !person.isLocal {
            now[ person.identity ] = person.handRaised
        }

        seen = now

        guard let before else { return }

        let at = Date()
        var left = Set<String>()
        var lowered = Set<String>()

        for ( identity, hand ) in before {
            if now[ identity ] == nil {
                left.insert( identity )
                leftAt[ identity ] = at
            } else if hand, now[ identity ] == false {
                lowered.insert( identity )
            }
        }

        var joined: [ String ] = []
        var hands: [ String ] = []

        for person in people where !person.isLocal {
            let identity = person.identity

            if before[ identity ] == nil {
                let gone = leftAt.removeValue( forKey: identity )

                if CallsHostPrefs.joinAlerts, !( gone.map { at.timeIntervalSince( $0 ) < Self.rejoin } ?? false ) {
                    joined.append( identity )
                }
            }

            if person.handRaised, before[ identity ] != true {
                if let last = handAt[ identity ], at.timeIntervalSince( last ) < Self.handAgain { continue }

                handAt[ identity ] = at
                hands.append( identity )
            }
        }

        guard !left.isEmpty || !lowered.isEmpty || !joined.isEmpty || !hands.isEmpty else { return }

        func person( _ identity: String ) -> ( identity: String, name: String, avatar: String ) {
            let found = people.first { $0.identity == identity }

            return ( identity, Self.plain( found?.name ?? "" ), found?.avatar ?? "" )
        }

        let raised = Set( hands )

        var next: [ Toast ] = toasts.compactMap { toast in
            var toast = toast
            toast.people = toast.people.filter { !left.contains( $0.identity ) && !raised.contains( $0.identity ) && !( toast.kind == .hand && lowered.contains( $0.identity ) ) }
            return toast.people.isEmpty ? nil : toast
        }

        if !joined.isEmpty {
            if let last = lastJoin, at.timeIntervalSince( last.at ) < Self.joinsTogether, let index = next.firstIndex( where: { $0.id == last.id } ) {
                next[ index ].people += joined.map( person )
                lastJoin = ( last.id, at )
                expire( last.id, in: Self.joinSeconds )
            } else {
                let toast = Toast( id: nextId, kind: .join, people: joined.map( person ) )
                nextId += 1
                next.append( toast )
                lastJoin = ( toast.id, at )
                expire( toast.id, in: Self.joinSeconds )
            }
        }

        for identity in hands {
            let toast = Toast( id: nextId, kind: .hand, people: [ person( identity ) ] )
            nextId += 1
            next.append( toast )
            expire( toast.id, in: Self.handSeconds )
        }

        show( Array( next.suffix( Self.most ) ) )

        if !hands.isEmpty, CallsHostPrefs.handSound { CallsTones.shared.play( .hand ) }
    }

    private var answersHeard: Int?

    /// The answers to this moderator's asks (CallsAsks), each once, from the second reading on: the two answers to an
    /// ask for both, alike, are one toast.
    func heard( _ answers: [ CallsTurnOnAnswer ], people: [ CallsRoomParticipant ] ) {
        guard let before = answersHeard, before <= answers.count else {
            answersHeard = answers.count
            return
        }

        answersHeard = answers.count

        let fresh = answers.dropFirst( before )

        guard !fresh.isEmpty else { return }

        var next = toasts

        for answer in fresh {
            guard let found = people.first( where: { $0.identity == answer.from } ) else { continue }

            if let pair = next.firstIndex( where: { toast in
                guard toast.kind == .answer, !toast.both, let other = toast.answer else { return false }
                return other.id == answer.id && other.from == answer.from && other.answer == answer.answer && other.device != answer.device
            } ) {
                next[ pair ].both = true
                expire( next[ pair ].id, in: Self.answerSeconds )
                continue
            }

            let toast = Toast( id: nextId, kind: .answer, people: [ ( found.identity, Self.plain( found.name ), found.avatar ) ], answer: answer )
            nextId += 1
            next.append( toast )
            expire( toast.id, in: Self.answerSeconds )
        }

        show( Array( next.suffix( Self.most ) ) )
    }

    func dismiss( _ id: Int ) {
        show( toasts.filter { $0.id != id } )
    }

    private func expire( _ id: Int, in seconds: TimeInterval ) {
        timers[ id ]?.invalidate()
        timers[ id ] = Timer.scheduledTimer( withTimeInterval: seconds, repeats: false ) { [weak self] _ in self?.dismiss( id ) }
    }

    private func show( _ next: [ Toast ] ) {
        for toast in toasts where !next.contains( where: { $0.id == toast.id } ) {
            timers.removeValue( forKey: toast.id )?.invalidate()
        }

        let added = next.filter { toast in !toasts.contains { $0.id == toast.id } }

        toasts = next
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for toast in next.reversed() {
            stack.addArrangedSubview( CallsHostToastView( toast: toast ) { [weak self] in self?.dismiss( toast.id ) } )
        }

        if let newest = added.last {
            UIAccessibility.post( notification: .announcement, argument: Self.text( newest ) )
        }
    }

    /// A name as text: a site's badges in it are markup, which a toast has no room for.
    static func plain( _ name: String ) -> String {
        name.replacingOccurrences( of: "<[^>]*>", with: "", options: .regularExpression ).trimmingCharacters( in: .whitespacesAndNewlines )
    }

    static func text( _ toast: Toast ) -> String {
        let names = toast.people.map( \.name )
        let first = names.first ?? ""

        if toast.kind == .hand {
            return CallsTheme.string( "hand_raised_toast", fallback: "%s raised a hand" ).replacingOccurrences( of: "%s", with: first )
        }

        if toast.kind == .answer, let answer = toast.answer {
            return CallsAsks.text( answer, name: first, both: toast.both )
        }

        switch names.count {
        case 1:
            return CallsTheme.string( "joined_toast", fallback: "%s joined" ).replacingOccurrences( of: "%s", with: first )
        case 2:
            return CallsTheme.string( "joined_two_toast", fallback: "%1$s and %2$s joined" )
                .replacingOccurrences( of: "%1$s", with: first )
                .replacingOccurrences( of: "%2$s", with: names[ 1 ] )
        default:
            return CallsTheme.string( "joined_others_toast", fallback: "%1$s and %2$d others joined" )
                .replacingOccurrences( of: "%1$s", with: first )
                .replacingOccurrences( of: "%2$d", with: String( names.count - 1 ) )
        }
    }
}

/// One toast: the raised hand's amber icon or the first person's picture, the words, and an ×.
private final class CallsHostToastView: UIView {
    private let onClose: () -> Void

    init( toast: CallsHostToasts.Toast, close: @escaping () -> Void ) {
        onClose = close

        super.init( frame: .zero )

        backgroundColor = UIColor( white: 0, alpha: 0.75 )
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor( white: 1, alpha: 0.08 ).cgColor

        let lead = UIView()
        lead.layer.cornerRadius = 14
        lead.clipsToBounds = true
        lead.translatesAutoresizingMaskIntoConstraints = false

        switch toast.kind {
        case .hand:
            lead.backgroundColor = CallsTheme.warning
            let glyph = CallsIconView( CallsIcons.raiseHand )
            glyph.color = UIColor( red: 17 / 255, green: 19 / 255, blue: 24 / 255, alpha: 1 )
            lead.addSubview( glyph )
            NSLayoutConstraint.activate( [
                glyph.widthAnchor.constraint( equalToConstant: 16 ),
                glyph.heightAnchor.constraint( equalToConstant: 16 ),
                glyph.centerXAnchor.constraint( equalTo: lead.centerXAnchor ),
                glyph.centerYAnchor.constraint( equalTo: lead.centerYAnchor ),
            ] )
        case .join, .answer:
            lead.backgroundColor = UIColor( white: 1, alpha: 0.16 )
            let first = toast.people.first
            let initial = UILabel()
            initial.text = first?.name.first.map { String( $0 ).uppercased() } ?? ""
            initial.font = .systemFont( ofSize: 13, weight: .semibold )
            initial.textColor = .white
            initial.textAlignment = .center
            initial.translatesAutoresizingMaskIntoConstraints = false
            let picture = UIImageView()
            picture.contentMode = .scaleAspectFill
            picture.translatesAutoresizingMaskIntoConstraints = false
            lead.addSubview( initial )
            lead.addSubview( picture )
            NSLayoutConstraint.activate( [
                initial.centerXAnchor.constraint( equalTo: lead.centerXAnchor ),
                initial.centerYAnchor.constraint( equalTo: lead.centerYAnchor ),
                picture.topAnchor.constraint( equalTo: lead.topAnchor ),
                picture.bottomAnchor.constraint( equalTo: lead.bottomAnchor ),
                picture.leadingAnchor.constraint( equalTo: lead.leadingAnchor ),
                picture.trailingAnchor.constraint( equalTo: lead.trailingAnchor ),
            ] )

            if let avatar = first?.avatar, !avatar.isEmpty {
                CallsAvatars.load( avatar ) { [weak picture, weak initial] image in
                    guard let image else { return }
                    picture?.image = image
                    initial?.isHidden = true
                }
            }
        }

        let label = UILabel()
        label.text = CallsHostToasts.text( toast )
        label.font = .systemFont( ofSize: 13, weight: .medium )
        label.textColor = .white
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        let close = UIControl()
        close.layer.cornerRadius = 14
        close.translatesAutoresizingMaskIntoConstraints = false
        close.isAccessibilityElement = true
        close.accessibilityLabel = CallsTheme.string( "dismiss", fallback: "Dismiss" )
        close.accessibilityTraits = .button
        close.addTarget( self, action: #selector( closeTapped ), for: .touchUpInside )
        let cross = CallsIconView( CallsIcons.close )
        cross.color = UIColor( white: 1, alpha: 0.7 )
        close.addSubview( cross )

        addSubview( lead )
        addSubview( label )
        addSubview( close )

        NSLayoutConstraint.activate( [
            heightAnchor.constraint( greaterThanOrEqualToConstant: 44 ),
            widthAnchor.constraint( lessThanOrEqualToConstant: 320 ),
            lead.widthAnchor.constraint( equalToConstant: 28 ),
            lead.heightAnchor.constraint( equalToConstant: 28 ),
            lead.leadingAnchor.constraint( equalTo: leadingAnchor, constant: 8 ),
            lead.centerYAnchor.constraint( equalTo: centerYAnchor ),
            label.leadingAnchor.constraint( equalTo: lead.trailingAnchor, constant: 10 ),
            label.topAnchor.constraint( greaterThanOrEqualTo: topAnchor, constant: 8 ),
            label.bottomAnchor.constraint( lessThanOrEqualTo: bottomAnchor, constant: -8 ),
            label.centerYAnchor.constraint( equalTo: centerYAnchor ),
            close.leadingAnchor.constraint( equalTo: label.trailingAnchor, constant: 10 ),
            close.trailingAnchor.constraint( equalTo: trailingAnchor, constant: -6 ),
            close.centerYAnchor.constraint( equalTo: centerYAnchor ),
            close.widthAnchor.constraint( equalToConstant: 28 ),
            close.heightAnchor.constraint( equalToConstant: 28 ),
            cross.widthAnchor.constraint( equalToConstant: 14 ),
            cross.heightAnchor.constraint( equalToConstant: 14 ),
            cross.centerXAnchor.constraint( equalTo: close.centerXAnchor ),
            cross.centerYAnchor.constraint( equalTo: close.centerYAnchor ),
        ] )
    }

    required init?( coder: NSCoder ) { fatalError( "init(coder:) has not been implemented" ) }

    @objc private func closeTapped() { onClose() }
}

/// A moderator's ask that this user turn on a device, as the engine's state names it (`asks`).
struct CallsTurnOnAsk: Equatable {
    let id: String
    let device: String
    let by: String
}

/// An answer to one of this user's own asks (`askAnswers`): `from` is whom they asked.
struct CallsTurnOnAnswer: Equatable {
    let id: String
    let from: String
    let device: String
    let answer: String
}

/// A moderator asking someone to turn on their camera or microphone, as the web asks (realtime-ui's ask-prompt.tsx), where
/// the engine carries asks (`CallsEngine.carriesAsks`): the moderator's rows in a person's menu (CallsModeration), one for
/// both while both are off, "Asked…" for `askedSeconds` after with the answer under it, and a toast of the answer
/// (CallsHostToasts); the person's card over the dock (CallsAskPrompt), whose Turn On does what the dock's buttons do once
/// the system allows the device. Nothing is turned on without their press.
enum CallsAsks {
    static let askedSeconds: TimeInterval = 30

    /// Why a device would not turn on: the system refuses it to the app, or there is none.
    enum Stuck: String {
        case blocked
        case noDevice = "no_device"
    }

    /// The asks this device sent, by person and device, for askedSeconds: `after` is how many answers it had heard as it
    /// asked, so the menu says the answer to this ask and to none before it.
    private static var asked: [ String: ( at: Date, after: Int ) ] = [:]

    /// The answers to this user's own asks, as the screen last heard them.
    static var answers: [ CallsTurnOnAnswer ] = []

    static func record( _ identity: String, _ devices: [ String ], after: Int ) {
        let at = Date()

        for device in devices { asked[ identity + "|" + device ] = ( at, after ) }
    }

    static func isAsked( _ identity: String, _ device: String ) -> Bool {
        guard let sent = asked[ identity + "|" + device ] else { return false }

        return Date().timeIntervalSince( sent.at ) < askedSeconds
    }

    /// The answer to this device's ask for `devices` while it says "Asked…", as the toast says it: one line where both
    /// answered alike, else each that came.
    static func answered( _ identity: String, _ devices: [ String ], name: String ) -> String? {
        let heard: [ CallsTurnOnAnswer ] = devices.compactMap { device in
            guard let sent = asked[ identity + "|" + device ], isAsked( identity, device ) else { return nil }

            return answers.dropFirst( sent.after ).last { $0.from == identity && $0.device == device }
        }

        if heard.count == 2, heard[ 0 ].answer == heard[ 1 ].answer {
            return text( heard[ 0 ], name: name, both: true )
        }

        return heard.isEmpty ? nil : heard.map { text( $0, name: name, both: false ) }.joined( separator: " · " )
    }

    /// What the moderator is told of an answer, `name` being whom they asked; `both` for both devices answered alike.
    static func text( _ answer: CallsTurnOnAnswer, name: String, both: Bool ) -> String {
        let camera = answer.device == "camera"
        let words: String

        switch answer.answer {
        case "on":
            words = both ? CallsTheme.string( "ask_answer_on_both", fallback: "%s turned on their camera and microphone" )
                : camera ? CallsTheme.string( "ask_answer_on_camera", fallback: "%s turned on their camera" )
                : CallsTheme.string( "ask_answer_on_microphone", fallback: "%s turned on their microphone" )
        case "not_now":
            words = both ? CallsTheme.string( "ask_answer_not_now_both", fallback: "%s is not turning on their camera and microphone now" )
                : camera ? CallsTheme.string( "ask_answer_not_now_camera", fallback: "%s is not turning on their camera now" )
                : CallsTheme.string( "ask_answer_not_now_microphone", fallback: "%s is not turning on their microphone now" )
        case "blocked":
            words = both ? CallsTheme.string( "ask_answer_blocked_both", fallback: "%s: their browser blocks the camera and microphone" )
                : camera ? CallsTheme.string( "ask_answer_blocked_camera", fallback: "%s: their browser blocks the camera" )
                : CallsTheme.string( "ask_answer_blocked_microphone", fallback: "%s: their browser blocks the microphone" )
        case "no_device":
            words = both ? CallsTheme.string( "ask_answer_no_device_both", fallback: "%s: no camera or microphone found" )
                : camera ? CallsTheme.string( "ask_answer_no_device_camera", fallback: "%s: no camera found" )
                : CallsTheme.string( "ask_answer_no_device_microphone", fallback: "%s: no microphone found" )
        default:
            words = both ? CallsTheme.string( "ask_answer_busy_both", fallback: "%s: another app is using their camera and microphone" )
                : camera ? CallsTheme.string( "ask_answer_busy_camera", fallback: "%s: another app is using their camera" )
                : CallsTheme.string( "ask_answer_busy_microphone", fallback: "%s: another app is using their microphone" )
        }

        return words.replacingOccurrences( of: "%s", with: name )
    }

    /// Why each device would not turn on, none where the system allows it: a device it never asked about is asked for
    /// here, from the person's own press of Turn On, one prompt each (the system has none for two).
    static func check( _ devices: [ String ], completion: @escaping ( [ String: Stuck ] ) -> Void ) {
        var stuck: [ String: Stuck ] = [:]
        var left = devices

        func next() {
            guard !left.isEmpty else { return completion( stuck ) }

            let device = left.removeFirst()
            let media: AVMediaType = device == "camera" ? .video : .audio

            guard AVCaptureDevice.default( for: media ) != nil else {
                stuck[ device ] = .noDevice
                return next()
            }

            switch AVCaptureDevice.authorizationStatus( for: media ) {
            case .authorized:
                next()
            case .notDetermined:
                AVCaptureDevice.requestAccess( for: media ) { granted in
                    DispatchQueue.main.async {
                        if !granted { stuck[ device ] = .blocked }
                        next()
                    }
                }
            default:
                stuck[ device ] = .blocked
                next()
            }
        }

        next()
    }

    /// What the card says of a device that would not turn on, and what to do about it.
    static func stuckTitle( _ device: String, _ stuck: Stuck ) -> String {
        let camera = device == "camera"

        switch stuck {
        case .blocked:
            return camera ? CallsTheme.string( "ask_blocked_camera", fallback: "The camera is not allowed for this app" )
                : CallsTheme.string( "ask_blocked_microphone", fallback: "The microphone is not allowed for this app" )
        case .noDevice:
            return camera ? CallsTheme.string( "ask_no_camera", fallback: "No camera found" )
                : CallsTheme.string( "ask_no_microphone", fallback: "No microphone found" )
        }
    }

    static func stuckSteps( _ device: String, _ stuck: Stuck ) -> [ String ] {
        switch stuck {
        case .blocked:
            let label = device == "camera"
                ? CallsTheme.string( "media_camera", fallback: "Camera" )
                : CallsTheme.string( "media_microphone", fallback: "Microphone" )

            return [ CallsTheme.string( "ask_allow_steps", fallback: "Open Settings, allow %s for this app, then come back and press Try Again." )
                .replacingOccurrences( of: "%s", with: label ) ]
        case .noDevice:
            return [ CallsTheme.string( "ask_connect_steps", fallback: "Connect one, or check that it is switched on, then press Try Again." ) ]
        }
    }
}

/// The ask this user was sent, over the dock in the join notice's place (the web's TurnOnAskPrompt): who asks for what,
/// Turn On, Preview (Test Microphone for the microphone alone) and Not Now; where the system refuses the device, how to
/// allow it, Try Again and Open Settings. Drawn once for what it says: the screen puts a new one in its place when that
/// changes.
final class CallsAskPrompt: UIView {
    struct Content: Equatable {
        let title: String
        let steps: [ String ]
        let camera: Bool
        let primary: String
        let secondary: String?
    }

    let content: Content
    var onPrimary: ( () -> Void )?
    var onSecondary: ( () -> Void )?
    var onNotNow: ( () -> Void )?

    private let primary: CallsDevicePill

    init( _ content: Content ) {
        self.content = content
        primary = CallsDevicePill( title: content.primary, fill: CallsTheme.accent, ink: CallsTheme.onAccent, height: 32 )

        super.init( frame: .zero )

        backgroundColor = UIColor( red: 22 / 255, green: 24 / 255, blue: 30 / 255, alpha: 0.96 )
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor( white: 1, alpha: 0.09 ).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize( width: 0, height: 12 )
        accessibilityViewIsModal = false

        let icon = UIView()
        icon.backgroundColor = CallsTheme.accent.withAlphaComponent( 0.18 )
        icon.layer.cornerRadius = 16
        icon.translatesAutoresizingMaskIntoConstraints = false
        let glyph = CallsIconView( content.camera ? CallsIcons.video : CallsIcons.mic )
        glyph.color = CallsTheme.accent
        glyph.translatesAutoresizingMaskIntoConstraints = false
        icon.addSubview( glyph )

        let text = UIStackView()
        text.axis = .vertical
        text.spacing = 3

        let title = UILabel()
        title.text = content.title
        title.font = .systemFont( ofSize: 13.5, weight: .semibold )
        title.textColor = .white
        title.numberOfLines = 0
        text.addArrangedSubview( title )

        for step in content.steps {
            let note = UILabel()
            note.text = step
            note.font = .systemFont( ofSize: 12 )
            note.textColor = UIColor( white: 1, alpha: 0.62 )
            note.numberOfLines = 0
            text.addArrangedSubview( note )
        }

        let buttons = UIStackView()
        buttons.axis = .horizontal
        buttons.spacing = 8
        buttons.alignment = .center

        primary.addTarget( self, action: #selector( primaryTapped ), for: .touchUpInside )
        buttons.addArrangedSubview( primary )

        if let words = content.secondary {
            let second = CallsDevicePill( title: words, fill: UIColor( white: 1, alpha: 0.12 ), ink: .white, height: 32 )
            second.addTarget( self, action: #selector( secondaryTapped ), for: .touchUpInside )
            buttons.addArrangedSubview( second )
        }

        let notNow = CallsDevicePill( title: CallsTheme.string( "ask_not_now", fallback: "Not Now" ), fill: .clear, ink: UIColor( white: 1, alpha: 0.72 ), height: 32 )
        notNow.addTarget( self, action: #selector( notNowTapped ), for: .touchUpInside )
        buttons.addArrangedSubview( notNow )

        let body = UIStackView( arrangedSubviews: [ text, buttons ] )
        body.axis = .vertical
        body.spacing = 10
        body.alignment = .leading
        body.translatesAutoresizingMaskIntoConstraints = false

        addSubview( icon )
        addSubview( body )

        NSLayoutConstraint.activate( [
            icon.widthAnchor.constraint( equalToConstant: 32 ),
            icon.heightAnchor.constraint( equalToConstant: 32 ),
            icon.leadingAnchor.constraint( equalTo: leadingAnchor, constant: 12 ),
            icon.topAnchor.constraint( equalTo: topAnchor, constant: 12 ),
            glyph.widthAnchor.constraint( equalToConstant: 16 ),
            glyph.heightAnchor.constraint( equalToConstant: 16 ),
            glyph.centerXAnchor.constraint( equalTo: icon.centerXAnchor ),
            glyph.centerYAnchor.constraint( equalTo: icon.centerYAnchor ),
            body.leadingAnchor.constraint( equalTo: icon.trailingAnchor, constant: 12 ),
            body.trailingAnchor.constraint( equalTo: trailingAnchor, constant: -12 ),
            body.topAnchor.constraint( equalTo: topAnchor, constant: 12 ),
            body.bottomAnchor.constraint( equalTo: bottomAnchor, constant: -12 ),
            text.widthAnchor.constraint( equalTo: body.widthAnchor ),
        ] )
    }

    required init?( coder: NSCoder ) { fatalError( "init(coder:) has not been implemented" ) }

    /// Turn On spins while the system is asked and the device opens.
    var busy = false {
        didSet {
            primary.isEnabled = !busy
            primary.alpha = busy ? 0.6 : 1
        }
    }

    /// Over the dock, where the join notice stands.
    func place( in host: UIView, above dock: UIView, announce: Bool ) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview( self )

        NSLayoutConstraint.activate( [
            centerXAnchor.constraint( equalTo: host.centerXAnchor ),
            bottomAnchor.constraint( equalTo: dock.topAnchor, constant: -12 ),
            leadingAnchor.constraint( greaterThanOrEqualTo: host.leadingAnchor, constant: 12 ),
            trailingAnchor.constraint( lessThanOrEqualTo: host.trailingAnchor, constant: -12 ),
            widthAnchor.constraint( lessThanOrEqualToConstant: 520 ),
        ] )

        let fill = widthAnchor.constraint( equalTo: host.widthAnchor, constant: -24 )
        fill.priority = .defaultHigh
        fill.isActive = true

        if announce { UIAccessibility.post( notification: .announcement, argument: content.title ) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath( roundedRect: bounds, cornerRadius: 14 ).cgPath
    }

    @objc private func primaryTapped() { onPrimary?() }
    @objc private func secondaryTapped() { onSecondary?() }
    @objc private func notNowTapped() { onNotNow?() }
}

// MARK: - A recording

/// A group call's recording, as the engine's state names it (`recording`) and as the web's call screens draw it
/// (realtime-ui's recording.tsx): REC in the bar, the notice over the dock, the question to stay or leave, and a
/// moderator's Start and Stop with their confirms. The engine keeps this user's answer by the recording's id and holds the
/// microphone, camera and screen off while the site asks for that and the answer is not `agreed` (`held`); the screens
/// draw from what it says. Nothing here sends anything.
struct CallsRecording: Equatable {
    /// `off`, `starting`, `on` or `stopping`.
    var state = "off"
    /// The recording's own id, which the answers are kept by: "" for none.
    var id = ""
    /// When it started, in seconds since 1970: 0 for not known.
    var since = 0
    /// Whether this user may start and stop it.
    var can = false
    /// How everyone else is told: `indicator` (REC alone), `moderators` (only its moderators see REC), `notice`, `ask`
    /// (the question to stay or leave) or `muted` (the same question, the microphone and camera off until they agree).
    var tell = "notice"
    /// Who started it, by name.
    var by = ""
    /// This user started it: they are told and asked nothing.
    var mine = false
    /// The user's own choice about the notice: false after Do Not Show Again, and they see REC alone.
    var notice = true
    /// This user's answer to it: `agreed`, `seen`, or "".
    var answer = ""
    /// The engine holds the microphone, camera and screen off until they agree.
    var held = false
    /// The admin's settings, which the start's confirm lists: the video's height, the layout, the audio call's layout,
    /// the transcript, its language, who may watch it afterwards and the days it is kept.
    var size = 0
    var layout = ""
    var audioLayout = ""
    var transcript: Bool?
    var language = ""
    var watch = ""
    var keepDays: Int?
    /// The words the host renders for the confirm in the site's language: "%d days" for keepDays, and the language's name.
    var keptWords = ""
    var languageWords = ""

    init() {}

    init?( _ value: Any? ) {
        guard let one = value as? [ String: Any ] else { return nil }

        state = Self.stateOf( one[ "state" ] as? String ?? "" )
        id = Self.text( one[ "id" ] )
        since = Self.number( one[ "since" ] ) ?? 0
        can = one[ "can" ] as? Bool ?? false
        tell = Self.tellOf( one[ "tell" ] as? String ?? "" )
        by = one[ "by" ] as? String ?? ""
        mine = one[ "mine" ] as? Bool ?? false
        notice = one[ "notice" ] as? Bool ?? true
        answer = one[ "answer" ] as? String ?? ""
        held = one[ "held" ] as? Bool ?? false

        if let settings = one[ "settings" ] as? [ String: Any ] {
            size = Self.number( settings[ "size" ] ) ?? 0
            layout = settings[ "layout" ] as? String ?? ""
            audioLayout = settings[ "audioLayout" ] as? String ?? ""
            transcript = settings[ "transcript" ] as? Bool
            language = settings[ "language" ] as? String ?? ""
            watch = settings[ "watch" ] as? String ?? ""
            keepDays = Self.number( settings[ "keepDays" ] )
        }

        if let words = one[ "words" ] as? [ String: Any ] {
            keptWords = words[ "kept" ] as? String ?? ""
            languageWords = words[ "language" ] as? String ?? ""
        }
    }

    /// The store's states as the call screen knows them (recording.ts's stateOf).
    static func stateOf( _ value: String ) -> String {
        switch value {
        case "starting": return "starting"
        case "recording", "on": return "on"
        case "stopping": return "stopping"
        default: return "off"
        }
    }

    static func tellOf( _ value: String ) -> String {
        [ "indicator", "moderators", "ask", "muted" ].contains( value ) ? value : "notice"
    }

    private static func number( _ value: Any? ) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int( text ) }

        return nil
    }

    private static func text( _ value: Any? ) -> String {
        if let text = value as? String { return text }
        if let number = number( value ), number != 0 { return String( number ) }

        return ""
    }

    /// It runs, or is on its way to.
    var running: Bool { state == "on" || state == "starting" }

    /// REC shows at all: not where moderators alone know of it and this user is none.
    var pillShown: Bool { !( tell == "moderators" && !can ) }

    /// Told of it beyond REC: where it runs, someone else started it, and the site tells people more than REC.
    var told: Bool { state == "on" && !mine && !id.isEmpty && tell != "moderators" && tell != "indicator" }

    /// The question to stay or leave, open until it is answered.
    var asking: Bool { told && tell != "notice" && answer != "agreed" }

    /// The notice, until Got It or Do Not Show Again.
    var noticeShown: Bool { told && tell == "notice" && answer != "seen" && notice }

    /// m:ss, h:mm:ss past an hour.
    static func elapsed( _ seconds: Int ) -> String {
        let s = max( 0, seconds )
        let hours = s / 3600
        let minutes = ( s % 3600 ) / 60
        let rest = String( format: "%02d", s % 60 )

        return hours > 0 ? "\( hours ):" + String( format: "%02d", minutes ) + ":" + rest : "\( minutes ):" + rest
    }

    private static func named( _ key: String, _ fallback: String, _ name: String ) -> String {
        CallsTheme.string( key, fallback: fallback ).replacingOccurrences( of: "%s", with: name )
    }

    /// Who may watch it, for the notice and the question: nothing where it goes to the site's own list alone.
    var watchNote: String {
        let who: String

        switch watch {
        case "moderators": who = CallsTheme.string( "rec_watch_moderators", fallback: "Moderators can watch it afterwards." )
        case "everyone": who = CallsTheme.string( "rec_watch_everyone", fallback: "Everyone in the conversation can watch it afterwards." )
        case "people": who = CallsTheme.string( "rec_watch_people", fallback: "The people who were in the call can watch it afterwards." )
        default: who = ""
        }

        let made = transcript == true ? CallsTheme.string( "rec_transcript_too", fallback: "A transcript is made too." ) : ""

        return [ who, made ].filter { !$0.isEmpty }.joined( separator: " " )
    }

    /// The notice's title: who started it, to someone there as it started; that it records, to someone who joined since.
    func noticeTitle( late: Bool ) -> String {
        !by.isEmpty && !late
            ? Self.named( "rec_started_title", "%s started recording this call", by )
            : CallsTheme.string( "rec_title", fallback: "This call is being recorded" )
    }

    func noticeNote( late: Bool ) -> String {
        [ !by.isEmpty && late ? Self.named( "rec_started", "%s started recording.", by ) : "", watchNote ]
            .filter { !$0.isEmpty }.joined( separator: " " )
    }

    /// The question's lead: what staying means, with the microphone and camera held where the site holds them.
    var questionLead: String {
        if tell == "muted" {
            return by.isEmpty
                ? CallsTheme.string( "rec_ask_muted", fallback: "Your microphone and camera stay off until you agree to be recorded." )
                : Self.named( "rec_ask_muted_by", "%s started recording. Your microphone and camera stay off until you agree to be recorded.", by )
        }

        return by.isEmpty
            ? CallsTheme.string( "rec_ask", fallback: "If you stay in the call, you agree to be recorded." )
            : Self.named( "rec_ask_by", "%s started recording. If you stay in the call, you agree to be recorded.", by )
    }

    var questionYes: String {
        tell == "muted"
            ? CallsTheme.string( "rec_agree", fallback: "I Agree" )
            : CallsTheme.string( "rec_stay", fallback: "Stay in Call" )
    }

    /// What Start Recording says in Host Controls, by how everyone else is told.
    var startNote: String {
        switch tell {
        case "moderators": return CallsTheme.string( "rec_start_note_moderators", fallback: "Asks you first. Nobody else in the call is told." )
        case "ask": return CallsTheme.string( "rec_start_note_ask", fallback: "Asks you first. Everyone in the call is then asked to stay or leave." )
        case "muted": return CallsTheme.string( "rec_start_note_muted", fallback: "Asks you first. Everyone in the call then keeps the microphone and camera off until they agree." )
        case "indicator": return CallsTheme.string( "rec_start_note_indicator", fallback: "Asks you first. Everyone in the call then sees REC beside the call controls." )
        default: return CallsTheme.string( "rec_start_note_notice", fallback: "Asks you first. Everyone in the call then sees a notice." )
        }
    }

    /// The start's confirm: how everyone else is told.
    var toldLead: String {
        switch tell {
        case "moderators": return CallsTheme.string( "rec_told_moderators", fallback: "Nobody else in the call is told: only moderators see REC, and nothing about it is posted in the conversation." )
        case "ask": return CallsTheme.string( "rec_told_ask", fallback: "Everyone in the call is asked to stay or leave, and so is anyone who joins later." )
        case "muted": return CallsTheme.string( "rec_told_muted", fallback: "Everyone else in the call keeps the microphone and camera off until they agree to be recorded, and so does anyone who joins later." )
        case "indicator": return CallsTheme.string( "rec_told_indicator", fallback: "Everyone in the call sees REC beside the call controls while it records, with no notice." )
        default: return CallsTheme.string( "rec_told_notice", fallback: "Everyone in the call sees a notice that it is recorded, and so does anyone who joins later." )
        }
    }

    /// The stop's confirm: when it can be watched, and by whom.
    var readyLead: String {
        switch watch {
        case "moderators": return CallsTheme.string( "rec_ready_moderators", fallback: "Moderators can watch it in a few minutes." )
        case "everyone": return CallsTheme.string( "rec_ready_everyone", fallback: "Everyone in the conversation can watch it in a few minutes." )
        case "admins": return CallsTheme.string( "rec_ready_admins", fallback: "Site administrators can watch it in a few minutes." )
        case "people": return CallsTheme.string( "rec_ready_people", fallback: "The people who were in the call can watch it in a few minutes." )
        default: return CallsTheme.string( "rec_ready", fallback: "It is ready to watch a few minutes after it stops." )
        }
    }

    /// The start's confirm: the admin's settings, each as a row. A row the host gave no words for is left out.
    func facts( audio: Bool ) -> [ ( String, String ) ] {
        var rows: [ ( String, String ) ] = []

        // An audio call is a video of its call screen too, in a layout of its own: the site sends none before it had one.
        if size > 0, !audio || !audioLayout.isEmpty {
            let shape: String

            if audio {
                shape = audioLayout == "gallery"
                    ? CallsTheme.string( "rec_layout_gallery", fallback: "Gallery layout" )
                    : CallsTheme.string( "rec_layout_call", fallback: "As in the call" )
            } else {
                shape = layout == "gallery" ? CallsTheme.string( "rec_layout_gallery", fallback: "Gallery layout" )
                    : layout == "speaker_only" ? CallsTheme.string( "rec_layout_speaker_only", fallback: "Speaker only" )
                    : CallsTheme.string( "rec_layout_speaker", fallback: "Speaker layout" )
            }

            rows.append( ( CallsTheme.string( "rec_fact_picture", fallback: "Picture" ), "\( size )p, " + shape ) )
        }

        if let transcript {
            let value = !transcript ? CallsTheme.string( "rec_transcript_off", fallback: "Off" )
                : language.isEmpty || language == "auto" ? CallsTheme.string( "rec_transcript_auto", fallback: "Automatic" )
                : languageWords

            if !value.isEmpty { rows.append( ( CallsTheme.string( "rec_fact_transcript", fallback: "Transcript" ), value ) ) }
        }

        if !watch.isEmpty {
            let value = watch == "moderators" ? CallsTheme.string( "rec_watch_is_moderators", fallback: "Moderators" )
                : watch == "everyone" ? CallsTheme.string( "rec_watch_is_everyone", fallback: "Everyone in the conversation" )
                : watch == "admins" ? CallsTheme.string( "rec_watch_is_admins", fallback: "Site administrators" )
                : CallsTheme.string( "rec_watch_is_people", fallback: "The people who were in the call" )

            rows.append( ( CallsTheme.string( "rec_fact_watch", fallback: "Who can watch" ), value ) )
        }

        if let keepDays {
            let value = keepDays > 0 ? keptWords : CallsTheme.string( "rec_kept_forever", fallback: "Until deleted" )

            if !value.isEmpty { rows.append( ( CallsTheme.string( "rec_fact_kept", fallback: "Kept" ), value ) ) }
        }

        return rows
    }
}

/// Whether the user joined while a recording ran rather than being in the call as it started, as the web's
/// useRecordingLayer tells it: connected before the recording was first seen running. A host may give a member no
/// recording at all until one runs, so its state before says nothing of that.
struct CallsRecordingLate {
    private var without = false
    private var late: [ String: Bool ] = [:]

    mutating func see( connected: Bool, recording: CallsRecording? ) {
        let state = recording?.state

        if !connected { without = false } else if state != "on" { without = true }

        if state == "on", let id = recording?.id, !id.isEmpty, late[ id ] == nil { late[ id ] = !without }
    }

    func isLate( _ id: String ) -> Bool {
        !id.isEmpty && late[ id ] == true
    }
}

/// REC, at the start of a group call's bar after its connection, level with the dock and clear of every tile (the web's
/// RecordingPill): a red pill with a dot that breathes, REC and the time while it records, for everyone in the call, or
/// for its moderators alone where they alone know of it. A moderator's is a button: Stop after a line, which asks first.
/// Starting, it says so to a moderator; stopped, "Saving recording…" for a few seconds. On a phone held upright REC and
/// the word Stop go, as the web's narrow bar drops them.
final class CallsRecordingPill: UIView {
    static let height: CGFloat = 28
    static let savingSeconds: TimeInterval = 4

    var onStop: ( () -> Void )?

    private let row = UIStackView()
    private let dot = UIView()
    private let mark = UILabel()
    private let time = UILabel()
    private let stop = UIStackView()
    private let line = UIView()
    private let square = UIView()
    private let stopWord = UILabel()
    private let spinner = UIActivityIndicatorView( style: .medium )
    private let words = UILabel()
    private var stoppable = false
    private var leading: NSLayoutConstraint?
    private var trailing: NSLayoutConstraint?

    override init( frame: CGRect ) {
        super.init( frame: frame )

        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Self.height / 2
        layer.cornerCurve = .continuous
        isAccessibilityElement = true
        isHidden = true

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        row.isUserInteractionEnabled = false
        addSubview( row )

        dot.backgroundColor = .white
        dot.layer.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false

        mark.text = CallsTheme.string( "rec_mark", fallback: "REC" )
        mark.font = .systemFont( ofSize: 12, weight: .semibold )
        mark.textColor = .white
        mark.attributedText = NSAttributedString( string: mark.text ?? "", attributes: [ .kern: 0.48, .font: mark.font as Any, .foregroundColor: UIColor.white ] )

        time.font = .monospacedDigitSystemFont( ofSize: 12, weight: .medium )
        time.textColor = .white

        line.backgroundColor = UIColor( white: 1, alpha: 0.45 )
        line.translatesAutoresizingMaskIntoConstraints = false
        square.backgroundColor = .white
        square.layer.cornerRadius = 1.5
        square.translatesAutoresizingMaskIntoConstraints = false
        stopWord.text = CallsTheme.string( "rec_stop", fallback: "Stop" )
        stopWord.font = .systemFont( ofSize: 12, weight: .semibold )
        stopWord.textColor = .white

        stop.axis = .horizontal
        stop.alignment = .center
        stop.spacing = 5
        stop.addArrangedSubview( line )
        stop.addArrangedSubview( square )
        stop.addArrangedSubview( stopWord )
        stop.setCustomSpacing( 7, after: line )

        spinner.color = UIColor( white: 1, alpha: 0.88 )
        spinner.hidesWhenStopped = false
        spinner.transform = CGAffineTransform( scaleX: 0.6, y: 0.6 )

        words.font = .systemFont( ofSize: 12, weight: .medium )
        words.textColor = .white

        for view in [ spinner, dot, mark, time, stop, words ] as [ UIView ] { row.addArrangedSubview( view ) }

        leading = row.leadingAnchor.constraint( equalTo: leadingAnchor, constant: 10 )
        trailing = row.trailingAnchor.constraint( equalTo: trailingAnchor, constant: -10 )

        NSLayoutConstraint.activate( [
            heightAnchor.constraint( equalToConstant: Self.height ),
            leading!,
            trailing!,
            row.centerYAnchor.constraint( equalTo: centerYAnchor ),
            dot.widthAnchor.constraint( equalToConstant: 7 ),
            dot.heightAnchor.constraint( equalToConstant: 7 ),
            line.widthAnchor.constraint( equalToConstant: 1 ),
            line.heightAnchor.constraint( equalToConstant: 16 ),
            square.widthAnchor.constraint( equalToConstant: 7 ),
            square.heightAnchor.constraint( equalToConstant: 7 ),
            spinner.widthAnchor.constraint( equalToConstant: 14 ),
            spinner.heightAnchor.constraint( equalToConstant: 14 ),
        ] )

        addGestureRecognizer( UITapGestureRecognizer( target: self, action: #selector( tapped ) ) )
    }

    required init?( coder: NSCoder ) { nil }

    /// A 44-point target round a pill drawn as high as the connection's chip.
    override func point( inside point: CGPoint, with event: UIEvent? ) -> Bool {
        stoppable && bounds.insetBy( dx: -2, dy: -8 ).contains( point )
    }

    @objc private func tapped() {
        if stoppable { onStop?() }
    }

    override func accessibilityActivate() -> Bool {
        guard stoppable else { return false }

        onStop?()
        return true
    }

    /// What it says now: `saving` while "Saving recording…" stands after a stop, `narrow` on a stage under 600 wide.
    /// Hidden where it says nothing.
    func show( _ recording: CallsRecording?, saving: Bool, narrow: Bool, now: Date = Date() ) {
        guard let recording, recording.pillShown else { return hide() }

        if recording.state == "on" {
            let since = recording.since > 0 ? Date( timeIntervalSince1970: TimeInterval( recording.since ) ) : now
            let said = CallsRecording.elapsed( Int( now.timeIntervalSince( since ) ) )

            backgroundColor = CallsTheme.recording
            layer.borderWidth = 0
            time.text = said
            spinner.isHidden = true
            spinner.stopAnimating()
            words.isHidden = true
            dot.isHidden = false
            time.isHidden = false
            mark.isHidden = narrow
            stop.isHidden = !recording.can
            stopWord.isHidden = narrow
            row.spacing = narrow ? 5 : 6
            leading?.constant = narrow ? 9 : 10
            trailing?.constant = narrow ? -9 : -10
            stoppable = recording.can

            accessibilityLabel = recording.can
                ? CallsTheme.string( "rec_stop_label", fallback: "Recording, %s. Stop recording" ).replacingOccurrences( of: "%s", with: said )
                : CallsTheme.string( "rec_recorded", fallback: "This call is being recorded." )
            accessibilityTraits = recording.can ? .button : .staticText

            breathe()
        } else if ( recording.state == "starting" && recording.can ) || ( recording.state == "stopping" && saving ) {
            backgroundColor = UIColor( white: 0, alpha: 0.42 )
            layer.borderWidth = 1
            layer.borderColor = CallsTheme.dockHairline.cgColor
            dot.isHidden = true
            mark.isHidden = true
            time.isHidden = true
            stop.isHidden = true
            words.isHidden = false
            spinner.isHidden = false
            spinner.startAnimating()
            words.text = recording.state == "starting"
                ? CallsTheme.string( "rec_starting", fallback: "Starting recording…" )
                : CallsTheme.string( "rec_saving", fallback: "Saving recording…" )
            row.spacing = 6
            leading?.constant = 10
            trailing?.constant = -10
            stoppable = false
            accessibilityLabel = words.text
            accessibilityTraits = .staticText
        } else {
            return hide()
        }

        isHidden = false
    }

    private func hide() {
        isHidden = true
        stoppable = false
        spinner.stopAnimating()
    }

    /// The dot's breath, 1.6 s a cycle, none where motion is reduced.
    private func breathe() {
        guard !UIAccessibility.isReduceMotionEnabled else {
            dot.layer.removeAnimation( forKey: "breathe" )
            return
        }

        guard dot.layer.animation( forKey: "breathe" ) == nil else { return }

        let breath = CABasicAnimation( keyPath: "opacity" )
        breath.fromValue = 1
        breath.toValue = 0.35
        breath.duration = 0.8
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction( name: .easeInEaseOut )
        dot.layer.add( breath, forKey: "breathe" )
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A layer's animations go with its window: back on screen, the dot breathes again.
        dot.layer.removeAnimation( forKey: "breathe" )
        if !isHidden, !dot.isHidden { breathe() }
    }
}

/// The notice to everyone else in the call, in the join notice's place over the dock (the web's RecordingNotice): who
/// started recording, or that it records to someone who joined since, and who can watch it. Got It puts it away for this
/// recording, Do Not Show Again for good, REC alone telling them from then on.
final class CallsRecordingNotice: UIView {
    struct Content: Equatable {
        let title: String
        let note: String
    }

    let content: Content
    var onSeen: ( () -> Void )?
    var onNever: ( () -> Void )?

    init( _ content: Content ) {
        self.content = content

        super.init( frame: .zero )

        backgroundColor = UIColor( red: 22 / 255, green: 24 / 255, blue: 30 / 255, alpha: 0.96 )
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor( white: 1, alpha: 0.09 ).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize( width: 0, height: 12 )

        let icon = UIView()
        icon.backgroundColor = CallsTheme.recording.withAlphaComponent( 0.18 )
        icon.layer.cornerRadius = 16
        icon.translatesAutoresizingMaskIntoConstraints = false
        let glyph = CallsIconView( CallsIcons.record )
        glyph.color = CallsTheme.recording
        icon.addSubview( glyph )

        let text = UIStackView()
        text.axis = .vertical
        text.spacing = 3

        let title = UILabel()
        title.text = content.title
        title.font = .systemFont( ofSize: 13.5, weight: .semibold )
        title.textColor = .white
        title.numberOfLines = 0
        title.accessibilityTraits = .header
        text.addArrangedSubview( title )

        if !content.note.isEmpty {
            let note = UILabel()
            note.text = content.note
            note.font = .systemFont( ofSize: 12 )
            note.textColor = UIColor( white: 1, alpha: 0.62 )
            note.numberOfLines = 0
            text.addArrangedSubview( note )
        }

        let gotIt = CallsDevicePill( title: CallsTheme.string( "rec_got_it", fallback: "Got It" ), fill: CallsTheme.accent, ink: CallsTheme.onAccent, height: 32 )
        gotIt.addTarget( self, action: #selector( seenTapped ), for: .touchUpInside )

        let never = CallsDevicePill( title: CallsTheme.string( "rec_never", fallback: "Do Not Show Again" ), fill: .clear, ink: UIColor( white: 1, alpha: 0.72 ), height: 32 )
        never.addTarget( self, action: #selector( neverTapped ), for: .touchUpInside )

        let buttons = UIStackView( arrangedSubviews: [ gotIt, never ] )
        buttons.axis = .horizontal
        buttons.spacing = 8
        buttons.alignment = .center

        let body = UIStackView( arrangedSubviews: [ text, buttons ] )
        body.axis = .vertical
        body.spacing = 10
        body.alignment = .leading
        body.translatesAutoresizingMaskIntoConstraints = false

        addSubview( icon )
        addSubview( body )

        NSLayoutConstraint.activate( [
            icon.widthAnchor.constraint( equalToConstant: 32 ),
            icon.heightAnchor.constraint( equalToConstant: 32 ),
            icon.leadingAnchor.constraint( equalTo: leadingAnchor, constant: 12 ),
            icon.topAnchor.constraint( equalTo: topAnchor, constant: 12 ),
            glyph.widthAnchor.constraint( equalToConstant: 16 ),
            glyph.heightAnchor.constraint( equalToConstant: 16 ),
            glyph.centerXAnchor.constraint( equalTo: icon.centerXAnchor ),
            glyph.centerYAnchor.constraint( equalTo: icon.centerYAnchor ),
            body.leadingAnchor.constraint( equalTo: icon.trailingAnchor, constant: 12 ),
            body.trailingAnchor.constraint( equalTo: trailingAnchor, constant: -12 ),
            body.topAnchor.constraint( equalTo: topAnchor, constant: 12 ),
            body.bottomAnchor.constraint( equalTo: bottomAnchor, constant: -12 ),
            text.widthAnchor.constraint( equalTo: body.widthAnchor ),
        ] )
    }

    required init?( coder: NSCoder ) { fatalError( "init(coder:) has not been implemented" ) }

    /// Over the dock, where the join notice stands.
    func place( in host: UIView, above dock: UIView, announce: Bool ) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview( self )

        NSLayoutConstraint.activate( [
            centerXAnchor.constraint( equalTo: host.centerXAnchor ),
            bottomAnchor.constraint( equalTo: dock.topAnchor, constant: -12 ),
            leadingAnchor.constraint( greaterThanOrEqualTo: host.leadingAnchor, constant: 12 ),
            trailingAnchor.constraint( lessThanOrEqualTo: host.trailingAnchor, constant: -12 ),
            widthAnchor.constraint( lessThanOrEqualToConstant: 520 ),
        ] )

        let fill = widthAnchor.constraint( equalTo: host.widthAnchor, constant: -24 )
        fill.priority = .defaultHigh
        fill.isActive = true

        if announce { UIAccessibility.post( notification: .announcement, argument: content.title ) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath( roundedRect: bounds, cornerRadius: 14 ).cgPath
    }

    @objc private func seenTapped() { onSeen?() }
    @objc private func neverTapped() { onNever?() }
}
