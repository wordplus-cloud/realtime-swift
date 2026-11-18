import XCTest
@testable import WordPlusRealtimeCalls

/// The picture giving way to the sound a step at a time (CallPictureSteps), as the web's calls/picture-steps.ts.
final class CallPictureStepsTests: XCTestCase {
    private let down = Int(CallPictureSteps.down)
    private let up = Int(CallPictureSteps.up)
    private let relapse = Int(CallPictureSteps.relapse)
    private let last = CallPictureSteps.cameraSteps.count

    private func at(_ second: Int) -> Date { Date(timeIntervalSinceReferenceDate: TimeInterval(second)) }

    /// Readings every 5 s, as a room's microphone makes them, from second `from` to `to`, all saying the same. Answers the seconds a step changed at.
    @discardableResult
    private func say(_ steps: CallPictureSteps, _ from: Int, _ to: Int, _ reading: CallPictureSteps.Reading, fitting: Int = 0) -> [Int] {
        var moved: [Int] = []

        for second in stride(from: from, through: to, by: 5) where steps.review(now: at(second), reading: reading, fitting: fitting) { moved.append(second) }

        return moved
    }

    func testTakesAStepOnceTheSoundHasSufferedForTheHoldAndTheNextOnlyAfterAsLongAgain() {
        let steps = CallPictureSteps()

        XCTAssertEqual(say(steps, 0, 0, .suffering), [])
        XCTAssertEqual(steps.step, 0)
        XCTAssertEqual(say(steps, down, 2 * down, .suffering), [down, 2 * down])
        XCTAssertEqual(steps.step, 2)
    }

    func testStopsAtItsLastStepHoweverLongTheSoundSuffers() {
        let steps = CallPictureSteps()

        say(steps, 0, 120, .suffering)
        XCTAssertEqual(steps.step, last)
    }

    func testStartsItsWaitOverWhenAReadingSaysOtherwiseAndHoldsThroughReadingsThatSayNothing() {
        let steps = CallPictureSteps()

        say(steps, 0, 0, .suffering)
        say(steps, 5, 5, .clean)
        XCTAssertEqual(say(steps, 10, 10, .suffering), [])
        XCTAssertEqual(say(steps, 15, 15, .suffering), [15])

        // silence between two halves of the wait: neither a step nor a new start
        let quiet = CallPictureSteps()

        say(quiet, 0, 0, .suffering)
        say(quiet, 5, 60, .idle)
        XCTAssertEqual(quiet.step, 0)
        XCTAssertEqual(say(quiet, 65, 65, .suffering), [65])
    }

    func testComesBackAStepForEveryWaitTheSoundStaysCleanThePersonTalking() {
        let steps = CallPictureSteps()

        say(steps, 0, 2 * down, .suffering)
        XCTAssertEqual(steps.step, 2)

        let from = 2 * down + 5

        XCTAssertEqual(say(steps, from, from + up - 5, .clean), [])
        XCTAssertEqual(say(steps, from + up, from + 2 * up, .clean), [from + up, from + 2 * up])
        XCTAssertEqual(steps.step, 0)
    }

    func testStaysWhereItIsThroughSilence() {
        let steps = CallPictureSteps()

        say(steps, 0, down, .suffering)
        say(steps, down + 5, 600, .idle)
        XCTAssertEqual(steps.step, 1)
    }

    func testWaitsTwiceAsLongForTheNextStepUpAfterOneThatBroughtTheTroubleBackUpToItsLongest() {
        let steps = CallPictureSteps()
        var second = 0

        func run(_ seconds: Int, _ reading: CallPictureSteps.Reading) {
            say(steps, second, second + seconds, reading)
            second += seconds + 5
        }

        run(down, .suffering)
        XCTAssertEqual(steps.step, 1)
        run(up, .clean)
        XCTAssertEqual(steps.step, 0)
        // the trouble is back straight after the step up: taken back by that reading
        run(0, .suffering)
        XCTAssertEqual(steps.step, 1)
        XCTAssertEqual(steps.wait, 2 * CallPictureSteps.up)
        // not before the doubled wait is over
        XCTAssertEqual(say(steps, second, second + 2 * up - 5, .clean), [])
        second += 2 * up
        XCTAssertTrue(steps.review(now: at(second), reading: .clean))
        second += 5

        for _ in 0 ..< 12 {
            run(0, .suffering)
            run(Int(steps.wait), .clean)
        }

        XCTAssertEqual(steps.wait, CallPictureSteps.upMax)
    }

