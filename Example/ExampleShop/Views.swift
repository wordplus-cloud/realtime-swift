import SwiftUI
import WordPlusRealtimeCalls
import WordPlusRealtimeUI

/// The shop colours, as its web pages have them.
enum Palette {
    static let page = Color(hex: 0xf8fafc)
    static let card = Color.white
    static let line = Color(hex: 0xe2e8f0)
    static let ink = Color(hex: 0x0f172a)
    static let muted = Color(hex: 0x64748b)
    static let blue = Color(hex: 0x2563eb)
    static let green = Color(hex: 0x13865b)
    static let online = Color(hex: 0x22c55e)
    static let bubble = Color(hex: 0xf1f5f9)
    static let people: [String: Color] = ["Ann": Color(hex: 0x2563c9), "Ben": Color(hex: 0x13865b), "Cara": Color(hex: 0xb4561c)]
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

struct RootView: View {
    @EnvironmentObject private var shop: Shop

    var body: some View {
        VStack(spacing: 0) {
            Bar()
            if shop.me == nil {
                SignIn()
            } else {
                ShopScreen()
            }
        }
        .background(Palette.page.ignoresSafeArea())
        .overlay(alignment: .top) { Notices().padding(.top, 56) }
        // The call itself is the Better Messages call screen (WordPlusRealtimeUI), in a window of its own above the shop.
        // this bar is what the shop shows of it while that screen is put away.
        .overlay(alignment: .bottom) { CallBar() }
    }
}

/// The call going on, while its screen is put away: who and for how long, someone to ring into it, and the way back.
private struct CallBar: View {
    @EnvironmentObject private var shop: Shop

    var body: some View {
        if shop.call != nil || shop.group != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline).foregroundStyle(.white)
                        if shop.group != nil {
                            Text(peopleText)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.75))
                                .accessibilityIdentifier("group-people")
                                .accessibilityValue("\(shop.groupPeople.count)")
                        } else {
                            Text(stateText)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.75))
                                .accessibilityIdentifier("call-state")
                                .accessibilityValue(shop.callState?.rawValue ?? "")
                        }
                    }
                    Spacer()
                    Button { CallScreen.shared.restore() } label: {
                        Text("Back to the call").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.white, in: Capsule())
                    }
                    .accessibilityIdentifier("back-to-call")
                }
                // Someone else rung into the call, which goes on as a group call.
                if let call = shop.call, shop.callState == .connected {
                    HStack(spacing: 10) {
                        ForEach(Person.all.filter { $0.id != shop.me?.id && $0.id != call.peer }) { person in
                            Button { shop.addToCall(person.id) } label: {
                                Label("Add \(person.name)", systemImage: "person.badge.plus")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(.white.opacity(0.16), in: Capsule())
                            }
                            .accessibilityIdentifier("add-\(person.id)")
                        }
                    }
                }
            }
            .padding(16)
            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 18))
            .padding(12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var title: String {
        if shop.group != nil { return shop.groupTitle }
        guard let call = shop.call else { return "" }
        return call.peerInfo["name"]?.string ?? Person.named(call.peer)?.name ?? "Someone"
    }

    private var peopleText: String {
        switch shop.groupState {
        case .connected:
            let count = shop.groupPeople.count
            return count == 0 ? "Nobody else yet" : count == 1 ? "1 other person" : "\(count) other people"
        case .reconnecting: return "Reconnecting…"
        default: return "Joining…"
        }
    }

    private var stateText: String {
        switch shop.callState {
        case .ringing: return "Ringing…"
        case .connecting: return "Connecting…"
        case .connected: return String(format: "%d:%02d", shop.callSeconds / 60, shop.callSeconds % 60)
        case .reconnecting: return "Reconnecting…"
        default: return ""
        }
    }
}

private struct Bar: View {
    @EnvironmentObject private var shop: Shop

    var body: some View {
        HStack(spacing: 8) {
            Text("API demo").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
            Spacer()
            if let me = shop.me {
                Avatar(name: me.name, size: 24, online: shop.connected)
                Text(me.name).font(.subheadline).foregroundStyle(Palette.ink)
                Button("Sign out") { shop.signOut() }
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Palette.card)
        .overlay(alignment: .bottom) { Palette.line.frame(height: 1) }
    }
}

/// The picture of a person: their initial on their colour, with a dot while they are online.
struct Avatar: View {
    let name: String
    var size: CGFloat = 32
    var online = false

