import Foundation
import Testing
@testable import LightClickCore

// MARK: - A finger on the glass, driven frame by frame

/// One pressing finger (plus whatever else rests on the glass),
/// moved and pressed frame by frame through a `Performer`, so a
/// scenario reads like what the hand does: touch down, home in on
/// the target, press, slide, pause, ease off, lift. The finger is
/// the pointer: its travel moves the cursor (1000 px per pad unit)
/// and the event tap sees native moved/dragged events for it.
@MainActor
private final class Hand {
    let performer: Performer
    var finger: Contact
    /// Contacts that stay on the glass beside the finger (a resting
    /// thumb, a palm). Sent with every frame.
    var others: [Contact] = []

    init(_ performer: Performer, id: Int32 = 1, x: Double = 0.3, y: Double = 0.5, major: Double = 10) {
        self.performer = performer
        finger = Contact(id: id, x: x, y: y, pressure: 12, major: major)
    }

    var now: Double { performer.rig.clock.time }
    var cursor: ClickPoint { performer.cursor }

    func frame(nativeFirst: Bool = false) {
        performer.frame(others + [finger], pointer: finger.id, nativeFirst: nativeFirst)
    }

    /// The fingertip touches the glass at pointing pressure.
    func touchDown(pressure: Double = 12) {
        finger.pressure = pressure
        frame()
    }

    /// Move the pointer without pressing (homing in on a target).
    func point(by dx: Double, _ dy: Double, frames: Int, pressure: Double = 12) {
        slide(by: dx, dy, frames: frames) { _ in pressure }
    }

    /// Pressure ramps in place to `peak`. `jab`: macOS's own press
    /// is delivered before the frame that crosses its threshold (a
    /// fast hard press winning the race against the touch stream).
    func press(to peak: Double, frames: Int = 3, jab: Bool = false) {
        let start = finger.pressure
        var fired = false
        let n = max(1, frames)
        for i in 1 ... n {
            finger.pressure = start + (peak - start) * Double(i) / Double(n)
            let first = jab && !fired && finger.pressure >= performer.nativeThreshold
            if first { fired = true }
            frame(nativeFirst: first)
        }
    }

    /// Hold still for `frames` frames; pressure per progress 0…1.
    func hold(frames: Int, pressure: ((Double) -> Double)? = nil) {
        let n = max(1, frames)
        for i in 1 ... n {
            if let pressure { finger.pressure = pressure(Double(i) / Double(n)) }
            frame()
        }
    }

    func hold(seconds: Double, pressure: ((Double) -> Double)? = nil) {
        hold(frames: Int((seconds / performer.frameDT).rounded()), pressure: pressure)
    }

    /// Slide by (dx, dy) pad units over `frames` frames. Pressure and
    /// contact size per progress 0…1 (unchanged when nil). A trailing
    /// closure is the pressure curve.
    func slide(by dx: Double, _ dy: Double, frames: Int,
               pressure: ((Double) -> Double)? = nil, major: ((Double) -> Double)? = nil) {
        let x0 = finger.x, y0 = finger.y
        let n = max(1, frames)
        for i in 1 ... n {
            let t = Double(i) / Double(n)
            finger.x = x0 + dx * t
            finger.y = y0 + dy * t
            if let pressure { finger.pressure = pressure(t) }
            if let major { finger.major = major(t) }
            frame()
        }
    }

    /// Pressure eases in place to `target`.
    func ease(to target: Double, frames: Int = 3) {
        press(to: target, frames: frames)
    }

    /// The finger leaves the glass; anything in `others` stays.
    func lift() {
        if others.isEmpty { performer.lift() } else { performer.frame(others, pointer: nil) }
    }
}

/// The fingertip rolling while it slides: pressure sags from `peak`
/// to `dip` at mid-slide and recovers (the thing that used to kill
/// browser tab drags).
private func roll(_ peak: Double, dipTo dip: Double) -> (Double) -> Double {
    { t in peak - (peak - dip) * sin(t * .pi) }
}

// MARK: - Checking a drag

