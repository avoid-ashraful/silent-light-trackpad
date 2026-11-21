import Foundation
@testable import LightClickCore

// MARK: - Pressure curves

/// How one finger presses: lands light, ramps to a peak, holds
/// (with optional jitter), eases off, lifts. Pressures are in the
/// app's units (threshold 50 by default; ~10–20 resting / pointing;
/// macOS's own click fires near 90).
struct Press: CustomStringConvertible {
    var finger: Int32 = 1
    var x = 0.5
    var y = 0.5
    /// Pressure the finger lands with.
    var landing = 8.0
    var peak = 70.0
    var rampFrames = 3
    var holdFrames = 4
    var releaseFrames = 3
    /// ± pressure noise during the hold (deterministic sine).
    var jitter = 0.0
    var major = 10.0
    /// Deliver macOS's native press before the frame that crosses
    /// the native threshold (a fast jab winning the race).
    var nativeFirst = false

    var description: String {
        String(format: "press(f%d peak %.0f ramp %d hold %d release %d%@%@)", finger, peak, rampFrames, holdFrames,
               releaseFrames, jitter > 0 ? String(format: " jitter %.0f", jitter) : "", nativeFirst ? " nativeFirst" : "")
    }

    /// The pressure at each frame of the press, landing to release
    /// (lift not included).
    var curve: [Double] {
        var values: [Double] = [landing]
        for i in 1 ... max(1, rampFrames) {
            values.append(landing + (peak - landing) * Double(i) / Double(max(1, rampFrames)))
        }
        for i in 0 ..< holdFrames {
            values.append(peak + jitter * sin(Double(i) * 1.7))
        }
        for i in 1 ... max(1, releaseFrames) {
            values.append(peak + (landing - peak) * Double(i) / Double(max(1, releaseFrames)))
        }
        return values
    }

    /// The highest pressure the curve actually reaches (jitter
    /// included) — what decides whether it clicks.
    var maxPressure: Double { curve.max() ?? peak }

    /// How many clicks one finger following this curve produces on
    /// its own: a press when pressure reaches the threshold, a
    /// release when it falls to 70% of it (the hysteresis band).
    /// Jitter wider than the band legitimately re-clicks.
    func pressCount(threshold: Double) -> Int {
        var down = false, count = 0
        for value in curve {
            if !down, value >= threshold { down = true; count += 1 }
            else if down, value <= threshold * 0.7 { down = false }
        }
        return count
    }

    /// Longest run of consecutive frames at or above `level`.
    func longestRun(atOrAbove level: Double) -> Int {
        var best = 0, run = 0
        for value in curve {
            run = value >= level ? run + 1 : 0
            best = max(best, run)
        }
        return best
    }

    // Presets drawn from on-device behaviour.

    /// A deliberate light click: lands, presses past 50, eases off.
    static func light(finger: Int32 = 1) -> Press { Press(finger: finger, peak: 70) }
    /// A firm click that also trips macOS's native click (~90).
    static func firm(finger: Int32 = 1) -> Press { Press(finger: finger, peak: 130, rampFrames: 4, holdFrames: 6) }
    /// A fast, hard jab: one frame to the peak, native press first.
    static func jab(finger: Int32 = 1) -> Press {
        Press(finger: finger, peak: 150, rampFrames: 1, holdFrames: 2, releaseFrames: 1, nativeFirst: true)
    }
    /// A quick tap as used in rapid double/triple clicks.
    static func quick(finger: Int32 = 1) -> Press { Press(finger: finger, peak: 68, rampFrames: 2, holdFrames: 2, releaseFrames: 2) }
}

// MARK: - Gesture vocabulary

/// What the gesture should produce, checked on the output it
/// generated (used by the fuzz runner and scenario helpers).
enum Expectation: Equatable {
    /// No left click at all (scroll, swipe, pinch, pointing, palm,
    /// two-finger secondary click…).
    case noClicks
    /// Exactly n separate stationary clicks.
    case clicks(Int)
    /// Exactly one press that drags (travel > 5 px).
    case oneDrag
    /// Anything goes, as long as the invariants hold.
    case anything
}

