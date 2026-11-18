import Foundation
import LiveKit
@_spi(WordPlusModules) import WordPlusRealtime

// A live stream: Easy Stream's protocol, as the web's engine speaks it, for an app's own code. The app's server signs
// the grant (`streams()`), the cloud's join answers with the stream, this user's place in it and two seats: the chat's
// socket (`/estream`, on a connection of its own here) and the media's room on the mesh. A viewer joins the room while
// the stream is live; a host previews, goes live, and ends it.

/// Where a live stream is: before its start, live, or over. A host may take an ended stream live again.
public enum LiveStreamState: String, Sendable {
    case idle
    case live
    case ended
}

/// This app's place in the stream's room, where its picture and sound come: not joined (the stream isn't live, or the
/// app only previews), joining, in it, or joining again after a drop.
public enum LiveStreamMedia: String, Sendable {
    case off
    case connecting
    case live
    case reconnecting
}

/// Who the app's grant made this user in a stream.
public enum LiveStreamRole: String, Sendable {
    case host
    case guest
    case viewer
}

/// The reactions players offer unless the site offers its own: a reaction is any one emoji, and these are theirs.
public enum LiveStreamReaction: String, CaseIterable, Sendable {
    case heart = "❤️"
    case clap = "👏"
    case laugh = "😂"
    case wow = "😮"
    case fire = "🔥"

    /// The emoji of a reaction as it arrives: itself, or for the name a player sent before emoji, the emoji of that name.
    public static func emoji(_ key: String) -> String {
        ["heart": "❤️", "clap": "👏", "laugh": "😂", "wow": "😮", "fire": "🔥"][key] ?? key
    }
}

/// A message in a stream's chat.
public struct LiveStreamMessage: Equatable, Sendable {
    public let id: String
    /// The app's user id of who wrote it, as the app's grants name users; nil for a visitor who isn't signed in.
    public let user: String?
    public let name: String
    public let avatar: String?
    public let role: LiveStreamRole
    public let text: String
    public let at: Date
}

/// Someone on the stage: the host, a guest, or OBS's picture (`encoder`).
public struct LiveStreamTile: Equatable, Sendable {
    /// Their place in the stream's room.
    public let identity: String
    /// The app's user id, for a signed-in person.
    public let user: String?
    public let name: String
    public let avatar: String?
    public let role: LiveStreamRole
    /// This app's own camera and microphone.
    public let local: Bool
    public let camera: Bool
    public let screen: Bool
    public let microphone: Bool
    public let speaking: Bool
    public let encoder: Bool
}

/// How the stage shows, as the host chose: everyone, the one speaking large, or one person alone (`identity`).
public struct LiveStreamLayout: Equatable, Sendable {
    public enum Mode: String, Sendable {
        case grid
        case speaker
        case spotlight
    }

    public let mode: Mode
    public let identity: String?
}

/// A hand raised to come on stage: who, by the app's user id, and since when.
public struct LiveStreamHand: Equatable, Sendable {
    public let user: String?
    public let name: String
    public let at: Date
}

/**
 A live stream the app's server lets this user into, by a token from its own route, `rt.joinStream(getToken:)`, or as its
 `streams()` rule says, `rt.calls.stream("show:42")`. Its state, the audience's count, the chat and the stage change as
 the stream goes, on the main queue (`onChange`), and the picture shows in a `LiveStreamVideoView`. A host goes live with
 the camera and microphone (`goLive()`), and ends it. What a role may not do throws its code (`not_host`, `read_only`,
 `slow` …).
 */
@MainActor
public final class LiveStream {
    public let name: String
    /// Whether this app takes the picture: false for one joined with `video: false`, until `watch()`.
    public private(set) var video: Bool
    public private(set) var role: LiveStreamRole = .viewer
    public private(set) var state: LiveStreamState = .idle
    /// This app's place in the stream's room: `live` once the picture can come.
    public internal(set) var media: LiveStreamMedia = .off {
        didSet { if media != .connecting { waiting = nil } }
    }
    /// While the join waits for a place: until when, and why (`busy`, `slot`, `unreachable`, or `full` while as many watch
    /// as the stream takes, `until` its next try then). `media` stays `connecting`, and the join goes on by itself. Nil at
    /// any other time.
    public private(set) var waiting: CallWait?
    /// How many may watch at once, as the cloud said at the join; nil where it set no limit.
    public internal(set) var audience: Int?
    public private(set) var startedAt: Date?
    /// How many watch, the stream's hosts and guests not counted, and the most at once since it went live.
    public private(set) var viewers = 0
    public private(set) var peak = 0
    /// The chat, oldest first, as far back as the cloud keeps it.
    public private(set) var messages: [LiveStreamMessage] = []
    /// The message pinned over the chat.
    public private(set) var pinned: LiveStreamMessage?
    /// Who is on the stage, the host first.
    public internal(set) var tiles: [LiveStreamTile] = []
    public private(set) var layout = LiveStreamLayout(mode: .grid, identity: nil)
    /// Whether the stream takes reactions now.
    public private(set) var reactionsOn = true
    /// Whether this user may write in the chat: their grant's right, while no moderator keeps them from it.
    public var canWrite: Bool { chatRight == "write" && (timeoutUntil.map { $0 <= Date() } ?? true) }
    /// Whether this user keeps the chat (a host, or a moderator by their grant).
    public private(set) var isModerator = false
    /// Until when a moderator keeps this user from writing.
    public private(set) var timeoutUntil: Date?
    /// Slow mode: one message per this many seconds, 0 for none.
    public private(set) var slow = 0
    /// The hands raised to come on stage, the oldest first: the host's and moderators' to see.
    public private(set) var hands: [LiveStreamHand] = []
    /// Whether this user's hand is up, and whether the host invited them on stage (`joinStage()` takes the place).
    public private(set) var handRaised = false
    public private(set) var invited = false
    /// Whether this user, a viewer, is on stage beside the host.
    public internal(set) var onStage = false
    /// Whether this user may ask to come on stage now: signed in, not the host, while it is live and takes guests.
    public var canAskStage: Bool { role != .host && (identity?.hasPrefix("u:") ?? false) && state == .live && stageOn }
    /// This user in the stream, and whether the stream takes guests (its setting, which may change as it goes).
    private var identity: String?
    private var stageOn = true
    /// What `ask` does in a test, which has no chat socket.
    var asking: ((String, [String: JSONValue]) async -> JSONValue?)?
    /// What this app sends, a host's or a guest's: its camera, its microphone and its screen.
    public private(set) var camera = false
    public private(set) var microphone = false
    public private(set) var sharingScreen = false
    /// Why this app is out of the stream: `left`, `banned`, `kicked`, or what it couldn't go on with. Nil while in it.
    public private(set) var endReason: String?
    /// The viewer's choice of picture (`setQuality`): `auto` by the size of the view showing it, the default.
    public private(set) var quality: LiveStreamQuality = .auto

