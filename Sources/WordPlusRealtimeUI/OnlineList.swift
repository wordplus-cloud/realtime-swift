import UIKit

// Who is online: realtime-ui's OnlineList, PersonRow, RowAction and OnlineCount (components/presence/online-list.tsx).
// Views only: whoever draws them gives the people, their rows and what may be done with them. An app feeds them from a
// presence room, as docs/ios/presence.md shows. None of them reads a room or a connection.

/// A title with how many are listed, an optional close button, and the rows, which scroll. With nobody in it, the line it
/// says instead. It takes the width and the height the app gives it.
public final class OnlineList: UIView {
    /// How many are listed, for the title and for the empty line. The rows do not set it, as a room may count more than it
    /// lists.
    public var count: Int { didSet { draw() } }
    /// The rows: a `PersonRow` each, or the app's own.
    public var rows: [ UIView ] { didSet { drawRows() } }
    /// The title before the count: `Online` by default (`online`).
    public var title: String? { didSet { draw() } }
    /// What it says with nobody in it: `No users online` by default (`online_empty`).
    public var empty: String? { didSet { draw() } }
    /// A close button in the title, where the list can be closed.
    public var onClose: ( () -> Void )? { didSet { draw() } }

    private let head = UILabel()
    private let close = RowAction( icon: CallsIcons.close, label: "" ) {}
    private let line = UIView()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let emptyLine = UILabel()

    public init( count: Int = 0, rows: [ UIView ] = [], title: String? = nil, empty: String? = nil, onClose: ( () -> Void )? = nil ) {
        self.count = count
        self.rows = rows
        self.title = title
        self.empty = empty
        self.onClose = onClose
        super.init( frame: .zero )

        translatesAutoresizingMaskIntoConstraints = false

        head.translatesAutoresizingMaskIntoConstraints = false
        head.font = .systemFont( ofSize: 11, weight: .bold )
        head.accessibilityTraits = .header
        addSubview( head )

        close.translatesAutoresizingMaskIntoConstraints = false
        close.action = { [weak self] in self?.onClose?() }
        addSubview( close )

        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview( line )

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        addSubview( scroll )

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        scroll.addSubview( stack )

        emptyLine.translatesAutoresizingMaskIntoConstraints = false
        emptyLine.font = .systemFont( ofSize: 12 )
        emptyLine.textAlignment = .center
        emptyLine.numberOfLines = 0
        addSubview( emptyLine )

        NSLayoutConstraint.activate( [
            head.leadingAnchor.constraint( equalTo: leadingAnchor, constant: 12 ),
            head.topAnchor.constraint( equalTo: topAnchor, constant: 10 ),
            head.trailingAnchor.constraint( lessThanOrEqualTo: close.leadingAnchor, constant: -8 ),
            close.trailingAnchor.constraint( equalTo: trailingAnchor, constant: -8 ),
            close.centerYAnchor.constraint( equalTo: head.centerYAnchor ),
            line.leadingAnchor.constraint( equalTo: leadingAnchor ),
            line.trailingAnchor.constraint( equalTo: trailingAnchor ),
            line.topAnchor.constraint( equalTo: head.bottomAnchor, constant: 10 ),
            line.heightAnchor.constraint( equalToConstant: 1 / UIScreen.main.scale ),
            scroll.leadingAnchor.constraint( equalTo: leadingAnchor ),
            scroll.trailingAnchor.constraint( equalTo: trailingAnchor ),
            scroll.topAnchor.constraint( equalTo: line.bottomAnchor ),
            scroll.bottomAnchor.constraint( equalTo: bottomAnchor ),
            stack.leadingAnchor.constraint( equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 4 ),
            stack.trailingAnchor.constraint( equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -4 ),
            stack.topAnchor.constraint( equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4 ),
            stack.bottomAnchor.constraint( equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4 ),
            emptyLine.leadingAnchor.constraint( equalTo: leadingAnchor, constant: 22 ),
            emptyLine.trailingAnchor.constraint( equalTo: trailingAnchor, constant: -22 ),
            emptyLine.topAnchor.constraint( equalTo: line.bottomAnchor, constant: 20 ),
        ] )

        draw()
        drawRows()
    }

    @available( *, unavailable )
    required init?( coder: NSCoder ) { fatalError( "init(coder:) is not supported" ) }

