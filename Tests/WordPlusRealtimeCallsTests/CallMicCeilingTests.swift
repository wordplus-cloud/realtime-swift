import XCTest
@testable import WordPlusRealtimeCalls

/// A direct call's microphone ceiling on a slow upload (CallMicCeiling), as the web's calls/mic-ceiling.ts.
final class CallMicCeilingTests: XCTestCase {
    private let whole = CallShapes.microphoneMaxBitrate
    private let hold = Int(CallMicCeiling.hold)

    /// A reading every two seconds, as the stats poll makes them, from second `from` for `seconds`. Answers how many changed it.
    @discardableResult
    private func readings(_ ceiling: CallMicCeiling, _ from: Int, _ seconds: Int, _ estimate: Int?, _ video: Bool) -> Int {
        var changes = 0

        for at in stride(from: from, through: from + seconds, by: 2) {
            if ceiling.review(now: Date(timeIntervalSinceReferenceDate: TimeInterval(at)), estimate: estimate, videoSending: video) { changes += 1 }
        }

        return changes
    }

    private func slowed() -> CallMicCeiling {
        let ceiling = CallMicCeiling()

        readings(ceiling, 0, hold, CallMicCeiling.slowBelow - 1, true)
        XCTAssertEqual(ceiling.bitrate, CallMicCeiling.slowBitrate)

        return ceiling
    }

    func testIsTheWholeOfItToBeginWith() {
        XCTAssertEqual(CallMicCeiling().bitrate, whole)
    }

    func testLeavesACallsFirstSecondsAlone() {
        let ceiling = CallMicCeiling()

        XCTAssertEqual(readings(ceiling, 0, hold - 2, 300_000, true), 0)
        XCTAssertEqual(readings(ceiling, hold, 60, 3_000_000, true), 0)
        XCTAssertEqual(ceiling.bitrate, whole)
    }

    func testComesDownOnceWhenTheEstimateStaysLowWhileVideoGoesOut() {
        let ceiling = CallMicCeiling()

        XCTAssertEqual(readings(ceiling, 0, 60, CallMicCeiling.slowBelow - 1, true), 1)
        XCTAssertEqual(ceiling.bitrate, CallMicCeiling.slowBitrate)
    }

    func testStartsItsWaitOverWhenAReadingSaysOtherwise() {
        let ceiling = CallMicCeiling()

        readings(ceiling, 0, hold - 2, CallMicCeiling.slowBelow - 1, true)
        readings(ceiling, hold, 0, CallMicCeiling.slowBelow, true)
        readings(ceiling, hold + 2, hold - 2, CallMicCeiling.slowBelow - 1, true)
        XCTAssertEqual(ceiling.bitrate, whole)
    }

    func testKeepsAllOfItWithNoVideoGoingOutHoweverLowTheEstimate() {
        let ceiling = CallMicCeiling()

        XCTAssertEqual(readings(ceiling, 0, 600, 60_000, false), 0)
        XCTAssertEqual(ceiling.bitrate, whole)
    }

    func testKeepsAllOfItWhereThereIsNoEstimate() {
        let ceiling = CallMicCeiling()

        XCTAssertEqual(readings(ceiling, 0, 600, nil, true), 0)
        XCTAssertEqual(ceiling.bitrate, whole)
    }

    func testDoesNotStartItsWaitOverForAReadingWithNoEstimate() {
        let ceiling = CallMicCeiling()

        readings(ceiling, 0, 0, CallMicCeiling.slowBelow - 1, true)
        readings(ceiling, 4, 0, nil, true)
        readings(ceiling, hold, 0, CallMicCeiling.slowBelow - 1, true)
        XCTAssertEqual(ceiling.bitrate, CallMicCeiling.slowBitrate)
    }

    func testStaysDownBetweenTheTwoMarks() {
        let ceiling = slowed()

        XCTAssertEqual(readings(ceiling, 100, 600, CallMicCeiling.backAt - 1, true), 0)
        XCTAssertEqual(ceiling.bitrate, CallMicCeiling.slowBitrate)
    }

