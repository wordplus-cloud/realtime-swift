import Foundation

/// What a call lets its microphone spend, on an upload too slow for 64 kbps of it. The browsers' engine
/// does the same with the same numbers, and says why and what was measured (realtime-client, calls/mic-ceiling.ts): the
/// allocation counts a microphone once at its ceiling while in RED it sends about twice that, so on a slow upload the
/// camera's share overcommits the link and the picture freezes.
///
/// The ceiling comes down only while video goes out and the estimate has stayed low, so a call's first seconds leave it
/// alone, and it goes back up once the estimate is clear of the mark or no video goes out any more. A call with no video
/// keeps all of it: nothing competes with its sound, and its estimate is low only because it sends little.
///
/// A room's marks sit higher, as the browsers' do: a simulcast camera pads what its picture doesn't need up to about the
/// estimate, and the microphone goes on top of that.
///
/// A room's microphone can be too much for its line all by itself, with no video going out and no estimate to say
/// anything: then its node's count of what it lost brings it down, and it stays down while it is alone (`GroupCall`
/// reads it so, with an estimate of 0, which stands under every mark). And beside video, sound lost past what its spare
/// copy hides is answered sooner (`heavyHold`): the video can give the room back.
final class CallMicCeiling {
    static let slowBitrate = 32_000
    static let slowBelow = 600_000
    /// Above where it comes down, so the ceiling doesn't flap around one mark.
    static let backAt = 750_000
    static let roomSlowBelow = 900_000
    static let roomBackAt = 1_000_000
    static let hold: TimeInterval = 10
    /// How long a room's microphone losing heavily beside video (`CallMicLoss.heavyMark`) has to go on before it comes down.
    static let heavyHold: TimeInterval = 4

    private let slowBelow: Int
    private let backAt: Int
    private var slow = false
    private var leavingSince: Date?

    init(slowBelow: Int = CallMicCeiling.slowBelow, backAt: Int = CallMicCeiling.backAt) {
        self.slowBelow = slowBelow
        self.backAt = backAt
    }

    var bitrate: Int {
        slow ? CallMicCeiling.slowBitrate : CallShapes.microphoneMaxBitrate
    }

    /// Whether it has come down.
    var lowered: Bool { slow }

    /// One stats reading: the sender's estimate in bits per second, nil when it gave none, and whether video went out
    /// since the last. `downHold` is how long a reading has to hold for the ceiling to come down on it, where that is
    /// less than the hold either way. Answers whether the ceiling changed.
    func review(now: Date, estimate: Int?, videoSending: Bool, downHold: TimeInterval = CallMicCeiling.hold) -> Bool {
        // A reading with no estimate says nothing, and doesn't restart the wait either.
        if videoSending, estimate == nil { return false }

        let wanted = videoSending && (estimate ?? 0) < (slow ? backAt : slowBelow)

        if wanted == slow {
            leavingSince = nil

            return false
        }

        let since = leavingSince ?? now

        leavingSince = since

        if now.timeIntervalSince(since) < (wanted ? min(downHold, CallMicCeiling.hold) : CallMicCeiling.hold) { return false }

        slow = wanted
        leavingSince = nil

        return true
    }
}

/// What a room's microphone hears of itself, at each reading of its ceiling, as the browsers' `watchRoomMic` reads it. A
/// camera whose viewers want little sends one layer and nothing holds it back, while the upload can still be too slow for
/// it and the microphone together. Then the share of the microphone its node says it lost, or asked for again, tells, and
/// realtime-client's calls/mic-ceiling.ts says what was measured.
final class CallMicLoss {
    /// The share lost or asked for again since the last reading that says the upload can't carry it.
    static let mark = 0.04
    /// The share lost that no spare copy hides: about one packet in eight, where two in a row go often enough to be heard.
    static let heavyMark = 0.12
    /// The packets that has to hold to say anything: a quiet microphone sends next to none, one talking 25 a second in 40 ms frames.
    static let minPackets: Int64 = 50
    /// How long a room's video waits in its sender's queue, on average since the last reading, that says the upload can't carry it, in seconds.
    static let queuedMark = 0.1
    /// What a microphone's packet costs beside what its sender counts of it: its IP and UDP headers and SRTP's tag, in bytes.
    static let packetOverhead: Int64 = 38

    /// What a reading says of the microphone: whether enough of it went out to say anything, which is the person talking;
    /// whether the share of that lost or asked for again says the upload can't carry it, and whether it is past what a
    /// spare copy hides; and what the microphone put on the line since the last reading, in bits per second with its
    /// packets' headers, nil where that can't be said.
    struct Heard: Equatable {
        var talking = false
        var lossy = false
        var heavy = false
        var wire: Double?
    }

    private var sent: Int64?
    private var missed: Int64?
    private var bytes: Int64?
    private var at: Date?
    private var videoPackets: Int64 = 0
    private var videoDelay = 0.0

    /// One reading of the video going out: its packets and how long they have waited so far. A reconnect's new senders count from nothing, which reads as none gone out.
    func queued(packets: Int64, delay: Double) -> Bool {
        let went = packets - videoPackets
        let waited = delay - videoDelay

        videoPackets = packets
        videoDelay = delay

        return went > 0 && waited / Double(went) >= CallMicLoss.queuedMark
    }

    /// One reading: what has gone out of the microphone so far and what its node says was lost or asked for again, nil when there is no saying.
    func losing(sent: Int64?, missed: Int64?) -> Bool {
        hearing(now: Date(), sent: sent, missed: missed, bytes: nil).lossy
    }

    /// One reading, with its moment and what the sender counts of the microphone's bytes so far (its payload and its RTP
    /// headers), nil where it doesn't say: `losing`, and the rest of what the reading tells.
    func hearing(now: Date, sent: Int64?, missed: Int64?, bytes: Int64?) -> Heard {
        let sentBefore = self.sent
        let missedBefore = self.missed
        let bytesBefore = self.bytes
        let atBefore = at

        self.sent = sent
        self.missed = missed
        self.bytes = bytes
        at = now

        guard let sent = sent, let missed = missed, let sentBefore = sentBefore, let missedBefore = missedBefore else { return Heard() }

        // A reconnect's new sender counts from nothing, which reads as none gone out.
        let went = sent - sentBefore
        let talking = went >= CallMicLoss.minPackets
        let share = talking ? Double(missed - missedBefore) / Double(went) : 0
        var wire: Double?

        if went > 0, let bytes = bytes, let bytesBefore = bytesBefore, bytes >= bytesBefore, let atBefore = atBefore {
            let over = now.timeIntervalSince(atBefore)

            if over > 0 { wire = Double(bytes - bytesBefore + went * CallMicLoss.packetOverhead) * 8 / over }
        }

        return Heard(talking: talking, lossy: share >= CallMicLoss.mark, heavy: share >= CallMicLoss.heavyMark, wire: wire)
    }
}
