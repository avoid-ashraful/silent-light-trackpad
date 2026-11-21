import Foundation
import Testing
@testable import LightClickCore

// Realistic end-to-end click usage: single clicks, double / triple /
// quadruple clicks, rapid clicking and click-and-hold, performed
// frame by frame (8 ms) through the scenario kit's Performer, which
// also plays macOS's own force click (~90) and the cursor. Every test
// checks the kit's invariants (pairing, haptics, event numbers, click
// chain, no stuck button) AND the specific outcome a person expects.

// MARK: - Helpers

@MainActor
private func makePerformer(threshold: Double = 50, interval: Double = 0.5) -> Performer {
    Performer(rig: TestRig(threshold: threshold, doubleClickInterval: interval))
}

/// Pressure steps from `from` (exclusive) to `to` (inclusive).
private func ramp(_ from: Double, _ to: Double, frames: Int) -> [Double] {
    let n = max(1, frames)
    return (1 ... n).map { from + (to - from) * Double($0) / Double(n) }
}

private func near(_ a: ClickPoint?, _ b: ClickPoint, within tolerance: Double = 0.5) -> Bool {
    guard let a else { return false }
    return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
}

private extension Performer {
    var states: [Int] { clicks.map(\.clickState) }
    var now: Double { rig.clock.time }

    /// Event numbers of successive presses strictly increase.
    var numbersStrictlyIncrease: Bool {
        zip(clicks, clicks.dropFirst()).allSatisfy { $0.number < $1.number }
    }

    /// One stationary finger follows `values`, one frame each, with
    /// optional other (resting) contacts; does not lift.
    func pressures(_ values: [Double], finger: Int32 = 1, x: Double = 0.5, y: Double = 0.5,
                   others: [Contact] = [], native: NativeButton = .auto) {
        for value in values {
            frame(others + [Contact(id: finger, x: x, y: y, pressure: value)], pointer: finger, native: native)
        }
    }

    /// Hold one finger for `seconds` with pressure `p(t)` (t from 0),
    /// and position offset `drift(t)` in pad units; does not lift.
    func hold(seconds: Double, finger: Int32 = 1, x: Double = 0.5, y: Double = 0.5, others: [Contact] = [],
              drift: (Double) -> (Double, Double) = { _ in (0, 0) }, pressure: (Double) -> Double) {
        let n = Int((seconds / frameDT).rounded())
        for i in 0 ..< n {
            let t = Double(i) * frameDT
            let (dx, dy) = drift(t)
            frame(others + [Contact(id: finger, x: x + dx, y: y + dy, pressure: pressure(t))], pointer: finger)
        }
    }

    /// Only the given contacts (e.g. a resting thumb) for `seconds`.
    func only(_ contacts: [Contact], seconds: Double) {
        for _ in 0 ..< Int((seconds / frameDT).rounded()) { frame(contacts, pointer: nil) }
    }

    /// Wait so a press that fires `fireDelay` s after it starts goes
    /// down exactly `target` s after `previousDown`.
    func waitForNextDown(after previousDown: Double, target: Double, fireDelay: Double) {
        wait(target - (now - previousDown) - fireDelay)
    }
}

// MARK: - Single clicks

