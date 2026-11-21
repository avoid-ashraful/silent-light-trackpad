#if canImport(XCTest)
import XCTest
@testable import LightClickCore

/// DRAG LATCH: once a held click has moved the cursor ~5 px it is
/// a drag, and a drag must hold like a physical (latched) button —
/// it releases only at near-zero pressure (~10% of threshold) or
/// when every finger lifts. Without the latch, the snappy 70%
/// release line fired mid-drag whenever sliding the finger rolled
/// the contact and dipped the pressure reading, cancelling browser
/// tab drags outright. Clicks that never move keep the snappy
/// release exactly as before.
@MainActor
final class DragLatchTests: EngineTestCase {

    /// Press, move the cursor 20 px, then dip pressure to 34 —
    /// below the 70% snappy line (35 at threshold 50). Latched, so
    /// the button stays down and no mouse-up is posted.
    func testLatchedDragSurvivesDipBelowSnappyLine() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        rig.clock.cursor = ClickPoint(x: 520, y: 500)
        rig.frame(rig.touch(1, 60))
        XCTAssertTrue(rig.engine.dragLatched)

        rig.frame(rig.touch(1, 34))

        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
        XCTAssertTrue(rig.engine.buttonDown)
    }

    /// The same dip with only ~2 px of cursor movement never
    /// latches, so the plain snappy release still fires at 34 —
    /// ordinary clicks are unchanged.
    func testDipWithoutMovementStillReleasesSnappy() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        rig.clock.cursor = ClickPoint(x: 502, y: 500)
        rig.frame(rig.touch(1, 60))
        XCTAssertFalse(rig.engine.dragLatched)

        rig.frame(rig.touch(1, 34))

        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"])
        XCTAssertFalse(rig.engine.buttonDown)
    }

    /// A latched drag releases when the press genuinely ends:
    /// pressure at the ~10% line (5 at threshold 50) lets go,
    /// while 6 — just above it — still holds.
    func testLatchedDragReleasesAtNearZeroPressure() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        rig.clock.cursor = ClickPoint(x: 520, y: 500)
        rig.frame(rig.touch(1, 60))
        XCTAssertTrue(rig.engine.dragLatched)

        rig.frame(rig.touch(1, 6))
        XCTAssertTrue(rig.engine.buttonDown)

        rig.frame(rig.touch(1, 5))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"])
        XCTAssertFalse(rig.engine.buttonDown)
    }

    /// Lifting every finger releases a latched drag, as it
    /// releases any held click.
    func testLatchedDragReleasesOnFullLift() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        rig.clock.cursor = ClickPoint(x: 520, y: 500)
        rig.frame(rig.touch(1, 60))
        XCTAssertTrue(rig.engine.dragLatched)

        rig.liftAll()

        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"])
        XCTAssertFalse(rig.engine.buttonDown)
    }

    /// The latch resets on release: the next click starts
    /// unlatched, so a stationary press after a drag still gets
    /// the snappy release.
    func testLatchResetsForNextClick() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        rig.clock.cursor = ClickPoint(x: 520, y: 500)
        rig.frame(rig.touch(1, 60))
        XCTAssertTrue(rig.engine.dragLatched)
        rig.liftAll()
        XCTAssertFalse(rig.engine.dragLatched)

        // Past the double-click interval, so the chain restarts.
        rig.advance(0.6)
        rig.clearLog()
        rig.frame(rig.touch(1, 60))
        XCTAssertFalse(rig.engine.dragLatched)

        rig.frame(rig.touch(1, 34))
        XCTAssertEqual(rig.log, ["down(1)@520,500", "hapticDown", "up(1)", "hapticUp"])
        XCTAssertFalse(rig.engine.buttonDown)
    }
}
#endif
