import Foundation
import SwiftUI
import WordPlusRealtime
import WordPlusRealtimeCalls
import WordPlusRealtimeUI

/// One of the shop people. The app lists them to sign in. Once signed in, the shop server says who they are.
struct Person: Identifiable, Hashable {
    let id: String
    let name: String
    let role: String
    let staff: Bool

    static let all = [
        Person(id: "34", name: "Ann", role: "Support", staff: true),
        Person(id: "42", name: "Ben", role: "Customer", staff: false),
        Person(id: "43", name: "Cara", role: "Warehouse", staff: true),
    ]

    static func named(_ id: String) -> Person? { all.first { $0.id == id } }
}

/// A message of the chat. `at` in milliseconds, what orders them.
struct Message: Identifiable, Equatable {
    let id: String
    let from: String
    let text: String
    let at: Double
}

struct Member: Identifiable, Equatable {
    let id: String
    let name: String
    let role: String
}

struct Notice: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// The API demo as the signed-in person sees it, on the same rooms as the shop web pages, so the app and a
/// browser signed in as someone else see each other: the order of Ben moving on (a room the shop server emits to, with a
/// notice to Ben alone), who is in the shop (a presence room) and who is online, and the chat of Ann and Ben (emitted from
/// the app with an ack, kept by the shop server, which the webhook brings them to. Typing as volatile events).
final class Shop: ObservableObject {
    static let steps = ["placed", "packed", "shipped", "delivered"]
    static let labels = ["placed": "Placed", "packed": "Packed", "shipped": "Shipped", "delivered": "Delivered"]

    /// The shop server: the Express example (examples/express in realtime-js, `npm start`), or WORDPLUS_SHOP. The
    /// simulator reaches the Mac at localhost, a phone at the Mac's name on the network (`http://<name>.local:3000`).
    /// Kept, as a call's push launches the app without the scheme's environment.
    let server: URL

    @Published private(set) var me: Person?
    @Published private(set) var signingIn: String?
    @Published private(set) var failure: String?
    @Published private(set) var connected = false
    @Published private(set) var orderId = 1042
    @Published private(set) var item = ""
    @Published private(set) var status = "placed"
    @Published private(set) var live = false
    @Published private(set) var members: [Member] = []
    @Published private(set) var inShop = true
    @Published private(set) var online: Set<String> = []
    @Published private(set) var inChat = false
    @Published private(set) var other: Person?
    @Published private(set) var otherName = ""
    @Published private(set) var messages: [Message] = []
    /// The shop server keeps older messages than those shown.
    @Published private(set) var moreMessages = false
    @Published private(set) var typing = false
    @Published private(set) var notices: [Notice] = []
    /// The call on now. The Better Messages call screen (WordPlusRealtimeUI) rings it and draws it. The shop follows it.
    @Published private(set) var call: Call?
    @Published private(set) var callState: CallState?
    @Published private(set) var callSeconds = 0
    @Published private(set) var callEnded: String?
    private var callClock: Timer?
    /// The group call on now: a call someone was added to, or the daily meeting.
    @Published private(set) var group: GroupCall?
    @Published private(set) var groupTitle = ""
    @Published private(set) var groupPeople: [GroupPerson] = []
    @Published private(set) var groupState: GroupCallState?
    /// The shop live show, while this app is in it, which the screen drawn ready shows as it goes.
    @Published private(set) var show: LiveStream?
    @Published private(set) var showRoom: String?
    @Published private(set) var showFailure: String?

    private var rt: Realtime?
    private var token = ""
    private var rooms = (order: "order:1042", chat: "chat:34:42", shop: "shop")
    private var events = (order: "updated", chat: "message")
    private var messagesRoute = "/chat/messages"
    private var seen = Set<String>()
    private var historyRead = false
    private var typingSent = Date.distantPast
    private var typingEnds: DispatchWorkItem?

    /// The one shop of the app, which the calls the system rings reach too (ExampleShopApp.swift).
    static let shared = Shop()

    /// The connection of the person signed in, for a call that rang the app closed (SystemCalls): the one running, or
    /// the one signing in again as the app opens, nil when nobody is signed in.
    @MainActor
    func connection() async -> Realtime? {
        guard rt == nil else { return rt }
        guard let id = UserDefaults.standard.string(forKey: "person") else { return nil }
        if signingIn == nil, me == nil { signIn(id) }
        for _ in 0..<150 where rt == nil && failure == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return rt
    }

