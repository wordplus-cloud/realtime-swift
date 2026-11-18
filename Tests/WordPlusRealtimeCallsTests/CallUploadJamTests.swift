import XCTest
@testable import WordPlusRealtimeCalls

/// Whether the upload this side sends on is jammed (CallUploadJam), as the web's calls/upload-jam.ts.
final class CallUploadJamTests: XCTestCase {
    /// A reading of the connection: its round trip (seconds, nil where the client gives none), whether a check was
    /// answered since the last, and whether anything arrived.
    private struct Step {
        var rtt: TimeInterval?
        var answered = true
        var arrives = true
    }

    /// The connection's counts as they stand, and the second the next reading is made at.
    private final class Line {
        var second = 0
        var requests: UInt64 = 0
        var responses: UInt64 = 0
        var bytes: UInt64 = 0
    }

    /// Readings every 5 s, as a room's microphone makes them. Answers each change with its second.
    @discardableResult
    private func play(_ jam: CallUploadJam, _ steps: [Step], on line: Line) -> [(second: Int, jammed: Bool)] {
        var changes: [(second: Int, jammed: Bool)] = []

        for step in steps {
            line.requests += 1
            if step.answered { line.responses += 1 }
            if step.arrives { line.bytes += 4000 }

            let reading = CallUploadJam.Reading(at: Date(timeIntervalSinceReferenceDate: TimeInterval(line.second)), rtt: step.rtt, requests: line.requests, responses: line.responses, bytesReceived: line.bytes)

            if jam.review(reading) { changes.append((line.second, jam.jammed)) }

            line.second += 5
        }

        return changes
    }

    private func times(_ count: Int, _ step: Step) -> [Step] { Array(repeating: step, count: count) }

    func testIsNotACleanLine() {
        XCTAssertTrue(play(CallUploadJam(), times(300, Step(rtt: 0.02)), on: Line()).isEmpty)
    }

    /// A 400 kbit/s line with a microphone in RED on it: a queue of the call's own of 1.1-1.7 s, for minutes.
    func testIsNotANarrowLineTheCallItselfFills() {
        let own = [0.529, 0.575, 0.559, 1.102, 1.407, 1.554, 0.378, 1.071, 1.353, 1.522, 1.618, 1.638, 1.495, 1.598, 1.557, 1.581, 1.603]

        XCTAssertTrue(play(CallUploadJam(), own.flatMap { times(3, Step(rtt: $0)) }, on: Line()).isEmpty)
    }

    func testIsARoundTripOfSecondsThatLasts() {
        let jam = CallUploadJam()
        let line = Line()

        play(jam, times(3, Step(rtt: 0.02)), on: line)
        // a moment's spike, gone before it has lasted: nothing to tell
        XCTAssertTrue(play(jam, [Step(rtt: CallUploadJam.rtt + 0.5), Step(rtt: 0.02)], on: line).isEmpty)
        XCTAssertFalse(jam.jammed)

        let began = line.second
        let changes = play(jam, times(4, Step(rtt: 26.09)), on: line)

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.jammed, true)
        // told once every reading has said so for the wait: the second reading after the first, 5 s apart
        XCTAssertEqual(changes.first?.second, began + 10)
    }

    /// The answer to a check waits in the same queue: no answer at all is the round trip that hasn't come yet.
    func testIsChecksUnansweredWhileWhatIsSentToItStillArrives() {
        let jam = CallUploadJam()
        let line = Line()

        play(jam, times(3, Step(rtt: 0.02)), on: line)

        let lastAnswer = line.second - 5
        let changes = play(jam, times(10, Step(rtt: 0.02, answered: false)), on: line)

        XCTAssertEqual(changes.count, 1)
        // unanswered from the first reading 6 s after the last answer (10 s, at readings 5 s apart), and then for the wait (10 s more)
        XCTAssertEqual(changes.first.map { $0.second - lastAnswer }, 20)
    }

    func testIsNotAConnectionThatIsGoneWhichTheCallShowsAsReconnecting() {
        let jam = CallUploadJam()
        let line = Line()

        play(jam, times(3, Step(rtt: 0.02)), on: line)
        XCTAssertTrue(play(jam, times(30, Step(rtt: 0.02, answered: false, arrives: false)), on: line).isEmpty)
    }

    func testClearsAfterItsRoundTripIsQuickAgainForAWhileAndASlowReadingStartsTheWaitAgain() {
        let jam = CallUploadJam()
        let line = Line()

        play(jam, times(4, Step(rtt: 30)), on: line)
        XCTAssertTrue(jam.jammed)
        play(jam, [Step(rtt: 0.04), Step(rtt: 0.04), Step(rtt: 2.5)], on: line)
        XCTAssertTrue(jam.jammed)

        let began = line.second
        let changes = play(jam, times(4, Step(rtt: 0.04)), on: line)

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.jammed, false)
        XCTAssertEqual(changes.first?.second, began + Int(CallUploadJam.clearFor))
    }

    func testStaysThroughAResumeWhoseNewConnectionCountsFromNothing() {
        let jam = CallUploadJam()

        play(jam, times(4, Step(rtt: 30)), on: Line())
        XCTAssertTrue(jam.jammed)

        // a new pair: its counts start again, and nothing is decided from its first reading
        let fresh = Line()

        fresh.second = 100
        XCTAssertTrue(play(jam, [Step(rtt: 30)], on: fresh).isEmpty)
        XCTAssertTrue(jam.jammed)
    }

    func testAClientThatGivesNoRoundTripIsToldByItsChecksAndClearsOnThemAnswered() {
        let jam = CallUploadJam()
        let line = Line()

        play(jam, times(3, Step(rtt: nil)), on: line)
        XCTAssertEqual(play(jam, times(6, Step(rtt: nil, answered: false)), on: line).map(\.jammed), [true])
        XCTAssertEqual(play(jam, times(4, Step(rtt: nil)), on: line).map(\.jammed), [false])
    }
}
