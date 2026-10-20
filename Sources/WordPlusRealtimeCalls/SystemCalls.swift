import Foundation
import Security
@_spi(WordPlusModules) import WordPlusRealtime
#if os(iOS)
import UIKit
import CallKit
import PushKit
import Intents
import AVFoundation

/**
 Calls as iOS knows them: CallKit's ring on a locked phone and in a closed app, answering and hanging up from the
 system's screen, a watch, a car or headphones, calls that go on in the background, audio routes the system follows, a
 cellular call holding this one, and Recents. The Better Messages app's (`bm-calls`), whose calls these are.

     // application(_:didFinishLaunchingWithOptions:), before anything else: a push may have woken the app
     SystemCalls.start(.init(name: "Example Shop")) {
         await Session.shared.realtime()   // the signed-in user's connection, or nil
     }
     SystemCalls.onAnswered { answered in show(answered) }      // answered from the system's screen
     SystemCalls.onCallBack { back in … }                        // Recents or Siri: the app places the call

 - **A closed app rings:** the phone's push token goes with the user's line (`rt.calls`), and a call that rings them
   rings it through a VoIP push, which WordPlus Cloud sends with the app's own APNs key (the account's Apps page).
   The push is reported to CallKit before anything else, as iOS requires of every VoIP push. Then the app's closure
   gives a connection, the line is held on it, and the ring goes on as one that came over the line.
 - **An open app** rings on its own screen (`onIncoming`, or `CallScreen`), as the Better Messages app does, and the
   system's ring comes too once the push lands. Answered on either, it is answered once.
 - **Every call goes through CallKit,** placed or answered, a group call too: CallKit owns the audio session and hands
   it over (CallAudio). A live stream, which is no call, takes the session itself.
 - **The caller's name** comes from the ring's `info`, sealed by the app's server with the day's key: the day's keys
   are kept in the Keychain while this runs, so a push opens it offline. When it cannot, the app's name shows until
   the connection opens it.

 What the app adds: the Push Notifications capability and the `voip` and `audio` background modes, and
 `SystemCalls.handle(_:)` for the activity Recents hands it. CallKit cannot be used on a simulator or in mainland China:
 there the calls run with the app's own screen and no system ring, and a closed app does not ring.
 */
public final class SystemCalls: NSObject {
    /// How the system shows the app's calls.
    public struct Options {
        /// The app's name, shown for a caller whose name is not known yet (the system names the app itself by its
        /// display name).
        public var name: String
        /// A sound in the app's bundle to ring with (`ring.caf`), or nil for the system's.
        public var ringtone: String?
        /// A template image for the button that opens the app from the system's call screen: 40 points square, one
        /// colour on transparent.
        public var icon: UIImage?
        /// Whether calls go to Recents, where they may be called back.
        public var recents: Bool

        public init(name: String, ringtone: String? = nil, icon: UIImage? = nil, recents: Bool = true) {
            self.name = name
            self.ringtone = ringtone
            self.icon = icon
            self.recents = recents
        }
    }

    /// A call asked for from Recents or Siri, which names a person or a group call, not a call: the app places it.
    public struct CallBack {
        /// The person, by the user id the call was with, or nil for a group call.
        public let user: String?
        /// The group call, by its name, or nil for a person.
        public let group: String?
        public let type: CallType
    }

    static let shared = SystemCalls()

