import Foundation
@_spi(WordPlusModules) import WordPlusRealtime

// A group call's moderation as Better Messages runs it, for apps: what the call offers (`acts`), the room's rules and
// raised hands from the room's own state, a host's asks, a held microphone, and the tiles of people who dropped or whose
// media stalled. @wordplus/realtime-client's sdk-calls/group-call.ts, calls/away.ts and calls/stall-watch.ts, rule for
// rule (its launch/moderation, 75ffaff), so a phone and a browser in one call show the same thing.

/// What a group call offers, as the realtime server's place and the app's server package both name it (`GroupCall.acts`):
/// a screen shows a control only for an act named here. `hand` is raising hands, for everyone; the rest are a host's.
public enum CallAct: String, CaseIterable, Sendable {
    case remove
    case ban
    case listen
    case speak
    case mute
    case holdMic = "hold_mic"
    case releaseMic = "release_mic"
    case rules
    case hand
    case ask
    case end
    case spotlight

    /// What every server and package took before `acts` was named (1.1.0): a host's remove, listen, speak, mute and
    /// spotlight.
    public static let base: [CallAct] = [.remove, .listen, .speak, .mute, .spotlight]

    /// What a group call offers: the acts both the realtime server's place and the app's package name, in the protocol's
    /// order; `base` where either names none, as a 1.1.0-era server or package does, so nothing new is offered there.
    public static func offered(server: [String]?, app: [String]?) -> [CallAct] {
        guard let server, let app else { return base }
        return allCases.filter { server.contains($0.rawValue) && app.contains($0.rawValue) }
    }

    /// A list of acts as a reply or a token names them: nil where it names none.
    static func names(_ value: JSONValue?) -> [String]? {
        value?.array.map { $0.compactMap(\.string) }
    }
}

/// The room's rules, which hold until it empties: `broadcast` mode lets only those a host promotes send, `locked` keeps
/// out anyone who wasn't in the call (someone who was gets back in after a reload, unless removed), `muted` holds every
/// microphone off but a host's. The room's metadata, so an app that joins later has them, and every host's screen follows.
public struct RoomRules: Equatable, Sendable {
    public enum Mode: String, Sendable {
        case broadcast
        case participatory
    }

    public var mode: Mode
    public var locked: Bool
    public var muted: Bool

    public init(mode: Mode = .participatory, locked: Bool = false, muted: Bool = false) {
        self.mode = mode
        self.locked = locked
        self.muted = muted
    }

    /// A room's rules as its metadata says them: participatory, unlocked and unmuted where it says nothing.
    static func of(_ metadata: String?) -> RoomRules {
        let rules = GroupRoomState.parsed(metadata)?["rules"] as? [String: Any]
        func on(_ value: Any?) -> Bool {
            if let flag = value as? Bool { return flag }
            if let number = value as? NSNumber { return number.intValue == 1 }
            return (value as? String) == "1"
        }
        return RoomRules(mode: rules?["mode"] as? String == "broadcast" ? .broadcast : .participatory, locked: on(rules?["locked"]), muted: on(rules?["muted"]))
    }
}

/// What a host may ask someone to turn on.
public enum AskDevice: String, Sendable {
    case camera
    case microphone
}

/// What the person asked answers, as Better Messages' screen says it: turned on, not now, blocked, no such device, in use.
public enum AskAnswer: String, CaseIterable, Sendable {
    case on
    case notNow = "not_now"
    case blocked
    case noDevice = "no_device"
    case busy
}

/// A host asks this app's user to turn on a camera or microphone (`onAsk`): the ask's id, what, and which host by user id.
public struct TurnOnAsk: Equatable, Sendable {
    public let id: String
    public let devices: [AskDevice]
    public let by: String?

    public init(id: String, devices: [AskDevice], by: String?) {
        self.id = id
        self.devices = devices
        self.by = by
    }
}

/// Someone's answer to this app's ask (`onAskAnswer`), sent to this app alone: by their user id.
public struct TurnOnAnswer: Equatable, Sendable {
    public let id: String
    public let answer: AskAnswer
    public let from: String?
}

/// What of someone's stopped reaching the media server while they are still in the room, as the mesh says it: `video`
/// when only their camera stopped, `all` when their sound did too.
public enum GroupStalled: String, Sendable {
    case video
    case all
}

/// What the calls route answers a host's act: whether it changed anything, an ask's id, the rules now.
struct ModerationAnswer {
    let done: Bool
    let id: String?
    let rules: [String: Any]?
}

/// Whose hand a hand request is about: this user's own, someone's a host lowers, or everyone's.
enum HandOf {
    case own
    case one(String)
    case everyone
}

/// The room's own state as the realtime server keeps it in the room's metadata, beside the spotlight.
enum GroupRoomState {
    /// The topics over the room: the server's ask to one person, their answer to the host, a hang-up's bye.
    static let askTopic = "realtime-ask"
    static let askAnswerTopic = "realtime-ask-answer"
    static let byeTopic = "realtime-bye"

