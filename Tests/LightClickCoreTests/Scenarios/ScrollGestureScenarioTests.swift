import Foundation
import Testing
@testable import LightClickCore

// Realistic scroll / multi-finger gesture scenarios, end to end:
// scrolling, swiping, pinching and rotating must NEVER produce a
// left click, while a deliberate click right before or right after
// still clicks exactly once. Each scenario is a hand-shaped frame
// sequence (per-finger pressure curves, fingers landing and lifting
// at different times, curved and accelerating paths) played through
// the gesture kit's `Performer`, which also models macOS's own
// (force-sensor) click and checks the output invariants.
//
// Units, as on the device: pressure in app units (threshold 30–80,
// fingertip resting / scrolling ~10–30, macOS's own click ~90);
// positions in pad units 0…1 (0.02 ≈ 2 mm); 8 ms per frame.

// MARK: - Building blocks

/// How macOS's own click is modelled for a frame of a gesture take.
private enum GestureNative {
    /// Two or more fingers on the glass: a force press is macOS's
    /// secondary click / a gesture — no left-button event. A lone
    /// finger: the kit's native left-click model.
    case gesture
    /// The kit's model on every frame (resting thumb + pressing
    /// finger is a left click natively).
    case auto
    /// macOS posts no left-button events at all.
    case none
}

/// One multi-finger stroke (scroll, swipe): fingers land one after
/// another, settle, travel together along an eased path with natural
/// pressure variation, then leave one after another.
private struct Stroke {
    var fingers = 2
    var firstID: Int32 = 1
    var start: (x: Double, y: Double) = (0.40, 0.35)
    /// Offset between neighbouring fingers.
    var spacing: (dx: Double, dy: Double) = (0.07, 0.012)
    /// Total travel of the hand while moving, pad units.
    var travel: (dx: Double, dy: Double) = (0, 0.25)
    /// Moving frames.
    var frames = 20
    /// Progress 0…1 → path progress 0…1 (acceleration profile).
    var ease: (Double) -> Double = { $0 }
    /// Optional sideways bend of the path (pad units at mid-travel):
    /// perpendicular offset `bend * sin(π·progress)`.
    var bend = 0.0
    /// Frames between one finger landing and the next (0 = together).
    var landStagger = 1
    /// Frames between one finger leaving and the next (0 = together).
    var liftStagger = 1
    /// Stationary frames after the last finger lands, before moving.
    var settle = 0
    /// Base contact pressure of the first finger; each further
    /// finger adds 2.5.
    var base = 16.0
    /// ± natural pressure variation (deterministic sine).
    var wobble = 3.0
    var phase = 0.0
    /// Fingers touch down soft (60% of their load) on their first
    /// frame.
    var landSoft = true
    /// Landing spike of the LAST finger to land: its reading jumps
    /// to this for `spikeFrames` as the hand settles.
    var spike: Double?
    var spikeFrames = 2
    /// Load the first finger builds up to once the hand has
    /// travelled ~3 mm (fully reached at ~8 mm); moving frames only.
    var heavy: Double?
    var majors: [Double] = []

    var lastLand: Int { (fingers - 1) * landStagger }
    /// Index (in `take`) of the first moving frame.
    var moveStart: Int { lastLand + 1 + settle }
    /// Index of the first lift-phase frame.
    var liftStart: Int { moveStart + frames }

    private func progress(_ g: Int) -> Double {
        let i = g - moveStart + 1
        if i <= 0 { return 0 }
        return ease(min(1, Double(i) / Double(max(1, frames))))
    }

    func contact(_ k: Int, frame g: Int) -> Contact {
        let p = progress(g)
        let length = max(1e-9, hypot(travel.dx, travel.dy))
        // Perpendicular unit vector for the bend.
        let nx = -travel.dy / length, ny = travel.dx / length
        let off = bend * sin(.pi * p)
        let x = start.x + spacing.dx * Double(k) + travel.dx * p + nx * off
        let y = start.y + spacing.dy * Double(k) + travel.dy * p + ny * off
        var pressure = base + 2.5 * Double(k) + wobble * sin(0.7 * Double(g) + 1.3 * Double(k) + phase)
        let landedAt = k * landStagger
        if landSoft, g == landedAt { pressure *= 0.6 }
        if let spike, fingers > 1, k == fingers - 1, g >= landedAt, g - landedAt < spikeFrames { pressure = spike }
        if let heavy, k == 0, g >= moveStart, g < liftStart {
            let f = min(1, max(0, (length * p - 0.03) / 0.05))
            pressure += (heavy - pressure) * f
        }
        return Contact(id: firstID + Int32(k), x: x, y: y, pressure: pressure,
                       major: k < majors.count ? majors[k] : 10)
    }

    /// The frames, landing to the last finger leaving (the final
    /// empty frame is not included).
    var take: [[Contact]] {
        var out: [[Contact]] = []
        for g in 0 ..< liftStart {
            out.append((0 ..< fingers).filter { $0 * landStagger <= g }.map { contact($0, frame: g) })
        }
        // Leave last-landed first; the rest hold still where they
        // stopped.
        var g = liftStart
        if liftStagger > 0 {
            for remaining in stride(from: fingers - 1, through: 1, by: -1) {
                for _ in 0 ..< liftStagger {
                    out.append((0 ..< remaining).map { contact($0, frame: g) })
                    g += 1
                }
            }
        }
        return out
    }
}

private func easeOut(_ t: Double) -> Double { 1 - (1 - t) * (1 - t) }
private func easeInOut(_ t: Double) -> Double { t * t * (3 - 2 * t) }

/// Set one finger's pressure over a range of frames of a take.
private func load(_ take: inout [[Contact]], finger: Int32, frames: Range<Int>, _ pressure: (Int) -> Double) {
    for g in frames where g < take.count {
        for i in take[g].indices where take[g][i].id == finger {
            take[g][i].pressure = pressure(g - frames.lowerBound)
        }
    }
}

/// Add a contact (e.g. a resting thumb or a palm) to every frame.
private func adding(_ extra: Contact, to take: [[Contact]]) -> [[Contact]] {
    take.map { [extra] + $0 }
}

