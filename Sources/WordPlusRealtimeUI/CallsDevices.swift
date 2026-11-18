import UIKit
import AVFoundation
import AVKit

/// Device Settings, the dock's settings button in every call, as the web draws it (realtime-ui's device-panel.tsx,
/// `.wplus-call-devices` in _call-stage.scss): the camera (on a video call), the microphone and the speaker, each with
/// a field for the device in use that opens the others in the system's own menu, a test that is the user's alone, and
/// whether the others see or hear it now.
///
/// Nothing here sends anything: going live is the dock's camera and microphone buttons alone. Nothing opens a device
/// before a press: a test runs only once its button is pressed, and only while the call does not send that device.
/// Drawn on the call, as the moderation menus are, never presented over it.
final class CallsDevices: UIView {
    /// What the panel reads of the call, asked again on every `refresh()`.
    struct Context {
        var video: Bool
        var group: Bool
        var cameraOn: Bool
        var microphoneOn: Bool
        /// A moderator keeps the microphone off.
        var micHeld: Bool
        /// May send at all (not a viewer in broadcast mode).
        var mayPublish: Bool
        var front: Bool
        /// The other person, in a call between two.
        var peerName: String
        /// The level the call sends the microphone at, 0…1, while it does; nil where it is not known.
        var sendingLevel: Float?
        /// Someone muted is talking ("You are muted"), said in the microphone's row while the panel is open.
        var talkingMuted: Bool
    }

    enum Start { case camera, microphone, both }

    enum Kind { case camera, microphone, speaker }

    private let context: () -> Context?
    private let traffic: ( () -> ( received: Int, sent: Int ) )?
    private let card = UIView()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let trafficLabel = UILabel()
    private var cameraRow: CallsDeviceRow?
    private(set) var microphoneRow: CallsDeviceRow
    private let speakerRow: CallsDeviceRow
    private let preview = CallsCameraPreview()
    private let microphoneTest = CallsMicrophoneTest()
    private let routePicker = AVRoutePickerView()

    /// Whether each test runs: set by its button alone (and by the package's own tests, to draw it running).
    var testingCamera = false
    var testingMicrophone = false
    private var playing = false
    private var previewFront = true
    private var cameraDenied = false
    private var microphoneDenied = false
    private var shownLevel: Float = 0
    private var meterTimer: Timer?
    private var trafficTimer: Timer?
    private var closing = false

    /// Called once the panel is gone, whichever way it went.
    var onClose: ( () -> Void )?
    /// The camera chosen in its menu: `true` for the front one.
    var onChooseCamera: ( ( Bool ) -> Void )?

