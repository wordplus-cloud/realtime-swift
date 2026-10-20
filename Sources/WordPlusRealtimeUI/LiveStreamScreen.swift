import UIKit
import WordPlusRealtime
import WordPlusRealtimeCalls

/**
 A live stream drawn ready for its viewers, as the web player draws it: the picture, Live and how many watch over it, the
 stream's title, the chat with a field to write in, and a heart for reactions, which float up the picture as everyone
 sends them. Optional, as the module is: an app that draws its own uses `LiveStream` and `LiveStreamVideoView` alone.
 The host goes live from the studio on the web, or with the stream's own calls (`preview()`, `goLive()`).

 ```swift
 let stream = try await rt.calls.stream("show:42")
 present(LiveStreamScreen(stream: stream, title: "The new mugs"), animated: true)
 ```

 Closing it leaves the stream (`leavesOnClose`) and dismisses the screen, unless `onClose` does something else.
 */
@MainActor
public final class LiveStreamScreen: UIViewController, UITableViewDataSource, UITextFieldDelegate {
    /// The screen's words and its colour.
    public struct Appearance {
        /// Its strings in the user's language, by key: `live`, `watching` (`%d` the count), `starts_soon`, `ended`,
        /// `say_something`, `send`, `read_only`, `pinned`, `react`, `close`, `not_sent` (`%@` the code). The English is
        /// the default for any left out.
        public var strings: [String: String]
        /// The send button's and the field's colour.
        public var accent: UIColor

