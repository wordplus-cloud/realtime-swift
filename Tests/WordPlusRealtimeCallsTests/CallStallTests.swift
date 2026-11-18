import XCTest
@testable import WordPlusRealtimeCalls

/// What keeps a direct call from escalating into a socket that cannot carry
/// it, and from giving up on a side that is slow rather than gone, as the web
/// engine does (realtime-client's calls-engine tests). A Firefox caller's
/// socket stalled for 47 s while its audio kept flowing, and its restart
/// arrived after the connection had come back (31 Oct 2026); a callee gave up
/// on a caller whose offer came nine seconds after the call had gone to the
/// room (the same day).
final class CallStallTests: XCTestCase {
    func testASocketThatAnswersNothingForFiveSecondsIsStalledUntilAnythingIsAnswered() {
        let watch = CallSocketWatch()
        let t0 = Date()

        XCTAssertEqual(watch.stalledFor(now: t0), 0)

        let pulse = watch.sent(at: t0)

        XCTAssertEqual(watch.stalledFor(now: t0.addingTimeInterval(4.9)), 0)
        XCTAssertGreaterThanOrEqual(watch.stalledFor(now: t0.addingTimeInterval(5.1)), 5)

        // Given up at its timeout: still stalled, since nothing came back.
        watch.settled(pulse, answered: false, at: t0.addingTimeInterval(8))
        XCTAssertGreaterThanOrEqual(watch.stalledFor(now: t0.addingTimeInterval(9)), 9)

        // Something else goes and is answered: the socket carries answers again.
        let sync = watch.sent(at: t0.addingTimeInterval(9))
        watch.settled(sync, answered: true, at: t0.addingTimeInterval(9.2))
        XCTAssertEqual(watch.stalledFor(now: t0.addingTimeInterval(9.3)), 0)
    }

    func testAStallAnOpTimedOutInCountsEvenWhenNobodyAskedDuringIt() {
        let watch = CallSocketWatch()
        let t0 = Date()

        let pulse = watch.sent(at: t0)
        watch.settled(pulse, answered: false, at: t0.addingTimeInterval(8))

        XCTAssertGreaterThanOrEqual(watch.stalledFor(now: t0.addingTimeInterval(8.5)), 8.5)
    }

    func testALateAnswerEndsTheStallToo() {
        let watch = CallSocketWatch()
        let t0 = Date()

        let op = watch.sent(at: t0)
        watch.settled(op, answered: false, at: t0.addingTimeInterval(8))
        XCTAssertGreaterThan(watch.stalledFor(now: t0.addingTimeInterval(8.5)), 0)

        watch.settled(op, answered: true, at: t0.addingTimeInterval(9))
        XCTAssertEqual(watch.stalledFor(now: t0.addingTimeInterval(9.1)), 0)
    }

    func testAStallCountsFromTheFirstOpThroughItsRetries() {
        let watch = CallSocketWatch()
        let t0 = Date()

        let first = watch.sent(at: t0)
        XCTAssertGreaterThanOrEqual(watch.stalledFor(now: t0.addingTimeInterval(6)), 6)

        watch.settled(first, answered: false, at: t0.addingTimeInterval(8))
        _ = watch.sent(at: t0.addingTimeInterval(8))
        XCTAssertGreaterThanOrEqual(watch.stalledFor(now: t0.addingTimeInterval(9)), 9)
    }

    func testASlowSocketThatAnswersIsNotStalled() {
        let watch = CallSocketWatch()
        let t0 = Date()

        for i in 0..<10 {
            let at = t0.addingTimeInterval(Double(i) * 2)
            let op = watch.sent(at: at)

            XCTAssertEqual(watch.stalledFor(now: at.addingTimeInterval(1)), 0)
            watch.settled(op, answered: true, at: at.addingTimeInterval(3))
            XCTAssertEqual(watch.stalledFor(now: at.addingTimeInterval(3.5)), 0)
        }

        XCTAssertEqual(watch.roundTrip, 3, accuracy: 0.001)
    }

    func testTheRoundTripIsTheLongestOfTheLatestFive() {
        let watch = CallSocketWatch()
        let t0 = Date()

        XCTAssertEqual(watch.roundTrip, 0)

        var at = t0

        for ms in [100, 900, 200, 300, 250, 150, 120] {
            let op = watch.sent(at: at)
            at = at.addingTimeInterval(Double(ms) / 1000)
            watch.settled(op, answered: true, at: at)
        }

        XCTAssertEqual(watch.roundTrip, 0.3, accuracy: 0.001)
    }

    func testThePoliteSideWaitsLongerOnASlowSocketUpToSixSeconds() {
        XCTAssertEqual(CallPeer.politeWait(roundTrip: 0), 3, accuracy: 0.001)
        XCTAssertEqual(CallPeer.politeWait(roundTrip: 0.9), 4.8, accuracy: 0.001)
        XCTAssertEqual(CallPeer.politeWait(roundTrip: 11), 6, accuracy: 0.001)
        XCTAssertEqual(CallPeer.politeWait(roundTrip: .infinity), 3, accuracy: 0.001)
    }

    func testANegotiationIsWaitedForWhileTheOtherSideKeepsSpeakingUpToFiftyTwoSeconds() {
        // Never heard: given up at the deadline, as before.
        XCTAssertNil(CallPeer.negotiationGrace(sinceBirth: 26, sinceHeard: nil))
        // Heard fifteen seconds ago: eleven more.
        XCTAssertEqual(CallPeer.negotiationGrace(sinceBirth: 26, sinceHeard: 15) ?? 0, 11, accuracy: 0.001)
        // Silent for twenty-six: given up.
        XCTAssertNil(CallPeer.negotiationGrace(sinceBirth: 40, sinceHeard: 26))
        // However lately heard, never past fifty-two from the birth.
        XCTAssertEqual(CallPeer.negotiationGrace(sinceBirth: 50, sinceHeard: 1) ?? 0, 2, accuracy: 0.001)
        XCTAssertNil(CallPeer.negotiationGrace(sinceBirth: 52, sinceHeard: 1))
    }
}
