#if canImport(XCTest)
import XCTest
@testable import LightClickCore

/// Native-parity behaviours from the macOS trackpad research:
/// contacts are size-filtered before anything else (palm
/// rejection), the button channel is never vetoed by the gesture
/// layer (a sustained hard press clicks even mid-scroll), and a
/// gesture is recognised by speed as well as by travel (velocity
/// trigger).
@MainActor
final class NativeParityTests: EngineTestCase {
    // MARK: - Palm rejection

    func testPalmAloneCannotClick() {
        let rig = makeRig()
        rig.frame(rig.touch(1, 80, major: 25)) // a palm leaning hard on the pad
        rig.frame(rig.touch(1, 80, major: 25))
        XCTAssertEqual(rig.log, [])
        XCTAssertFalse(rig.engine.buttonDown)
    }

    func testPalmPlusFingerPressFiresInstantly() {
        let rig = makeRig()
        // The palm does not count as a second finger, so the real
        // press is a single-finger press: first frame, no dwell.
        rig.frame(rig.touch(1, 80, major: 25), rig.touch(2, 60))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
    }

    func testPalmDoesNotDisturbAScrollGate() {
        let rig = makeRig()
        // Palm resting on the pad while two real fingers scroll:
        // the gate sees exactly the two fingers.
        var y = 0.50
        for _ in 0 ..< 4 {
            rig.frame(
                rig.touch(1, 70, x: 0.15, y: 0.80, major: 25),
                rig.touch(2, 60, x: 0.40, y: y),
                rig.touch(3, 20, x: 0.60, y: y + 0.05)
            )
            y += 0.015
        }
        XCTAssertEqual(rig.log, [])
        XCTAssertTrue(rig.engine.gestureMoved)
    }