    /// Whether CallKit can be used here: not on a simulator, where it does nothing useful, and not in mainland China,
    /// where iOS does not offer it.
    public static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        guard let region = Locale.current.regionCode else { return false }
        return !(region.contains("CN") || region.contains("CHN"))
        #endif
    }

    /// Whether `start` was called: the app's calls go through the system.
    public static var isStarted: Bool { shared.options != nil }

    /// Starts CallKit and PushKit for the app's life. Call it at launch, in `application(_:didFinishLaunchingWithOptions:)`,
    /// since a push can wake the app with nothing else running. `connection` gives the signed-in user's connection for
    /// a call that woke the app, or nil when nobody is signed in: the call then rings no further.
    @MainActor
    public static func start(_ options: Options, connection: @escaping () async -> Realtime?) {
        shared.begin(options, connection: connection)
    }

    /// A call answered from the system's screen (the lock screen, a watch, a car), once it is on: the call between two,
    /// or the group call it rang into. A call answered from the app's own screen comes back from `accept()` alone.
    @MainActor
    public static func onAnswered(_ handler: @escaping (IncomingCall.Answered) -> Void) {
        shared.answeredHandlers.append(handler)
    }

    /// A call asked for from Recents or Siri: the app places it with `rt.calls.start` or `rt.calls.group`, naming it.
    @MainActor
    public static func onCallBack(_ handler: @escaping (CallBack) -> Void) {
        shared.callBackHandlers.append(handler)
        // One asked for before the app was ready, as tapping Recents launches it from cold.
        if let waiting = shared.waitingCallBack {
            shared.waitingCallBack = nil
            handler(waiting)
        }
    }

    /// The activity the system hands the app for a call tapped in Recents, or asked of Siri: from
    /// `application(_:continue:restorationHandler:)` or the scene's `scene(_:continue:)`. True when it was one.
    @MainActor
    @discardableResult
    public static func handle(_ activity: NSUserActivity) -> Bool {
        shared.handle(activity)
    }

    /// The name the system shows for a call placed from the app: the person called, or the group call's title. The call
    /// screen (WordPlusRealtimeUI) says it itself.
    @MainActor
    public static func setName(_ name: String, of call: Call) {
        shared.setName(name, id: call.id)
    }

    @MainActor
    public static func setName(_ name: String, of group: GroupCall) {
        guard let entry = shared.entries.values.first(where: { $0.group === group }) else { return }
        shared.setName(name, id: entry.id)
    }

    // MARK: - State, on the main queue

    private var options: Options?
    private var connection: (() async -> Realtime?)?
    private var provider: CXProvider?
    private let controller = CXCallController()
    private var registry: PKPushRegistry?
    private(set) var pushToken: String?
    private var answeredHandlers: [(IncomingCall.Answered) -> Void] = []
    private var callBackHandlers: [(CallBack) -> Void] = []
    private var waitingCallBack: CallBack?
    /// A call the system asked for and the app has not placed yet: the call that follows adopts it.
    private var requestedUUID: UUID?

    /// What the system knows of each call: by our id (a ring's, which the call answered from it keeps) and by CallKit's.
    private var entries: [String: Entry] = [:]
    private var byUUID: [UUID: Entry] = [:]
    /// Muted or unmuted because the system said so: what that changes is not told back to it.
    private var fromSystem = false

    final class Entry {
        let id: String
        let uuid: UUID
        var name: String
        var video: Bool
        let outgoing: Bool
        var incoming: IncomingCall?
        var call: Call?
        var group: GroupCall?
        /// The ring a push reported, before the line brings it, and when it came.
        var push: PushRing?
        var pushedAt = Date()
        /// What the system's screen asked for before the ring arrived on a line.
        var answerOnArrival = false
        var declineOnArrival = false
        var answering: Task<IncomingCall.Answered, Error>?
        /// Answered from the app's own screen, through the system's answer: the app has the call from `accept()`.
        var answeredInApp = false
        /// Hung up or left from this side, rather than by the other side or the network.
        var endedHere = false
        var reporting = false
        var endAfterReport: CXCallEndedReason??
        var heldMicrophone: Bool?
        var heldCamera: Bool?
        var connectedReported = false
        var ended = false

        init(id: String, uuid: UUID, name: String, video: Bool, outgoing: Bool) {
            self.id = id
            self.uuid = uuid
            self.name = name
            self.video = video
            self.outgoing = outgoing
        }
    }

    @MainActor
    private func begin(_ options: Options, connection: @escaping () async -> Realtime?) {
        guard self.options == nil else { return }
        self.options = options
        self.connection = connection

        if Self.isAvailable {
            // The system names the app by its own display name.
            let configuration = CXProviderConfiguration()
            configuration.supportsVideo = true
            configuration.maximumCallGroups = 1
            configuration.maximumCallsPerCallGroup = 1
            configuration.supportedHandleTypes = [.generic]
            configuration.includesCallsInRecents = options.recents
            if let icon = options.icon { configuration.iconTemplateImageData = icon.pngData() }
            // The system plays it while the call rings, and stops it when the call is answered or ends: nothing here
            // has to manage sound.
            if let ringtone = options.ringtone { configuration.ringtoneSound = ringtone }

            let provider = CXProvider(configuration: configuration)
            provider.setDelegate(self, queue: .main)
            self.provider = provider

            CallAudio.prepareForCallKit()

            // PushKit only where CallKit runs: every VoIP push must report a call, and iOS stops delivering them to an
            // app that does not.
            let registry = PKPushRegistry(queue: .main)
            registry.delegate = self
            registry.desiredPushTypes = [.voIP]
            self.registry = registry
        }

        CallLog.write("system calls started: callkit=\(Self.isAvailable)")

        #if DEBUG
        rehearse()
        #endif
    }

    // MARK: - The line

    /// What a line brings of this phone, so its user's calls ring it: nil until PushKit gave a token.
    func linePush() -> JSONValue? {
        guard let token = pushToken, let topic = Bundle.main.bundleIdentifier else { return nil }
        return .object([
            "device": .string(Self.device),
            "platform": .string("ios"),
            "token": .string(token),
            "env": .string(PushEnvironment.current),
            "topic": .string(topic),
        ])
    }

    /// What `unline` brings at sign-out: this phone rings for nobody any more.
    func unlinePush() -> JSONValue? {
        pushToken == nil ? nil : .object(["device": .string(Self.device)])
    }

    /// The line was held, with what still rings: a ring a push reported that is not among them is over, its push having
    /// come for a call answered, declined or given up on before the app could hold its line.
    func lineHeld(ringing: Set<String>, askedAt: Date, keyring: Keyring) {
        DispatchQueue.main.async {
            DayKeys.keep(keyring.entries("d:"))
            for entry in self.entries.values where entry.push != nil && entry.incoming == nil && !ringing.contains(entry.id) && entry.pushedAt < askedAt {
                CallLog.write("the ring \(entry.id) a push reported no longer rings")
                self.endReported(entry, reason: .remoteEnded)
            }
        }
    }

    /// The install's own id, made once: what the line names this phone by.
    static var device: String {
        let key = "cloud.wordplus.realtime.device"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let id = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    // MARK: - A ring

    /// A ring came over a line, on the main queue. With a push's report waiting for it, it is that call: what the
    /// system's screen asked for meanwhile is done now. A ring during a call is answered busy, as the system takes one
    /// call at a time: true then, and the app is not told of it.
    func ringArrived(_ incoming: IncomingCall) -> Bool {
        guard options != nil else { return false }
        let entry = entries[incoming.id]

        if busy, entry?.answering == nil {
            CallLog.write("incoming \(incoming.id) refused busy")
            Task { try? await incoming.decline(busy: true) }
            if let entry { endReported(entry, reason: .unanswered) }
            return true
        }

        guard let entry, entry.incoming == nil || entry.incoming === incoming else { return false }
        entry.incoming = incoming
        entry.push = nil
        if let name = incoming.info["name"]?.string, !name.isEmpty, name != entry.name { setName(name, id: entry.id) }
        if entry.declineOnArrival {
            Task { try? await incoming.decline() }
            return true
        }
        // Answered on the system's screen already: the app gets the call (`onAnswered`), not the ring.
        if entry.answerOnArrival {
            answerFromSystem(entry)
            return true
        }
        return false
    }

    /// A ring is over, for the reason the relay gave, on the main queue: the system's ends too, unless this side
    /// answered it.
    func ringOver(_ id: String, reason: String) {
        guard let entry = entries[id], entry.call == nil, entry.group == nil, entry.answering == nil else { return }
        endReported(entry, reason: Self.endReason(reason))
    }

    /// This side declined the ring: the system's ring ends as this side's own.
    func declined(_ id: String) {
        DispatchQueue.main.async {
            guard let entry = self.entries[id] else { return }
            self.endLocally(entry)
        }
    }

    /// Answering a ring from the app: through the system's own answer when it rings there too, so it rings nowhere
    /// after and the system's timer runs. Nil when the system has no call for it: the call then takes the session
    /// itself (CallAudio), as the system hands none to a call it did not answer.
    @MainActor
    func answer(_ incoming: IncomingCall) async throws -> IncomingCall.Answered? {
        guard options != nil else { return nil }
        guard let entry = entries[incoming.id], !entry.ended, provider != nil else {
            CallAudio.takeSessionWithoutCallKit()
            return nil
        }
        entry.incoming = incoming
        entry.answeredInApp = true
        if let answering = entry.answering { return try await answering.value }

        let refused: Bool = await withCheckedContinuation { continuation in
            controller.request(CXTransaction(action: CXAnswerCallAction(call: entry.uuid))) { error in
                if let error { CallLog.write("callkit refused the answer: \(error.localizedDescription)") }
                continuation.resume(returning: error != nil)
            }
        }
        if let answering = entry.answering { return try await answering.value }
        if refused {
            // The push's report was still on its way, or the system would not take the call for a reason of its own:
            // it hands no audio session to a call it did not answer. Answered as it was, the call was silent both ways
            // and the system's ring went on beside it. So the call takes a session of its own, and the system's call is
            // ended as answered here.
            CallAudio.takeSessionWithoutCallKit()
            endReported(entry, reason: .answeredElsewhere)
            return nil
        }
        // The action came back through the provider, which started the answer.
        guard let answering = entry.answering else { return nil }
        return try await answering.value
    }

    /// Answered from the system's screen: the ring's answer, and the app told once it is on.
    private func answerFromSystem(_ entry: Entry) {
        guard let incoming = entry.incoming else {
            entry.answerOnArrival = true
            return
        }
        guard entry.answering == nil else { return }
        CallAudio.configure(video: incoming.type == .video)
        let answering = Task { @MainActor in try await incoming.acceptNow() }
        entry.answering = answering
        Task { @MainActor in
            do {
                let answered = try await answering.value
                if !entry.answeredInApp { self.answeredHandlers.forEach { $0(answered) } }
            } catch {
                self.endReported(entry, reason: .failed)
            }
        }
    }

    // MARK: - Calls placed and answered

    /// A call the app placed: the system knows of it, which gives it the audio session, the routes and Recents. On the
    /// main queue, as the calls are placed.
    func outgoing(_ call: Call) {
        guard options != nil, call.state != .ended else { return }
        CallAudio.configure(video: call.type == .video)
        let entry = startOutgoing(id: call.id, handle: "wordplus:" + call.peer, name: call.peerInfo["name"]?.string ?? "", video: call.type == .video)
        entry?.call = call
        track(call)
    }

    /// A group call the app joined: a conversation rather than a person, with a handle of its own.
    func outgoing(_ group: GroupCall, type: CallType) {
        guard options != nil, group.state != .ended else { return }
        CallAudio.configure(video: type == .video)
        let id = "group-" + UUID().uuidString
        let entry = startOutgoing(id: id, handle: "wordplus-group:" + type.rawValue + ":" + group.name, name: "", video: type == .video)
        entry?.group = group
        track(group, id: id)
    }

    /// A ring answered: the call or group call it became goes on as the system's call. On the main queue.
    func answered(_ id: String, _ answered: IncomingCall.Answered) {
        guard let entry = entries[id] else { return }
        switch answered {
        case .call(let call):
            entry.call = call
            track(call)
        case .group(let group):
            entry.group = group
            track(group, id: id)
        }
    }

    /// Someone was added: the call goes on as a group call, the same call for the system. On the main queue.
    func moved(_ call: Call, to group: GroupCall) {
        guard let entry = entries[call.id] else { return }
        entry.call = nil
        entry.group = group
        track(group, id: entry.id)
    }

    /// This side hangs up or leaves: the system's call ends as this side's own, not as something done to it.
    func endingHere(call: Call? = nil, group: GroupCall? = nil) {
        entries.values.first { (call != nil && $0.call === call) || (group != nil && $0.group === group) }?.endedHere = true
    }

    /// This side's microphone, as the app set it: the system's screen shows the same. Not when the system set it, which
    /// is read here as it happens, inside the system's own action.
    func microphone(_ on: Bool, call: Call? = nil, group: GroupCall? = nil) {
        guard !fromSystem, let entry = entries.values.first(where: { (call != nil && $0.call === call) || (group != nil && $0.group === group) }) else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: entry.uuid, muted: !on))) { _ in }
    }

    /// Whether a call is on here, so a ring is answered busy.
    var busy: Bool {
        entries.values.contains { !$0.ended && ($0.call != nil || $0.group != nil || $0.answering != nil) }
    }

    private func track(_ call: Call) {
        call.onState { [weak self] state in
            guard let self, let entry = self.entries[call.id], entry.call === call, let provider = self.provider else { return }
            if entry.outgoing, state == .connecting { provider.reportOutgoingCall(with: entry.uuid, startedConnectingAt: Date()) }
            if state == .connected, !entry.connectedReported {
                entry.connectedReported = true
                if entry.outgoing { provider.reportOutgoingCall(with: entry.uuid, connectedAt: Date()) }
            }
        }
        call.onEnded { [weak self] reason in
            guard let self, reason != "group", let entry = self.entries[call.id], entry.call === call else { return }
            self.finished(entry, reason: reason)
        }
    }

    private func track(_ group: GroupCall, id: String) {
        group.onState { [weak self] state in
            guard let self, state == .connected, let entry = self.entries[id], entry.group === group, !entry.connectedReported else { return }
            entry.connectedReported = true
            if entry.outgoing { self.provider?.reportOutgoingCall(with: entry.uuid, connectedAt: Date()) }
        }
        group.onEnded { [weak self] reason in
            guard let self, let entry = self.entries[id], entry.group === group else { return }
            self.finished(entry, reason: reason)
        }
    }

    /// The call ended: by this side, which ends it through the system as its own, or by the other side or the network,
    /// which is reported as what happened to it.
    private func finished(_ entry: Entry, reason: String) {
        if entry.endedHere {
            endLocally(entry)
        } else {
            endReported(entry, reason: Self.endReason(reason))
        }
        CallAudio.giveSessionBackToCallKit()
    }

    // MARK: - Reporting

    @discardableResult
    private func startOutgoing(id: String, handle: String, name: String, video: Bool) -> Entry? {
        guard provider != nil else { return nil }
        // A call the system asked for from Recents or Siri already exists as far as CallKit is concerned: reporting a
        // second one would leave a ghost in the call list. This call adopts its UUID.
        let adopted = requestedUUID
        requestedUUID = nil
        let entry = Entry(id: id, uuid: adopted ?? UUID(), name: name, video: video, outgoing: true)
        remember(entry)

        if adopted != nil {
            let update = CXCallUpdate()
            update.localizedCallerName = name.isEmpty ? nil : name
            update.hasVideo = video
            provider?.reportCall(with: entry.uuid, updated: update)
            return entry
        }

        let action = CXStartCallAction(call: entry.uuid, handle: CXHandle(type: .generic, value: handle))
        action.isVideo = video
        action.contactIdentifier = name.isEmpty ? nil : name
        controller.request(CXTransaction(action: action)) { [weak self] error in
            if let error {
                CallLog.write("callkit refused the call: \(error.localizedDescription)")
                // Not the system's: it runs on a session of its own.
                CallAudio.takeSessionWithoutCallKit()
                self?.forget(entry)
                return
            }
            // `contactIdentifier` is for matching a contact, not for showing: the name in the status bar, the in-call
            // screen and Recents comes from `localizedCallerName` on a reported update, and without one the system
            // falls back to the handle.
            guard !entry.name.isEmpty else { return }
            let update = CXCallUpdate()
            update.localizedCallerName = entry.name
            update.hasVideo = video
            self?.provider?.reportCall(with: entry.uuid, updated: update)
        }
        Intents.donate(handle: handle, name: name, video: video, outgoing: true)
        return entry
    }

    /// Reports a ring to the system. It must happen inside the PushKit callback before anything async, or iOS
    /// terminates the app and eventually stops delivering VoIP pushes to it at all.
    private func reportIncoming(_ entry: Entry, handle: String, completion: @escaping (Error?) -> Void) {
        guard let provider else {
            completion(nil)
            return
        }
        remember(entry)

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.localizedCallerName = entry.name.isEmpty ? nil : entry.name
        update.hasVideo = entry.video
        update.supportsHolding = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        Intents.donate(handle: handle, name: entry.name, video: entry.video, outgoing: false)

        entry.reporting = true
        provider.reportNewIncomingCall(with: entry.uuid, update: update) { [weak self] error in
            entry.reporting = false
            CallLog.write("callkit reported call=\(entry.id) error=\(error.map { "\($0)" } ?? "none")")
            if error != nil {
                self?.forget(entry)
            } else if let pending = entry.endAfterReport {
                // An end asked for while the report was in flight: a call refused busy the moment its push arrived was
                // ended before CallKit had taken the report, the report then failed, and the system's own screen was
                // left over the live call.
                entry.endAfterReport = nil
                if let reason = pending { self?.endReported(entry, reason: reason) } else { self?.endLocally(entry) }
            }
            completion(error)
        }
    }

    /// The call ended, as something that happened to it: what the person sees in Recents afterwards.
    private func endReported(_ entry: Entry, reason: CXCallEndedReason) {
        guard !entry.ended else { return }
        if entry.reporting {
            entry.endAfterReport = .some(reason)
            return
        }
        entry.ended = true
        provider?.reportCall(with: entry.uuid, endedAt: Date(), reason: reason)
        forget(entry)
    }

    /// This side hung up or declined: through the call controller, as the system's own button does.
    private func endLocally(_ entry: Entry) {
        guard !entry.ended else { return }
        if entry.reporting {
            entry.endAfterReport = .some(nil)
            return
        }
        entry.ended = true
        controller.request(CXTransaction(action: CXEndCallAction(call: entry.uuid))) { [weak self] _ in self?.forget(entry) }
    }

    private func setName(_ name: String, id: String) {
        guard let entry = entries[id], !name.isEmpty else { return }
        entry.name = name
        let update = CXCallUpdate()
        update.localizedCallerName = name
        update.hasVideo = entry.video
        provider?.reportCall(with: entry.uuid, updated: update)
    }

    private func remember(_ entry: Entry) {
        entries[entry.id] = entry
        byUUID[entry.uuid] = entry
    }

    private func forget(_ entry: Entry) {
        entry.ended = true
        if entries[entry.id] === entry { entries[entry.id] = nil }
        byUUID[entry.uuid] = nil
    }

    /// Why a call or a ring ended, as the relay and the calls say it, in the terms Recents understands.
    static func endReason(_ reason: String) -> CXCallEndedReason {
        switch reason {
        case "answered_elsewhere": return .answeredElsewhere
        case "rejected", "declined", "declined_elsewhere", "busy": return .declinedElsewhere
        case "no_answer", "timeout", "unanswered": return .unanswered
        case "failed", "connection_failed", "room_failed", "room_lost", "group_failed", "not_started", "auth_failed", "forbidden": return .failed
        default: return .remoteEnded
        }
    }

    // MARK: - The push

    /// A VoIP push: a ring for this phone. Reported to the system before anything else, then its call is found on the
    /// user's line.
    func pushReceived(_ payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        guard let options else {
            completion()
            return
        }
        guard let ring = PushRing(payload) else {
            // A VoIP push must report a call even when it cannot be read: reported and ended at once.
            CallLog.write("a push carried no ring")
            let entry = Entry(id: "unread-" + UUID().uuidString, uuid: UUID(), name: options.name, video: false, outgoing: false)
            reportIncoming(entry, handle: "wordplus:unknown") { _ in completion() }
            endReported(entry, reason: .failed)
            return
        }

        CallLog.write("push call=\(ring.id) video=\(ring.video) until=\(Int(ring.until.timeIntervalSinceNow))s")

        // Twice for one ring (pushes sent again, or a push for a ring already reported): one ring.
        if let known = entries[ring.id], !known.ended {
            if provider == nil || known.call != nil || known.group != nil || known.answering != nil {
                // The push for a call already answered here on a ring that came over the line first. It must still
                // report a call, and reported as usual it rang beside the live one: reported and ended at once.
                let duplicate = Entry(id: ring.id + "-again", uuid: UUID(), name: known.name, video: ring.video, outgoing: false)
                reportIncoming(duplicate, handle: "wordplus:" + ring.from) { _ in completion() }
                endReported(duplicate, reason: .answeredElsewhere)
            } else {
                completion()
            }
            return
        }

        let name = Self.callerName(ring) ?? options.name
        let entry = Entry(id: ring.id, uuid: UUID(), name: name, video: ring.video, outgoing: false)
        entry.push = ring
        entry.pushedAt = Date()

        let late = ring.until.timeIntervalSinceNow <= 0
        let busy = self.busy

        if provider != nil {
            reportIncoming(entry, handle: "wordplus:" + ring.from) { _ in completion() }
        } else {
            // No CallKit (the rehearsal on a simulator): the line rings on the app's own screen.
            remember(entry)
            completion()
        }

        if late {
            endReported(entry, reason: .unanswered)
            return
        }
        if busy {
            // A ring during a call: the system's ring ended at once, and the ring answered busy as it reaches the line.
            CallLog.write("push call=\(ring.id) refused busy")
            endReported(entry, reason: .unanswered)
            return
        }

        // Unanswered at the ring's end: the system's ring stops then, as the caller's does.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, ring.until.timeIntervalSinceNow)) { [weak self] in
            guard let self, self.entries[entry.id] === entry, entry.call == nil, entry.group == nil, entry.answering == nil else { return }
            self.endReported(entry, reason: .unanswered)
        }

        ringOnLine(entry)
    }

    /// The ring on the user's line: the connection the app gives, its line held, and the ring it brings.
    private func ringOnLine(_ entry: Entry) {
        // Already ringing on a line of this process: that is the call.
        if let incoming = RealtimeCalls.ringing(entry.id) {
            _ = ringArrived(incoming)
            return
        }
        guard let connection else { return }
        Task { @MainActor in
            guard let rt = await connection() else {
                CallLog.write("push call=\(entry.id): no one signed in, the ring goes no further")
                self.endReported(entry, reason: .failed)
                return
            }
            // The calls of the connection: holding the line brings what rings (lineHeld, then the ring).
            let calls = rt.calls
            if rt.state != .connected { rt.connect() }
            calls.refreshLine()
        }
    }

    /// The caller's name from the ring's info, opened with the day's keys kept from the last line: nil when none opens.
    static func callerName(_ ring: PushRing, keys: [String] = DayKeys.load()) -> String? {
        guard let info = ring.info else { return nil }
        let keyring = Keyring()
        keyring.add(keys)
        return (keyring.openJSON(info) ?? info)["name"]?.string
    }

    // MARK: - Recents and Siri

    @MainActor
    private func handle(_ activity: NSUserActivity) -> Bool {
        guard let back = Intents.callBack(activity) else { return false }
        callBack(back)
        return true
    }

    private func callBack(_ back: CallBack) {
        CallLog.write("the system asked for a call back: group=\(back.group != nil) video=\(back.type == .video)")
        if callBackHandlers.isEmpty {
            waitingCallBack = back
        } else {
            callBackHandlers.forEach { $0(back) }
        }
    }

    // MARK: - The rehearsal

    #if DEBUG
    /// A push as a debug build's launch argument gives one (`-WordPlusSimulatedPush <base64 JSON of the push>`), into
    /// the same entry point, and the system's answer after `-WordPlusSimulatedAnswer <seconds>`: the woken path on a
    /// simulator, which has no PushKit or CallKit, as the Better Messages app rehearses it.
    private func rehearse() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "-WordPlusSimulatedPush"), at + 1 < arguments.count,
              let data = Data(base64Encoded: arguments[at + 1]),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any] else { return }
        let answerAfter = arguments.firstIndex(of: "-WordPlusSimulatedAnswer").flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil }

        DispatchQueue.main.async {
            CallLog.write("rehearsal: a simulated push")
            self.pushReceived(payload) {}
            guard let answerAfter, let id = PushRing(payload)?.id else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + answerAfter) {
                guard let entry = self.entries[id] else { return }
                CallLog.write("rehearsal: the system answers")
                self.answerFromSystem(entry)
            }
        }
    }
    #endif
}