    /// The title, as it is drawn.
    var titleShown: String { head.text ?? "" }
    /// The empty line, while it shows.
    var emptyShown: String? { emptyLine.isHidden ? nil : emptyLine.text }
    /// The close button, while it shows.
    var closeShown: RowAction? { close.isHidden ? nil : close }

    private func draw() {
        let words = title ?? CallsTheme.string( "online", fallback: "Online" )
        head.text = "\( words ) (\( count ))".uppercased()
        head.textColor = PresenceColors.textTertiary
        line.backgroundColor = PresenceColors.border
        close.isHidden = onClose == nil
        close.accessibilityLabel = CallsTheme.string( "close", fallback: "Close" )
        emptyLine.text = empty ?? CallsTheme.string( "online_empty", fallback: "No users online" )
        emptyLine.textColor = PresenceColors.textTertiary
        emptyLine.isHidden = count != 0
    }

    private func drawRows() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows.forEach { stack.addArrangedSubview( $0 ) }
    }

    public override func traitCollectionDidChange( _ previous: UITraitCollection? ) {
        super.traitCollectionDidChange( previous )
        draw()
    }
}

/// A person's row: the avatar with its dot, the name, a line under it, and what may be done with them at its end.
public final class PersonRow: UIView {
    /// The name.
    public var name: String { didSet { draw() } }
    /// The line under the name (`You`, a role).
    public var sub: String? { didSet { draw() } }
    /// What may be done with the person, at the end of the row: a `RowAction` each, or the app's own.
    public var actions: [ UIView ] { didSet { drawActions() } }
    /// The avatar: an `Avatar`, or the app's own.
    public var avatar: UIView { didSet { drawAvatar( oldValue ) } }

    private let nameLabel = UILabel()
    private let subLabel = UILabel()
    private let avatarHolder = UIView()
    private let actionsRow = UIStackView()

    public init( avatar: UIView, name: String, sub: String? = nil, actions: [ UIView ] = [] ) {
        self.avatar = avatar
        self.name = name
        self.sub = sub
        self.actions = actions
        super.init( frame: .zero )

        translatesAutoresizingMaskIntoConstraints = false
        shouldGroupAccessibilityChildren = true

        avatarHolder.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont( ofSize: 14, weight: .semibold )
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority( .defaultLow, for: .horizontal )
        subLabel.font = .systemFont( ofSize: 12 )
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.setContentCompressionResistancePriority( .defaultLow, for: .horizontal )

        let body = UIStackView( arrangedSubviews: [ nameLabel, subLabel ] )
        body.axis = .vertical
        body.spacing = 1

        actionsRow.axis = .horizontal
        actionsRow.alignment = .center
        actionsRow.spacing = 4
        actionsRow.setContentHuggingPriority( .required, for: .horizontal )
        actionsRow.setContentCompressionResistancePriority( .required, for: .horizontal )

        let row = UIStackView( arrangedSubviews: [ avatarHolder, body, actionsRow ] )
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        addSubview( row )

        NSLayoutConstraint.activate( [
            row.leadingAnchor.constraint( equalTo: leadingAnchor, constant: 8 ),
            row.trailingAnchor.constraint( equalTo: trailingAnchor, constant: -8 ),
            row.topAnchor.constraint( equalTo: topAnchor, constant: 6 ),
            row.bottomAnchor.constraint( equalTo: bottomAnchor, constant: -6 ),
        ] )

        draw()
        drawAvatar( nil )
        drawActions()
    }

    @available( *, unavailable )
    required init?( coder: NSCoder ) { fatalError( "init(coder:) is not supported" ) }

    /// The words of the row, for a test.
    var subShown: String? { subLabel.isHidden ? nil : subLabel.text }

    private func draw() {
        nameLabel.text = name
        nameLabel.textColor = PresenceColors.textPrimary
        subLabel.text = sub
        subLabel.textColor = PresenceColors.textTertiary
        subLabel.isHidden = sub?.isEmpty ?? true
    }

    private func drawAvatar( _ old: UIView? ) {
        old?.removeFromSuperview()
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatarHolder.addSubview( avatar )
        NSLayoutConstraint.activate( [
            avatar.leadingAnchor.constraint( equalTo: avatarHolder.leadingAnchor ),
            avatar.trailingAnchor.constraint( equalTo: avatarHolder.trailingAnchor ),
            avatar.topAnchor.constraint( equalTo: avatarHolder.topAnchor ),
            avatar.bottomAnchor.constraint( equalTo: avatarHolder.bottomAnchor ),
        ] )
    }

