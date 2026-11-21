import Foundation
import Testing
@testable import LightClickCore

// Realistic multi-finger postures (resting thumb, two-finger
// secondary click, chords, palms) and the interplay between the
// trackpad's own native events, an external mouse and the engine.
//
// Every test asserts the scenario's specific outcome AND that the
// performer saw no invariant / native-pairing violation. Tests that
// expose an engine bug keep the desired assertion inside
// `withKnownIssue("BUG: …")`, so the suite stays green and flips
// red the day the bug is fixed.

// MARK: - Scenario helpers

/// Contacts used across the scenarios.
private enum Hand {
    /// A thumb resting near the bottom edge (larger than a
    /// fingertip, still well under the palm cut-off).
    static func thumb(_ pressure: Double = 12, id: Int32 = 9) -> Contact {
        Contact(id: id, x: 0.42, y: 0.88, pressure: pressure, major: 13)
    }

    /// A palm / heel of the hand lying on the pad while typing.
    static func palm(id: Int32, x: Double, pressure: Double, major: Double) -> Contact {
        Contact(id: id, x: x, y: 0.9, pressure: pressure, major: major)
    }

    /// A light press scaled to the threshold (40% over it).
    static func light(_ threshold: Double, finger: Int32 = 1) -> Press {
        Press(finger: finger, peak: threshold * 1.4)
    }

    /// A quick tap as used in double / triple clicks, scaled.
    static func quick(_ threshold: Double, finger: Int32 = 1) -> Press {
        Press(finger: finger, peak: threshold * 1.4, rampFrames: 2, holdFrames: 2, releaseFrames: 2)
    }
}

/// What an external mouse click did at the event tap.
private struct MouseClickResult {
    var downSwallowed: Bool
    var upSwallowed: Bool
    var downAt: Double
    var upAt: Double
    /// Dragged events the tap swallowed (and replaced with ours).
    var movesSwallowed = 0
    var moves = 0
}

private extension Performer {
    /// `contacts` held perfectly still for `count` frames (frames
    /// keep arriving while anything touches the glass).
    func still(_ contacts: [Contact], frames count: Int, native: NativeButton = .auto) {
        for _ in 0 ..< count { frame(contacts, pointer: nil, native: native) }
    }

    /// `contacts` held still for about `seconds` of frames.
    func still(_ contacts: [Contact], seconds: Double) {
        still(contacts, frames: max(1, Int((seconds / frameDT).rounded())))
    }

    /// One finger presses following `p.curve` while `others` stay on
    /// the glass; the finger then lifts, the others remain (no full
    /// lift).
    func press(_ p: Press, with others: [Contact], native: NativeButton = .auto) {
        var nativeFired = false
        for pressure in p.curve {
            let jab = p.nativeFirst && !nativeFired && pressure >= nativeThreshold
            if jab { nativeFired = true }
            frame(others + [Contact(id: p.finger, x: p.x, y: p.y, pressure: pressure, major: p.major)],
                  pointer: p.finger, native: native, nativeFirst: jab)
        }
        frame(others, pointer: nil)
    }

    /// Press-and-drag with one finger while `others` rest: ramp,
    /// pause, slide `dx` (cursor follows) with a pressure dip to
    /// `dipTo`, settle, release; the finger lifts, others remain.
    func drag(_ p: Press, dx: Double, frames: Int, dipTo: Double, with others: [Contact]) {
        func c(_ x: Double, _ pr: Double) -> Contact { Contact(id: p.finger, x: x, y: p.y, pressure: pr, major: p.major) }
        for i in 0 ... max(1, p.rampFrames) {
            frame(others + [c(p.x, p.landing + (p.peak - p.landing) * Double(i) / Double(max(1, p.rampFrames)))], pointer: p.finger)
        }
        for _ in 0 ..< 2 { frame(others + [c(p.x, p.peak)], pointer: p.finger) }
        slide(finger: p.finger, from: (p.x, p.y), by: (dx, 0), frames: frames,
              pressure: { t in p.peak - (p.peak - dipTo) * sin(t * .pi) }, others: others)
        frame(others + [c(p.x + dx, p.peak)], pointer: p.finger)
        for i in 1 ... 3 { frame(others + [c(p.x + dx, p.peak + (p.landing - p.peak) * Double(i) / 3)], pointer: p.finger) }
        frame(others, pointer: nil)
    }

    /// The index finger moves the cursor (hover pressure) while
    /// `others` rest, stops, and stays on the glass.
    func point(finger: Int32, from: (Double, Double), dx: Double, frames: Int, with others: [Contact]) {
        slide(finger: finger, from: from, by: (dx, 0), frames: frames, pressure: { _ in 12 }, others: others)
    }

    /// An external mouse click while `contacts` stay on the trackpad
    /// (frames keep flowing during the click). `holdFrames` frames
    /// pass between the mouse's down and up; `dragBy` moves the
    /// mouse that far (px, x axis) while held, one step per frame.
    func externalMouseClick(during contacts: [Contact], holdFrames: Int, dragBy: Double = 0) -> MouseClickResult {
        let downAt = rig.clock.time
        let down = rig.nativeDown()
        note("external mouse down → \(down ? "swallowed" : "passed")")
        var r = MouseClickResult(downSwallowed: down, upSwallowed: false, downAt: downAt, upAt: 0)
        let start = cursor
        for i in 1 ... max(1, holdFrames) {
            if contacts.isEmpty { rig.advance(frameDT) } else { frame(contacts, pointer: nil, native: .none) }
            if dragBy != 0 {
                r.moves += 1
                if rig.move(to: ClickPoint(x: start.x + dragBy * Double(i) / Double(holdFrames), y: start.y)) {
                    r.movesSwallowed += 1
                }
            }
        }
        r.upAt = rig.clock.time
        r.upSwallowed = rig.nativeUp()
        note("external mouse up → \(r.upSwallowed ? "swallowed" : "passed")")
        return r
    }
}

