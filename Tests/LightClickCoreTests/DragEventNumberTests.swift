#if canImport(XCTest)
import XCTest
@testable import LightClickCore

/// DRAG EVENT NUMBERS: macOS treats a mouse-down / dragged /
/// mouse-up sequence as a single drag only when every event
/// carries the same kCGMouseEventNumber. A hardware press gets
/// one number for its whole sequence; the engine must assign its
/// own — one per press, stamped on the down, every dragged event
/// and the up. (Without this, Chromium tab drags and Mission
/// Control window drags silently never started: the original app
/// mutated hardware mouseMoved events into dragged ones, keeping
/// their unrelated event numbers and a click state of 0.) The
/// engine now replaces movement during a held press with its own
/// dragged events; these tests pin the numbering and the
/// replacement behaviour.
@MainActor
final class DragEventNumberTests: EngineTestCase {

    /// Down, two dragged events and the up of one press all share
    /// the press's event number.
    func testWholeSequenceSharesOneEventNumber() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        XCTAssertTrue(rig.move(to: ClickPoint(x: 520, y: 500)))
        XCTAssertTrue(rig.move(to: ClickPoint(x: 560, y: 500)))
        rig.liftAll()

        XCTAssertEqual(rig.log, [
            "down(1)@500,500", "hapticDown",
            "drag(1)@520,500", "drag(1)@560,500",
            "up(1)", "hapticUp",
        ])
        XCTAssertEqual(rig.numbers, [1, 1, 1, 1])
    }

    /// Each new press gets a fresh number, shared by its own
    /// sequence and different from the previous press's.
    func testEachPressGetsAFreshEventNumber() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        rig.liftAll()

        // Past the double-click interval, so the chain restarts.
        rig.advance(0.6)
        rig.frame(rig.touch(1, 60))
        XCTAssertTrue(rig.move(to: ClickPoint(x: 520, y: 500)))
        rig.liftAll()

        XCTAssertEqual(rig.numbers, [1, 1, 2, 2, 2])
    }

    /// A move with no press held is not ours: it passes (returns
    /// false) and nothing is posted.
    func testMoveWithoutPressPassesAndPostsNothing() {
        let rig = makeRig(threshold: 50)

        XCTAssertFalse(rig.move(to: ClickPoint(x: 520, y: 500)))

        XCTAssertEqual(rig.log, [])
        XCTAssertEqual(rig.numbers, [])
    }

    /// A dragged event carries the click state of the press it
    /// belongs to — the second press of a double-click drags with
    /// click state 2, under its own event number.
    func testDraggedCarriesThePressClickState() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        rig.liftAll()
        // Same spot, no time passing: the chain makes this click 2.
        rig.frame(rig.touch(1, 60))
        XCTAssertTrue(rig.move(to: ClickPoint(x: 520, y: 500)))
        rig.liftAll()

        XCTAssertEqual(rig.log, [
            "down(1)@500,500", "hapticDown", "up(1)", "hapticUp",
            "down(2)@500,500", "hapticDown", "drag(2)@520,500", "up(2)", "hapticUp",
        ])
        XCTAssertEqual(rig.numbers, [1, 1, 2, 2, 2])
    }

    /// A press that began through the fast-jab path (a native
    /// press the tap answered) drags under its event number too —
    /// both paths share the one fireButtonDown funnel.
    func testJabPressDragSharesItsEventNumber() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 10)) // touch activity, no press yet
        XCTAssertTrue(rig.nativeDown()) // jab: swallowed, our down fires
        XCTAssertTrue(rig.move(to: ClickPoint(x: 520, y: 500)))
        rig.liftAll()

        XCTAssertEqual(rig.log, [
            "down(1)@500,500", "hapticDown", "drag(1)@520,500", "up(1)", "hapticUp",
        ])
        XCTAssertEqual(rig.numbers, [1, 1, 1])
    }
}
#endif
