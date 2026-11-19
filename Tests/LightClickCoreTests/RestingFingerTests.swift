import XCTest
@testable import LightClickCore

/// Resting-finger support: the engine tracks ONE finger (the
/// presser) and ignores fingers that merely rest on the glass.
/// With two or more fingers down, a press fires only on the 3rd
/// consecutive frame at/above threshold (the dwell rule); a
/// single-finger press fires on the 1st frame.
@MainActor
final class RestingFingerTests: EngineTestCase {

    /// Thumb resting at low pressure + a finger pressing: the dwell
    /// rule applies (two fingers on the glass), so the click fires
    /// on the 3rd frame, and lifting everything releases it.
    func testRestingThumbPlusPressFiresOnThirdFrame() {
        let rig = makeRig(threshold: 50)
        let thumb = rig.touch(1, 8)
        let finger = rig.touch(2, 60)

        rig.frame(thumb, finger)
        XCTAssertEqual(rig.log, [])
        rig.frame(thumb, finger)
        XCTAssertEqual(rig.log, [])
        rig.frame(thumb, finger)
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
        XCTAssertTrue(rig.engine.buttonDown)

        rig.liftAll()
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"])
        XCTAssertFalse(rig.engine.buttonDown)
    }

    /// A finger already being tracked at low pressure (so it owns
    /// the tracking) starts pressing while a thumb rests: dwell
    /// still applies once the second finger is on the glass.
    func testRestingFingerLandsAfterTracking() {
        let rig = makeRig(threshold: 50)

        // Finger 1 lands alone at resting pressure: it is tracked.
        rig.frame(rig.touch(1, 10))
        XCTAssertEqual(rig.log, [])

        let finger = rig.touch(1, 60)
        let thumb = rig.touch(2, 8)
        rig.frame(finger, thumb)
        XCTAssertEqual(rig.log, [])
        rig.frame(finger, thumb)
        XCTAssertEqual(rig.log, [])
        rig.frame(finger, thumb)
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
    }

    /// A resting finger landing during a held click never disturbs
    /// it: no extra output, the button stays down until all lift.
    func testRestingFingerNeverDisturbsAHold() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
        rig.clearLog()

        for _ in 0..<3 {
            rig.frame(rig.touch(1, 60), rig.touch(2, 10))
            XCTAssertEqual(rig.log, [])
            XCTAssertTrue(rig.engine.buttonDown)
        }

        rig.liftAll()
        XCTAssertEqual(rig.log, ["up(1)", "hapticUp"])
    }

    /// The pressing finger lifts while the thumb keeps resting: the
    /// click releases WITHOUT locking, and the remaining finger can
    /// then press on its own — now a single finger, so it fires on
    /// the 1st frame. (No time passes, so the second click chains:
    /// down(2).)
    func testPresserLiftsRestingFingerPressesOnItsOwn() {
        let rig = makeRig(threshold: 50)
        let thumb = rig.touch(1, 8)
        let finger = rig.touch(2, 60)

        rig.frame(thumb, finger)
        rig.frame(thumb, finger)
        rig.frame(thumb, finger)
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])

        // Presser lifts, thumb remains: release, no lock.
        rig.frame(thumb)
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"])
        XCTAssertFalse(rig.engine.buttonDown)
        XCTAssertFalse(rig.engine.isLocked)

        // The thumb presses on its own: single finger, 1st frame.
        rig.frame(rig.touch(1, 60))
        XCTAssertEqual(rig.log, [
            "down(1)@500,500", "hapticDown", "up(1)", "hapticUp",
            "down(2)@500,500", "hapticDown",
        ])
    }

    /// A second finger at 60% of threshold (30 of 50) during a held
    /// click is below the FULL threshold, so it is not a chord: the
    /// click stays down, no lock, no extra output.
    func testSecondFingerBelowFullThresholdIsNotAChord() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
        rig.clearLog()

        for _ in 0..<2 {
            rig.frame(rig.touch(1, 60), rig.touch(2, 30))
            XCTAssertEqual(rig.log, [])
            XCTAssertTrue(rig.engine.buttonDown)
            XCTAssertFalse(rig.engine.isLocked)
        }
    }

    /// A palm-sized contact (major axis 25 mm) is filtered out
    /// entirely — even at high pressure — so palm + resting thumb +
    /// pressing finger behaves exactly like thumb + finger alone.
    func testPalmPlusRestingPlusPress() {
        let rig = makeRig(threshold: 50)
        let palm = rig.touch(1, 70, major: 25)
        let thumb = rig.touch(2, 8)
        let finger = rig.touch(3, 60)

        rig.frame(palm, thumb, finger)
        XCTAssertEqual(rig.log, [])
        rig.frame(palm, thumb, finger)
        XCTAssertEqual(rig.log, [])
        rig.frame(palm, thumb, finger)
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])

        rig.liftAll()
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"])
    }
}