/// Did the mouse click reach apps as exactly one complete press?
/// Either both native events passed through untouched (and the
/// engine posted nothing for them), or both were swallowed and the
/// engine's own press covered the whole click (down at the mouse's
/// down, up no earlier than the mouse's up) — never a half-swallowed
/// pair and never a synthetic press left held after the mouse let go.
@MainActor
private func mouseClickProblems(_ r: MouseClickResult, performer: Performer, outputBefore: Int) -> [String] {
    var problems: [String] = []
    let ours = clickRecords(Array(performer.events[outputBefore...]))
    if r.downSwallowed != r.upSwallowed {
        problems.append("mouse down \(r.downSwallowed ? "swallowed" : "passed") but up \(r.upSwallowed ? "swallowed" : "passed"): apps see an unpaired event")
    }
    if r.movesSwallowed != 0, r.movesSwallowed != r.moves {
        problems.append("only \(r.movesSwallowed) of \(r.moves) mouse drags were turned into ours: the drag is split")
    }
    if !r.downSwallowed, !ours.isEmpty { problems.append("mouse passed through, yet the engine also clicked: \(ours)") }
    if r.downSwallowed {
        if ours.count != 1 { problems.append("mouse down swallowed; engine produced \(ours.count) presses: \(ours)") }
        if let first = ours.first {
            if let upAt = first.upAt {
                if upAt < r.upAt - 1e-9 {
                    problems.append(String(format: "our press released %.3f s before the mouse button was (click cut short)", r.upAt - upAt))
                }
            } else {
                problems.append("our press is STILL HELD after the mouse button was released (stuck button)")
            }
        }
    }
    if performer.engine.buttonDown { problems.append("engine reports buttonDown after the mouse click ended") }
    return problems
}

private func describe(_ clicks: [ClickRecord]) -> String { clicks.map(\.description).joined(separator: "; ") }

// MARK: - Resting thumb

@MainActor
@Suite("Scenarios: thumb resting while the index finger works")
struct RestingThumbScenarioTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]
    nonisolated static let rests: [Double] = [5, 12, 18, 24]

    /// The classic MacBook posture: the thumb rests on the bottom of
    /// the pad the whole time, the index clicks once.
    @Test(arguments: thresholds, rests)
    func indexClicksWhileThumbRests(threshold: Double, rest: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let thumb = Hand.thumb(rest)
        performer.still([thumb], frames: 5)
        performer.press(Hand.light(threshold), with: [thumb])
        performer.still([thumb], seconds: 0.3)
        performer.lift()
        let clicks = performer.clicks
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(clicks.count == 1, "\(describe(clicks))\n\(performer.report())")
        #expect(clicks.allSatisfy { !$0.isDrag })
        #expect(performer.leakedNativePresses == 0)
    }

    /// Double-click to select a word, thumb resting throughout:
    /// every press is a fresh index contact, the thumb's frames keep
    /// flowing in the gap.
    @Test(arguments: thresholds, rests)
    func indexDoubleClicksWhileThumbRests(threshold: Double, rest: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let thumb = Hand.thumb(rest)
        performer.still([thumb], frames: 4)
        performer.press(Hand.quick(threshold, finger: 1), with: [thumb])
        performer.still([thumb], seconds: 0.1)
        performer.press(Hand.quick(threshold, finger: 2), with: [thumb])
        performer.still([thumb], frames: 10)
        performer.lift()
        let clicks = performer.clicks
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(clicks.map(\.clickState) == [1, 2], "\(describe(clicks))\n\(performer.report())")
    }

    /// Triple-click to select a line, thumb resting.
    @Test(arguments: thresholds)
    func indexTripleClicksWhileThumbRests(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let thumb = Hand.thumb(14)
        performer.still([thumb], frames: 4)
        for finger: Int32 in 1 ... 3 {
            performer.press(Hand.quick(threshold, finger: finger), with: [thumb])
            performer.still([thumb], seconds: 0.08)
        }
        performer.lift()
        let clicks = performer.clicks
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(clicks.map(\.clickState) == [1, 2, 3], "\(describe(clicks))\n\(performer.report())")
    }

    /// Drag a file with the index while the thumb rests: one held
    /// press that travels, fingertip roll dip included.
    @Test(arguments: thresholds)
    func indexDragsWhileThumbRests(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let thumb = Hand.thumb(14)
        performer.still([thumb], frames: 4)
        performer.drag(Hand.light(threshold), dx: 0.2, frames: 20, dipTo: threshold * 0.45, with: [thumb])
        performer.still([thumb], frames: 5)
        performer.lift()
        let clicks = performer.clicks
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(clicks.count == 1 && clicks[0].isDrag, "\(describe(clicks))\n\(performer.report())")
        #expect((clicks.first?.travel ?? 0) > 150)
    }

    /// A firm index click with the thumb resting crosses macOS's own
    /// click force too: exactly one click reaches apps, the native
    /// pair is swallowed.
    @Test(arguments: thresholds)
    func firmIndexClickWhileThumbRests(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let thumb = Hand.thumb(15)
        performer.still([thumb], frames: 3)
        performer.press(.firm(), with: [thumb])
        performer.still([thumb], frames: 10)
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.count == 1, "\(performer.report())")
        #expect(performer.leakedNativePresses == 0)
    }

    /// A fast jab with the thumb resting: the native press wins the
    /// race and the engine answers from the native path — still one
    /// click, held while the jab holds.
    @Test(arguments: thresholds)
    func jabWhileThumbRests(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let thumb = Hand.thumb(15)
        performer.still([thumb], frames: 3)
        performer.press(.jab(), with: [thumb])
        performer.still([thumb], frames: 10)
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.count == 1, "\(performer.report())")
        #expect(performer.leakedNativePresses == 0)
    }

    /// The thumb settles onto the pad AFTER the index is already
    /// tracked (hovering), then the index clicks.
    @Test(arguments: thresholds)
    func thumbLandsAfterIndexThenIndexClicks(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let index = Contact(id: 1, x: 0.5, y: 0.5, pressure: 10)
        performer.still([index], frames: 4)
        performer.still([index, Hand.thumb(6)], frames: 1)
        performer.still([index, Hand.thumb(14)], frames: 4)
        performer.press(Press(finger: 1, landing: 10, peak: threshold * 1.4), with: [Hand.thumb(14)])
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.count == 1, "\(performer.report())")
    }

    /// The thumb lands during a held index click and stays after the
    /// index eases off: the click releases on the index's pressure,
    /// not when the thumb finally lifts.
    @Test(arguments: thresholds)
    func thumbLandingMidClickDoesNotStretchTheClick(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let p = threshold * 1.4
        func index(_ pr: Double) -> Contact { Contact(id: 1, x: 0.5, y: 0.5, pressure: pr) }
        performer.still([index(10)], frames: 1)
        performer.still([index(p)], frames: 3)
        performer.still([index(p), Hand.thumb(14)], frames: 3)
        performer.still([index(threshold * 0.3), Hand.thumb(14)], frames: 1)
        let releasedAt = performer.rig.clock.time
        performer.still([index(10), Hand.thumb(14)], frames: 1)
        performer.still([Hand.thumb(14)], seconds: 0.5)
        performer.lift()
        let clicks = performer.clicks
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(clicks.count == 1, "\(performer.report())")
        #expect((clicks.first?.upAt ?? .infinity) <= releasedAt + 1e-9, "\(performer.report())")
    }

    /// After the index lifts, the thumb that had only been resting
    /// presses on its own (thumb-click): one click, from the thumb.
    @Test(arguments: thresholds)
    func thumbClicksAfterIndexLifts(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let index = Contact(id: 1, x: 0.5, y: 0.5, pressure: 12)
        performer.still([Hand.thumb(12), index], frames: 6)
        performer.still([Hand.thumb(12)], frames: 6)
        performer.press(Press(finger: 9, x: 0.42, y: 0.88, landing: 12, peak: threshold * 1.5, major: 13), with: [])
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.count == 1, "\(performer.report())")
    }

    /// The thumb presses and holds the click while the index slides
    /// to move the cursor (the old "thumb-click, index-drag" style),
    /// lightly and hard enough to also fire macOS's own click.
    @Test(arguments: thresholds, [1.5, 2.4])
    func thumbHoldsIndexDrags(threshold: Double, thumbFactor: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.perform(.thumbHoldIndexDrag(thumbPeak: threshold * thumbFactor, dx: 0.2, frames: 20))
        let clicks = performer.clicks
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(clicks.count == 1 && clicks[0].isDrag, "\(describe(clicks))\n\(performer.report())")
    }

    /// Thumb resting, the index moves the cursor onto a button,
    /// stops, and clicks lightly — the most ordinary thing a MacBook
    /// user does with a resting thumb.
    @Test(arguments: thresholds)
    func indexPointsThenClicksWhileThumbRests(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let thumb = Hand.thumb(14)
        performer.still([thumb], frames: 3)
        performer.point(finger: 1, from: (0.45, 0.5), dx: 0.12, frames: 12, with: [thumb])
        performer.still([thumb, Contact(id: 1, x: 0.57, y: 0.5, pressure: 12)], frames: 4)
        performer.press(Press(finger: 1, x: 0.57, landing: 12, peak: threshold * 1.4), with: [thumb])
        performer.lift()
        #expect(performer.leakedNativePresses == 0)
        withKnownIssue("BUG: a resting thumb + index pointing trips the scroll gate; light clicks die until the thumb lifts") {
            #expect(performer.clicks.count == 1, "\(performer.report())")
            // At 80 the press (112) also fires macOS's own click: its
            // down is swallowed (gesture) but its up leaks unpaired.
            if threshold * 1.4 >= performer.nativeThreshold {
                #expect(performer.violations().isEmpty, "\(performer.report())")
            }
        }
        if threshold * 1.4 < performer.nativeThreshold {
            #expect(performer.violations().isEmpty, "\(performer.report())")
        }
    }

    /// Thumb resting: drag something with the index, lift the index,
    /// then click lightly somewhere else (thumb never lifted).
    @Test(arguments: [40.0, 50, 60])
    func clickAfterDragWhileThumbStillRests(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let thumb = Hand.thumb(14)
        performer.still([thumb], frames: 3)
        performer.drag(Hand.light(threshold), dx: 0.15, frames: 15, dipTo: threshold * 0.6, with: [thumb])
        performer.still([thumb], seconds: 0.3)
        performer.press(Hand.light(threshold, finger: 2), with: [thumb])
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.first?.isDrag == true, "\(performer.report())")
        withKnownIssue("BUG: the drag's travel leaves the scroll gate set while the thumb rests; the next light click is dropped") {
            #expect(performer.clicks.count == 2, "\(performer.report())")
        }
    }
}