    init( context: @escaping () -> Context?, traffic: ( () -> ( received: Int, sent: Int ) )? ) {
        self.context = context
        self.traffic = traffic
        microphoneRow = CallsDeviceRow( kind: .microphone )
        speakerRow = CallsDeviceRow( kind: .speaker )

        super.init( frame: .zero )

        backgroundColor = .clear

        let ctx = context()
        previewFront = ctx?.front ?? true

        card.backgroundColor = UIColor( red: 22 / 255, green: 24 / 255, blue: 30 / 255, alpha: 1 )
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor( white: 1, alpha: 0.09 ).cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.5
        card.layer.shadowRadius = 24
        card.layer.shadowOffset = CGSize( width: 0, height: 18 )
        card.translatesAutoresizingMaskIntoConstraints = false
        card.accessibilityViewIsModal = true
        card.accessibilityLabel = CallsTheme.string( "device_settings", fallback: "Device Settings" )

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.layer.cornerRadius = 16
        scroll.layer.cornerCurve = .continuous
        scroll.clipsToBounds = true

        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = CallsTheme.string( "device_settings", fallback: "Device Settings" )
        title.font = .systemFont( ofSize: 14, weight: .semibold )
        title.textColor = .white
        title.accessibilityTraits = .header
        stack.addArrangedSubview( Self.padded( title, UIEdgeInsets( top: 4, left: 6, bottom: 8, right: 6 ) ) )

        if ctx?.video ?? true {
            let row = CallsDeviceRow( kind: .camera )
            row.preview = preview
            cameraRow = row
            stack.addArrangedSubview( row )
        }

        stack.addArrangedSubview( microphoneRow )
        stack.addArrangedSubview( speakerRow )

        // The system's own list of outputs: the route picker, pressed for the person from the speaker's row.
        routePicker.isHidden = true
        addSubview( routePicker )

        if traffic != nil {
            trafficLabel.font = .monospacedDigitSystemFont( ofSize: 11.5, weight: .regular )
            trafficLabel.textColor = UIColor( white: 1, alpha: 0.55 )
            trafficLabel.numberOfLines = 0
            stack.addArrangedSubview( Self.padded( trafficLabel, UIEdgeInsets( top: 6, left: 8, bottom: 2, right: 8 ) ) )
        }

        let done = CallsDevicePill( title: CallsTheme.string( "device_done", fallback: "Done" ) )
        done.addTarget( self, action: #selector( doneTapped ), for: .touchUpInside )
        let doneHolder = Self.padded( done, UIEdgeInsets( top: 6, left: 0, bottom: 0, right: 0 ) )
        stack.addArrangedSubview( doneHolder )

        scroll.addSubview( stack )
        card.addSubview( scroll )
        addSubview( card )

        let fit = scroll.frameLayoutGuide.heightAnchor.constraint( equalTo: stack.heightAnchor, constant: 16 )
        fit.priority = .defaultLow

        NSLayoutConstraint.activate( [
            stack.topAnchor.constraint( equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8 ),
            stack.bottomAnchor.constraint( equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8 ),
            stack.leadingAnchor.constraint( equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 8 ),
            stack.trailingAnchor.constraint( equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -8 ),
            scroll.leadingAnchor.constraint( equalTo: card.leadingAnchor ),
            scroll.trailingAnchor.constraint( equalTo: card.trailingAnchor ),
            scroll.topAnchor.constraint( equalTo: card.topAnchor ),
            scroll.bottomAnchor.constraint( equalTo: card.bottomAnchor ),
            fit,
        ] )

        for row in [ cameraRow, microphoneRow, speakerRow ].compactMap( { $0 } ) {
            row.onTest = { [weak self, weak row] in
                guard let self, let row else { return }
                self.toggleTest( row.kind )
            }
            row.onChoose = { [weak self, weak row] id in
                guard let self, let row else { return }
                self.choose( id, of: row.kind )
            }
        }

        speakerRow.onCurrent = { [weak self] in self?.openOutputs() }

        refresh()
        drawTraffic()

        if traffic != nil {
            trafficTimer = Timer.scheduledTimer( withTimeInterval: 1, repeats: true ) { [weak self] _ in self?.drawTraffic() }
        }

        NotificationCenter.default.addObserver( self, selector: #selector( routeChanged ), name: AVAudioSession.routeChangeNotification, object: nil )
    }

    required init?( coder: NSCoder ) { fatalError( "init(coder:) has not been implemented" ) }

    deinit {
        meterTimer?.invalidate()
        trafficTimer?.invalidate()
        NotificationCenter.default.removeObserver( self )
    }

    /// Over the whole of `host`, the card just above the dock: a tap outside it closes it.
    func place( in host: UIView, above dock: UIView ) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview( self )
        self.dock = dock

        // 340 wide where it fits, the stage less its edges where it does not (layoutSubviews).
        let wide = card.widthAnchor.constraint( equalToConstant: min( 340, host.bounds.width - 28 ) )
        cardWidth = wide

        NSLayoutConstraint.activate( [
            leadingAnchor.constraint( equalTo: host.leadingAnchor ),
            trailingAnchor.constraint( equalTo: host.trailingAnchor ),
            topAnchor.constraint( equalTo: host.topAnchor ),
            bottomAnchor.constraint( equalTo: host.bottomAnchor ),
            card.centerXAnchor.constraint( equalTo: centerXAnchor ),
            card.bottomAnchor.constraint( equalTo: dock.topAnchor, constant: -12 ),
            card.topAnchor.constraint( greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: 14 ),
            wide,
        ] )

        card.alpha = 0
        card.transform = CGAffineTransform( translationX: 0, y: 4 ).scaledBy( x: 0.98, y: 0.98 )

        UIView.animate( withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.14, delay: 0, options: [ .curveEaseOut ] ) {
            self.card.alpha = 1
            self.card.transform = .identity
        }

        UIAccessibility.post( notification: .screenChanged, argument: card )
    }

    /// The tests a join notice's Preview starts: the camera and the microphone together on a video call, the
    /// microphone on an audio one.
    func start( _ start: Start ) {
        switch start {
        case .camera: toggleTest( .camera )
        case .microphone: toggleTest( .microphone )
        case .both:
            toggleTest( .camera )
            toggleTest( .microphone )
        }
    }

    private var cardWidth: NSLayoutConstraint?
    private weak var dock: UIView?

    override func layoutSubviews() {
        let width = min( 340, max( 200, bounds.width - 28 ) )

        if let cardWidth, bounds.width > 0, cardWidth.constant != width {
            cardWidth.constant = width
        }

        super.layoutSubviews()
        card.layer.shadowPath = UIBezierPath( roundedRect: card.bounds, cornerRadius: 16 ).cgPath
    }

    override func hitTest( _ point: CGPoint, with event: UIEvent? ) -> UIView? {
        guard !closing else { return nil }

        // A press beside a device's menu closes the menu and presses nothing else: since iOS 26 it comes through to here,
        // where it would close the panel too.
        if [ cameraRow, microphoneRow, speakerRow ].contains( where: { $0?.menuOpen == true } ) {
            return self
        }

        if card.frame.contains( point ) {
            return super.hitTest( point, with: event )
        }

        // The dock stays usable under the panel: its camera and microphone are how a device goes live, and the panel
        // then says so.
        if let dock, dock.bounds.contains( convert( point, to: dock ) ) {
            return nil
        }

        // Elsewhere outside the card: the panel goes, as Done does.
        if event?.type == .touches {
            DispatchQueue.main.async { [weak self] in self?.close() }
        }

        return nil
    }

    func close() {
        guard !closing else { return }

        closing = true
        stopCameraTest()
        stopMicrophoneTest()
        CallsTones.shared.stop()
        meterTimer?.invalidate()
        trafficTimer?.invalidate()

        UIView.animate( withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.1, animations: {
            self.card.alpha = 0
        }, completion: { _ in
            self.removeFromSuperview()
        } )

        onClose?()
    }

    @objc private func doneTapped() { close() }

    @objc private func routeChanged() {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// The camera's test stopped before the dock's camera opens the device for the call.
    func cameraWillGoLive( _ then: @escaping () -> Void ) {
        guard testingCamera else {
            then()
            return
        }

        testingCamera = false
        preview.stop( then )
        refresh()
    }

    /// The microphone's test stopped before the dock's microphone sends it.
    func microphoneWillGoLive() {
        stopMicrophoneTest()
        refresh()
    }

    // MARK: Tests

    private func toggleTest( _ kind: Kind ) {
        guard let ctx = context() else { return }

        switch kind {
        case .camera:
            if testingCamera {
                stopCameraTest()
            } else if ctx.video, !ctx.cameraOn, CallsEngine.shared.testsCamera {
                testingCamera = true
                preview.start( front: previewFront ) { [weak self] ok in
                    guard let self, !self.closing else { return }

                    if !ok {
                        self.testingCamera = false
                        self.cameraDenied = CallsDeviceTests.cameraDenied
                    }
                    self.refresh()
                }
            }
        case .microphone:
            if testingMicrophone {
                stopMicrophoneTest()
            } else if !ctx.microphoneOn, !ctx.micHeld, CallsEngine.shared.testsMicrophone {
                testingMicrophone = true
                microphoneTest.start { [weak self] ok in
                    guard let self, !self.closing else { return }

                    if !ok {
                        self.testingMicrophone = false
                        self.microphoneDenied = CallsDeviceTests.microphoneDenied
                    }
                    self.refresh()
                }
            }
        case .speaker:
            if playing {
                CallsTones.shared.stop()
                playing = false
            } else {
                playing = true
                CallsTones.shared.play( .speakerTest ) { [weak self] in
                    self?.playing = false
                    self?.refresh()
                }
            }
        }

        refresh()
    }

    private func stopCameraTest() {
        guard testingCamera else { return }

        testingCamera = false
        preview.stop( nil )
    }

    private func stopMicrophoneTest() {
        guard testingMicrophone else { return }

        testingMicrophone = false
        microphoneTest.stop()
    }

    // MARK: Choosing

    /// The system's list of outputs, where AirPlay and every paired device are.
    private func openOutputs() {
        for view in routePicker.subviews {
            guard let button = view as? UIButton else { continue }
            button.sendActions( for: .touchUpInside )
            break
        }
    }

    private func choose( _ id: String, of kind: Kind ) {
        switch kind {
        case .camera:
            let front = id == "front"
            previewFront = front
            onChooseCamera?( front )

            if testingCamera {
                preview.start( front: front ) { [weak self] _ in self?.refresh() }
            }
        case .microphone:
            let session = AVAudioSession.sharedInstance()
            if let input = session.availableInputs?.first( where: { $0.uid == id } ) {
                do {
                    try session.setPreferredInput( input )
                } catch {
                    CallsLog.write( "devices: input not set: \( error )" )
                }
            }
        case .speaker:
            break
        }

        refresh()
    }

    // MARK: Drawing

    /// Everything again from what the call says now: after a dock press, a moderator's act, a route change.
    func refresh() {
        guard !closing, let ctx = context() else { return }

        // Gone live from the dock: the test is over, and does not open the device again once it is turned off.
        if ctx.cameraOn { stopCameraTest() }
        // And a microphone test ends once the host no longer allows it (the call's session taken away, on hold).
        if ctx.microphoneOn || ctx.micHeld || !CallsEngine.shared.testsMicrophone { stopMicrophoneTest() }

        if !testingCamera { cameraDenied = CallsDeviceTests.cameraDenied }
        if !testingMicrophone { microphoneDenied = CallsDeviceTests.microphoneDenied }

        let peer = ctx.group ? nil : ( ctx.peerName.isEmpty ? nil : ctx.peerName )

        if let row = cameraRow {
            let front = ctx.cameraOn ? ctx.front : previewFront
            var model = CallsDeviceRow.Model(
                icon: ctx.cameraOn ? CallsIcons.video : CallsIcons.videoOff,
                label: CallsTheme.string( "device_camera", fallback: "Camera" ),
                current: front ? Self.frontName : Self.backName,
                choices: [ ( "front", Self.frontName, front ), ( "back", Self.backName, !front ) ],
                live: ctx.cameraOn,
                test: nil,
                note: nil,
                meter: nil,
                state: ctx.cameraOn
                    ? Self.named( peer, "person_sees_you", "%s sees you", "everyone_sees_you", "Everyone sees you" )
                    : CallsTheme.string( "nobody_sees_you", fallback: "Nobody sees you" ),
                previewing: testingCamera
            )

            if cameraDenied {
                model.note = ( CallsTheme.string( "camera_denied", fallback: "No permission to access the camera. Please allow it in the app settings." ), .warning )
            } else if !ctx.cameraOn, ctx.mayPublish, CallsEngine.shared.testsCamera {
                model.test = ( CallsTheme.string( "device_preview", fallback: "Preview" ), testingCamera )
            }

            row.apply( model )
        }

        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        let input = session.currentRoute.inputs.first
        let inputName = input?.portName ?? inputs.first?.portName ?? CallsTheme.string( "device_microphone", fallback: "Microphone" )

        var mic = CallsDeviceRow.Model(
            icon: ctx.microphoneOn ? CallsIcons.mic : CallsIcons.micOff,
            label: CallsTheme.string( "device_microphone", fallback: "Microphone" ),
            current: inputName,
            choices: inputs.count > 1 ? inputs.map { ( $0.uid, $0.portName, $0.uid == input?.uid ) } : [],
            live: ctx.microphoneOn,
            test: nil,
            note: nil,
            meter: nil,
            state: ctx.microphoneOn
                ? Self.named( peer, "person_hears_you", "%s hears you", "everyone_hears_you", "Everyone hears you" )
                : CallsTheme.string( "nobody_hears_you", fallback: "Nobody hears you" ),
            previewing: false
        )

        if ctx.microphoneOn {
            mic.meter = ctx.sendingLevel != nil ? "" : nil
        } else if microphoneDenied {
            mic.note = ( CallsTheme.string( "microphone_denied", fallback: "No permission to access the microphone. Please allow it in the app settings." ), .warning )
        } else if testingMicrophone {
            mic.meter = CallsTheme.string( "speak_to_test", fallback: "Speak to test. Nobody hears it." )
        } else if ctx.micHeld, ctx.mayPublish {
            mic.note = ( CallsTheme.string( "moderator_muted_you", fallback: "A moderator muted your microphone." ), .off )
        } else if ctx.talkingMuted {
            mic.note = ( CallsTheme.string( "you_are_muted", fallback: "You are muted" ), .talking )
        }

        if !ctx.microphoneOn, !microphoneDenied, !ctx.micHeld, ctx.mayPublish, CallsEngine.shared.testsMicrophone {
            mic.test = ( CallsTheme.string( "device_test", fallback: "Test" ), testingMicrophone )
        }

        microphoneRow.apply( mic )

        let output = session.currentRoute.outputs.first
        speakerRow.apply( CallsDeviceRow.Model(
            icon: CallsIcons.speaker,
            label: CallsTheme.string( "speaker", fallback: "Speaker" ),
            current: output?.portName ?? CallsTheme.string( "speaker", fallback: "Speaker" ),
            choices: [],
            live: false,
            test: ( CallsTheme.string( "device_test", fallback: "Test" ), playing ),
            note: nil,
            meter: nil,
            state: nil,
            previewing: false,
            chooses: true
        ) )

        let metering = mic.meter != nil

        if metering, meterTimer == nil {
            shownLevel = 0
            meterTimer = Timer.scheduledTimer( withTimeInterval: 0.05, repeats: true ) { [weak self] _ in self?.meter() }
        } else if !metering {
            meterTimer?.invalidate()
            meterTimer = nil
            shownLevel = 0
        }
    }

    /// The level rises at once and falls away over a few readings, twenty a second.
    private func meter() {
        guard let ctx = context() else { return }

        let heard: Float = ctx.microphoneOn ? ( ctx.sendingLevel ?? 0 ) : microphoneTest.level

        shownLevel = max( heard, shownLevel * 0.8 )
        microphoneRow.level( shownLevel )
    }

    private func drawTraffic() {
        guard let traffic else { return }

        let now = traffic()

        trafficLabel.text = CallsTheme.string( "downloaded", fallback: "Downloaded" ) + ": " + Self.size( now.received ) + "    "
            + CallsTheme.string( "uploaded", fallback: "Uploaded" ) + ": " + Self.size( now.sent )
    }

    private static var frontName: String { CallsTheme.string( "front_camera", fallback: "Front Camera" ) }
    private static var backName: String { CallsTheme.string( "back_camera", fallback: "Back Camera" ) }

    /// Who is live to: the other person by name in a call between two, everyone in a group call.
    private static func named( _ peer: String?, _ personKey: String, _ personFallback: String, _ allKey: String, _ allFallback: String ) -> String {
        guard let peer else { return CallsTheme.string( allKey, fallback: allFallback ) }

        return CallsTheme.string( personKey, fallback: personFallback ).replacingOccurrences( of: "%s", with: peer )
    }

    /// The web's `filesize`: powers of 1024, one decimal above a kilobyte.
    static func size( _ bytes: Int ) -> String {
        if bytes < 1024 { return "\( bytes ) B" }

        let units = [ "KB", "MB", "GB", "TB" ]
        var value = Double( bytes ) / 1024
        var unit = 0

        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }

        return String( format: "%.1f %@", value, units[ unit ] )
    }

    static func padded( _ view: UIView, _ inset: UIEdgeInsets ) -> UIView {
        let holder = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview( view )

        NSLayoutConstraint.activate( [
            view.topAnchor.constraint( equalTo: holder.topAnchor, constant: inset.top ),
            view.bottomAnchor.constraint( equalTo: holder.bottomAnchor, constant: -inset.bottom ),
            view.leadingAnchor.constraint( equalTo: holder.leadingAnchor, constant: inset.left ),
            view.trailingAnchor.constraint( equalTo: holder.trailingAnchor, constant: -inset.right ),
        ] )

        return holder
    }
}

/// A quiet note in a row: a device the phone refuses (warning), a microphone a moderator holds (off), talking while
/// muted (talking, pulsing). `.wplus-call-device-note`.
enum CallsDeviceNoteTone { case warning, off, talking }

/// One device: its glyph and name with its test on the end of that line, under them a field with the device in use,
/// then a status, the camera's preview and whether the others see or hear it.
final class CallsDeviceRow: UIView {
    struct Model {
        var icon: String
        var label: String
        var current: String
        var choices: [ ( id: String, name: String, selected: Bool ) ]
        var live: Bool
        /// The test button's label and whether it runs; nil for none.
        var test: ( String, Bool )?
        var note: ( String, CallsDeviceNoteTone )?
        /// The meter, with the words beside it ("" for none); nil for no meter.
        var meter: String?
        var state: String?
        var previewing: Bool
        /// The field opens a list even with no choices of ours (the system's route picker).
        var chooses = false
    }