private extension Performer {
    /// Play a take; lifts every finger at the end unless told not to.
    func play(_ take: [[Contact]], pointer: Int32? = nil, native rule: GestureNative = .gesture, lift doLift: Bool = true) {
        for contacts in take {
            let native: NativeButton
            switch rule {
            case .auto: native = .auto
            case .none: native = .none
            case .gesture: native = contacts.filter { $0.major < 20 }.count >= 2 ? .none : .auto
            }
            frame(contacts, pointer: pointer, native: native)
        }
        if doLift { lift() }
    }

    func play(_ stroke: Stroke, native: GestureNative = .gesture, lift doLift: Bool = true) {
        play(stroke.take, native: native, lift: doLift)
    }

    /// A deliberate light click by a fresh finger, scaled to the
    /// threshold (peak 1.4×), at a fixed spot so the cursor is still.
    func deliberateClick(threshold: Double, finger: Int32 = 7, holdFrames: Int = 4, lift doLift: Bool = true) {
        press(Press(finger: finger, x: 0.55, y: 0.55, peak: threshold * 1.4, rampFrames: 3, holdFrames: holdFrames),
              lift: doLift)
    }
}

@MainActor
private func expectOutcome(_ p: Performer, clicks expected: Int, _ context: String = "",
                   sourceLocation: SourceLocation = #_sourceLocation) {
    let violations = p.violations()
    #expect(violations.isEmpty, "\(context) invariant violations\n\(p.report())", sourceLocation: sourceLocation)
    #expect(p.clicks.count == expected,
            "\(context): expected \(expected) click(s), got \(p.clicks.count): \(p.clicks)\n\(p.report())",
            sourceLocation: sourceLocation)
}

// MARK: - Reading, browsing, timelines

@MainActor
@Suite("Scroll scenarios: reading and browsing")
struct ScrollReadingScenarioTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]

    /// Reading a long article: forty two-finger strokes — slow
    /// creeps, ordinary scrolls and flicks, mostly down, some back
    /// up — with fingers landing and leaving untidily, landing
    /// spikes, and one finger leaning in up to just under twice the
    /// threshold once the hand is moving. Not one click.
    @Test(arguments: thresholds)
    func longArticleSession(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        var rng = SeededRNG(seed: UInt64(threshold) &* 7919)
        for n in 0 ..< 40 {
            var s = Stroke()
            let kind = Int.random(in: 0 ..< 3, using: &rng)
            let speed: Double
            switch kind {
            case 0: // slow read-along creep
                s.frames = Int.random(in: 20 ... 50, using: &rng)
                speed = Double.random(in: 0.002 ... 0.006, using: &rng)
            case 1: // ordinary scroll
                s.frames = Int.random(in: 10 ... 25, using: &rng)
                speed = Double.random(in: 0.008 ... 0.015, using: &rng)
                s.ease = easeInOut
            default: // flick
                s.frames = Int.random(in: 4 ... 8, using: &rng)
                speed = Double.random(in: 0.02 ... 0.03, using: &rng)
                s.ease = easeOut
            }
            let down = Double.random(in: 0 ... 1, using: &rng) < 0.75
            let dy = min(0.5, speed * Double(s.frames)) * (down ? 1 : -1)
            s.travel = (Double.random(in: -0.01 ... 0.01, using: &rng), dy)
            s.start = (Double.random(in: 0.3 ... 0.5, using: &rng), down ? 0.2 : 0.8)
            s.landStagger = Int.random(in: 0 ... 3, using: &rng)
            s.liftStagger = Int.random(in: 0 ... 2, using: &rng)
            s.settle = Int.random(in: 0 ... 2, using: &rng)
            s.base = Double.random(in: 13 ... 20, using: &rng)
            s.wobble = Double.random(in: 2 ... 4, using: &rng)
            s.phase = Double(n)
            if Double.random(in: 0 ... 1, using: &rng) < 0.3 {
                s.spike = threshold * Double.random(in: 1.1 ... 1.6, using: &rng)
                s.spikeFrames = Int.random(in: 1 ... 2, using: &rng)
            }
            if Double.random(in: 0 ... 1, using: &rng) < 0.4 {
                s.heavy = threshold * Double.random(in: 1.05 ... 1.9, using: &rng)
            }
            performer.note("stroke \(n): kind \(kind) frames \(s.frames) travel \(s.travel)")
            performer.play(s)
            performer.wait(Double.random(in: 0.08 ... 1.2, using: &rng))
        }
        expectOutcome(performer, clicks: 0, "long article at \(threshold)")
    }

    /// One finger leans in hard while scrolling — 1.9× the
    /// threshold, held for the whole stroke — still under the
    /// hard-press override: no click.
    @Test(arguments: thresholds)
    func heavyFingerJustUnderHardPress(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        for dir in [1.0, -1.0, 1.0] {
            var s = Stroke(travel: (0, 0.3 * dir), frames: 30, heavy: threshold * 1.9)
            s.start = (0.4, dir > 0 ? 0.2 : 0.8)
            performer.play(s)
            performer.wait(0.3)
        }
        expectOutcome(performer, clicks: 0)
        // The heavy load really was over the click threshold.
        #expect(performer.trace.contains { $0.contains(String(format: "p%.0f", threshold * 1.9)) })
    }

    /// The hand lands hard: the last finger's reading spikes to 1.5×
    /// the threshold for two frames while nothing is moving yet. The
    /// multi-finger dwell (3 frames) absorbs it.
    @Test(arguments: thresholds)
    func landingSpikeBeforeMovement(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        for stagger in 0 ... 2 {
            let s = Stroke(travel: (0, 0.2), frames: 15, landStagger: stagger, settle: 1,
                           spike: threshold * 1.5, spikeFrames: 2)
            performer.play(s)
            performer.wait(0.25)
        }
        expectOutcome(performer, clicks: 0)
    }

    /// Creeping along while reading: 0.0025 per frame (0.3 mm), far
    /// below the velocity trigger, so only the travel distance can
    /// classify it — and the leading finger loads past the threshold
    /// as the creep goes on.
    @Test(arguments: thresholds)
    func verySlowCreepingScroll(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let s = Stroke(travel: (0, 0.1), frames: 40, heavy: threshold * 1.5)
        var classifiedAt: Int?
        for (g, contacts) in s.take.enumerated() {
            performer.frame(contacts, pointer: nil, native: contacts.count >= 2 ? .none : .auto)
            if classifiedAt == nil, performer.engine.gestureMoved { classifiedAt = g }
        }
        performer.lift()
        expectOutcome(performer, clicks: 0)
        // Classified by travel (~2 mm = 8 frames at 0.25 mm/frame),
        // well before the heavy load (from ~3 mm) builds.
        #expect(classifiedAt.map { $0 - s.moveStart } ?? 99 <= 9, "classified at frame \(String(describing: classifiedAt))")
    }

    /// A fast flick: the very first moving frame is already 4 mm —
    /// the velocity trigger classifies it in one frame, and the
    /// leading finger's load spike on that same frame cannot click.
    @Test(arguments: thresholds)
    func fastFlick(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        var s = Stroke(travel: (0, 0.14), frames: 5, ease: easeOut, landStagger: 1)
        var take = s.take
        load(&take, finger: 1, frames: s.moveStart ..< s.moveStart + 3) { _ in threshold * 1.6 }
        for (g, contacts) in take.enumerated() {
            performer.frame(contacts, pointer: nil, native: contacts.count >= 2 ? .none : .auto)
            if g == s.moveStart {
                #expect(performer.engine.gestureMoved, "flick not classified on its first moving frame")
            }
        }
        performer.lift()
        // And an upward flick straight after, fingers landing together.
        s.travel = (0, -0.14)
        s.landStagger = 0
        s.start = (0.4, 0.7)
        performer.wait(0.1)
        performer.play(s)
        expectOutcome(performer, clicks: 0)
    }

    /// Scrolling up and down within one touch: the hand stops at
    /// each reversal for a few frames and presses a little harder to
    /// change direction — the stop is still the scroll.
    @Test(arguments: thresholds)
    func directionReversalsInOneTouch(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        var take: [[Contact]] = []
        var y = 0.4
        var g = 0
        func hand(_ p1: Double) -> [Contact] {
            g += 1
            return [Contact(id: 1, x: 0.40, y: y, pressure: p1),
                    Contact(id: 2, x: 0.47, y: y + 0.012, pressure: 19 + 2 * sin(Double(g)))]
        }
        take.append([Contact(id: 1, x: 0.40, y: y, pressure: 10)])
        take.append(hand(15))
        for (velocity, frames) in [(0.009, 12), (0.0, 4), (-0.012, 15), (0.0, 3), (0.007, 10), (0.0, 5), (-0.01, 8)] {
            for i in 0 ..< frames {
                y += velocity
                // Loading at the turn: over the threshold while still.
                let p1 = velocity == 0 ? threshold * (i == 0 ? 1.1 : 1.3) : 17 + 3 * sin(Double(g) * 0.6)
                take.append(hand(p1))
            }
        }
        performer.play(take)
        expectOutcome(performer, clicks: 0)
    }

    /// Horizontal scrolling through a spreadsheet / video timeline:
    /// left and right strokes, some with a bit of vertical wander.
    @Test(arguments: thresholds)
    func horizontalTimelineScroll(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        for (i, dx) in [0.25, -0.18, 0.3, -0.35, 0.12, -0.08].enumerated() {
            let s = Stroke(fingers: 2, start: (dx > 0 ? 0.25 : 0.75, 0.5), spacing: (0.012, 0.07),
                           travel: (dx, 0.02 * sin(Double(i))), frames: 12 + 3 * i, ease: easeInOut,
                           landStagger: i % 3, liftStagger: (i + 1) % 2, phase: Double(i),
                           heavy: i.isMultiple(of: 2) ? threshold * 1.4 : nil)
            performer.play(s)
            performer.wait(0.15)
        }
        expectOutcome(performer, clicks: 0)
    }

    /// Diagonal panning (a large image / a PDF zoomed in) and a
    /// curved swoop (the hand arcs as the wrist pivots).
    @Test(arguments: thresholds)
    func diagonalAndCurvedPaths(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.play(Stroke(start: (0.3, 0.3), travel: (0.25, 0.25), frames: 20, heavy: threshold * 1.3))
        performer.wait(0.2)
        performer.play(Stroke(start: (0.6, 0.7), travel: (-0.2, -0.3), frames: 18, ease: easeOut, landStagger: 2))
        performer.wait(0.2)
        performer.play(Stroke(start: (0.3, 0.3), travel: (0, 0.35), frames: 28, ease: easeInOut, bend: 0.08,
                              spike: threshold * 1.3, heavy: threshold * 1.2))
        performer.wait(0.2)
        performer.play(Stroke(start: (0.6, 0.2), travel: (-0.1, 0.4), frames: 25, bend: -0.12, liftStagger: 3))
        expectOutcome(performer, clicks: 0)
    }
}