// MARK: - Two-finger secondary click

@MainActor
@Suite("Scenarios: two-finger secondary click")
struct TwoFingerClickScenarioTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]

    /// Both fingers press together for a context menu: macOS posts a
    /// secondary click; the engine must never add a left click and
    /// must stay locked until both lift.
    @Test(arguments: thresholds)
    func simultaneousTwoFingerClick(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        func pair(_ a: Double, _ b: Double) -> [Contact] {
            [Contact(id: 1, x: 0.45, y: 0.5, pressure: a), Contact(id: 2, x: 0.55, y: 0.5, pressure: b)]
        }
        var lockedDuring = false
        for i in 0 ... 4 {
            let p = 8 + (threshold * 1.5 - 8) * Double(i) / 4
            performer.frame(pair(p, p), pointer: nil, native: .none)
            lockedDuring = lockedDuring || performer.engine.isLocked
        }
        performer.still(pair(threshold * 1.5, threshold * 1.5), frames: 6, native: .none)
        let lockedAfter = performer.engine.isLocked
        performer.still(pair(10, 10), frames: 3, native: .none)
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.isEmpty, "\(performer.report())")
        #expect(!performer.engine.isLocked)
        // Fingers land light and ramp together, so tracking latches
        // onto one finger before either reaches 50 %: the lock (only
        // checked while nobody is tracked) never engages; tracking
        // ping-pongs between the two pressers instead.
        withKnownIssue("BUG: a real two-finger click (both land light, ramp together) never engages the two-finger lock") {
            #expect(lockedDuring && lockedAfter)
        }
    }

    /// Real fingers land a frame or three apart, ramping together.
    @Test(arguments: thresholds, [1, 2, 3])
    func staggeredTwoFingerClick(threshold: Double, offset: Int) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.perform(.twoFingerClick(peak: threshold * 1.6, offsetFrames: offset))
        #expect(performer.violations().isEmpty, "\(performer.report())")
        let clicks = performer.clicks
        if offset >= 3 {
            withKnownIssue("BUG: a two-finger click whose 2nd finger lands 3 frames late fires a left click before locking") {
                #expect(clicks.isEmpty, "\(describe(clicks))\n\(performer.report())")
            }
        } else {
            #expect(clicks.isEmpty, "\(describe(clicks))\n\(performer.report())")
        }
    }

    /// One finger of the pair presses lighter than the other (the
    /// middle finger is weaker): still a secondary click.
    @Test(arguments: thresholds, [0.55, 0.7, 0.9])
    func twoFingerClickWithLighterSecondFinger(threshold: Double, ratio: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let peak = threshold * 1.5
        for i in 0 ... 9 {
            let a = 8 + (peak - 8) * min(1, Double(i) / 4)
            let b = 8 + (peak * ratio - 8) * min(1, Double(i) / 4)
            performer.frame([Contact(id: 1, x: 0.45, y: 0.5, pressure: a), Contact(id: 2, x: 0.55, y: 0.5, pressure: b)],
                            pointer: nil, native: .none)
        }
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        if peak * ratio < threshold {
            // The lighter finger (≥ 50 % but < 100 % of the
            // threshold) is never a "presser", so the tracked finger
            // fires after the 3-frame dwell as if the other rested.
            withKnownIssue("BUG: two-finger click with the 2nd finger at 50–99 % of threshold fires a left click") {
                #expect(performer.clicks.isEmpty, "\(describe(performer.clicks))\n\(performer.report())")
            }
        } else {
            #expect(performer.clicks.isEmpty, "\(describe(performer.clicks))\n\(performer.report())")
        }
    }

    /// Context menu, then the user picks an item with an ordinary
    /// one-finger click 0.4 s later: the lock is gone, the click is a
    /// fresh single click.
    @Test(arguments: thresholds)
    func normalClickAfterTwoFingerClick(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.perform(.twoFingerClick(peak: threshold * 1.5, offsetFrames: 1))
        performer.wait(0.4)
        performer.perform(.click(Hand.light(threshold)))
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.map(\.clickState) == [1], "\(performer.report())")
    }

    /// The pair releases one finger at a time: the first finger
    /// lifts a frame before the second, which is still easing off
    /// above the threshold — no left click from the finger left
    /// behind.
    @Test(arguments: thresholds)
    func twoFingerClickReleasedOneFingerAtATime(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let peak = threshold * 1.5
        func pair(_ a: Double, _ b: Double) -> [Contact] {
            [Contact(id: 1, x: 0.45, y: 0.5, pressure: a), Contact(id: 2, x: 0.55, y: 0.5, pressure: b)]
        }
        for i in 0 ... 4 {
            let p = 10 + (peak - 10) * Double(i) / 4
            performer.still(pair(p, p), frames: 1, native: .none)
        }
        performer.still(pair(peak, peak), frames: 4, native: .none)
        for p in [peak * 0.85, peak * 0.5, 10] {
            performer.still([Contact(id: 2, x: 0.55, y: 0.5, pressure: p)], frames: 1, native: .none)
        }
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        withKnownIssue("BUG: the finger left behind after a two-finger click fires a left click (no lock was engaged)") {
            #expect(performer.clicks.isEmpty, "\(describe(performer.clicks))\n\(performer.report())")
        }
    }

    /// A long secondary-click hold with pressure wobble on both
    /// fingers (holding a context menu open): never a left click.
    @Test(arguments: thresholds)
    func longJitteryTwoFingerHold(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        for i in 0 ..< 60 {
            let ramp = min(1, Double(i) / 4)
            let a = 8 + (threshold * 1.5 - 8) * ramp + 6 * sin(Double(i) * 1.3)
            let b = 8 + (threshold * 1.3 - 8) * ramp + 6 * cos(Double(i) * 0.9)
            performer.frame([Contact(id: 1, x: 0.45, y: 0.5, pressure: a), Contact(id: 2, x: 0.55, y: 0.5, pressure: b)],
                            pointer: nil, native: .none)
        }
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.isEmpty, "\(performer.report())")
    }
}