    func testTrackedFingerFlatteningIsExemptFromPalmFilter() {
        let rig = makeRig()
        rig.frame(rig.touch(1, 60, major: 10)) // fingertip lands, click fires
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])

        // Pressing flattens the finger: its ellipse grows past the
        // palm cutoff. The tracked finger is exempt — the click must
        // not be cancelled mid-press.
        rig.frame(rig.touch(1, 60, major: 24))
        XCTAssertTrue(rig.engine.buttonDown)
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])

        rig.frame(rig.touch(1, 20, major: 24)) // ease off → normal release
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"])
    }

    func testPalmDoesNotCountAsTouchActivity() {
        let rig = makeRig()
        rig.frame(rig.touch(1, 60, major: 25)) // palm only
        // A native press right after a palm contact is not "the
        // trackpad's own press" — palms are not touches for any
        // purpose, so it passes through as another input source.
        XCTAssertFalse(rig.nativeDown())
        XCTAssertEqual(rig.log, [])
    }

    // MARK: - Hard-press override during a classified scroll

    /// Classify a scroll with finger 1 tracked (32) and finger 2
    /// resting (20 — below the 25 two-finger arming line, so the
    /// pair does not lock), both gliding. Returns after 3 frames.
    private func classifyScroll(_ rig: TestRig) {
        var y = 0.50
        for _ in 0 ..< 3 {
            rig.frame(
                rig.touch(1, 32, x: 0.40, y: y),
                rig.touch(2, 20, x: 0.60, y: y + 0.05)
            )
            y += 0.015
        }
        XCTAssertTrue(rig.engine.gestureMoved)
        XCTAssertEqual(rig.log, [])
    }

    func testHardPressOverridesScrollGate() {
        let rig = makeRig() // threshold 50 → override needs a sustained 100
        classifyScroll(rig)

        rig.frame(rig.touch(1, 110, x: 0.40, y: 0.545), rig.touch(2, 30, x: 0.60, y: 0.595))
        XCTAssertEqual(rig.log, []) // one hard frame is not enough
        rig.frame(rig.touch(1, 110, x: 0.40, y: 0.56), rig.touch(2, 30, x: 0.60, y: 0.61))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"]) // sustained → clicks, like a real Mac

        rig.frame(rig.touch(1, 110, x: 0.40, y: 0.575), rig.touch(2, 30, x: 0.60, y: 0.625))
        XCTAssertTrue(rig.engine.buttonDown) // holding turns the scroll into a drag

        rig.frame(rig.touch(1, 30, x: 0.40, y: 0.59), rig.touch(2, 30, x: 0.60, y: 0.64))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"]) // ease off → release
    }

    func testHardPressNeedsTwoSustainedFrames() {
        let rig = makeRig()
        classifyScroll(rig)

        rig.frame(rig.touch(1, 110, x: 0.40, y: 0.545), rig.touch(2, 30, x: 0.60, y: 0.595))
        rig.frame(rig.touch(1, 30, x: 0.40, y: 0.56), rig.touch(2, 30, x: 0.60, y: 0.61))
        rig.frame(rig.touch(1, 30, x: 0.40, y: 0.575), rig.touch(2, 30, x: 0.60, y: 0.625))
        XCTAssertEqual(rig.log, []) // a single-frame spike at 2x is scroll load, not a press
    }

    func testHardPressNeedsDoubleTheThreshold() {
        let rig = makeRig()
        classifyScroll(rig)

        for i in 0 ..< 5 { // 75 = 1.5x threshold, sustained — still scroll load
            rig.frame(
                rig.touch(1, 75, x: 0.40, y: 0.545 + Double(i) * 0.015),
                rig.touch(2, 30, x: 0.60, y: 0.595 + Double(i) * 0.015)
            )
        }
        XCTAssertEqual(rig.log, [])
    }

    func testHardPressOverrideScalesWithTheThreshold() {
        let rig = makeRig(threshold: 30) // override needs a sustained 60 here
        var y = 0.50
        for _ in 0 ..< 3 {
            // Finger 2 at 12 stays below the 15 arming line at this
            // threshold, so the pair scrolls instead of locking.
            rig.frame(rig.touch(1, 22, x: 0.40, y: y), rig.touch(2, 12, x: 0.60, y: y + 0.05))
            y += 0.015
        }
        XCTAssertTrue(rig.engine.gestureMoved)

        rig.frame(rig.touch(1, 60, x: 0.40, y: y), rig.touch(2, 20, x: 0.60, y: y + 0.05))
        XCTAssertEqual(rig.log, [])
        rig.frame(rig.touch(1, 60, x: 0.40, y: y + 0.015), rig.touch(2, 20, x: 0.60, y: y + 0.065))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
    }

    // MARK: - Velocity trigger

    func testVelocityClassifiesBeforeAnchorDistance() {
        let rig = makeRig()
        // Two stationary frames: the dwell counter reaches 2 (one
        // frame from firing) with no gesture classification.
        rig.frame(rig.touch(1, 60, x: 0.500, y: 0.50), rig.touch(2, 20, x: 0.700, y: 0.55))
        rig.frame(rig.touch(1, 60, x: 0.500, y: 0.50), rig.touch(2, 20, x: 0.700, y: 0.55))
        XCTAssertEqual(rig.log, [])
        XCTAssertFalse(rig.engine.gestureMoved)

        // One fast step of both fingers: 0.013 in a single frame.
        // Total travel is still under the ~2 mm anchor distance, so
        // only the velocity trigger can classify this — and it must,
        // or the dwell rule would fire the click on this very frame.
        // (Both fingers move: one finger moving beside a still one is
        // pointing with a resting thumb, not a gesture.)
        rig.frame(rig.touch(1, 60, x: 0.513, y: 0.50), rig.touch(2, 20, x: 0.713, y: 0.55))
        XCTAssertTrue(rig.engine.gestureMoved)
        XCTAssertEqual(rig.log, [])

        rig.frame(rig.touch(1, 60, x: 0.526, y: 0.50), rig.touch(2, 20, x: 0.726, y: 0.55))
        XCTAssertEqual(rig.log, []) // and it stays blocked
    }
}
#endif
