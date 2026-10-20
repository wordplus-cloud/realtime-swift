import UIKit

/// The messenger's own icons, drawn from the paths the web draws them from.
///
/// The call screen is meant to be the mobile web's call screen, and SF Symbols
/// are not it: they are filled where these are stroked, they sit on a
/// different grid, and their weights do not agree with one another. So the
/// registry's path data is carried over verbatim from `src/main/primitives/
/// icon.tsx` — Lucide's 24 grid, `|` between subpaths — and stroked here at
/// the 1.85 the call stylesheet asks for, scaled to whatever size it is drawn
/// at.
///
/// Keep these in step with the registry. They are the same glyphs on both
/// sides of the same call.
enum BmCallsIcons {
    static let phone = "M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72c.12.94.34 1.86.66 2.74a2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.34-1.34a2 2 0 0 1 2.11-.45c.88.32 1.8.54 2.74.66A2 2 0 0 1 22 16.92Z"
    static let mic = "M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3zM19 11v1a7 7 0 0 1-14 0v-1M12 19v3M8 22h8"
    static let micOff = "M12 19v3|M8 22h8|m2 2 20 20|M18.89 13.23A7.12 7.12 0 0 0 19 12v-2|M5 10v2a7 7 0 0 0 12 5|M15 9.34V5a3 3 0 0 0-5.68-1.33|M9 9v3a3 3 0 0 0 5.12 2.12"
    static let video = "m16 13 5.223 3.482a.5.5 0 0 0 .777-.416V7.87a.5.5 0 0 0-.752-.432L16 10.5|M4 6h10a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-10a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2z"
    static let videoOff = "M10.66 6H14a2 2 0 0 1 2 2v2.5l5.248-3.494A.5.5 0 0 1 22 7.435v8.13a.5.5 0 0 1-.752.43L16 13.5|M16 16a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h2|m2 2 20 20"
    static let pip = "M21 9V6a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v10c0 1.1.9 2 2 2h4|M12 13h8a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2h-8a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2z"
    static let screenShare = "M13 3H4a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-3|M8 21h8|M12 17v4|m17 8 5-5|M17 3h5v5"
    static let screenShareOff = "M13 3H4a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-3|M8 21h8|M12 17v4|m22 3-5 5|m17 3 5 5"
    static let settings = "M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915|M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z"
    static let switchCamera = "M11 19H4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h5|M13 5h7a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2h-5|M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0z|m18 22-3-3 3-3|m6 2 3 3-3 3"
    static let speaker = "M11 5 6 9H2v6h4l5 4V5zM15.5 8.5a5 5 0 0 1 0 7M19 5a9 9 0 0 1 0 14"
    static let speakerOff = "M11 5 6 9H2v6h4l5 4V5z|m23 9-6 6|m17 9 6 6"
    static let users = "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2|M16 3.128a4 4 0 0 1 0 7.744|M22 21v-2a4 4 0 0 0-3-3.87|M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z"
    static let flip = "M12 3v18|M9 7 4 12l5 5V7zM15 7l5 5-5 5V7z"
    static let alert = "M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20z|M12 8v4|M12 16h.01"
    static let wifiOff = "M12 20h.01|M8.5 16.429a5 5 0 0 1 7 0|M5 12.859a10 10 0 0 1 5.17-2.69|M19 12.859a10 10 0 0 0-2.007-1.523|M2 8.82a15 15 0 0 1 4.177-2.643|M22 8.82a15 15 0 0 0-11.288-3.764|m2 2 20 20"
    static let swapVideos = "M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8|M21 3v5h-5|M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16|M8 16H3v5"
    static let chevronDown = "m6 9 6 6 6-6"
    static let raiseHand = "M7 11V5a2 2 0 1 1 4 0v6M11 11V3a2 2 0 1 1 4 0v8M15 11V5a2 2 0 1 1 4 0v9a8 8 0 0 1-8 8H9a4 4 0 0 1-4-4l-2-5 1.5-1.5L7 13"
    /// Leaving a room, which is what ending a group call is — the web's
    /// `bm-exit-room` uses this glyph rather than the handset.
    static let logout = "M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4|m16 17 5-5-5-5|M21 12H9"