// MARK: - CallKit

extension SystemCalls: CXProviderDelegate {
    /// The system dropped every call it knew about: a provider reset takes the calls with it, so nothing may be left
    /// running.
    public func providerDidReset(_ provider: CXProvider) {
        let all = Array(entries.values)
        entries.removeAll()
        byUUID.removeAll()
        for entry in all {
            entry.ended = true
            entry.call?.end()
            entry.group?.leave()
            if let incoming = entry.incoming, incoming.state == .ringing { Task { try? await incoming.decline() } }
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let entry = byUUID[action.callUUID] else {
            CallLog.write("callkit answered a call this process does not know")
            action.fail()
            return
        }
        CallLog.write("callkit answered call=\(entry.id)")
        answerFromSystem(entry)
        // Fulfilled now, not when the media connects: the call says when it connects, and a slow answer is a poor one.
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let entry = byUUID[action.callUUID] {
            CallLog.write("callkit ended call=\(entry.id)")
            forget(entry)
            if let call = entry.call {
                call.end()
            } else if let group = entry.group {
                group.leave()
            } else if let incoming = entry.incoming, incoming.state == .ringing {
                Task { try? await incoming.decline() }
            } else if entry.incoming == nil {
                // Declined on the system's screen before the ring reached a line: declined once it does.
                entry.declineOnArrival = true
                entries[entry.id] = entry
            }
            CallAudio.giveSessionBackToCallKit()
        }
        action.fulfill()
    }

    /// Muted from the system's screen or a headset: it does what the app's button does, the track stopped.
    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        if let entry = byUUID[action.callUUID] {
            fromSystem = true
            if let call = entry.call, call.microphone == action.isMuted { call.microphone = !action.isMuted }
            if let group = entry.group, group.microphone == action.isMuted { group.microphone = !action.isMuted }
            fromSystem = false
        }
        action.fulfill()
    }