// MARK: - System gestures

@MainActor
@Suite("Gesture scenarios: system swipes, pinches, taps")
struct SystemGestureScenarioTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]

    /// Two-finger swipe between pages in a browser: quick horizontal
    /// swipes back and forward.
    @Test(arguments: thresholds)
    func browserSwipeBackAndForward(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        for dx in [0.3, -0.3, 0.35] {
            performer.play(Stroke(start: (dx > 0 ? 0.25 : 0.7, 0.5), spacing: (0.015, 0.07), travel: (dx, 0.01),
                                  frames: 9, ease: easeOut, spike: threshold * 1.2, spikeFrames: 1))
            performer.wait(0.35)
        }
        expectOutcome(performer, clicks: 0)
    }

    /// Three fingers swipe up (Mission Control) and down (App
    /// Exposé), and sideways between full-screen apps.
    @Test(arguments: thresholds)
    func threeFingerSwipes(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let moves: [(Double, Double)] = [(0, -0.3), (0, 0.3), (0.35, 0), (-0.35, 0)]
        for (i, travel) in moves.enumerated() {
            performer.play(Stroke(fingers: 3, start: (0.35, travel.1 < 0 ? 0.75 : 0.25), spacing: (0.08, -0.015),
                                  travel: travel, frames: 12, ease: easeOut, landStagger: i % 2, base: 14,
                                  spike: threshold * 1.4, heavy: threshold * 1.3))
            performer.wait(0.4)
        }
        expectOutcome(performer, clicks: 0)
    }

    /// Four fingers swipe between Spaces, both ways.
    @Test(arguments: thresholds)
    func fourFingerSpacesSwipe(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        for dx in [-0.35, 0.35, -0.3] {
            performer.play(Stroke(fingers: 4, start: (dx < 0 ? 0.45 : 0.15, 0.4), spacing: (0.065, -0.01),
                                  travel: (dx, 0.02), frames: 10, ease: easeOut, landStagger: 1, liftStagger: 1,
                                  base: 13, spike: threshold * 1.5))
            performer.wait(0.5)
        }
        expectOutcome(performer, clicks: 0)
    }

    /// Thumb and three fingers pinch together (Launchpad), then
    /// spread (show Desktop).
    @Test(arguments: thresholds)
    func fourFingerPinchAndSpread(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let spread: [(x: Double, y: Double)] = [(0.35, 0.8), (0.42, 0.3), (0.52, 0.27), (0.62, 0.3)]
        let centre = (x: 0.48, y: 0.45)
        for inward in [true, false] {
            var take: [[Contact]] = []
            let frames = 14
            // Fingers land over three frames.
            for g in 0 ..< 3 + frames {
                let t = max(0, Double(g - 2)) / Double(frames)
                let amount = inward ? 0.6 * t : 0.6 * (1 - t)
                let present = min(4, g + 2)
                take.append((0 ..< present).map { k in
                    let p = spread[k]
                    return Contact(id: Int32(k + 1), x: p.x + (centre.x - p.x) * amount, y: p.y + (centre.y - p.y) * amount,
                                   pressure: (k == 0 ? 20 : 15) + 4 * t + 2 * sin(Double(g + k)), major: k == 0 ? 13 : 10)
                })
            }
            performer.play(take)
            performer.wait(0.4)
        }
        expectOutcome(performer, clicks: 0)
    }

    /// Pinch to zoom in and out on a map: the fingers press harder as
    /// they spread (up to 1.5× the threshold), lighter as they close.
    @Test(arguments: thresholds)
    func pinchZoomInMaps(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        for (outward, frames) in [(true, 18), (false, 14), (true, 8)] {
            var take: [[Contact]] = [[Contact(id: 1, x: 0.46, y: 0.52, pressure: 10)]]
            for i in 0 ... frames {
                let t = Double(i) / Double(frames)
                let half = outward ? 0.04 + 0.14 * easeInOut(t) : 0.18 - 0.14 * easeInOut(t)
                // Load builds once the fingers are under way.
                let load = outward ? 16 + (threshold * 1.5 - 16) * t : 16 + (threshold * 1.2 - 16) * sin(.pi * t)
                take.append([Contact(id: 1, x: 0.5 - half, y: 0.52 + half * 0.3, pressure: load),
                             Contact(id: 2, x: 0.5 + half, y: 0.48 - half * 0.3, pressure: load * 0.85)])
            }
            performer.play(take)
            performer.wait(0.3)
        }
        expectOutcome(performer, clicks: 0)
    }

    /// Rotate a photo 90° one way and back, thumb pivoting heavier
    /// than the index finger.
    @Test(arguments: thresholds)
    func rotatePhoto(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        for degrees in [90.0, -90.0, 45.0] {
            var take: [[Contact]] = []
            let frames = 20
            for i in 0 ... frames {
                let t = Double(i) / Double(frames)
                let a = degrees * .pi / 180 * easeInOut(t)
                // The thumb bears down as the twist gets going.
                let thumb = 16 + (threshold * 1.3 - 16) * min(1, max(0, (t - 0.3) / 0.2))
                take.append([
                    Contact(id: 1, x: 0.5 - 0.09 * cos(a), y: 0.5 - 0.09 * sin(a), pressure: thumb, major: 13),
                    Contact(id: 2, x: 0.5 + 0.09 * cos(a), y: 0.5 + 0.09 * sin(a), pressure: 18 + 3 * sin(Double(i))),
                ])
            }
            performer.play(take)
            performer.wait(0.3)
        }
        expectOutcome(performer, clicks: 0)
    }

    /// Smart zoom: a two-finger double-tap. Each tap is light and
    /// brief, but the second finger's reading pokes over the
    /// threshold for a frame.
    @Test(arguments: thresholds)
    func twoFingerDoubleTapSmartZoom(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        for _ in 0 ..< 3 {
            for _ in 0 ..< 2 {
                performer.play([
                    [Contact(id: 1, x: 0.45, y: 0.5, pressure: 12), Contact(id: 2, x: 0.53, y: 0.5, pressure: 14)],
                    [Contact(id: 1, x: 0.45, y: 0.5, pressure: 22), Contact(id: 2, x: 0.53, y: 0.5, pressure: threshold * 1.05)],
                    [Contact(id: 1, x: 0.45, y: 0.5, pressure: 20), Contact(id: 2, x: 0.53, y: 0.5, pressure: 24)],
                    [Contact(id: 1, x: 0.45, y: 0.5, pressure: 10)],
                ])
                performer.wait(0.12)
            }
            performer.wait(0.6)
        }
        expectOutcome(performer, clicks: 0)
    }

    /// Notification Center: two fingers swipe in from the right edge.
    /// The second finger appears a frame later (it was off the pad)
    /// already loaded.
    @Test(arguments: thresholds)
    func notificationCenterEdgeSwipe(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.play(Stroke(start: (0.93, 0.45), spacing: (0.05, 0.06), travel: (-0.3, 0.0), frames: 10,
                              ease: easeOut, landStagger: 1, landSoft: false, spike: threshold * 1.2))
        performer.wait(0.5)
        // And swiped back out.
        performer.play(Stroke(start: (0.6, 0.45), spacing: (0.05, 0.06), travel: (0.35, 0.0), frames: 8, ease: easeOut))
        expectOutcome(performer, clicks: 0)
    }

    /// Look up: a three-finger tap. Fingers land a frame apart and
    /// tap briefly; the middle one taps a little harder.
    @Test(arguments: thresholds)
    func threeFingerTapLookUp(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        for stagger in [0, 1] {
            var take: [[Contact]] = []
            for g in 0 ..< 4 + 2 * stagger {
                let peakPhase = g >= 1 + stagger && g <= 2 + stagger
                take.append((0 ..< 3).filter { $0 * stagger <= g }.map { k in
                    Contact(id: Int32(k + 1), x: 0.4 + 0.07 * Double(k), y: 0.5 - 0.01 * Double(k),
                            pressure: peakPhase ? (k == 1 ? threshold * 1.1 : 24) : 12)
                })
            }
            performer.play(take)
            performer.wait(0.5)
        }
        expectOutcome(performer, clicks: 0)
    }
}