    /// Cached because a call screen redraws its dock on every state change and
    /// parsing seventeen paths each time is work nobody asked for.
    private static var cache: [String: CGPath] = [:]
    private static let lock = NSLock()

    /// The glyph on the 24 grid, unscaled.
    static func path(_ data: String) -> CGPath {
        lock.lock()
        defer { lock.unlock() }

        if let known = cache[data] { return known }

        let built = BmCallsSVGPath.parse(data)
        cache[data] = built

        return built
    }
}

/// Enough of the SVG path grammar for the registry: the commands Lucide's
/// exports actually use, and the elliptical arc, which most of them do.
enum BmCallsSVGPath {
    static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()

        for piece in data.components(separatedBy: "|") {
            append(piece, to: path)
        }

        return path
    }

    private static func append(_ data: String, to path: CGMutablePath) {
        var scanner = Scanner(data)
        var current = CGPoint.zero
        var start = CGPoint.zero
        var previous: Character = " "
        var lastControl: CGPoint?

        while true {
            guard let command = scanner.command(after: previous) else { break }

            let relative = command.isLowercase
            let kind = Character(command.lowercased())

            switch kind {
            case "m":
                guard let x = scanner.number(), let y = scanner.number() else { return }

                current = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                start = current
                lastControl = nil

                path.move(to: current)

                // A moveto followed by more pairs is a polyline, per the spec.
                while scanner.hasNumber {
                    guard let nx = scanner.number(), let ny = scanner.number() else { return }

                    current = relative ? CGPoint(x: current.x + nx, y: current.y + ny) : CGPoint(x: nx, y: ny)

                    path.addLine(to: current)
                }

            case "l":
                while scanner.hasNumber {
                    guard let x = scanner.number(), let y = scanner.number() else { return }

                    current = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                    lastControl = nil

                    path.addLine(to: current)
                }

            case "h":
                while scanner.hasNumber {
                    guard let x = scanner.number() else { return }

                    current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                    lastControl = nil

                    path.addLine(to: current)
                }

            case "v":
                while scanner.hasNumber {
                    guard let y = scanner.number() else { return }

                    current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                    lastControl = nil

                    path.addLine(to: current)
                }

            case "c":
                while scanner.hasNumber {
                    guard let x1 = scanner.number(), let y1 = scanner.number(),
                          let x2 = scanner.number(), let y2 = scanner.number(),
                          let x = scanner.number(), let y = scanner.number() else { return }

                    let c1 = relative ? CGPoint(x: current.x + x1, y: current.y + y1) : CGPoint(x: x1, y: y1)
                    let c2 = relative ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
                    let end = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)

                    path.addCurve(to: end, control1: c1, control2: c2)

                    lastControl = c2
                    current = end
                }

            case "s":
                while scanner.hasNumber {
                    guard let x2 = scanner.number(), let y2 = scanner.number(),
                          let x = scanner.number(), let y = scanner.number() else { return }

                    let mirrored = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                    let c2 = relative ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
                    let end = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)

                    path.addCurve(to: end, control1: mirrored, control2: c2)

                    lastControl = c2
                    current = end
                }

            case "q":
                while scanner.hasNumber {
                    guard let x1 = scanner.number(), let y1 = scanner.number(),
                          let x = scanner.number(), let y = scanner.number() else { return }

                    let c = relative ? CGPoint(x: current.x + x1, y: current.y + y1) : CGPoint(x: x1, y: y1)
                    let end = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)

                    path.addQuadCurve(to: end, control: c)

                    lastControl = c
                    current = end
                }

            case "t":
                while scanner.hasNumber {
                    guard let x = scanner.number(), let y = scanner.number() else { return }

                    let c = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                    let end = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)

                    path.addQuadCurve(to: end, control: c)

                    lastControl = c
                    current = end
                }

            case "a":
                while scanner.hasNumber {
                    guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                          let large = scanner.flag(), let sweep = scanner.flag(),
                          let x = scanner.number(), let y = scanner.number() else { return }

                    let end = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)

                    arc(path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)

                    lastControl = nil
                    current = end
                }

            case "z":
                path.closeSubpath()
                current = start
                lastControl = nil

            default:
                return
            }

            previous = command
        }
    }

    /// The endpoint parameterisation SVG uses, turned into the centre one and
    /// then into cubics — CoreGraphics has no elliptical arc of its own.
    private static func arc(
        _ path: CGMutablePath,
        from current: CGPoint,
        to end: CGPoint,
        rx radiusX: CGFloat,
        ry radiusY: CGFloat,
        rotation: CGFloat,
        large: Bool,
        sweep: Bool
    ) {
        if current == end { return }

        var rx = abs(radiusX)
        var ry = abs(radiusY)

        guard rx > 0, ry > 0 else {
            path.addLine(to: end)
            return
        }

        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        let dx = (current.x - end.x) / 2
        let dy = (current.y - end.y) / 2

        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        // A radius too small for the two points is scaled up until it fits,
        // which is what the spec asks for rather than an error.
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)

        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }

        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let numerator = max(rx * rx * ry * ry - denominator, 0)
        let factor = (large == sweep ? -1 : 1) * sqrt(numerator / max(denominator, .leastNonzeroMagnitude))

        let cx1 = factor * rx * y1 / ry
        let cy1 = -factor * ry * x1 / rx

        let cx = cosPhi * cx1 - sinPhi * cy1 + (current.x + end.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (current.y + end.y) / 2

        let theta = atan2((y1 - cy1) / ry, (x1 - cx1) / rx)
        var sweepAngle = atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx) - theta

        if !sweep && sweepAngle > 0 { sweepAngle -= 2 * .pi }
        if sweep && sweepAngle < 0 { sweepAngle += 2 * .pi }

        let segments = max(Int(ceil(abs(sweepAngle) / (.pi / 2))), 1)
        let step = sweepAngle / CGFloat(segments)
        let handle = 4.0 / 3.0 * tan(step / 4)

        var angle = theta

        for _ in 0..<segments {
            let next = angle + step

            let from = ellipse(cx, cy, rx, ry, cosPhi, sinPhi, angle)
            let to = ellipse(cx, cy, rx, ry, cosPhi, sinPhi, next)
            let fromSlope = slope(rx, ry, cosPhi, sinPhi, angle)
            let toSlope = slope(rx, ry, cosPhi, sinPhi, next)

            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x + handle * fromSlope.x, y: from.y + handle * fromSlope.y),
                control2: CGPoint(x: to.x - handle * toSlope.x, y: to.y - handle * toSlope.y)
            )

            angle = next
        }
    }

    private static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ cosPhi: CGFloat, _ sinPhi: CGFloat, _ angle: CGFloat) -> CGPoint {
        let x = rx * cos(angle)
        let y = ry * sin(angle)

        return CGPoint(x: cosPhi * x - sinPhi * y + cx, y: sinPhi * x + cosPhi * y + cy)
    }

    private static func slope(_ rx: CGFloat, _ ry: CGFloat, _ cosPhi: CGFloat, _ sinPhi: CGFloat, _ angle: CGFloat) -> CGPoint {
        let x = -rx * sin(angle)
        let y = ry * cos(angle)

        return CGPoint(x: cosPhi * x - sinPhi * y, y: sinPhi * x + cosPhi * y)
    }

    /// SVG path data is written without separators wherever it can get away
    /// with it — `a.5.5 0 0 0 .777-.416` is seven numbers — so this reads
    /// numbers rather than splitting on anything.
    private struct Scanner {
        private let characters: [Character]
        private var index = 0

        init(_ data: String) {
            characters = Array(data)
        }

        /// The next command letter, or a repeat of the last one where the data
        /// simply carries on with more arguments.
        mutating func command(after previous: Character) -> Character? {
            skip()

            guard index < characters.count else { return nil }

            let character = characters[index]

            if character.isLetter {
                index += 1
                return character
            }

            // A bare number here continues the previous command, except after
            // a moveto, which continues as a lineto.
            switch previous {
            case "M": return "L"
            case "m": return "l"
            case " ": return nil
            default: return previous
            }
        }

        var hasNumber: Bool {
            var probe = index

            while probe < characters.count, characters[probe] == " " || characters[probe] == "," || characters[probe] == "\n" || characters[probe] == "\t" {
                probe += 1
            }

            guard probe < characters.count else { return false }

            let character = characters[probe]

            return character.isNumber || character == "-" || character == "+" || character == "."
        }

        /// An arc flag is exactly one digit, and it may be glued to whatever
        /// comes next — reading it as a number would swallow the coordinate
        /// after it.
        mutating func flag() -> Bool? {
            skip()

            guard index < characters.count, let digit = characters[index].wholeNumberValue, digit == 0 || digit == 1 else {
                return nil
            }

            index += 1

            return digit == 1
        }

        mutating func number() -> CGFloat? {
            skip()

            guard index < characters.count else { return nil }

            var text = ""

            if characters[index] == "-" || characters[index] == "+" {
                text.append(characters[index])
                index += 1
            }

            var seenPoint = false
            var seenExponent = false

            while index < characters.count {
                let character = characters[index]

                if character.isNumber {
                    text.append(character)
                    index += 1
                    continue
                }

                if character == ".", !seenPoint, !seenExponent {
                    seenPoint = true
                    text.append(character)
                    index += 1
                    continue
                }

                if character == "e" || character == "E", !seenExponent, !text.isEmpty {
                    seenExponent = true
                    text.append(character)
                    index += 1

                    if index < characters.count, characters[index] == "-" || characters[index] == "+" {
                        text.append(characters[index])
                        index += 1
                    }

                    continue
                }

                break
            }

            guard let value = Double(text) else { return nil }

            return CGFloat(value)
        }

        private mutating func skip() {
            while index < characters.count {
                let character = characters[index]

                guard character == " " || character == "," || character == "\n" || character == "\t" || character == "\r" else { break }

                index += 1
            }
        }
    }
}