    private unowned let owner: RealtimeCalls
    /// Where a grant comes from for a stream joined with a token of the app's server. Nil for one joined by its name,
    /// whose grant the calls route signs.
    private let grant: (@MainActor () async throws -> String)?
    var seats: JSONValue = .null
    private var joinedAt = Date()
    private var chatRight = "read"
    private var chat: NamespaceSocket?
    private var chatTries = 0
    private var room: LiveKit.Room?
    private var roomWatcher: LiveStreamRoomWatcher?
    private var connectingMedia: Task<LiveKit.Room?, Never>?
    private var localVideo: LocalVideoTrack?
    private var localAudio: LocalAudioTrack?
    private var published: Set<ObjectIdentifier> = []
    private var changeHandlers: [() -> Void] = []
    private var messageHandlers: [(LiveStreamMessage) -> Void] = []
    private var reactionHandlers: [([String: Int]) -> Void] = []
    private var endHandlers: [(String) -> Void] = []
    private var waitingHandlers: [(CallWait) -> Void] = []
    let playback = LiveStreamPlayback()
    private var reading: Task<Void, Never>?
    private var statisticsAsked: Set<ObjectIdentifier> = []
    #if canImport(UIKit)
    private let views = NSHashTable<LiveStreamVideoView>.weakObjects()
    #endif

    /// A new stream's seats are renewed past this age before its room is joined: the media's token lasts six hours.
    static let seatsFresh: TimeInterval = 5 * 3600
    /// Viewers spread their arrival over this when a stream goes live, so a big audience doesn't come at once.
    static let liveJitter: TimeInterval = 2
    static let historyKept = 200
    /// A viewer still joining this long in while the stream is full waits for a place, as the web's player has it, and one
    /// the room refused while it is full tries again this often: the media server doesn't say why it refuses one.
    static let fullAfter: TimeInterval = 4
    static let fullRetry: TimeInterval = 10

    init(owner: RealtimeCalls, name: String, video: Bool = true, grant: (@MainActor () async throws -> String)? = nil) {
        self.owner = owner
        self.name = name
        self.video = video
        self.grant = grant
    }

    // MARK: - Hearing it

    /// Any change: the state, the count, the chat, the stage. On the main queue.
    public func onChange(_ handler: @escaping () -> Void) { changeHandlers.append(handler) }

    /// The join waits for a place on the mesh: until when, and why. It goes on by itself.
    public func onWaiting(_ handler: @escaping (CallWait) -> Void) { waitingHandlers.append(handler) }

    /// Each new message in the chat.
    public func onMessage(_ handler: @escaping (LiveStreamMessage) -> Void) { messageHandlers.append(handler) }

    /// The reactions sent since the last ones, by emoji, about every half second while the stream takes them.
    public func onReactions(_ handler: @escaping ([String: Int]) -> Void) { reactionHandlers.append(handler) }

    /// This app is out of the stream: `left`, `banned`, `kicked`, or what it couldn't go on with.
    public func onEnded(_ handler: @escaping (String) -> Void) { endHandlers.append(handler) }

    // MARK: - Everyone's

    /// Writes in the chat. Throws the cloud's code: `read_only`, `slow`, `timeout`, `too_long`, `not_live` …
    public func send(_ text: String) async throws {
        _ = try await ask("chat", ["text": .string(text)])
    }

    /// A reaction everyone watching sees float up.
    public func react(_ kind: LiveStreamReaction) {
        react(kind.rawValue)
    }

    /// A reaction everyone watching sees float up: any one emoji the app offers.
    public func react(_ emoji: String) {
        chat?.send("react", .object(["kind": .string(emoji)]))
    }

    /// Leaves the stream: its picture, what this app sends, and its chat.
    public func leave() {
        finish("left")
    }

    // MARK: - On stage

    /// Asks to come on stage, or no longer: the host sees the hand. A signed-in viewer's.
    public func hand(_ up: Bool) async throws {
        _ = try await ask("hand", ["up": .bool(up)])
        handRaised = up
        changed()
    }

    /// Comes on stage when invited (`invited`), with the camera and microphone beside the host's.
    public func joinStage() async throws {
        let reply: JSONValue
        do {
            reply = try await ask("stage", [:])
        } catch {
            invited = false
            changed()
            throw error
        }
        invited = false
        handRaised = false
        guard let url = reply["media"]?["url"]?.string, let token = reply["media"]?["token"]?.string else {
            changed()
            throw CallError("server")
        }
        // The viewer's place in the room is left for the guest's.
        leaveRoom()
        onStage = true
        do {
            try await preview()
            guard let room = await mediaRoom(seat: (url, token)) else { throw CallError("publish_failed") }
            try await publish(room)
        } catch {
            leaveStage()
            throw error
        }
    }

    /// Says no to the invitation, for now: the host is told nothing, and may invite again.
    public func declineStage() {
        guard invited else { return }
        invited = false
        changed()
    }

    /// Off stage by choice, back to watching. The cloud takes this guest off everyone's stage first: left to itself, the
    /// guest's session stays a publisher in the room until the media server lets it go, and the viewer's join, the same
    /// person's, waits for it. A cloud that refuses leaves it at that.
    public func leaveStage() {
        guard onStage, let identity else { return backToWatching(watch: true) }
        backToWatching(watch: false)
        Task { @MainActor in
            _ = try? await ask("unstage", ["identity": .string(identity)])
            if video { watch(after: 0) }
        }
    }

