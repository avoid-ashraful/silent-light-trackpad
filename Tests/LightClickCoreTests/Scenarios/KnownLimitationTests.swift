import Testing
@testable import LightClickCore

/// Behaviour the fuzz sessions found that differs from a native
/// trackpad but follows from deliberate engine tradeoffs. Each test
/// asserts what a user would WANT inside `withKnownIssue`, so the
/// suite stays green today — and fails loudly ("known issue was not
/// recorded") the day the engine changes, prompting a decision.
@MainActor
@Suite("Known limitations (found by fuzzing)")
struct KnownLimitationTests {
    /// A quick light click (above the threshold for only one or two
    /// frames, ~8–16 ms) with a thumb resting on the pad is dropped:
    /// with two fingers down, the scroll-spike guard requires the
    /// press to hold for 3 frames. Without the resting thumb the same
    /// press clicks. A press hard enough for macOS's own click (~90)
    /// is rescued by the native path.
    @Test func quickLightClickWithRestingThumbIsDropped() {
        let quick = Press(peak: 70, rampFrames: 3, holdFrames: 0, releaseFrames: 1)

        let alone = Performer(rig: TestRig())
        alone.perform(.click(quick))
        #expect(alone.clicks.count == 1, "control: the same press without a resting thumb clicks")

        let withThumb = Performer(rig: TestRig())
        withThumb.perform(.restingFingerClick(restPressure: 15, press: quick))
        #expect(withThumb.violations().isEmpty, "\(withThumb.report())")
        withKnownIssue("Quick light press with a resting finger never reaches the 3-frame dwell") {
            #expect(withThumb.clicks.count == 1, "a native trackpad clicks here")
        }

        let hard = Performer(rig: TestRig())
        hard.perform(.restingFingerClick(restPressure: 15, press: Press(peak: 120, rampFrames: 2, holdFrames: 0, releaseFrames: 1)))
        #expect(hard.clicks.count == 1, "a press past macOS's native click is rescued by the native path")
    }

    /// Starting a slow drag: the fingertip rolls and its pressure
    /// dips under 70% of the threshold before the cursor has moved
    /// 5 px, so the drag latch is not set yet. The press releases,
    /// then re-presses as pressure recovers: apps see two short
    /// clicks — chained into a DOUBLE-click — instead of one drag.
    /// (In Finder that can open the file you meant to move.)
    @Test func slowDragStartWithEarlyPressureDipBecomesDoubleClick() {
        let performer = Performer(rig: TestRig(threshold: 50))
        // 12 px of travel over 8 frames; pressure 70 → 20 → 70.
        performer.perform(.drag(press: Press(peak: 70, rampFrames: 3, holdFrames: 2, releaseFrames: 2),
                                dx: 0.012, dy: 0, frames: 8, dipTo: 20))
        #expect(performer.violations().isEmpty, "\(performer.report())")
        withKnownIssue("Pressure dip before the 5 px drag latch releases and re-presses") {
            #expect(performer.clicks.count == 1, "one press, held through the dip\n\(performer.report())")
            #expect(performer.clicks.map(\.clickState) == [1])
        }
    }

    /// Loading one finger to the threshold for 3 frames while every
    /// finger is still stationary — at the very start of a scroll or
    /// swipe — is indistinguishable from pressing with resting
    /// fingers, and clicks.
    @Test func loadedFingerBeforeAScrollMovesClicks() {
        let performer = Performer(rig: TestRig(threshold: 50))
        // Four fingers settle, one carries 55 for several frames
        // before the hand starts moving.
        performer.perform(.scroll(fingers: 4, dx: 0, dy: -0.03, frames: 29, heavy: 55, landingSpike: false))
        #expect(performer.violations().isEmpty, "\(performer.report())")
        withKnownIssue("A stationary multi-finger load past the dwell clicks before the gesture is recognised") {
            #expect(performer.clicks.isEmpty, "\(performer.report())")
        }
    }
}
