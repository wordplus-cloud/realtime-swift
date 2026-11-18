import Foundation

/// The picture giving way to the sound, a step at a time, on an upload that can't carry both. The browsers' engine does
/// the same with the same numbers, and says why and what was measured (realtime-client, calls/picture-steps.ts).
///
/// The sound comes first while the person talks. The microphone's ceiling gives the camera room; this is the other way
/// round, for the upload where the microphone has come down and is still being lost, or still waits behind the video in
/// the sender's queue: the camera is made smaller until the sound gets through, and never taken away. A step is a ceiling
/// on what the camera sends (the room client's product caps over its cameras), under whatever else holds it.
///
/// - Down: only on a line the sender's estimate says is too narrow for even the first step beside what the microphone
///   puts on the wire, after `down` of the sound suffering, straight to the first step that fits, and no further while
///   the estimate says the line carries it. A line that loses at random loses the sound whatever the picture's size, and
///   an overloaded one brings its estimate down. With the microphone, in the same reading, when it comes down for heavy
///   loss (`giveWay`). One step at a time where there is no estimate.
/// - Up: after `up` of clean sound while the person talks. Silence says nothing of the line, so the picture stays where
///   it is through it. Each step up is on trial for `relapse`: the first reading that says it cost the sound takes it
///   back and doubles the wait for the next, up to `upMax`. A capped sender's estimate stays near one and a half times
///   what it sends whatever the line carries, so it can't say beforehand whether a step up fits.
///
/// An app reads its statistics less often than a browser does, so a step down waits one reading, whose loss is all from
/// after the step before.
final class CallPictureSteps {
    /// A ceiling on what a camera sends: its height in lines, its frames a second, its bitrate in kbps.
    struct Caps: Equatable {
        let height: Int
        let fps: Int
        let kbps: Int
    }

    /// What a reading says of the sound: it suffers, it is clean while the person talks, or it says nothing (silence, no
    /// camera going out, trouble the microphone hasn't answered yet).
    enum Reading {
        case suffering, clean, idle
    }

    /// A camera's steps down.
    static let cameraSteps = [Caps(height: 360, fps: 15, kbps: 150), Caps(height: 180, fps: 10, kbps: 50), Caps(height: 180, fps: 8, kbps: 30)]
    /// How long the sound has to go on suffering before the picture takes a step, or the next one.
    static let down: TimeInterval = 5
    /// How long it has to be clean, the person talking, before a step back up.
    static let up: TimeInterval = 30
    /// A step up that brought the trouble back within this of it is taken back at once, and doubles the wait for the next.
    static let relapse: TimeInterval = 30
    /// The longest such a wait gets.
    static let upMax: TimeInterval = 300
    /// The share of the sender's estimate a step's picture and the microphone may plan on: the rest is what a video
    /// sends beside its picture, again and as padding.
    static let fit = 0.85

    private var at = 0
    /// The readings in a row that said the same, and since when; an idle one breaks neither.
    private var said: Reading?
    private var since = Date.distantPast
    private var upWait = CallPictureSteps.up
    private var liftedAt: Date?

    /// How many steps down the picture is: 0 all of it.
    var step: Int { at }

    /// How long the next step up waits for.
    var wait: TimeInterval { upWait }

    /// The ceiling a step puts on a camera: nil at step 0.
    static func caps(_ step: Int) -> Caps? {
        step <= 0 ? nil : cameraSteps[min(step, cameraSteps.count) - 1]
    }

    /// The first step down at which a camera fits in `kbps` beside the microphone: the last step when none does, 0 when
    /// there is no figure to go by or no camera going out.
    static func fitting(camera: Bool, kbps: Double?) -> Int {
        guard camera, let kbps = kbps, kbps.isFinite else { return 0 }

        for step in 1 ... cameraSteps.count where Double(cameraSteps[step - 1].kbps) <= kbps { return step }

        return cameraSteps.count
    }

    /// The microphone has just come down for sound lost past what its spare copy hides. Where the line is said not to
    /// carry even the picture's first step beside it (`fitting` 2 or more), the picture goes with it, to that step,
    /// without a step's wait. Answers whether the step changed.
    func giveWay(now: Date, fitting: Int) -> Bool {
        let to = min(fitting, CallPictureSteps.cameraSteps.count)

        if fitting < 2 || at >= to { return false }

        at = to
        liftedAt = nil
        said = .suffering
        since = now

        return true
    }

    /// One reading. `fitting` is the first step the line is said to carry, 0 when nothing says: a step down goes
    /// straight there, and no further while that is said; said to carry the first step, the picture takes none.
    /// Answers whether the step changed.
    func review(now: Date, reading: Reading, fitting: Int = 0) -> Bool {
        if reading == .idle { return false }

        if reading != said {
            said = reading
            since = now
        }

        if reading == .suffering {
            if at >= CallPictureSteps.cameraSteps.count { return false }

            // A step up on trial is taken back by the first reading that says it cost the sound.
            let onTrial = liftedAt.map { now.timeIntervalSince($0) <= CallPictureSteps.relapse } ?? false

            // The line is said to carry this step beside the microphone, or the whole picture's first step from none
            // taken: what loses the sound isn't the picture, and a smaller one would cost it for nothing.
            if !onTrial, fitting > 0, at >= fitting || fitting < 2 { return false }

            if !onTrial, now.timeIntervalSince(since) < CallPictureSteps.down { return false }

            if let lifted = liftedAt, now.timeIntervalSince(lifted) <= CallPictureSteps.relapse + CallPictureSteps.down {
                upWait = min(upWait * 2, CallPictureSteps.upMax)
            }

            liftedAt = nil
            // Taken back, it goes back the one step it came up; otherwise down to the first step said to fit.
            at = onTrial ? at + 1 : min(max(at + 1, fitting), CallPictureSteps.cameraSteps.count)
            since = now

            return true
        }

        // A step up that held: the next line that jams starts from the first wait again.
        if at == 0 {
            if let lifted = liftedAt, now.timeIntervalSince(lifted) > CallPictureSteps.relapse + CallPictureSteps.down {
                liftedAt = nil
                upWait = CallPictureSteps.up
            }

            return false
        }

        if now.timeIntervalSince(since) < upWait { return false }

        at -= 1
        liftedAt = now
        since = now

        return true
    }
}