    var body: some View {
        Circle()
            .fill(Palette.people[name] ?? Palette.muted)
            .frame(width: size, height: size)
            .overlay(Text(name.prefix(1)).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white))
            .overlay(alignment: .bottomTrailing) {
                if online {
                    Circle().fill(Palette.online)
                        .frame(width: size * 0.32, height: size * 0.32)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
    }
}

private struct Heading: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.ink)
    }
}

private struct Muted: View {
    let text: String

    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(Palette.muted)
    }
}

private struct SignIn: View {
    @EnvironmentObject private var shop: Shop

    var body: some View {
        ScrollView {
            Card {
                Heading(text: "Sign in")
                Muted(text: "As Ann, Ben or Cara. Sign in as someone else in a browser, or on another device.")
                ForEach(Person.all) { person in
                    Button { shop.signIn(person.id) } label: {
                        HStack(spacing: 12) {
                            Avatar(name: person.name)
                            Text(person.name).foregroundStyle(Palette.ink)
                            Text(person.role).font(.subheadline).foregroundStyle(Palette.muted)
                            Spacer()
                            if shop.signingIn == person.id { ProgressView() }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("sign-in-\(person.id)")
                }
                if let failure = shop.failure {
                    Text("Could not connect: \(failure)").font(.subheadline).foregroundStyle(.red)
                }
            }
            .padding(16)
        }
    }
}

private struct ShopScreen: View {
    @EnvironmentObject private var shop: Shop

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                OrderCard()
                PresenceCard()
                if shop.showRoom != nil { ShowCard() }
                MeetingCard()
                if shop.inChat {
                    ChatCard()
                } else {
                    Card {
                        Heading(text: "Chat")
                        Muted(text: "The chat is between Ann and Ben.")
                    }
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// The order: its customer watches it move on. The staff move it.
private struct OrderCard: View {
    @EnvironmentObject private var shop: Shop

    var body: some View {
        let reached = shop.reached
        let staff = shop.me?.staff ?? false
        Card {
            Heading(text: staff ? "Order #\(shop.orderId) · Ben" : "Your order #\(shop.orderId)")
            Muted(text: shop.item)
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(Shop.steps.enumerated()), id: \.offset) { i, step in
                    VStack(spacing: 6) {
                        HStack(spacing: 0) {
                            Rectangle().fill(i == 0 ? .clear : i <= reached ? Palette.green : Palette.line).frame(height: 2)
                            Circle()
                                .fill(i < reached ? Palette.green : i == reached ? Palette.blue : Palette.card)
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(i < reached ? Palette.green : i == reached ? Palette.blue : Color(hex: 0xcbd5e1), lineWidth: 2))
                            Rectangle().fill(i == Shop.steps.count - 1 ? .clear : i < reached ? Palette.green : Palette.line).frame(height: 2)
                        }
                        Text(Shop.labels[step] ?? step)
                            .font(.footnote.weight(i == reached ? .semibold : .regular))
                            .foregroundStyle(i <= reached ? Palette.ink : Palette.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("step-\(step)")
                    .accessibilityValue(i < reached ? "done" : i == reached ? "now" : "next")
                }
            }
            .padding(.vertical, 4)
            if staff {
                HStack(spacing: 8) {
                    Muted(text: "Mark as")
                    ForEach(Shop.steps.dropFirst(), id: \.self) { next in
                        Button(Shop.labels[next] ?? next) { shop.mark(next) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(Palette.blue)
                            .disabled((Shop.steps.firstIndex(of: next) ?? 0) <= reached)
                    }
                }
            } else {
                Text(shop.live ? "● Live" : "Connecting…")
                    .font(.subheadline)
                    .foregroundStyle(shop.live ? Palette.green : Palette.muted)
                    .accessibilityIdentifier("order-live")
                    .accessibilityLabel(shop.live ? "Live" : "Connecting")
            }
        }
    }
}

/// Everyone in the shop now. Stepping out leaves the room.
private struct PresenceCard: View {
    @EnvironmentObject private var shop: Shop

    var body: some View {
        Card {
            Heading(text: "In the shop now")
            if !shop.inShop {
                Muted(text: "You stepped out.")
            }
            ForEach(shop.members) { member in
                HStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Avatar(name: member.name, online: shop.online.contains(member.id))
                        Text(member.name).foregroundStyle(Palette.ink)
                            + Text(member.id == shop.me?.id ? " (you)" : "").foregroundStyle(Palette.muted)
                        Spacer()
                        Text(member.role).font(.subheadline).foregroundStyle(Palette.muted)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("member-\(member.id)")
                    .accessibilityValue(shop.online.contains(member.id) ? "online" : "offline")
                    if member.id != shop.me?.id {
                        Button { shop.startCall(to: member.id) } label: {
                            Image(systemName: "video.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Palette.blue)
                                .frame(width: 34, height: 34)
                                .background(Palette.blue.opacity(0.1), in: Circle())
                        }
                        .disabled(shop.call != nil)
                        .accessibilityIdentifier("call-\(member.id)")
                        .accessibilityLabel("Call \(member.name)")
                    }
                }
            }
            if let ended = shop.callEnded {
                Text("Call ended")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("call-ended")
                    .accessibilityValue(ended)
            }
            Button(shop.inShop ? "Step out" : "Come back") { shop.toggleShop() }
                .font(.subheadline)
                .foregroundStyle(Palette.muted)
        }
    }
}

/// The shop live show: Ann presents it, and the app watches it on the screen drawn ready (LiveStreamScreen of
/// WordPlusRealtimeUI): its picture, Live and how many watch, its chat and a heart.
private struct ShowCard: View {
    @EnvironmentObject private var shop: Shop

    var body: some View {
        Card {
            Heading(text: "Live show")
            Muted(text: shop.showFailure.map { "The show is not available here (\($0))." } ?? "Ann presents the mugs live.")
            Button { shop.watchShow() } label: {
                Text("Watch the show").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.blue)
            .accessibilityIdentifier("watch-show")
        }
        .fullScreenCover(isPresented: Binding(get: { shop.show != nil }, set: { if !$0 { shop.leaveShow() } })) {
            if let show = shop.show {
                ShowScreen(stream: show, close: { shop.leaveShow() }).ignoresSafeArea()
            }
        }
    }
}

/// The screen drawn ready, in SwiftUI. Closing it leaves the show, as the shop keeps it.
private struct ShowScreen: UIViewControllerRepresentable {
    let stream: LiveStream
    let close: () -> Void

    func makeUIViewController(context: Context) -> LiveStreamScreen {
        let screen = LiveStreamScreen(stream: stream, title: "The new mugs")
        screen.leavesOnClose = false
        screen.onClose = close
        return screen
    }

    func updateUIViewController(_ screen: LiveStreamScreen, context: Context) {}
}

/// The daily meeting: a group call everyone in the shop may join.
private struct MeetingCard: View {
    @EnvironmentObject private var shop: Shop

    var body: some View {
        Card {
            Heading(text: "Daily meeting")
            Muted(text: "Ann, Ben and Cara, with video.")
            Button { shop.joinMeeting() } label: {
                Text("Join the meeting").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.blue)
            .disabled(shop.group != nil || shop.call != nil)
            .accessibilityIdentifier("join-meeting")
        }
    }
}

/// The chat of Ann and Ben.
private struct ChatCard: View {
    @EnvironmentObject private var shop: Shop
    @State private var draft = ""

    var body: some View {
        Card {
            HStack(spacing: 10) {
                Avatar(name: shop.other?.name ?? "", size: 30, online: shop.other.map { shop.online.contains($0.id) } ?? false)
                Heading(text: shop.otherName)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat-with")
            VStack(alignment: .leading, spacing: 6) {
                if shop.moreMessages {
                    Button("Earlier messages") { shop.showEarlier() }
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                }
                ForEach(shop.messages) { message in
                    let mine = message.from == shop.me?.id
                    HStack {
                        if mine { Spacer(minLength: 40) }
                        Text(message.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundStyle(mine ? .white : Palette.ink)
                            .background(mine ? Palette.blue : Palette.bubble, in: RoundedRectangle(cornerRadius: 14))
                        if !mine { Spacer(minLength: 40) }
                    }
                }
            }
            Text(shop.typing ? "\(shop.otherName) is typing…" : " ")
                .font(.subheadline)
                .foregroundStyle(Palette.muted)
                .accessibilityIdentifier("typing")
            HStack(spacing: 8) {
                TextField("Write a message", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draft) { _, text in shop.typed(text) }
                    .onSubmit(send)
                    .accessibilityIdentifier("message-field")
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.blue)
                    .accessibilityIdentifier("send")
            }
        }
    }

    private func send() {
        shop.send(draft)
        draft = ""
    }
}

/// Notices from the shop server, for a few seconds each.
private struct Notices: View {
    @EnvironmentObject private var shop: Shop

    var body: some View {
        VStack(spacing: 8) {
            ForEach(shop.notices) { notice in
                Text(notice.text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Palette.ink, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("notice")
            }
        }
    }
}