@MainActor
@Suite("Scenarios: single clicks")
struct SingleClickScenarioTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]

    /// Clicking a link with a light, deliberate press (20 units over
    /// the chosen threshold, eased off before lifting): one click
    /// where the cursor is, state 1, released before the finger lifts.
    @Test(arguments: thresholds)
    func lightClickOnLink(threshold: Double) {
        let p = makePerformer(threshold: threshold)
        p.press(Press(peak: threshold + 20), lift: false)
        let releasedBeforeLift = !p.engine.buttonDown
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.states == [1])
        #expect(releasedBeforeLift, "the click must end when the press eases, not when the finger lifts")
        #expect(near(p.clicks.first?.downPoint, ClickPoint(x: 500, y: 500)))
        #expect(p.clicks.first?.isDrag == false)
        #expect(p.leakedNativePresses == 0)
    }

    /// Clicking a button firmly — hard enough that macOS's own force
    /// click (~90) fires too: still exactly one click; the native
    /// press and release are both swallowed.
    @Test(arguments: thresholds)
    func firmClickOnButton(threshold: Double) {
        let p = makePerformer(threshold: threshold)
        p.press(.firm())

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.states == [1])
        #expect(p.clicks.first?.upAt != nil)
        #expect(p.leakedNativePresses == 0, "\(p.report())")
    }

    /// A fast, hard jab at a button where macOS's native press wins
    /// the race against the touch stream: one click, answered on the
    /// native event, never two.
    @Test(arguments: thresholds)
    func jabClickOnButton(threshold: Double) {
        let p = makePerformer(threshold: threshold)
        p.press(.jab())

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.states == [1])
        #expect(p.leakedNativePresses == 0, "\(p.report())")
    }

    /// A slow, careful click (pressure builds over ~120 ms, held,
    /// eased off over ~80 ms), like clicking a small checkbox.
    @Test func slowCarefulClickOnCheckbox() {
        let p = makePerformer()
        p.press(Press(landing: 6, peak: 72, rampFrames: 15, holdFrames: 12, releaseFrames: 10))

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.states == [1])
        #expect((p.clicks.first?.duration ?? 0) > 0.1)
    }

    /// Pressure hovering right at the threshold (±2) for a third of a
    /// second, as a hesitant press does: the hysteresis band keeps it
    /// one click — no flicker of downs and ups.
    @Test(arguments: thresholds)
    func pressureHoveringAtThreshold(threshold: Double) {
        let p = makePerformer(threshold: threshold)
        p.pressures([8] + ramp(8, threshold + 2, frames: 3))
        p.pressures((0 ..< 40).map { threshold + 2 * sin(Double($0) * 0.9) })
        p.pressures(ramp(threshold, 8, frames: 3))
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.states == [1])
    }

    /// A press that never quite commits (peaks 1 unit under the
    /// threshold and holds there) does not click.
    @Test(arguments: thresholds)
    func almostClickDoesNotClick(threshold: Double) {
        let p = makePerformer(threshold: threshold)
        p.press(Press(peak: threshold - 1, rampFrames: 4, holdFrames: 12))

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.isEmpty, "\(p.report())")
    }

    /// A finger simply resting on the pad while reading (pressure
    /// wandering 10–18 for two seconds) never clicks, even at the
    /// most sensitive threshold.
    @Test func restingFingerWhileReadingNeverClicks() {
        let p = makePerformer(threshold: 30)
        p.hold(seconds: 2) { t in 14 + 4 * sin(t * 7) }
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.isEmpty, "\(p.report())")
    }

    /// A very deep Force-Touch-level press (250) held for a second,
    /// e.g. someone who always presses hard: one click, one release.
    @Test func veryHardDeepPress() {
        let p = makePerformer()
        p.press(Press(peak: 250, rampFrames: 4, holdFrames: 125, releaseFrames: 4))

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.states == [1])
        #expect(abs((p.clicks.first?.duration ?? 0) - 1.03) < 0.05, "\(p.report())")
        #expect(p.leakedNativePresses == 0)
    }

    /// A deep jab straight to 250 where the native press arrives
    /// before the frame: still exactly one click.
    @Test func veryHardDeepJab() {
        let p = makePerformer()
        p.press(Press(peak: 250, rampFrames: 1, holdFrames: 10, releaseFrames: 2, nativeFirst: true))

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.states == [1])
        #expect(p.leakedNativePresses == 0)
    }

    /// Point at a link and press without lifting: the click lands
    /// exactly where the pointer stopped, with no dragged events.
    @Test func pointThenClickWithoutLifting() {
        let p = makePerformer()
        p.slide(finger: 1, from: (0.5, 0.5), by: (0.15, -0.05), frames: 20, pressure: { _ in 15 })
        p.pressures(ramp(15, 70, frames: 3) + [70, 70, 70, 70] + ramp(70, 12, frames: 3), x: 0.65, y: 0.45)
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.states == [1])
        #expect(near(p.clicks.first?.downPoint, ClickPoint(x: 650, y: 450)), "\(p.report())")
        #expect(p.clicks.first?.drags.isEmpty == true)
    }

    /// Click a button, glide the same finger 100 px to the next
    /// button without lifting, click again inside the double-click
    /// interval: two separate single clicks (state 1, 1) and the
    /// glide between them posts no dragged events.
    @Test func clickThenGlideToNextButtonAndClick() {
        let p = makePerformer()
        p.press(.light(), lift: false)
        p.slide(finger: 1, from: (0.5, 0.5), by: (0.1, 0), frames: 12, pressure: { _ in 12 })
        p.pressures([12] + ramp(12, 70, frames: 3) + [70, 70] + ramp(70, 10, frames: 3), x: 0.6)
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 2, "\(p.report())")
        #expect(p.states == [1, 1], "\(p.report())")
        #expect((p.clicks.last?.downAt ?? 9) - (p.clicks.first?.downAt ?? 0) < 0.5)
        #expect(p.clicks.allSatisfy { $0.drags.isEmpty }, "moving with the button up must not drag")
        #expect(near(p.clicks.last?.downPoint, ClickPoint(x: 600, y: 500)))
    }

    /// The fingertip rolls a pixel or two while clicking (contact
    /// centroid shifts as it flattens): still a click, not a drag.
    @Test func fingertipWobbleWhileClickingIsNotADrag() {
        let p = makePerformer()
        p.pressures([8] + ramp(8, 70, frames: 3))
        let wobble = [0.0005, 0.001, 0.0015, 0.002, 0.0015, 0.001]
        for dx in wobble { p.frame([Contact(id: 1, x: 0.5 + dx, y: 0.5, pressure: 70)], pointer: 1) }
        p.pressures(ramp(70, 8, frames: 3), x: 0.501)
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.clicks.first?.isDrag == false, "\(p.report())")
        #expect((p.clicks.first?.travel ?? 99) <= 2.01)
        #expect(!p.engine.dragLatched)
    }

    /// Scroll a page with two fingers, lift, and click a link right
    /// away (next frame / 30 ms / 200 ms later): the scroll gate is
    /// cleared on lift and the click fires normally, state 1.
    @Test(arguments: [0.0, 0.03, 0.2])
    func clickRightAfterTwoFingerScroll(pause: Double) {
        let p = makePerformer()
        p.scroll(fingers: 2, dx: 0, dy: 0.3, frames: 20, heavy: nil, landingSpike: false)
        if pause > 0 { p.wait(pause) }
        p.press(.light())

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.states == [1])
        #expect(!p.engine.gestureMoved)
    }

    /// After a two-finger scroll, one finger stays on the glass and
    /// clicks firmly (as on a real Mac, where the force button still
    /// works): one click, via the hard-press override; the native
    /// press that surfaced mid-gesture is swallowed and paired.
    @Test func firmClickWithLastFingerAfterScroll() {
        let p = makePerformer()
        for i in 0 ... 15 {
            let y = 0.45 + 0.02 * Double(i)
            p.frame([Contact(id: 1, x: 0.45, y: y, pressure: 18), Contact(id: 2, x: 0.53, y: y, pressure: 20)], pointer: nil)
        }
        p.pressures([18, 18, 18], x: 0.45, y: 0.75)
        p.press(Press(x: 0.45, y: 0.75, landing: 18, peak: 130, rampFrames: 4, holdFrames: 6))

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.states == [1])
        #expect(p.leakedNativePresses == 0, "\(p.report())")
    }

    /// Right-click (two-finger press) to open a context menu, slide
    /// to a menu item, click it: exactly one left click, at the item.
    @Test func clickMenuItemAfterRightClick() {
        let p = makePerformer()
        p.twoFingerClick(peak: 80, offsetFrames: 0)
        p.wait(0.3)
        p.slide(finger: 1, from: (0.5, 0.5), by: (0.04, 0.06), frames: 12, pressure: { _ in 14 })
        p.pressures(ramp(14, 70, frames: 3) + [70, 70, 70] + ramp(70, 10, frames: 3), x: 0.54, y: 0.56)
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.states == [1])
        #expect(near(p.clicks.first?.downPoint, ClickPoint(x: 540, y: 560)), "\(p.report())")
        #expect(!p.engine.isLocked)
    }

    /// Thumb resting on the bottom edge, index already over the
    /// target, index clicks: one click (after the 3-frame dwell).
    @Test func clickWithThumbResting() {
        let p = makePerformer()
        let thumb = Contact(id: 9, x: 0.4, y: 0.88, pressure: 12, major: 13)
        p.only([thumb], seconds: 0.5)
        p.pressures([8, 10, 12, 12] + ramp(12, 72, frames: 3) + [72, 72, 72, 72] + ramp(72, 10, frames: 3), others: [thumb])
        p.only([thumb], seconds: 0.1)
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.states == [1])
    }

    /// Thumb resting on the bottom edge, index POINTS to a link
    /// (thumb stays still), then clicks lightly. On a Mac the resting
    /// thumb is ignored and the index's click works.
    @Test func pointWithIndexWhileThumbRestsThenClick() {
        let p = makePerformer()
        let thumb = Contact(id: 9, x: 0.4, y: 0.88, pressure: 12, major: 13)
        p.only([thumb], seconds: 0.3)
        p.slide(finger: 1, from: (0.5, 0.5), by: (0.1, 0), frames: 20, pressure: { _ in 15 }, others: [thumb])
        p.pressures([15, 15, 15] + ramp(15, 72, frames: 3) + [72, 72, 72, 72, 72] + ramp(72, 10, frames: 3),
                    x: 0.6, others: [thumb])
        p.only([thumb], seconds: 0.1)
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(near(p.clicks.first?.downPoint, ClickPoint(x: 600, y: 500)))
    }

    /// A quick firm tap where macOS's native press reaches the event
    /// tap a couple of frames AFTER the touch stream (the reverse of
    /// the fast-jab race): the pressure path already clicked and
    /// released; the late native press belongs to that same press and
    /// must be swallowed, not turned into a second click.
    @Test func quickFirmTapWithLateNativePress() {
        let p = makePerformer()
        p.pressures([8, 60, 110, 110, 40, 8], native: .none)
        p.note("late native leftMouseDown → \(p.rig.nativeDown() ? "swallowed" : "PASSED THROUGH")")
        p.pressures([8], native: .none)
        p.note("late native leftMouseUp → \(p.rig.nativeUp() ? "swallowed" : "PASSED THROUGH")")
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        withKnownIssue("BUG: a native down arriving after the pressure click already released is converted into a second click (one tap → double-click)") {
            #expect(p.clicks.count == 1, "\(p.report())")
            #expect(p.states == [1])
        }
    }

    /// Same late native press, but it arrives just after the finger
    /// has left the glass (still within 150 ms of the last frame).
    @Test func quickFirmTapWithNativePressArrivingAfterLift() {
        let p = makePerformer()
        p.pressures([8, 60, 110, 110, 40, 8], native: .none)
        p.lift()
        p.note("late native leftMouseDown → \(p.rig.nativeDown() ? "swallowed" : "PASSED THROUGH")")
        p.wait(0.01)
        p.note("late native leftMouseUp → \(p.rig.nativeUp() ? "swallowed" : "PASSED THROUGH")")
        p.wait(0.5)

        withKnownIssue("BUG: a native down arriving after lift fires a tap click that nothing releases (stuck button until the next touch)") {
            #expect(p.violations(settled: true).isEmpty, "\(p.report())")
            #expect(!p.engine.buttonDown)
            #expect(p.clicks.count == 1, "\(p.report())")
        }
    }
}