private func distance(_ a: ClickPoint, _ b: ClickPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

/// What is wrong with the drag press `index` (default: the last
/// press) against what the person did. Checks the press count, the
/// click state, that the whole down → dragged… → up sequence carries
/// one event number and one click state (what macOS and Chromium
/// need to treat it as a single drag), how far and how many dragged
/// events it produced, where and when it dropped, and that no
/// native press leaked and no button is left held.
@MainActor
private func dragProblems(
    _ performer: Performer,
    presses: Int = 1,
    index: Int? = nil,
    clickState: Int = 1,
    minDrags: Int = 5,
    minExcursion: Double = 6,
    dropAt: ClickPoint? = nil,
    notReleasedBefore: Double? = nil
) -> [String] {
    var problems: [String] = []
    let clicks = performer.clicks
    guard clicks.count == presses else {
        return ["expected \(presses) press(es), got \(clicks.count): \(clicks)"]
    }
    let c = clicks[index ?? clicks.count - 1]
    if c.clickState != clickState { problems.append("press has click state \(c.clickState), expected \(clickState)") }

    // The press's own sequence: from its down to the following up.
    var sequence: [(kind: String, state: Int, number: Int)] = []
    var inside = false
    for event in performer.events {
        switch event {
        case let .down(_, _, s, n):
            if !inside, n == c.number { inside = true; sequence.append(("down", s, n)) }
        case let .drag(_, _, s, n):
            if inside { sequence.append(("drag", s, n)) }
        case let .up(_, _, s, n):
            if inside { sequence.append(("up", s, n)); inside = false }
        case .haptic:
            break
        }
        if !inside, !sequence.isEmpty { break }
    }
    if sequence.last?.kind != "up" { problems.append("press #\(c.number) never got its mouse-up") }
    if sequence.count != c.drags.count + 2 { problems.append("press sequence has \(sequence.count) events, expected \(c.drags.count + 2)") }
    for item in sequence where item.number != c.number || item.state != c.clickState {
        problems.append("\(item.kind) carries #\(item.number) state \(item.state); press is #\(c.number) state \(c.clickState)")
    }

    if c.drags.count < minDrags { problems.append("only \(c.drags.count) dragged events, expected ≥ \(minDrags)") }
    let excursion = c.drags.map { distance($0, c.downPoint) }.max() ?? 0
    // 1 px of slack: cursor positions are sums of fractional steps.
    if excursion + 1 < minExcursion { problems.append("drag reached \(Int(excursion)) px from its press, expected ≥ \(Int(minExcursion))") }
    if let dropAt, let up = c.upPoint, distance(up, dropAt) > 1 {
        problems.append("dropped at \(Int(up.x)),\(Int(up.y)), expected \(Int(dropAt.x)),\(Int(dropAt.y))")
    }
    if let notReleasedBefore, let upAt = c.upAt, upAt < notReleasedBefore - 1e-9 {
        problems.append(String(format: "released early: up at %.3f, before the drop at %.3f", upAt, notReleasedBefore))
    }
    if performer.engine.buttonDown { problems.append("button still held at the end") }
    if performer.leakedNativePresses > 0 { problems.append("\(performer.leakedNativePresses) native press(es) leaked to apps") }
    return problems
}

/// The output stream keeps every invariant (pairing, haptics, event
/// numbers, click chain, nothing stuck) — always checked.
@MainActor
private func expectClean(_ performer: Performer, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(performer.violations().isEmpty, "\(performer.report())", sourceLocation: sourceLocation)
    #expect(!performer.engine.buttonDown, "button held at the end\n\(performer.report())", sourceLocation: sourceLocation)
}

@MainActor
private func expectOutcome(_ problems: [String], _ performer: Performer, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(problems.isEmpty, "\(performer.report(problems))", sourceLocation: sourceLocation)
}

/// Clean stream AND exactly the drag the person made.
@MainActor
private func expectDrag(
    _ performer: Performer,
    presses: Int = 1,
    index: Int? = nil,
    clickState: Int = 1,
    minDrags: Int = 5,
    minExcursion: Double = 6,
    dropAt: ClickPoint? = nil,
    notReleasedBefore: Double? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    expectClean(performer, sourceLocation: sourceLocation)
    let problems = dragProblems(performer, presses: presses, index: index, clickState: clickState, minDrags: minDrags,
                                minExcursion: minExcursion, dropAt: dropAt, notReleasedBefore: notReleasedBefore)
    expectOutcome(problems, performer, sourceLocation: sourceLocation)
}

// MARK: - Scenarios

/// Drags as people really make them on a light-click trackpad:
/// browser tabs, windows, text selection, files, sliders — with
/// fingertip roll, pauses, resting thumbs, flattening fingertips,
/// fingers sliding off the edge. Every scenario checks the stream's
/// invariants AND that the apps saw exactly the drag the person
/// made: one press, one event number and click state for the whole
/// down/dragged/up sequence, the drop where the cursor was, and no
/// button left held.
@MainActor
@Suite("Drag scenarios")
struct DragScenarioTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]

    /// A realistic drag press for a threshold: people press 70-ish
    /// whatever the setting, harder when the threshold is high.
    static func peak(_ threshold: Double) -> Double { max(70, threshold * 1.4) }

    // MARK: Browser tabs

    /// Rearrange a Chrome tab: home in on the tab, press, pause a
    /// beat, slide it 300 px along the tab strip while the fingertip
    /// rolls (pressure dips to 30–60% of the peak once moving), drop.
    @Test(arguments: thresholds, [0.3, 0.45, 0.6])
    func rearrangeChromeTab(threshold: Double, dip: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.25, y: 0.15)
        let peak = Self.peak(threshold)
        hand.touchDown()
        hand.point(by: 0.04, 0.01, frames: 8)
        hand.press(to: peak, frames: 4)
        hand.hold(frames: 6)
        let start = hand.cursor
        hand.slide(by: 0.3, 0, frames: 45, pressure: roll(peak, dipTo: peak * dip))
        let drop = hand.cursor, dropTime = hand.now
        hand.hold(frames: 3)
        hand.ease(to: 2)
        hand.lift()

        expectDrag(performer, minDrags: 45, minExcursion: 299, dropAt: drop, notReleasedBefore: dropTime)
        #expect(abs(drop.x - start.x - 300) < 1, "tab travelled \(drop.x - start.x) px")
    }

    /// Rearrange a Safari tab leftwards across many tabs: the hand
    /// starts slow, speeds up, slows to place it (400 px).
    @Test(arguments: thresholds)
    func rearrangeSafariTabWithUnevenSpeed(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.75, y: 0.12)
        let peak = Self.peak(threshold)
        hand.touchDown()
        hand.press(to: peak)
        hand.hold(frames: 4)
        hand.slide(by: -0.03, 0, frames: 10) { _ in peak * 0.8 }
        hand.slide(by: -0.32, 0, frames: 12) { t in peak * (0.8 - 0.35 * sin(t * .pi)) }
        hand.slide(by: -0.05, 0, frames: 20) { _ in peak * 0.7 }
        let drop = hand.cursor, dropTime = hand.now
        hand.ease(to: 0, frames: 2)
        hand.lift()

        expectDrag(performer, minDrags: 42, minExcursion: 399, dropAt: drop, notReleasedBefore: dropTime)
    }

    /// Tear a tab off into its own window: drag down out of the tab
    /// strip, pause while the new window materialises, drop.
    @Test(arguments: thresholds)
    func tearTabOffIntoNewWindow(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.4, y: 0.1)
        let peak = Self.peak(threshold)
        hand.touchDown()
        hand.press(to: peak)
        hand.hold(frames: 4)
        hand.slide(by: 0.02, 0.28, frames: 35, pressure: roll(peak, dipTo: peak * 0.4))
        hand.hold(seconds: 0.3) { t in peak * (1 - 0.3 * sin(t * .pi)) }
        let drop = hand.cursor, dropTime = hand.now
        hand.ease(to: 1)
        hand.lift()

        expectDrag(performer, minDrags: 35, minExcursion: 280, dropAt: drop, notReleasedBefore: dropTime)
    }

    /// Tear a tab off, change your mind, drag it back into the strip
    /// a couple of tabs over: one press the whole way, even though
    /// the drop lands near where it started.
    @Test func tearTabOffAndDragItBack() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.4, y: 0.1)
        hand.touchDown()
        hand.press(to: 72)
        hand.hold(frames: 4)
        let start = hand.cursor
        hand.slide(by: 0, 0.25, frames: 30, pressure: roll(72, dipTo: 30))
        hand.hold(seconds: 0.25)
        hand.slide(by: 0.05, -0.24, frames: 30, pressure: roll(72, dipTo: 35))
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()

        expectDrag(performer, minDrags: 60, minExcursion: 245, dropAt: drop, notReleasedBefore: dropTime)
        #expect(distance(drop, ClickPoint(x: start.x + 50, y: start.y + 10)) < 1)
    }

    /// Long-press a tab (0.4 s, nothing moving) before deciding to
    /// drag it: the still hold must neither release nor re-click.
    @Test func longPressTabThenDrag() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.3, y: 0.1)
        hand.touchDown()
        hand.press(to: 66)
        hand.hold(seconds: 0.4) { t in 66 - 8 * sin(t * 6) }
        hand.slide(by: 0.2, 0, frames: 30, pressure: roll(66, dipTo: 26))
        let drop = hand.cursor, dropTime = hand.now
        hand.ease(to: 2)
        hand.lift()

        expectDrag(performer, minDrags: 30, minExcursion: 199, dropAt: drop, notReleasedBefore: dropTime)
    }

    /// Jab a tab hard (macOS's own press reaches the event tap
    /// before the touch frame), then drag it while the pressure
    /// relaxes from the jab: one press, the jab's event number all
    /// the way through.
    @Test(arguments: thresholds)
    func jabTabThenDrag(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.3, y: 0.12)
        hand.touchDown(pressure: 8)
        hand.press(to: 150, frames: 1, jab: true)
        hand.hold(frames: 2)
        hand.slide(by: 0.22, 0, frames: 28) { t in 150 - 95 * sin(t * .pi / 2) }
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()

        expectDrag(performer, minDrags: 28, minExcursion: 219, dropAt: drop, notReleasedBefore: dropTime)
        #expect(performer.trace.contains { $0.contains("native leftMouseDown → swallowed") }, "the jab path was not exercised")
    }

    /// A feather-light hand: the press barely clears the threshold
    /// (105%), and the roll sags it to under 60% of that mid-slide.
    @Test(arguments: thresholds)
    func featherLightTabDrag(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.3, y: 0.1)
        let peak = threshold * 1.05
        hand.touchDown(pressure: min(12, threshold * 0.4))
        hand.press(to: peak, frames: 4)
        hand.hold(frames: 3)
        hand.slide(by: 0.25, 0, frames: 35, pressure: roll(peak, dipTo: peak * 0.55))
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()

        expectDrag(performer, minDrags: 35, minExcursion: 249, dropAt: drop, notReleasedBefore: dropTime)
    }

    // MARK: Windows

    /// Drag a window by its title bar: across the screen, back the
    /// other way, a half-second pause to look, then down and up a
    /// little to line it up — one press throughout.
    @Test(arguments: thresholds)
    func dragWindowByTitleBarWithReversals(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.3, y: 0.2)
        let peak = Self.peak(threshold)
        hand.touchDown()
        hand.press(to: peak)
        hand.hold(frames: 5)
        let start = hand.cursor
        hand.slide(by: 0.3, 0, frames: 30, pressure: roll(peak, dipTo: peak * 0.45))
        hand.slide(by: -0.15, 0, frames: 20, pressure: roll(peak, dipTo: peak * 0.5))
        hand.hold(seconds: 0.5) { t in peak * (0.75 - 0.1 * sin(t * 9)) }
        hand.slide(by: 0, 0.1, frames: 15, pressure: roll(peak * 0.75, dipTo: peak * 0.4))
        hand.slide(by: 0, -0.05, frames: 10) { _ in peak * 0.7 }
        let drop = hand.cursor, dropTime = hand.now
        hand.ease(to: 1)
        hand.lift()

        expectDrag(performer, minDrags: 75, minExcursion: 299, dropAt: drop, notReleasedBefore: dropTime)
        #expect(distance(drop, ClickPoint(x: start.x + 150, y: start.y + 50)) < 1)
    }

    /// Drag a file onto a Finder folder and hover a full second for
    /// the spring-loaded folder to open — the hand relaxes to half
    /// the peak while waiting — then carry on into the opened window
    /// and drop. The pause must not release.
    @Test(arguments: thresholds)
    func springLoadedFolderHover(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.3, y: 0.5)
        let peak = Self.peak(threshold)
        hand.touchDown()
        hand.press(to: peak)
        hand.hold(frames: 4)
        hand.slide(by: 0.2, -0.08, frames: 25, pressure: roll(peak, dipTo: peak * 0.4))
        let hoverStart = hand.now
        hand.hold(seconds: 1.0) { t in peak * (1 - 0.5 * sin(t * .pi)) }
        let hoverEnd = hand.now
        hand.slide(by: 0.06, 0.03, frames: 10) { _ in peak * 0.8 }
        let drop = hand.cursor, dropTime = hand.now
        hand.ease(to: 2)
        hand.lift()

        expectDrag(performer, minDrags: 35, minExcursion: 250, dropAt: drop, notReleasedBefore: dropTime)
        let ups = performer.events.filter { if case let .up(t, _, _, _) = $0 { t >= hoverStart && t <= hoverEnd } else { false } }
        #expect(ups.isEmpty, "released during the spring-loaded hover\n\(performer.report())")
    }

    /// Drag a window from one display to the other: one long stroke
    /// nearly edge to edge of the pad (900 px), the roll dipping
    /// twice along the way.
    @Test func dragWindowAcrossDisplays() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.05, y: 0.3)
        hand.touchDown()
        hand.press(to: 75)
        hand.hold(frames: 4)
        hand.slide(by: 0.9, 0.05, frames: 90) { t in 75 - 45 * abs(sin(t * 2 * .pi)) }
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()

        expectDrag(performer, minDrags: 90, minExcursion: 900, dropAt: drop, notReleasedBefore: dropTime)
    }

    /// Hold a window still mid-drag while deciding where it goes:
    /// the fingertip trembles (sub-pixel to 1 px jitter) and the
    /// pressure wanders for 0.8 s. Still one press; the drop is
    /// where the cursor ended.
    @Test func windowDragTremblingPause() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.3, y: 0.3)
        hand.touchDown()
        hand.press(to: 70)
        hand.hold(frames: 4)
        hand.slide(by: 0.15, 0.05, frames: 20, pressure: roll(70, dipTo: 35))
        let cx = hand.finger.x, cy = hand.finger.y
        for i in 0 ..< 100 {
            hand.finger.x = cx + 0.0008 * sin(Double(i) * 1.3)
            hand.finger.y = cy + 0.0005 * cos(Double(i) * 0.9)
            hand.finger.pressure = 55 + 15 * sin(Double(i) * 0.21)
            hand.frame()
        }
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()

        expectDrag(performer, minDrags: 100, minExcursion: 150, dropAt: drop, notReleasedBefore: dropTime)
    }

    // MARK: Text selection

    /// Select a paragraph: press at the start of a line and drag
    /// slowly right and down across four lines of text.
    @Test(arguments: thresholds)
    func selectAcrossParagraph(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.2, y: 0.4)
        let peak = Self.peak(threshold)
        hand.touchDown()
        hand.press(to: peak)
        hand.hold(frames: 2)
        hand.slide(by: 0.4, 0.07, frames: 90) { t in peak * (0.85 - 0.3 * sin(t * 3 * .pi)) }
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()

        expectDrag(performer, minDrags: 90, minExcursion: 400, dropAt: drop, notReleasedBefore: dropTime)
    }

    /// Double-click a word and keep holding to drag (select word by
    /// word): the second press, its dragged events and its up all
    /// carry click state 2 and the second press's own number.
    @Test(arguments: thresholds)
    func doubleClickDragSelectsByWord(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.4, y: 0.4)
        let peak = Self.peak(threshold)
        hand.touchDown(pressure: 8)
        hand.press(to: peak, frames: 2)
        hand.hold(frames: 2)
        hand.ease(to: 8, frames: 2)
        hand.lift()
        performer.wait(0.12)
        hand.touchDown(pressure: 8)
        hand.press(to: peak, frames: 2)
        hand.hold(frames: 2)
        hand.slide(by: 0.18, 0.02, frames: 30, pressure: roll(peak, dipTo: peak * 0.45))
        let drop = hand.cursor, dropTime = hand.now
        hand.ease(to: 1)
        hand.lift()

        expectDrag(performer, presses: 2, clickState: 2, minDrags: 30, minExcursion: 180, dropAt: drop,
                   notReleasedBefore: dropTime)
        let clicks = performer.clicks
        if clicks.count == 2 {
            #expect(clicks[0].clickState == 1 && !clicks[0].isDrag, "\(performer.report())")
            #expect(clicks[0].number != clicks[1].number)
        }
    }

    /// Triple-click a line and drag to extend the selection line by
    /// line: the third press drags with click state 3.
    @Test func tripleClickDragSelectsByLine() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.4, y: 0.3)
        for _ in 0 ..< 2 {
            hand.touchDown(pressure: 8)
            hand.press(to: 68, frames: 2)
            hand.hold(frames: 2)
            hand.ease(to: 8, frames: 2)
            hand.lift()
            performer.wait(0.1)
        }
        hand.touchDown(pressure: 8)
        hand.press(to: 68, frames: 2)
        hand.hold(frames: 2)
        hand.slide(by: 0.02, 0.12, frames: 25, pressure: roll(68, dipTo: 30))
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()

        expectDrag(performer, presses: 3, clickState: 3, minDrags: 25, minExcursion: 120, dropAt: drop,
                   notReleasedBefore: dropTime)
        #expect(performer.clicks.map(\.clickState) == [1, 2, 3])
    }

    /// Select some text, then click somewhere else to deselect: the
    /// click is a plain click #1, not chained to the selection.
    @Test func selectThenClickElsewhereToDeselect() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.3, y: 0.4)
        hand.touchDown()
        hand.press(to: 70)
        hand.hold(frames: 2)
        hand.slide(by: 0.15, 0, frames: 20, pressure: roll(70, dipTo: 32))
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()
        performer.wait(0.08)
        hand.touchDown()
        hand.point(by: -0.1, 0.12, frames: 10)
        hand.press(to: 68, frames: 2)
        hand.hold(frames: 2)
        hand.ease(to: 8, frames: 2)
        hand.lift()

        expectDrag(performer, presses: 2, index: 0, minDrags: 20, minExcursion: 150, dropAt: drop,
                   notReleasedBefore: dropTime)
        let clicks = performer.clicks
        if clicks.count == 2 {
            #expect(clicks[1].clickState == 1 && !clicks[1].isDrag && clicks[1].drags.isEmpty, "\(performer.report())")
        }
    }

    /// Two selections in quick succession (select, lift, immediately
    /// select the next phrase from where the first ended): two
    /// separate drags, separate event numbers, both click #1.
    @Test func twoSelectionsInQuickSuccession() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.3, y: 0.4)
        var drops: [ClickPoint] = []
        for _ in 0 ..< 2 {
            hand.touchDown(pressure: 8)
            hand.press(to: 70, frames: 2)
            hand.slide(by: 0.1, 0, frames: 8) { _ in 64 }
            drops.append(hand.cursor)
            hand.lift()
            performer.wait(0.05)
        }

        expectClean(performer)
        for i in 0 ..< 2 {
            expectOutcome(dragProblems(performer, presses: 2, index: i, minDrags: 8, minExcursion: 100, dropAt: drops[i]), performer)
        }
        let clicks = performer.clicks
        if clicks.count == 2 {
            #expect(clicks.map(\.clickState) == [1, 1], "\(performer.report())")
            #expect(clicks[0].number != clicks[1].number)
        }
    }

    /// Drag-select right, then back left past the starting point
    /// (the selection flips to the other side): one press.
    @Test func selectionFlipsBackPastStart() {
        let performer = Performer(rig: TestRig(threshold: 40))
        let hand = Hand(performer, x: 0.5, y: 0.4)
        hand.touchDown()
        hand.press(to: 70)
        hand.hold(frames: 2)
        let start = hand.cursor
        hand.slide(by: 0.12, 0, frames: 15, pressure: roll(70, dipTo: 35))
        hand.slide(by: -0.25, 0, frames: 30, pressure: roll(70, dipTo: 30))
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()

        expectDrag(performer, minDrags: 45, minExcursion: 130, dropAt: drop, notReleasedBefore: dropTime)
        #expect(abs(drop.x - (start.x - 130)) < 1)
    }

    // MARK: Files, sliders, scrollbars

    /// Drag a file onto a folder with a firm press (hard enough for
    /// macOS's own click too, which the event tap swallows): one
    /// press, no native press leaks.
    @Test(arguments: thresholds)
    func dragFileOntoFolderFirmly(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.25, y: 0.6)
        hand.touchDown()
        hand.press(to: 130, frames: 4)
        hand.hold(frames: 4)
        hand.slide(by: 0.25, -0.2, frames: 35, pressure: roll(130, dipTo: 60))
        let drop = hand.cursor, dropTime = hand.now
        hand.hold(frames: 4)
        hand.ease(to: 2, frames: 4)
        hand.lift()

        expectDrag(performer, minDrags: 35, minExcursion: 320, dropAt: drop, notReleasedBefore: dropTime)
    }

    /// A firm file drag whose roll sags below macOS's own release
    /// point and back: macOS posts its native up mid-drag and a new
    /// native down when the pressure recovers. Both are swallowed;
    /// apps still see one press.
    @Test func firmDragNativeReleaseAndRepressMidDrag() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.25, y: 0.6)
        hand.touchDown()
        hand.press(to: 130, frames: 4)
        hand.hold(frames: 3)
        hand.slide(by: 0.3, 0, frames: 40, pressure: roll(130, dipTo: 35))
        let drop = hand.cursor, dropTime = hand.now
        hand.ease(to: 1, frames: 4)
        hand.lift()

        expectDrag(performer, minDrags: 40, minExcursion: 299, dropAt: drop, notReleasedBefore: dropTime)
        let nativeDowns = performer.trace.filter { $0.contains("native leftMouseDown") }.count
        #expect(nativeDowns >= 2, "scenario should re-cross macOS's own click mid-drag\n\(performer.report())")
    }

    /// Scrub a volume / video slider back and forth slowly for 2.4 s,
    /// the pressure wobbling ±25% as the hand works it.
    @Test(arguments: thresholds)
    func scrubSliderBackAndForth(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.5, y: 0.7)
        let peak = Self.peak(threshold)
        hand.touchDown()
        hand.press(to: peak)
        hand.hold(frames: 3)
        for stroke in 0 ..< 6 {
            let dir = stroke % 2 == 0 ? 1.0 : -1.0
            hand.slide(by: 0.08 * dir, 0, frames: 50) { t in peak * (1 - 0.25 * sin(t * 4 * .pi)) }
        }
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()

        expectDrag(performer, minDrags: 300, minExcursion: 79, dropAt: drop, notReleasedBefore: dropTime)
    }

    /// Drag a scrollbar thumb down a long document, pause to read,
    /// drag back up a bit.
    @Test func dragScrollbarThumb() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.95, y: 0.2)
        hand.touchDown()
        hand.press(to: 68)
        hand.hold(frames: 3)
        hand.slide(by: 0, 0.3, frames: 60, pressure: roll(68, dipTo: 30))
        hand.hold(seconds: 0.2) { _ in 50 }
        hand.slide(by: 0, -0.1, frames: 20) { _ in 55 }
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()

        expectDrag(performer, minDrags: 80, minExcursion: 300, dropAt: drop, notReleasedBefore: dropTime)
    }

    /// A careful, very slow drag start: the finger creeps 1 px a
    /// frame for ten frames at steady pressure before committing.
    @Test func creepingSlowDragStart() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.4, y: 0.5)
        hand.touchDown()
        hand.press(to: 66)
        hand.hold(frames: 3)
        hand.slide(by: 0.01, 0, frames: 10) { _ in 64 }
        hand.slide(by: 0.15, 0, frames: 20, pressure: roll(64, dipTo: 28))
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()

        expectDrag(performer, minDrags: 30, minExcursion: 160, dropAt: drop, notReleasedBefore: dropTime)
    }

    /// Already-known limitation, pinned: a very slow start where the
    /// fingertip roll sags the pressure under 70% of the threshold
    /// before the cursor has crept 5 px. The press releases and
    /// re-presses (apps see two presses, the second chained as a
    /// double-click).
    @Test func creepingStartWithEarlyRoll() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.4, y: 0.5)
        hand.touchDown()
        hand.press(to: 62)
        hand.hold(frames: 2)
        hand.slide(by: 0.004, 0, frames: 8) { t in 62 - 32 * t }
        hand.slide(by: 0.15, 0, frames: 20) { t in 30 + 32 * t }
        let drop = hand.cursor
        hand.lift()

        expectClean(performer)
        withKnownIssue("Known limitation: roll below 70% of threshold before 5 px of travel releases and re-presses") {
            expectOutcome(dragProblems(performer, minDrags: 20, minExcursion: 150, dropAt: drop), performer)
        }
    }

    /// A fast flick drag: press and throw the item 400 px in four
    /// frames, then lift straight away.
    @Test(arguments: thresholds)
    func fastFlickDrag(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.3, y: 0.5)
        let peak = Self.peak(threshold)
        hand.touchDown()
        hand.press(to: peak, frames: 2)
        hand.hold(frames: 1)
        hand.slide(by: 0.4, 0, frames: 4) { t in peak * (1 - 0.3 * t) }
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()

        expectDrag(performer, minDrags: 4, minExcursion: 399, dropAt: drop, notReleasedBefore: dropTime)
    }

    /// Press while the finger is still travelling towards the item
    /// (no stop first), and keep going: the movement before the
    /// press is plain pointing, the movement after it drags.
    @Test func pressWhileStillMovingThenDrag() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.3, y: 0.5)
        let start = hand.cursor
        hand.touchDown()
        hand.point(by: 0.05, 0, frames: 5)
        hand.slide(by: 0.03, 0, frames: 3) { t in 12 + 58 * t }
        hand.slide(by: 0.2, 0, frames: 20, pressure: roll(70, dipTo: 30))
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()

        expectDrag(performer, minDrags: 20, minExcursion: 200, dropAt: drop, notReleasedBefore: dropTime)
        // The press fires during the ramp (frame 2 of 3): the 50 px of
        // pointing before it, and the first ramp frame, moved the
        // cursor with no button down.
        if let press = performer.clicks.first {
            #expect(press.downPoint.x - start.x >= 59, "pointing before the press was dragged\n\(performer.report())")
            #expect(press.drags.count <= 22, "\(performer.report())")
        }
    }

    // MARK: Hands: flattening fingertips, resting thumbs, palms

    /// A fingertip pressing into a long drag flattens: its contact
    /// grows past 20 mm (palm size) mid-drag and shrinks back. The
    /// tracked finger is exempt from the palm filter — the drag must
    /// not be cut.
    @Test(arguments: thresholds)
    func fingertipFlattensBeyondPalmSize(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.3, y: 0.5)
        let peak = Self.peak(threshold)
        hand.touchDown()
        hand.press(to: peak)
        hand.hold(frames: 3)
        hand.slide(by: 0.3, 0.05, frames: 40, pressure: roll(peak, dipTo: peak * 0.5),
                   major: { t in 10 + 14 * sin(t * .pi) })
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()

        expectDrag(performer, minDrags: 40, minExcursion: 300, dropAt: drop, notReleasedBefore: dropTime)
    }

    /// Same flattening fingertip, with a thumb resting on the pad
    /// the whole time.
    @Test func fingertipFlattensWithRestingThumb() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.4, y: 0.4)
        hand.others = [Contact(id: 9, x: 0.35, y: 0.88, pressure: 12, major: 13)]
        for _ in 0 ..< 38 { performer.frame(hand.others, pointer: nil) } // already resting
        hand.touchDown(pressure: 8)
        hand.press(to: 75)
        hand.hold(frames: 5)
        hand.slide(by: 0.25, 0, frames: 35, pressure: roll(75, dipTo: 35), major: { t in 10 + 13 * sin(t * .pi) })
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()
        performer.lift()

        expectDrag(performer, minDrags: 35, minExcursion: 250, dropAt: drop, notReleasedBefore: dropTime)
    }

    /// Drag with a thumb resting at the bottom of the pad (the usual
    /// posture): the index presses, holds a beat, drags, drops.
    @Test(arguments: thresholds)
    func dragWithRestingThumb(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.4, y: 0.4)
        hand.others = [Contact(id: 9, x: 0.35, y: 0.88, pressure: 12, major: 13)]
        let peak = Self.peak(threshold)
        for _ in 0 ..< 38 { performer.frame(hand.others, pointer: nil) } // already resting
        hand.touchDown(pressure: 8)
        hand.press(to: peak)
        hand.hold(frames: 5)
        hand.slide(by: 0.25, -0.05, frames: 35, pressure: roll(peak, dipTo: peak * 0.4))
        let drop = hand.cursor, dropTime = hand.now
        hand.ease(to: 2)
        hand.lift()
        performer.lift()

        expectDrag(performer, minDrags: 35, minExcursion: 254, dropAt: drop, notReleasedBefore: dropTime)
    }

    /// Mid-drag, the thumb comes down to rest on the pad (no press):
    /// the drag carries on undisturbed.
    @Test func thumbLandsToRestMidDrag() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.3, y: 0.4)
        hand.touchDown()
        hand.press(to: 70)
        hand.hold(frames: 3)
        hand.slide(by: 0.12, 0, frames: 15, pressure: roll(70, dipTo: 40))
        hand.others = [Contact(id: 9, x: 0.35, y: 0.88, pressure: 6, major: 13)]
        hand.hold(frames: 1)
        hand.others[0].pressure = 14
        hand.slide(by: 0.15, 0.03, frames: 20, pressure: roll(70, dipTo: 35))
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()
        performer.lift()

        expectDrag(performer, minDrags: 35, minExcursion: 270, dropAt: drop, notReleasedBefore: dropTime)
    }

    /// Suspected bug: mid-drag, the resting thumb tenses (its reading
    /// climbs to 120% of the threshold for ~50 ms) while the index
    /// keeps dragging. On a real Mac the button stays down — a finger
    /// added mid-press never turns a held click into anything else —
    /// so the file keeps moving. The engine treats it as a two-finger
    /// chord: releases the drag where it is and locks until lift.
    /// (Peak kept under macOS's own click; the firm variant is
    /// `thumbTensesDuringFirmDragLeaksNativeUp`.)
    @Test(arguments: thresholds)
    func restingThumbTensesMidDrag(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.3, y: 0.4)
        hand.others = [Contact(id: 9, x: 0.35, y: 0.88, pressure: 12, major: 13)]
        let peak = min(85, Self.peak(threshold))
        hand.touchDown(pressure: 8)
        hand.press(to: peak)
        hand.hold(frames: 5)
        hand.slide(by: 0.12, 0, frames: 15, pressure: roll(peak, dipTo: peak * 0.5))
        hand.others[0].pressure = threshold * 1.2
        hand.slide(by: 0.04, 0, frames: 6) { _ in peak }
        hand.others[0].pressure = 12
        hand.slide(by: 0.12, 0, frames: 15, pressure: roll(peak, dipTo: peak * 0.5))
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()
        performer.lift()

        expectClean(performer)
        withKnownIssue("BUG: a resting thumb pressing past the threshold mid-drag drops a latched drag (chord release)") {
            expectOutcome(dragProblems(performer, minDrags: 36, minExcursion: 280, dropAt: drop, notReleasedBefore: dropTime),
                          performer)
        }
    }

    /// Suspected bug (second symptom of the chord release above): a
    /// FIRM drag — hard enough that macOS's own click went down and
    /// the event tap swallowed it — when the thumb tenses. The engine
    /// releases its click and locks; the index keeps pressing, so the
    /// native button stays down; when the index finally lets go
    /// (> 150 ms later) the native mouse-up is no longer recognised
    /// as ours and passes through: apps get a mouse-up with no
    /// mouse-down.
    @Test func thumbTensesDuringFirmDragLeaksNativeUp() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.3, y: 0.4)
        hand.others = [Contact(id: 9, x: 0.35, y: 0.88, pressure: 12, major: 13)]
        hand.touchDown(pressure: 8)
        hand.press(to: 120, frames: 4)
        hand.hold(frames: 4)
        hand.slide(by: 0.15, 0, frames: 20, pressure: roll(120, dipTo: 70))
        hand.others[0].pressure = 60
        hand.slide(by: 0.03, 0, frames: 5) { _ in 120 }
        hand.others[0].pressure = 12
        hand.slide(by: 0.1, 0, frames: 15) { _ in 110 }
        let drop = hand.cursor, dropTime = hand.now
        hand.ease(to: 2, frames: 4)
        hand.lift()
        performer.lift()

        #expect(performer.trace.contains { $0.contains("native leftMouseDown → swallowed") }, "macOS's own click never went down")
        withKnownIssue("BUG: native up of a swallowed native press leaks after a chord release (> 150 ms later)") {
            expectClean(performer)
        }
        withKnownIssue("BUG: a resting thumb pressing past the threshold mid-drag drops a latched drag (chord release)") {
            expectOutcome(dragProblems(performer, minDrags: 40, minExcursion: 280, dropAt: drop, notReleasedBefore: dropTime),
                          performer)
        }
    }

    /// The classic two-finger drag: the thumb presses and holds the
    /// click at the bottom of the pad while the index finger slides
    /// to move the cursor; the drop comes when the thumb lifts.
    @Test(arguments: thresholds)
    func thumbHoldsIndexSlides(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let peak = Self.peak(threshold)
        var index = Contact(id: 1, x: 0.4, y: 0.4, pressure: 12)
        var thumb = Contact(id: 2, x: 0.45, y: 0.88, pressure: 6, major: 13)
        for _ in 0 ..< 38 { performer.frame([index], pointer: 1) } // index was pointing
        performer.frame([index, thumb], pointer: 1)
        for i in 1 ... 4 {
            thumb.pressure = 6 + (peak - 6) * Double(i) / 4
            thumb.major = 13 + 4 * Double(i) / 4
            performer.frame([index, thumb], pointer: 1)
        }
        for _ in 0 ..< 4 { performer.frame([index, thumb], pointer: 1) }
        let start = performer.cursor
        for i in 1 ... 40 {
            index.x = 0.4 + 0.3 * Double(i) / 40
            thumb.pressure = peak * (1 - 0.15 * sin(Double(i) * 0.4))
            performer.frame([index, thumb], pointer: 1)
        }
        let drop = performer.cursor, dropTime = performer.rig.clock.time
        performer.frame([index], pointer: 1) // thumb lifts
        performer.frame([index], pointer: 1)
        performer.lift()

        expectDrag(performer, minDrags: 40, minExcursion: 299, dropAt: drop, notReleasedBefore: dropTime)
        #expect(abs(drop.x - start.x - 300) < 1, "cursor did not follow the index")
    }

    /// The two-finger drag over a long distance: the thumb holds
    /// while the index swipes, lifts, comes back and swipes again
    /// (like rowing) — one press across both strokes.
    @Test func thumbHoldsIndexRepositions() {
        let performer = Performer(rig: TestRig(threshold: 50))
        var index = Contact(id: 1, x: 0.3, y: 0.4, pressure: 12)
        var thumb = Contact(id: 2, x: 0.45, y: 0.88, pressure: 6, major: 13)
        for _ in 0 ..< 38 { performer.frame([index], pointer: 1) } // index was pointing
        for i in 1 ... 4 {
            thumb.pressure = 6 + 70 * Double(i) / 4
            performer.frame([index, thumb], pointer: 1)
        }
        for _ in 0 ..< 4 { performer.frame([index, thumb], pointer: 1) }
        for stroke in 0 ..< 2 {
            for i in 1 ... 25 {
                index.x = 0.3 + 0.3 * Double(i) / 25
                thumb.pressure = 76 - 20 * sin(Double(i) * 0.3)
                performer.frame([index, thumb], pointer: 1)
            }
            if stroke == 0 {
                // Index lifts and comes back to the left; thumb holds.
                performer.frame([thumb], pointer: nil)
                performer.frame([thumb], pointer: nil)
                index.x = 0.3
                performer.frame([index, thumb], pointer: 1)
            }
        }
        let drop = performer.cursor, dropTime = performer.rig.clock.time
        thumb.pressure = 20
        performer.frame([index, thumb], pointer: 1)
        performer.frame([index], pointer: 1)
        performer.lift()

        expectDrag(performer, minDrags: 50, minExcursion: 599, dropAt: drop, notReleasedBefore: dropTime)
    }

    /// Suspected bug: in the two-finger drag, the thumb eases off to
    /// a light rest (the index stays on the glass to keep pointing)
    /// and the index moves on. On a real Mac easing the thumb ends
    /// the click there; the engine keeps the latched drag held
    /// until the thumb fully lifts, so the item follows the index
    /// past the intended drop point.
    @Test(arguments: thresholds)
    func thumbEasesOffToDrop(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let peak = Self.peak(threshold)
        var index = Contact(id: 1, x: 0.4, y: 0.4, pressure: 12)
        var thumb = Contact(id: 2, x: 0.45, y: 0.88, pressure: 6, major: 13)
        performer.frame([index], pointer: 1)
        for i in 1 ... 4 {
            thumb.pressure = 6 + (peak - 6) * Double(i) / 4
            performer.frame([index, thumb], pointer: 1)
        }
        for _ in 0 ..< 4 { performer.frame([index, thumb], pointer: 1) }
        for i in 1 ... 30 {
            index.x = 0.4 + 0.2 * Double(i) / 30
            performer.frame([index, thumb], pointer: 1)
        }
        let drop = performer.cursor, dropTime = performer.rig.clock.time
        for i in 1 ... 4 {
            thumb.pressure = peak + (10 - peak) * Double(i) / 4
            performer.frame([index, thumb], pointer: 1)
        }
        for i in 1 ... 15 {
            index.x = 0.6 + 0.1 * Double(i) / 15
            performer.frame([index, thumb], pointer: 1)
        }
        performer.lift()

        expectClean(performer)
        withKnownIssue("BUG: a latched drag ignores easing off to resting pressure; only a full lift drops it") {
            expectOutcome(dragProblems(performer, minDrags: 30, minExcursion: 199, dropAt: drop, notReleasedBefore: dropTime),
                          performer)
        }
    }

    /// Drag with the heel of the other hand resting on the pad edge
    /// (palm, 28 mm, heavy): the palm is ignored; the drag is clean.
    @Test func dragWithPalmResting() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.5, y: 0.4)
        hand.others = [Contact(id: 20, x: 0.1, y: 0.9, pressure: 70, major: 28)]
        for _ in 0 ..< 38 { performer.frame(hand.others, pointer: nil) } // already resting
        hand.touchDown()
        hand.press(to: 70)
        hand.hold(frames: 3)
        hand.slide(by: 0.25, 0, frames: 30, pressure: roll(70, dipTo: 30))
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()
        performer.lift()

        expectDrag(performer, minDrags: 30, minExcursion: 250, dropAt: drop, notReleasedBefore: dropTime)
    }

    /// Jab-start a drag with a thumb resting: macOS's own press
    /// wins the race, the engine answers it, and the press belongs
    /// to the index (not the thumb) through the whole drag.
    @Test func jabDragWithRestingThumb() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.4, y: 0.4)
        hand.others = [Contact(id: 9, x: 0.35, y: 0.88, pressure: 14, major: 13)]
        for _ in 0 ..< 38 { performer.frame(hand.others, pointer: nil) } // already resting
        hand.touchDown(pressure: 8)
        hand.press(to: 150, frames: 1, jab: true)
        hand.hold(frames: 2)
        hand.slide(by: 0.2, 0, frames: 25) { t in 150 - 90 * sin(t * .pi / 2) }
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()
        performer.lift()

        expectDrag(performer, minDrags: 25, minExcursion: 200, dropAt: drop, notReleasedBefore: dropTime)
    }

    // MARK: How drags end

    /// Mid-drag the finger slides off the edge of the pad: the
    /// contact simply disappears. The drag must drop right there —
    /// never a stuck button.
    @Test(arguments: thresholds)
    func fingerSlidesOffPadEdge(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.6, y: 0.5)
        let peak = Self.peak(threshold)
        hand.touchDown()
        hand.press(to: peak)
        hand.hold(frames: 3)
        hand.slide(by: 0.39, 0, frames: 30) { _ in peak * 0.8 }
        let lastSeen = hand.cursor, lastSeenTime = hand.now
        hand.lift()

        expectDrag(performer, minDrags: 30, minExcursion: 389, dropAt: lastSeen, notReleasedBefore: lastSeenTime)
    }

    /// The finger slides off the pad edge while the thumb rests on
    /// the glass: the press goes with the finger that made it.
    @Test func fingerSlidesOffEdgeWithThumbResting() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.6, y: 0.4)
        hand.others = [Contact(id: 9, x: 0.35, y: 0.88, pressure: 12, major: 13)]
        for _ in 0 ..< 38 { performer.frame(hand.others, pointer: nil) } // already resting
        hand.touchDown(pressure: 8)
        hand.press(to: 70)
        hand.hold(frames: 4)
        hand.slide(by: 0.39, 0, frames: 30) { _ in 60 }
        let lastSeen = hand.cursor, lastSeenTime = hand.now
        hand.lift() // index gone, thumb still resting
        let releasedWithThumbDown = !performer.engine.buttonDown
        performer.frame(hand.others, pointer: nil)
        performer.lift()

        expectDrag(performer, minDrags: 30, minExcursion: 389, dropAt: lastSeen, notReleasedBefore: lastSeenTime)
        #expect(releasedWithThumbDown, "drag still held after its finger left, thumb resting\n\(performer.report())")
    }

    /// Drop by lifting the finger abruptly at full pressure, still
    /// moving — no easing off at all.
    @Test(arguments: thresholds)
    func dropByAbruptLift(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.3, y: 0.5)
        let peak = Self.peak(threshold)
        hand.touchDown()
        hand.press(to: peak)
        hand.hold(frames: 3)
        hand.slide(by: 0.2, 0.1, frames: 25) { _ in peak }
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()

        expectDrag(performer, minDrags: 25, minExcursion: 223, dropAt: drop, notReleasedBefore: dropTime)
    }

    /// Drop by easing all the way off before lifting: the up comes
    /// at the drop point, before the finger leaves.
    @Test(arguments: thresholds)
    func dropByEasingOffThenLift(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.3, y: 0.5)
        let peak = Self.peak(threshold)
        hand.touchDown()
        hand.press(to: peak)
        hand.hold(frames: 3)
        hand.slide(by: 0.2, 0, frames: 25, pressure: roll(peak, dipTo: peak * 0.4))
        let drop = hand.cursor, dropTime = hand.now
        hand.ease(to: 1, frames: 5)
        let releasedBeforeLift = !performer.engine.buttonDown
        hand.lift()

        expectDrag(performer, minDrags: 25, minExcursion: 200, dropAt: drop, notReleasedBefore: dropTime)
        #expect(releasedBeforeLift, "easing fully off did not release before the lift\n\(performer.report())")
    }

    /// Suspected bug: drop a file by easing off to pointing pressure
    /// (the finger stays on the glass, as it would on a real Mac) and
    /// move on to the next thing. Natively the click ends when the
    /// press does; here the latched drag stays down at any pressure
    /// a touching finger produces (10% of the threshold is 3–8,
    /// pointing is 10–20), so the file is carried along to wherever
    /// the finger finally lifts.
    @Test(arguments: thresholds)
    func dropByEasingToPointingThenMoveOn(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.3, y: 0.5)
        let peak = Self.peak(threshold)
        hand.touchDown()
        hand.press(to: peak)
        hand.hold(frames: 3)
        hand.slide(by: 0.2, 0, frames: 25, pressure: roll(peak, dipTo: peak * 0.45))
        let drop = hand.cursor, dropTime = hand.now
        hand.ease(to: 12, frames: 4)
        hand.hold(frames: 4)
        hand.point(by: 0.1, 0.1, frames: 12)
        hand.lift()

        expectClean(performer)
        withKnownIssue("BUG: a latched drag ignores easing off to pointing pressure; only a full lift drops it") {
            expectOutcome(dragProblems(performer, minDrags: 25, minExcursion: 200, dropAt: drop, notReleasedBefore: dropTime),
                          performer)
        }
    }

    /// Run out of pad mid-drag: drop, lift, put the finger back on
    /// the left and drag again. Two separate drags, each with its
    /// own event number; the second is a fresh click #1.
    @Test func runOutOfPadLiftAndDragAgain() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.5, y: 0.5)
        var drops: [ClickPoint] = []
        for _ in 0 ..< 2 {
            hand.finger.x = 0.5
            hand.touchDown(pressure: 8)
            hand.press(to: 70)
            hand.hold(frames: 3)
            hand.slide(by: 0.4, 0, frames: 30, pressure: roll(70, dipTo: 35))
            drops.append(hand.cursor)
            hand.lift()
            performer.wait(0.06)
        }

        expectClean(performer)
        for i in 0 ..< 2 {
            expectOutcome(dragProblems(performer, presses: 2, index: i, minDrags: 30, minExcursion: 400, dropAt: drops[i]),
                          performer)
        }
        let clicks = performer.clicks
        if clicks.count == 2 {
            #expect(clicks.map(\.clickState) == [1, 1])
            #expect(clicks[0].number != clicks[1].number)
            #expect(abs(drops[1].x - drops[0].x - 400) < 1, "the second stroke continues from the first drop")
        }
    }

    /// Drop a file in a folder, then double-click it right there to
    /// open it: the drag is click #1 on its own; the two clicks that
    /// follow are a clean 1 → 2 double-click, unaffected by the drag.
    @Test func dropFileThenDoubleClickIt() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let hand = Hand(performer, x: 0.3, y: 0.5)
        hand.touchDown()
        hand.press(to: 70)
        hand.hold(frames: 3)
        hand.slide(by: 0.2, 0.05, frames: 30, pressure: roll(70, dipTo: 32))
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()
        performer.wait(0.15)
        for _ in 0 ..< 2 {
            hand.touchDown(pressure: 8)
            hand.press(to: 68, frames: 2)
            hand.hold(frames: 2)
            hand.ease(to: 8, frames: 2)
            hand.lift()
            performer.wait(0.1)
        }

        expectDrag(performer, presses: 3, index: 0, minDrags: 30, minExcursion: 200, dropAt: drop,
                   notReleasedBefore: dropTime)
        let clicks = performer.clicks
        #expect(clicks.map(\.clickState) == [1, 1, 2], "\(performer.report())")
        #expect(clicks.dropFirst().allSatisfy { !$0.isDrag && distance($0.downPoint, drop) < 1 }, "\(performer.report())")
    }

    /// Drag, then immediately click a button somewhere else (drop a
    /// tab, click its close box): the click is a plain #1 with no
    /// dragged events of its own.
    @Test(arguments: thresholds)
    func dragThenImmediatelyClickElsewhere(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.3, y: 0.15)
        let peak = Self.peak(threshold)
        hand.touchDown()
        hand.press(to: peak)
        hand.hold(frames: 3)
        hand.slide(by: 0.15, 0, frames: 15, pressure: roll(peak, dipTo: peak * 0.5))
        let drop = hand.cursor, dropTime = hand.now
        hand.lift()
        hand.touchDown()
        hand.point(by: 0.03, 0.01, frames: 6)
        hand.press(to: peak, frames: 2)
        hand.hold(frames: 2)
        hand.ease(to: 8, frames: 2)
        hand.lift()

        expectDrag(performer, presses: 2, index: 0, minDrags: 15, minExcursion: 150, dropAt: drop,
                   notReleasedBefore: dropTime)
        let clicks = performer.clicks
        if clicks.count == 2 {
            #expect(clicks[1].clickState == 1 && clicks[1].drags.isEmpty, "\(performer.report())")
        }
    }

    /// Two quick tab flicks in a row: flick a tab right, lift, and
    /// within the double-click interval flick it again from where it
    /// landed. Far from the first press, so the second must NOT
    /// chain into click state 2 (that would select a word / open
    /// something instead of dragging).
    @Test(arguments: thresholds)
    func twoQuickDragsInARowDoNotChain(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hand = Hand(performer, x: 0.3, y: 0.15)
        let peak = Self.peak(threshold)
        var drops: [ClickPoint] = []
        for _ in 0 ..< 2 {
            hand.touchDown(pressure: 8)
            hand.press(to: peak, frames: 2)
            hand.slide(by: 0.12, 0, frames: 8) { t in peak * (1 - 0.3 * sin(t * .pi)) }
            drops.append(hand.cursor)
            hand.lift()
            performer.wait(0.04)
        }

        expectClean(performer)
        for i in 0 ..< 2 {
            expectOutcome(dragProblems(performer, presses: 2, index: i, minDrags: 8, minExcursion: 120, dropAt: drops[i]),
                          performer)
        }
        let clicks = performer.clicks
        if clicks.count == 2 {
            #expect(clicks[1].downAt - clicks[0].downAt < performer.rig.doubleClickInterval, "scenario must be within the interval")
            #expect(clicks.map(\.clickState) == [1, 1], "\(performer.report())")
        }
    }
}