/// A real-world trackpad gesture, as data: printable, so a fuzz
/// failure shows the exact sequence that broke.
indirect enum Gesture: CustomStringConvertible {
    /// One finger presses (and lifts).
    case click(Press)
    /// `count` presses at one spot, `gap` seconds between a lift and
    /// the next landing (double / triple / quadruple click).
    case multiClick(count: Int, gap: Double, press: Press)
    /// Single finger moves the pointer at hover pressure; never
    /// presses. `dx/dy` in pad units (1 unit ≈ 1000 px).
    case point(dx: Double, dy: Double, frames: Int, pressure: Double)
    /// Press, hold, slide `dx/dy` (cursor follows), drop. Pressure
    /// rolls down to `dipTo` mid-slide (fingertip rolling while it
    /// slides — the thing that used to kill tab drags), then back up
    /// to `peak` before the release.
    case drag(press: Press, dx: Double, dy: Double, frames: Int, dipTo: Double)
    /// Double-click-and-drag (select word by word): click, then
    /// press again within the interval and drag.
    case doubleClickDrag(gap: Double, dx: Double, frames: Int)
    /// Thumb presses near the bottom and holds the click while the
    /// index finger slides to move the cursor; thumb lets go.
    case thumbHoldIndexDrag(thumbPeak: Double, dx: Double, frames: Int)
    /// n fingers scroll/swipe together (2 = scroll, 3 = Mission
    /// Control / app switch, 4 = spaces). `heavy` gives one finger a
    /// load above the threshold; `landingSpike` spikes on landing.
    case scroll(fingers: Int, dx: Double, dy: Double, frames: Int, heavy: Double?, landingSpike: Bool)
    /// Two fingers spreading apart / pinching together.
    case pinch(spread: Double, frames: Int, pressure: Double)
    /// Two fingers rotating around their midpoint.
    case rotate(degrees: Double, frames: Int, pressure: Double)
    /// Both fingers press together: macOS's secondary (right) click.
    case twoFingerClick(peak: Double, offsetFrames: Int)
    /// A thumb (or second finger) rests while another finger clicks.
    case restingFingerClick(restPressure: Double, press: Press)
    /// A palm lies on the pad (typing posture); optionally a finger
    /// clicks meanwhile.
    case palmRest(palmPressure: Double, frames: Int, fingerPress: Press?)
    /// Second finger presses hard while a click is held (a chord):
    /// the held click must be released, never stranded.
    case chordMidClick(secondPeak: Double)
    /// External mouse clicks with no finger on the pad.
    case externalMouseClick
    /// Nobody touches anything.
    case pause(Double)

    var description: String {
        switch self {
        case let .click(p): "click(\(p))"
        case let .multiClick(n, gap, p): String(format: "multiClick(%d, gap %.2f, %@)", n, gap, p.description)
        case let .point(dx, dy, f, pr): String(format: "point(%.2f,%.2f over %d, p%.0f)", dx, dy, f, pr)
        case let .drag(p, dx, dy, f, dip): String(format: "drag(%@, %.2f,%.2f over %d, dip %.0f)", p.description, dx, dy, f, dip)
        case let .doubleClickDrag(gap, dx, f): String(format: "doubleClickDrag(gap %.2f, dx %.2f over %d)", gap, dx, f)
        case let .thumbHoldIndexDrag(tp, dx, f): String(format: "thumbHoldIndexDrag(thumb %.0f, dx %.2f over %d)", tp, dx, f)
        case let .scroll(n, dx, dy, f, heavy, spike):
            String(format: "scroll(%d fingers, %.2f,%.2f over %d%@%@)", n, dx, dy, f,
                   heavy.map { String(format: ", heavy %.0f", $0) } ?? "", spike ? ", landing spike" : "")
        case let .pinch(s, f, p): String(format: "pinch(spread %.2f over %d, p%.0f)", s, f, p)
        case let .rotate(d, f, p): String(format: "rotate(%.0f° over %d, p%.0f)", d, f, p)
        case let .twoFingerClick(peak, off): String(format: "twoFingerClick(peak %.0f, offset %d)", peak, off)
        case let .restingFingerClick(rest, p): String(format: "restingFingerClick(rest %.0f, %@)", rest, p.description)
        case let .palmRest(pp, f, fp): String(format: "palmRest(p%.0f over %d%@)", pp, f, fp.map { ", finger " + $0.description } ?? "")
        case let .chordMidClick(sp): String(format: "chordMidClick(second %.0f)", sp)
        case .externalMouseClick: "externalMouseClick"
        case let .pause(s): String(format: "pause(%.2f)", s)
        }
    }

    /// What this gesture must produce when performed from rest at
    /// threshold `threshold`.
    func expectation(threshold: Double) -> Expectation {
        switch self {
        case let .click(p): p.pressCount(threshold: threshold) == 0 ? .noClicks : .clicks(p.pressCount(threshold: threshold))
        case let .multiClick(n, _, p): p.pressCount(threshold: threshold) == 0 ? .noClicks : .clicks(n * p.pressCount(threshold: threshold))
        case let .point(_, _, _, pressure): pressure < threshold ? .noClicks : .anything
        case let .drag(p, dx, dy, frames, dip):
            Self.dragExpectation(p, dx: dx, dy: dy, frames: frames, dipTo: dip, threshold: threshold)
        case .doubleClickDrag, .thumbHoldIndexDrag, .chordMidClick: .anything
        case let .scroll(_, _, _, _, heavy, _):
            // A finger loaded at/above the threshold while the hand
            // is still stationary is indistinguishable from a press
            // with resting fingers (it fires after the 3-frame
            // dwell, by design — see ScrollEdgeTests); and a
            // sustained 2× load mid-scroll is the deliberate
            // hard-press override. Anything lighter must stay
            // silent.
            (heavy ?? 0) >= threshold ? .anything : .noClicks
        case let .pinch(_, _, p), let .rotate(_, _, p): p >= threshold * 2 ? .anything : .noClicks
        case .twoFingerClick: .noClicks
        case let .restingFingerClick(rest, p):
            if rest >= threshold * 0.5 { .anything }
            else if p.maxPressure < threshold { .noClicks }
            // With a second finger down, a light press must hold the
            // threshold for 3 frames (the scroll-spike dwell) unless
            // it is hard enough for macOS's own click (~90). A
            // shorter light press is dropped — a known limitation,
            // pinned in KnownLimitationTests.
            else if p.pressCount(threshold: threshold) == 1, p.longestRun(atOrAbove: threshold) >= 3 || p.maxPressure >= 90 { .clicks(1) }
            else { .anything }
        case let .palmRest(_, _, fp): fp.map { $0.pressCount(threshold: threshold) == 0 ? .noClicks : .clicks($0.pressCount(threshold: threshold)) } ?? .noClicks
        case .externalMouseClick, .pause: .noClicks
        }
    }
}

