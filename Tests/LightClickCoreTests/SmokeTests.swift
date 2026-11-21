#if canImport(XCTest)
import XCTest
@testable import LightClickCore

/// Pipeline smoke tests: the smallest set that proves the harness
/// drives the engine and the engine's most basic contract holds.
/// The full behavioural suite lives in the sibling files.
@MainActor
final class SmokeTests: EngineTestCase {
    func testSinglePressFiresDownThenUpOnLift() {
        let rig = makeRig()
        rig.frame(rig.touch(1, 60))
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown"])
        XCTAssertTrue(rig.engine.buttonDown)

        rig.liftAll()
        XCTAssertEqual(rig.log, ["down(1)@500,500", "hapticDown", "up(1)", "hapticUp"])
        XCTAssertFalse(rig.engine.buttonDown)
    }

    func testBelowThresholdDoesNotFire() {
        let rig = makeRig()
        rig.frame(rig.touch(1, 49))
        XCTAssertEqual(rig.log, [])
        XCTAssertFalse(rig.engine.buttonDown)
    }

    func testNativeDownWithNoTouchHistoryPassesThrough() {
        let rig = makeRig()
        XCTAssertFalse(rig.nativeDown())
        XCTAssertEqual(rig.log, [])
    }
}
#endif
