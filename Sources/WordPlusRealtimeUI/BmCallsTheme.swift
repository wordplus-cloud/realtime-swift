import UIKit

/// The colours and the words the call screens use.
///
/// Both come from the site: the palette the person chose in the Design tab and
/// the strings in their language, handed over in `configure` and kept with the
/// rest of the config. A phone that has never been configured still has to
/// draw something, so every lookup has a fallback that reads as a call screen.
enum BmCallsTheme {
    /// The site's palette is keyed the way the stylesheet writes it — the
    /// custom property's own name — so a lookup for `accent` finds nothing and
    /// every colour on the call screen silently falls back to a built-in one.
    /// Both spellings are tried, the prefixed one first.
    static func color(_ token: String, fallback: UIColor) -> UIColor {
        guard let config = BmCallsConfigStore.current else { return fallback }

        let tokens = config.darkMode ? config.designTokensDark : config.designTokens

        // `--bm-call-canvas` and the call screen's other own tokens are found as `call-canvas` too, as the web names them.
        for name in [ "--bm-color-" + token, "--bm-" + token, token ] {
            guard let value = tokens[name] ?? config.designTokens[name],
                  let parsed = BmCallsTheme.parse(value) else {
                continue
            }

            return parsed
        }

        return fallback
    }

    static func string(_ key: String, fallback: String) -> String {
        BmCallsConfigStore.current?.strings[key] ?? fallback
    }

    /// Whether the microphone and camera controls wear the state they are in
    /// or the action they perform — the site's "Invert Mute/Hide Icons"
    /// setting, which the app used to ignore. The default is the state, which
    /// is what the web draws with the setting off and what these screens have
    /// always drawn.
    static var showsState: Bool { BmCallsConfigStore.current?.iconsReverted ?? true }

    /// The one place the microphone's glyph is decided, so the dock and the
    /// tap that changes it cannot end up saying different things. Android
    /// decides it in one place too, in `BmCallsRoundButton.symbol`.
    static func micIcon(muted: Bool) -> String {
        (showsState ? muted : !muted) ? BmCallsIcons.micOff : BmCallsIcons.mic
    }

    static func cameraIcon(on: Bool) -> String {
        (showsState ? on : !on) ? BmCallsIcons.video : BmCallsIcons.videoOff
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
enum BmCallsButtonTone {
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

final class BmCallsButton: UIView {
    private let glyph: BmCallsIconView
    /// Variables so the dock can keep a host's button and take what its pieces gave anew (BmCallsScreen.keepDocked).
    var action: () -> Void
    private(set) var icon: String
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var glyphSize: [NSLayoutConstraint] = []

    let tone: BmCallsButtonTone

    var isOn = false {
        didSet { restyle() }
    }

    init(icon: String, tone: BmCallsButtonTone = .control, action: @escaping () -> Void) {
        self.glyph = BmCallsIconView(icon)
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

        let width = widthAnchor.constraint(equalToConstant: BmCallsButton.stride(for: tone, diameter: 34))
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
    /// is always the narrowest of them: 34 with a 4 gap, against 40 on a
    /// desktop call column.
    static func diameter(for width: CGFloat) -> CGFloat {
        if width <= 559 { return 34 }
        if width <= 719 { return 36 }

        return 40
    }

    /// Hanging up and answering are pills rather than discs, so they cannot be
    /// mistaken for one of the toggles beside them.
    private static func stride(for tone: BmCallsButtonTone, diameter: CGFloat) -> CGFloat {
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

        widthConstraint?.constant = BmCallsButton.stride(for: tone, diameter: diameter)
        heightConstraint?.constant = diameter

        for constraint in glyphSize { constraint.constant = round(diameter * 0.5) }

        layer.cornerRadius = diameter / 2
    }

    /**
     A control wider than it is tall, for the chat chevron.

     It is the one the stylesheet does not draw as a disc — 44 by 20 against
     the bottom edge — and it owns its own width and height constraints. Giving
     it a shape from outside only set two constraints fighting the two it
     already had, and left the glyph at the size of a disc it is no longer.
     */
    func setTab(width: CGFloat, height: CGFloat) {
        widthConstraint?.constant = width
        heightConstraint?.constant = height

        for constraint in glyphSize { constraint.constant = round(height * 0.5) }

        layer.cornerRadius = height / 2
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
            backgroundColor = BmCallsTheme.control
            glyph.color = .white

        case .medium:
            backgroundColor = isOn ? BmCallsTheme.controlActive : BmCallsTheme.control
            glyph.color = isOn ? BmCallsTheme.recording : .white

        case .latch:
            backgroundColor = isOn ? BmCallsTheme.accent : BmCallsTheme.control
            glyph.color = isOn ? BmCallsTheme.onAccent : .white

        case .warning:
            backgroundColor = isOn ? BmCallsTheme.warning : BmCallsTheme.control
            glyph.color = isOn ? UIColor(red: 0.067, green: 0.075, blue: 0.094, alpha: 1) : .white

        case .danger:
            backgroundColor = BmCallsTheme.recording
            glyph.color = .white

        case .answer:
            backgroundColor = BmCallsTheme.success
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

/// The translucent row the controls sit in.
final class BmCallsDock: UIView {
    let row = UIStackView()

    init(spacing: CGFloat = 4, padding: CGFloat = 5) {
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = BmCallsTheme.dockGlass
        layer.borderWidth = 1
        layer.borderColor = BmCallsTheme.dockHairline.cgColor
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
