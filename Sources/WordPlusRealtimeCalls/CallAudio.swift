import Foundation
#if os(iOS)
import AVFoundation
import LiveKit
import LiveKitWebRTC

/// The audio session, which belongs to CallKit once `SystemCalls` runs, rather than to us. The same rules as the
/// Better Messages app's (`BmCallsAudio`), whose calls these are.
///
/// The rule that shapes this file: **never call `setActive(true)` while CallKit owns the session**. CallKit activates
/// the session when the call is really starting (after the person has answered on the lock screen, after a cellular
/// call has ended, after the system has decided it is our turn) and hands it over through `provider(_:didActivate:)`.
/// Activating it ourselves takes the session at the wrong moment, and the symptoms are the awkward kind: a call with
/// no sound, a ringtone that keeps playing over it, or audio that dies when a phone call interrupts.
///
/// The category is still ours to set, because only we know whether this is an audio or a video call, and the two want
/// different defaults: a video call belongs on the speaker, an audio call at the ear.
///
/// Without `SystemCalls`, or where CallKit cannot be used (a simulator, mainland China), nothing here changes anything:
/// the stack and LiveKit run the session as they always have.
enum CallAudio {
    /// Whether CallKit owns the session: `SystemCalls` started where CallKit runs.
    private(set) static var callKit = false

    /// Whether the call or stream running now took the session itself.
    private(set) static var ownSession = false

    /// Live streams playing or sending now, which take the session themselves: a stream is no call.
    private static var streams = 0

    /// Bluetooth headsets for calls (HFP), by its value: the newest SDKs renamed the option `allowBluetoothHFP` and
    /// deprecate the old name, which the Xcode an app builds with may not know yet.
    private static let bluetoothHeadsets = AVAudioSession.CategoryOptions(rawValue: 0x4)

    /// Called once, as `SystemCalls` starts where CallKit runs: tells the WebRTC stack to keep its hands off the audio
    /// unit until CallKit says otherwise.
    static func prepareForCallKit() {
        // LiveKit configures `AVAudioSession` itself unless it is told not to, and what it picks depends on whether
        // this side is publishing: `.playAndRecord` while the engine records, `.playback` while it only plays, and
        // `setActive(false)` when it does neither. A group call publishes nothing on the way in, so every remote
        // microphone going on or off moved the category, and the first one to arrive ran `setActive(false)` then
        // `setActive(true)` on a `.playback` session in the middle of a call: a group call was silent on a phone
        // while the same call was fine in a browser (the Better Messages app, which found it). The session is
        // configured in `configure(video:)` and handed over by CallKit, and that is the whole of it.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false

        // Manual mode: WebRTC stops starting and stopping the audio unit on its own. Nothing plays or records until
        // `activated` says so, which is the only way a call and a CallKit session can agree about who owns the
        // microphone.
        let session = LKRTCAudioSession.sharedInstance()
        session.useManualAudio = true
        session.isAudioEnabled = false

        callKit = true
    }

    /// A call the system has not been told of (a ring answered from the app before its push landed, or one CallKit
    /// refused, which is what a Focus that silences calls does) has nobody to hand the session over, and manual mode
    /// then keeps it silent both ways for its whole length. That one call runs the way a device without CallKit does:
    /// the stack drives its own audio unit and the session is ours.
    static func takeSessionWithoutCallKit() {
        guard callKit else { return }

        let rtc = LKRTCAudioSession.sharedInstance()
        ownSession = true
        rtc.useManualAudio = false
        rtc.isAudioEnabled = true

        activate(AVAudioSession.sharedInstance())

        CallLog.write("audio session taken without the system \(state)")
    }

    /// The next call goes back to waiting for CallKit.
    static func giveSessionBackToCallKit() {
        guard callKit, ownSession, streams == 0 else { return }

        ownSession = false

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            CallLog.write("audio session could not be let go of: \(error)")
        }

        let session = LKRTCAudioSession.sharedInstance()
        session.useManualAudio = true
        session.isAudioEnabled = false
    }

    /// Configure, not activate, the session for the call about to run.
    static func configure(video: Bool) {
        guard callKit else { return }

        var options: AVAudioSession.CategoryOptions = [bluetoothHeadsets, .allowBluetoothA2DP, .allowAirPlay]

        // A video call is held away from the face, so it starts on the speaker. An audio call starts at the earpiece
        // and the person moves it if they want to.
        if video { options.insert(.defaultToSpeaker) }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: video ? .videoChat : .voiceChat, options: options)
        } catch {
            // A session that will not take the category still carries the call. It simply routes it less well.
        }

        CallLog.write("audio session \(state)")

        // With CallKit the session is handed over by the system, unless this call took it itself.
        if ownSession { activate(AVAudioSession.sharedInstance()) }
    }

    /// A live stream starts playing or sending. It is no call, so CallKit hands it no session: it takes it, on
    /// `.playback` to watch and `.playAndRecord` to go live.
    static func streamStarted(sending: Bool) {
        guard callKit else { return }

        streams += 1
        do {
            try AVAudioSession.sharedInstance().setCategory(sending ? .playAndRecord : .playback, mode: sending ? .videoChat : .moviePlayback,
                                                            options: sending ? [.defaultToSpeaker, bluetoothHeadsets, .allowBluetoothA2DP] : [])
        } catch {}
        takeSessionWithoutCallKit()
    }

    /// A live stream stopped playing and sending: the session goes back once nothing else holds it.
    static func streamStopped() {
        guard callKit, streams > 0 else { return }

        streams -= 1
        giveSessionBackToCallKit()
    }

    /// CallKit has handed the session over: from here the media may run.
    static func activated(_ session: AVAudioSession) {
        let rtc = LKRTCAudioSession.sharedInstance()

        // The order matters: the stack is told the session is live before the unit is switched on, or it starts
        // against a session it does not yet believe in and the call comes up silent.
        rtc.audioSessionDidActivate(session)
        rtc.isAudioEnabled = true

        CallLog.write("audio session activated \(state)")
    }

    /// CallKit has taken the session back: an interruption, or the end of the call.
    static func deactivated(_ session: AVAudioSession) {
        let rtc = LKRTCAudioSession.sharedInstance()

        rtc.isAudioEnabled = false
        rtc.audioSessionDidDeactivate(session)
    }

    /// A session made active by this app, on the roads where nothing else will. A failure is written down: swallowed,
    /// it was a call nobody could hear with nothing anywhere to say why.
    private static func activate(_ session: AVAudioSession) {
        do {
            try session.setActive(true, options: [])
        } catch {
            CallLog.write("audio session could not be activated: \(error)")
        }
    }

    /// What the session is set to: the only way to tell a call that was handed a `.playAndRecord` session from one
    /// somebody moved to `.playback` underneath it. A silent call looks identical from every other angle.
    static var state: String {
        let session = AVAudioSession.sharedInstance()
        let rtc = LKRTCAudioSession.sharedInstance()

        return "category=\(session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")) " +
            "mode=\(session.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: "")) " +
            "manual=\(rtc.useManualAudio) enabled=\(rtc.isAudioEnabled)"
    }
}

#else

/// macOS has no CallKit, and its calls run the session as they always have: nothing here changes anything.
enum CallAudio {
    static func takeSessionWithoutCallKit() {}
    static func giveSessionBackToCallKit() {}
    static func configure(video: Bool) {}
    static func streamStarted(sending: Bool) {}
    static func streamStopped() {}
}

#endif
