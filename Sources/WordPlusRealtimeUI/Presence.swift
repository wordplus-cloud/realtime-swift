import UIKit

// A person's face with their status dot, and the typing and activity line: realtime-ui's presence parts
// (components/presence/avatar-face.tsx and presence.tsx) under their names. Views only: whoever draws them says who is
// online and passes the people, so an app feeds them from a presence room, from its own list, or from anything else. None
// of them reads a room or a connection. Their words are `CallScreen.Appearance.strings` and their colours its tokens.

/// A person's status, as the dot and the label say it.
public enum Presence: String, Sendable, CaseIterable {
    case online, busy, away, offline

    /// What a screen reader says of it: `Online` … in the app's words (`presence_online` …), English otherwise.
    var said: String {
        switch self {
        case .online: return CallsTheme.string( "presence_online", fallback: "Online" )
        case .busy: return CallsTheme.string( "presence_busy", fallback: "Do not disturb" )
        case .away: return CallsTheme.string( "presence_away", fallback: "Away" )
        case .offline: return CallsTheme.string( "presence_offline", fallback: "Offline" )
        }
    }
}

/// The colours of these parts, by the tokens of the web, each following the phone's light or dark where no token says.
enum PresenceColors {
    static func of( _ presence: Presence ) -> UIColor {
        switch presence {
        case .online: return CallsTheme.color( "online", fallback: UIColor( red: 61 / 255, green: 165 / 255, blue: 18 / 255, alpha: 1 ) )
        case .busy: return CallsTheme.color( "busy", fallback: UIColor( red: 220 / 255, green: 53 / 255, blue: 69 / 255, alpha: 1 ) )
        case .away: return CallsTheme.color( "away", fallback: UIColor( red: 245 / 255, green: 158 / 255, blue: 11 / 255, alpha: 1 ) )
        case .offline: return CallsTheme.color( "offline", fallback: UIColor( red: 156 / 255, green: 163 / 255, blue: 175 / 255, alpha: 1 ) )
        }
    }

    static var surface: UIColor { CallsTheme.color( "surface", fallback: .systemBackground ) }
    static var textPrimary: UIColor { CallsTheme.color( "text-primary", fallback: .label ) }
    static var textTertiary: UIColor { CallsTheme.color( "text-tertiary", fallback: .secondaryLabel ) }
    static var border: UIColor { CallsTheme.color( "border", fallback: .separator ) }
    static var hover: UIColor { CallsTheme.color( "bg-hover", fallback: .secondarySystemFill ) }
    static var activity: UIColor { CallsTheme.color( "accent-hover", fallback: CallsTheme.accent ) }
}

/// The status dot, in the colour of its status with a ring of what is behind it: `presence` nil draws it as offline.
public final class PresenceDot: UIView {
    public var presence: Presence? { didSet { draw() } }
    /// The ring round it: the surface by default. Clear for none.
    public var ringColor: UIColor? { didSet { draw() } }
    /// A status of the app's own in its colour, while the person is not offline.
    public var color: UIColor? { didSet { draw() } }

    private let size: CGFloat

    public init( presence: Presence?, size: CGFloat = 10, ringColor: UIColor? = nil, color: UIColor? = nil ) {
        self.presence = presence
        self.size = size
        self.ringColor = ringColor
        self.color = color
        super.init( frame: .zero )
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        NSLayoutConstraint.activate( [ widthAnchor.constraint( equalToConstant: size ), heightAnchor.constraint( equalToConstant: size ) ] )
        draw()
    }

    @available( *, unavailable )
    required init?( coder: NSCoder ) { fatalError( "init(coder:) is not supported" ) }

    private func draw() {
        let shown = presence ?? .offline
        backgroundColor = shown != .offline ? color ?? PresenceColors.of( shown ) : PresenceColors.of( shown )
        layer.cornerRadius = size / 2
        // Two points outside the dot, as the web's box shadow, so its size is the dot's own.
        layer.shadowColor = ( ringColor ?? PresenceColors.surface ).cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = 0
        layer.shadowOffset = .zero
        layer.shadowPath = UIBezierPath( ovalIn: CGRect( x: -2, y: -2, width: size + 4, height: size + 4 ) ).cgPath
        accessibilityLabel = shown.said
    }