    /// Off stage, once, whichever comes first: the word of the cloud, or this app.
    private func backToWatching(watch watching: Bool) {
        guard onStage else { return }
        onStage = false
        stopMedia()
        if watching && video && state == .live { watch(after: 0) }
    }

    // MARK: - A host's

    /// The camera and microphone, shown in a `LiveStreamVideoView` before going live. Asks for them as the system does.
    public func preview(camera: Bool = true, microphone: Bool = true) async throws {
        guard sends else { throw CallError("not_host") }
        if camera { try await setCamera(true) }
        if microphone { try await setMicrophone(true) }
    }

    /// Whether this app may send: a host, a guest, or a viewer on stage.
    private var sends: Bool { role != .viewer || onStage }

    /// Asks a signed-in viewer on stage, by the app's user id; `unstage` takes a guest off.
    public func invite(_ user: String) async throws {
        _ = try await ask("invite", ["identity": .string("u:" + user)])
    }

    public func unstage(_ user: String) async throws {
        _ = try await ask("unstage", ["identity": .string("u:" + user)])
    }

    /// What everyone sees on stage: everyone, the one speaking large, or one person (`user`) in the spotlight.
    public func layout(_ mode: LiveStreamLayout.Mode, user: String? = nil) async throws {
        var payload: [String: JSONValue] = ["mode": .string(mode.rawValue)]
        if let user { payload["identity"] = .string("u:" + user) }
        _ = try await ask("layout", payload)
    }

    /// Where OBS streams to, over WHIP, and its key; `renew` makes a new key, which cuts off an encoder using the old.
    public func ingest(renew: Bool = false) async throws -> (url: URL, key: String) {
        let reply = try await ask("ingest", renew ? ["renew": .bool(true)] : [:])
        guard let key = reply["key"]?.string, let path = reply["path"]?.string,
              let url = URL(string: owner.rt.serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw CallError("server")
        }
        return (url, key)
    }

    // MARK: - Keeping the chat (a host's, and a moderator's)

    public func deleteMessage(_ id: String) async throws { _ = try await ask("delete", ["id": .string(id)]) }
    public func pin(_ id: String) async throws { _ = try await ask("pin", ["id": .string(id)]) }
    public func unpin() async throws { _ = try await ask("unpin", [:]) }
    /// Keeps a user from writing for a minute to a day; they go on watching.
    public func timeout(_ user: String, seconds: Int) async throws {
        _ = try await ask("timeout", ["identity": .string("u:" + user), "seconds": .number(Double(seconds))])
    }
    /// One message per `seconds`, 0 to turn it off.
    public func setSlow(_ seconds: Int) async throws { _ = try await ask("slow", ["seconds": .number(Double(seconds))]) }
    public func clearChat() async throws { _ = try await ask("clear", [:]) }
    /// Out of the stream now; they may come back. The same word as on a room and a group call.
    public func remove(_ user: String) async throws { _ = try await ask("kick", ["identity": .string("u:" + user)]) }
    /// The same as `remove(_:)`.
    public func kick(_ user: String) async throws { try await remove(user) }
    /// Out of the stream, and kept out.
    public func ban(_ user: String) async throws { _ = try await ask("ban", ["identity": .string("u:" + user)]) }

    public func setCamera(_ on: Bool) async throws {
        guard sends else { throw CallError("not_host") }
        if on {
            if let track = localVideo {
                if published.contains(ObjectIdentifier(track)) { try await track.unmute() } else { try await track.start() }
            } else {
                // on the room client's RTC executor (async since LiveKit 2.18)
                let track = await LocalVideoTrack.createCameraTrack()
                try await track.start()
                localVideo = track
                if state == .live, let room { try await publish(room) }
            }
        } else if let track = localVideo {
            if published.contains(ObjectIdentifier(track)) { try await track.mute() } else { try await track.stop() }
        }
        camera = on && localVideo != nil
        changed()
    }

    public func setMicrophone(_ on: Bool) async throws {
        guard sends else { throw CallError("not_host") }
        if on {
            if let track = localAudio {
                if published.contains(ObjectIdentifier(track)) { try await track.unmute() }
            } else {
                localAudio = await LocalAudioTrack.createTrack()
                if state == .live, let room { try await publish(room) }
            }
        } else if let track = localAudio, published.contains(ObjectIdentifier(track)) {
            try await track.mute()
        }
        microphone = on && localAudio != nil
        changed()
    }

    /// Shares this phone's screen, or stops, for a host or a guest on stage. To share it needs the app's broadcast extension
    /// (`ScreenShare`), joins the room, and puts up the system's picker: true says it was asked, and `onChange` shows
    /// `sharingScreen` when the share begins. It shows as the stage's main picture once the stream is live.
    @discardableResult
    public func setScreenShare(_ on: Bool) async -> Bool {
        guard on else {
            _ = try? await room?.localParticipant.set(source: .screenShareVideo, enabled: false)
            stopBroadcast()
            return false
        }
        guard !sharingScreen else { return true }
        guard sends, ScreenShare.isAvailable, let room = await mediaRoom() else { return false }
        do {
            _ = try await room.localParticipant.set(source: .screenShareVideo, enabled: true)
            return true
        } catch {
            return false
        }
    }

    /// The room says the screen went out, or came down.
    func screenPublished(_ on: Bool) {
        guard sharingScreen != on else { return }
        sharingScreen = on
        refreshTiles()
    }

    /// A broadcast outlives the room that started it unless told.
    private func stopBroadcast() {
        #if os(iOS)
        if BroadcastManager.shared.isBroadcasting { BroadcastManager.shared.requestStop() }
        #endif
    }

