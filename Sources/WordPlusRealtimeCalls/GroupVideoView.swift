#if canImport(UIKit)
import UIKit
import LiveKit

/**
 A group call's picture, drawn for an app's own screen: someone's camera or shared screen (`show(_:of:)`), or this app's
 own camera (`showOwn(of:)`), filling the view. What `CallScreen`'s grid draws, for an app that draws its own grid
 instead. Call it again when the call's `onPeople` says what someone sends changed: a
 camera turned off shows nothing.

 ```swift
 call.onPeople {
     for person in call.people { tiles[person.identity]?.video.show(person.identity, of: call) }
 }
 ```
 */
@MainActor
public final class GroupVideoView: UIView {
    private let video = VideoView()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        video.layoutMode = .fill
        video.translatesAutoresizingMaskIntoConstraints = false
        addSubview(video)
        NSLayoutConstraint.activate([
            video.leadingAnchor.constraint(equalTo: leadingAnchor),
            video.trailingAnchor.constraint(equalTo: trailingAnchor),
            video.topAnchor.constraint(equalTo: topAnchor),
            video.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Whether the picture fills the view, cropped (true, the default), or fits inside it, as a shared screen should.
    public var fills = true {
        didSet { video.layoutMode = fills ? .fill : .fit }
    }

    /// Whether the picture is drawn as a mirror, as one's own camera usually is.
    public var mirrored = false {
        didSet { video.mirrorMode = mirrored ? .mirror : .off }
    }

    /// Someone's camera or shared screen (`GroupPerson.identity`), or nothing for nil or a picture they don't send.
    public func show(_ identity: String?, of call: GroupCall, source: GroupVideoSource = .camera) {
        video.track = identity.flatMap { call.videoTrack(of: $0, source: source) }
    }

    /// This app's own camera while it is sent into the call.
    public func showOwn(of call: GroupCall) {
        video.track = call.ownCameraTrack
    }

    /// Draws nothing.
    public func clear() {
        video.track = nil
    }
}
#endif
