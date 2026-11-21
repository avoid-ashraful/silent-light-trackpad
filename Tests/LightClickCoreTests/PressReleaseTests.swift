#if canImport(XCTest)
import XCTest
@testable import LightClickCore

/// Basic press / release behaviour of a single finger at the
/// default threshold of 50.
@MainActor
final class PressReleaseTests: EngineTestCase {

    /// A single-finger press above the threshold fires on the very
    /// first frame — no dwell for a lone finger.
    func testPressAboveThresholdFiresOnFirstFrame() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))

        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
        XCTAssertTrue(rig.engine.buttonDown)
    }

    /// The threshold itself is inclusive: 49 never fires, 50 does.
    func testPressAtExactlyThresholdFiresAndJustBelowDoesNot() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 49))
        XCTAssertEqual(rig.log, [])
        XCTAssertFalse(rig.engine.buttonDown)

        rig.frame(rig.touch(1, 50))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
        XCTAssertTrue(rig.engine.buttonDown)
    }

    /// Snappy release: easing off to 34 (below the 70% release line
    /// of 35 at threshold 50) releases while the finger is still on
    /// the glass.
    func testEaseOffBelowReleaseLineReleasesWhileFingerStillDown() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        rig.frame(rig.touch(1, 34))

        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"])
        XCTAssertFalse(rig.engine.buttonDown)
    }

    /// Easing only to 36 (still inside the hysteresis band above
    /// the 70% line) keeps the button held across frames.
    func testEaseOffInsideHysteresisBandDoesNotRelease() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        for _ in 0..<3 {
            rig.frame(rig.touch(1, 36))
        }

        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
        XCTAssertTrue(rig.engine.buttonDown)
    }

    /// Holding pressure steady produces exactly one down and no up.
    func testHoldKeepsButtonDownWithExactlyOneDown() {
        let rig = makeRig(threshold: 50)

        for _ in 0..<5 {
            rig.frame(rig.touch(1, 60))
        }

        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
        XCTAssertTrue(rig.engine.buttonDown)
    }

    /// Lifting every finger releases the held click.
    func testFullLiftReleases() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        rig.liftAll()

        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"])
        XCTAssertFalse(rig.engine.buttonDown)
    }

    /// Negative pressure (sensor noise) is clamped to zero and
    /// never fires.
    func testNegativePressureNeverFires() {
        let rig = makeRig(threshold: 50)

        for _ in 0..<3 {
            rig.frame(rig.touch(1, -5))
        }

        XCTAssertEqual(rig.log, [])
        XCTAssertFalse(rig.engine.buttonDown)
    }

    /// After an ease-off release, pressing again within the same
    /// touch session fires a fresh click. (The clock is advanced
    /// past the double-click interval so the chain restarts at 1.)
    func testPressAgainAfterEaseReleaseFiresSecondDown() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        rig.frame(rig.touch(1, 34))
        XCTAssertFalse(rig.engine.buttonDown)

        rig.advance(0.6)
        rig.frame(rig.touch(1, 60))

        XCTAssertEqual(rig.log, [
            "down(1)@500,500", "hapticDown", "up(1)", "hapticUp",
            "down(1)@500,500", "hapticDown",
        ])
        XCTAssertTrue(rig.engine.buttonDown)
    }

    /// The pressure callback reports the handled touch's pressure,
    /// and reports 0 when the sequence ends (finger lifted).
    func testPressureCallbackReportsHandledTouchThenZeroOnLift() {
        let rig = makeRig(threshold: 50)
        var reported: [Double] = []
        rig.engine.onPressureChange = { reported.append($0) }

        rig.frame(rig.touch(1, 25))
        XCTAssertEqual(reported, [25])

        rig.liftAll()
        XCTAssertEqual(reported, [25, 0])
    }
}
#endif