    let kind: CallsDevices.Kind
    var onTest: ( () -> Void )?
    var onCurrent: ( () -> Void )?
    var onChoose: ( ( String ) -> Void )?
    weak var preview: CallsCameraPreview? {
        didSet { attachPreview() }
    }

    var menuOpen: Bool { current.menuOpen }

    private static let steps: [ Float ] = [ 0.25, 0.34, 0.44, 0.53, 0.62, 0.71, 0.81, 0.90 ]

    private let glyph = CallsIconView( CallsIcons.mic )
    private let label = UILabel()
    private let current = CallsDeviceField()
    private let reading = UIStackView()
    private let note = UIView()
    private let noteGlyph = CallsIconView( CallsIcons.alert )
    private let noteText = UILabel()
    private let meterLine = UIStackView()
    private var segments: [ UIView ] = []
    private let meterWords = UILabel()
    private let test = UIControl()
    private let testGlyph = CallsIconView( CallsIcons.play )
    private let testLabel = UILabel()
    private let previewHolder = UIView()
    private let badge = UIView()
    private let stateLine = UIStackView()
    private let dot = UIView()
    private let livePill = UILabel()
    private let stateText = UILabel()
    private var drawnList = ""

    init( kind: CallsDevices.Kind ) {
        self.kind = kind

        super.init( frame: .zero )

        let column = UIStackView()
        column.axis = .vertical
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview( column )

        NSLayoutConstraint.activate( [
            column.topAnchor.constraint( equalTo: topAnchor ),
            column.bottomAnchor.constraint( equalTo: bottomAnchor ),
            column.leadingAnchor.constraint( equalTo: leadingAnchor ),
            column.trailingAnchor.constraint( equalTo: trailingAnchor ),
        ] )

        // The head: the glyph, the name, and the test on the end of the line.
        glyph.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont( ofSize: 13, weight: .semibold )
        label.textColor = .white
        label.setContentHuggingPriority( .defaultLow, for: .horizontal )
        label.setContentCompressionResistancePriority( .defaultLow, for: .horizontal )

        current.addTarget( self, action: #selector( currentTapped ), for: .touchUpInside )

        note.layer.cornerRadius = 6
        note.layer.cornerCurve = .continuous
        noteText.font = .systemFont( ofSize: 11.5 )
        noteText.numberOfLines = 0
        noteText.setContentCompressionResistancePriority( .defaultLow, for: .horizontal )
        noteText.translatesAutoresizingMaskIntoConstraints = false
        note.addSubview( noteGlyph )
        note.addSubview( noteText )

        // The words under the meter: beside it they broke into three lines on a phone.
        meterLine.axis = .vertical
        meterLine.alignment = .leading
        meterLine.spacing = 0
        let bars = UIStackView()
        bars.axis = .horizontal
        bars.spacing = 3
        bars.alignment = .center
        for _ in Self.steps {
            let segment = UIView()
            segment.layer.cornerRadius = 2
            segment.backgroundColor = UIColor( white: 1, alpha: 0.16 )
            segment.translatesAutoresizingMaskIntoConstraints = false
            segment.widthAnchor.constraint( equalToConstant: 10 ).isActive = true
            segment.heightAnchor.constraint( equalToConstant: 5 ).isActive = true
            segments.append( segment )
            bars.addArrangedSubview( segment )
        }
        bars.heightAnchor.constraint( equalToConstant: 18 ).isActive = true
        meterWords.font = .systemFont( ofSize: 11.5 )
        meterWords.textColor = UIColor( white: 1, alpha: 0.6 )
        meterWords.numberOfLines = 0
        meterWords.setContentCompressionResistancePriority( .defaultLow, for: .horizontal )
        meterLine.addArrangedSubview( bars )
        meterLine.addArrangedSubview( meterWords )

        test.layer.cornerRadius = 14
        test.translatesAutoresizingMaskIntoConstraints = false
        testLabel.font = .systemFont( ofSize: 12, weight: .medium )
        testLabel.translatesAutoresizingMaskIntoConstraints = false
        // The name over the field takes the rest of the line, never the test.
        testLabel.setContentHuggingPriority( .required, for: .horizontal )
        testLabel.setContentCompressionResistancePriority( .required, for: .horizontal )
        test.addSubview( testGlyph )
        test.addSubview( testLabel )
        test.addTarget( self, action: #selector( testTapped ), for: .touchUpInside )
        test.isAccessibilityElement = true
        test.accessibilityTraits = .button
        test.setContentHuggingPriority( .required, for: .horizontal )
        test.setContentCompressionResistancePriority( .required, for: .horizontal )

        let head = UIStackView( arrangedSubviews: [ glyph, label, test ] )
        head.axis = .horizontal
        head.alignment = .center
        head.spacing = 8
        head.isLayoutMarginsRelativeArrangement = true
        head.directionalLayoutMargins = NSDirectionalEdgeInsets( top: 6, leading: 8, bottom: 4, trailing: 8 )
        column.addArrangedSubview( head )

        // The device in use, the width of the row.
        column.addArrangedSubview( CallsDevices.padded( current, UIEdgeInsets( top: 0, left: 8, bottom: 8, right: 8 ) ) )

        // The microphone's level, or why it is off, under the field.
        reading.axis = .vertical
        reading.alignment = .leading
        reading.spacing = 2
        reading.isLayoutMarginsRelativeArrangement = true
        reading.directionalLayoutMargins = NSDirectionalEdgeInsets( top: 0, leading: 8, bottom: 8, trailing: 8 )
        reading.addArrangedSubview( note )
        reading.addArrangedSubview( meterLine )
        column.addArrangedSubview( reading )

        // The camera's preview.
        previewHolder.backgroundColor = .black
        previewHolder.layer.cornerRadius = 10
        previewHolder.layer.cornerCurve = .continuous
        previewHolder.clipsToBounds = true
        previewHolder.translatesAutoresizingMaskIntoConstraints = false
        badge.backgroundColor = UIColor( white: 0, alpha: 0.6 )
        badge.layer.cornerRadius = 11
        badge.translatesAutoresizingMaskIntoConstraints = false
        let lock = CallsIconView( CallsIcons.padlock )
        lock.color = UIColor( white: 1, alpha: 0.92 )
        let badgeText = UILabel()
        badgeText.text = CallsTheme.string( "only_you_see_this", fallback: "Only you see this" )
        badgeText.font = .systemFont( ofSize: 11, weight: .semibold )
        badgeText.textColor = UIColor( white: 1, alpha: 0.92 )
        badgeText.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview( lock )
        badge.addSubview( badgeText )
        previewHolder.addSubview( badge )
        let previewSlot = CallsDevices.padded( previewHolder, UIEdgeInsets( top: 0, left: 8, bottom: 8, right: 8 ) )
        column.addArrangedSubview( previewSlot )

        // Whether the others see or hear it.
        dot.layer.cornerRadius = 4
        dot.layer.borderWidth = 1.5
        dot.layer.borderColor = UIColor( white: 1, alpha: 0.5 ).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        livePill.text = " " + CallsTheme.string( "device_live", fallback: "Live" ).uppercased() + " "
        livePill.font = .systemFont( ofSize: 10, weight: .bold )
        livePill.textColor = .white
        livePill.backgroundColor = CallsTheme.recording
        livePill.layer.cornerRadius = 4
        livePill.clipsToBounds = true
        livePill.textAlignment = .center
        livePill.translatesAutoresizingMaskIntoConstraints = false
        let liveKern = NSMutableAttributedString( string: livePill.text ?? "" )
        liveKern.addAttribute( .kern, value: 0.5, range: NSRange( location: 0, length: liveKern.length ) )
        livePill.attributedText = liveKern
        stateText.font = .systemFont( ofSize: 12 )
        stateText.numberOfLines = 0
        stateText.setContentCompressionResistancePriority( .defaultLow, for: .horizontal )
        stateLine.addArrangedSubview( dot )
        stateLine.addArrangedSubview( livePill )
        stateLine.addArrangedSubview( stateText )
        stateLine.setCustomSpacing( 8, after: livePill )
        stateLine.axis = .horizontal
        stateLine.alignment = .center
        stateLine.spacing = 6
        stateLine.isLayoutMarginsRelativeArrangement = true
        stateLine.directionalLayoutMargins = NSDirectionalEdgeInsets( top: 0, leading: 8, bottom: 8, trailing: 8 )
        column.addArrangedSubview( stateLine )

        NSLayoutConstraint.activate( [
            // The height the test gives the line, so the row does not move as the test goes once the device is live.
            head.heightAnchor.constraint( greaterThanOrEqualToConstant: 38 ),
            glyph.widthAnchor.constraint( equalToConstant: 16 ),
            glyph.heightAnchor.constraint( equalToConstant: 16 ),

            noteGlyph.leadingAnchor.constraint( equalTo: note.leadingAnchor, constant: 8 ),
            noteGlyph.topAnchor.constraint( equalTo: note.topAnchor, constant: 4 ),
            noteGlyph.widthAnchor.constraint( equalToConstant: 13 ),
            noteGlyph.heightAnchor.constraint( equalToConstant: 13 ),
            noteText.leadingAnchor.constraint( equalTo: noteGlyph.trailingAnchor, constant: 5 ),
            noteText.trailingAnchor.constraint( equalTo: note.trailingAnchor, constant: -8 ),
            noteText.topAnchor.constraint( equalTo: note.topAnchor, constant: 3 ),
            noteText.bottomAnchor.constraint( equalTo: note.bottomAnchor, constant: -3 ),

            test.heightAnchor.constraint( equalToConstant: 28 ),
            testGlyph.leadingAnchor.constraint( equalTo: test.leadingAnchor, constant: 11 ),
            testGlyph.centerYAnchor.constraint( equalTo: test.centerYAnchor ),
            testGlyph.widthAnchor.constraint( equalToConstant: 12 ),
            testGlyph.heightAnchor.constraint( equalToConstant: 12 ),
            testLabel.leadingAnchor.constraint( equalTo: testGlyph.trailingAnchor, constant: 5 ),
            testLabel.trailingAnchor.constraint( equalTo: test.trailingAnchor, constant: -11 ),
            testLabel.centerYAnchor.constraint( equalTo: test.centerYAnchor ),

            previewHolder.heightAnchor.constraint( equalTo: previewHolder.widthAnchor, multiplier: 9.0 / 16.0 ),
            badge.topAnchor.constraint( equalTo: previewHolder.topAnchor, constant: 8 ),
            badge.leadingAnchor.constraint( equalTo: previewHolder.leadingAnchor, constant: 8 ),
            badge.heightAnchor.constraint( equalToConstant: 22 ),
            lock.leadingAnchor.constraint( equalTo: badge.leadingAnchor, constant: 9 ),
            lock.centerYAnchor.constraint( equalTo: badge.centerYAnchor ),
            lock.widthAnchor.constraint( equalToConstant: 12 ),
            lock.heightAnchor.constraint( equalToConstant: 12 ),
            badgeText.leadingAnchor.constraint( equalTo: lock.trailingAnchor, constant: 5 ),
            badgeText.trailingAnchor.constraint( equalTo: badge.trailingAnchor, constant: -9 ),
            badgeText.centerYAnchor.constraint( equalTo: badge.centerYAnchor ),

            dot.widthAnchor.constraint( equalToConstant: 8 ),
            dot.heightAnchor.constraint( equalToConstant: 8 ),
            livePill.heightAnchor.constraint( equalToConstant: 16 ),
            stateText.heightAnchor.constraint( greaterThanOrEqualToConstant: 16 ),
        ] )

        previewSlot.isHidden = true
        self.previewSlot = previewSlot
    }

    private var previewSlot: UIView?

    required init?( coder: NSCoder ) { fatalError( "init(coder:) has not been implemented" ) }

    private func attachPreview() {
        guard let preview else { return }

        preview.translatesAutoresizingMaskIntoConstraints = false
        previewHolder.insertSubview( preview, at: 0 )

        NSLayoutConstraint.activate( [
            preview.topAnchor.constraint( equalTo: previewHolder.topAnchor ),
            preview.bottomAnchor.constraint( equalTo: previewHolder.bottomAnchor ),
            preview.leadingAnchor.constraint( equalTo: previewHolder.leadingAnchor ),
            preview.trailingAnchor.constraint( equalTo: previewHolder.trailingAnchor ),
        ] )
    }

    func apply( _ model: Model ) {
        let accent = CallsTheme.accent

        glyph.set( model.icon )
        glyph.color = model.live ? accent : UIColor( white: 1, alpha: 0.6 )

        label.text = model.label
        current.name.text = model.current
        current.opens = !model.choices.isEmpty || model.chooses
        current.accessibilityLabel = model.label
        current.accessibilityValue = model.current

        // Only where the list changed: this runs on every dock press and route change, with the menu perhaps open.
        let listed = model.choices.map { "\( $0.id )|\( $0.name )|\( $0.selected )" }.joined( separator: "\n" )

        if listed != drawnList {
            drawnList = listed
            current.menu = model.choices.isEmpty ? nil : menu( model.choices )
            current.showsMenuAsPrimaryAction = !model.choices.isEmpty
        }

        if let ( words, tone ) = model.note {
            note.isHidden = false
            noteText.text = words
            note.layer.removeAnimation( forKey: "talking" )

            switch tone {
            case .warning:
                note.backgroundColor = CallsTheme.warning.withAlphaComponent( 0.14 )
                noteText.textColor = UIColor( white: 1, alpha: 0.9 )
                noteText.font = .systemFont( ofSize: 11.5 )
                noteGlyph.set( CallsIcons.alert )
                noteGlyph.color = CallsTheme.warning
            case .off:
                note.backgroundColor = CallsTheme.recording.withAlphaComponent( 0.16 )
                noteText.textColor = UIColor( red: 1, green: 170 / 255, blue: 160 / 255, alpha: 1 )
                noteText.font = .systemFont( ofSize: 11.5 )
                noteGlyph.set( CallsIcons.silenced )
                noteGlyph.color = noteText.textColor
            case .talking:
                note.backgroundColor = CallsTheme.warning.withAlphaComponent( 0.22 )
                noteText.textColor = .white
                noteText.font = .systemFont( ofSize: 11.5, weight: .semibold )
                noteGlyph.set( CallsIcons.micOff )
                noteGlyph.color = CallsTheme.warning

                if !UIAccessibility.isReduceMotionEnabled {
                    let pulse = CABasicAnimation( keyPath: "backgroundColor" )
                    pulse.fromValue = CallsTheme.warning.withAlphaComponent( 0.22 ).cgColor
                    pulse.toValue = CallsTheme.warning.withAlphaComponent( 0.38 ).cgColor
                    pulse.duration = 0.6
                    pulse.autoreverses = true
                    pulse.repeatCount = .infinity
                    note.layer.add( pulse, forKey: "talking" )
                }
            }
        } else {
            note.isHidden = true
        }

        if let words = model.meter {
            meterLine.isHidden = false
            meterWords.text = words
            meterWords.isHidden = words.isEmpty
        } else {
            meterLine.isHidden = true
            level( 0 )
        }

        reading.isHidden = note.isHidden && meterLine.isHidden

        if let ( words, running ) = model.test {
            test.isHidden = false
            testLabel.text = running ? CallsTheme.string( "device_stop", fallback: "Stop" ) : words
            testGlyph.set( running ? CallsIcons.close : CallsIcons.play )
            test.backgroundColor = running ? accent.withAlphaComponent( 0.25 ) : UIColor( white: 1, alpha: 0.1 )
            testLabel.textColor = running ? accent : UIColor( white: 1, alpha: 0.92 )
            testGlyph.color = testLabel.textColor
            test.accessibilityLabel = testLabel.text
        } else {
            test.isHidden = true
        }

        previewSlot?.isHidden = !model.previewing

        if let state = model.state {
            stateLine.isHidden = false
            stateText.text = state
            stateText.textColor = UIColor( white: 1, alpha: model.live ? 0.95 : 0.7 )
            dot.isHidden = model.live
            livePill.isHidden = !model.live
        } else {
            stateLine.isHidden = true
        }
    }

    /// Lit from the left at the web's steps.
    func level( _ value: Float ) {
        for ( index, segment ) in segments.enumerated() {
            segment.backgroundColor = value >= Self.steps[ index ] ? CallsTheme.success : UIColor( white: 1, alpha: 0.16 )
        }
    }

    /// The system's own menu of the devices, the one in use ticked.
    private func menu( _ choices: [ ( id: String, name: String, selected: Bool ) ] ) -> UIMenu {
        UIMenu( children: choices.map { choice in
            UIAction( title: choice.name, state: choice.selected ? .on : .off ) { [weak self] _ in self?.onChoose?( choice.id ) }
        } )
    }

    @objc private func testTapped() { onTest?() }
    @objc private func currentTapped() { onCurrent?() }
}

/// The device in use, `.wplus-call-device-current`: a field the width of the row with its arrow on the end, which opens
/// the others. A line of quiet text here read as a caption under the name, and people did not find where to choose a
/// device. With nothing to open it is plain text, level with the name over it. 40 tall where the web's is 32, for a
/// finger.
final class CallsDeviceField: UIButton {
    let name = UILabel()
    private let arrow = CallsIconView( CallsIcons.chevronDown )
    private var height: NSLayoutConstraint?
    private var start: NSLayoutConstraint?

    /// From the menu showing until it has gone.
    private(set) var menuOpen = false

    var opens = true {
        didSet { paint() }
    }

    override var isHighlighted: Bool {
        didSet { paint() }
    }

    override func contextMenuInteraction( _ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating? ) {
        super.contextMenuInteraction( interaction, willDisplayMenuFor: configuration, animator: animator )
        menuOpen = true
    }

    override func contextMenuInteraction( _ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating? ) {
        super.contextMenuInteraction( interaction, willEndFor: configuration, animator: animator )

        guard let animator else {
            menuOpen = false
            return
        }

        animator.addCompletion { [weak self] in self?.menuOpen = false }
    }

    init() {
        super.init( frame: .zero )

        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        // The menu comes in the settings' own dark, whatever the phone is set to.
        overrideUserInterfaceStyle = .dark

        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        arrow.color = UIColor( white: 1, alpha: 0.7 )
        arrow.isUserInteractionEnabled = false
        arrow.translatesAutoresizingMaskIntoConstraints = false
        addSubview( name )
        addSubview( arrow )

        let height = heightAnchor.constraint( equalToConstant: 40 )
        let start = name.leadingAnchor.constraint( equalTo: leadingAnchor, constant: 10 )
        self.height = height
        self.start = start

        NSLayoutConstraint.activate( [
            height,
            start,
            name.centerYAnchor.constraint( equalTo: centerYAnchor ),
            name.trailingAnchor.constraint( lessThanOrEqualTo: arrow.leadingAnchor, constant: -6 ),
            arrow.trailingAnchor.constraint( equalTo: trailingAnchor, constant: -8 ),
            arrow.centerYAnchor.constraint( equalTo: centerYAnchor ),
            arrow.widthAnchor.constraint( equalToConstant: 14 ),
            arrow.heightAnchor.constraint( equalToConstant: 14 ),
        ] )

        paint()
    }

    required init?( coder: NSCoder ) { fatalError( "init(coder:) has not been implemented" ) }

    private func paint() {
        height?.constant = opens ? 40 : 18
        start?.constant = opens ? 10 : 24
        arrow.isHidden = !opens
        isUserInteractionEnabled = opens
        accessibilityTraits = opens ? .button : .staticText

        name.font = .systemFont( ofSize: opens ? 13 : 12 )
        name.textColor = UIColor( white: 1, alpha: opens ? 0.92 : 0.6 )

        backgroundColor = opens ? UIColor( white: 1, alpha: isHighlighted ? 0.1 : 0.06 ) : .clear
        layer.borderWidth = opens ? 1 : 0
        layer.borderColor = UIColor( white: 1, alpha: isHighlighted ? 0.28 : 0.16 ).cgColor
    }
}

/// Done: a full-width pill, `.wplus-call-devices-done`.
final class CallsDevicePill: UIControl {
    private let label = UILabel()
    private let fill: UIColor
    private let pressedFill: UIColor

    init( title: String, fill: UIColor = UIColor( white: 1, alpha: 0.1 ), ink: UIColor = UIColor( white: 1, alpha: 0.95 ), height: CGFloat = 38 ) {
        self.fill = fill
        pressedFill = fill.withAlphaComponent( min( 1, fill.cgColor.alpha + 0.06 ) )

        super.init( frame: .zero )

        backgroundColor = fill
        layer.cornerRadius = height / 2

        label.text = title
        label.font = .systemFont( ofSize: 13, weight: .semibold )
        label.textColor = ink
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview( label )

        NSLayoutConstraint.activate( [
            heightAnchor.constraint( equalToConstant: height ),
            label.centerXAnchor.constraint( equalTo: centerXAnchor ),
            label.centerYAnchor.constraint( equalTo: centerYAnchor ),
            label.leadingAnchor.constraint( greaterThanOrEqualTo: leadingAnchor, constant: 14 ),
            label.trailingAnchor.constraint( lessThanOrEqualTo: trailingAnchor, constant: -14 ),
        ] )

        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button

        addTarget( self, action: #selector( down ), for: [ .touchDown, .touchDragEnter ] )
        addTarget( self, action: #selector( up ), for: [ .touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit ] )
    }

    required init?( coder: NSCoder ) { fatalError( "init(coder:) has not been implemented" ) }

    func setTitle( _ title: String ) {
        label.text = title
        accessibilityLabel = title
    }

    @objc private func down() { backgroundColor = pressedFill }
    @objc private func up() { backgroundColor = fill }
}

// MARK: - The tests

enum CallsDeviceTests {
    /// What the phone says, unless set: the package's own tests draw the panel with it.
    static var denied: ( camera: Bool, microphone: Bool )?

    static var cameraDenied: Bool {
        if let denied { return denied.camera }

        let status = AVCaptureDevice.authorizationStatus( for: .video )
        return status == .denied || status == .restricted
    }

    static var microphoneDenied: Bool {
        if let denied { return denied.microphone }

        return AVAudioSession.sharedInstance().recordPermission == .denied
    }
}

/// The camera, for the user's eyes alone: a capture session of its own with its picture on a preview layer, never a
/// track, so nothing of it can reach the call. It runs only while the call's own camera is off, and lets go of the
/// camera before the call's capture opens it (`release`): two sessions on one camera interrupt each other. Not
/// mirrored, the front camera included: the user sees what the others would, as every call picture is drawn.
final class CallsCameraPreview: UIView {
    private let queue = DispatchQueue( label: "calls.devices.preview" )
    private var session: AVCaptureSession?
    private var generation = 0
    /// Started and not stopped since: its session may still be opening.
    private var held = false

    private static let all = NSHashTable<CallsCameraPreview>.weakObjects()

    /// Whether a preview holds the camera, or is opening it.
    static var isHeld: Bool {
        all.allObjects.contains { $0.held }
    }

    /// Every preview stopped, and `then` once the camera is let go of: for the call's own capture, before it opens.
    static func release( _ then: @escaping () -> Void ) {
        let group = DispatchGroup()

        for preview in all.allObjects {
            group.enter()
            preview.stop { group.leave() }
        }

        group.notify( queue: .main, execute: then )
    }

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override init( frame: CGRect ) {
        super.init( frame: frame )
        previewLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black
    }

    required init?( coder: NSCoder ) { fatalError( "init(coder:) has not been implemented" ) }

    /// Asks for the camera where it was never asked, then shows it: `done(false)` where it is refused or missing.
    func start( front: Bool, done: @escaping ( Bool ) -> Void ) {
        switch AVCaptureDevice.authorizationStatus( for: .video ) {
        case .authorized:
            open( front: front, done: done )
        case .notDetermined:
            AVCaptureDevice.requestAccess( for: .video ) { [weak self] granted in
                DispatchQueue.main.async {
                    guard granted else { return done( false ) }
                    self?.open( front: front, done: done )
                }
            }
        default:
            done( false )
        }
    }

    /// Everything on one serial queue: a stop queued after an open runs once the open has finished, and finds its
    /// session either handed over here or already stopped by the open itself.
    private func open( front: Bool, done: @escaping ( Bool ) -> Void ) {
        generation += 1
        held = true
        Self.all.add( self )

        let mine = generation
        let old = session

        queue.async { [weak self] in
            old?.stopRunning()

            let current: () -> Bool = { DispatchQueue.main.sync { self?.generation == mine } }

            guard current() else { return }

            let session = AVCaptureSession()
            session.sessionPreset = .medium

            guard let device = AVCaptureDevice.default( .builtInWideAngleCamera, for: .video, position: front ? .front : .back ),
                  let input = try? AVCaptureDeviceInput( device: device ),
                  session.canAddInput( input ) else {
                DispatchQueue.main.async {
                    if self?.generation == mine { self?.held = false }
                    done( false )
                }
                return
            }

            session.addInput( input )

            let kept: Bool = DispatchQueue.main.sync {
                guard let self, self.generation == mine else { return false }
                self.session = session
                self.previewLayer.session = session
                self.unmirror()
                return true
            }

            guard kept else { return }

            session.startRunning()

            // Stopped while it was starting: its stop found no session to stop, so this one stops it.
            guard current() else {
                session.stopRunning()
                return
            }

            DispatchQueue.main.async { done( true ) }
        }
    }

    /// Stopped, and `then` once the camera is let go of.
    func stop( _ then: ( () -> Void )? ) {
        generation += 1
        held = false

        let old = session
        session = nil
        previewLayer.session = nil

        queue.async {
            old?.stopRunning()
            DispatchQueue.main.async { then?() }
        }
    }

    /// The layer mirrors the front camera unless told not to.
    private func unmirror() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }

        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = false
    }
}

/// The microphone, heard for the user alone: a recorder kept to its level, writing nowhere anyone reads, in the call's
/// own audio session as it is. It runs only while the call does not send the microphone, and only into a session
/// already set for recording: a recorder never sets the session's category or mode, and the host offers the test only
/// while the call's session is live (`CallsEngine.testsMicrophone`), so it adds a listener and changes nothing else.
final class CallsMicrophoneTest {
    private var recorder: AVAudioRecorder?
    private var file: URL?

    /// 0…1, as loud as the last reading.
    var level: Float {
        guard let recorder, recorder.isRecording else { return 0 }

        recorder.updateMeters()

        let power = recorder.averagePower( forChannel: 0 )

        return max( 0, min( 1, ( power + 55 ) / 50 ) )
    }

    func start( done: @escaping ( Bool ) -> Void ) {
        let session = AVAudioSession.sharedInstance()

        switch session.recordPermission {
        case .granted:
            done( open() )
        case .undetermined:
            session.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    done( granted && ( self?.open() ?? false ) )
                }
            }
        default:
            done( false )
        }
    }

