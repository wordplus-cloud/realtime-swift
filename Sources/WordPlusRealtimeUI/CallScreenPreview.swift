#if canImport(UIKit)
import UIKit

/// Every state of the call screen with no call: calling,
/// ringing, connecting, a call by voice and by video, the microphone and camera off, the other side lost, this side
/// reconnecting, and a group call by video and by voice, each in light and dark and right to left. The app's pieces
/// (`CallScreen.shared.pieces`) and look (`configure`) are drawn as in a call, and an app that copied the screen
/// (`swift package wordplus-ui add`) has this file in its copy, so the preview draws the copy.
///
///     window.rootViewController = UINavigationController( rootViewController: CallScreenPreview() )
///
/// lists the states; `CallScreenPreview( .video )` shows one, as Xcode's canvas does:
/// `#Preview { CallScreenPreview( .video ) }`.
@MainActor
public final class CallScreenPreview: UIViewController, UITableViewDataSource, UITableViewDelegate {
    /// A state the screen can be in.
    public enum Shown: String, CaseIterable, Sendable {
        case calling, ringing, connecting, voice, video, off, peerLost, reconnecting, group, groupVoice

        public var title: String {
            switch self {
            case .calling: return "Calling"
            case .ringing: return "Ringing in"
            case .connecting: return "Connecting"
            case .voice: return "In a call by voice"
            case .video: return "In a call by video"
            case .off: return "Microphone and camera off"
            case .peerLost: return "The other side lost"
            case .reconnecting: return "This side reconnecting"
            case .group: return "Group call by video"
            case .groupVoice: return "Group call by voice"
            }
        }
    }

    private let shown: Shown?
    private var dark = false
    private var rightToLeft = false
    private var screen: BmCallsScreen?

    /// The list of states, or one state alone.
    public init( _ shown: Shown? = nil ) {
        self.shown = shown
        super.init( nibName: nil, bundle: nil )
    }

    @available( *, unavailable )
    required init?( coder: NSCoder ) { fatalError( "init(coder:) is not supported" ) }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        guard let shown else {
            title = "Call screen"
            let list = UITableView( frame: view.bounds, style: .insetGrouped )
            list.autoresizingMask = [ .flexibleWidth, .flexibleHeight ]
            list.dataSource = self
            list.delegate = self
            list.register( UITableViewCell.self, forCellReuseIdentifier: "state" )
            view.addSubview( list )
            return
        }

        title = shown.title
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem( title: "Dark", style: .plain, target: self, action: #selector( toggleDark ) ),
            UIBarButtonItem( title: "RTL", style: .plain, target: self, action: #selector( toggleDirection ) ),
        ]
        draw( shown )
    }

    // MARK: The list

    public func tableView( _ tableView: UITableView, numberOfRowsInSection section: Int ) -> Int { Shown.allCases.count }

    public func tableView( _ tableView: UITableView, cellForRowAt indexPath: IndexPath ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell( withIdentifier: "state", for: indexPath )
        var content = cell.defaultContentConfiguration()
        content.text = Shown.allCases[ indexPath.row ].title
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    public func tableView( _ tableView: UITableView, didSelectRowAt indexPath: IndexPath ) {
        tableView.deselectRow( at: indexPath, animated: true )
        let page = CallScreenPreview( Shown.allCases[ indexPath.row ] )
        if let navigationController { navigationController.pushViewController( page, animated: true ) } else { present( page, animated: true ) }
    }

    // MARK: One state

    @objc private func toggleDark() {
        dark.toggle()
        applyTraits()
    }

    @objc private func toggleDirection() {
        rightToLeft.toggle()
        applyTraits()
    }

    private func applyTraits() {
        guard let screen else { return }
        let traits = UITraitCollection( traitsFrom: [
            UITraitCollection( userInterfaceStyle: dark ? .dark : .light ),
            UITraitCollection( layoutDirection: rightToLeft ? .rightToLeft : .leftToRight ),
        ] )
        setOverrideTraitCollection( traits, forChild: screen )
        screen.view.semanticContentAttribute = rightToLeft ? .forceRightToLeft : .forceLeftToRight
        screen.view.setNeedsLayout()
    }

    private func draw( _ shown: Shown ) {
        // The screen's look and the app's pieces are installed with the call screen.
        _ = CallScreen.shared
        let screen = BmCallsScreen()
        screen.canShareScreen = false
        addChild( screen )
        screen.view.frame = view.bounds
        screen.view.autoresizingMask = [ .flexibleWidth, .flexibleHeight ]
        view.addSubview( screen.view )
        screen.didMove( toParent: self )
        self.screen = screen
        applyTraits()

        let group = shown == .group || shown == .groupVoice
        let video = shown != .voice && shown != .groupVoice
        screen.show( name: group ? "Daily meeting" : "Ann", avatar: "", video: video )
        screen.apply( state: Self.state( shown ) )
        if group { screen.setRoster( Self.people() ) }
    }

    /// The state as the call screen hands it to the screen in a call (CallScreen.state).
    static func state( _ shown: Shown ) -> [ String: Any ] {
        let phase: String
        switch shown {
        case .calling: phase = "ringing_out"
        case .ringing: phase = "ringing_in"
        case .connecting: phase = "connecting"
        case .peerLost, .reconnecting: phase = "reconnecting"
        default: phase = "in_progress"
        }
        let group = shown == .group || shown == .groupVoice
        let video = shown != .voice && shown != .groupVoice
        let off = shown == .off
        let trouble: Any
        switch shown {
        case .peerLost: trouble = "peer"
        case .reconnecting: trouble = "self"
        default: trouble = NSNull()
        }
        return [
            "phase": phase,
            "trouble": trouble,
            "type": video ? "video" : "audio",
            "group": group,
            "peer": [ "camera": false, "microphone": !off, "screen": false, "known": phase == "in_progress" || phase == "reconnecting" ],
            "local": [ "muted": off, "camera": false, "screen": false, "front": true, "route": "" ],
            "callMode": group ? "participatory" : NSNull(),
            "roomLocked": false,
            "roomMuted": false,
            "canModerate": false,
            "handRaised": false,
            "online": [ Int ](),
            "peerOnline": true,
        ]
    }

    /// A group call's people with no pictures: this side, someone speaking, someone muted, someone else.
    static func people() -> [ BmCallsRoomParticipant ] {
        func person( _ identity: String, _ name: String, local: Bool = false, speaking: Bool = false, muted: Bool = false ) -> BmCallsRoomParticipant {
            BmCallsRoomParticipant(
                identity: identity, name: name, avatar: "", isLocal: local, video: nil, screen: nil,
                speaking: speaking, audioLevel: speaking ? 0.6 : 0, muted: muted, micMuted: false, handRaised: false,
                isPinned: false, canPublish: true, canAdmin: false, mode: "participant", lost: false
            )
        }
        return [
            person( "me", "You", local: true ),
            person( "ann", "Ann", speaking: true ),
            person( "ben", "Ben", muted: true ),
            person( "cara", "Cara" ),
        ]
    }
}
#endif