    init() {
        let environment = ProcessInfo.processInfo.environment
        if let shop = environment["WORDPLUS_SHOP"] { UserDefaults.standard.set(shop, forKey: "shop") }
        server = URL(string: UserDefaults.standard.string(forKey: "shop") ?? "http://localhost:3000")!
        if environment["WORDPLUS_RESET"] == "1" { UserDefaults.standard.removeObject(forKey: "person") }
        // Whoever signed in last time, signed in again.
        if let id = UserDefaults.standard.string(forKey: "person") { signIn(id) }
    }

    var reached: Int { Self.steps.firstIndex(of: status) ?? 0 }

    /// Signs in as one of the shop people (how the example stands in for the sign-in of an app), then connects with the
    /// settings its server sent: the user keys and identity included, so no request comes first.
    func signIn(_ id: String) {
        signingIn = id
        failure = nil
        var request = URLRequest(url: server.appendingPathComponent("api/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"as\":\(id)}".utf8)
        Task { @MainActor in
            defer { self.signingIn = nil }
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let answer = JSONValue.parse(String(decoding: data, as: UTF8.self)), let token = answer["token"]?.string,
                      let config = answer["realtime"], let shop = answer["shop"] else { throw RealtimeError("sign_in") }
                UserDefaults.standard.set(id, forKey: "person")
                self.start(token: token, config: config, shop: shop)
            } catch {
                self.failure = (error as? RealtimeError)?.code ?? error.localizedDescription
            }
        }
    }

    @MainActor
    func signOut() {
        call?.end()
        group?.leave()
        leaveShow()
        // Nothing rings this phone for the person signed out any more, the app closed or not.
        rt?.calls.stopRinging()
        rt?.close()
        rt = nil
        UserDefaults.standard.removeObject(forKey: "person")
        me = nil
        members = []
        messages = []
        moreMessages = false
        notices = []
        online = []
        seen = []
        historyRead = false
        live = false
        connected = false
    }