// MARK: - Chords and hand-off

@MainActor
@Suite("Scenarios: chords and finger hand-off")
struct ChordAndHandOffScenarioTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]

    /// Index holds a light click, then the middle finger also
    /// presses: the held click is released at once (no stuck
    /// button), the engine stays locked until every finger lifts,
    /// and the next ordinary click works.
    @Test(arguments: thresholds)
    func secondFingerPressesDuringHeldClick(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let p = threshold * 1.3
        func index(_ pr: Double) -> Contact { Contact(id: 1, x: 0.45, y: 0.5, pressure: pr) }
        performer.still([index(10)], frames: 1)
        performer.still([index(p)], frames: 4)
        #expect(performer.engine.buttonDown)
        for i in 0 ... 4 {
            performer.frame([index(p), Contact(id: 2, x: 0.55, y: 0.5, pressure: 8 + (p - 8) * Double(i) / 4)],
                            pointer: nil, native: .none)
        }
        #expect(!performer.engine.buttonDown)
        #expect(performer.engine.isLocked)
        // One finger lets go; the other keeps pressing: still locked.
        performer.still([Contact(id: 2, x: 0.55, y: 0.5, pressure: p)], frames: 6, native: .none)
        #expect(performer.engine.isLocked)
        #expect(performer.clicks.count == 1)
        performer.lift()
        performer.wait(0.6)
        performer.perform(.click(Hand.light(threshold)))
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.count == 2, "\(performer.report())")
        #expect(performer.clicks.allSatisfy { $0.upAt != nil })
    }

    /// The same chord, but the index's click was firm enough for
    /// macOS's own click (swallowed): the chord is held 0.3 s before
    /// both fingers let go together — the native button stays down
    /// through it, as a physical click does.
    @Test(arguments: [40.0, 50, 60])
    func chordAfterFirmClickHeldAWhile(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        func index(_ pr: Double) -> Contact { Contact(id: 1, x: 0.45, y: 0.5, pressure: pr) }
        performer.still([index(10)], frames: 1)
        for pr in [50.0, 90, 120, 130] { performer.still([index(pr)], frames: 1) }
        let pair = [index(130), Contact(id: 2, x: 0.55, y: 0.5, pressure: 110)]
        performer.still(pair, seconds: 0.3)
        performer.still([index(20), Contact(id: 2, x: 0.55, y: 0.5, pressure: 20)], frames: 1)
        performer.lift()
        #expect(performer.clicks.count == 1, "\(performer.report())")
        #expect(Invariants.check(performer.events, doubleClickInterval: 0.5, settled: true).isEmpty, "\(performer.report())")
        withKnownIssue("BUG: native down swallowed, but its up passes through after a chord held > 0.15 s (unpaired up)") {
            #expect(performer.violations().isEmpty, "\(performer.report())")
        }
    }

    /// A chord during a drag (the hand grips harder while moving a
    /// window): the drag is dropped where it is, nothing stays held.
    @Test(arguments: thresholds)
    func chordDuringDrag(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let p = threshold * 1.3
        performer.still([Contact(id: 1, x: 0.4, y: 0.5, pressure: 10)], frames: 1)
        performer.still([Contact(id: 1, x: 0.4, y: 0.5, pressure: p)], frames: 3)
        performer.slide(finger: 1, from: (0.4, 0.5), by: (0.1, 0), frames: 10, pressure: { _ in p })
        #expect(performer.engine.dragLatched)
        let index = Contact(id: 1, x: 0.5, y: 0.5, pressure: p)
        for i in 0 ... 4 {
            performer.frame([index, Contact(id: 2, x: 0.6, y: 0.5, pressure: 8 + (p - 8) * Double(i) / 4)],
                            pointer: nil, native: .none)
        }
        #expect(!performer.engine.buttonDown)
        performer.lift()
        let clicks = performer.clicks
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(clicks.count == 1 && clicks[0].isDrag && clicks[0].upAt != nil, "\(describe(clicks))")
    }

    /// While dragging, a second finger lands and leans a little
    /// (below the click threshold): the drag carries on unharmed.
    @Test(arguments: thresholds)
    func secondFingerLeaningDuringDragIsNotAChord(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let p = threshold * 1.3
        let other = Contact(id: 2, x: 0.65, y: 0.6, pressure: threshold * 0.8)
        performer.still([Contact(id: 1, x: 0.4, y: 0.5, pressure: 10)], frames: 1)
        performer.still([Contact(id: 1, x: 0.4, y: 0.5, pressure: p)], frames: 3)
        performer.slide(finger: 1, from: (0.4, 0.5), by: (0.1, 0), frames: 10, pressure: { _ in p })
        performer.slide(finger: 1, from: (0.5, 0.5), by: (0.1, 0), frames: 10, pressure: { _ in p }, others: [other])
        #expect(performer.engine.buttonDown)
        performer.still([Contact(id: 1, x: 0.6, y: 0.5, pressure: 4), other], frames: 1)
        performer.lift()
        let clicks = performer.clicks
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(clicks.count == 1 && clicks[0].travel > 150, "\(describe(clicks))\n\(performer.report())")
    }

    /// The middle finger touches first and is tracked; then the
    /// index presses: tracking hands over, one click, and the middle
    /// finger never clicks on its own.
    @Test(arguments: thresholds)
    func restingFingerTrackedFirstThenAnotherPresses(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let middle = Contact(id: 3, x: 0.6, y: 0.55, pressure: 16)
        performer.still([middle], frames: 5)
        performer.press(Hand.light(threshold), with: [middle])
        performer.still([middle], seconds: 0.2)
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.count == 1, "\(performer.report())")
    }

    /// Thumb and middle finger rest; the index presses between them.
    @Test(arguments: thresholds)
    func twoRestingFingersThirdPresses(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let rest = [Hand.thumb(14), Contact(id: 3, x: 0.62, y: 0.52, pressure: 11)]
        performer.still(rest, frames: 5)
        performer.press(Hand.light(threshold), with: rest)
        performer.still(rest, frames: 5)
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.count == 1, "\(performer.report())")
    }

    /// Three fingers land together and rest; one of them then
    /// presses (no prior tracking): one click after the dwell.
    @Test(arguments: thresholds)
    func threeFingersRestOnePresses(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        func hand(_ p: Double) -> [Contact] {
            [Contact(id: 1, x: 0.4, y: 0.5, pressure: 12), Contact(id: 2, x: 0.5, y: 0.5, pressure: p),
             Contact(id: 3, x: 0.6, y: 0.5, pressure: 13)]
        }
        performer.still(hand(12), frames: 4)
        for p in Press(finger: 2, landing: 12, peak: threshold * 1.4).curve {
            performer.frame(hand(p), pointer: nil)
        }
        performer.still(hand(12), frames: 3)
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.count == 1, "\(performer.report())")
    }

    /// Three fingers press down together (three-finger drag off):
    /// not a left click from the engine, and no lock left behind.
    @Test(arguments: thresholds)
    func threeFingerPress(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        for i in 0 ... 8 {
            let p = 8 + (threshold * 1.4 - 8) * min(1, Double(i) / 4)
            performer.frame((0 ..< 3).map { Contact(id: Int32($0 + 1), x: 0.4 + 0.1 * Double($0), y: 0.5, pressure: p - Double($0) * 3) },
                            pointer: nil)
        }
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.isEmpty, "\(performer.report())")
    }

    /// Three-finger drag ON (Accessibility): three fingers glide at
    /// hover pressure and macOS itself posts left down / dragged /
    /// up. Those are a real drag from the trackpad — apps must see
    /// one complete, paired drag.
    @Test
    func threeFingerDragPostedByMacOS() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let rig = performer.rig
        func hand(_ dx: Double) -> [Contact] {
            (0 ..< 3).map { Contact(id: Int32($0 + 1), x: 0.4 + 0.08 * Double($0) + dx, y: 0.5, pressure: 14) }
        }
        performer.still(Array(hand(0).prefix(1)), frames: 1, native: .none)
        performer.still(hand(0), frames: 3, native: .none)
        var downSwallowed = false
        var dragsPassed = 0, dragsSwallowed = 0
        for i in 1 ... 20 {
            performer.frame(hand(0.01 * Double(i)), pointer: nil, native: .none)
            if i == 3 { downSwallowed = rig.nativeDown() }
            if i >= 3 {
                if rig.move(to: ClickPoint(x: 500 + 10 * Double(i), y: 500)) { dragsSwallowed += 1 } else { dragsPassed += 1 }
            }
        }
        performer.lift()
        let upSwallowed = rig.nativeUp()
        #expect(Invariants.check(performer.events, doubleClickInterval: 0.5, settled: true).isEmpty, "\(performer.report())")
        #expect(!performer.engine.buttonDown)
        withKnownIssue("BUG: three-finger drag: macOS's own down is swallowed mid-gesture but its drags and up pass through") {
            // Either the whole native drag passes untouched…
            let passedWhole = !downSwallowed && !upSwallowed && dragsSwallowed == 0 && performer.clicks.isEmpty
            // …or the engine re-posts all of it as one press of its own.
            let replacedWhole = downSwallowed && upSwallowed && dragsPassed == 0
                && performer.clicks.count == 1 && performer.clicks[0].isDrag
            #expect(passedWhole || replacedWhole,
                    "down \(downSwallowed ? "swallowed" : "passed"), up \(upSwallowed ? "swallowed" : "passed"), drags passed \(dragsPassed) swallowed \(dragsSwallowed)\n\(performer.report())")
        }
    }
}

