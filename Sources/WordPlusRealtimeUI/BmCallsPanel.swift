import UIKit

/// One line in a panel.
struct BmCallsPanelRow {
    let title: String
    var selected: Bool = false
    var destructive: Bool = false
    let run: () -> Void
}

/// The call's own way of asking a question.
///
/// Configure and Participants used to be `UIAlertController` action sheets.
/// They worked, and they looked like what they were: a piece of iOS put on top
/// of the call rather than a piece of the call. They did not look built into
/// the call natively, and the arrow on the popover pointing back
/// at the dock made the seam obvious.
///
/// This is the same list drawn on the call screen itself, in the language the
/// rest of it already speaks: the glass the peer notice and the error card are
/// made of, the card radius, the dock's own width. Nothing is presented, so
/// nothing takes the screen away from the call — which also settles the second
/// half of the report, a video that stopped while the sheet was up: a view
/// LiveKit thinks nobody is looking at is a view it may stop feeding, and an
/// alert covering the stage is exactly that.
final class BmCallsPanel: UIView {
    private let card = UIView()
    private let rows = UIStackView()
    private var onDismiss: (() -> Void)?

    /// The second line of the header, kept so a panel showing a figure that
    /// keeps moving can be handed the new one without being rebuilt.
    private weak var detail: UILabel?

    override init(frame: CGRect) {
        super.init(frame: frame)

        // Clear rather than dimmed: the web does not dim behind its Configure
        // panel either, and the call is the thing worth looking at.
        backgroundColor = .clear

        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(white: 0, alpha: 0.82)
        card.layer.cornerRadius = 14
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 1, alpha: 0.08).cgColor
        card.clipsToBounds = true

        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.axis = .vertical
        rows.spacing = 0

        card.addSubview(rows)
        addSubview(card)

        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rows.topAnchor.constraint(equalTo: card.topAnchor),
            rows.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(backdropTapped)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A tap anywhere off the card closes it, which is what an action sheet
    /// did and what anyone will try first.
    @objc private func backdropTapped() {
        onDismiss?()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // The panel only exists while it is shown, so it may claim the whole
        // screen: outside the card that claim is what closes it.
        bounds.contains(point)
    }

    /// Put it on the call, with the card just above whatever the dock's top
    /// edge is — the same twelve points the error card leaves.
    func place(in host: UIView, above dock: UIView) {
        translatesAutoresizingMaskIntoConstraints = false

        host.addSubview(self)

        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),

            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.bottomAnchor.constraint(equalTo: dock.topAnchor, constant: -12),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            // The dock's own width at every size, so the two read as one
            // object rather than a card and a row that happen to be near
            // each other.
            card.widthAnchor.constraint(greaterThanOrEqualTo: dock.widthAnchor),
            card.topAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: 16)
        ])
    }

    func fill(title: String, message: String?, entries: [BmCallsPanelRow], dismiss: @escaping () -> Void) {
        onDismiss = dismiss

        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }

        rows.addArrangedSubview(header(title: title, message: message))

        for entry in entries {
            rows.addArrangedSubview(separator())
            rows.addArrangedSubview(row(entry))
        }
    }

    /// A new second line for a panel already on screen.
    ///
    /// The byte counts behind the gear are sampled every two seconds and the
    /// web redraws them as they come, so a panel left open there counts up.
    /// Filling this once at open time and leaving it would have shown a figure
    /// frozen at whatever it was when the card appeared.
    func update(message: String?) {
        guard let detail = detail else { return }

        detail.text = message ?? ""
    }

    private func header(title: String, message: String?) -> UIView {
        let holder = UIView()
        let stack = UIStackView()

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 4

        let name = UILabel()
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.textColor = .white
        name.numberOfLines = 2
        name.text = title
        stack.addArrangedSubview(name)

        if let message = message, !message.isEmpty {
            let detail = UILabel()
            detail.font = .systemFont(ofSize: 13)
            detail.textColor = UIColor(white: 1, alpha: 0.65)
            detail.numberOfLines = 0
            detail.text = message
            stack.addArrangedSubview(detail)

            self.detail = detail
        }

        holder.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: holder.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -14)
        ])

        return holder
    }

    private func separator() -> UIView {
        let line = UIView()

        line.backgroundColor = UIColor(white: 1, alpha: 0.08)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true

        return line
    }

    private func row(_ entry: BmCallsPanelRow) -> UIView {
        let button = BmCallsPanelRowView(entry: entry) { [weak self] in
            self?.onDismiss?()
            entry.run()
        }

        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 48).isActive = true

        return button
    }
}

/// One tappable line, highlighting while the finger is down the way a sheet's
/// row does.
private final class BmCallsPanelRowView: UIControl {
    private let run: () -> Void

    init(entry: BmCallsPanelRow, run: @escaping () -> Void) {
        self.run = run

        super.init(frame: .zero)

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 15)
        title.textColor = entry.destructive
            ? BmCallsTheme.recording
            : .white
        title.numberOfLines = 1
        title.text = entry.title
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(title)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        let tick = UILabel()
        tick.translatesAutoresizingMaskIntoConstraints = false
        tick.font = .systemFont(ofSize: 15, weight: .semibold)
        tick.textColor = .white
        tick.text = entry.selected ? "✓" : ""

        addSubview(tick)

        NSLayoutConstraint.activate([
            tick.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            tick.centerYAnchor.constraint(equalTo: centerYAnchor),
            tick.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 10)
        ])

        addTarget(self, action: #selector(pressed), for: .touchUpInside)
        addTarget(self, action: #selector(down), for: [.touchDown, .touchDragEnter])
        addTarget(self, action: #selector(up), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func pressed() { run() }
    @objc private func down() { backgroundColor = UIColor(white: 1, alpha: 0.1) }
    @objc private func up() { backgroundColor = .clear }
}