    private func open() -> Bool {
        let category = AVAudioSession.sharedInstance().category

        // A session the call set up for playing alone would need setting up again to record, which is the call's.
        guard category == .playAndRecord || category == .record else {
            CallsLog.write( "devices: the session does not record (\( category.rawValue )): no microphone test" )
            return false
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent( "calls-microphone-test.caf" )
        let settings: [ String: Any ] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]

        guard let recorder = try? AVAudioRecorder( url: url, settings: settings ) else { return false }

        recorder.isMeteringEnabled = true

        guard recorder.record() else {
            CallsLog.write( "devices: the microphone test did not start" )
            return false
        }

        self.recorder = recorder
        file = url

        return true
    }

    func stop() {
        recorder?.stop()
        recorder = nil

        if let file { try? FileManager.default.removeItem( at: file ) }
        file = nil
    }
}

/// Short sine notes through the call's audio session and route as they are: the speaker's test and the chime of a
/// raised hand.
final class CallsTones {
    static let shared = CallsTones()

    enum Tune {
        /// Three rising notes, 0.22 s apart, each half a second.
        case speakerTest
        /// Two notes, 0.14 s apart, each 0.3 s, quieter.
        case hand
    }

    private var player: AVAudioPlayer?
    private var finished: ( () -> Void )?
    private var timer: Timer?