// MARK: - Palms

@MainActor
@Suite("Scenarios: palms on the pad (typing posture)")
struct PalmScenarioTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]
    nonisolated static let palms: [(major: Double, pressure: Double)] = [(25, 50), (28, 90), (32, 120), (35, 150)]

    static func bothPalms(_ major: Double, _ pressure: Double) -> [Contact] {
        [Hand.palm(id: 20, x: 0.08, pressure: pressure, major: major),
         Hand.palm(id: 21, x: 0.92, pressure: pressure * 0.8, major: major - 2)]
    }

    /// Typing on the keyboard with both palms heavy on the pad's
    /// corners, shifting their weight: never a click.
    @Test(arguments: palms)
    func palmsAloneNeverClick(palm: (major: Double, pressure: Double)) {
        let performer = Performer(rig: TestRig(threshold: 30))
        for i in 0 ..< 120 {
            let wobble = 1 + 0.25 * sin(Double(i) * 0.4)
            performer.frame(Self.bothPalms(palm.major, palm.pressure * wobble), pointer: nil)
        }
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.isEmpty, "\(performer.report())")
    }

    /// Palms resting heavily while the index reaches over and clicks
    /// once: the palms are invisible, the click fires like a lone
    /// finger's.
    @Test(arguments: thresholds, palms)
    func indexClicksWithPalmsResting(threshold: Double, palm: (major: Double, pressure: Double)) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let palms = Self.bothPalms(palm.major, palm.pressure)
        performer.still(palms, frames: 6)
        performer.press(Hand.light(threshold), with: palms)
        performer.still(palms, frames: 6)
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.count == 1, "\(performer.report())")
    }

    /// Palms resting, the index double-clicks a word.
    @Test(arguments: thresholds)
    func indexDoubleClicksWithPalmsResting(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let palms = Self.bothPalms(30, 110)
        performer.still(palms, frames: 4)
        performer.press(Hand.quick(threshold, finger: 1), with: palms)
        performer.still(palms, seconds: 0.1)
        performer.press(Hand.quick(threshold, finger: 2), with: palms)
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.map(\.clickState) == [1, 2], "\(performer.report())")
    }

    /// A palm brushes the pad mid-drag, heavy, and leaves again: the
    /// drag is one uninterrupted press.
    @Test(arguments: thresholds)
    func palmBrushDuringDrag(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let p = threshold * 1.3
        let palm = Hand.palm(id: 20, x: 0.1, pressure: 140, major: 30)
        performer.still([Contact(id: 1, x: 0.4, y: 0.4, pressure: 10)], frames: 1)
        performer.still([Contact(id: 1, x: 0.4, y: 0.4, pressure: p)], frames: 3)
        performer.slide(finger: 1, from: (0.4, 0.4), by: (0.1, 0), frames: 8, pressure: { _ in p })
        performer.slide(finger: 1, from: (0.5, 0.4), by: (0.1, 0), frames: 8, pressure: { _ in p }, others: [palm])
        performer.slide(finger: 1, from: (0.6, 0.4), by: (0.05, 0), frames: 5, pressure: { _ in p })
        performer.still([Contact(id: 1, x: 0.65, y: 0.4, pressure: 3)], frames: 1)
        performer.lift()
        let clicks = performer.clicks
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(clicks.count == 1 && clicks[0].travel > 200, "\(describe(clicks))\n\(performer.report())")
    }

    /// The pressing finger flattens past 20 mm mid-press (a hard,
    /// flat press): the in-flight click is kept and releases on the
    /// ease-off, not when the finger lifts.
    @Test(arguments: thresholds)
    func presserFlattensPastPalmSize(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let majors: [Double] = [10, 12, 15, 19, 22, 24, 24, 21, 16, 12]
        let pressures: [Double] = [8, threshold, threshold * 1.6, threshold * 2.2, threshold * 2.6, threshold * 2.6,
                                   threshold * 2, threshold * 1.2, threshold * 0.5, 10]
        for (m, pr) in zip(majors, pressures) {
            performer.frame([Contact(id: 1, x: 0.5, y: 0.5, pressure: pr, major: m)], pointer: 1)
        }
        let releasedBy = performer.rig.clock.time
        performer.still([Contact(id: 1, x: 0.5, y: 0.5, pressure: 10)], frames: 5)
        performer.lift()
        let clicks = performer.clicks
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(clicks.count == 1, "\(performer.report())")
        #expect((clicks.first?.upAt ?? .infinity) <= releasedBy, "\(performer.report())")
    }

    /// The presser flattens past 20 mm while holding a drag: the
    /// drag is not lost.
    @Test(arguments: thresholds)
    func flatteningPresserKeepsDragging(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let p = threshold * 1.4
        performer.still([Contact(id: 1, x: 0.4, y: 0.5, pressure: 10)], frames: 1)
        performer.still([Contact(id: 1, x: 0.4, y: 0.5, pressure: p, major: 14)], frames: 3)
        for i in 1 ... 15 {
            performer.frame([Contact(id: 1, x: 0.4 + 0.01 * Double(i), y: 0.5, pressure: p, major: 14 + Double(i) * 0.6)], pointer: 1)
        }
        #expect(performer.engine.buttonDown)
        performer.still([Contact(id: 1, x: 0.55, y: 0.5, pressure: 3, major: 18)], frames: 1)
        performer.lift()
        let clicks = performer.clicks
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(clicks.count == 1 && clicks[0].isDrag, "\(describe(clicks))\n\(performer.report())")
    }

    /// A palm lands the way palms do: the first frames show a small
    /// contact that grows past 20 mm as the hand settles, its load
    /// rising with it. A palm must never click.
    @Test(arguments: thresholds)
    func palmSettlingFromSmallContactNeverClicks(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let growth: [(major: Double, pressure: Double)] = [(9, 5), (14, 15), (19, 28), (24, 55), (28, 90), (30, 120)]
        for g in growth { performer.frame([Hand.palm(id: 20, x: 0.1, pressure: g.pressure, major: g.major)], pointer: nil) }
        performer.still([Hand.palm(id: 20, x: 0.1, pressure: 120, major: 30)], frames: 30)
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        withKnownIssue("BUG: a palm tracked while still finger-sized keeps the tracked-finger exemption and clicks once it bears down") {
            #expect(performer.clicks.isEmpty, "\(describe(performer.clicks))\n\(performer.report())")
        }
    }

    /// Palm + resting thumb + a jab from the index.
    @Test(arguments: thresholds)
    func jabWithPalmAndThumbResting(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let rest = [Hand.palm(id: 20, x: 0.1, pressure: 100, major: 30), Hand.thumb(13)]
        performer.still(rest, frames: 5)
        performer.press(.jab(), with: rest)
        performer.still(rest, frames: 5)
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.count == 1, "\(performer.report())")
        #expect(performer.leakedNativePresses == 0)
    }
}

