import UIKit

/// The colours and the words the call screens use.
///
/// Both come from the site: the palette the person chose in the Design tab and
/// the strings in their language, handed over in `configure` and kept with the
/// rest of the config. A phone that has never been configured still has to
/// draw something, so every lookup has a fallback that reads as a call screen.
enum CallsTheme {
    /// The site's palette is keyed the way the stylesheet writes it — the
    /// custom property's own name — so a lookup for `accent` finds nothing and
    /// every colour on the call screen silently falls back to a built-in one.
    /// Both spellings are tried, the prefixed one first.
    static func color(_ token: String, fallback: UIColor) -> UIColor {
        guard let config = CallsConfigStore.current else { return fallback }

        let tokens = config.darkMode ? config.designTokensDark : config.designTokens

        // `--wplus-call-canvas` and the call screen's other own tokens are found as `call-canvas` too, as the web names
        // them. The names before @wordplus/realtime-ui 1.0.6, `--bm-…`, still count, under the new ones.
        for name in [ "--wplus-color-" + token, "--wplus-" + token, "--bm-color-" + token, "--bm-" + token, token ] {
            guard let value = tokens[name] ?? config.designTokens[name],
                  let parsed = CallsTheme.parse(value) else {
                continue
            }

            return parsed
        }

        return fallback
    }

    static func string(_ key: String, fallback: String) -> String {
        CallsConfigStore.current?.strings[key] ?? fallback
    }

    /// Whether the microphone and camera controls wear the state they are in
    /// or the action they perform — the site's "Invert Mute/Hide Icons"
    /// setting, which the app used to ignore. The default is the state, which
    /// is what the web draws with the setting off and what these screens have
    /// always drawn.
    static var showsState: Bool { CallsConfigStore.current?.iconsReverted ?? true }

    /// The one place the microphone's glyph is decided, so the dock and the
    /// tap that changes it cannot end up saying different things. Android
    /// decides it in one place too, in `CallsRoundButton.symbol`.
    static func micIcon(muted: Bool) -> String {
        (showsState ? muted : !muted) ? CallsIcons.micOff : CallsIcons.mic
    }

    static func cameraIcon(on: Bool) -> String {
        (showsState ? on : !on) ? CallsIcons.video : CallsIcons.videoOff
    }