// MARK: - Double / triple / quadruple clicks

@MainActor
@Suite("Scenarios: multi-clicks")
struct MultiClickScenarioTests {
    nonisolated static let intervals: [Double] = [0.25, 0.5, 0.8, 1.5]
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]

    /// Double-click a word to select it, at the pace a user with this
    /// double-click interval naturally uses (gap 30% of it).
    @Test(arguments: intervals)
    func doubleClickWord(interval: Double) {
        let p = makePerformer(interval: interval)
        p.perform(.multiClick(count: 2, gap: interval * 0.3, press: .quick()))

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.states == [1, 2], "\(p.report())")
        #expect(p.numbersStrictlyIncrease)
    }

    /// Triple-click a line to select the paragraph.
    @Test(arguments: intervals)
    func tripleClickLine(interval: Double) {
        let p = makePerformer(interval: interval)
        p.perform(.multiClick(count: 3, gap: interval * 0.3, press: .quick()))

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.states == [1, 2, 3], "\(p.report())")
        #expect(p.numbersStrictlyIncrease)
    }

    /// Four quick clicks (some editors select the whole document):
    /// the count keeps climbing, 1-2-3-4, as macOS's own does.
    @Test func quadrupleClick() {
        let p = makePerformer()
        p.perform(.multiClick(count: 4, gap: 0.09, press: .quick()))

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.states == [1, 2, 3, 4], "\(p.report())")
    }

    /// Double-click with the user's threshold preset: a quick press
    /// 18 units over the threshold, twice.
    @Test(arguments: thresholds)
    func doubleClickAtThreshold(threshold: Double) {
        let p = makePerformer(threshold: threshold)
        let tap = Press(peak: threshold + 18, rampFrames: 2, holdFrames: 2, releaseFrames: 2)
        p.perform(.multiClick(count: 2, gap: 0.1, press: tap))

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.states == [1, 2], "\(p.report())")
        #expect(p.leakedNativePresses == 0)
    }

    /// The second press lands 10 ms inside the double-click interval
    /// (down to down): it still chains.
    @Test(arguments: intervals)
    func secondPressJustInsideIntervalChains(interval: Double) {
        let p = makePerformer(interval: interval)
        p.press(.light())
        p.waitForNextDown(after: p.clicks[0].downAt, target: interval - 0.01, fireDelay: 3 * p.frameDT)
        p.press(.light())

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(abs(p.clicks[1].downAt - p.clicks[0].downAt - (interval - 0.01)) < 0.001, "\(p.report())")
        #expect(p.states == [1, 2], "\(p.report())")
    }

    /// The second press lands 10 ms past the interval: two single
    /// clicks (1, 1) — e.g. clicking a field, then again to place
    /// the caret.
    @Test(arguments: intervals)
    func secondPressJustOutsideIntervalDoesNotChain(interval: Double) {
        let p = makePerformer(interval: interval)
        p.press(.light())
        p.waitForNextDown(after: p.clicks[0].downAt, target: interval + 0.01, fireDelay: 3 * p.frameDT)
        p.press(.light())

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(abs(p.clicks[1].downAt - p.clicks[0].downAt - (interval + 0.01)) < 0.001, "\(p.report())")
        #expect(p.states == [1, 1], "\(p.report())")
    }

    /// Double-click to open a file where the SECOND press is firm
    /// enough to trip macOS's native click: still exactly two clicks,
    /// state 1 then 2, nothing leaks.
    @Test func doubleClickSecondPressTripsNativeClick() {
        let p = makePerformer()
        p.press(.quick())
        p.wait(0.1)
        p.press(Press(peak: 120, rampFrames: 2, holdFrames: 3, releaseFrames: 2))

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.states == [1, 2], "\(p.report())")
        #expect(p.leakedNativePresses == 0, "\(p.report())")
    }

    /// Double-click where the second press is a jab whose native
    /// press wins the race: exactly two clicks, 1 then 2.
    @Test func doubleClickSecondPressIsNativeFirstJab() {
        let p = makePerformer()
        p.press(.quick())
        p.wait(0.1)
        p.press(.jab())

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.states == [1, 2], "\(p.report())")
        #expect(p.leakedNativePresses == 0, "\(p.report())")
    }

    /// Jab first, then a light second press: 1 then 2.
    @Test func doubleClickJabThenLight() {
        let p = makePerformer()
        p.press(.jab())
        p.wait(0.1)
        p.press(.quick())

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.states == [1, 2], "\(p.report())")
        #expect(p.leakedNativePresses == 0, "\(p.report())")
    }

    /// A heavy-handed user double-clicks with two firm presses, both
    /// tripping the native click: exactly 2 clicks.
    @Test func doubleClickBothPressesFirm() {
        let p = makePerformer()
        p.perform(.multiClick(count: 2, gap: 0.1, press: Press(peak: 130, rampFrames: 2, holdFrames: 3, releaseFrames: 2)))

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.states == [1, 2], "\(p.report())")
        #expect(p.leakedNativePresses == 0, "\(p.report())")
    }

    nonisolated static let drifts: [(Double, Double)] = [
        (0, 0), (2, 0), (0, -3), (2, 3), (4.9, 0), (5.2, 0), (4, 4), (8, 0), (15, -10),
    ]

    /// Between the two presses of a double-click, the finger stays on
    /// the glass and drifts the cursor a little before lifting: up to
    /// 5 px still chains (word select); more is two single clicks.
    @Test(arguments: drifts)
    func doubleClickWithCursorDrift(dx: Double, dy: Double) {
        let p = makePerformer()
        p.press(.quick(), lift: false)
        p.slide(finger: 1, from: (0.5, 0.5), by: (dx / 1_000, dy / 1_000), frames: 4, pressure: { _ in 10 })
        p.lift()
        p.wait(0.08)
        p.press(Press(x: 0.5 + dx / 1_000, y: 0.5 + dy / 1_000, peak: 68, rampFrames: 2, holdFrames: 2, releaseFrames: 2))

        let chains = dx * dx + dy * dy <= 25
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 2, "\(p.report())")
        #expect(p.states == (chains ? [1, 2] : [1, 1]), "\(p.report())")
        #expect(near(p.clicks.last?.downPoint, ClickPoint(x: 500 + dx, y: 500 + dy)))
    }

    /// Double-click without lifting: press, ease well below the
    /// release line (finger still touching), press again. The engine
    /// treats it like two presses of a physical button: 1 then 2.
    @Test(arguments: thresholds)
    func doubleClickWithoutLifting(threshold: Double) {
        let p = makePerformer(threshold: threshold)
        let peak = threshold * 1.4, ease = threshold * 0.4
        p.pressures([8] + ramp(8, peak, frames: 3) + [peak, peak] + ramp(peak, ease, frames: 3) + [ease, ease])
        p.pressures(ramp(ease, peak, frames: 3) + [peak, peak] + ramp(peak, 8, frames: 3))
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.states == [1, 2], "\(p.report())")
        #expect(p.leakedNativePresses == 0)
    }

    /// Triple-click without ever lifting the finger: 1, 2, 3.
    @Test func tripleClickWithoutLifting() {
        let p = makePerformer()
        p.pressures([8])
        for _ in 0 ..< 3 {
            p.pressures(ramp(15, 70, frames: 3) + [70, 70] + ramp(70, 15, frames: 3) + [15])
        }
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.states == [1, 2, 3], "\(p.report())")
    }

    /// Easing only partway (to 40 at threshold 50 — inside the
    /// hysteresis band) and pressing again is NOT a double-click: a
    /// physical button that never came back up clicked once.
    @Test func partialEaseInsideBandIsOneClick() {
        let p = makePerformer()
        p.pressures([8] + ramp(8, 70, frames: 3) + [70, 70] + ramp(70, 40, frames: 3) + [40, 40])
        p.pressures(ramp(40, 70, frames: 3) + [70, 70] + ramp(70, 8, frames: 3))
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.states == [1])
    }

    /// Double-click by drumming two fingers (index then middle):
    /// the cursor does not move, so the presses chain: 1 then 2.
    @Test func doubleClickWithAlternatingFingers() {
        let p = makePerformer()
        p.press(Press(finger: 1, x: 0.48, peak: 68, rampFrames: 2, holdFrames: 2, releaseFrames: 2))
        p.wait(0.08)
        p.press(Press(finger: 2, x: 0.55, peak: 68, rampFrames: 2, holdFrames: 2, releaseFrames: 2))

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.states == [1, 2], "\(p.report())")
        #expect(near(p.clicks.last?.downPoint, ClickPoint(x: 500, y: 500)))
    }

    /// Double-click with the thumb resting on the pad throughout (each
    /// index press is a new contact): 1 then 2.
    @Test func doubleClickWithThumbResting() {
        let p = makePerformer()
        let thumb = Contact(id: 9, x: 0.4, y: 0.88, pressure: 12, major: 13)
        p.only([thumb], seconds: 0.3)
        p.pressures([8, 38, 68, 68, 68, 68, 38, 8], finger: 1, others: [thumb])
        p.only([thumb], seconds: 0.08)
        p.pressures([8, 38, 68, 68, 68, 68, 38, 8], finger: 3, others: [thumb])
        p.only([thumb], seconds: 0.1)
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.states == [1, 2], "\(p.report())")
    }

    /// A slow user (1.5 s interval) double-clicks with long, lazy
    /// presses (each held ~0.3 s): still a double-click.
    @Test func slowUserLazyDoubleClick() {
        let p = makePerformer(interval: 1.5)
        p.perform(.multiClick(count: 2, gap: 0.4, press: Press(peak: 66, rampFrames: 6, holdFrames: 30, releaseFrames: 6)))

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.states == [1, 2], "\(p.report())")
        #expect(p.clicks.allSatisfy { ($0.duration ?? 0) > 0.25 })
    }
}