        public init(strings: [String: String] = [:], accent: UIColor = UIColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1)) {
            self.strings = strings
            self.accent = accent
        }
    }

    static let english: [String: String] = [
        "live": "Live",
        "watching": "%d watching",
        "starts_soon": "The stream starts soon",
        "ended": "This stream has ended",
        "say_something": "Say something…",
        "send": "Send",
        "read_only": "Chat is read-only for you",
        "pinned": "Pinned",
        "react": "Send a heart",
        "close": "Close",
        "not_sent": "Not sent (%@)",
    ]

    public let stream: LiveStream
    public let streamTitle: String?
    public var appearance: Appearance {
        didSet { if isViewLoaded { styled() } }
    }
    /// Whether closing the screen leaves the stream (true), or keeps it for the app.
    public var leavesOnClose = true
    /// What closing does, in place of dismissing the screen.
    public var onClose: (() -> Void)?

    let picture = LiveStreamVideoView()
    let note = UILabel()
    let badge = PaddedLabel()
    let viewers = PaddedLabel()
    let close = UIButton(type: .system)
    let titleLabel = UILabel()
    let pinned = PaddedLabel()
    let table = UITableView(frame: .zero, style: .plain)
    let field = UITextField()
    let send = UIButton(type: .system)
    let heart = UIButton(type: .system)
    let failure = UILabel()
    private let floats = UIView()
    private var shown: [LiveStreamMessage] = []
    private var sending = false

    public init(stream: LiveStream, title: String? = nil, appearance: Appearance = Appearance()) {
        self.stream = stream
        self.streamTitle = title
        self.appearance = appearance
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func text(_ key: String) -> String {
        appearance.strings[key] ?? Self.english[key] ?? key
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "stream-screen"
        build()
        styled()
        picture.show(stream)
        stream.onChange { [weak self] in self?.render() }
        stream.onReactions { [weak self] counts in
            guard let self else { return }
            for emoji in counts.flatMap({ Array(repeating: $0.key, count: $0.value) }).prefix(6) { self.float(emoji) }
        }
        render()
    }

    // MARK: - Building it

    private func build() {
        let stage = UIView()
        stage.backgroundColor = .black
        stage.clipsToBounds = true
        picture.isAccessibilityElement = true
        picture.accessibilityIdentifier = "stream-picture"
        note.textColor = .white
        note.font = .preferredFont(forTextStyle: .headline)
        note.textAlignment = .center
        note.numberOfLines = 0
        note.accessibilityIdentifier = "stream-note"
        badge.backgroundColor = UIColor(red: 0.86, green: 0.15, blue: 0.15, alpha: 1)
        badge.textColor = .white
        badge.font = .systemFont(ofSize: 12, weight: .bold)
        badge.layer.cornerRadius = 4
        badge.clipsToBounds = true
        badge.accessibilityIdentifier = "stream-live"
        viewers.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        viewers.textColor = .white
        viewers.font = .systemFont(ofSize: 12, weight: .semibold)
        viewers.layer.cornerRadius = 4
        viewers.clipsToBounds = true
        viewers.accessibilityIdentifier = "stream-viewers"
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = .white
        close.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        close.layer.cornerRadius = 16
        close.accessibilityIdentifier = "stream-close"
        close.addTarget(self, action: #selector(closed), for: .touchUpInside)
        floats.isUserInteractionEnabled = false

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 2
        titleLabel.text = streamTitle
        titleLabel.isHidden = streamTitle?.isEmpty ?? true
        pinned.font = .preferredFont(forTextStyle: .subheadline)
        pinned.numberOfLines = 2
        pinned.backgroundColor = .secondarySystemBackground
        pinned.layer.cornerRadius = 8
        pinned.clipsToBounds = true
        pinned.accessibilityIdentifier = "stream-pinned"

        table.dataSource = self
        table.separatorStyle = .none
        table.allowsSelection = false
        table.keyboardDismissMode = .interactive
        table.register(UITableViewCell.self, forCellReuseIdentifier: "message")
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 28
        table.accessibilityIdentifier = "stream-chat"

        field.borderStyle = .roundedRect
        field.returnKeyType = .send
        field.delegate = self
        field.accessibilityIdentifier = "stream-field"
        send.setImage(UIImage(systemName: "paperplane.fill"), for: .normal)
        send.accessibilityIdentifier = "stream-send"
        send.addTarget(self, action: #selector(sent), for: .touchUpInside)
        heart.setImage(UIImage(systemName: "heart.fill"), for: .normal)
        heart.tintColor = UIColor(red: 0.93, green: 0.27, blue: 0.4, alpha: 1)
        heart.accessibilityIdentifier = "stream-react"
        heart.addTarget(self, action: #selector(hearted), for: .touchUpInside)
        failure.font = .preferredFont(forTextStyle: .footnote)
        failure.textColor = .secondaryLabel
        failure.numberOfLines = 0
        failure.isHidden = true
        failure.accessibilityIdentifier = "stream-failure"

        let composer = UIStackView(arrangedSubviews: [field, heart, send])
        composer.spacing = 8
        composer.alignment = .center
        let below = UIStackView(arrangedSubviews: [titleLabel, pinned, table, failure, composer])
        below.axis = .vertical
        below.spacing = 8

        for v in [stage, picture, note, badge, viewers, close, floats, below] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false }
        stage.addSubview(picture)
        stage.addSubview(note)
        stage.addSubview(floats)
        stage.addSubview(badge)
        stage.addSubview(viewers)
        stage.addSubview(close)
        view.addSubview(stage)
        view.addSubview(below)

        let safe = view.safeAreaLayoutGuide
        let sixteenByNine = stage.heightAnchor.constraint(equalTo: stage.widthAnchor, multiplier: 9 / 16)
        sixteenByNine.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: safe.topAnchor),
            stage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sixteenByNine,
            stage.heightAnchor.constraint(lessThanOrEqualTo: safe.heightAnchor, multiplier: 0.6),
            picture.topAnchor.constraint(equalTo: stage.topAnchor),
            picture.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            picture.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            floats.topAnchor.constraint(equalTo: stage.topAnchor),
            floats.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            floats.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            floats.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            note.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            note.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 24),
            note.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -24),
            badge.topAnchor.constraint(equalTo: stage.topAnchor, constant: 12),
            badge.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            viewers.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            viewers.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 6),
            close.topAnchor.constraint(equalTo: stage.topAnchor, constant: 8),
            close.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),
            close.widthAnchor.constraint(equalToConstant: 32),
            close.heightAnchor.constraint(equalToConstant: 32),
            below.topAnchor.constraint(equalTo: stage.bottomAnchor, constant: 12),
            below.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            below.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            below.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            send.widthAnchor.constraint(equalToConstant: 36),
            heart.widthAnchor.constraint(equalToConstant: 36),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
    }

    private func styled() {
        badge.text = text("live").uppercased()
        field.placeholder = text("say_something")
        field.tintColor = appearance.accent
        send.tintColor = appearance.accent
        send.accessibilityLabel = text("send")
        heart.accessibilityLabel = text("react")
        close.accessibilityLabel = text("close")
        render()
    }

    // MARK: - Drawing it

    func render() {
        guard isViewLoaded else { return }
        let live = stream.state == .live
        badge.isHidden = !live
        viewers.isHidden = !live
        viewers.text = String(format: text("watching"), stream.viewers)
        switch stream.state {
        case .idle: note.text = text("starts_soon")
        case .ended: note.text = text("ended")
        case .live: note.text = nil
        }
        note.isHidden = note.text == nil
        picture.accessibilityValue = picture.showsPicture ? "picture" : "none"
        heart.isHidden = !(live && stream.reactionsOn)
        let writes = stream.canWrite
        field.isEnabled = writes && !sending
        send.isEnabled = writes && !sending
        field.placeholder = writes ? text("say_something") : text("read_only")
        if let message = stream.pinned {
            pinned.attributedText = line(message, prefix: text("pinned") + ": ")
            pinned.isHidden = false
        } else {
            pinned.isHidden = true
        }
        if stream.messages.map(\.id) != shown.map(\.id) {
            shown = stream.messages
            table.reloadData()
            if !shown.isEmpty { table.scrollToRow(at: IndexPath(row: shown.count - 1, section: 0), at: .bottom, animated: false) }
        }
    }

    private func line(_ message: LiveStreamMessage, prefix: String = "") -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .subheadline)
        let bold = UIFont.systemFont(ofSize: body.pointSize, weight: .semibold)
        let out = NSMutableAttributedString(string: prefix, attributes: [.font: body, .foregroundColor: UIColor.secondaryLabel])
        out.append(NSAttributedString(string: message.name + "  ", attributes: [.font: bold, .foregroundColor: UIColor.label]))
        out.append(NSAttributedString(string: message.text, attributes: [.font: body, .foregroundColor: UIColor.label]))
        return out
    }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        shown.count
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "message", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.attributedText = line(shown[indexPath.row])
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0)
        cell.contentConfiguration = content
        // Its text in line with the title, not the table's own margins.
        cell.preservesSuperviewLayoutMargins = false
        cell.directionalLayoutMargins = .zero
        cell.backgroundColor = .clear
        cell.accessibilityIdentifier = "stream-message"
        return cell
    }

    // MARK: - What the person does

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sent()
        return false
    }

    @objc private func sent() {
        let words = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !sending else { return }
        sending = true
        failure.isHidden = true
        render()
        Task { @MainActor in
            do {
                try await stream.send(words)
                field.text = ""
            } catch {
                failure.text = String(format: text("not_sent"), (error as? CallError)?.code ?? "\(error)")
                failure.isHidden = false
            }
            sending = false
            render()
        }
    }

    @objc private func hearted() {
        stream.react(.heart)
        float(LiveStreamReaction.heart.rawValue)
    }

    @objc func closed() {
        if leavesOnClose { stream.leave() }
        if let onClose { onClose() } else { dismiss(animated: true) }
    }

    /// A reaction floating up the picture, from its lower right: the emoji that was sent.
    private func float(_ emoji: String) {
        guard floats.bounds.height > 0 else { return }
        let image = UILabel()
        image.text = emoji
        image.font = .systemFont(ofSize: 20)
        image.textAlignment = .center
        let x = floats.bounds.width - 36 - CGFloat.random(in: 0...24)
        image.frame = CGRect(x: x, y: floats.bounds.height - 40, width: 24, height: 22)
        floats.addSubview(image)
        UIView.animate(withDuration: 1.8, delay: 0, options: [.curveEaseOut], animations: {
            image.frame.origin.y = self.floats.bounds.height * 0.25
            image.frame.origin.x += CGFloat.random(in: -20...8)
            image.alpha = 0
        }, completion: { _ in image.removeFromSuperview() })
    }
}

/// A label with room around its text, for the badges over the picture.
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 3, left: 7, bottom: 3, right: 7)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}