    public override func traitCollectionDidChange( _ previous: UITraitCollection? ) {
        super.traitCollectionDidChange( previous )
        draw()
    }
}

/// The shape of a face: a circle by default, as the call screen draws them.
public enum AvatarShape: String, Sendable, CaseIterable {
    case circle, rounded, square

    func radius( size: CGFloat ) -> CGFloat {
        switch self {
        case .circle: return size / 2
        case .rounded: return min( 8, size / 2 )
        case .square: return min( 2, size / 2 )
        }
    }
}

/// A person's letters and the colours they are drawn in, where the app gives them: the first letters of their name on the
/// blank of the face otherwise.
public struct AvatarLetters: Sendable {
    public let text: String
    public let background: UIColor
    public let color: UIColor

    public init( text: String, background: UIColor, color: UIColor ) {
        self.text = text
        self.background = background
        self.color = color
    }
}

/// A person's face: their picture, or their letters, with their status dot at its corner. A picture that does not load
/// leaves the letters. A photo and an SVG both draw, as on the call screen.
public final class Avatar: UIView {
    public var name: String? { didSet { draw() } }
    /// The picture's address.
    public var picture: String? { didSet { load() } }
    public var presence: Presence? { didSet { drawDot() } }
    /// The dot for an offline person too, where no dot would say nothing.
    public var showOffline: Bool { didSet { drawDot() } }
    public var shape: AvatarShape { didSet { draw() } }
    /// The status of the app's own in its colour.
    public var presenceColor: UIColor? { didSet { dot?.color = presenceColor } }
    /// The ring round the dot: the surface by default.
    public var presenceRing: UIColor? { didSet { dot?.ringColor = presenceRing } }
    public var letters: AvatarLetters? { didSet { draw() } }
    /// The name is beside the face already: nothing for a screen reader to read twice.
    public var decorative: Bool { didSet { drawLabel() } }

    private let size: CGFloat
    private let dotSize: CGFloat
    private let face = UIView()
    private let lettersLabel = UILabel()
    private let image = UIImageView()
    private var dot: PresenceDot?

    public init(
        name: String? = nil, picture: String? = nil, size: CGFloat = 36, shape: AvatarShape = .circle, presence: Presence? = nil,
        showOffline: Bool = false, dotSize: CGFloat? = nil, presenceColor: UIColor? = nil, presenceRing: UIColor? = nil,
        letters: AvatarLetters? = nil, decorative: Bool = false
    ) {
        self.name = name
        self.picture = picture
        self.size = size
        self.shape = shape
        self.presence = presence
        self.showOffline = showOffline
        self.dotSize = dotSize ?? max( 6, ( size * 0.28 ).rounded() )
        self.presenceColor = presenceColor
        self.presenceRing = presenceRing
        self.letters = letters
        self.decorative = decorative
        super.init( frame: .zero )

        translatesAutoresizingMaskIntoConstraints = false
        face.translatesAutoresizingMaskIntoConstraints = false
        face.clipsToBounds = true
        addSubview( face )

        lettersLabel.translatesAutoresizingMaskIntoConstraints = false
        lettersLabel.textAlignment = .center
        lettersLabel.adjustsFontSizeToFitWidth = true
        lettersLabel.minimumScaleFactor = 0.5
        lettersLabel.font = .systemFont( ofSize: size * 0.38, weight: .semibold )
        face.addSubview( lettersLabel )

        image.translatesAutoresizingMaskIntoConstraints = false
        image.contentMode = .scaleAspectFill
        image.isHidden = true
        face.addSubview( image )

        NSLayoutConstraint.activate( [
            widthAnchor.constraint( equalToConstant: size ),
            heightAnchor.constraint( equalToConstant: size ),
            face.leadingAnchor.constraint( equalTo: leadingAnchor ),
            face.trailingAnchor.constraint( equalTo: trailingAnchor ),
            face.topAnchor.constraint( equalTo: topAnchor ),
            face.bottomAnchor.constraint( equalTo: bottomAnchor ),
            lettersLabel.centerXAnchor.constraint( equalTo: face.centerXAnchor ),
            lettersLabel.centerYAnchor.constraint( equalTo: face.centerYAnchor ),
            lettersLabel.widthAnchor.constraint( lessThanOrEqualTo: face.widthAnchor, multiplier: 0.86 ),
            image.leadingAnchor.constraint( equalTo: face.leadingAnchor ),
            image.trailingAnchor.constraint( equalTo: face.trailingAnchor ),
            image.topAnchor.constraint( equalTo: face.topAnchor ),
            image.bottomAnchor.constraint( equalTo: face.bottomAnchor ),
        ] )

        draw()
        load()
        drawDot()
    }

