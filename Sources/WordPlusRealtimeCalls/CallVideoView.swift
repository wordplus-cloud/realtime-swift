#if canImport(UIKit)
import UIKit
import LiveKitWebRTC

/// A call's video, drawn: the other side's camera (`call.remoteCamera`) or this side's own picture (`call.localCamera`).
public final class CallVideoView: UIView {
    private let renderer = LKRTCMTLVideoView(frame: .zero)
    private var shown: LKRTCVideoTrack?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        renderer.videoContentMode = .scaleAspectFill
        renderer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(renderer)
        NSLayoutConstraint.activate([
            renderer.leadingAnchor.constraint(equalTo: leadingAnchor),
            renderer.trailingAnchor.constraint(equalTo: trailingAnchor),
            renderer.topAnchor.constraint(equalTo: topAnchor),
            renderer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Whether the picture is drawn as a mirror, as one's own camera usually is.
    public var mirrored = false {
        didSet { renderer.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity }
    }

    /// The track to draw, or nil for none.
    public func show(_ track: CallVideoTrack?) {
        guard shown !== track?.track else { return }
        shown?.remove(renderer)
        shown = track?.track
        shown?.add(renderer)
    }

    deinit {
        shown?.remove(renderer)
    }
}
#endif