// MARK: - External mouse

@MainActor
@Suite("Scenarios: an external mouse alongside the trackpad")
struct ExternalMouseScenarioTests {
    /// No finger anywhere near the pad: mouse clicks of every length
    /// pass through untouched and the engine posts nothing.
    @Test(arguments: [0.02, 0.08, 0.2, 0.6])
    func mouseClickWithNoTouchPassesThrough(hold: Double) {
        let performer = Performer(rig: TestRig())
        performer.wait(2)
        let r = performer.externalMouseClick(holdFor: hold)
        #expect(!r.down && !r.up)
        #expect(performer.events.isEmpty)
        #expect(performer.violations(settled: true).isEmpty, "\(performer.report())")
    }

    /// A mouse double-click with no touch: both clicks pass through.
    @Test
    func mouseDoubleClickWithNoTouchPassesThrough() {
        let performer = Performer(rig: TestRig())
        performer.wait(1)
        let a = performer.externalMouseClick(holdFor: 0.06)
        performer.wait(0.09)
        let b = performer.externalMouseClick(holdFor: 0.06)
        #expect(!a.down && !a.up && !b.down && !b.up)
        #expect(performer.events.isEmpty)
        #expect(performer.violations(settled: true).isEmpty, "\(performer.report())")
    }

    /// A mouse drag with no touch: the down, every dragged event and
    /// the up pass through untouched.
    @Test
    func mouseDragWithNoTouchPassesThrough() {
        let performer = Performer(rig: TestRig())
        performer.wait(1)
        let r = performer.externalMouseClick(during: [], holdFrames: 30, dragBy: 300)
        #expect(!r.downSwallowed && !r.upSwallowed && r.movesSwallowed == 0)
        #expect(performer.events.isEmpty)
        #expect(performer.violations(settled: true).isEmpty, "\(performer.report())")
    }

