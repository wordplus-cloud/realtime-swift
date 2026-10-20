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
 A live stream the app's server lets this user into, as its `streams()` rule says: `rt.calls.stream("show:42")`. Its
 state, the audience's count, the chat and the stage change as the stream goes, on the main queue (`onChange`); the
 picture shows in a `LiveStreamVideoView`. A host goes live with the camera and microphone (`goLive()`), and ends it.
 What a role may not do throws its code (`not_host`, `read_only`, `slow` …).
 */
@MainActor
public final class LiveStream {
    public let name: String
    public private(set) var role: LiveStreamRole = .viewer
    public private(set) var state: LiveStreamState = .idle
    /// This app's place in the stream's room: `live` once the picture can come.
    public private(set) var media: LiveStreamMedia = .off
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
    public private(set) var onStage = false
    /// What this app sends, a host's or a guest's: its camera and its microphone.
    public private(set) var camera = false
    public private(set) var microphone = false
    /// Why this app is out of the stream: `left`, `banned`, `kicked`, or what it couldn't go on with. Nil while in it.
    public private(set) var endReason: String?

    private unowned let owner: RealtimeCalls
    private var seats: JSONValue = .null
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
    #if canImport(UIKit)
    private let views = NSHashTable<LiveStreamVideoView>.weakObjects()
    #endif

    /// A new stream's seats are renewed past this age before its room is joined: the media's token lasts six hours.
    static let seatsFresh: TimeInterval = 5 * 3600
    /// Viewers spread their arrival over this when a stream goes live, so a big audience doesn't come at once.
    static let liveJitter: TimeInterval = 2
    static let historyKept = 200

    init(owner: RealtimeCalls, name: String) {
        self.owner = owner
        self.name = name
    }

    // MARK: - Hearing it

    /// Any change: the state, the count, the chat, the stage. On the main queue.
    public func onChange(_ handler: @escaping () -> Void) { changeHandlers.append(handler) }

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
        let reply = try await ask("stage", [:])
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

    /// Off stage, by choice or by the host: back to watching.
    public func leaveStage() {
        guard onStage else { return }
        onStage = false
        stopMedia()
        if state == .live { watch(after: 0) }
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
    /// Out of the stream now; they may come back.
    public func kick(_ user: String) async throws { _ = try await ask("kick", ["identity": .string("u:" + user)]) }
    /// Out of the stream, and kept out.
    public func ban(_ user: String) async throws { _ = try await ask("ban", ["identity": .string("u:" + user)]) }

    public func setCamera(_ on: Bool) async throws {
        guard sends else { throw CallError("not_host") }
        if on {
            if let track = localVideo {
                if published.contains(ObjectIdentifier(track)) { try await track.unmute() } else { try await track.start() }
            } else {
                let track = LocalVideoTrack.createCameraTrack()
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
                localAudio = LocalAudioTrack.createTrack()
                if state == .live, let room { try await publish(room) }
            }
        } else if let track = localAudio, published.contains(ObjectIdentifier(track)) {
            try await track.mute()
        }
        microphone = on && localAudio != nil
        changed()
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
        if role == .viewer && state == .live { watch(after: 0) }
    }

    private func requestSeats(retried: Bool = false) async throws {
        let grant = try await owner.authorize(["stream": name])
        guard let token = grant["token"] as? String else { throw CallError("auth_failed") }

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
            leaveStage()
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
        chatRight = you["chat"]?.string ?? chatRight
        isModerator = role == .host || you["mod"]?.bool == true
    }

    private func applyStream(_ stream: JSONValue) {
        guard let next = stream["state"]?.string.flatMap(LiveStreamState.init(rawValue:)) else { return }
        let was = state
        state = next
        startedAt = stream["started_at"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) }

        if next == .live && was != .live && role == .viewer && room == nil {
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
        guard let chat else { throw CallError("not_connected") }
        guard let reply = await chat.emit(event, .object(payload)) else { throw CallError("timeout") }
        guard reply["ok"]?.bool == true else { throw CallError(reply["error"]?.string ?? "server") }
        return reply
    }

    // MARK: - The picture

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
            self.changed()
            if seat == nil, Date().timeIntervalSince(self.joinedAt) > Self.seatsFresh { try? await self.requestSeats() }
            guard let url = seat?.url ?? self.seats["media"]?["url"]?.string,
                  let token = seat?.token ?? self.seats["media"]?["token"]?.string else {
                self.media = .off
                return nil
            }

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
                onMeshWait: nil,
                meshHardwareEncoders: CallCodecs.hardwareEncoders(caps)
            )
            do {
                try await room.connect(url: url, token: token, connectOptions: connectOptions, roomOptions: RoomOptions(adaptiveStream: true, dynacast: true))
            } catch {
                self.releaseAudio()
                // Still live: the room again in a while, as the web's player does.
                self.media = .reconnecting
                if self.endReason == nil, self.state == .live, self.role == .viewer { self.watch(after: 3) }
                self.changed()
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

    /// The room left, what this app sends kept: for another place in it (a viewer's for a guest's).
    private func leaveRoom() {
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
        if role == .viewer { watch(after: 2) }
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
        if sends, camera || microphone {
            next.append(LiveStreamTile(
                identity: "local", user: nil, name: "", avatar: nil, role: onStage ? .guest : role, local: true,
                camera: camera, screen: false, microphone: microphone, speaking: false, encoder: false
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
        if tile.local { return camera ? localVideo : nil }
        let participant = room?.remoteParticipants.values.first { $0.identity?.stringValue == tile.identity }
        let publications: [TrackPublication] = participant.map { Array($0.trackPublications.values) } ?? []
        let screen = publications.first { $0.source == .screenShareVideo && !$0.isMuted }?.track as? VideoTrack
        return screen ?? publications.first { $0.source == .camera && !$0.isMuted }?.track as? VideoTrack
    }

    #if canImport(UIKit)
    func show(in view: LiveStreamVideoView) {
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
}

extension RealtimeCalls {
    /**
     The live stream `name`, as the app's server's `streams()` rule lets this user in: a host, a guest or a viewer.
     A viewer of a live stream sees its picture at once in a `LiveStreamVideoView`. Throws its code: `forbidden` (the
     rule said no), `not_included` (the app's plan doesn't stream), `banned`, `no_hours` …
     */
    @MainActor
    public func stream(_ name: String) async throws -> LiveStream {
        let stream = LiveStream(owner: self, name: name)
        try await stream.join()
        return stream
    }
}
