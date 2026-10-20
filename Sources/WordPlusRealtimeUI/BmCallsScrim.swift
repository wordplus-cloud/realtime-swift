import UIKit

/// The gradient the web lays over a ringing call's own-camera picture, so the
/// name, the status and the dock stay readable against whatever the camera
/// happens to be pointing at.
///
/// The stops are `_call-stage.scss`'s, to the number:
/// `linear-gradient(to bottom, rgba(0,0,0,.38) 0%, rgba(0,0,0,.06) 40%, rgba(0,0,0,.6) 100%)`.
final class BmCallsScrim: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    private var gradient: CAGradientLayer { layer as! CAGradientLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        backgroundColor = .clear

        gradient.colors = [
            UIColor(white: 0, alpha: 0.38).cgColor,
            UIColor(white: 0, alpha: 0.06).cgColor,
            UIColor(white: 0, alpha: 0.60).cgColor
        ]

        gradient.locations = [0, 0.4, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }
}