/// One glyph, stroked, sized to its own bounds.
final class BmCallsIconView: UIView {
    private let shape = CAShapeLayer()
    private var data: String
    private var drawn = CGSize.zero

    var color: UIColor = .white {
        didSet { shape.strokeColor = color.cgColor }
    }

    init(_ data: String) {
        self.data = data

        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        backgroundColor = .clear

        shape.fillColor = nil
        shape.strokeColor = color.cgColor
        shape.lineCap = .round
        shape.lineJoin = .round

        layer.addSublayer(shape)
    }

    required init?(coder: NSCoder) { nil }

    func set(_ data: String) {
        guard data != self.data else { return }

        self.data = data
        drawn = .zero

        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard bounds.width > 0, bounds.height > 0 else { return }

        if drawn == bounds.size, shape.path != nil { return }

        drawn = bounds.size

        let side = min(bounds.width, bounds.height)
        let scale = side / 24

        var transform = CGAffineTransform(translationX: (bounds.width - side) / 2, y: (bounds.height - side) / 2)
            .scaledBy(x: scale, y: scale)

        // Cheaper than a layer transform and it keeps the stroke honest: a
        // scaled layer scales its line width with everything else.
        shape.frame = bounds
        shape.path = BmCallsIcons.path(data).copy(using: &transform)
        shape.lineWidth = 1.85 * scale

        // No implicit animation when a call redraws its dock.
        shape.actions = [ "path": NSNull(), "strokeColor": NSNull() ]
    }
}