// MARK: - Untidy fingers

@MainActor
@Suite("Scroll scenarios: fingers landing, lifting, re-landing")
struct ScrollUntidyFingerScenarioTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]
    nonisolated static let staggers = [1, 2, 3, 4, 5]

    /// One finger leaves mid-scroll while the other keeps gliding;
    /// its load jumps as it takes the whole hand's weight (to 1.2×
    /// the threshold, staying under macOS's own click), then it
    /// stops and lifts. Still the scroll: no click.
    @Test(arguments: thresholds)
    func oneFingerLiftsMidScrollOtherKeepsGliding(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let loaded = min(threshold * 1.2, 85)
        var take: [[Contact]] = [[Contact(id: 1, x: 0.4, y: 0.3, pressure: 10)]]
        var y = 0.3
        for i in 0 ..< 12 {
            y += 0.01
            take.append([Contact(id: 1, x: 0.4, y: y, pressure: 17 + 2 * sin(Double(i))),
                         Contact(id: 2, x: 0.47, y: y + 0.01, pressure: 19)])
        }
        for i in 0 ..< 14 {
            y += 0.01 * Double(14 - i) / 14 // decelerating glide
            take.append([Contact(id: 1, x: 0.4, y: y, pressure: i < 5 ? loaded : 18)])
        }
        for _ in 0 ..< 4 { take.append([Contact(id: 1, x: 0.4, y: y, pressure: loaded)]) }
        performer.play(take)
        expectOutcome(performer, clicks: 0)
    }

    /// Fingers landing 1–5 frames apart; the first finger starts to
    /// move before the second arrives, and the second arrives with a
    /// two-frame spike.
    @Test(arguments: staggers)
    func staggeredLanding(stagger: Int) {
        for threshold in [30.0, 50, 80] {
            let performer = Performer(rig: TestRig(threshold: threshold))
            var take: [[Contact]] = []
            var y = 0.3
            for _ in 0 ..< stagger {
                y += 0.004
                take.append([Contact(id: 1, x: 0.4, y: y, pressure: 14)])
            }
            for i in 0 ..< 20 {
                y += 0.009
                take.append([Contact(id: 1, x: 0.4, y: y, pressure: 18),
                             Contact(id: 2, x: 0.47, y: y + 0.01, pressure: i < 2 ? threshold * 1.4 : 20)])
            }
            performer.play(take)
            expectOutcome(performer, clicks: 0, "stagger \(stagger) threshold \(threshold)")
        }
    }

    /// A third finger lands late with a spike, turning a scroll into
    /// a three-finger swipe.
    @Test(arguments: thresholds)
    func lateThirdFingerSpike(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let s = Stroke(travel: (0.3, 0), frames: 20)
        var take = s.take
        for g in s.moveStart + 5 ..< s.liftStart {
            let lead = take[g][0]
            let spike = g - (s.moveStart + 5) < 2
            take[g].append(Contact(id: 3, x: lead.x + 0.14, y: lead.y + 0.02, pressure: spike ? threshold * 1.8 : 20))
        }
        performer.play(take)
        expectOutcome(performer, clicks: 0)
    }

    /// Mid-scroll one finger lifts and comes back down a few frames
    /// later (a new contact id) with a landing spike.
    @Test(arguments: thresholds)
    func fingerRelandsMidScroll(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        var take: [[Contact]] = [[Contact(id: 1, x: 0.4, y: 0.2, pressure: 10)]]
        var y = 0.2
        for i in 0 ..< 36 {
            y += 0.011
            var hand = [Contact(id: 1, x: 0.4, y: y, pressure: 18 + 3 * sin(Double(i)))]
            switch i {
            case ..<10: hand.append(Contact(id: 2, x: 0.47, y: y + 0.01, pressure: 20))
            case 10 ..< 14: break // finger 2 is off the glass
            case 14 ..< 16: hand.append(Contact(id: 3, x: 0.47, y: y + 0.01, pressure: threshold * 1.3))
            default: hand.append(Contact(id: 3, x: 0.47, y: y + 0.01, pressure: 21))
            }
            take.append(hand)
        }
        performer.play(take)
        expectOutcome(performer, clicks: 0)
    }

    /// As the hand comes off the pad after a scroll, the last finger
    /// briefly carries the load — over the threshold, still, for
    /// several frames — before it too lifts.
    @Test(arguments: thresholds)
    func lastFingerLoadsAsHandLeaves(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        var take = Stroke(travel: (0, 0.2), frames: 15, liftStagger: 0).take
        let end = take.last!
        take.append([end[0]])
        for i in 0 ..< 6 {
            take.append([Contact(id: 1, x: end[0].x, y: end[0].y, pressure: min(85, threshold * (1.1 + 0.05 * Double(i))))])
        }
        performer.play(take)
        expectOutcome(performer, clicks: 0)
    }
}