    /// The stage is near-black whatever the site's palette says: it is what a
    /// remote camera is seen against, and a light one washes the picture out.
    /// An app that wants it otherwise says so in the web's own token,
    /// `--bm-call-canvas`, which no site's palette carries.
    static var stage: UIColor { color("call-canvas", fallback: UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)) }

    /// The tile a grid draws people on: the stylesheet's `--bm-call-tile`, a
    /// wash of white over the stage. Composited to an opaque colour here
    /// rather than laid on as a translucent fill, because the presence dot's
    /// ring has to be *the colour behind it* — and a see-through ring is not
    /// a ring.
    static var tile: UIColor {
        let own = color("call-tile", fallback: .clear)
        if own != .clear { return own }

        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0

        stage.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let wash: CGFloat = 0.08

        return UIColor(
            red: red * (1 - wash) + wash,
            green: green * (1 - wash) + wash,
            blue: blue * (1 - wash) + wash,
            alpha: 1
        )
    }

    static var accent: UIColor { color("accent", fallback: UIColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 1)) }
    static var onAccent: UIColor { color("text-on-accent", fallback: .white) }

    /// The red a call hangs up in and a switched-off microphone is drawn in.
    static var recording: UIColor { color("recording", fallback: UIColor(red: 0.910, green: 0.255, blue: 0.255, alpha: 1)) }
    static var success: UIColor { color("success", fallback: UIColor(red: 0.133, green: 0.773, blue: 0.369, alpha: 1)) }

    /// The presence dot, from the same token the stylesheet draws it with, so
    /// a site that recoloured it is followed here too.
    static var online: UIColor { color("online", fallback: UIColor(red: 0.263, green: 0.894, blue: 0.263, alpha: 1)) }
    static var warning: UIColor { color("warning", fallback: UIColor(red: 0.961, green: 0.620, blue: 0.043, alpha: 1)) }

    static var danger: UIColor { recording }
    static var onStage: UIColor { .white }

    /// The dock's own colours, as the call stylesheet has them: a control is a
    /// twelve-percent white disc (`--bm-call-btn`), and the glass behind the
    /// row is flat black with a hairline rather than a blur — blurring live
    /// video costs a compositor pass a frame, and WebKit draws the blurred
    /// region square behind rounded corners. An app recolours the glass with
    /// `--bm-call-dock`.
    static var control: UIColor { color("call-btn", fallback: UIColor(white: 1, alpha: 0.12)) }
    static var controlActive: UIColor { UIColor(white: 1, alpha: 0.92) }
    static var dockGlass: UIColor { color("call-dock", fallback: UIColor(white: 0, alpha: 0.5)) }
    static var dockHairline: UIColor { UIColor(white: 1, alpha: 0.08) }

    /// `#rgb`, `#rrggbb`, `#rrggbbaa` and `rgb()/rgba()`, which is everything
    /// the Design tab can produce.
    static func parse(_ value: String) -> UIColor? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if text.hasPrefix("#") {
            var hex = String(text.dropFirst())

            if hex.count == 3 {
                hex = hex.map { String(repeating: $0, count: 2) }.joined()
            }

            guard hex.count == 6 || hex.count == 8, let number = UInt64(hex, radix: 16) else { return nil }

            let shift = hex.count == 8 ? 8 : 0
            let alpha = hex.count == 8 ? CGFloat(number & 0xff) / 255 : 1

            return UIColor(
                red: CGFloat((number >> (16 + shift)) & 0xff) / 255,
                green: CGFloat((number >> (8 + shift)) & 0xff) / 255,
                blue: CGFloat((number >> shift) & 0xff) / 255,
                alpha: alpha
            )
        }

        // WordPress hands these over as the stylesheet stores them, which is
        // three bare numbers — `37, 99, 235` — so that a rule can write
        // `rgba(var(--bm-color-accent), 0.5)`. Nothing arrives as `rgb(...)`
        // in practice, but both are read here.
        let inner: Substring

        if text.hasPrefix("rgb"), let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")") {
            inner = text[text.index(after: open)..<close]
        } else {
            inner = text[text.startIndex...]
        }

        let parts = inner
            .components(separatedBy: CharacterSet(charactersIn: ",/"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard parts.count >= 3,
              let red = Double(parts[0]), let green = Double(parts[1]), let blue = Double(parts[2]) else {
            return nil
        }

        let alpha = parts.count > 3 ? (Double(parts[3]) ?? 1) : 1

        return UIColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }
}

/// A control on the call dock.
///
/// The shape, the size and the tones are the call stylesheet's, so that the
/// same call looks the same in the app and in a phone browser: a round disc of
/// twelve-percent white with a stroked glyph, going solid white with the
/// recording red through it when the medium behind it is switched off, accent
/// when an extra is latched on, and a wider pill in red or green to hang up
/// and to answer.
///
/// Not a `UIButton`: the plugin's own rule is that host styling outranks ours
/// everywhere it can reach, and a plain view with a tap recogniser cannot be
/// restyled out from under the call.
enum CallsButtonTone {
    /// Available, and doing nothing in particular.
    case control
    /// A medium that can be switched off — the microphone, the camera. `isOn`
    /// means *off*, which is the stylesheet's own naming: `bm-enable-mic` is
    /// the state where the microphone is not running.
    case medium
    /// An extra that latches: sharing, picture in picture.
    case latch
    /// A restriction someone else holds.
    case warning
    case danger
    case answer
}

final class CallsButton: UIView {
    private let glyph: CallsIconView
    /// Variables so the dock can keep a host's button and take what its pieces gave anew (CallsScreen.keepDocked).
    var action: () -> Void
    private(set) var icon: String
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var glyphSize: [NSLayoutConstraint] = []

    /// A variable for Host Controls, which is latched while its menu is open and amber while a room rule holds, as the
    /// web's `.bm-host-controls` is.
    var tone: CallsButtonTone {
        didSet { restyle() }
    }

    var isOn = false {
        didSet { restyle() }
    }