    /// A cellular call arriving holds this one: the microphone and camera stop, and letting it go gives back what the
    /// person had on. Reading the hold off the mute state instead unmuted anyone who had muted themselves before.
    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        if let entry = byUUID[action.callUUID] {
            fromSystem = true
            let microphone = entry.call?.microphone ?? entry.group?.microphone ?? false
            let camera = entry.call?.camera ?? entry.group?.camera ?? false
            if action.isOnHold, entry.heldMicrophone == nil {
                entry.heldMicrophone = microphone
                entry.heldCamera = camera
                entry.call?.microphone = false
                entry.call?.camera = false
                entry.group?.microphone = false
                entry.group?.camera = false
                CallLog.write("the system put the call on hold")
            } else if !action.isOnHold, let wasMicrophone = entry.heldMicrophone {
                let hadCamera = entry.heldCamera ?? false
                entry.heldMicrophone = nil
                entry.heldCamera = nil
                entry.call?.microphone = wasMicrophone
                entry.call?.camera = hadCamera
                entry.group?.microphone = wasMicrophone
                entry.group?.camera = hadCamera
                CallLog.write("the system let the call go again")
            }
            fromSystem = false
        }
        action.fulfill()
    }

    /// A call asked for from Recents or Siri rather than placed from the app: all it gives is the handle, so the app
    /// is asked for the call, which adopts this UUID.
    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        if byUUID[action.callUUID] == nil, let back = Intents.callBack(handle: action.handle.value, video: action.isVideo) {
            requestedUUID = action.callUUID
            callBack(back)
        }
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        CallLog.write("callkit handed the audio session over")
        CallAudio.activated(audioSession)
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        CallLog.write("callkit took the audio session back")
        CallAudio.deactivated(audioSession)
    }
}