    /// Starts the stream: what this app has on goes out (the camera and microphone when nothing is), then everyone
    /// watching sees it live.
    public func goLive() async throws {
        guard role == .host else { throw CallError("not_host") }
        if localVideo == nil && localAudio == nil { try await preview() }
        guard let room = await mediaRoom() else { throw CallError("publish_failed") }
        try await publish(room)
        let reply = try await ask("live", [:])
        if let stream = reply["stream"], stream != .null { applyStream(stream) }
    }

    /// Ends the stream for everyone: its room closes.
    public func end() async throws {
        let reply = try await ask("end", [:])
        if let stream = reply["stream"], stream != .null { applyStream(stream) }
        stopMedia()
    }

    // MARK: - Joining

    /// The grant from the app's server, then the cloud's join; the chat opens, and a viewer of a live stream joins its
    /// room.
    func join() async throws {
        try await requestSeats()
        openChat()
        if video && role == .viewer && state == .live { watch(after: 0) }
    }

    /// The next grant: from the token the app's server gave, or signed by its calls route.
    private func nextGrant() async throws -> String {
        if let grant { return try await grant() }
        let answer = try await owner.authorize(["stream": name])
        guard let token = answer["token"] as? String else { throw CallError("auth_failed") }
        return token
    }

    private func requestSeats(retried: Bool = false) async throws {
        let token = try await nextGrant()

        var request = URLRequest(url: owner.rt.serverURL.appendingPathComponent("easy-stream/v1/join"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONValue.object(["grant": .string(token)]).encoded()
        let reply: JSONValue
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            reply = String(data: data, encoding: .utf8).flatMap(JSONValue.parse) ?? .null
        } catch {
            throw CallError("server")
        }

        guard reply["ok"]?.bool == true else {
            let error = reply["error"]?.string ?? "server"
            // A grant signed afresh may pass where one that ran out on the way didn't.
            if error == "expired" && !retried { return try await requestSeats(retried: true) }
            throw CallError(error)
        }

        seats = reply
        joinedAt = Date()
        audience = reply["audience"]?.int
        applyYou(reply["you"] ?? .null)
        applyStream(reply["stream"] ?? .null)
    }

    // MARK: - The chat's socket

    private func openChat() {
        guard endReason == nil, let token = seats["chat"]?["token"]?.string else { return }
        chat?.close()

        let fallback = owner.rt.serverURL
        let named = seats["chat"]?["url"]?.string.flatMap(URL.init(string:))
        var origin = URLComponents(url: named ?? fallback, resolvingAgainstBaseURL: false)
        origin?.path = ""
        origin?.query = nil
        let base = origin?.url ?? fallback

        // No `rt`: this socket isn't handed on to a node, and one a draining node closes is opened again here.
        let socket = NamespaceSocket(
            base: base,
            path: seats["chat"]?["path"]?.string ?? "/websocket",
            namespace: seats["chat"]?["namespace"]?.string ?? "/estream",
            auth: .object(["t": .string(token)])
        ) { [weak self] event in
            Task { @MainActor [weak self] in self?.heard(event) }
        }
        chat = socket
        socket.open()
    }

    private func heard(_ event: NamespaceSocket.Event) {
        guard endReason == nil else { return }
        switch event {
        case .connected:
            chatTries = 0
        case let .refused(reason):
            if reason.contains("banned") {
                finish("banned")
            } else if reason.contains("bad_token") {
                // The seats ran out: new ones, then the chat again.
                Task { @MainActor in
                    do {
                        try await requestSeats()
                        openChat()
                    } catch {
                        finish((error as? CallError)?.code ?? "server")
                    }
                }
            } else {
                reopenChat()
            }
        case .closed:
            reopenChat()
        case let .event(name, data):
            apply(name, data)
        }
    }

    /// The chat again after a drop, sooner at first: a draining node closes it, and the server's address hands it on.
    private func reopenChat() {
        chatTries += 1
        let delay = min(15, pow(2, Double(min(chatTries, 4))) / 2)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.endReason == nil else { return }
            self.openChat()
        }
    }

