#if canImport(XCTest)
import XCTest
@testable import LightClickCore

/// The fast-jab path: a hard, fast press can cross Apple's native
/// threshold before the next touch frame arrives, so the native
/// click reaches the event tap first. The engine must swallow it
/// and answer with its own click — exactly once — and that
/// tap-fired click must behave like any other click (hold, drag,
/// release, chain) and must never be stranded down.
@MainActor
final class JabTests: EngineTestCase {
    func testJabFiresImmediatelyAndSwallows() {
        let rig = makeRig()
        rig.frame(rig.touch(1, 10)) // light touch on the glass, no click yet
        XCTAssertEqual(rig.log, [])

        XCTAssertTrue(rig.nativeDown()) // swallowed…
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"]) // …and answered with ours
        XCTAssertTrue(rig.engine.buttonDown)
    }

    func testJabClickHoldsAndReleasesWithPressure() {
        let rig = makeRig()
        rig.frame(rig.touch(1, 10))
        XCTAssertTrue(rig.nativeDown())

        rig.frame(rig.touch(1, 60)) // the presser's frames catch up
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"]) // no second click
        XCTAssertTrue(rig.engine.buttonDown)

        rig.frame(rig.touch(1, 20)) // ease off → snappy release
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"])
        XCTAssertFalse(rig.engine.buttonDown)
    }

    func testJabWithRestingThumbHandsClickToThePresser() {
        let rig = makeRig()
        rig.frame(rig.touch(1, 12)) // thumb lands first and is tracked
        rig.frame(rig.touch(1, 12), rig.touch(2, 10)) // finger rests too
        XCTAssertTrue(rig.nativeDown()) // the finger's jab wins the race
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])

        rig.advance(0.02)
        // The presser now crosses the threshold in the frames. The
        // held click is fresh and tap-fired, so it belongs to the
        // presser: tracking hands over, the click stays down, and
        // the engine must NOT read this as a chord and lock.
        rig.frame(rig.touch(1, 12), rig.touch(2, 60))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
        XCTAssertTrue(rig.engine.buttonDown)
        XCTAssertFalse(rig.engine.isLocked)

        rig.frame(rig.touch(1, 12), rig.touch(2, 20)) // presser eases off
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"])
    }

    func testJabClickIsReleasedWhenAllFingersLift() {
        let rig = makeRig()
        rig.frame(rig.touch(1, 10))
        XCTAssertTrue(rig.nativeDown())
        XCTAssertTrue(rig.engine.buttonDown)

        rig.liftAll() // the touch session ends while no finger is tracked as presser
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"])
        XCTAssertFalse(rig.engine.buttonDown)
    }

    func testJabClickIsReleasedBeforeATwoFingerLock() {
        let rig = makeRig()
        rig.frame(rig.touch(1, 10))
        XCTAssertTrue(rig.nativeDown())
        XCTAssertTrue(rig.engine.buttonDown)

        // Finger 1 lifts; two fresh fingers land already pressing.
        // The engine must release the tap-fired click before locking,
        // never stranding it down for the whole lock.
        rig.frame(rig.touch(2, 30), rig.touch(3, 30))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"])
        XCTAssertFalse(rig.engine.buttonDown)
        XCTAssertTrue(rig.engine.isLocked)
    }

    func testNativeDownDuringScrollIsSwallowedButNotConverted() {
        let rig = makeRig()
        // Classify a scroll (two fingers gliding; finger 2 below
        // the arming line, so this is the gate, not the lock).
        rig.frame(rig.touch(1, 30, x: 0.40, y: 0.50), rig.touch(2, 20, x: 0.60, y: 0.55))
        rig.frame(rig.touch(1, 30, x: 0.40, y: 0.515), rig.touch(2, 20, x: 0.60, y: 0.565))
        rig.frame(rig.touch(1, 30, x: 0.40, y: 0.53), rig.touch(2, 20, x: 0.60, y: 0.58))
        XCTAssertTrue(rig.engine.gestureMoved)

        XCTAssertTrue(rig.nativeDown()) // swallowed…
        XCTAssertEqual(rig.log, []) // …but NOT answered with a click mid-scroll
        XCTAssertFalse(rig.engine.buttonDown)
    }

    func testNativeDownWhileLockedIsSwallowedButNotConverted() {
        let rig = makeRig()
        rig.frame(rig.touch(1, 30), rig.touch(2, 30)) // two-finger press → lock
        XCTAssertTrue(rig.engine.isLocked)

        XCTAssertTrue(rig.nativeDown())
        XCTAssertEqual(rig.log, [])
    }

    func testJabClickCountsTowardTheClickChain() {
        let rig = makeRig()
        rig.frame(rig.touch(1, 10))
        XCTAssertTrue(rig.nativeDown()) // click 1, tap-fired
        rig.liftAll()
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"])

        rig.advance(0.1)
        rig.frame(rig.touch(1, 60)) // a normal pressure press right after
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp", "down(2)@500,500", "hapticDown"])
    }
}
#endif
