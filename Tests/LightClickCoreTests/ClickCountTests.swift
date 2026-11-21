#if canImport(XCTest)
import XCTest
@testable import LightClickCore

/// Click-state chaining: a press within the double-click interval
/// (0.5 s in the rig) and within 5 px (dx² + dy² ≤ 25) of the
/// previous press bumps the count; the matching up carries it.
@MainActor
final class ClickCountTests: EngineTestCase {

    /// Two quick presses at the same spot chain: the second down
    /// and its up both carry click state 2.
    func testDoublePressChainsToClickState2() {
        let rig = makeRig()

        rig.frame(rig.touch(1, 60))
        rig.liftAll()
        rig.advance(0.1)
        rig.frame(rig.touch(1, 60))
        rig.liftAll()

        XCTAssertEqual(rig.log, [
            "down(1)@500,500", "hapticDown", "up(1)", "hapticUp",
            "down(2)@500,500", "hapticDown", "up(2)", "hapticUp",
        ])
    }

    /// Three quick presses chain to click state 3 (line select).
    func testTriplePressChainsToClickState3() {
        let rig = makeRig()

        rig.frame(rig.touch(1, 60))
        rig.liftAll()
        rig.advance(0.1)
        rig.frame(rig.touch(1, 60))
        rig.liftAll()
        rig.advance(0.1)
        rig.frame(rig.touch(1, 60))
        rig.liftAll()

        XCTAssertEqual(rig.log, [
            "down(1)@500,500", "hapticDown", "up(1)", "hapticUp",
            "down(2)@500,500", "hapticDown", "up(2)", "hapticUp",
            "down(3)@500,500", "hapticDown", "up(3)", "hapticUp",
        ])
    }

    /// Waiting past the double-click interval restarts the chain.
    func testPressAfterIntervalRestartsAtClickState1() {
        let rig = makeRig()

        rig.frame(rig.touch(1, 60))
        rig.liftAll()
        rig.advance(0.6)
        rig.frame(rig.touch(1, 60))
        rig.liftAll()

        XCTAssertEqual(rig.log, [
            "down(1)@500,500", "hapticDown", "up(1)", "hapticUp",
            "down(1)@500,500", "hapticDown", "up(1)", "hapticUp",
        ])
    }

    /// A press 10 px away, though well within the interval, breaks
    /// the chain on distance.
    func testPressFarAwayBreaksChain() {
        let rig = makeRig()

        rig.frame(rig.touch(1, 60))
        rig.liftAll()
        rig.clock.cursor = ClickPoint(x: 510, y: 500)
        rig.advance(0.1)
        rig.frame(rig.touch(1, 60))
        rig.liftAll()

        XCTAssertEqual(rig.log, [
            "down(1)@500,500", "hapticDown", "up(1)", "hapticUp",
            "down(1)@510,500", "hapticDown", "up(1)", "hapticUp",
        ])
    }

    /// Boundary: an offset of (3, 4) gives dx² + dy² = 25, which is
    /// still within tolerance — the chain holds.
    func testPressAtDistanceBoundaryStillChains() {
        let rig = makeRig()

        rig.frame(rig.touch(1, 60))
        rig.liftAll()
        rig.clock.cursor = ClickPoint(x: 503, y: 504)
        rig.advance(0.1)
        rig.frame(rig.touch(1, 60))
        rig.liftAll()

        XCTAssertEqual(rig.log, [
            "down(1)@500,500", "hapticDown", "up(1)", "hapticUp",
            "down(2)@503,504", "hapticDown", "up(2)", "hapticUp",
        ])
    }

    /// Just past the boundary: an offset of (4, 4) gives
    /// dx² + dy² = 32 > 25 — the chain breaks.
    func testPressJustPastDistanceBoundaryBreaksChain() {
        let rig = makeRig()

        rig.frame(rig.touch(1, 60))
        rig.liftAll()
        rig.clock.cursor = ClickPoint(x: 504, y: 504)
        rig.advance(0.1)
        rig.frame(rig.touch(1, 60))
        rig.liftAll()

        XCTAssertEqual(rig.log, [
            "down(1)@500,500", "hapticDown", "up(1)", "hapticUp",
            "down(1)@504,504", "hapticDown", "up(1)", "hapticUp",
        ])
    }

    /// The chain is about time and place, not about which finger
    /// pressed: a second press by a different finger still counts.
    func testChainContinuesAcrossDifferentFingers() {
        let rig = makeRig()

        rig.frame(rig.touch(1, 60))
        rig.liftAll()
        rig.advance(0.1)
        rig.frame(rig.touch(2, 60))
        rig.liftAll()

        XCTAssertEqual(rig.log, [
            "down(1)@500,500", "hapticDown", "up(1)", "hapticUp",
            "down(2)@500,500", "hapticDown", "up(2)", "hapticUp",
        ])
    }
}
#endif