    /// An event of the chat's socket.
    func apply(_ name: String, _ data: JSONValue) {
        switch name {
        case "hello":
            applyYou(data["you"] ?? .null)
            applyStream(data["stream"] ?? .null)
            viewers = data["viewers"]?.int ?? viewers
            peak = data["peak"]?.int ?? max(peak, viewers)
            slow = data["slow"]?.int ?? 0
            messages = (data["history"]?.array ?? []).compactMap { Self.message($0) }
            if let raised = data["hands"] { apply("hands", raised) }
            pinned = Self.message(data["pinned"])
            layout = Self.layout(data["layout"]) ?? LiveStreamLayout(mode: .grid, identity: nil)
            timeoutUntil = data["timeout"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) }
            reactionsOn = data["reactions"]?.bool ?? true
        case "state":
            applyStream(data)
        case "chat":
            guard let message = Self.message(data), !messages.contains(where: { $0.id == message.id }) else { return }
            messages.append(message)
            if messages.count > Self.historyKept { messages.removeFirst(messages.count - Self.historyKept) }
            messageHandlers.forEach { $0(message) }
        case "chat_deleted":
            let id = data["id"]?.string
            messages.removeAll { $0.id == id }
            if pinned?.id == id { pinned = nil }
        case "cleared":
            messages = []
            pinned = nil
        case "pinned":
            pinned = Self.message(data["message"])
        case "viewers":
            viewers = data["n"]?.int ?? viewers
            peak = data["peak"]?.int ?? max(peak, viewers)
        case "reactions":
            var counts: [String: Int] = [:]
            for (key, value) in data.object ?? [:] { if let n = value.int, n > 0 { counts[LiveStreamReaction.emoji(key), default: 0] += n } }
            if !counts.isEmpty { reactionHandlers.forEach { $0(counts) } }
            return
        case "reacting":
            reactionsOn = data["on"]?.bool ?? reactionsOn
        case "slow":
            slow = data["seconds"]?.int ?? 0
        case "layout":
            layout = Self.layout(data) ?? layout
        case "timeout":
            timeoutUntil = data["until"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) }
        case "muted":
            Task { @MainActor in try? await self.setMicrophone(false) }
        case "hands":
            hands = (data.array ?? []).map {
                LiveStreamHand(user: Self.userOf($0["identity"]?.string ?? ""), name: $0["name"]?.string ?? "",
                               at: Date(timeIntervalSince1970: ($0["at"]?.number ?? 0) / 1000))
            }
        case "invited":
            invited = true
            handRaised = false
        case "unstaged":
            backToWatching(watch: true)
        case "banned":
            finish("banned")
            return
        case "kicked":
            finish("kicked")
            return
        default:
            return
        }
        changed()
    }

    private func applyYou(_ you: JSONValue) {
        guard you != .null else { return }
        if let role = you["role"]?.string.flatMap(LiveStreamRole.init(rawValue:)) { self.role = role }
        identity = you["identity"]?.string ?? identity
        stageOn = you["stage"]?.bool != false
        chatRight = you["chat"]?.string ?? chatRight
        isModerator = role == .host || you["mod"]?.bool == true
    }

    private func applyStream(_ stream: JSONValue) {
        guard let next = stream["state"]?.string.flatMap(LiveStreamState.init(rawValue:)) else { return }
        let was = state
        state = next
        startedAt = stream["started_at"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) }

        if video && next == .live && was != .live && role == .viewer && room == nil {
            watch(after: was == .idle ? Double.random(in: 0...Self.liveJitter) : 0)
        }
        if next == .ended { stopMedia() }
        changed()
    }

    static func message(_ value: JSONValue?) -> LiveStreamMessage? {
        guard let value, let id = value["id"]?.string, let text = value["text"]?.string else { return nil }
        let from = value["from"]
        let identity = from?["id"]?.string ?? ""
        return LiveStreamMessage(
            id: id,
            user: userOf(identity),
            name: from?["name"]?.string ?? "",
            avatar: from?["avatar"]?.string,
            role: from?["role"]?.string.flatMap(LiveStreamRole.init(rawValue:)) ?? .viewer,
            text: text,
            at: Date(timeIntervalSince1970: (value["at"]?.number ?? 0) / 1000)
        )
    }

    static func layout(_ value: JSONValue?) -> LiveStreamLayout? {
        guard let mode = value?["mode"]?.string.flatMap(LiveStreamLayout.Mode.init(rawValue:)) else { return nil }
        return LiveStreamLayout(mode: mode, identity: value?["identity"]?.string)
    }

    /// The app's user id in the cloud's name for a person: `u:<id>`, or `u:<id>.<8 hex>` for a place in the room.
    static func userOf(_ identity: String) -> String? {
        guard identity.hasPrefix("u:") else { return nil }
        let rest = identity.dropFirst(2)
        if let dot = rest.lastIndex(of: "."), rest.distance(from: dot, to: rest.endIndex) == 9,
           rest[rest.index(after: dot)...].allSatisfy({ $0.isHexDigit }) {
            return String(rest[..<dot])
        }
        return String(rest)
    }

    private func ask(_ event: String, _ payload: [String: JSONValue]) async throws -> JSONValue {
        let answer: JSONValue?
        if let asking {
            answer = await asking(event, payload)
        } else {
            guard let chat else { throw CallError("not_connected") }
            answer = await chat.emit(event, .object(payload))
        }
        guard let reply = answer else { throw CallError("timeout") }
        guard reply["ok"]?.bool == true else { throw CallError(reply["error"]?.string ?? "server") }
        return reply
    }

    // MARK: - The picture

    /// The picture and sound of a stream joined with `video: false`: they come as they would have. A `LiveStreamVideoView`
    /// asks for them by itself.
    public func watch() {
        guard !video else { return }
        video = true
        if role == .viewer && state == .live && room == nil { watch(after: 0) }
    }

    private func watch(after delay: TimeInterval) {
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, self.endReason == nil, self.state == .live, self.room == nil else { return }
            _ = await self.mediaRoom()
        }
    }

    /// The stream's room, joined with this user's seat (renewed first when it is old), or a guest's (`seat`, from the
    /// stage's invitation).
    private func mediaRoom(seat: (url: String, token: String)? = nil) async -> LiveKit.Room? {
        if let room { return room }
        if let connectingMedia { return await connectingMedia.value }

        let task = Task { @MainActor [weak self] () -> LiveKit.Room? in
            guard let self else { return nil }
            if self.media != .reconnecting { self.media = .connecting }
            self.playback.joining()
            self.changed()
            if seat == nil, Date().timeIntervalSince(self.joinedAt) > Self.seatsFresh { try? await self.requestSeats() }
            guard let url = seat?.url ?? self.seats["media"]?["url"]?.string,
                  let token = seat?.token ?? self.seats["media"]?["token"]?.string else {
                self.media = .off
                return nil
            }

            let fullCheck = seat == nil && self.role == .viewer ? Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.fullAfter * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.waitIfFull()
            } : nil
            defer { fullCheck?.cancel() }

            let room = LiveKit.Room()
            let watcher = LiveStreamRoomWatcher(self)
            room.add(delegate: watcher)
            self.takeAudio(sending: seat != nil || self.role != .viewer)
            // The join names, as the browser's does, the codecs this device encodes and decodes in hardware (the room
            // client's own join budget, 30 s).
            let caps = CallMedia.shared.codecCaps
            let connectOptions = ConnectOptions(
                meshJoinBudget: 30,
                meshHardwareDecoders: CallCodecs.hardwareDecoders(caps),
                onMeshWait: { [weak self] wait in Task { @MainActor in self?.heardWait(CallWait(wait)) } },
                meshHardwareEncoders: CallCodecs.hardwareEncoders(caps)
            )
            do {
                try await room.connect(url: url, token: token, connectOptions: connectOptions, roomOptions: RoomOptions(adaptiveStream: true, dynacast: true))
            } catch {
                self.releaseAudio()
                self.joinFailed(asViewer: seat == nil && self.role == .viewer)
                return nil
            }
            guard self.endReason == nil else {
                self.releaseAudio()
                await room.disconnect()
                return nil
            }
            self.room = room
            self.roomWatcher = watcher
            self.media = .live
            self.playback.joined(server: LiveStreamStats.Server(url: url, node: room.serverNodeId, region: room.serverRegion, version: room.serverVersion))
            self.startReading()
            self.refreshTiles()
            return room
        }
        connectingMedia = task
        let room = await task.value
        connectingMedia = nil
        return room
    }

    private func publish(_ room: LiveKit.Room) async throws {
        if let track = localVideo, !published.contains(ObjectIdentifier(track)) {
            _ = try await room.localParticipant.publish(videoTrack: track, options: Self.cameraPublish(room))
            published.insert(ObjectIdentifier(track))
        }
        if let track = localAudio, !published.contains(ObjectIdentifier(track)) {
            _ = try await room.localParticipant.publish(audioTrack: track)
            published.insert(ObjectIdentifier(track))
        }
        refreshTiles()
    }

    /// The camera's codec and what goes behind it, as the browser's streams take them (cameraCodecFor(), backupFor()):
    /// the media server's policy, which comes with the join, else H.264 from hardware with VP8 behind it. H.265 only
    /// on the mesh.
    private static func cameraPublish(_ room: LiveKit.Room) -> VideoPublishOptions {
        let caps = CallMedia.shared.codecCaps
        let policy = room.meshCodecPolicy
        let codec = CallCodecs.roomPublishCodec(caps, encrypted: false, onMesh: CallCodecs.onMesh(room.url ?? ""), policy: policy?.camera)
        let backup = CallCodecs.roomBackupCodec(codec, encrypted: false, policy: policy?.backup)
        return VideoPublishOptions(preferredCodec: VideoCodec.from(name: codec) ?? .vp8, preferredBackupCodec: backup.flatMap { VideoCodec.from(name: $0) })
    }

    /// Whether as many watch as the stream takes.
    private var full: Bool { audience.map { viewers >= $0 } ?? false }

    /// A viewer's join that is taking a while, while the stream is full, is waiting for a place: the room refuses them
    /// until someone leaves, and the room client tries again meanwhile.
    func waitIfFull() {
        guard room == nil, media == .connecting, waiting == nil, full else { return }
        heardWait(CallWait(until: Date().addingTimeInterval(Self.fullRetry), reason: "full"))
    }

    /// The room could not be joined. Still live, a viewer tries again in a while, as the web's player does: every few
    /// seconds while the stream is full, as a place may come, and told so.
    func joinFailed(asViewer: Bool) {
        playback.failed(asViewer ? "media_unreachable" : "publish_failed")
        let live = video && endReason == nil && state == .live
        if asViewer, full {
            media = .connecting
            heardWait(CallWait(until: Date().addingTimeInterval(Self.fullRetry), reason: "full"))
            if live { watch(after: Self.fullRetry + Double.random(in: 0...Self.liveJitter)) }
            return
        }
        media = .reconnecting
        if live, asViewer { watch(after: 3) }
        changed()
    }

    /// A join waiting for a place on the mesh, as the room client tells it.
    func heardWait(_ wait: CallWait) {
        guard room == nil, media == .connecting || media == .reconnecting else { return }
        waiting = wait
        waitingHandlers.forEach { $0(wait) }
        changed()
    }

    /// The room left, what this app sends kept: for another place in it (a viewer's for a guest's).
    private func leaveRoom() {
        stopReading()
        let room = self.room
        self.room = nil
        roomWatcher = nil
        published = []
        media = .off
        releaseAudio()
        Task { await room?.disconnect() }
    }

    /// Where CallKit owns the audio session (SystemCalls), a stream, which is no call, takes it itself while its room
    /// is joined, and gives it back as it leaves (CallAudio).
    private var holdsAudio = false

    private func takeAudio(sending: Bool) {
        guard !holdsAudio else { return }
        holdsAudio = true
        CallAudio.streamStarted(sending: sending)
    }

    private func releaseAudio() {
        guard holdsAudio else { return }
        holdsAudio = false
        CallAudio.streamStopped()
    }

    /// The room left and what this app sent stopped: the stream ended, or this app left it.
    private func stopMedia() {
        stopReading()
        releaseAudio()
        let room = self.room
        let video = localVideo
        self.room = nil
        roomWatcher = nil
        localVideo = nil
        localAudio = nil
        published = []
        camera = false
        microphone = false
        if sharingScreen { stopBroadcast() }
        sharingScreen = false
        media = .off
        Task {
            try? await video?.stop()
            await room?.disconnect()
        }
        refreshTiles()
    }

    /// The room dropped this app: joined again while the stream is live, as the web's player does.
    func roomDropped(_ dropped: LiveKit.Room) {
        guard room === dropped else { return }
        stopReading()
        room = nil
        releaseAudio()
        roomWatcher = nil
        published = []
        // A guest whose place dropped watches again, as the web's player does.
        if onStage { return leaveStage() }
        guard endReason == nil, state == .live else {
            media = .off
            refreshTiles()
            return
        }
        media = .reconnecting
        refreshTiles()
        if video && role == .viewer { watch(after: 2) }
    }

    /// The stage again, from the room: whoever sends in it, the host first.
    func refreshTiles() {
        var next: [LiveStreamTile] = []
        if let room {
            let speaking = Set(room.activeSpeakers.compactMap { $0.identity?.stringValue })
            for participant in room.remoteParticipants.values {
                guard let identity = participant.identity?.stringValue else { continue }
                let meta = participant.metadata.flatMap(JSONValue.parse) ?? .null
                let encoder = identity == "ingest"
                let role = meta["role"]?.string.flatMap(LiveStreamRole.init(rawValue:)) ?? .viewer
                guard (role != .viewer || encoder), !participant.trackPublications.isEmpty else { continue }
                let tracks = participant.trackPublications.values
                next.append(LiveStreamTile(
                    identity: identity,
                    user: Self.userOf(identity),
                    name: participant.name ?? identity,
                    avatar: meta["avatar"]?.string.flatMap { $0.hasPrefix("https://") ? $0 : nil },
                    role: encoder ? .host : role,
                    local: false,
                    camera: tracks.contains { $0.source == .camera && !$0.isMuted },
                    screen: tracks.contains { $0.source == .screenShareVideo && !$0.isMuted },
                    microphone: tracks.contains { $0.source == .microphone && !$0.isMuted },
                    speaking: speaking.contains(identity),
                    encoder: encoder
                ))
            }
        }
        if sends, camera || microphone || sharingScreen {
            next.append(LiveStreamTile(
                identity: "local", user: nil, name: "", avatar: nil, role: onStage ? .guest : role, local: true,
                camera: camera, screen: sharingScreen, microphone: microphone, speaking: false, encoder: false
            ))
        }
        tiles = next.sorted { ($0.role == .host ? 0 : 1) < ($1.role == .host ? 0 : 1) }
        changed()
    }

    /// The stage's main picture, as the web's player picks it: the spotlight's, a shared screen, OBS's, the one
    /// speaking (for that layout), the host's, or anyone's.
    var mainTile: LiveStreamTile? {
        let pictured = tiles.filter { $0.camera || $0.screen }
        if layout.mode == .spotlight, let spot = layout.identity,
           let tile = pictured.first(where: { $0.identity == spot || $0.identity.hasPrefix(spot + ".") }) {
            return tile
        }
        return pictured.first { $0.screen }
            ?? pictured.first { $0.encoder }
            ?? (layout.mode == .speaker ? pictured.first { $0.speaking } : nil)
            ?? pictured.first { $0.role == .host }
            ?? pictured.first
    }

    /// A tile's picture: its shared screen, else its camera; this app's own camera for its own tile.
    func videoTrack(of tile: LiveStreamTile?) -> VideoTrack? {
        guard let tile else { return nil }
        if tile.local {
            let screen = sharingScreen ? room?.localParticipant.trackPublications.values.first { $0.source == .screenShareVideo }?.track as? VideoTrack : nil
            return screen ?? (camera ? localVideo : nil)
        }
        return picture(of: tile)?.track as? VideoTrack
    }

    private func publications(of tile: LiveStreamTile) -> [TrackPublication] {
        let participant = room?.remoteParticipants.values.first { $0.identity?.stringValue == tile.identity }
        return participant.map { Array($0.trackPublications.values) } ?? []
    }

    /// The publication of someone else's picture: their shared screen, else their camera.
    private func picture(of tile: LiveStreamTile) -> TrackPublication? {
        let publications = publications(of: tile)
        return publications.first { $0.source == .screenShareVideo && !$0.isMuted } ?? publications.first { $0.source == .camera && !$0.isMuted }
    }

    private func layers(of tile: LiveStreamTile?) -> [LiveStreamLayer] {
        guard let tile, !tile.local, let publication = picture(of: tile), let size = publication.dimensions else { return [] }
        return LiveStreamPicture.layers(width: Int(size.width), height: Int(size.height), simulcast: publication.isSimulcasted)
    }

    /// The layers of the main picture a viewer may choose, the best first, each with its size: what `setQuality` chooses
    /// from. None above 720p, which comes only on `auto`, to a view big enough for it. None before the picture arrives, and
    /// for a host's own. Their sizes are worked out from the picture's: the largest, then half and a quarter.
    public func qualities() -> [LiveStreamLayer] {
        LiveStreamPicture.choosable(layers(of: mainTile))
    }

    /// The picture's quality: one of the layers `qualities()` gives, whatever the size of the view, or `auto`, the default,
    /// by its size. A layer above 720p chosen still gives 720p.
    public func setQuality(_ quality: LiveStreamQuality) {
        guard quality != self.quality else { return }
        self.quality = quality
        playback.note("quality", quality.rawValue)
        changed()
    }

    /// How the stream plays here, to debug it: the picture and the sound that arrive, the media server and the way they
    /// come, and the session so far (how long the picture took to start, stalls, reconnects), with the last things that
    /// happened. Measured on this device once a second while the room is joined, and sent nowhere.
    public func stats() -> LiveStreamStats {
        playback.snapshot()
    }

    /// The layer a view showing this tile asks for: nil on `auto`.
    func chosenLayer(of tile: LiveStreamTile?) -> LiveStreamLayer? {
        LiveStreamPicture.chosen(quality, in: layers(of: tile))
    }

    private func startReading() {
        reading?.cancel()
        reading = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.readPlayback()
            }
        }
    }

    private func stopReading() {
        reading?.cancel()
        reading = nil
        statisticsAsked = []
        playback.left()
    }

    /// One reading a second of the main picture and its sound, whose counters the room client gathers once asked.
    private func readPlayback() async {
        guard room != nil else { return }
        let tile = mainTile
        let publication = tile.flatMap { $0.local ? nil : picture(of: $0) }
        let track = publication?.track
        let sound = tile.flatMap { $0.local ? nil : publications(of: $0).first { $0.source == .microphone && !$0.isMuted }?.track }
        for asked in [track, sound].compactMap({ $0 }) where statisticsAsked.insert(ObjectIdentifier(asked)).inserted {
            await asked.set(reportStatistics: true)
        }
        #if canImport(UIKit)
        let shown = !views.allObjects.isEmpty
        #else
        let shown = false
        #endif
        let videoStats = track?.statistics
        let audioStats = sound?.statistics
        playback.read(
            video: videoStats.flatMap(Self.rtp),
            audio: audioStats.flatMap(Self.rtp),
            layers: layers(of: tile),
            transport: (videoStats ?? audioStats).map(Self.transport),
            pictured: shown && track != nil
        )
    }

    private static func rtp(_ stats: TrackStatistics) -> LiveStreamRtp? {
        guard let inbound = stats.inboundRtpStream.first else { return nil }
        return LiveStreamRtp(
            bytes: inbound.bytesReceived ?? 0,
            frames: inbound.framesDecoded ?? 0,
            lost: inbound.packetsLost ?? 0,
            received: inbound.packetsReceived ?? 0,
            bufferDelay: inbound.jitterBufferDelay ?? 0,
            emitted: inbound.jitterBufferEmittedCount ?? 0,
            concealed: inbound.concealedSamples ?? 0,
            samples: inbound.totalSamplesReceived ?? 0,
            freezes: inbound.freezeCount ?? 0,
            frozen: inbound.totalFreezesDuration ?? 0,
            nacks: inbound.nackCount ?? 0,
            plis: inbound.pliCount ?? 0,
            dropped: inbound.framesDropped ?? 0,
            width: inbound.frameWidth ?? 0,
            height: inbound.frameHeight ?? 0,
            fps: inbound.framesPerSecond ?? 0,
            jitter: inbound.jitter ?? 0,
            codec: stats.codec.first { $0.id == inbound.codecId }?.mimeType,
            decoder: inbound.decoderImplementation,
            hardware: inbound.powerEfficientDecoder
        )
    }

    private static func transport(_ stats: TrackStatistics) -> LiveStreamStats.Transport {
        let selected = stats.transportStats?.selectedCandidatePairId
        let pair = stats.iceCandidatePair.first { $0.id == selected } ?? stats.iceCandidatePair.first { $0.nominated == true }
        let local = stats.localIceCandidate
        return LiveStreamStats.Transport(
            protocol: local?.protocol,
            relayed: local?.candidateType.map { $0 == .relay },
            relayProtocol: local?.relayProtocol?.rawValue,
            rttMs: pair?.currentRoundTripTime.map { $0 * 1000 }
        )
    }

    #if canImport(UIKit)
    func show(in view: LiveStreamVideoView) {
        watch()
        views.add(view)
        view.draw(self)
    }

    func hide(from view: LiveStreamVideoView) {
        views.remove(view)
    }
    #endif

    private func changed() {
        #if canImport(UIKit)
        for view in views.allObjects { view.draw(self) }
        #endif
        changeHandlers.forEach { $0() }
    }

    private func finish(_ reason: String) {
        guard endReason == nil else { return }
        endReason = reason
        chat?.close()
        chat = nil
        stopMedia()
        endHandlers.forEach { $0(reason) }
    }
}

