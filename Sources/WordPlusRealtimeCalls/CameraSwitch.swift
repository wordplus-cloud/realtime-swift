import Foundation

/**
 Someone's camera changing its codec in the middle of a room call, as the web's call screen does it: it says
 `{"state":"optimizing"}` on the data channel (`topic`), takes its camera down, puts it up again in the other codec and
 says `{"state":"ready"}`, which it also says when a failed attempt has given up and left the old camera up. Between the
 two the person has no camera, which drawn as it is would read as the camera turned off; a screen shows a placeholder
 ("Optimizing video quality...") instead.

 The mark (`optimizing`) holds until, as the web's call screen holds it (camera-moves.ts, `OptimizingHold`):
 - the first frame of a camera publication other than the one up when the word came (`from`), whose last frames still
   arriving must not end it;
 - after `ready`, the next frame of whatever camera is up, the old one included: a move that changed nothing ends at
   once;
 - the camera is turned off: muted, or taken out of the room other than by the move itself (the old one before `ready`);
 - `failsafe` from the move's first word, whatever was heard since: the media server's `tune.failsafeS`, held to
   `failsafeRange`, `failsafeDefault` where it gives none.

 A move is over at its `ready` or its failsafe: an `optimizing` said again before then starts nothing new, so a peer
 repeating itself can't keep the placeholder up. `GroupCall` keeps one per room and hears the frames itself, so a mark
 that has ended stays ended whatever a screen's renderer does next; the SDK's call screens draw the placeholder while
 it is up. `GroupPerson.optimizing` says it until a new camera of theirs arrives (`awaiting`). Better Messages' app runs
 the same machine (`BmCallsCameraSwitch`).
 */
@_spi(WordPlusUI) public struct CameraSwitch: Sendable {
    public static let topic = "wp-camera"

    /// The failsafe where the media server's codec policy gives none, and the range one it gives is held to: the web's
    /// (the realtime client's CAMERA_TUNE_RANGES.failsafeS, the mesh's CodecTuneRange).
    public static let failsafeDefault: TimeInterval = 10
    public static let failsafeRange: ClosedRange<TimeInterval> = 3 ... 30

    /// This room's: its node's `tune.failsafeS`, read as it joined.
    public var failsafe: TimeInterval = Self.failsafeDefault

    public struct Pending: Equatable, Sendable {
        /// The move's first word: its failsafe runs from it.
        public let since: Date
        /// The camera publication up when the word came, nil with none: its frames are not the new camera's.
        public let from: String?
        /// `ready` heard: the next frame of any camera ends the mark.
        public var ready: Bool
        /// The placeholder is up. Taken down before its `ready`, the move is kept until then, so no word of the same
        /// move puts it up again.
        public var up: Bool
    }

    public private(set) var pending: [String: Pending] = [:]

    public init() {}

    /// The failsafe for a node's `tune.failsafeS`, in seconds: held to `failsafeRange`, the default where it gives none.
    public static func failsafe(tune seconds: Double?) -> TimeInterval {
        guard let seconds, seconds.isFinite else { return failsafeDefault }
        return min(max(seconds, failsafeRange.lowerBound), failsafeRange.upperBound)
    }

    /// The number `name` in a node's codec policy's `tune` (`Room.meshCodecPolicy`), nil where it has none. Read by
    /// name: the WordPlus RTC client for Swift keeps `tune` from 1.0.7 on (Vendor/rtc-client-swift), and a client
    /// before it has none, so the same code reads nil there and the default stands, whichever client an app builds with.
    public static func tune(_ name: String, of policy: Any?) -> Double? {
        guard
            let policy,
            let tune = Mirror(reflecting: policy).children.first(where: { $0.label == "tune" })?.value
        else { return nil }
        return (tune as? [String: Double])?[name]
    }

    /// The word, as the sender wrote it, or nil for anything else.
    public static func state(of data: Data) -> String? {
        guard
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let state = parsed["state"] as? String,
            state == "optimizing" || state == "ready"
        else { return nil }

        return state
    }

