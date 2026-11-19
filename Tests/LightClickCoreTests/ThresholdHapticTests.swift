import XCTest
@testable import LightClickCore

/// Threshold presets and haptic pairing: every synthetic down is
/// answered by a haptic down-pulse, every up by an up-pulse, at
/// every threshold the app offers.
@MainActor
final class ThresholdHapticTests: EngineTestCase {

    /// For every preset the menu offers (30/40/50/60/80): a press
    /// 5 units below the threshold stays silent, a press 10 units
    /// above it fires.
    func testEveryPresetThresholdSeparatesBelowFromAbove() {
        for preset in [30.0, 40.0, 50.0, 60.0, 80.0] {
            let rig = makeRig(threshold: preset)

            rig.frame(rig.touch(1, preset - 5))
            XCTAssertEqual(rig.log, [], "threshold \(preset): \(preset - 5) must not fire")
            XCTAssertFalse(rig.engine.buttonDown, "threshold \(preset)")

            rig.frame(rig.touch(1, preset + 10))
            XCTAssertEqual(
                rig.log,
                ["down(1)@500,500", "hapticDown"],
                "threshold \(preset): \(preset + 10) must fire"
            )
            XCTAssertTrue(rig.engine.buttonDown, "threshold \(preset)")
        }
    }

    /// Across a full double-click cycle the haptics pair exactly
    /// with the events: down-pulse after each down, up-pulse after
    /// each up, nothing extra.
    func testHapticsPairAcrossDoubleClickCycle() {
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

    /// The same pressure is a click at a light threshold and
    /// nothing at a heavy one: 35 fires at threshold 30 and is
    /// ignored at threshold 80.
    func testLowerThresholdFiresWhereHigherDoesNot() {
        let light = makeRig(threshold: 30)
        light.frame(light.touch(1, 35))
        XCTAssertEqual(light.log, ["down(1)@500,500", "hapticDown"])
        XCTAssertTrue(light.engine.buttonDown)

        let heavy = makeRig(threshold: 80)
        heavy.frame(heavy.touch(1, 35))
        XCTAssertEqual(heavy.log, [])
        XCTAssertFalse(heavy.engine.buttonDown)
    }
}