extension Gesture {
    /// A drag is one held press — unless the fingertip roll dips the
    /// pressure through a release line first: below 70% of the
    /// threshold before the cursor has travelled 5 px (the latch is
    /// not set yet), or to 10% after it. Then the press releases and
    /// re-presses (a known limitation, pinned in
    /// KnownLimitationTests), so anything may come out.
    /// Mirrors `Performer.drag` exactly: frame i of the slide sees
    /// the cursor moved by frames 1…i-1.
    static func dragExpectation(_ p: Press, dx: Double, dy: Double, frames: Int, dipTo: Double,
                                threshold: Double, padToScreen: Double = 1_000) -> Expectation {
        guard p.peak >= threshold else { return .noClicks }
        let n = max(1, frames)
        let stepX = dx * padToScreen / Double(n), stepY = dy * padToScreen / Double(n)
        for i in 0 ... n {
            let t = Double(i) / Double(n)
            let pressure = p.peak - (p.peak - dipTo) * sin(t * .pi)
            let moved = Double(max(0, i - 1))
            let latched = pow(stepX * moved, 2) + pow(stepY * moved, 2) > 25
            if pressure <= threshold * (latched ? 0.1 : 0.7) { return .anything }
        }
        let total = hypot(dx, dy) * padToScreen
        return total > 5 ? .oneDrag : .clicks(1)
    }
}