    /// A trackpad click, the hand moves to the mouse, and the mouse
    /// clicks `delay` seconds after the finger left the glass (no
    /// trackpad frames arrive in between — nothing touches it).
    @Test(arguments: [0.05, 0.1, 0.14, 0.16, 0.3])
    func mouseClickShortlyAfterTrackpadClick(delay: Double) {
        let performer = Performer(rig: TestRig())
        performer.perform(.click(.light()))
        performer.wait(delay - performer.frameDT)
        let before = performer.events.count
        let r = performer.externalMouseClick(during: [], holdFrames: 10)
        performer.wait(1)
        let problems = mouseClickProblems(r, performer: performer, outputBefore: before)
        if delay <= 0.15 {
            withKnownIssue("BUG: mouse click < 0.15 s after a trackpad touch becomes our click and stays held (stuck button)") {
                #expect(problems.isEmpty, "\(problems)\n\(performer.report())")
                #expect(performer.violations(settled: true).isEmpty, "\(performer.report())")
            }
        } else {
            #expect(problems.isEmpty, "\(problems)\n\(performer.report())")
            #expect(performer.violations(settled: true).isEmpty, "\(performer.report())")
            #expect(performer.clicks.count == 1)
        }
    }

    /// The same after a mere touch (pointing with the finger, no
    /// click), then reaching for the mouse — and moving it a bit
    /// afterwards, which with a stuck button drags whatever is under
    /// the cursor.
    @Test(arguments: [0.06, 0.12])
    func mouseClickRightAfterPointingStrandsOurButton(delay: Double) {
        let performer = Performer(rig: TestRig())
        performer.perform(.point(dx: 0.1, dy: 0, frames: 10, pressure: 14))
        performer.wait(delay - performer.frameDT)
        let before = performer.events.count
        let r = performer.externalMouseClick(during: [], holdFrames: 10)
        let moveSwallowed = performer.rig.move(to: ClickPoint(x: 800, y: 300))
        let problems = mouseClickProblems(r, performer: performer, outputBefore: before)
        withKnownIssue("BUG: mouse click < 0.15 s after a touch strands our synthetic button; later mouse moves become drags") {
            #expect(problems.isEmpty, "\(problems)\n\(performer.report())")
            #expect(!moveSwallowed, "a plain mouse move after the click was turned into a drag")
        }
    }

    /// Typing posture: palms on the pad, the hand on the mouse
    /// clicks — palms are not touches, the click passes through.
    @Test(arguments: [0.06, 0.3])
    func mouseClickWhilePalmsRestOnPad(hold: Double) {
        let performer = Performer(rig: TestRig())
        let palms = PalmScenarioTests.bothPalms(30, 100)
        performer.still(palms, frames: 10)
        let before = performer.events.count
        let r = performer.externalMouseClick(during: palms, holdFrames: Int(hold / performer.frameDT))
        performer.still(palms, frames: 5)
        performer.lift()
        #expect(!r.downSwallowed && !r.upSwallowed, "\(performer.report())")
        #expect(mouseClickProblems(r, performer: performer, outputBefore: before).isEmpty)
        #expect(performer.violations().isEmpty, "\(performer.report())")
    }

    /// A finger (or thumb) rests lightly on the trackpad while the
    /// other hand clicks the mouse briefly: apps must see one
    /// complete click.
    @Test(arguments: [3, 8])
    func shortMouseClickWhileFingerRestsOnPad(holdFrames: Int) {
        let performer = Performer(rig: TestRig())
        let thumb = Hand.thumb(12)
        performer.still([thumb], frames: 10)
        let before = performer.events.count
        let r = performer.externalMouseClick(during: [thumb], holdFrames: holdFrames)
        performer.still([thumb], frames: 30)
        performer.lift()
        let problems = mouseClickProblems(r, performer: performer, outputBefore: before)
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(r.downSwallowed == r.upSwallowed)
        #expect(performer.clicks.count == 1, "\(performer.report())")
        // Apps do get one paired click, so this is the mild form of
        // the bug below: the mouse's press is converted into ours and
        // released by the next trackpad frame, not by the mouse.
        withKnownIssue("BUG (minor): a mouse click while a finger rests on the pad is converted and cut to ≤ 1 frame") {
            #expect(problems.isEmpty, "\(problems)\n\(performer.report())")
        }
    }

