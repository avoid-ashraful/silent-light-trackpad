import XCTest
@testable import LightClickCore

/// The scroll/gesture gate: two-finger scrolling must never click,
/// even when one finger's contact pressure crosses the threshold,
/// while a deliberate press with a resting finger still clicks
/// after a short dwell. Movement classifies the sequence; the
/// classification sticks until every finger lifts.
@MainActor
final class ScrollGateTests: EngineTestCase {
    /// Feed a two-finger downward scroll: finger 1 at `pressure`,
    /// finger 2 resting at 20, both gliding 0.015 per frame.
    private func scrollFrames(_ rig: TestRig, pressure: Double, frames: Int) {
        var y = 0.50
        for _ in 0 ..< frames {
            rig.frame(
                rig.touch(1, pressure, x: 0.40, y: y),
                rig.touch(2, 20, x: 0.60, y: y + 0.05)
            )
            y += 0.015
        }
    }

    func testScrollWithFingerOverThresholdNeverClicks() {
        let rig = makeRig()
        scrollFrames(rig, pressure: 60, frames: 5) // finger 1 is ABOVE the threshold the whole time
        XCTAssertEqual(rig.log, [])
        XCTAssertFalse(rig.engine.buttonDown)
        XCTAssertTrue(rig.engine.gestureMoved)
    }

    func testLandingSpikeDoesNotClick() {
        let rig = makeRig()
        rig.frame(rig.touch(1, 60), rig.touch(2, 20)) // fingers land, one spikes over
        rig.frame(rig.touch(1, 20), rig.touch(2, 20)) // …and settles within a frame
        rig.frame(rig.touch(1, 15), rig.touch(2, 20))
        XCTAssertEqual(rig.log, [])
    }

    func testDeliberatePressWithRestingFingerFiresOnThirdFrame() {
        let rig = makeRig()
        rig.frame(rig.touch(1, 10), rig.touch(2, 60))
        rig.frame(rig.touch(1, 10), rig.touch(2, 60))
        XCTAssertEqual(rig.log, []) // dwell: not yet
        rig.frame(rig.touch(1, 10), rig.touch(2, 60))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
    }

    func testDwellMustBeConsecutive() {
        let rig = makeRig()
        rig.frame(rig.touch(1, 10), rig.touch(2, 60)) // dwell 1
        rig.frame(rig.touch(1, 10), rig.touch(2, 60)) // dwell 2
        rig.frame(rig.touch(1, 10), rig.touch(2, 20)) // dip → dwell resets
        rig.frame(rig.touch(1, 10), rig.touch(2, 60)) // dwell 1
        rig.frame(rig.touch(1, 10), rig.touch(2, 60)) // dwell 2
        XCTAssertEqual(rig.log, [])
        rig.frame(rig.touch(1, 10), rig.touch(2, 60)) // dwell 3 → fire
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
    }

    func testClassificationSticksWhenOneFingerLifts() {
        let rig = makeRig()
        scrollFrames(rig, pressure: 60, frames: 3)
        XCTAssertTrue(rig.engine.gestureMoved)

        // One finger lifts; the other keeps gliding and pressing.
        // Still the same scroll — no click.
        rig.frame(rig.touch(1, 60, x: 0.40, y: 0.545))
        XCTAssertEqual(rig.log, [])
        XCTAssertTrue(rig.engine.gestureMoved)

        rig.liftAll()
        XCTAssertFalse(rig.engine.gestureMoved) // gate resets on the empty frame

        rig.frame(rig.touch(1, 60)) // a fresh press is a fresh press
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
    }

    func testThreeFingerGestureDoesNotClick() {
        let rig = makeRig()
        var y = 0.50
        for _ in 0 ..< 4 {
            rig.frame(
                rig.touch(1, 60, x: 0.35, y: y),
                rig.touch(2, 30, x: 0.50, y: y + 0.03),
                rig.touch(3, 30, x: 0.65, y: y + 0.06)
            )
            y += 0.015
        }
        XCTAssertEqual(rig.log, [])
        XCTAssertTrue(rig.engine.gestureMoved)
    }

    func testStationaryPressAfterScrollStaysBlockedUntilLift() {
        let rig = makeRig()
        scrollFrames(rig, pressure: 30, frames: 3) // classify, nobody over threshold
        XCTAssertTrue(rig.engine.gestureMoved)

        // The fingers stop moving and one presses — but the sequence
        // is still the scroll until every finger lifts.
        for _ in 0 ..< 3 {
            rig.frame(rig.touch(1, 60, x: 0.40, y: 0.545), rig.touch(2, 20, x: 0.60, y: 0.595))
        }
        XCTAssertEqual(rig.log, [])
    }

    func testSlowDriftPressStillFires() {
        let rig = makeRig()
        // A deliberate press whose fingers drift very slightly
        // (0.005/frame: below the velocity trigger, and total travel
        // stays below the ~2 mm anchor distance) is a press, not a
        // scroll — the dwell rule lets it fire on frame 3.
        var x = 0.40
        for _ in 0 ..< 3 {
            rig.frame(rig.touch(1, 60, x: x, y: 0.50), rig.touch(2, 20, x: 0.60, y: 0.55))
            x += 0.005
        }
        XCTAssertFalse(rig.engine.gestureMoved)
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
    }

    func testSingleFingerFastMovementNeverClassifies() {
        let rig = makeRig()
        var x = 0.30
        for _ in 0 ..< 3 {
            rig.frame(rig.touch(1, 10, x: x, y: 0.50)) // fling the cursor with one finger
            x += 0.05
        }
        XCTAssertFalse(rig.engine.gestureMoved) // the gate needs two fingers

        rig.frame(rig.touch(1, 60, x: x, y: 0.50))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"]) // instant, as always
    }
}
