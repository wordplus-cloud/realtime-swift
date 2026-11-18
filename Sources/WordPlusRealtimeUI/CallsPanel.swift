import UIKit

/// One line in a panel.
struct CallsPanelRow {
    let title: String
    var selected: Bool = false
    var destructive: Bool = false
    /// A second, quieter line saying what the row does, as the web's moderation menus say it.
    var note: String? = nil
    let run: () -> Void
}

/// The call's own way of asking a question.
///
/// Configure and Participants used to be `UIAlertController` action sheets.
/// They worked, and they looked like what they were: a piece of iOS put on top
/// of the call rather than a piece of the call. They did not look built into
/// the call natively, and the arrow on the popover pointing back
/// at the dock made the seam obvious.
///
/// This is the same list drawn on the call screen itself, in the language the
/// rest of it already speaks: the glass the peer notice and the error card are
/// made of, the card radius, the dock's own width. Nothing is presented, so
/// nothing takes the screen away from the call — which also settles the second
/// half of the report, a video that stopped while the sheet was up: a view
/// LiveKit thinks nobody is looking at is a view it may stop feeding, and an
/// alert covering the stage is exactly that.
final class CallsPanel: UIView {
    private let card = UIView()
    private let rows = UIStackView()
    private var onDismiss: (() -> Void)?

    /// The second line of the header, kept so a panel showing a figure that
    /// keeps moving can be handed the new one without being rebuilt.
    private weak var detail: UILabel?

    override init(frame: CGRect) {
        super.init(frame: frame)

        // Clear rather than dimmed: the web does not dim behind its Configure
        // panel either, and the call is the thing worth looking at.
        backgroundColor = .clear

        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(white: 0, alpha: 0.82)
        card.layer.cornerRadius = 14
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 1, alpha: 0.08).cgColor
        card.clipsToBounds = true

        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.axis = .vertical
        rows.spacing = 0

        card.addSubview(rows)
        addSubview(card)

        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rows.topAnchor.constraint(equalTo: card.topAnchor),
            rows.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        // Off the card alone: its rows are its own.
        addGestureRecognizer(CallsGroundTap(target: self, action: #selector(backdropTapped)) { [weak self] in $0 === self?.card })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A tap anywhere off the card closes it, which is what an action sheet
    /// did and what anyone will try first.
    @objc private func backdropTapped() {
        onDismiss?()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // The panel only exists while it is shown, so it may claim the whole
        // screen: outside the card that claim is what closes it.
        bounds.contains(point)
    }

    /// Put it on the call, with the card just above whatever the dock's top
    /// edge is — the same twelve points the error card leaves.
    func place(in host: UIView, above dock: UIView) {
        translatesAutoresizingMaskIntoConstraints = false

        host.addSubview(self)

        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),

            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.bottomAnchor.constraint(equalTo: dock.topAnchor, constant: -12),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            // The dock's own width at every size, so the two read as one
            // object rather than a card and a row that happen to be near
            // each other.
            card.widthAnchor.constraint(greaterThanOrEqualTo: dock.widthAnchor),
            card.topAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: 16)
        ])
    }

    func fill(title: String, message: String?, entries: [CallsPanelRow], dismiss: @escaping () -> Void) {
        onDismiss = dismiss

        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }

        rows.addArrangedSubview(header(title: title, message: message))

        for entry in entries {
            rows.addArrangedSubview(separator())
            rows.addArrangedSubview(row(entry))
        }
    }

    /// A new second line for a panel already on screen.
    ///
    /// The byte counts behind the gear are sampled every two seconds and the
    /// web redraws them as they come, so a panel left open there counts up.
    /// Filling this once at open time and leaving it would have shown a figure
    /// frozen at whatever it was when the card appeared.
    func update(message: String?) {
        guard let detail = detail else { return }

        detail.text = message ?? ""
    }

    private func header(title: String, message: String?) -> UIView {
        let holder = UIView()
        let stack = UIStackView()

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 4

        let name = UILabel()
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.textColor = .white
        name.numberOfLines = 2
        name.text = title
        stack.addArrangedSubview(name)

        if let message = message, !message.isEmpty {
            let detail = UILabel()
            detail.font = .systemFont(ofSize: 13)
            detail.textColor = UIColor(white: 1, alpha: 0.65)
            detail.numberOfLines = 0
            detail.text = message
            stack.addArrangedSubview(detail)

            self.detail = detail
        }

        holder.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: holder.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -14)
        ])

        return holder
    }

    private func separator() -> UIView {
        let line = UIView()

        line.backgroundColor = UIColor(white: 1, alpha: 0.08)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true

        return line
    }

    private func row(_ entry: CallsPanelRow) -> UIView {
        let button = CallsPanelRowView(entry: entry) { [weak self] in
            self?.onDismiss?()
            entry.run()
        }

        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true

        return button
    }
}