// MARK: - Rapid clicking

@MainActor
@Suite("Scenarios: rapid clicking")
struct RapidClickScenarioTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]

    private func expectRapidRun(_ p: Performer, presses: Int) {
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == presses, "\(p.report())")
        #expect(p.states == Array(1 ... presses), "\(p.report())")
        #expect(p.clicks.allSatisfy { $0.upAt != nil }, "every press must be released")
        #expect(p.numbersStrictlyIncrease)
        #expect(!p.engine.buttonDown)
        #expect(p.leakedNativePresses == 0)
    }

    /// Hammering an increment button (or a game) at ~8 clicks per
    /// second for 2 s: every press accounted for, each one released,
    /// event numbers strictly increase. Each press is within the
    /// interval of the last, so the count keeps climbing (as macOS's
    /// own click count does).
    @Test func incrementButtonEightPerSecond() {
        let p = makePerformer()
        for i in 0 ..< 16 {
            if i > 0 { p.wait(0.061) }
            p.press(.quick())
        }
        expectRapidRun(p, presses: 16)
    }

    /// The same 8-per-second hammering at every threshold preset.
    @Test(arguments: thresholds)
    func rapidClickingAtThreshold(threshold: Double) {
        let p = makePerformer(threshold: threshold)
        for i in 0 ..< 16 {
            if i > 0 { p.wait(0.061) }
            p.press(Press(peak: threshold + 18, rampFrames: 2, holdFrames: 2, releaseFrames: 2))
        }
        expectRapidRun(p, presses: 16)
    }

    /// Rapid FIRM clicking: every press trips the native click too.
    @Test func rapidFirmClicking() {
        let p = makePerformer()
        for i in 0 ..< 16 {
            if i > 0 { p.wait(0.061) }
            p.press(Press(peak: 125, rampFrames: 2, holdFrames: 2, releaseFrames: 2))
        }
        expectRapidRun(p, presses: 16)
    }

    /// Rapid jabs where the native press always wins the race.
    @Test func rapidJabbing() {
        let p = makePerformer()
        for i in 0 ..< 16 {
            if i > 0 { p.wait(0.077) }
            p.press(.jab())
        }
        expectRapidRun(p, presses: 16)
    }

    /// Pumping the press without lifting (finger stays on the glass,
    /// pressure 12 ↔ 70) at ~8 per second for 2 s.
    @Test func rapidPumpingWithoutLifting() {
        let p = makePerformer()
        p.pressures([8])
        for _ in 0 ..< 16 {
            p.pressures([41, 70, 70, 70, 41, 12] + Array(repeating: 12, count: 10))
        }
        p.lift()
        expectRapidRun(p, presses: 16)
    }

    /// Drumming index and middle fingers alternately at ~8 per second.
    @Test func rapidDrummingAlternateFingers() {
        let p = makePerformer()
        for i in 0 ..< 16 {
            if i > 0 { p.wait(0.061) }
            let finger: Int32 = i.isMultiple(of: 2) ? 1 : 2
            p.press(Press(finger: finger, x: finger == 1 ? 0.47 : 0.54, peak: 68, rampFrames: 2, holdFrames: 2, releaseFrames: 2))
        }
        expectRapidRun(p, presses: 16)
    }

    /// Two bursts of rapid clicking separated by a pause longer than
    /// the interval: the count restarts at 1 for the second burst.
    @Test func twoBurstsRestartTheCount() {
        let p = makePerformer()
        for burst in 0 ..< 2 {
            if burst > 0 { p.wait(0.8) }
            for i in 0 ..< 5 {
                if i > 0 { p.wait(0.061) }
                p.press(.quick())
            }
        }
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.states == [1, 2, 3, 4, 5, 1, 2, 3, 4, 5], "\(p.report())")
        #expect(p.numbersStrictlyIncrease)
    }
}