// MARK: - PushKit

extension SystemCalls: PKPushRegistryDelegate {
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        let token = credentials.token.map { String(format: "%02.2hhx", $0) }.joined()
        guard token != pushToken else { return }
        pushToken = token
        // Every line held now brings it again, so the user's calls ring this phone from now on.
        RealtimeCalls.refreshLines()
    }

    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        pushToken = nil
    }

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        pushReceived(payload.dictionaryPayload, completion: completion)
    }
}

#else

/// macOS has no CallKit: its calls run with the app's own screen, and what the calls tell the system goes nowhere.
final class SystemCalls {
    static let shared = SystemCalls()
    static var isStarted: Bool { false }
    var busy: Bool { false }
    func linePush() -> JSONValue? { nil }
    func unlinePush() -> JSONValue? { nil }
    func lineHeld(ringing: Set<String>, askedAt: Date, keyring: Keyring) {}
    func ringArrived(_ incoming: IncomingCall) -> Bool { false }
    func ringOver(_ id: String, reason: String) {}
    func declined(_ id: String) {}
    @MainActor func answer(_ incoming: IncomingCall) async throws -> IncomingCall.Answered? { nil }
    func outgoing(_ call: Call) {}
    func outgoing(_ group: GroupCall, type: CallType) {}
    func answered(_ id: String, _ answered: IncomingCall.Answered) {}
    func moved(_ call: Call, to group: GroupCall) {}
    func endingHere(call: Call? = nil, group: GroupCall? = nil) {}
    func microphone(_ on: Bool, call: Call? = nil, group: GroupCall? = nil) {}
}