// MARK: - Momentum

@MainActor
@Suite("Scroll scenarios: stopping momentum")
struct ScrollMomentumScenarioTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]

    /// Flick, then a single light finger touch to stop the momentum
    /// scroll: no click.
    @Test(arguments: thresholds)
    func flickThenOneFingerStopsMomentum(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        for gap in [0.05, 0.12, 0.3] {
            performer.play(Stroke(travel: (0, 0.18), frames: 6, ease: easeOut))
            performer.wait(gap)
            performer.play([12.0, 20, 22, 21, 16, 9].map { [Contact(id: 5, x: 0.45, y: 0.5, pressure: $0)] })
            performer.wait(0.4)
        }
        expectOutcome(performer, clicks: 0)
    }

    /// Flick, then two fingers come down and hold still to catch the
    /// momentum, then carry on scrolling.
    @Test(arguments: thresholds)
    func flickThenTwoFingersCatchAndContinue(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.play(Stroke(travel: (0, 0.2), frames: 6, ease: easeOut))
        performer.wait(0.08)
        var s = Stroke(start: (0.4, 0.4), travel: (0, 0.15), frames: 15, landStagger: 1, settle: 25)
        s.wobble = 4
        performer.play(s)
        expectOutcome(performer, clicks: 0)
    }

    /// Flick through a list, then a deliberate click to stop it and
    /// open the item under the cursor: exactly one click.
    @Test(arguments: thresholds)
    func flickThenDeliberateClick(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.play(Stroke(travel: (0, -0.2), frames: 5, ease: easeOut, spike: threshold * 1.2))
        performer.wait(0.06)
        performer.deliberateClick(threshold: threshold)
        expectOutcome(performer, clicks: 1)
        #expect(performer.clicks.first?.clickState == 1)
    }
}

// MARK: - Deliberate clicks around scrolls