    @available( *, unavailable )
    required init?( coder: NSCoder ) { fatalError( "init(coder:) is not supported" ) }

    /// The words the face draws with no picture.
    var lettersShown: String { letters?.text ?? CallsAvatars.initials( of: name ?? "" ) }

    private func draw() {
        face.layer.cornerRadius = shape.radius( size: size )
        face.backgroundColor = letters?.background ?? PresenceColors.hover
        lettersLabel.textColor = letters?.color ?? PresenceColors.textTertiary
        lettersLabel.text = lettersShown
        drawLabel()
    }

    private func drawLabel() {
        isAccessibilityElement = !decorative
        // The name, and the status where a dot says one.
        accessibilityLabel = decorative ? nil : [ name, drawnDot?.said ].compactMap { $0 }.joined( separator: ", " )
        accessibilityElementsHidden = decorative
    }

    /// The status the dot says, while it shows.
    private var drawnDot: Presence? {
        guard let presence, presence != .offline || showOffline else { return nil }
        return presence
    }

    private func drawDot() {
        defer { drawLabel() }

        guard let shown = drawnDot else {
            dot?.removeFromSuperview()
            dot = nil
            return
        }

        if let dot {
            dot.presence = shown
            return
        }

        let added = PresenceDot( presence: shown, size: dotSize, ringColor: presenceRing, color: presenceColor )
        added.isAccessibilityElement = false
        addSubview( added )
        // At the corner the line ends on, a fifth of the dot out of the face.
        NSLayoutConstraint.activate( [
            added.trailingAnchor.constraint( equalTo: trailingAnchor, constant: dotSize * 0.2 ),
            added.bottomAnchor.constraint( equalTo: bottomAnchor, constant: dotSize * 0.2 ),
        ] )
        dot = added
    }

    private func load() {
        let wanted = picture ?? ""
        image.image = nil
        image.isHidden = true

        guard !wanted.isEmpty else { return }

        CallsAvatars.load( wanted ) { [weak self] picture in
            // Another picture was asked for since.
            guard let self, self.picture == wanted, let picture else { return }
            self.image.image = picture
            self.image.isHidden = false
        }
    }

    /// The dot, for a test.
    var dotShown: PresenceDot? { dot }

    public override func traitCollectionDidChange( _ previous: UITraitCollection? ) {
        super.traitCollectionDidChange( previous )
        draw()
    }
}

/// Three dots that bounce in turn, still where the phone is asked to reduce motion.
public final class TypingDots: UIView {
    private let dots: [ UIView ]

    public init( small: Bool = false ) {
        let side: CGFloat = small ? 4 : 5
        dots = ( 0..<3 ).map { _ in
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.layer.cornerRadius = side / 2
            dot.alpha = 0.7
            dot.widthAnchor.constraint( equalToConstant: side ).isActive = true
            dot.heightAnchor.constraint( equalToConstant: side ).isActive = true
            return dot
        }
        super.init( frame: .zero )

        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false

        let row = UIStackView( arrangedSubviews: dots )
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = small ? 2 : 3
        addSubview( row )

        NSLayoutConstraint.activate( [
            row.leadingAnchor.constraint( equalTo: leadingAnchor ),
            row.trailingAnchor.constraint( equalTo: trailingAnchor ),
            row.centerYAnchor.constraint( equalTo: centerYAnchor ),
            heightAnchor.constraint( greaterThanOrEqualToConstant: side + 3 ),
        ] )
        draw()
    }

    @available( *, unavailable )
    required init?( coder: NSCoder ) { fatalError( "init(coder:) is not supported" ) }

    /// The colour of the dots: the line's.
    public override var tintColor: UIColor! { didSet { draw() } }

    private func draw() {
        dots.forEach { $0.backgroundColor = tintColor }
    }

    public override func tintColorDidChange() {
        super.tintColorDidChange()
        draw()
    }

