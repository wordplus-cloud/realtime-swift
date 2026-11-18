import UIKit

/// What a tile or the stage shows over a picture that stopped arriving while
/// its sender is still in the call (`CallsStallWatch`): the last frame
/// stays, blurred and dimmed so it doesn't pass for live, as the web's
/// `bm-call-video-stalled` draws it, and over a camera that alone stopped,
/// "Video interrupted" in the glass chip the web's paused notice wears. The
/// stage of a call between two says why as well: "Their video stopped
/// arriving. It comes back by itself." It comes back sharp with the next
/// frame the room hears.
///
/// Laid over the picture it blurs, which the blur reads from below whatever
/// draws it, and never takes a touch.
final class CallsStalledView: UIView {
    private let blur = UIVisualEffectView(effect: nil)
    private let veil = UIView()
    private let chip = UIView()
    private let icon = CallsIconView(CallsIcons.videoOff)
    private let title = UILabel()
    private let why = UILabel()

    /// The stage of a call between two, whose chip says why as well.
    private let main: Bool

    private(set) var isBlurred = false
    private var noticed = false

    init(main: Bool = false) {
        self.main = main

        super.init(frame: .zero)

        isUserInteractionEnabled = false
        isHidden = true
        clipsToBounds = true

        // the web's paused notice: a 45% veil under its chip
        veil.backgroundColor = UIColor(white: 0, alpha: 0.45)
        veil.alpha = 0

        chip.backgroundColor = UIColor(white: 0, alpha: 0.55)
        chip.layer.cornerRadius = 12
        chip.layer.borderWidth = 1
        chip.layer.borderColor = UIColor(white: 1, alpha: 0.08).cgColor
        chip.alpha = 0
        chip.isAccessibilityElement = true
        chip.accessibilityTraits = .updatesFrequently

        icon.color = .white

        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .white
        title.numberOfLines = main ? 0 : 2

        why.font = .systemFont(ofSize: 13)
        why.textColor = UIColor(white: 1, alpha: 0.85)
        why.numberOfLines = 0
        why.isHidden = !main

        chip.addSubview(icon)
        chip.addSubview(title)
        chip.addSubview(why)

        addSubview(blur)
        addSubview(veil)
        addSubview(chip)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        blur.frame = bounds
        veil.frame = bounds

        // `.bm-call-paused-notice`: 6 by 10 of padding and a 16pt glyph on a
        // tile, 10 by 14 and 22pt on the stage, at most 420 wide there
        let glyph: CGFloat = main ? 22 : 16
        let gap: CGFloat = main ? 10 : 6
        let padX: CGFloat = main ? 14 : 10
        let padY: CGFloat = main ? 10 : 6
        let most = main ? min(bounds.width - 32, 420) : bounds.width - 16
        // a tile too small for the words keeps the glyph
        let words = most - padX * 2 - glyph - gap >= 48
        let textWidth = max(0, most - padX * 2 - glyph - gap)

        title.isHidden = !words
        why.isHidden = !main || !words

        let titleSize = words ? title.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)) : .zero
        let whySize = main && words ? why.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)) : .zero
        let textW = min(textWidth, max(titleSize.width, whySize.width))
        let textH = titleSize.height + (whySize.height > 0 ? 2 + whySize.height : 0)
        let width = padX * 2 + glyph + (words ? gap + textW : 0)
        let height = padY * 2 + max(glyph, textH)

        chip.frame = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        icon.frame = CGRect(x: padX, y: (height - glyph) / 2, width: glyph, height: glyph)

        let textX = padX + glyph + gap
        let textY = (height - textH) / 2

        title.frame = CGRect(x: textX, y: textY, width: textW, height: titleSize.height)
        why.frame = CGRect(x: textX, y: textY + titleSize.height + 2, width: textW, height: whySize.height)
    }

    /// Blurred or sharp again, and "Video interrupted" over it or not: only
    /// over a blurred picture.
    func show(blurred: Bool, notice: Bool) {
        let notice = blurred && notice
        let words = CallsTheme.string("video_interrupted", fallback: "Video interrupted")
        let because = CallsTheme.string("video_interrupted_why", fallback: "Their video stopped arriving. It comes back by itself.")

        title.text = words
        why.text = because
        chip.accessibilityLabel = main ? words + ". " + because : words

        let quick = UIAccessibility.isReduceMotionEnabled

        if notice != noticed {
            noticed = notice

            setNeedsLayout()

            UIView.animate(withDuration: quick ? 0 : 0.3, delay: 0, options: [.beginFromCurrentState]) {
                self.chip.alpha = notice ? 1 : 0
                self.veil.alpha = notice ? 1 : 0
            }

            // the web's chip is a status: said once as it comes up, after
            // whatever is being read
            if notice, window != nil, UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: NSAttributedString(string: words, attributes: [.accessibilitySpeechQueueAnnouncement: true])
                )
            }
        }

        guard blurred != isBlurred else { return }

        isBlurred = blurred

        if blurred {
            isHidden = false

            UIView.animate(withDuration: quick ? 0 : 0.3, delay: 0, options: [.beginFromCurrentState]) {
                self.blur.effect = UIBlurEffect(style: .dark)
            }
        } else {
            UIView.animate(withDuration: quick ? 0 : 0.2, delay: 0, options: [.beginFromCurrentState], animations: {
                self.blur.effect = nil
                self.chip.alpha = 0
                self.veil.alpha = 0
            }, completion: { _ in
                guard !self.isBlurred else { return }

                self.isHidden = true
            })
        }
    }
}