    private func drawActions() {
        actionsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actions.forEach { actionsRow.addArrangedSubview( $0 ) }
        actionsRow.isHidden = actions.isEmpty
    }

    public override func traitCollectionDidChange( _ previous: UITraitCollection? ) {
        super.traitCollectionDidChange( previous )
        draw()
    }
}

/// Something to do with a person, at the end of their row (a call): an icon, and what it does for a screen reader.
public final class RowAction: UIControl {
    /// Ours by name, for `icon`: the icons of the call screen's dock.
    public static let icons = CallScreen.CallControl.icons

    /// What a press does.
    public var action: () -> Void

    private let icon: CallsIconView

    /// `icon` a path in a 24-point grid, as Lucide's are (`RowAction.icons` has ours by name). `label` is what it does.
    public init( icon: String, label: String, action: @escaping () -> Void ) {
        self.icon = CallsIconView( icon )
        self.action = action
        super.init( frame: .zero )

        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 6
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = label

        addSubview( self.icon )
        NSLayoutConstraint.activate( [
            widthAnchor.constraint( equalToConstant: 28 ),
            heightAnchor.constraint( equalToConstant: 28 ),
            self.icon.centerXAnchor.constraint( equalTo: centerXAnchor ),
            self.icon.centerYAnchor.constraint( equalTo: centerYAnchor ),
            self.icon.widthAnchor.constraint( equalToConstant: 16 ),
            self.icon.heightAnchor.constraint( equalToConstant: 16 ),
        ] )
        draw()

        addTarget( self, action: #selector( pressed ), for: .touchUpInside )
        addTarget( self, action: #selector( held ), for: [ .touchDown, .touchDragEnter ] )
        addTarget( self, action: #selector( released ), for: [ .touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit ] )
    }

    @available( *, unavailable )
    required init?( coder: NSCoder ) { fatalError( "init(coder:) is not supported" ) }

    /// A 44-point target round a 28-point button, as a finger needs.
    public override func point( inside point: CGPoint, with event: UIEvent? ) -> Bool {
        bounds.insetBy( dx: -8, dy: -8 ).contains( point )
    }

    private func draw() {
        icon.color = PresenceColors.textTertiary
    }

    @objc private func pressed() { action() }

    @objc private func held() {
        icon.color = CallsTheme.accent
        backgroundColor = PresenceColors.hover
    }

    @objc private func released() {
        draw()
        backgroundColor = .clear
    }

    public override func traitCollectionDidChange( _ previous: UITraitCollection? ) {
        super.traitCollectionDidChange( previous )
        draw()
    }
}

/// A live count: nothing at 0, `99+` past 99.
public final class OnlineCount: UIView {
    public var count: Int { didSet { draw() } }

    private let label = UILabel()

    public init( count: Int = 0 ) {
        self.count = count
        super.init( frame: .zero )

        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 8
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = [ .staticText, .updatesFrequently ]

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont( ofSize: 9.5, weight: .bold )
        label.textAlignment = .center
        addSubview( label )

        NSLayoutConstraint.activate( [
            heightAnchor.constraint( equalToConstant: 15 ),
            widthAnchor.constraint( greaterThanOrEqualToConstant: 15 ),
            label.leadingAnchor.constraint( equalTo: leadingAnchor, constant: 4 ),
            label.trailingAnchor.constraint( equalTo: trailingAnchor, constant: -4 ),
            label.centerYAnchor.constraint( equalTo: centerYAnchor ),
        ] )
        draw()
    }

    @available( *, unavailable )
    required init?( coder: NSCoder ) { fatalError( "init(coder:) is not supported" ) }

    /// What it draws, nil at nothing.
    static func said( _ count: Int ) -> String? {
        count <= 0 ? nil : count > 99 ? "99+" : String( count )
    }

    private func draw() {
        let said = Self.said( count )
        label.text = said
        label.textColor = CallsTheme.onAccent
        backgroundColor = CallsTheme.accent
        accessibilityLabel = said
        isHidden = said == nil
    }

    public override func traitCollectionDidChange( _ previous: UITraitCollection? ) {
        super.traitCollectionDidChange( previous )
        draw()
    }
}