    /// Whether they are moving, for a test.
    var moving: Bool { dots.first?.layer.animation( forKey: "typing" ) != nil }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stop() : start()
    }

    private func stop() {
        dots.forEach { $0.layer.removeAnimation( forKey: "typing" ) }
    }

    private func start() {
        stop()
        guard !UIAccessibility.isReduceMotionEnabled else { return }

        // The web's: 1.2 seconds, a point and a half either side of the line, dimmer below it, each 0.15 after the last.
        for ( index, dot ) in dots.enumerated() {
            let move = CAKeyframeAnimation( keyPath: "transform.translation.y" )
            move.values = [ 1.5, -1.5, 1.5 ]
            let fade = CAKeyframeAnimation( keyPath: "opacity" )
            fade.values = [ 0.35, 1, 0.35 ]
            let both = CAAnimationGroup()
            both.animations = [ move, fade ]
            both.duration = 1.2
            both.repeatCount = .infinity
            both.timingFunction = CAMediaTimingFunction( name: .easeInEaseOut )
            both.beginTime = CACurrentMediaTime() + Double( index ) * 0.15
            both.isRemovedOnCompletion = false
            dot.layer.add( both, forKey: "typing" )
        }
    }
}

/// What someone is doing right now, as the line says it.
public enum Activity: String, Sendable, CaseIterable {
    case typing, recording, uploading
}

/// Someone in the line: their name, or none for the activity alone.
public struct ActivityEntry: Sendable, Equatable {
    public let name: String?
    public let activity: Activity

    public init( name: String? = nil, activity: Activity = .typing ) {
        self.name = name
        self.activity = activity
    }
}

/// The line that says who is typing, recording or sending a file: every activity gets its own part ("Anna, Bob typing,
/// Carol recording"), up to two names are spelled out and more become a count, and the icon is the one activity's, or the
/// typing dots once they mix. Hide it while nobody is: with nobody given it says "typing" alone, as the web's does.
public final class ActivityIndicator: UIView {
    /// Who, each with what they do. Empty, the line is `names` doing `activity`.
    public var entries: [ ActivityEntry ] { didSet { draw() } }
    public var activity: Activity { didSet { draw() } }
    public var names: [ String ] { didSet { draw() } }
    /// The smaller line.
    public var compact: Bool { didSet { draw() } }

    private let row = UIStackView()
    private let holder = UIView()
    private let label = UILabel()

    public init( entries: [ ActivityEntry ] = [], activity: Activity = .typing, names: [ String ] = [], compact: Bool = false ) {
        self.entries = entries
        self.activity = activity
        self.names = names
        self.compact = compact
        super.init( frame: .zero )

        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityTraits = [ .staticText, .updatesFrequently ]

        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        addSubview( row )

        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.setContentHuggingPriority( .required, for: .horizontal )
        row.addArrangedSubview( holder )

        label.numberOfLines = 1
        label.setContentCompressionResistancePriority( .defaultLow, for: .horizontal )
        row.addArrangedSubview( label )

        NSLayoutConstraint.activate( [
            row.leadingAnchor.constraint( equalTo: leadingAnchor ),
            row.trailingAnchor.constraint( equalTo: trailingAnchor ),
            row.topAnchor.constraint( equalTo: topAnchor ),
            row.bottomAnchor.constraint( equalTo: bottomAnchor ),
        ] )
        draw()
    }

    @available( *, unavailable )
    required init?( coder: NSCoder ) { fatalError( "init(coder:) is not supported" ) }

    /// What the line says, as realtime-ui's ActivityIndicator groups it. `%s` in the app's words (`typing_named`,
    /// `recording_named`, `uploading_named`) is who, the words alone (`typing`, `recording`, `uploading`) for one person
    /// with no name.
    static func said( _ list: [ ActivityEntry ] ) -> String {
        groups( list ).map { group -> String in
            let who = !group.named.isEmpty && group.named.count <= 2 ? group.named.joined( separator: ", " ) : String( group.count )
            let named = !group.named.isEmpty || group.count > 1
            switch group.activity {
            case .recording:
                return named
                    ? CallsTheme.string( "recording_named", fallback: "%s recording" ).replacingOccurrences( of: "%s", with: who )
                    : CallsTheme.string( "recording", fallback: "recording" )
            case .uploading:
                return named
                    ? CallsTheme.string( "uploading_named", fallback: "%s sending file" ).replacingOccurrences( of: "%s", with: who )
                    : CallsTheme.string( "uploading", fallback: "sending file" )
            case .typing:
                return named
                    ? CallsTheme.string( "typing_named", fallback: "%s typing" ).replacingOccurrences( of: "%s", with: who )
                    : CallsTheme.string( "typing", fallback: "typing" )
            }
        }.joined( separator: ", " )
    }

