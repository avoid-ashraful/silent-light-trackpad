import XCTest
@testable import LightClickCore

/// reset() is the app's stop path for the decision state: it must
/// release any held click and clear every sequence, lock and gate,
/// so a restart begins from a clean slate.
@MainActor
final class ResetTests: EngineTestCase {

    /// Resetting mid-press posts the release for the held click.
    func testResetMidPressReleases() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
        XCTAssertTrue(rig.engine.buttonDown)

        rig.engine.reset()
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"])
        XCTAssertFalse(rig.engine.buttonDown)
    }

    /// Resetting clears the two-finger lock without needing an
    /// empty frame: the next press fires normally.
    func testResetClearsTwoFingerLock() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 30), rig.touch(2, 30))
        XCTAssertTrue(rig.engine.isLocked)

        rig.engine.reset()
        XCTAssertFalse(rig.engine.isLocked)

        rig.frame(rig.touch(1, 60))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
    }

    /// Resetting clears the scroll/gesture classification.
    func testResetClearsGestureClassification() {
        let rig = makeRig(threshold: 50)

        // Two fingers gliding: ~1.5 mm of travel per frame trips
        // the velocity trigger on the second frame.
        rig.frame(rig.touch(1, 30, y: 0.50), rig.touch(2, 30, y: 0.55))
        rig.frame(rig.touch(1, 30, y: 0.515), rig.touch(2, 30, y: 0.565))
        rig.frame(rig.touch(1, 30, y: 0.53), rig.touch(2, 30, y: 0.58))
        XCTAssertTrue(rig.engine.gestureMoved)

        rig.engine.reset()
        XCTAssertFalse(rig.engine.gestureMoved)
    }

    /// Resetting an idle engine is a no-op: no output, and a normal
    /// press still works afterwards.
    func testResetWhenIdleIsNoOp() {
        let rig = makeRig(threshold: 50)

        rig.engine.reset()
        XCTAssertEqual(rig.log, [])
        XCTAssertFalse(rig.engine.buttonDown)
        XCTAssertFalse(rig.engine.isLocked)
        XCTAssertFalse(rig.engine.gestureMoved)

        rig.frame(rig.touch(1, 60))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
    }
}