    init(icon: String, tone: CallsButtonTone = .control, action: @escaping () -> Void) {
        self.glyph = CallsIconView(icon)
        self.icon = icon
        self.tone = tone
        self.action = action

        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        isUserInteractionEnabled = true
        layer.cornerRadius = 17
        layer.cornerCurve = .continuous

        addSubview(glyph)

        let width = widthAnchor.constraint(equalToConstant: CallsButton.stride(for: tone, diameter: 34))
        let height = heightAnchor.constraint(equalToConstant: 34)

        widthConstraint = width
        heightConstraint = height

        glyphSize = [
            glyph.widthAnchor.constraint(equalToConstant: 17),
            glyph.heightAnchor.constraint(equalToConstant: 17)
        ]

        NSLayoutConstraint.activate([
            width,
            height,
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor)
        ] + glyphSize)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        // A label alone does not make a view something VoiceOver can reach:
        // without these every control on the call screen was silent to it,
        // and to the UI tests that find the controls by their labels.
        isAccessibilityElement = true
        accessibilityTraits = .button

        restyle()
    }

    override func accessibilityActivate() -> Bool {
        tapped()

        return true
    }

    required init?(coder: NSCoder) { nil }

    /// The stylesheet steps its controls down on a narrow stage, and a phone
    /// is always the narrowest of them: `--wplus-call-btn` is 34, 32 on a
    /// stage of 719 or less and 30 on one of 559 or less.
    static func diameter(for width: CGFloat) -> CGFloat {
        if width <= 559 { return 30 }
        if width <= 719 { return 32 }

        return 34
    }

    /// Hanging up and answering are pills rather than discs, so they cannot be
    /// mistaken for one of the toggles beside them.
    static func stride(for tone: CallsButtonTone, diameter: CGFloat) -> CGFloat {
        switch tone {
        case .danger, .answer:
            return diameter + 16
        default:
            return diameter
        }
    }

    func setDiameter(_ diameter: CGFloat) {
        // The radius is set here rather than only on a change, because the
        // first call arrives with the size it was built at and would
        // otherwise leave every control square.
        layer.cornerRadius = diameter / 2

        guard heightConstraint?.constant != diameter else { return }

        widthConstraint?.constant = CallsButton.stride(for: tone, diameter: diameter)
        heightConstraint?.constant = diameter

        for constraint in glyphSize { constraint.constant = round(diameter * 0.5) }

        layer.cornerRadius = diameter / 2
    }


    func setIcon(_ icon: String) {
        self.icon = icon
        glyph.set(icon)
    }

    /// The hang-up glyph is the handset turned, exactly as the stylesheet
    /// turns it — there is no second path for it in the registry.
    func rotateGlyph(degrees: CGFloat) {
        glyph.transform = CGAffineTransform(rotationAngle: degrees * .pi / 180)
    }

    private func restyle() {
        switch tone {
        case .control:
            backgroundColor = CallsTheme.control
            glyph.color = .white

        case .medium:
            backgroundColor = isOn ? CallsTheme.controlActive : CallsTheme.control
            glyph.color = isOn ? CallsTheme.recording : .white

        case .latch:
            backgroundColor = isOn ? CallsTheme.accent : CallsTheme.control
            glyph.color = isOn ? CallsTheme.onAccent : .white

        case .warning:
            backgroundColor = isOn ? CallsTheme.warning : CallsTheme.control
            glyph.color = isOn ? UIColor(red: 0.067, green: 0.075, blue: 0.094, alpha: 1) : .white

        case .danger:
            backgroundColor = CallsTheme.recording
            glyph.color = .white

        case .answer:
            backgroundColor = CallsTheme.success
            glyph.color = .white
        }
    }

    @objc private func tapped() {
        // A press that does nothing feels broken, so it is answered even when
        // the call is in a state the button cannot change.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // The stylesheet presses its buttons to 0.94; the same here, because a
        // control with no press at all reads as a picture of a control.
        UIView.animate(withDuration: 0.09, animations: {
            self.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        }, completion: { _ in
            UIView.animate(withDuration: 0.09) { self.transform = .identity }
        })

        action()
    }
}

