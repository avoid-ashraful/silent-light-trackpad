import XCTest
@testable import LightClickCore

/// The two-finger lock: two fingers pressing together is a
/// two-finger (secondary) click, never a left click. The engine
/// locks until EVERY finger lifts; while locked, all frames are
/// ignored. The same lock follows a chord — a second finger
/// reaching full threshold while a click is held.
@MainActor
final class TwoFingerLockTests: EngineTestCase {

    /// Both fingers at 30 (>= 50% of the 50 threshold) on the first
    /// frame: lock, no output.
    func testTwoFingersPressingTogetherLock() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 30), rig.touch(2, 30))
        XCTAssertEqual(rig.log, [])
        XCTAssertTrue(rig.engine.isLocked)
        XCTAssertFalse(rig.engine.buttonDown)
    }

    /// Both fingers at full pressure together: still a two-finger
    /// click — lock, no left click.
    func testTwoFingersAtFullPressureTogetherLock() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60), rig.touch(2, 60))
        XCTAssertEqual(rig.log, [])
        XCTAssertTrue(rig.engine.isLocked)
        XCTAssertFalse(rig.engine.buttonDown)
    }

    /// While locked, pressing harder changes nothing.
    func testHarderPressingWhileLockedDoesNothing() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 30), rig.touch(2, 30))
        XCTAssertTrue(rig.engine.isLocked)
        rig.clearLog()

        for _ in 0..<3 {
            rig.frame(rig.touch(1, 80), rig.touch(2, 80))
            XCTAssertEqual(rig.log, [])
            XCTAssertTrue(rig.engine.isLocked)
            XCTAssertFalse(rig.engine.buttonDown)
        }
    }

    /// The lock clears ONLY on an empty frame: one finger lifting
    /// leaves the engine locked and the remaining finger's press is
    /// ignored. After a full lift, a normal press works again.
    func testLockPersistsWhileOneFingerRemains() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 30), rig.touch(2, 30))
        XCTAssertTrue(rig.engine.isLocked)

        rig.frame(rig.touch(1, 60))
        XCTAssertEqual(rig.log, [])
        XCTAssertTrue(rig.engine.isLocked)

        rig.liftAll()
        XCTAssertFalse(rig.engine.isLocked)

        rig.frame(rig.touch(1, 60))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
    }

    /// Chord: a second finger reaching full threshold while a
    /// pressure-path click is held releases our click and locks.
    func testChordDuringHeldClickReleasesAndLocks() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
        XCTAssertTrue(rig.engine.buttonDown)

        rig.frame(rig.touch(1, 60), rig.touch(2, 60))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"])
        XCTAssertFalse(rig.engine.buttonDown)
        XCTAssertTrue(rig.engine.isLocked)

        rig.liftAll()
        XCTAssertFalse(rig.engine.isLocked)
    }

    /// After a chord lock and a full lift, the next press works —
    /// and because no time has passed and the cursor has not moved,
    /// it chains as click 2, proving the click chain survived the
    /// lock.
    func testPressAfterChordLockChainsClickCount() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        rig.frame(rig.touch(1, 60), rig.touch(2, 60))
        XCTAssertTrue(rig.engine.isLocked)
        rig.liftAll()
        XCTAssertFalse(rig.engine.isLocked)

        rig.frame(rig.touch(1, 60))
        XCTAssertEqual(rig.log, [
            "down(1)@500,500", "hapticDown", "up(1)", "hapticUp",
            "down(2)@500,500", "hapticDown",
        ])
    }
}