@MainActor
@Suite("Scroll scenarios: deliberate clicks before and after")
struct ScrollAdjacentClickScenarioTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]

    /// Scroll to a link, lift, and click it on the very next frame.
    @Test(arguments: thresholds)
    func clickImmediatelyAfterScrollLift(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.play(Stroke(travel: (0, 0.25), frames: 20, heavy: threshold * 1.5))
        performer.deliberateClick(threshold: threshold)
        expectOutcome(performer, clicks: 1)
        #expect(performer.clicks.first?.clickState == 1)
        #expect(performer.clicks.first?.isDrag == false)
    }

    /// Scroll, lift, and click 50 ms later, with a resting finger
    /// arriving alongside the clicking one.
    @Test(arguments: thresholds)
    func clickFiftyMillisecondsAfterScroll(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.play(Stroke(travel: (0, -0.2), frames: 12, ease: easeOut))
        performer.wait(0.05)
        performer.deliberateClick(threshold: threshold)
        performer.wait(0.05)
        performer.restingFingerClick(restPressure: 14, press: Press(x: 0.55, y: 0.55, peak: threshold * 1.4, holdFrames: 4))
        expectOutcome(performer, clicks: 2)
    }

    /// Click, then scroll 40 ms later: the click is exactly one.
    @Test(arguments: thresholds)
    func clickRightBeforeScroll(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.deliberateClick(threshold: threshold)
        performer.wait(0.04)
        performer.play(Stroke(travel: (0, 0.25), frames: 18, spike: threshold * 1.3, heavy: threshold * 1.5))
        expectOutcome(performer, clicks: 1)
    }

    /// Click into a page and start scrolling without lifting the
    /// clicking finger: it eases off, a second finger lands, and the
    /// two scroll. One click, released before the scroll starts.
    @Test(arguments: thresholds)
    func clickingFingerStaysDownAndScrolls(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        var take: [[Contact]] = []
        for p in [10, threshold * 0.6, threshold * 1.2, threshold * 1.4, threshold * 1.4, threshold * 0.9, 25, 18] {
            take.append([Contact(id: 1, x: 0.45, y: 0.4, pressure: p)])
        }
        var y = 0.4
        for i in 0 ..< 20 {
            y += 0.01
            take.append([Contact(id: 1, x: 0.45, y: y, pressure: 18 + 2 * sin(Double(i))),
                         Contact(id: 2, x: 0.52, y: y + 0.01, pressure: i < 2 ? threshold * 1.3 : 20)])
        }
        performer.play(take, native: .gesture)
        expectOutcome(performer, clicks: 1)
        // Released (at 70% of the threshold) before the second finger
        // lands on frame 8.
        let up = performer.clicks.first?.upAt ?? .infinity
        #expect(up <= 1_000 + 7 * 0.008 + 1e-9, "click held into the scroll\n\(performer.report())")
    }

    /// Double-click a word, then scroll briefly, then click the same
    /// spot again within the double-click interval: the chain state
    /// follows the system's rule (time + distance), and the scroll
    /// produced nothing.
    @Test
    func doubleClickThenShortScrollThenClick() {
        let threshold = 50.0
        let performer = Performer(rig: TestRig(threshold: threshold))
        let quick = Press(x: 0.55, y: 0.55, peak: 68, rampFrames: 2, holdFrames: 2, releaseFrames: 2)
        performer.press(quick)
        performer.wait(0.08)
        performer.press(quick)
        performer.wait(0.03)
        performer.play(Stroke(travel: (0, 0.06), frames: 8, landStagger: 0, liftStagger: 0))
        performer.wait(0.03)
        performer.press(quick)
        expectOutcome(performer, clicks: 3)
        #expect(performer.clicks.map(\.clickState) == [1, 2, 3], "\(performer.report())")
    }

    /// Double-click, then a long scroll (past the interval), then a
    /// click: the chain restarts at 1.
    @Test
    func doubleClickThenLongScrollThenClick() {
        let performer = Performer(rig: TestRig(threshold: 50))
        let quick = Press(x: 0.55, y: 0.55, peak: 68, rampFrames: 2, holdFrames: 2, releaseFrames: 2)
        performer.press(quick)
        performer.wait(0.1)
        performer.press(quick)
        performer.play(Stroke(travel: (0, 0.3), frames: 60, heavy: 90))
        performer.press(quick)
        expectOutcome(performer, clicks: 3)
        #expect(performer.clicks.map(\.clickState) == [1, 2, 1], "\(performer.report())")
    }
}

// MARK: - Hard press mid-scroll (native parity)