// MARK: - Click and hold

@MainActor
@Suite("Scenarios: click and hold")
struct ClickHoldScenarioTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]
    nonisolated static let holdSeconds: [Double] = [1, 2, 3]

    /// Long-press the browser back button to get its history menu:
    /// press, hold 1–3 s with pressure wandering inside the hysteresis
    /// band (85%–135% of the threshold), ease off. One down, held the
    /// whole time, one up; no drag.
    @Test(arguments: thresholds, holdSeconds)
    func pressAndHoldBackButton(threshold: Double, seconds: Double) {
        let p = makePerformer(threshold: threshold)
        let peak = threshold * 1.3
        p.pressures([8] + ramp(8, peak, frames: 3))
        p.hold(seconds: seconds) { t in
            threshold * (1.1 + 0.2 * sin(2 * .pi * 1.3 * t) + 0.05 * sin(2 * .pi * 4.1 * t))
        }
        let heldThroughout = p.engine.buttonDown
        p.pressures(ramp(threshold * 1.1, 8, frames: 4))
        let releasedBeforeLift = !p.engine.buttonDown
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.states == [1])
        #expect(heldThroughout)
        #expect(releasedBeforeLift)
        #expect(abs((p.clicks.first?.duration ?? 0) - seconds) < 0.05, "\(p.report())")
        #expect(p.clicks.first?.drags.isEmpty == true)
        #expect(p.leakedNativePresses == 0)
    }

    /// Hold a Dock icon for its menu, then lift straight off without
    /// easing: the click releases on the lift frame.
    @Test func holdDockIconThenLiftStraightOff() {
        let p = makePerformer()
        p.pressures([8] + ramp(8, 68, frames: 3))
        p.hold(seconds: 1.2) { t in 65 + 5 * sin(t * 9) }
        let liftAt = p.now
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(abs((p.clicks.first?.upAt ?? 0) - liftAt) < 0.0001, "\(p.report())")
        #expect(abs((p.clicks.first?.duration ?? 0) - 1.2) < 0.02)
    }

    /// While holding, squeeze harder (past macOS's native click) and
    /// relax back: still one held click; the native press and release
    /// are swallowed as a pair.
    @Test func squeezeHarderMidHold() {
        let p = makePerformer()
        p.pressures([8] + ramp(8, 60, frames: 3))
        p.hold(seconds: 0.5) { _ in 60 }
        p.pressures(ramp(60, 130, frames: 5))
        p.hold(seconds: 0.3) { _ in 130 }
        p.pressures(ramp(130, 60, frames: 5))
        p.hold(seconds: 0.5) { _ in 60 }
        p.pressures(ramp(60, 8, frames: 4))
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect((p.clicks.first?.duration ?? 0) > 1.3)
        #expect(p.leakedNativePresses == 0, "\(p.report())")
    }

    /// Holding a click, the thumb comes to rest on the pad mid-hold,
    /// then the index lets go while the thumb stays: one click, never
    /// disturbed, no lock afterwards.
    @Test func thumbComesToRestDuringHold() {
        let p = makePerformer()
        p.pressures([8] + ramp(8, 70, frames: 3))
        p.hold(seconds: 0.5) { t in 68 + 3 * sin(t * 11) }
        var thumb = Contact(id: 9, x: 0.4, y: 0.88, pressure: 6, major: 13)
        for pressure in [6.0, 10, 14] {
            thumb.pressure = pressure
            p.pressures([68], others: [thumb])
        }
        p.hold(seconds: 1, others: [thumb]) { t in 68 + 3 * sin(t * 11) }
        let stillHeld = p.engine.buttonDown
        p.pressures(ramp(68, 10, frames: 3), others: [thumb])
        p.only([thumb], seconds: 0.1)
        let lockedWithThumbOnly = p.engine.isLocked
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(stillHeld)
        #expect(!lockedWithThumbOnly)
        #expect((p.clicks.first?.duration ?? 0) > 1.4)
    }

    /// A small hand tremor (±1.5 px) during a 1.5 s hold: dragged
    /// events may flow, but it stays a held click, never a drag.
    @Test func handTremorDuringHoldIsNotADrag() {
        let p = makePerformer()
        p.pressures([8] + ramp(8, 70, frames: 3))
        p.hold(seconds: 1.5, drift: { t in (0.0015 * sin(2 * .pi * 5 * t), 0.001 * sin(2 * .pi * 3 * t)) }) { _ in 68 }
        let latched = p.engine.dragLatched
        p.pressures(ramp(68, 8, frames: 3))
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(!latched)
        #expect(p.clicks.first?.isDrag == false, "\(p.report())")
        #expect((p.clicks.first?.travel ?? 99) <= 2.5)
    }

    /// Hold, then let go very slowly (pressure falls 70 → 8 over half
    /// a second): exactly one release, at the 70% line, no re-press.
    @Test func holdThenVerySlowRelease() {
        let p = makePerformer()
        p.pressures([8] + ramp(8, 70, frames: 3))
        p.hold(seconds: 0.5) { _ in 70 }
        let easeStart = p.now
        let easing = ramp(70, 8, frames: 62)
        p.pressures(easing)
        p.lift()

        let releaseFrame = easing.firstIndex { $0 <= 35 } ?? -1
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(abs((p.clicks.first?.upAt ?? 0) - (easeStart + Double(releaseFrame) * p.frameDT)) < 0.0001, "\(p.report())")
    }

    /// A deep, Force-Touch-level hold (pressure ~220 ± 20 for 2 s), as
    /// when someone presses hard to hold a scrollbar arrow: one click.
    @Test func deepForceHold() {
        let p = makePerformer()
        p.pressures([8] + ramp(8, 220, frames: 4))
        p.hold(seconds: 2) { t in 220 + 20 * sin(t * 6) }
        p.pressures(ramp(220, 8, frames: 4))
        p.lift()

        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(abs((p.clicks.first?.duration ?? 0) - 2.0) < 0.08, "\(p.report())")
        #expect(p.leakedNativePresses == 0)
    }
}