    /// A finger rests on the trackpad while the mouse holds its
    /// button (long press, e.g. a Dock menu) or drags a selection:
    /// apps must see one complete, paired press.
    @Test(arguments: [0.0, 250])
    func longMousePressOrDragWhileFingerRestsOnPad(dragBy: Double) {
        let performer = Performer(rig: TestRig())
        let thumb = Hand.thumb(12)
        performer.still([thumb], frames: 10)
        let before = performer.events.count
        let r = performer.externalMouseClick(during: [thumb], holdFrames: 50, dragBy: dragBy)
        performer.still([thumb], frames: 10)
        performer.lift()
        let problems = mouseClickProblems(r, performer: performer, outputBefore: before)
        #expect(Invariants.check(performer.events, doubleClickInterval: 0.5, settled: true).isEmpty, "\(performer.report())")
        #expect(!performer.engine.buttonDown)
        withKnownIssue("BUG: mouse press/drag while a finger rests: our click ends after one frame, the mouse's up/drags leak unpaired") {
            #expect(problems.isEmpty, "\(problems)\n\(performer.report())")
        }
    }

    /// Mouse first, trackpad right after (the hand comes back to the
    /// pad 0.1 s after a mouse click): the trackpad click is normal.
    @Test
    func trackpadClickRightAfterMouseClick() {
        let performer = Performer(rig: TestRig())
        performer.wait(1)
        let r = performer.externalMouseClick(holdFor: 0.07)
        performer.wait(0.1)
        performer.perform(.click(.firm()))
        #expect(!r.down && !r.up)
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.map(\.clickState) == [1], "\(performer.report())")
        #expect(performer.leakedNativePresses == 0)
    }
}

// MARK: - Native race

@MainActor
@Suite("Scenarios: the trackpad's own native click racing the frames")
struct NativeRaceScenarioTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]

    /// A firm click: our light click fires first, macOS's own press
    /// arrives a few frames later and is swallowed — one click, held
    /// from our down to the release.
    @Test(arguments: thresholds)
    func firmClickNativeAfterOurs(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.perform(.click(.firm()))
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.count == 1, "\(performer.report())")
        #expect(performer.leakedNativePresses == 0)
        #expect(performer.trace.contains { $0.contains("native leftMouseDown → swallowed") })
    }

    /// A jab: the native press wins the race. Our click must fire
    /// right then from the native path (not a frame later), and the
    /// frames after it must not add a second one.
    @Test(arguments: thresholds)
    func jabNativeBeforeOurFrame(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.frame([Contact(id: 1, x: 0.5, y: 0.5, pressure: 8)], pointer: 1)
        let nativeAt = performer.rig.clock.time
        let swallowed = performer.rig.nativeDown()
        #expect(swallowed)
        #expect(performer.clicks.first?.downAt == nativeAt, "\(performer.report())")
        for pr in [150.0, 150, 150, 40] {
            performer.frame([Contact(id: 1, x: 0.5, y: 0.5, pressure: pr)], pointer: 1, native: .none)
        }
        #expect(performer.rig.nativeUp())
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.count == 1, "\(performer.report())")
        #expect(performer.clicks.first?.upAt != nil)
    }

    /// Native up arrives while our button is still down (macOS lets
    /// go at a higher force than our 70 % line): swallowed, and our
    /// own release follows on the next frames.
    @Test(arguments: [30.0, 40, 50])
    func nativeUpBeforeOurRelease(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        func f(_ p: Double) { performer.frame([Contact(id: 1, x: 0.5, y: 0.5, pressure: p)], pointer: 1) }
        for p in [8.0, 60, 100, 130, 130] { f(p) }
        f((threshold * 0.7 + performer.nativeThreshold * 0.6) / 2) // below macOS's release, above ours
        #expect(performer.trace.last { $0.contains("native leftMouseUp") }?.contains("swallowed") == true, "\(performer.report())")
        #expect(performer.engine.buttonDown)
        f(threshold * 0.5)
        #expect(!performer.engine.buttonDown)
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.count == 1)
    }

    /// Native up arriving just after our release (high threshold:
    /// our release line sits above macOS's): the echo is swallowed
    /// within 0.15 s, nothing extra reaches apps.
    @Test(arguments: [0.0, 0.05, 0.12])
    func nativeEchoUpAfterOurRelease(extraDelay: Double) {
        let performer = Performer(rig: TestRig(threshold: 80))
        let rig = performer.rig
        func f(_ p: Double) { performer.frame([Contact(id: 1, x: 0.5, y: 0.5, pressure: p)], pointer: 1, native: .none) }
        f(8)
        f(90)
        #expect(rig.nativeDown())
        f(120)
        f(55) // ours releases (≤ 56)
        #expect(!rig.engine.buttonDown)
        rig.advance(extraDelay)
        #expect(rig.nativeUp(), "echo up not swallowed")
        f(10)
        performer.lift()
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.count == 1)
    }

    /// A fast firm double-click: both native presses are swallowed,
    /// apps see exactly our two clicks, chained.
    @Test(arguments: thresholds)
    func firmDoubleClick(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.perform(.multiClick(count: 2, gap: 0.08, press: Press(peak: 130, rampFrames: 2, holdFrames: 2, releaseFrames: 2)))
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.map(\.clickState) == [1, 2], "\(performer.report())")
        #expect(performer.leakedNativePresses == 0)
    }

    /// A jab double-click (both presses win the race).
    @Test(arguments: thresholds)
    func jabDoubleClick(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.perform(.multiClick(count: 2, gap: 0.07, press: .jab()))
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(performer.clicks.map(\.clickState) == [1, 2], "\(performer.report())")
        #expect(performer.leakedNativePresses == 0)
    }

    /// A firm press that becomes a drag: the native press is
    /// swallowed, the drag is ours, and macOS's up (well before the
    /// latched drag lets go) is swallowed too.
    @Test(arguments: thresholds)
    func firmDragNativePairSwallowed(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.perform(.drag(press: .firm(), dx: 0.2, dy: 0.05, frames: 20, dipTo: 35))
        let clicks = performer.clicks
        #expect(performer.violations().isEmpty, "\(performer.report())")
        #expect(clicks.count == 1 && clicks[0].isDrag, "\(describe(clicks))\n\(performer.report())")
        #expect(performer.leakedNativePresses == 0)
    }
}