// MARK: - Performing gestures

extension Performer {
    /// Perform a gesture from rest; always ends with every finger
    /// lifted. Returns the output events it produced.
    @discardableResult
    func perform(_ gesture: Gesture) -> [OutputEvent] {
        let start = events.count
        note("▶ \(gesture)")
        switch gesture {
        case let .click(p):
            press(p)
        case let .multiClick(n, gap, p):
            for i in 0 ..< n {
                if i > 0 { wait(gap) }
                press(p)
            }
        case let .point(dx, dy, frames, pressure):
            slide(finger: 1, from: (0.5, 0.5), by: (dx, dy), frames: frames, pressure: { _ in pressure })
            lift()
        case let .drag(p, dx, dy, frames, dip):
            drag(p, dx: dx, dy: dy, frames: frames, dipTo: dip)
        case let .doubleClickDrag(gap, dx, frames):
            press(.quick())
            wait(gap)
            drag(.quick(), dx: dx, dy: 0, frames: frames, dipTo: 40)
        case let .thumbHoldIndexDrag(thumbPeak, dx, frames):
            thumbHoldIndexDrag(thumbPeak: thumbPeak, dx: dx, frames: frames)
        case let .scroll(n, dx, dy, frames, heavy, spike):
            scroll(fingers: n, dx: dx, dy: dy, frames: frames, heavy: heavy, landingSpike: spike)
        case let .pinch(spread, frames, pressure):
            twoFingerMotion(frames: frames, pressure: pressure) { t in
                let half = 0.08 + spread * t / 2
                return ((0.5 - half, 0.5), (0.5 + half, 0.5))
            }
        case let .rotate(degrees, frames, pressure):
            twoFingerMotion(frames: frames, pressure: pressure) { t in
                let a = degrees * .pi / 180 * t
                return ((0.5 - 0.1 * cos(a), 0.5 - 0.1 * sin(a)), (0.5 + 0.1 * cos(a), 0.5 + 0.1 * sin(a)))
            }
        case let .twoFingerClick(peak, offset):
            twoFingerClick(peak: peak, offsetFrames: offset)
        case let .restingFingerClick(rest, p):
            restingFingerClick(restPressure: rest, press: p)
        case let .palmRest(palmPressure, frames, fingerPress):
            palmRest(palmPressure: palmPressure, frames: frames, fingerPress: fingerPress)
        case let .chordMidClick(secondPeak):
            chordMidClick(secondPeak: secondPeak)
        case .externalMouseClick:
            let r = externalMouseClick()
            if r.down || r.up { note("‼︎ external mouse click was swallowed") }
        case let .pause(s):
            wait(s)
        }
        return Array(events[start...])
    }

    // MARK: Building blocks (usable directly from scenario tests)

    /// One finger presses following `p.curve`, then lifts.
    func press(_ p: Press, lift doLift: Bool = true) {
        var nativeFired = false
        for pressure in p.curve {
            let jab = p.nativeFirst && !nativeFired && pressure >= nativeThreshold
            if jab { nativeFired = true }
            frame([Contact(id: p.finger, x: p.x, y: p.y, pressure: pressure, major: p.major)], pointer: p.finger, nativeFirst: jab)
        }
        if doLift { lift() }
    }

    /// One finger slides from `from` by `by` over `frames`, pressure
    /// per progress 0…1; cursor follows. Does not lift.
    func slide(finger: Int32, from: (Double, Double), by: (Double, Double), frames: Int,
               pressure: (Double) -> Double, others: [Contact] = []) {
        for i in 0 ... frames {
            let t = Double(i) / Double(max(1, frames))
            let c = Contact(id: finger, x: from.0 + by.0 * t, y: from.1 + by.1 * t, pressure: pressure(t))
            frame(others + [c], pointer: finger)
        }
    }

