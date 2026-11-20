import XCTest
@testable import LightClickCore

/// The event-tap decisions: which native mouse events the engine
/// swallows (they are the trackpad's own press, or duplicates of
/// ours) and which pass through (they belong to another input
/// source). The fast-jab window is 0.15 s after the last touch
/// activity; the native-up ignore window after our release is
/// also 0.15 s.
@MainActor
final class NativeEventTests: EngineTestCase {

    /// A native down with no touch ever: an external mouse — pass.
    func testNativeDownWithNoTouchPasses() {
        let rig = makeRig(threshold: 50)

        XCTAssertFalse(rig.nativeDown())
        XCTAssertEqual(rig.log, [])
    }

    /// A native down while our synthetic button is down is the
    /// trackpad's own press arriving after ours: swallow it, post
    /// nothing more.
    func testNativeDownWhileButtonDownIsSwallowed() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        XCTAssertTrue(rig.engine.buttonDown)
        rig.clearLog()

        XCTAssertTrue(rig.nativeDown())
        XCTAssertEqual(rig.log, [])
    }

    /// A native up while our button is down pairs with our click:
    /// swallow it.
    func testNativeUpWhileButtonDownIsSwallowed() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        XCTAssertTrue(rig.engine.buttonDown)

        XCTAssertTrue(rig.nativeUp())
    }

    /// The native echo of a click we just released is swallowed
    /// (ignore window: release time + 0.15 s); after the window, a
    /// native up passes through.
    func testNativeUpAfterReleaseSwallowedOnlyWithinWindow() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 60))
        rig.liftAll()
        XCTAssertFalse(rig.engine.buttonDown)

        XCTAssertTrue(rig.nativeUp())

        rig.advance(0.2)
        XCTAssertFalse(rig.nativeUp())
    }

    /// A native up with no history at all: nothing of ours to pair
    /// with — pass.
    func testNativeUpWithNoHistoryPasses() {
        let rig = makeRig(threshold: 50)

        XCTAssertFalse(rig.nativeUp())
        XCTAssertEqual(rig.log, [])
    }

<<<<<<< HEAD
    /// A native move is replaced by the engine's own dragged
    /// event exactly while our button is held; with no button
    /// held it passes untouched and posts nothing.
    func testMoveReplacementFollowsButton() {
        let rig = makeRig(threshold: 50)

        XCTAssertFalse(rig.move(to: ClickPoint(x: 510, y: 500)))
        XCTAssertEqual(rig.log, [])

        rig.frame(rig.touch(1, 60))
        XCTAssertTrue(rig.move(to: ClickPoint(x: 520, y: 500)))
        XCTAssertTrue(rig.log.contains("drag(1)@520,500"))

        rig.liftAll()
        XCTAssertFalse(rig.move(to: ClickPoint(x: 530, y: 500)))
=======
    /// Move-to-drag conversion is exactly "our button is held".
    func testDragConversionFlagFollowsButton() {
        let rig = makeRig(threshold: 50)

        XCTAssertFalse(rig.engine.shouldConvertMoveToDrag)

        rig.frame(rig.touch(1, 60))
        XCTAssertTrue(rig.engine.shouldConvertMoveToDrag)

        rig.liftAll()
        XCTAssertFalse(rig.engine.shouldConvertMoveToDrag)
>>>>>>> ci/swift61-build-test
    }

    /// A native down 0.2 s after the last touch activity is outside
    /// the 0.15 s fast-jab window: it belongs to another input
    /// source — pass, and fire nothing.
    func testNativeDownLongAfterTouchActivityPasses() {
        let rig = makeRig(threshold: 50)

        rig.frame(rig.touch(1, 10))
        rig.advance(0.2)

        XCTAssertFalse(rig.nativeDown())
        XCTAssertEqual(rig.log, [])
        XCTAssertFalse(rig.engine.buttonDown)
    }
}
