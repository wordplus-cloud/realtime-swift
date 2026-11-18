#if canImport(UIKit)
import UIKit
import LiveKit

/**
 A live stream's picture: the stage's main one as the stream goes (the spotlight's, a shared screen, the host's), or one
 tile's (`show(_:tile:)`), filling the view. A host sees their own camera here from `preview()` on. Its sound plays by
 itself while the stream is watched.

 ```swift
 let stream = try await rt.calls.stream("show:42")
 player.show(stream)
 ```
 */
@MainActor
public final class LiveStreamVideoView: UIView {
    private let video = VideoView()
    private weak var stream: LiveStream?
    private var tile: String?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        video.layoutMode = .fit
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

    /// Whether the picture fills the view, cropped, or fits inside it (the default: a stream's picture is seen whole).
    public var fills = false {
        didSet { video.layoutMode = fills ? .fill : .fit }
    }

    /// The stream's main picture, or the tile `identity`'s (`LiveStreamTile.identity`), following it as it changes.
    public func show(_ stream: LiveStream, tile identity: String? = nil) {
        if self.stream !== stream { self.stream?.hide(from: self) }
        self.stream = stream
        tile = identity
        stream.show(in: self)
    }

    /// Draws nothing, and stops following the stream.
    public func clear() {
        stream?.hide(from: self)
        stream = nil
        video.track = nil
    }

    /// Whether a picture is drawn now.
    public var showsPicture: Bool { video.track != nil }

    func draw(_ stream: LiveStream) {
        let shown = tile.flatMap { id in stream.tiles.first { $0.identity == id } } ?? (tile == nil ? stream.mainTile : nil)
        let track = stream.videoTrack(of: shown)
        if video.track !== track { video.track = track }
        video.mirrorMode = shown?.local == true ? .mirror : .off
        // A picture comes at the size its view asks: a viewer's choice of layer (`setQuality`) is that layer's size.
        let density = stream.chosenLayer(of: shown).flatMap { LiveStreamPicture.density(for: $0, in: bounds.size, fills: fills) }
        video.adaptiveStreamPixelDensity = density.map { .fixed($0) } ?? .auto
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if let stream { draw(stream) }
    }
}
#endif