    /// Press, hold, slide with a pressure dip, release, lift — the
    /// shape of a browser tab drag / window drag / file drag.
    func drag(_ p: Press, dx: Double, dy: Double, frames: Int, dipTo: Double) {
        let c = Contact(id: p.finger, x: p.x, y: p.y, pressure: p.landing, major: p.major)
        // Land and ramp up in place.
        for i in 0 ... max(1, p.rampFrames) {
            let pr = p.landing + (p.peak - p.landing) * Double(i) / Double(max(1, p.rampFrames))
            frame([Contact(id: c.id, x: c.x, y: c.y, pressure: pr, major: c.major)], pointer: c.id)
        }
        // Brief hold before moving (people pause before dragging).
        for _ in 0 ..< max(1, p.holdFrames / 2) {
            frame([Contact(id: c.id, x: c.x, y: c.y, pressure: p.peak, major: c.major)], pointer: c.id)
        }
        // Slide: pressure dips to `dipTo` at mid-travel, recovers.
        slide(finger: c.id, from: (c.x, c.y), by: (dx, dy), frames: frames) { t in
            p.peak - (p.peak - dipTo) * sin(t * .pi)
        }
        let end = (c.x + dx, c.y + dy)
        // Settle at the drop target, then release and lift.
        frame([Contact(id: c.id, x: end.0, y: end.1, pressure: p.peak, major: c.major)], pointer: c.id)
        for i in 1 ... max(1, p.releaseFrames) {
            let pr = p.peak + (p.landing - p.peak) * Double(i) / Double(max(1, p.releaseFrames))
            frame([Contact(id: c.id, x: end.0, y: end.1, pressure: pr, major: c.major)], pointer: c.id)
        }
        lift()
    }

    func thumbHoldIndexDrag(thumbPeak: Double, dx: Double, frames: Int) {
        let index = Contact(id: 1, x: 0.5, y: 0.45, pressure: 12)
        var thumb = Contact(id: 2, x: 0.45, y: 0.85, pressure: 6, major: 13)
        frame([index], pointer: 1)
        // Thumb lands and presses, index resting.
        for i in 0 ... 4 {
            thumb.pressure = 6 + (thumbPeak - 6) * Double(i) / 4
            frame([index, thumb], pointer: nil)
        }
        for _ in 0 ..< 3 { frame([index, thumb], pointer: nil) }
        // Index slides; cursor follows it; thumb keeps holding.
        slide(finger: 1, from: (index.x, index.y), by: (dx, 0), frames: frames, pressure: { _ in 12 }, others: [thumb])
        // Thumb lets go, then everything lifts.
        let moved = Contact(id: 1, x: index.x + dx, y: index.y, pressure: 12)
        for i in 1 ... 3 {
            thumb.pressure = thumbPeak + (6 - thumbPeak) * Double(i) / 3
            frame([moved, thumb], pointer: nil)
        }
        lift()
    }

    func scroll(fingers n: Int, dx: Double, dy: Double, frames: Int, heavy: Double?, landingSpike: Bool) {
        let spacing = 0.06
        enum Phase { case staggered, landed, moving }
        func contacts(_ t: Double, _ phase: Phase) -> [Contact] {
            (0 ..< n).map { k in
                var pressure = 18.0 + Double(k) * 2
                switch phase {
                // Fingers touch down light; load builds once all
                // are on the glass.
                case .staggered: pressure = 10
                // The landing spike: one finger's reading jumps as
                // the hand settles, then falls back.
                case .landed: if landingSpike, k == 0 { pressure = 65 }
                case .moving: if k == 0, let heavy { pressure = heavy }
                }
                return Contact(id: Int32(k + 1), x: 0.35 + Double(k) * spacing + dx * t, y: 0.45 + dy * t, pressure: pressure)
            }
        }
        // Fingers land a frame apart, as real fingers do.
        for k in 1 ..< n { frame(Array(contacts(0, .staggered).prefix(k)), pointer: nil) }
        frame(contacts(0, .landed), pointer: nil)
        for i in 1 ... frames { frame(contacts(Double(i) / Double(frames), .moving), pointer: nil) }
        // Fingers leave a frame apart (the last one may still glide).
        for k in stride(from: n - 1, through: 1, by: -1) {
            frame(Array(contacts(1, .moving).prefix(k)), pointer: nil)
        }
        lift()
    }