@MainActor
@Suite("Scroll scenarios: hard press mid-scroll")
struct ScrollHardPressScenarioTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]

    /// Mid-scroll the user presses down hard (2.2× the threshold for
    /// 4 frames) on a link: one click (as a real Mac's force click
    /// would), released as the press eases, and the rest of the
    /// scroll stays silent.
    @Test(arguments: thresholds)
    func deliberateHardPressMidScroll(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let s = Stroke(travel: (0, 0.3), frames: 30, base: 15, wobble: 2)
        var take = s.take
        let at = s.moveStart + 12
        let curve = [threshold * 1.3, threshold * 2.2, threshold * 2.25, threshold * 2.2, threshold * 2.1, threshold, 15]
        load(&take, finger: 1, frames: at ..< at + curve.count) { curve[$0] }
        performer.play(take)
        expectOutcome(performer, clicks: 1)
        if let click = performer.clicks.first {
            let pressStart = 1_000 + Double(at) * 0.008
            #expect(click.downAt >= pressStart + 0.008 - 1e-9 && click.downAt <= pressStart + 0.024 + 1e-9,
                    "hard press fired at the wrong frame\n\(performer.report())")
            #expect(click.upAt != nil && click.upAt! <= pressStart + 0.056 + 1e-9, "not released as the press eased")
        }
    }

    /// Just under the override: 1.95× the threshold for ten frames,
    /// and separately 2.2× for a single frame. Neither clicks.
    @Test(arguments: thresholds)
    func justUnderHardPressMidScroll(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let s = Stroke(travel: (0, 0.35), frames: 40)
        var take = s.take
        load(&take, finger: 1, frames: s.moveStart + 8 ..< s.moveStart + 18) { _ in threshold * 1.95 }
        load(&take, finger: 1, frames: s.moveStart + 25 ..< s.moveStart + 26) { _ in threshold * 2.2 }
        load(&take, finger: 2, frames: s.moveStart + 30 ..< s.moveStart + 31) { _ in threshold * 2.4 }
        performer.play(take)
        expectOutcome(performer, clicks: 0)
    }

    /// The scroll fingers come down together and firmly (both at
    /// once, each at over half the threshold). A hard press mid-scroll
    /// must still click, exactly as it does when they land a frame
    /// apart.
    @Test(arguments: [30.0, 40.0])
    func hardPressMidScrollAfterFirmSimultaneousLanding(threshold: Double) {
        var outcomes: [Int] = []
        for stagger in [1, 0] {
            let performer = Performer(rig: TestRig(threshold: threshold))
            let s = Stroke(travel: (0, 0.3), frames: 30, landStagger: stagger, base: 21, wobble: 1, landSoft: false)
            var take = s.take
            let at = s.moveStart + 12
            load(&take, finger: 1, frames: at ..< at + 5) { [threshold * 1.4, threshold * 2.3, threshold * 2.3, threshold * 2.3, 15][$0] }
            performer.play(take)
            #expect(performer.violations().isEmpty, "\(performer.report())")
            outcomes.append(performer.clicks.count)
        }
        #expect(outcomes[0] == 1, "staggered landing: hard press should click")
        withKnownIssue("BUG: two fingers landing together at ≥ half the threshold lock the engine, killing the hard-press override for the whole scroll") {
            #expect(outcomes[1] == 1, "simultaneous landing: hard press should click like the staggered one (got \(outcomes[1]))")
        }
    }

    /// After a scroll, one finger stays on the glass, stops, and
    /// force-presses past macOS's own click (95, native fires at 90).
    /// A real Mac clicks here; the app must either answer with its
    /// own click or let macOS's through — never eat it.
    @Test(arguments: thresholds)
    func forcePressByLoneFingerAfterScroll(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        var take = Stroke(travel: (0, 0.2), frames: 15, liftStagger: 0).take
        let end = take.last![0]
        for _ in 0 ..< 3 { take.append([end]) } // finger 2 lifted; finger 1 stops
        for p in [40.0, 70, 95, 95, 95, 95, 60, 30, 15] {
            take.append([Contact(id: 1, x: end.x, y: end.y, pressure: p)])
        }
        performer.play(take)
        let nativeOutranThreshold = threshold * 2 > 95
        withKnownIssue("BUG: a native force click after a scroll (gesture flag still set) is swallowed unanswered, and its mouse-up leaks unpaired",
                       isIntermittent: false) {
            expectOutcome(performer, clicks: 1, "threshold \(threshold)")
        } when: {
            nativeOutranThreshold
        }
    }
}

// MARK: - Palm and thumb

@MainActor
@Suite("Scroll scenarios: palm and thumb resting")
struct ScrollRestingHandScenarioTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]

    static func palm(_ pressure: Double = 85) -> Contact {
        Contact(id: 20, x: 0.12, y: 0.88, pressure: pressure, major: 28)
    }

    static func thumb(_ pressure: Double = 14) -> Contact {
        Contact(id: 9, x: 0.32, y: 0.9, pressure: pressure, major: 13)
    }

    /// The heel of the hand rests on the pad (typing posture) while
    /// two fingers scroll: no click, and the palm never gets
    /// mistaken for a finger.
    @Test(arguments: thresholds)
    func palmRestingDuringScroll(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.play([[Self.palm()], [Self.palm()]], lift: false)
        for dy in [0.25, -0.2, 0.3] {
            let s = Stroke(start: (0.5, dy > 0 ? 0.2 : 0.6), travel: (0, dy), frames: 18, spike: threshold * 1.3,
                           heavy: threshold * 1.6)
            performer.play(adding(Self.palm(), to: s.take), lift: false)
            performer.play([[Self.palm()], [Self.palm()]], lift: false)
        }
        performer.lift()
        expectOutcome(performer, clicks: 0)
    }

    /// Palm resting, scroll, then (palm still down) click a link:
    /// exactly one click — the palm is not a finger, so the scroll's
    /// gesture flag ended when the scrolling fingers left.
    @Test(arguments: thresholds)
    func palmRestingScrollThenClick(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.play([[Self.palm()], [Self.palm()]], lift: false)
        performer.play(adding(Self.palm(), to: Stroke(start: (0.5, 0.2), travel: (0, 0.25), frames: 18).take), lift: false)
        performer.play([[Self.palm()], [Self.palm()], [Self.palm()]], lift: false)
        let p = Press(finger: 7, x: 0.55, y: 0.5, peak: threshold * 1.4, holdFrames: 4)
        performer.play(p.curve.map { [Self.palm(), Contact(id: 7, x: 0.55, y: 0.5, pressure: $0)] }, native: .auto, lift: false)
        performer.play([[Self.palm()]], lift: true)
        expectOutcome(performer, clicks: 1)
    }

    /// A thumb rests at the bottom of the pad (its load drifting up
    /// past the threshold mid-scroll) while two fingers scroll.
    @Test(arguments: thresholds)
    func scrollWithThumbResting(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.play([[Self.thumb(9)], [Self.thumb()], [Self.thumb()]], native: .auto, lift: false)
        let s = Stroke(start: (0.45, 0.2), travel: (0, 0.3), frames: 24)
        var take = adding(Self.thumb(), to: s.take)
        load(&take, finger: 9, frames: s.moveStart + 6 ..< s.liftStart) { _ in threshold * 1.3 }
        performer.play(take, lift: false)
        performer.play([[Self.thumb()], [Self.thumb()]], native: .auto)
        expectOutcome(performer, clicks: 0)
    }

    /// Scroll with the thumb resting, lift the two scrolling fingers,
    /// and click a link with the index finger — the thumb still
    /// resting, as it was before the scroll. A real Mac ignores a
    /// resting thumb; the click must land.
    @Test(arguments: thresholds)
    func clickAfterScrollWithThumbStillResting(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.play([[Self.thumb(9)], [Self.thumb()], [Self.thumb()]], native: .auto, lift: false)
        performer.play(adding(Self.thumb(), to: Stroke(start: (0.45, 0.2), travel: (0, 0.3), frames: 24).take), lift: false)
        // Scrolling fingers gone; thumb stays for 80 ms.
        performer.play(Array(repeating: [Self.thumb()], count: 10), native: .auto, lift: false)
        let p = Press(finger: 7, x: 0.55, y: 0.5, peak: threshold * 1.4, holdFrames: 5)
        performer.play(p.curve.map { [Self.thumb(), Contact(id: 7, x: 0.55, y: 0.5, pressure: $0)] }, native: .auto, lift: false)
        performer.play([[Self.thumb()]], native: .auto)
        withKnownIssue("BUG: a stationary resting thumb keeps the scroll's gesture flag alive, so light clicks after the scroll are dropped until the thumb lifts") {
            expectOutcome(performer, clicks: 1, "threshold \(threshold)")
        }
    }

    /// Thumb resting, the index finger moves the pointer to a button
    /// and clicks it lightly. Pointing is not scrolling: the click
    /// must land.
    @Test(arguments: thresholds)
    func pointWithThumbRestingThenClick(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        performer.play([[Self.thumb(9)], [Self.thumb()], [Self.thumb()]], native: .auto, lift: false)
        var take: [[Contact]] = []
        for i in 0 ... 20 {
            let t = easeInOut(Double(i) / 20)
            take.append([Self.thumb(), Contact(id: 7, x: 0.4 + 0.15 * t, y: 0.4 + 0.1 * t, pressure: i == 0 ? 8 : 14)])
        }
        performer.play(take, pointer: 7, native: .auto, lift: false)
        let p = Press(finger: 7, x: 0.55, y: 0.5, landing: 14, peak: threshold * 1.4, holdFrames: 5)
        performer.play(p.curve.map { [Self.thumb(), Contact(id: 7, x: 0.55, y: 0.5, pressure: $0)] }, pointer: 7,
                       native: .auto, lift: false)
        performer.play([[Self.thumb()]], native: .auto)
        withKnownIssue("BUG: pointing with one finger while a thumb rests trips the scroll gate, so the following light click is dropped") {
            expectOutcome(performer, clicks: 1, "threshold \(threshold)")
        }
    }
}