/// The room's news for its stream, on the main queue.
final class LiveStreamRoomWatcher: NSObject, RoomDelegate, @unchecked Sendable {
    private weak var stream: LiveStream?

    @MainActor
    init(_ stream: LiveStream) {
        self.stream = stream
    }

    private func refresh() {
        Task { @MainActor [weak self] in self?.stream?.refreshTiles() }
    }

    func room(_ room: LiveKit.Room, participantDidConnect participant: RemoteParticipant) { refresh() }
    func room(_ room: LiveKit.Room, participantDidDisconnect participant: RemoteParticipant) { refresh() }
    func room(_ room: LiveKit.Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) { refresh() }
    func room(_ room: LiveKit.Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) { refresh() }
    func room(_ room: LiveKit.Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) { refresh() }
    func room(_ room: LiveKit.Room, participant: Participant, didUpdateMetadata metadata: String?) { refresh() }
    func room(_ room: LiveKit.Room, didUpdateSpeakingParticipants participants: [Participant]) { refresh() }

    func room(_ room: LiveKit.Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in self?.stream?.roomDropped(room) }
    }

    func room(_ room: LiveKit.Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        guard publication.source == .screenShareVideo else { return }
        Task { @MainActor [weak self] in self?.stream?.screenPublished(true) }
    }

    func room(_ room: LiveKit.Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        guard publication.source == .screenShareVideo else { return }
        Task { @MainActor [weak self] in self?.stream?.screenPublished(false) }
    }

    func roomIsReconnecting(_ room: LiveKit.Room) {
        Task { @MainActor [weak self] in self?.stream?.playback.reconnecting() }
    }

    func roomDidReconnect(_ room: LiveKit.Room) {
        Task { @MainActor [weak self] in self?.stream?.playback.reconnected() }
    }
}