    func twoFingerMotion(frames: Int, pressure: Double, path: (Double) -> ((Double, Double), (Double, Double))) {
        for i in 0 ... frames {
            let (a, b) = path(Double(i) / Double(max(1, frames)))
            frame([Contact(id: 1, x: a.0, y: a.1, pressure: pressure), Contact(id: 2, x: b.0, y: b.1, pressure: pressure)], pointer: nil)
        }
        lift()
    }

    func twoFingerClick(peak: Double, offsetFrames: Int) {
        let steps = 4 + offsetFrames
        for i in 0 ... steps + 3 {
            let a = 8 + (peak - 8) * min(1, Double(i) / 4)
            let b = 8 + (peak - 8) * min(1, max(0, Double(i - offsetFrames)) / 4)
            // macOS answers a two-finger press with a secondary click:
            // no left-button events for the event tap.
            frame([Contact(id: 1, x: 0.45, y: 0.5, pressure: a), Contact(id: 2, x: 0.55, y: 0.5, pressure: b)],
                  pointer: nil, native: .none)
        }
        for i in 1 ... 3 {
            let p = peak + (8 - peak) * Double(i) / 3
            frame([Contact(id: 1, x: 0.45, y: 0.5, pressure: p), Contact(id: 2, x: 0.55, y: 0.5, pressure: p)],
                  pointer: nil, native: .none)
        }
        lift()
    }

    func restingFingerClick(restPressure: Double, press p: Press) {
        let rest = Contact(id: 9, x: 0.4, y: 0.85, pressure: restPressure, major: 13)
        frame([rest], pointer: nil)
        frame([rest], pointer: nil)
        var nativeFired = false
        for pressure in p.curve {
            let jab = p.nativeFirst && !nativeFired && pressure >= nativeThreshold
            if jab { nativeFired = true }
            frame([rest, Contact(id: p.finger, x: p.x, y: p.y, pressure: pressure, major: p.major)],
                  pointer: p.finger, nativeFirst: jab)
        }
        frame([rest], pointer: nil)
        lift()
    }

    func palmRest(palmPressure: Double, frames: Int, fingerPress: Press?) {
        let palm = Contact(id: 20, x: 0.15, y: 0.85, pressure: palmPressure, major: 28)
        for _ in 0 ..< frames { frame([palm], pointer: nil) }
        if let p = fingerPress {
            for pressure in p.curve {
                frame([palm, Contact(id: p.finger, x: p.x, y: p.y, pressure: pressure, major: p.major)], pointer: p.finger)
            }
            frame([palm], pointer: nil)
        }
        lift()
    }

    func chordMidClick(secondPeak: Double) {
        let first = Press.light()
        for pressure in first.curve.prefix(first.rampFrames + 3) {
            frame([Contact(id: 1, x: 0.45, y: 0.5, pressure: pressure)], pointer: 1)
        }
        for i in 0 ... 4 {
            let p2 = 8 + (secondPeak - 8) * Double(i) / 4
            frame([Contact(id: 1, x: 0.45, y: 0.5, pressure: first.peak), Contact(id: 2, x: 0.55, y: 0.5, pressure: p2)],
                  pointer: nil, native: .none)
        }
        lift()
    }
}

// MARK: - Checking a gesture's slice of output

/// Problems with `produced` (the output of one gesture performed
/// from rest) against `expectation`.
func expectationProblems(_ expectation: Expectation, produced: [OutputEvent]) -> [String] {
    let clicks = clickRecords(produced)
    switch expectation {
    case .anything:
        return []
    case .noClicks:
        return clicks.isEmpty ? [] : ["expected no clicks, got \(clicks)"]
    case let .clicks(n):
        if clicks.count != n { return ["expected \(n) click(s), got \(clicks.count): \(clicks)"] }
        let dragged = clicks.filter(\.isDrag)
        return dragged.isEmpty ? [] : ["expected stationary clicks, but some dragged: \(dragged)"]
    case .oneDrag:
        if clicks.count != 1 { return ["expected exactly one drag press, got \(clicks.count): \(clicks)"] }
        return clicks[0].isDrag ? [] : ["expected the press to drag, but it travelled \(Int(clicks[0].travel)) px: \(clicks[0])"]
    }
}
