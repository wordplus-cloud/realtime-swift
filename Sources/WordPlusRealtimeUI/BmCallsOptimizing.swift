import UIKit

/// What a tile or the stage shows while its person's camera changes codec
/// (`BmCallsCameraSwitch`): their picture, blurred and dimmed, behind a slow
/// ring and the words, so a second without video reads as the call working on
/// it rather than as the camera going off. The web's tile draws the same.
///
/// It fades in and out rather than cutting, and says itself once to
/// VoiceOver, queued behind whatever is being read rather than over it: once
/// a change per person where a grid shares its `said` among its tiles, since
/// a person's tile can move to another one while their camera changes.
final class BmCallsOptimizingView: UIView {
    private let backdrop = UIImageView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let veil = UIView()
    private let ring = CAShapeLayer()
    private let ringTrack = CAShapeLayer()
    private let label = UILabel()

    private(set) var isUp = false
    private var announced = false
    /// Who has been told, by person, shared by a grid's tiles; nil for a view
    /// of its own, which says itself once each time it comes up.
    var said: BmCallsOptimizingSaid?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        clipsToBounds = true
        isUserInteractionEnabled = false
        backgroundColor = BmCallsTheme.tile
        alpha = 0
        isHidden = true

        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        // A face blurred this far is only colour: enough to say whose tile it
        // is without pretending to be the picture.
        backdrop.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)

        veil.backgroundColor = UIColor(white: 0, alpha: 0.35)

        ringTrack.fillColor = UIColor.clear.cgColor
        ringTrack.strokeColor = UIColor(white: 1, alpha: 0.18).cgColor
        ringTrack.lineWidth = 2.5

        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor(white: 1, alpha: 0.9).cgColor
        ring.lineWidth = 2.5
        ring.lineCap = .round
        ring.strokeStart = 0
        ring.strokeEnd = 0.28

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = UIColor(white: 1, alpha: 0.92)
        label.textAlignment = .center
        label.numberOfLines = 2
        label.adjustsFontForContentSizeCategory = true

        addSubview(backdrop)
        addSubview(blur)
        addSubview(veil)
        layer.addSublayer(ringTrack)
        layer.addSublayer(ring)
        addSubview(label)

        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        backdrop.frame = bounds
        blur.frame = bounds
        veil.frame = bounds

        // A ring that keeps to the tile: a quarter of its shorter side at
        // most, so a small grid tile still has room for the words.
        let side = min(bounds.width, bounds.height)
        let diameter = max(18, min(36, side * 0.22))
        let showsWords = side >= 96
        let labelHeight: CGFloat = showsWords ? 36 : 0
        let gap: CGFloat = showsWords ? 10 : 0
        let top = bounds.midY - (diameter + gap + labelHeight) / 2

        let circle = CGRect(x: bounds.midX - diameter / 2, y: top, width: diameter, height: diameter)
        let path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: circle.size)).cgPath

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [ringTrack, ring] {
            shape.frame = circle
            shape.path = path
        }
        CATransaction.commit()

        label.isHidden = !showsWords
        label.frame = CGRect(x: 8, y: circle.maxY + gap, width: bounds.width - 16, height: labelHeight)
    }

    /// Up with `picture` behind it (nil: the tile's own colour), or down.
    /// `key` is whose camera it is, for `said`.
    func show(_ up: Bool, picture: UIImage?, key: String? = nil) {
        let text = BmCallsTheme.string("optimizing_video", fallback: "Optimizing video quality...")
        label.text = text
        accessibilityLabel = text

        if backdrop.image !== picture { backdrop.image = picture }
        backdrop.isHidden = picture == nil

        guard up != isUp else { return }

        isUp = up

        if up {
            isHidden = false
            spin(true)

            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                self.alpha = 1
            }

            if !announced, window != nil, UIAccessibility.isVoiceOverRunning {
                announced = true

                // Not where another tile of the same person said it already.
                let first = key.flatMap { key in said?.first(key) } ?? true

                if first {
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
                    )
                }
            }
        } else {
            announced = false

            UIView.animate(withDuration: 0.35, delay: 0, options: [.beginFromCurrentState, .curveEaseIn], animations: {
                self.alpha = 0
            }, completion: { _ in
                guard !self.isUp else { return }

                self.isHidden = true
                self.spin(false)
            })
        }
    }

    /// A slow turn, eased so it breathes rather than whirs.
    private func spin(_ on: Bool) {
        ring.removeAllAnimations()

        guard on, !UIAccessibility.isReduceMotionEnabled else { return }

        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = Double.pi * 2
        turn.duration = 1.4
        turn.repeatCount = .infinity
        turn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        turn.isRemovedOnCompletion = false

        ring.add(turn, forKey: "turn")
    }
}

/// Whose camera changing codec has been said, by person, for a grid's tiles
/// to share: said once a change, whichever of them shows it, until the grid
/// sees that person's change over (`keep`). On the main queue.
final class BmCallsOptimizingSaid {
    private var said = Set<String>()

    /// Whether `key` is still to be told of, counted as told from now.
    func first(_ key: String) -> Bool {
        said.insert(key).inserted
    }

    /// Only these are still changing: anyone else is told of their next change.
    func keep(_ keys: Set<String>) {
        said.formIntersection(keys)
    }
}