    /// A word from `identity`, whose camera publication is `camera` now. Whether their mark came up or went down.
    public mutating func heard(_ state: String, from identity: String, camera: String?, at now: Date) -> Bool {
        let current = pending[identity]
        let live = current.map { now.timeIntervalSince($0.since) < failsafe } ?? false

        switch state {
        case "optimizing":
            // The same move said again: nothing new, its failsafe still running from its first word.
            if let current, live, !current.ready { return false }
            pending[identity] = Pending(since: now, from: camera, ready: false, up: true)
            return current?.up != true

        case "ready":
            guard var current else { return false }
            // Over already: its mark taken down by a frame, or its failsafe passed. The move ends here.
            guard live, current.up else {
                pending[identity] = nil
                return current.up
            }
            current.ready = true
            pending[identity] = current
            return false

        default:
            return false
        }
    }

    /// A frame of `identity`'s camera publication `camera` arrived. Whether it ended their mark (`watches`).
    public mutating func shown(_ identity: String, camera: String) -> Bool {
        guard watches(identity, camera: camera) else { return false }
        end(identity)
        return true
    }

    /// `identity`'s camera publication `camera` was taken out of the room. Whether that ended their mark: the old camera
    /// going is the move itself until `ready`; any other, or after it, is the camera turned off.
    public mutating func unpublished(_ identity: String, camera: String) -> Bool {
        guard let current = pending[identity], current.up, current.ready || camera != current.from else { return false }
        end(identity)
        return true
    }

    /// `identity` muted their camera, which no move does: turned off. Whether that ended their mark.
    public mutating func muted(_ identity: String) -> Bool {
        guard pending[identity]?.up == true else { return false }
        end(identity)
        return true
    }

    /// Marks past their failsafe, taken down, and their moves forgotten. Whose mark that took down.
    public mutating func expire(at now: Date) -> [String] {
        let over = pending.filter { now.timeIntervalSince($0.value.since) >= failsafe }
        for identity in over.keys { pending[identity] = nil }
        return over.filter { $0.value.up }.map(\.key).sorted()
    }

    /// When the next mark up reaches its failsafe, nil with none up.
    public func nextExpiry() -> Date? {
        pending.values.filter(\.up).map(\.since).min()?.addingTimeInterval(failsafe)
    }

    /// Gone from the room: nothing to wait for.
    public mutating func left(_ identity: String) {
        pending[identity] = nil
    }

    /// Whether `identity`'s camera is held as changing now: a screen draws its placeholder.
    public func optimizing(_ identity: String) -> Bool {
        pending[identity]?.up == true
    }

    /// The camera publication that was up when the word came.
    public func from(_ identity: String) -> String? {
        pending[identity]?.from
    }

    /// Whether a frame of `identity`'s camera publication `camera` ends their mark: a camera other than the old one, or,
    /// once `ready` is heard, any.
    public func watches(_ identity: String, camera: String?) -> Bool {
        guard let camera, let current = pending[identity], current.up else { return false }
        return current.ready || camera != current.from
    }

    /// Whether anyone's mark is up: the room listens for frames only then.
    public var anyUp: Bool {
        pending.values.contains { $0.up }
    }

    /// What `GroupPerson.optimizing` says, with `camera` the camera publication of theirs that has arrived (nil with
    /// none): their mark is up and no camera other than the old one has come yet. A screen holds its placeholder on
    /// until the room ends the mark.
    public func awaiting(_ identity: String, camera: String?) -> Bool {
        Self.covers(optimizing: optimizing(identity), from: from(identity), camera: camera, rendering: camera != nil)
    }

    /// Whether a mark up still covers a camera: none, or the old one, whatever it draws, does not end it; another that
    /// draws does.
    public static func covers(optimizing: Bool, from: String?, camera: String?, rendering: Bool) -> Bool {
        guard optimizing else { return false }
        guard let camera, rendering else { return true }

        return camera == from
    }

    /// The mark down. The move stays until its `ready`, or goes now if that was heard.
    private mutating func end(_ identity: String) {
        guard var current = pending[identity] else { return }
        guard !current.ready else {
            pending[identity] = nil
            return
        }
        current.up = false
        pending[identity] = current
    }
}