extension RealtimeCalls {
    /**
     The live stream `name`, as the app's server's `streams()` rule lets this user in: a host, a guest or a viewer.
     A viewer of a live stream sees its picture at once in a `LiveStreamVideoView`. Throws its code: `forbidden` (the
     rule said no), `not_included` (the app's plan doesn't stream), `banned`, `no_hours` … `video: false` for an app
     that shows only the chat or the stream's details: the picture is fetched once something wants it (`watch()`, or a
     `LiveStreamVideoView`).
     */
    @MainActor
    public func stream(_ name: String, video: Bool = true) async throws -> LiveStream {
        let stream = LiveStream(owner: self, name: name, video: video)
        try await stream.join()
        return stream
    }

    /**
     Joins the live stream in a token from the app's own server (`streamToken( user, name, options )` there), which decided
     who this user is in it. A token lasts ten minutes, so `getToken` gets one from the app's route, and it is asked again as
     each runs out, when the route may say no. Throws its code: `bad_token` for what isn't a token, or what the app's
     function threw. `video: false` for an app that shows only the chat or the stream's details.
     */
    @MainActor
    public func joinStream(getToken: @escaping () async throws -> String, video: Bool = true) async throws -> LiveStream {
        try await intoStream(first: try await getToken(), again: getToken, video: video)
    }

    /// Joins the live stream in one token from the app's own server, for a screen that won't outlast it. Throws `expired`
    /// when it would need another, which also ends a stream it has joined, and `bad_token` for what isn't a token.
    @MainActor
    public func joinStream(_ token: String, video: Bool = true) async throws -> LiveStream {
        try await intoStream(first: token, again: nil, video: video)
    }

    /// The first token read for the stream it names and spent on the join, then a new one each time a grant runs out.
    @MainActor
    private func intoStream(first: String, again: (() async throws -> String)?, video: Bool) async throws -> LiveStream {
        guard let made = CallTokens.stream(first) else { throw CallError("bad_token") }
        var given: String? = made.token
        let stream = LiveStream(owner: self, name: made.name, video: video) {
            if let token = given {
                given = nil
                return token
            }
            guard let again else { throw CallError("expired") }
            guard let next = CallTokens.stream(try await again()) else { throw CallError("bad_token") }
            return next.token
        }
        try await stream.join()
        return stream
    }
}