    /// The icon of the line: the one activity's, the typing dots once they mix.
    static func iconActivity( _ list: [ ActivityEntry ] ) -> Activity {
        let found = groups( list )
        return found.count == 1 ? found[ 0 ].activity : .typing
    }

    private static func groups( _ list: [ ActivityEntry ] ) -> [ ( activity: Activity, count: Int, named: [ String ] ) ] {
        Activity.allCases.compactMap { activity in
            let members = list.filter { $0.activity == activity }
            guard !members.isEmpty else { return nil }
            let named = members.map { ( $0.name ?? "" ).trimmingCharacters( in: .whitespacesAndNewlines ) }.filter { !$0.isEmpty }
            return ( activity, members.count, named )
        }
    }

    private var list: [ ActivityEntry ] {
        if !entries.isEmpty { return entries }
        if !names.isEmpty { return names.map { ActivityEntry( name: $0, activity: activity ) } }
        return [ ActivityEntry( activity: activity ) ]
    }

    /// The icon's view, for a test.
    var iconView: UIView? { holder.subviews.first }

    private var drawnIcon: Activity?
    private var drawnCompact: Bool?

    private func draw() {
        let list = self.list
        let said = Self.said( list )
        let colour = PresenceColors.activity
        label.text = said
        label.textColor = colour
        label.font = .systemFont( ofSize: compact ? 12 : 14, weight: .medium )
        accessibilityLabel = said

        let icon = Self.iconActivity( list )
        tintColor = colour

        guard icon != drawnIcon || compact != drawnCompact else {
            holder.subviews.first?.tintColor = colour
            return
        }
        drawnIcon = icon
        drawnCompact = compact

        holder.subviews.forEach { $0.removeFromSuperview() }

        let drawn = iconOf( icon )
        holder.addSubview( drawn )
        NSLayoutConstraint.activate( [
            drawn.leadingAnchor.constraint( equalTo: holder.leadingAnchor ),
            drawn.trailingAnchor.constraint( equalTo: holder.trailingAnchor ),
            drawn.topAnchor.constraint( greaterThanOrEqualTo: holder.topAnchor ),
            drawn.bottomAnchor.constraint( lessThanOrEqualTo: holder.bottomAnchor ),
            drawn.centerYAnchor.constraint( equalTo: holder.centerYAnchor ),
        ] )
    }

    private func iconOf( _ activity: Activity ) -> UIView {
        switch activity {
        case .typing:
            let dots = TypingDots( small: compact )
            dots.tintColor = PresenceColors.activity
            return dots
        case .recording:
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = CallsTheme.recording
            dot.layer.cornerRadius = 3.5
            let mic = glyph( CallsIcons.mic, colour: CallsTheme.recording )
            let both = UIStackView( arrangedSubviews: [ dot, mic ] )
            both.translatesAutoresizingMaskIntoConstraints = false
            both.axis = .horizontal
            both.alignment = .center
            both.spacing = 4
            NSLayoutConstraint.activate( [ dot.widthAnchor.constraint( equalToConstant: 7 ), dot.heightAnchor.constraint( equalToConstant: 7 ) ] )
            return both
        case .uploading:
            return glyph( Self.paperclip, colour: PresenceColors.activity )
        }
    }

    private func glyph( _ data: String, colour: UIColor ) -> UIView {
        let icon = CallsIconView( data )
        icon.color = colour
        NSLayoutConstraint.activate( [ icon.widthAnchor.constraint( equalToConstant: 12 ), icon.heightAnchor.constraint( equalToConstant: 12 ) ] )
        return icon
    }

    /// The web's paperclip (realtime-ui's primitives/icons/chat.ts).
    private static let paperclip = "m21.44 11.05-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"
}