/// One tappable line, highlighting while the finger is down the way a sheet's
/// row does.
private final class CallsPanelRowView: UIControl {
    private let run: () -> Void

    init(entry: CallsPanelRow, run: @escaping () -> Void) {
        self.run = run

        super.init(frame: .zero)

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 15)
        title.textColor = entry.destructive
            ? CallsTheme.recording
            : .white
        title.numberOfLines = 1
        title.text = entry.title
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = UIStackView(arrangedSubviews: [ title ])
        text.translatesAutoresizingMaskIntoConstraints = false
        text.axis = .vertical
        text.spacing = 2
        text.isUserInteractionEnabled = false

        if let note = entry.note, !note.isEmpty {
            let line = UILabel()
            line.font = .systemFont(ofSize: 12)
            line.textColor = UIColor(white: 1, alpha: 0.6)
            line.numberOfLines = 0
            line.text = note
            text.addArrangedSubview(line)
        }

        addSubview(text)

        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10)
        ])

        let tick = UILabel()
        tick.translatesAutoresizingMaskIntoConstraints = false
        tick.font = .systemFont(ofSize: 15, weight: .semibold)
        tick.textColor = .white
        tick.text = entry.selected ? "✓" : ""

        addSubview(tick)

        NSLayoutConstraint.activate([
            tick.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            tick.centerYAnchor.constraint(equalTo: centerYAnchor),
            tick.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 10)
        ])

        addTarget(self, action: #selector(pressed), for: .touchUpInside)
        addTarget(self, action: #selector(down), for: [.touchDown, .touchDragEnter])
        addTarget(self, action: #selector(up), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func pressed() { run() }
    @objc private func down() { backgroundColor = UIColor(white: 1, alpha: 0.1) }
    @objc private func up() { backgroundColor = .clear }
}

/// Add Person as a host gives it (realtime-ui's `people` and `addPerson`, with the rings so far): none, and the dock has
/// no such button, so a host that knows nothing of it draws nothing new. On the main thread.
struct CallsAddPerson {
    struct Person: Equatable {
        let id: String
        let name: String
        let avatar: String
    }

    /// Someone rung into the call: `ringing`, then `answered`, `rejected`, `busy`, `no_answer` or `cancelled`.
    struct Ring: Equatable {
        let id: String
        let to: String
        let state: String
        let canCancel: Bool
    }

    /// Whom the user may bring in, asked as the panel opens.
    let people: ( @escaping ( [ Person ] ) -> Void ) -> Void
    /// Rings them in: `done` with nil, or the error to show.
    let add: ( Person, @escaping ( String? ) -> Void ) -> Void
    /// The rings so far, asked each time the panel draws: a person's last one is what their row says.
    let rings: () -> [ Ring ]
    /// Calls a ring off: `done` with nil, or the error to show.
    let cancel: ( String, @escaping ( String? ) -> Void ) -> Void
}

enum CallsAddPersonStore {
    static var current: CallsAddPerson?
}

/// Add Person (realtime-ui's add-person.tsx): whom the user may bring in, as the call settings' card, on the glass of the
/// panel above. A press rings them. The card then stays and their row says how the ring stands, with Cancel while it
/// rings, where the web closes it: the row is the one place a phone says so. A failure closes it and the screen says why.
final class CallsAddPersonPanel: UIView {
    private let card = UIView()
    private let scroll = UIScrollView()
    private let rows = UIStackView()
    private let close: () -> Void
    private let failed: ( String ) -> Void

    /// Nil until the host answers.
    private var people: [ CallsAddPerson.Person ]?
    private var adding: String?
    private var cancelling: Set<String> = []

    /// What the rows were last drawn from.
    private struct Drawn: Equatable {
        let people: [ CallsAddPerson.Person ]?
        let rings: [ CallsAddPerson.Ring ]
        let adding: String?
        let cancelling: Set<String>
    }

    private var drawn: Drawn?

    init( close: @escaping () -> Void, failed: @escaping ( String ) -> Void ) {
        self.close = close
        self.failed = failed

        super.init( frame: .zero )

        backgroundColor = .clear

        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor( white: 0, alpha: 0.82 )
        card.layer.cornerRadius = 14
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor( white: 1, alpha: 0.08 ).cgColor
        card.clipsToBounds = true
        card.accessibilityViewIsModal = true

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont( ofSize: 15, weight: .semibold )
        title.textColor = .white
        title.text = CallsTheme.string( "add_person", fallback: "Add Person" )
        title.accessibilityTraits = .header
        // The rows give way where the screen's room runs out, never the title.
        title.setContentCompressionResistancePriority( .required, for: .vertical )

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false

        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.axis = .vertical

        scroll.addSubview( rows )
        card.addSubview( title )
        card.addSubview( scroll )
        addSubview( card )

        // As tall as its rows, until the screen's room runs out and they scroll.
        let fits = scroll.heightAnchor.constraint( equalTo: rows.heightAnchor )
        fits.priority = .defaultHigh

        NSLayoutConstraint.activate( [
            title.leadingAnchor.constraint( equalTo: card.leadingAnchor, constant: 16 ),
            title.trailingAnchor.constraint( equalTo: card.trailingAnchor, constant: -16 ),
            title.topAnchor.constraint( equalTo: card.topAnchor, constant: 14 ),
            scroll.leadingAnchor.constraint( equalTo: card.leadingAnchor ),
            scroll.trailingAnchor.constraint( equalTo: card.trailingAnchor ),
            scroll.topAnchor.constraint( equalTo: title.bottomAnchor, constant: 10 ),
            scroll.bottomAnchor.constraint( equalTo: card.bottomAnchor ),
            rows.leadingAnchor.constraint( equalTo: scroll.frameLayoutGuide.leadingAnchor ),
            rows.trailingAnchor.constraint( equalTo: scroll.frameLayoutGuide.trailingAnchor ),
            rows.topAnchor.constraint( equalTo: scroll.contentLayoutGuide.topAnchor ),
            rows.bottomAnchor.constraint( equalTo: scroll.contentLayoutGuide.bottomAnchor ),
            fits,
        ] )

        // Off the card alone: its rows are its own.
        addGestureRecognizer( CallsGroundTap( target: self, action: #selector( backdropTapped ) ) { [weak self] in $0 === self?.card } )
    }

    required init?( coder: NSCoder ) { fatalError( "init(coder:) has not been implemented" ) }

    @objc private func backdropTapped() {
        close()
    }

    override func point( inside point: CGPoint, with event: UIEvent? ) -> Bool {
        bounds.contains( point )
    }

    /// On the call, the card just above the dock, as the panel above.
    func place( in host: UIView, above dock: UIView ) {
        translatesAutoresizingMaskIntoConstraints = false

        host.addSubview( self )

        NSLayoutConstraint.activate( [
            leadingAnchor.constraint( equalTo: host.leadingAnchor ),
            trailingAnchor.constraint( equalTo: host.trailingAnchor ),
            topAnchor.constraint( equalTo: host.topAnchor ),
            bottomAnchor.constraint( equalTo: host.bottomAnchor ),

            card.centerXAnchor.constraint( equalTo: centerXAnchor ),
            card.bottomAnchor.constraint( equalTo: dock.topAnchor, constant: -12 ),
            card.leadingAnchor.constraint( greaterThanOrEqualTo: leadingAnchor, constant: 16 ),
            card.trailingAnchor.constraint( lessThanOrEqualTo: trailingAnchor, constant: -16 ),
            card.widthAnchor.constraint( lessThanOrEqualToConstant: 420 ),
            card.widthAnchor.constraint( greaterThanOrEqualTo: dock.widthAnchor ),
            card.topAnchor.constraint( greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: 16 ),
        ] )
    }

    /// Asks the host whom it may offer, and draws what it has meanwhile.
    func open() {
        draw()

        CallsAddPersonStore.current?.people { [weak self] found in
            guard let self else { return }

            self.people = found
            self.draw()
        }
    }

    /// Who is offered and how each ring stands, again: the rings change while it is open. Only where something did, as the
    /// call draws this with each of its changes, and rows made again would drop a finger on one.
    func draw() {
        let rings = CallsAddPersonStore.current?.rings() ?? []
        let now = Drawn( people: people, rings: rings, adding: adding, cancelling: cancelling )

        guard now != drawn else { return }

        drawn = now
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let people else {
            rows.addArrangedSubview( line( CallsTheme.string( "add_person_loading", fallback: "Loading..." ) ) )
            return
        }

        guard !people.isEmpty else {
            rows.addArrangedSubview( line( CallsTheme.string( "add_person_empty", fallback: "There is no one else to add" ) ) )
            return
        }

        for person in people {
            rows.addArrangedSubview( separator() )
            rows.addArrangedSubview( row( person, ring: rings.last { $0.to == person.id } ) )
        }
    }

    /// How a ring stands, in the app's words: `add_person_ringing`, `add_person_answered`, `add_person_rejected`,
    /// `add_person_busy`, `add_person_no_answer`, `add_person_cancelled`.
    static func said( _ state: String ) -> String {
        switch state {
        case "ringing": return CallsTheme.string( "add_person_ringing", fallback: "Ringing…" )
        case "answered": return CallsTheme.string( "add_person_answered", fallback: "Answered" )
        case "rejected": return CallsTheme.string( "add_person_rejected", fallback: "Declined" )
        case "busy": return CallsTheme.string( "add_person_busy", fallback: "Busy" )
        case "no_answer": return CallsTheme.string( "add_person_no_answer", fallback: "No answer" )
        case "cancelled": return CallsTheme.string( "add_person_cancelled", fallback: "Cancelled" )
        default: return ""
        }
    }

    private func line( _ text: String ) -> UIView {
        let holder = UIView()
        let label = UILabel()

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont( ofSize: 13 )
        label.textColor = UIColor( white: 1, alpha: 0.65 )
        label.numberOfLines = 0
        label.text = text
        holder.addSubview( label )

        NSLayoutConstraint.activate( [
            label.leadingAnchor.constraint( equalTo: holder.leadingAnchor, constant: 16 ),
            label.trailingAnchor.constraint( equalTo: holder.trailingAnchor, constant: -16 ),
            label.topAnchor.constraint( equalTo: holder.topAnchor, constant: 2 ),
            label.bottomAnchor.constraint( equalTo: holder.bottomAnchor, constant: -14 ),
        ] )

        return holder
    }

    private func separator() -> UIView {
        let line = UIView()

        line.backgroundColor = UIColor( white: 1, alpha: 0.08 )
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint( equalToConstant: 1 / UIScreen.main.scale ).isActive = true

        return line
    }

    private func row( _ person: CallsAddPerson.Person, ring: CallsAddPerson.Ring? ) -> UIView {
        let ringing = ring?.state == "ringing"

        let row = CallsAddPersonRow( person: person, note: ring.map { Self.said( $0.state ) } ?? "" )
        row.isEnabled = adding == nil && !ringing
        row.onPress = { [weak self] in self?.add( person ) }

        if adding == person.id {
            row.spin()
        } else if let ring, ringing, ring.canCancel {
            let cancel = CallsDevicePill( title: CallsTheme.string( "cancel", fallback: "Cancel" ), height: 30 )
            cancel.accessibilityLabel = ( cancel.accessibilityLabel ?? "" ) + " " + person.name
            cancel.isEnabled = !cancelling.contains( ring.id )
            // As wide as its word, which a pill holds to no size of its own: the name has the rest of the row.
            let tight = cancel.widthAnchor.constraint( equalToConstant: 0 )
            tight.priority = UILayoutPriority( 740 )
            tight.isActive = true
            row.onCancel = { [weak self] in self?.cancel( ring.id ) }
            cancel.addTarget( row, action: #selector( CallsAddPersonRow.cancelPressed ), for: .touchUpInside )
            row.end( cancel )
        }

        return row
    }

    private func add( _ person: CallsAddPerson.Person ) {
        guard adding == nil, let host = CallsAddPersonStore.current else { return }

        adding = person.id
        draw()

        host.add( person ) { [weak self] error in
            guard let self else { return }

            self.adding = nil

            if let error { return self.failed( error ) }

            self.draw()
        }
    }

    private func cancel( _ ring: String ) {
        guard let host = CallsAddPersonStore.current else { return }

        cancelling.insert( ring )
        draw()

        host.cancel( ring ) { [weak self] error in
            guard let self else { return }

            self.cancelling.remove( ring )

            if let error { return self.failed( error ) }

            self.draw()
        }
    }
}

/// A person the panel offers: their face, their name, how a ring of theirs stands, and at its end a spinner or Cancel.
private final class CallsAddPersonRow: UIControl {
    var onPress: ( () -> Void )?
    var onCancel: ( () -> Void )?

    private let holder = UIStackView()
    private let text: UIStackView

    init( person: CallsAddPerson.Person, note: String ) {
        let name = UILabel()
        text = UIStackView( arrangedSubviews: [ name ] )

        super.init( frame: .zero )

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint( greaterThanOrEqualToConstant: 48 ).isActive = true

        let face = UIView()
        face.translatesAutoresizingMaskIntoConstraints = false
        face.backgroundColor = UIColor( white: 1, alpha: 0.12 )
        face.layer.cornerRadius = 14
        face.clipsToBounds = true
        face.isUserInteractionEnabled = false

        let letters = UILabel()
        letters.translatesAutoresizingMaskIntoConstraints = false
        letters.font = .systemFont( ofSize: 11, weight: .semibold )
        letters.textColor = .white
        letters.text = CallsAvatars.initials( of: person.name )
        face.addSubview( letters )

        let picture = UIImageView()
        picture.translatesAutoresizingMaskIntoConstraints = false
        picture.contentMode = .scaleAspectFill
        face.addSubview( picture )

        name.font = .systemFont( ofSize: 15 )
        name.textColor = .white
        name.lineBreakMode = .byTruncatingTail
        name.text = person.name
        name.setContentCompressionResistancePriority( .defaultLow, for: .horizontal )

        text.axis = .vertical
        text.spacing = 2
        text.isUserInteractionEnabled = false

        if !note.isEmpty {
            let line = UILabel()
            line.font = .systemFont( ofSize: 12 )
            line.textColor = UIColor( white: 1, alpha: 0.6 )
            line.text = note
            text.addArrangedSubview( line )
        }

        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.axis = .horizontal
        holder.alignment = .center
        holder.spacing = 10
        holder.addArrangedSubview( face )
        holder.addArrangedSubview( text )
        addSubview( holder )

        NSLayoutConstraint.activate( [
            face.widthAnchor.constraint( equalToConstant: 28 ),
            face.heightAnchor.constraint( equalToConstant: 28 ),
            letters.centerXAnchor.constraint( equalTo: face.centerXAnchor ),
            letters.centerYAnchor.constraint( equalTo: face.centerYAnchor ),
            picture.leadingAnchor.constraint( equalTo: face.leadingAnchor ),
            picture.trailingAnchor.constraint( equalTo: face.trailingAnchor ),
            picture.topAnchor.constraint( equalTo: face.topAnchor ),
            picture.bottomAnchor.constraint( equalTo: face.bottomAnchor ),
            holder.leadingAnchor.constraint( equalTo: leadingAnchor, constant: 16 ),
            holder.trailingAnchor.constraint( equalTo: trailingAnchor, constant: -16 ),
            holder.topAnchor.constraint( equalTo: topAnchor, constant: 8 ),
            holder.bottomAnchor.constraint( equalTo: bottomAnchor, constant: -8 ),
        ] )

        CallsAvatars.load( person.avatar ) { [weak picture] image in picture?.image = image }

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = note.isEmpty ? person.name : person.name + ", " + note

        addTarget( self, action: #selector( pressed ), for: .touchUpInside )
        addTarget( self, action: #selector( down ), for: [ .touchDown, .touchDragEnter ] )
        addTarget( self, action: #selector( up ), for: [ .touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit ] )
    }

    required init?( coder: NSCoder ) { fatalError( "init(coder:) has not been implemented" ) }

    override var isEnabled: Bool {
        didSet { accessibilityTraits = isEnabled ? .button : [ .button, .notEnabled ] }
    }

    /// While the ring goes out.
    func spin() {
        let spinner = UIActivityIndicatorView( style: .medium )
        spinner.color = .white
        spinner.startAnimating()
        spinner.isUserInteractionEnabled = false
        holder.addArrangedSubview( spinner )
    }

    /// Cancel at the end of the row: read on its own, beside the words of the row.
    func end( _ view: UIView ) {
        holder.addArrangedSubview( view )
        isAccessibilityElement = false
        text.isAccessibilityElement = true
        text.accessibilityLabel = accessibilityLabel
        accessibilityElements = [ text, view ]
    }

    @objc func cancelPressed() { onCancel?() }
    @objc private func pressed() { onPress?() }
    @objc private func down() { backgroundColor = UIColor( white: 1, alpha: 0.1 ) }
    @objc private func up() { backgroundColor = .clear }
}