    @MainActor
    private func start(token: String, config: JSONValue, shop: JSONValue) {
        self.token = token
        let me = shop["me"]
        let myId = me?["id"]?.id ?? ""
        self.me = Person(id: myId, name: me?["name"]?.string ?? "", role: me?["role"]?.string ?? "", staff: me?["staff"]?.bool ?? false)
        orderId = shop["order"]?["id"]?.int ?? orderId
        item = shop["order"]?["item"]?.string ?? ""
        status = shop["order"]?["status"]?.string ?? "placed"
        rooms = (shop["rooms"]?["order"]?.string ?? rooms.order, shop["rooms"]?["chat"]?.string ?? rooms.chat, shop["rooms"]?["shop"]?.string ?? rooms.shop)
        showRoom = shop["rooms"]?["show"]?.string
        events = (shop["events"]?["order"]?.string ?? events.order, shop["events"]?["chat"]?.string ?? events.chat)
        let between = shop["chat"]?["between"]?.array?.compactMap(\.id) ?? []
        inChat = between.contains(myId)
        other = between.first { $0 != myId }.flatMap(Person.named)
        otherName = other?.name ?? ""
        messagesRoute = shop["routes"]?["messages"]?.string ?? messagesRoute
        messages = []

        let rt = Realtime(RealtimeOptions(config: config, base: server, headers: { ["Authorization": "Bearer " + token] }))
        self.rt = rt
        rt.onState { [weak self] state, _ in self?.connected = state == .connected }

        // What the shop server sends the signed-in user alone, such as a notice that their order moved on.
        rt.on("notice") { [weak self] data, _ in
            guard let self, let text = data["text"]?.string else { return }
            let notice = Notice(text: text)
            withAnimation { self.notices.append(notice) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { withAnimation { self.notices.removeAll { $0.id == notice.id } } }
        }

        // Who is online across the shop: a dot on every avatar.
        let everyone = Person.all.map(\.id)
        rt.online.watch(everyone).on("change") { [weak self, weak rt] _ in
            guard let rt else { return }
            self?.online = Set(everyone.filter { rt.online.has($0) })
        }

        // The order: the shop server emits each change to its room.
        let order = rt.join(rooms.order)
        order.on(events.order) { [weak self] data, _ in
            if let status = data["status"]?.string { self?.status = status }
        }
        order.on("joined") { [weak self] _, _ in self?.live = true }
        order.on("error") { [weak self] error, _ in
            self?.live = false
            self?.failure = error["code"]?.string
        }

        enterShop()
        if inChat { openChat(rt) }

        // A call ringing for this user, from a browser or another app: Better Messages call screen rings and shows it
        // (WordPlusRealtimeUI), the shop follows the call it becomes.
        CallScreen.shared.attach(rt.calls)
        CallScreen.shared.onAnswered = { [weak self] answered in
            self?.callEnded = nil
            switch answered {
            case let .call(call): self?.follow(call)
            case let .group(group): self?.follow(group: group, title: "Group call")
            }
        }
        rt.connect()
    }

    // MARK: Calls

    /// The call name for two people, as the shop server allows it: `support:<lower id>:<higher id>`.
    func callName(with other: String) -> String {
        "support:" + [me?.id ?? "", other].sorted().joined(separator: ":")
    }

    /// Calls someone in the shop.
    func startCall(to other: String) {
        guard let rt, call == nil else { return }
        callEnded = nil
        Task { @MainActor in
            do {
                let call = try await rt.calls.start(self.callName(with: other), to: other, type: .video)
                self.follow(call)
                CallScreen.shared.show(call, name: Person.named(other)?.name)
            } catch {
                self.callEnded = (error as? CallError)?.code ?? "error"
            }
        }
    }

    /// Rings someone else in the shop into the call, which becomes a group call.
    func addToCall(_ user: String) {
        guard let call else { return }
        Task { @MainActor in _ = try? await call.add(user) }
    }

    /// The daily meeting: a group call for everyone in the shop, joined silent.
    func joinMeeting() {
        guard let rt, group == nil, call == nil else { return }
        Task { @MainActor in
            do {
                let group = try await rt.calls.group("meeting:daily", type: .video)
                self.follow(group: group, title: "Daily meeting")
                CallScreen.shared.show(group, title: "Daily meeting")
            } catch {
                self.callEnded = (error as? CallError)?.code ?? "error"
            }
        }
    }

    // MARK: The live show

    /// Watches the shop live show, as the `streams()` rule of the shop server lets this user in (Ann presents it).
    @MainActor
    func watchShow() {
        guard let rt, let name = showRoom, show == nil else { return }
        showFailure = nil
        Task { @MainActor in
            do {
                let stream = try await rt.calls.stream(name)
                stream.onEnded { [weak self, weak stream] _ in
                    guard let self, self.show === stream else { return }
                    self.show = nil
                }
                self.show = stream
            } catch {
                self.showFailure = (error as? CallError)?.code ?? "error"
            }
        }
    }

    @MainActor
    func leaveShow() {
        show?.leave()
        show = nil
    }

    private func follow(group: GroupCall, title: String) {
        self.group = group
        groupTitle = title
        groupState = group.state
        groupPeople = group.people
        group.onState { [weak self, weak group] state in
            guard let self, self.group === group else { return }
            self.groupState = state
        }
        group.onPeople { [weak self, weak group] in
            guard let self, let group, self.group === group else { return }
            self.groupPeople = group.people
        }
        group.onEnded { [weak self, weak group] _ in
            guard let self, self.group === group else { return }
            self.group = nil
            self.groupPeople = []
            self.groupState = nil
        }
    }

    private func follow(_ call: Call) {
        self.call = call
        callState = call.state
        callSeconds = 0
        call.onState { [weak self, weak call] state in
            guard let self, let call, self.call === call else { return }
            self.callState = state
            if state == .connected, self.callClock == nil {
                self.callClock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.callSeconds += 1 }
            }
        }
        call.onRemote { [weak self] in self?.objectWillChange.send() }
        // Someone was added: the call goes on as a group call.
        call.onGroup { [weak self] group in self?.follow(group: group, title: "Group call") }
        call.onEnded { [weak self, weak call] reason in
            guard let self, self.call === call else { return }
            self.callClock?.invalidate()
            self.callClock = nil
            self.call = nil
            self.callState = nil
            self.callEnded = reason
        }
    }

    // MARK: The order