    func testGoesBackUpOnceTheEstimateHoldsClearOfTheMark() {
        let ceiling = slowed()

        XCTAssertEqual(readings(ceiling, 100, hold - 2, CallMicCeiling.backAt, true), 0)
        XCTAssertEqual(readings(ceiling, 100 + hold, 60, CallMicCeiling.backAt, true), 1)
        XCTAssertEqual(ceiling.bitrate, whole)
    }

    func testGoesBackUpWhenNoVideoGoesOutAndAShortPauseLeavesItDown() {
        let ceiling = slowed()

        XCTAssertEqual(readings(ceiling, 100, hold - 2, 300_000, false), 0)
        XCTAssertEqual(ceiling.bitrate, CallMicCeiling.slowBitrate)
        readings(ceiling, 110, 0, 300_000, true)
        XCTAssertEqual(readings(ceiling, 200, 60, 300_000, false), 1)
        XCTAssertEqual(ceiling.bitrate, whole)
    }

    /// What the estimate read at each ceiling through a shaped upload (calls/mic-ceiling.ts): 850 and 818 on 1000 kbps, 966 and 1028 on 1200.
    func testARoomsMarksComeDownOn1000KbpsStayDownThereAndLeave1200KbpsAlone() {
        let ceiling = CallMicCeiling(slowBelow: CallMicCeiling.roomSlowBelow, backAt: CallMicCeiling.roomBackAt)

        XCTAssertEqual(readings(ceiling, 0, 60, 966_000, true), 0)
        XCTAssertEqual(readings(ceiling, 100, 60, 850_000, true), 1)
        XCTAssertTrue(ceiling.lowered)
        XCTAssertEqual(readings(ceiling, 200, 60, 818_000, true), 0)
        XCTAssertEqual(readings(ceiling, 300, 60, 1_028_000, true), 1)
        XCTAssertFalse(ceiling.lowered)
    }

    /// What a room reads of its microphone, 125 packets apart as at 25 a second and a reading every 5 s.
    func testALossSaysNothingOnItsFirstReadingAndThenReadsFromTheLastOne() {
        let loss = CallMicLoss()

        XCTAssertFalse(loss.losing(sent: 125, missed: 50))
        XCTAssertFalse(loss.losing(sent: 250, missed: 50))
        XCTAssertTrue(loss.losing(sent: 375, missed: 55))
        XCTAssertFalse(loss.losing(sent: 500, missed: 59))
    }

    func testALossTakesNothingOfAQuietMicrophoneOrOfAClientThatGivesNone() {
        let quiet = CallMicLoss()

        XCTAssertFalse(quiet.losing(sent: 0, missed: 0))
        XCTAssertFalse(quiet.losing(sent: 49, missed: 25))

        let none = CallMicLoss()

        XCTAssertFalse(none.losing(sent: 125, missed: nil))
        XCTAssertFalse(none.losing(sent: 250, missed: nil))
    }

    func testAQueueReadsTheWaitSinceTheLastReadingAndANewSenderFromNothing() {
        let loss = CallMicLoss()

        XCTAssertFalse(loss.queued(packets: 100, delay: 0))
        XCTAssertTrue(loss.queued(packets: 200, delay: 10))
        XCTAssertFalse(loss.queued(packets: 300, delay: 15))
        XCTAssertFalse(loss.queued(packets: 300, delay: 40))
        XCTAssertFalse(loss.queued(packets: 100, delay: 5))
        XCTAssertTrue(loss.queued(packets: 200, delay: 25))
    }

    func testALossReadsAReconnectsNewSenderFromItsFirstReading() {
        let loss = CallMicLoss()

        XCTAssertFalse(loss.losing(sent: 5000, missed: 100))
        XCTAssertFalse(loss.losing(sent: 125, missed: 10))
        XCTAssertTrue(loss.losing(sent: 250, missed: 30))
    }