    static func parsed(_ metadata: String?) -> [String: Any]? {
        guard let data = metadata?.data(using: .utf8), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Whose hands are up, as the metadata says: the media server's identities, once each, in the order raised.
    static func hands(of metadata: String?) -> [String] {
        guard let list = parsed(metadata)?["hands"] as? [Any] else { return [] }
        var hands: [String] = []
        for case let identity as String in list where !identity.isEmpty && !hands.contains(identity) {
            hands.append(identity)
        }
        return hands
    }

    /// Whether permissions that let someone send leave their microphone out: an empty list is every source. `sources`
    /// are the media server's TrackSource numbers (microphone 2) or a token's names for them.
    static func holdsMic(publish: Bool, sources: [Any]) -> Bool {
        guard publish, !sources.isEmpty else { return false }
        return !sources.contains { source in
            if let number = source as? Int { return number == 2 }
            if let name = source as? String { return name.lowercased() == "microphone" }
            return false
        }
    }

    /// The realtime server's ask, from data that came with no participant (the server sent it); nil for anything else.
    static func ask(_ data: Data) -> TurnOnAsk? {
        guard
            let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let id = message["id"] as? String, !id.isEmpty
        else { return nil }
        var devices: [AskDevice] = []
        for case let name as String in message["devices"] as? [Any] ?? [] {
            if let device = AskDevice(rawValue: name), !devices.contains(device) { devices.append(device) }
        }
        guard !devices.isEmpty else { return nil }
        let by: String?
        switch message["by"] {
        case let text as String: by = text.hasPrefix("user_") ? GroupCall.users(of: [text]).first : text
        case let number as NSNumber: by = number.stringValue
        default: by = nil
        }
        return TurnOnAsk(id: id, devices: devices, by: by)
    }

    /// An answer to an ask, from the person asked; nil for anything else.
    static func answer(_ data: Data, from identity: String) -> TurnOnAnswer? {
        guard
            let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let id = message["id"] as? String, !id.isEmpty,
            let answer = (message["answer"] as? String).flatMap(AskAnswer.init(rawValue:))
        else { return nil }
        return TurnOnAnswer(id: id, answer: answer, from: GroupCall.users(of: [identity]).first)
    }
}

/**
 How long a group call keeps the tile of someone who left, marked as reconnecting, before it goes: Better Messages' call
 screen's `awayFor`, as @wordplus/realtime-client's calls/away.ts runs it. By the departure's reason, the media server's
 DisconnectReason: none, the room made it up; 1 (CLIENT_INITIATED) a hang-up on the mesh, gone at once, and off it
 maybe a full reconnect, so `leftOffMesh`; 2, 3, 8 and 9 (a reload, a node going, a move, a dropped signal) come back;
 any other (removed, the room closed, a timeout) is gone. A departure within `byeKeep` of their bye goes at once.
 */
enum CallAway {
    /// The wait for someone who may come back.
    static let wait: TimeInterval = 20
    /// The wait for a leave off the mesh, which may be a full reconnect.
    static let leftOffMesh: TimeInterval = 6
    /// How long a bye stands for the departure it announces.
    static let byeKeep: TimeInterval = 30

    /// How long a tile of someone who left stays: 0 for at once. `byeAt` is when their bye came, if it did.
    static func awayFor(_ reason: Int?, onMesh: Bool, byeAt: Date? = nil, now: Date = Date()) -> TimeInterval {
        if let byeAt, now.timeIntervalSince(byeAt) < byeKeep { return 0 }
        guard let reason, reason != 0 else { return wait }
        if reason == 1 { return onMesh ? 0 : leftOffMesh }
        if [2, 3, 8, 9].contains(reason) { return wait }
        return 0
    }
}

/**
 Whose media stopped reaching the media server while they are still in a room call, as WordPlus Mesh tells each viewer
 (Room.meshSourcesDry): @wordplus/realtime-client's calls/stall-watch.ts (Better Messages' own, moved there), rule for
 rule. Each sender's verdict, from their streams expected to arrive: `all` when their sound stopped too (or they send
 only sound), `video` when only their camera stopped. A microphone stopped under a camera that still comes is nothing.
 */
final class StallWatch {
    struct Stream {
        let who: String
        let camera: Bool
        let id: String
        let expected: Bool
    }

    private var verdicts: [String: GroupStalled] = [:]

    /// The room's streams and the track sids the media server says stopped reaching it: the senders whose verdict
    /// changed, with the new one (nil: none).
    func read(_ streams: [Stream], dry: Set<String>) -> [String: GroupStalled?] {
        var stopped: [String: (camera: Bool?, microphone: Bool?)] = [:]
        for stream in streams where stream.expected {
            var sender = stopped[stream.who] ?? (nil, nil)
            if stream.camera {
                sender.camera = (sender.camera ?? true) && dry.contains(stream.id)
            } else {
                sender.microphone = (sender.microphone ?? true) && dry.contains(stream.id)
            }
            stopped[stream.who] = sender
        }
        var next: [String: GroupStalled] = [:]
        for (who, sender) in stopped {
            if sender.microphone == true && sender.camera != false {
                next[who] = .all
            } else if sender.camera == true {
                next[who] = .video
            }
        }
        return replace(next)
    }

    func of(_ who: String) -> GroupStalled? { verdicts[who] }

    @discardableResult
    func clear() -> [String: GroupStalled?] { replace([:]) }

    private func replace(_ next: [String: GroupStalled]) -> [String: GroupStalled?] {
        var changed: [String: GroupStalled?] = [:]
        for (who, verdict) in verdicts where next[who] != verdict { changed[who] = .some(next[who]) }
        for (who, verdict) in next where verdicts[who] != verdict { changed[who] = .some(verdict) }
        verdicts = next
        return changed
    }
}