/// A tap on the ground under a call's controls: the stage, a menu's backdrop. It leaves a press on a control to the
/// control, and a press on whatever `keepOff` names to that view. UIKit keeps a standard control's tap from an
/// ancestor's tap recognizer (a UIButton's, a UISwitch's), but not a UIControl of ours: the ancestor took the tap and
/// cancelled the control's, so every button in Device Settings, the join notice and the confirmations did nothing.
final class CallsGroundTap: UITapGestureRecognizer, UIGestureRecognizerDelegate {
    private let keepOff: ( UIView ) -> Bool

    init( target: Any?, action: Selector?, keepOff: @escaping ( UIView ) -> Bool = { _ in false } ) {
        self.keepOff = keepOff

        super.init( target: target, action: action )

        delegate = self
    }

    func gestureRecognizer( _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch ) -> Bool {
        takes( touch.view )
    }

    /// Whether a press on `pressed` is the ground's.
    func takes( _ pressed: UIView? ) -> Bool {
        var on = pressed

        while let view = on, view !== self.view {
            if view is UIControl || keepOff( view ) { return false }
            on = view.superview
        }

        return true
    }
}

/// The translucent row the controls sit in: the web's dock, 5 between its
/// controls and 5 inside a hairline it draws outside its padding, which a
/// layer's border draws inside, so 6 here.
final class CallsDock: UIView {
    let row = UIStackView()
    let padding: CGFloat

    init(spacing: CGFloat = 5, padding: CGFloat = 6) {
        self.padding = padding

        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = CallsTheme.dockGlass
        layer.borderWidth = 1
        layer.borderColor = CallsTheme.dockHairline.cgColor
        layer.cornerCurve = .continuous

        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = spacing

        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            row.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()

        // 26 in the stylesheet, which CSS clamps to half the height on a row
        // this short. Clamped here for the same reason.
        layer.cornerRadius = min(26, bounds.height / 2)
    }
}

/// A group call's connection, the web's connection badge (`.wplus-connection-quality`) as a narrow call draws it at the
/// start of its bar: a 28-point glass disc with a spinner while the room connects or reconnects, and a 7-point dot once
/// it is up, green, or red while this side's connection reads lost. It sits back at 72% and comes forward for three
/// seconds after a change, as the web's does.
final class CallsConnectionPill: UIView {
    static let size: CGFloat = 28

    private let body = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let dot = UIView()
    private var phase = ""
    private var settle: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)

        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        accessibilityLabel = CallsTheme.string("connection_status", fallback: "Connection Status (Quality)")

        // The web's glass at 0.42, under its hairline.
        body.translatesAutoresizingMaskIntoConstraints = false
        body.backgroundColor = UIColor(white: 0, alpha: 0.42)
        body.layer.borderWidth = 1
        body.layer.borderColor = CallsTheme.dockHairline.cgColor
        body.layer.cornerRadius = Self.size / 2
        body.alpha = 0.72

        // The web's spinner is 13 pixels: the system's, scaled to it.
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = UIColor(white: 1, alpha: 0.88)
        spinner.hidesWhenStopped = true
        spinner.transform = CGAffineTransform(scaleX: 0.65, y: 0.65)

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer.cornerRadius = 3.5
        dot.isHidden = true

        addSubview(body)
        body.addSubview(spinner)
        body.addSubview(dot)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: topAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: body.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// `connecting`, `reconnecting` or `in_progress`, and whether this side's connection reads lost.
    func show(phase: String, lost: Bool = false) {
        dot.backgroundColor = lost ? CallsTheme.danger : CallsTheme.success

        guard phase != self.phase else { return }

        self.phase = phase

        let connected = phase == "in_progress"

        if connected { spinner.stopAnimating() } else { spinner.startAnimating() }
        dot.isHidden = !connected

        // Connected, the label says it all: the web's own words for the state are not translated.
        accessibilityValue = connected ? nil : phase == "reconnecting"
            ? CallsTheme.string("reconnecting_self", fallback: "Reconnecting...")
            : CallsTheme.string("connecting", fallback: "Connecting...")

        settle?.cancel()
        body.alpha = 1

        let back = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.2) { self?.body.alpha = 0.72 }
        }

        settle = back
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: back)
    }

    /// Put away with its call: the next one starts from its first state, which comes forward like any change.
    func reset() {
        settle?.cancel()
        settle = nil
        phase = ""
        spinner.stopAnimating()
        dot.isHidden = true
        body.alpha = 0.72
    }
}