    /// A reading of a room's microphone says more than whether it is lost: whether the person talks, whether the loss is
    /// past what a spare copy hides, and what the microphone put on the line.
    func testAReadingTellsTalkingHeavyLossAndWhatWentOnTheWire() {
        let loss = CallMicLoss()
        let at = { (second: Int) in Date(timeIntervalSinceReferenceDate: TimeInterval(second)) }

        XCTAssertEqual(loss.hearing(now: at(0), sent: 0, missed: 0, bytes: 0), CallMicLoss.Heard())

        // 125 packets in 5 s, 8% of them lost: talking, lossy, not heavy; 67,500 bytes and 125 packets' headers on the wire
        let light = loss.hearing(now: at(5), sent: 125, missed: 10, bytes: 67_500)

        XCTAssertTrue(light.talking)
        XCTAssertTrue(light.lossy)
        XCTAssertFalse(light.heavy)
        XCTAssertEqual(light.wire ?? 0, Double(67_500 + 125 * 38) * 8 / 5, accuracy: 0.5)

        // 12% and more: heavy
        XCTAssertTrue(loss.hearing(now: at(10), sent: 250, missed: 25, bytes: 135_000).heavy)

        // a quiet microphone says nothing of loss, and still says what it put on the wire
        let quiet = loss.hearing(now: at(15), sent: 260, missed: 30, bytes: 136_000)

        XCTAssertFalse(quiet.talking)
        XCTAssertFalse(quiet.lossy)
        XCTAssertNotNil(quiet.wire)

        // a client that doesn't count its bytes: nothing said of the wire
        XCTAssertNil(loss.hearing(now: at(20), sent: 385, missed: 30, bytes: nil).wire)
    }

    /// Beside video, sound lost past what its spare copy hides brings the ceiling down sooner, and no sooner back up.
    func testComesDownSoonerOnAShorterHoldAndGoesBackUpOnTheWholeOne() {
        let heavy = CallMicCeiling(slowBelow: CallMicCeiling.roomSlowBelow, backAt: CallMicCeiling.roomBackAt)
        let at = { (second: Int) in Date(timeIntervalSinceReferenceDate: TimeInterval(second)) }

        XCTAssertFalse(heavy.review(now: at(0), estimate: 300_000, videoSending: true, downHold: CallMicCeiling.heavyHold))
        XCTAssertTrue(heavy.review(now: at(5), estimate: 300_000, videoSending: true, downHold: CallMicCeiling.heavyHold))
        XCTAssertTrue(heavy.lowered)

        // the whole hold on the way up, whatever the shorter one says
        XCTAssertFalse(heavy.review(now: at(10), estimate: 2_000_000, videoSending: true, downHold: CallMicCeiling.heavyHold))
        XCTAssertFalse(heavy.review(now: at(15), estimate: 2_000_000, videoSending: true, downHold: CallMicCeiling.heavyHold))
        XCTAssertTrue(heavy.review(now: at(20), estimate: 2_000_000, videoSending: true, downHold: CallMicCeiling.heavyHold))
        XCTAssertFalse(heavy.lowered)

        // and never a longer one than the hold
        let long = CallMicCeiling()

        XCTAssertFalse(long.review(now: at(0), estimate: 300_000, videoSending: true, downHold: 60))
        XCTAssertTrue(long.review(now: at(hold), estimate: 300_000, videoSending: true, downHold: 60))
    }

    /// A room's microphone alone: no estimate to read, so its loss is given with 0, which stands under every mark, and
    /// having come down alone is what keeps it there.
    func testComesDownAloneOnItsLossAndStaysDownWhileThatIsSaid() {
        let ceiling = CallMicCeiling(slowBelow: CallMicCeiling.roomSlowBelow, backAt: CallMicCeiling.roomBackAt)

        XCTAssertEqual(readings(ceiling, 0, 60, 0, false), 0)
        XCTAssertEqual(readings(ceiling, 100, 60, 0, true), 1)
        XCTAssertTrue(ceiling.lowered)
        XCTAssertEqual(readings(ceiling, 200, 600, 0, true), 0)
        XCTAssertTrue(ceiling.lowered)
    }
}