    /// The staff move the order on, through the shop server, which emits it to the order room and skips this app.
    func mark(_ next: String) {
        guard let rt else { return }
        status = next
        var request = URLRequest(url: server.appendingPathComponent("orders/\(orderId)/status"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(rt.tab, forHTTPHeaderField: "X-Realtime-Tab")
        request.httpBody = try? JSONValue.object(["status": .string(next)]).encoded()
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: Who is in the shop

    private func enterShop() {
        guard let rt else { return }
        let room = rt.join(rooms.shop)
        for event in ["joined", "join", "leave"] {
            room.on(event) { [weak self, weak room] _, _ in
                guard let self, let room, self.inShop else { return }
                self.members = room.members
                    .map { Member(id: $0.key, name: $0.value["name"]?.string ?? Person.named($0.key)?.name ?? "", role: $0.value["role"]?.string ?? "") }
                    .sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
            }
        }
        inShop = true
    }

    /// Stepping out leaves the presence room. Coming back joins it again.
    func toggleShop() {
        if inShop {
            rt?.leave(rooms.shop)
            inShop = false
            members = []
        } else {
            enterShop()
        }
    }

    // MARK: The chat

    private func openChat(_ rt: Realtime) {
        let chat = rt.join(rooms.chat)
        chat.on(events.chat) { [weak self] data, meta in
            self?.typing = false
            self?.add(from: data["from"]?.id ?? meta.from ?? "", text: data["text"]?.string ?? "", id: meta.id, at: meta.at)
        }
        chat.on("typing") { [weak self] data, _ in
            guard let self else { return }
            self.typing = data["on"]?.bool == true
            self.typingEnds?.cancel()
            guard self.typing else { return }
            let end = DispatchWorkItem { [weak self] in self?.typing = false }
            self.typingEnds = end
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: end)
        }
        // What was said before the app opened, once: the conversation from the shop server, then from the room
        // history (its last 5 minutes) what the webhook may not have brought yet. A reconnect gets what it missed itself.
        chat.on("joined") { [weak self, weak chat] _, _ in
            guard let self, let chat, !self.historyRead else { return }
            self.historyRead = true
            Task { @MainActor in
                await self.earlier(before: nil)
                guard let page = try? await chat.history(limit: 50) else { return }
                for e in page.events where e.event == self.events.chat {
                    self.add(from: e.data["from"]?.id ?? e.meta.from ?? "", text: e.data["text"]?.string ?? "", id: e.meta.id, at: e.meta.at)
                }
            }
        }
        // Who is on the other side, from the app directory: the name their own server gave when they connected.
        if let other {
            Task { @MainActor in
                if let name = try? await rt.users([other.id])[other.id]?["name"]?.string { self.otherName = name }
            }
        }
    }

    /// A message once, in the order it was said.
    private func add(from: String, text: String, id: String?, at: Double?) {
        if let id {
            guard !seen.contains(id) else { return }
            seen.insert(id)
        }
        let message = Message(id: id ?? UUID().uuidString, from: from, text: text, at: at ?? Date().timeIntervalSince1970 * 1000)
        messages.insert(message, at: messages.firstIndex { $0.at > message.at } ?? messages.endIndex)
    }

    /// A page of the conversation the shop server keeps: the newest, or the one before the message `before`.
    @MainActor
    private func earlier(before: String?) async {
        guard var address = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return }
        address.path = messagesRoute
        address.queryItems = before.map { [URLQueryItem(name: "before", value: $0)] }
        guard let url = address.url else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let page = JSONValue.parse(String(decoding: data, as: UTF8.self)) else { return }
        for m in page["messages"]?.array ?? [] {
            add(from: m["from"]?.id ?? "", text: m["text"]?.string ?? "", id: m["id"]?.string, at: m["at"]?.number)
        }
        moreMessages = page["more"]?.bool ?? false
    }

    /// The page before the oldest message shown.
    func showEarlier() {
        Task { @MainActor in await self.earlier(before: self.messages.first?.id) }
    }

    /// Typing, sent at most every two seconds while there is something written.
    func typed(_ text: String) {
        guard !text.isEmpty, Date().timeIntervalSince(typingSent) > 2 else { return }
        typingSent = Date()
        rt?.room(rooms.chat)?.volatile.emit("typing", ["on": true])
    }

    /// A message straight to the room, acked by the cloud once it is kept and sent.
    func send(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let chat = rt?.room(rooms.chat), let me else { return }
        typingSent = .distantPast
        chat.volatile.emit("typing", ["on": false])
        Task { @MainActor in
            do {
                let ack = try await chat.emitWithAck(self.events.chat, ["from": .number(Double(me.id) ?? 0), "text": .string(words)])
                self.add(from: me.id, text: words, id: ack.id, at: nil)
            } catch {
                self.add(from: me.id, text: "Not sent: " + ((error as? RealtimeError)?.code ?? "error"), id: nil, at: nil)
            }
        }
    }
}