    func testTakesAStepUpBackAtTheFirstReadingThatSaysItCostTheSoundAndPastItsTrialWaitsTheHoldAgain() {
        let steps = CallPictureSteps()

        say(steps, 0, down, .suffering)

        let lifted = down + 5 + up

        XCTAssertEqual(say(steps, down + 5, lifted, .clean), [lifted])
        XCTAssertEqual(steps.step, 0)

        // on trial: no hold, and back the one step it came up, whatever is said to fit
        XCTAssertTrue(steps.review(now: at(lifted + 5), reading: .suffering, fitting: 3))
        XCTAssertEqual(steps.step, 1)
        XCTAssertEqual(steps.wait, 2 * CallPictureSteps.up)

        // a step up that has held its trial: trouble after it is a step down like any other
        let held = CallPictureSteps()

        say(held, 0, down, .suffering)
        say(held, down + 5, lifted + relapse, .clean)
        XCTAssertEqual(held.step, 0)

        let again = lifted + relapse + 5

        XCTAssertEqual(say(held, again, again, .suffering), [])
        XCTAssertEqual(say(held, again + down, again + down, .suffering), [again + down])
    }

    func testGoesStraightDownToTheFirstStepSaidToFitAndNoFurtherWhileThatIsSaid() {
        let steps = CallPictureSteps()

        XCTAssertEqual(say(steps, 0, down, .suffering, fitting: 2), [down])
        XCTAssertEqual(steps.step, 2)
        // the line is said to carry that step, or more: still suffering, the picture isn't what loses the sound
        XCTAssertEqual(say(steps, down + 5, 60, .suffering, fitting: 2), [])
        XCTAssertEqual(say(steps, 65, 80, .suffering, fitting: 1), [])
        XCTAssertEqual(steps.step, 2)
        // said to carry less after all: the next step at once, its wait long over
        XCTAssertEqual(say(steps, 85, 85, .suffering, fitting: 3), [85])
        XCTAssertEqual(steps.step, 3)

        // said to carry the first step: none is taken from the whole picture, however long the sound suffers
        let whole = CallPictureSteps()

        XCTAssertEqual(say(whole, 0, 60, .suffering, fitting: 1), [])
        XCTAssertEqual(whole.step, 0)

        let far = CallPictureSteps()

        say(far, 0, down, .suffering)
        XCTAssertEqual(far.step, 1)
        say(far, down + 5, down + 5, .clean)
        say(far, down + 10, down + 10 + down, .suffering, fitting: 9)
        XCTAssertEqual(far.step, last)
    }

    func testGoesWithAMicrophoneThatCameDownForHeavyLossWhereNotEvenItsFirstStepIsSaidToFit() {
        let steps = CallPictureSteps()

        // nothing says, or the first step fits: the microphone alone first
        XCTAssertFalse(steps.giveWay(now: at(0), fitting: 0))
        XCTAssertFalse(steps.giveWay(now: at(0), fitting: 1))
        XCTAssertEqual(steps.step, 0)

        XCTAssertTrue(steps.giveWay(now: at(0), fitting: 2))
        XCTAssertEqual(steps.step, 2)
        XCTAssertFalse(steps.giveWay(now: at(5), fitting: 2))
        // the next step waits its hold from there
        XCTAssertFalse(steps.review(now: at(down - 1), reading: .suffering, fitting: 3))
        XCTAssertTrue(steps.review(now: at(down), reading: .suffering, fitting: 3))
        XCTAssertEqual(steps.step, 3)

        let all = CallPictureSteps()

        XCTAssertTrue(all.giveWay(now: at(0), fitting: 9))
        XCTAssertEqual(all.step, last)
    }

    func testGoesBackToItsFirstWaitOnceAStepUpToTheWholePictureHasHeld() {
        let steps = CallPictureSteps()
        var second = 0

        func run(_ seconds: Int, _ reading: CallPictureSteps.Reading) {
            say(steps, second, second + seconds, reading)
            second += seconds + 5
        }

        run(down, .suffering)
        run(up, .clean)
        run(0, .suffering)
        XCTAssertEqual(steps.wait, 2 * CallPictureSteps.up)
        run(2 * up, .clean)
        XCTAssertEqual(steps.step, 0)
        run(relapse + down + 5, .clean)
        XCTAssertEqual(steps.wait, CallPictureSteps.up)
    }

    func testAStepsCeilingIsACamerasSizeFramesAndBitrate() {
        XCTAssertNil(CallPictureSteps.caps(0))
        XCTAssertEqual(CallPictureSteps.caps(1), CallPictureSteps.cameraSteps[0])
        XCTAssertEqual(CallPictureSteps.caps(9), CallPictureSteps.cameraSteps[last - 1])
        XCTAssertEqual(CallPictureSteps.cameraSteps.map(\.kbps), [150, 50, 30])
    }

    func testFitsALineAtTheFirstStepWhoseCameraItCarries() {
        XCTAssertEqual(CallPictureSteps.fitting(camera: true, kbps: 200), 1)
        XCTAssertEqual(CallPictureSteps.fitting(camera: true, kbps: 149), 2)
        XCTAssertEqual(CallPictureSteps.fitting(camera: true, kbps: 49), 3)
        XCTAssertEqual(CallPictureSteps.fitting(camera: true, kbps: 5), last)
        // nothing to go by: no figure, or no camera going out
        XCTAssertEqual(CallPictureSteps.fitting(camera: true, kbps: nil), 0)
        XCTAssertEqual(CallPictureSteps.fitting(camera: false, kbps: 100), 0)
    }
}