    func play( _ tune: Tune, done: ( () -> Void )? = nil ) {
        stop()

        let notes: [ ( frequency: Double, start: Double ) ]
        let length: Double
        let peak: Double

        switch tune {
        case .speakerTest:
            notes = [ ( 523.25, 0 ), ( 659.25, 0.22 ), ( 783.99, 0.44 ) ]
            length = 0.5
            peak = 0.18
        case .hand:
            notes = [ ( 660, 0 ), ( 880, 0.14 ) ]
            length = 0.3
            peak = 0.08
        }

        let data = Self.wave( notes: notes, length: length, peak: peak )

        guard let player = try? AVAudioPlayer( data: data ) else {
            done?()
            return
        }

        self.player = player
        finished = done
        player.prepareToPlay()
        player.play()

        timer = Timer.scheduledTimer( withTimeInterval: player.duration + 0.05, repeats: false ) { [weak self] _ in
            self?.stop()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil

        let finished = finished
        self.finished = nil
        finished?()
    }

    /// A WAV of the notes, each a 20 ms rise to `peak` and an exponential fall over the rest of `length`.
    static func wave( notes: [ ( frequency: Double, start: Double ) ], length: Double, peak: Double ) -> Data {
        let rate = 44100.0
        let total = ( notes.map { $0.start }.max() ?? 0 ) + length
        let count = Int( total * rate )
        var samples = [ Double ]( repeating: 0, count: count )

        for note in notes {
            let first = Int( note.start * rate )
            let span = Int( length * rate )

            for index in 0 ..< span where first + index < count {
                let t = Double( index ) / rate
                let gain: Double

                if t < 0.02 {
                    gain = peak * t / 0.02
                } else {
                    gain = peak * pow( 0.0001 / peak, ( t - 0.02 ) / ( length - 0.02 ) )
                }

                samples[ first + index ] += gain * sin( 2 * .pi * note.frequency * t )
            }
        }

        var data = Data()
        let bytes = count * 2

        func put<T>( _ value: T ) {
            withUnsafeBytes( of: value ) { data.append( contentsOf: $0 ) }
        }

        data.append( contentsOf: Array( "RIFF".utf8 ) )
        put( UInt32( 36 + bytes ).littleEndian )
        data.append( contentsOf: Array( "WAVEfmt ".utf8 ) )
        put( UInt32( 16 ).littleEndian )
        put( UInt16( 1 ).littleEndian )
        put( UInt16( 1 ).littleEndian )
        put( UInt32( rate ).littleEndian )
        put( UInt32( rate * 2 ).littleEndian )
        put( UInt16( 2 ).littleEndian )
        put( UInt16( 16 ).littleEndian )
        data.append( contentsOf: Array( "data".utf8 ) )
        put( UInt32( bytes ).littleEndian )

        for sample in samples {
            put( Int16( max( -1, min( 1, sample ) ) * Double( Int16.max ) ).littleEndian )
        }

        return data
    }
}