#endif

// MARK: - What a push brings

/// A ring as its push carries it (better-messages-server's inc/calls/p2p/sdk-push.ts): `wp`, what the line's `incoming`
/// says, the caller's info still sealed by the app's server.
struct PushRing {
    let id: String
    let call: String
    let from: String
    let video: Bool
    let until: Date
    let info: JSONValue?
    let group: String?

    init?(_ payload: [AnyHashable: Any]) {
        guard let wp = payload["wp"] as? [String: Any], wp["op"] as? String == "incoming",
              let id = wp["id"] as? String, !id.isEmpty, let call = wp["call"] as? String else { return nil }
        self.id = id
        self.call = call
        from = wp["from"].map { "\($0)" } ?? ""
        video = (wp["type"] as? String) != "audio"
        // The relay's own ring limit: a push that asks for longer is held to a minute, a phone ringing for ten minutes
        // being the worse fault.
        let until = (wp["until"] as? NSNumber)?.doubleValue ?? (Date().timeIntervalSince1970 + 45) * 1000
        self.until = min(Date(timeIntervalSince1970: until / 1000), Date().addingTimeInterval(60))
        info = wp["info"].map { JSONValue.from(any: $0) }
        group = (wp["group"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Which APNs the pushes for this build belong to. It matters completely and fails silently: a token minted for the
/// sandbox is refused by the production gateway and the other way round, so a build that says the wrong one simply
/// never rings. The app's own `aps-environment` entitlement is the authority, and the only public way to read it is the
/// provisioning profile embedded in the bundle, a signed container with a plist inside. An App Store or TestFlight
/// build has no embedded profile at all, which is itself the answer: production.
enum PushEnvironment {
    static var current: String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>"),
              let plist = String(text[start.lowerBound..<end.upperBound]).data(using: .isoLatin1),
              let parsed = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Any],
              let entitlements = parsed["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String else { return "production" }
        return environment == "development" ? "development" : "production"
    }
}

/// The day's keys, kept in the Keychain on this device only, after its first unlock: what opens the caller's name in a
/// push before anything connects. The three newest days are kept.
enum DayKeys {
    private static let service = "cloud.wordplus.realtime.day-keys"

    static func keep(_ entries: [String]) {
        guard !entries.isEmpty else { return }
        let kept = Array(Set(load() + entries)).sorted().suffix(3)
        guard let data = try? JSONSerialization.data(withJSONObject: Array(kept)) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return entries
    }
}

#if os(iOS)
/// Calling back from Recents, Siri or the Phone app. Every call the app puts through CallKit lands in the system's call
/// history, and tapping one there hands the app an `INStartCallIntent` naming the person by the handle the call was
/// reported with: `wordplus:<user>`, or `wordplus-group:<type>:<name>` for a group call.
enum Intents {
    static func callBack(_ activity: NSUserActivity) -> SystemCalls.CallBack? {
        guard let intent = activity.interaction?.intent else { return nil }
        if let start = intent as? INStartCallIntent {
            return start.contacts?.first?.personHandle?.value.flatMap { callBack(handle: $0, video: start.callCapability == .videoCall) }
        }
        // And the two Apple deprecated, which the system still hands back: tapping a call in the history delivers
        // `INStartAudioCallIntent`, not `INStartCallIntent` (the Better Messages app, iOS 26.6.1). Read by name, so
        // the deprecated classes are not named here.
        let kind = String(describing: type(of: intent))
        guard kind == "INStartVideoCallIntent" || kind == "INStartAudioCallIntent",
              let contacts = intent.value(forKey: "contacts") as? [INPerson],
              let handle = contacts.first?.personHandle?.value else { return nil }
        return callBack(handle: handle, video: kind == "INStartVideoCallIntent")
    }

    /// A handle this app wrote, and nothing else: one it did not write is not a call it can place.
    static func callBack(handle: String, video: Bool) -> SystemCalls.CallBack? {
        if handle.hasPrefix("wordplus-group:") {
            let rest = handle.dropFirst("wordplus-group:".count)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            let type = CallType(rawValue: String(rest[..<colon])) ?? (video ? .video : .audio)
            let name = String(rest[rest.index(after: colon)...])
            return name.isEmpty ? nil : SystemCalls.CallBack(user: nil, group: name, type: type)
        }
        if handle.hasPrefix("wordplus:") {
            let user = String(handle.dropFirst("wordplus:".count))
            return user.isEmpty || user == "unknown" ? nil : SystemCalls.CallBack(user: user, group: nil, type: video ? .video : .audio)
        }
        return nil
    }

    /// Tells the system who a call was with, so its entry in the history can be tapped: reporting a call puts it in
    /// the list, the donation is what turns the row into an `INStartCallIntent` coming back.
    static func donate(handle: String, name: String, video: Bool, outgoing: Bool) {
        let person = INPerson(personHandle: INPersonHandle(value: handle, type: .unknown), nameComponents: nil,
                              displayName: name.isEmpty ? nil : name, image: nil, contactIdentifier: nil, customIdentifier: handle)
        let intent = INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown, destinationType: .normal,
                                       contacts: [person], callCapability: video ? .videoCall : .audioCall)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = outgoing ? .outgoing : .incoming
        interaction.donate { error in
            if let error { CallLog.write("the call could not be donated: \(error.localizedDescription)") }
        }
    }
}
#endif