// MARK: - Scrolling while a click is held

@MainActor
@Suite("Scroll scenarios: scrolling while a click is held")
struct ScrollWhileHeldScenarioTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]

    static func holdingThumb(_ pressure: Double) -> Contact {
        Contact(id: 1, x: 0.4, y: 0.85, pressure: pressure, major: 12)
    }

    /// The thumb presses and holds (a scrollbar arrow, a selection
    /// anchor); the index finger lands and glides. On a Mac that is a
    /// drag: the button stays held and the cursor follows the
    /// gliding finger. One press, held until the thumb eases off.
    @Test(arguments: thresholds)
    func holdClickWhileSecondFingerGlides(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hold = threshold * 1.4
        performer.play([10, threshold * 0.7, hold, hold].map { [Self.holdingThumb($0)] }, pointer: nil, native: .auto, lift: false)
        var take: [[Contact]] = []
        for i in 0 ... 25 {
            take.append([Self.holdingThumb(hold + 3 * sin(Double(i))),
                         Contact(id: 2, x: 0.45, y: 0.4 - 0.008 * Double(i), pressure: i == 0 ? 9 : 16)])
        }
        performer.play(take, pointer: 2, native: .auto, lift: false)
        let easeStart = performer.rig.clock.time
        performer.play([threshold * 0.8, threshold * 0.5, 10].map {
            [Self.holdingThumb($0), Contact(id: 2, x: 0.45, y: 0.2, pressure: 16)]
        }, pointer: 2, native: .auto)
        expectOutcome(performer, clicks: 1)
        if let click = performer.clicks.first {
            #expect(click.isDrag, "the held press should have dragged with the gliding finger: \(click)")
            #expect((click.upAt ?? 0) >= easeStart, "the hold ended before the thumb let go\n\(performer.report())")
        }
    }

    /// The thumb holds a click while two other fingers scroll.
    /// The scroll must neither release the held click early nor add
    /// a click of its own.
    @Test(arguments: thresholds)
    func holdClickWhileTwoFingersScroll(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hold = threshold * 1.4
        performer.play([10, threshold * 0.7, hold, hold].map { [Self.holdingThumb($0)] }, native: .auto, lift: false)
        let s = Stroke(firstID: 2, start: (0.45, 0.2), travel: (0, 0.3), frames: 20)
        performer.play(adding(Self.holdingThumb(hold), to: s.take), native: .auto, lift: false)
        let easeStart = performer.rig.clock.time
        performer.play([threshold * 0.8, threshold * 0.5, 10].map { [Self.holdingThumb($0)] }, native: .auto)
        expectOutcome(performer, clicks: 1)
        #expect((performer.clicks.first?.upAt ?? 0) >= easeStart, "the scroll released the held click\n\(performer.report())")
    }

    /// As above, but the first scrolling finger lands with a
    /// one-frame spike over the threshold (as scroll fingers do,
    /// 300 ms into the hold). That is a hand settling, not a
    /// two-finger click: the hold must survive it.
    @Test(arguments: thresholds)
    func heldClickSurvivesScrollFingerLandingSpike(threshold: Double) {
        let performer = Performer(rig: TestRig(threshold: threshold))
        let hold = threshold * 1.4
        performer.play([10, threshold * 0.7] + Array(repeating: hold, count: 36), native: .auto, lift: false)
        let s = Stroke(firstID: 2, start: (0.45, 0.2), travel: (0, 0.3), frames: 20, spike: threshold * 1.2, spikeFrames: 1)
        performer.play(adding(Self.holdingThumb(hold), to: s.take), native: .auto, lift: false)
        let easeStart = performer.rig.clock.time
        performer.play([threshold * 0.8, threshold * 0.5, 10].map { [Self.holdingThumb($0)] }, native: .auto)
        // No extra click either way.
        #expect(performer.clicks.count == 1, "\(performer.report())")
        withKnownIssue("BUG: a scroll finger's one-frame landing spike during a held click is taken as a two-finger chord — the hold is cut early, the engine locks, and (when macOS's own click was also down) its mouse-up later leaks unpaired") {
            #expect((performer.clicks.first?.upAt ?? 0) >= easeStart, "landing spike released the held click\n\(performer.report())")
            #expect(performer.violations().isEmpty, "\(performer.report())")
        }
    }
}

private extension Performer {
    /// Play a single-contact pressure series for the holding thumb.
    func play(_ pressures: [Double], native: GestureNative, lift doLift: Bool) {
        play(pressures.map { [ScrollWhileHeldScenarioTests.holdingThumb($0)] }, native: native, lift: doLift)
    }
}
