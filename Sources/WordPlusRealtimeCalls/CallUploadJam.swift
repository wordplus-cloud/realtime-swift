import Foundation

/// Whether the upload this side sends on is jammed, so the person can be told: what they send waits seconds on their own
/// line, or gets no answer at all, while what is sent to them still arrives. The browsers' engine judges it the same way
/// with the same numbers, and says what was seen and measured (realtime-client, calls/upload-jam.ts): a round trip of
/// seconds is the line's, and the one who can mend it is the person, whatever else uploads on their network.
///
/// A reading is the selected candidate pair of the connection this side sends on, as the room's microphone reader
/// already has it. Jammed takes every reading saying so for `jamFor`: the pair's round trip `rtt` or more, or its checks
/// asked and none answered for `unanswered` (a check's answer waits in the same queue, so the round trip it would read
/// comes late, if at all), while something still arrives on it, so a connection that is gone altogether, which the call
/// already shows as reconnecting, isn't called jammed. It clears after `clearFor` of readings with the round trip under
/// `clearRtt` and the checks answered. A pair whose counts go back is a new one (a resume restarts ICE): its counts start
/// again and what was decided stays.
final class CallUploadJam {
    /// A round trip from which the upload counts as jammed, seconds.
    static let rtt: TimeInterval = 3
    /// How long checks asked and none answered count as jammed.
    static let unanswered: TimeInterval = 6
    /// How long every reading has to say so before it counts: a moment's spike of seconds is no jam to tell anyone about.
    static let jamFor: TimeInterval = 6
    /// The round trip under which a reading counts as clear, seconds.
    static let clearRtt: TimeInterval = 1
    /// How long readings have to be clear before it is no longer jammed.
    static let clearFor: TimeInterval = 10

    /// One reading of the connection this side sends on. Anything not known is nil.
    struct Reading {
        /// When it was read.
        var at: Date
        /// The pair's round trip, seconds.
        var rtt: TimeInterval?
        /// Its checks sent so far, and those answered.
        var requests: UInt64?
        var responses: UInt64?
        /// What has arrived on it so far, bytes.
        var bytesReceived: UInt64?
    }

    private var on = false
    /// When the readings began to say so, in a row.
    private var since: Date?
    private var clearSince: Date?
    private var last: Reading?
    /// When a check was last answered, or counts began, and the checks sent then.
    private var answeredAt = Date.distantPast
    private var requestsThen: UInt64 = 0

    /// Whether the upload is jammed now.
    var jammed: Bool { on }

    /// One reading. Answers whether `jammed` changed.
    func review(_ r: Reading) -> Bool {
        let before = last

        last = r

        guard let last = before,
              (r.requests ?? 0) >= (last.requests ?? 0),
              (r.responses ?? 0) >= (last.responses ?? 0),
              (r.bytesReceived ?? 0) >= (last.bytesReceived ?? 0)
        else {
            answeredAt = r.at
            requestsThen = r.requests ?? 0

            return false
        }

        if (r.responses ?? 0) > (last.responses ?? 0) {
            answeredAt = r.at
            requestsThen = r.requests ?? 0
        }

        let unanswered = (r.requests ?? 0) > requestsThen && r.at.timeIntervalSince(answeredAt) >= CallUploadJam.unanswered
        let arrives = (r.bytesReceived ?? 0) > (last.bytesReceived ?? 0)
        let slow = (r.rtt ?? 0) >= CallUploadJam.rtt

        if !on {
            guard arrives, slow || unanswered else {
                since = nil

                return false
            }

            let began = since ?? r.at

            since = began

            if r.at.timeIntervalSince(began) < CallUploadJam.jamFor { return false }

            on = true
            since = nil
            clearSince = nil

            return true
        }

        // a client that gives no round trip clears on its checks answered alone
        let clear = !unanswered && (r.rtt.map { $0 < CallUploadJam.clearRtt } ?? true)

        guard clear else {
            clearSince = nil

            return false
        }

        let began = clearSince ?? r.at

        clearSince = began

        if r.at.timeIntervalSince(began) < CallUploadJam.clearFor { return false }

        on = false
        clearSince = nil

        return true
    }
}
