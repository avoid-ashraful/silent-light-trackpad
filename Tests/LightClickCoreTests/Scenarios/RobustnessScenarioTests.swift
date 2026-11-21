import Foundation
import Testing
@testable import LightClickCore

// Robustness scenarios: the app's lifecycle (stop / restart via
// `reset()`), settings changed from the menu while fingers are on
// the glass, double-click intervals at the Accessibility extremes,
// sensor glitches, long sessions, and record/replay fidelity.
//
// Tests that pin a genuine defect keep the user-facing expectation
// inside `withKnownIssue("BUG: …")`, so the suite stays green while
// the defect exists and turns red (known issue not recorded) the
// day it is fixed — then drop the wrapper.

// MARK: - Helpers

@MainActor
enum Robust {
    static func finger(_ id: Int32 = 1, _ pressure: Double, x: Double = 0.5, y: Double = 0.5, major: Double = 10) -> Contact {
        Contact(id: id, x: x, y: y, pressure: pressure, major: major)
    }

    /// One stationary finger following `pressures`, one frame each.
    static func feed(_ performer: Performer, _ pressures: [Double], id: Int32 = 1, x: Double = 0.5, y: Double = 0.5,
                     native: NativeButton = .auto) {
        for pressure in pressures {
            performer.frame([finger(id, pressure, x: x, y: y)], pointer: id, native: native)
        }
    }

    static func states(_ performer: Performer) -> [Int] { performer.clicks.map(\.clickState) }

    static func downNumbers(_ events: [OutputEvent]) -> [Int] {
        events.compactMap { if case let .down(_, _, _, n) = $0 { n } else { nil } }
    }

    /// Write `events` with `FrameRecorder`, read them back.
    static func roundTrip(_ events: [RecordedEvent]) throws -> [RecordedEvent] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sltp-robust-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try #require(FrameRecorder(url: url))
        for event in events { recorder.record(event) }
        recorder.close()
        return try FrameRecorder.readEvents(from: url)
    }

    static func describe(_ events: [RecordedEvent]) -> String {
        events.map { "  \($0)" }.joined(separator: "\n")
    }
}

/// Forwards every engine output to the rig's `FakeOutput` (so the
/// Performer's analysis keeps working) and also captures it as a
/// `RecordedEvent`, exactly like the debug build's output recorder.
@MainActor
final class RecordingTapOutput: ClickOutput {
    let inner: FakeOutput
    let clock: RigClock
    var captured: [RecordedEvent] = []

    init(inner: FakeOutput, clock: RigClock) {
        self.inner = inner
        self.clock = clock
    }

    func postMouseDown(at point: ClickPoint, clickState: Int, eventNumber: Int) {
        inner.postMouseDown(at: point, clickState: clickState, eventNumber: eventNumber)
        captured.append(.outputDown(time: clock.time, x: point.x, y: point.y, clickState: clickState))
    }

    func postMouseDragged(at point: ClickPoint, clickState: Int, eventNumber: Int) {
        inner.postMouseDragged(at: point, clickState: clickState, eventNumber: eventNumber)
        captured.append(.outputDragged(time: clock.time, x: point.x, y: point.y, clickState: clickState))
    }

    func postMouseUp(at point: ClickPoint, clickState: Int, eventNumber: Int) {
        inner.postMouseUp(at: point, clickState: clickState, eventNumber: eventNumber)
        captured.append(.outputUp(time: clock.time, x: point.x, y: point.y, clickState: clickState))
    }

    func pulseHaptic(down: Bool) {
        inner.pulseHaptic(down: down)
        captured.append(.outputHaptic(time: clock.time, down: down))
    }
}

/// A Performer that also writes the session the way the debug build
/// records it: every input the engine consumed (frames, native
/// down/up/move, threshold changes) and every output it produced,
/// stamped with the engine clock. The Performer's own native-event
/// and cursor modelling is reused unchanged: each frame's native
/// side effects are recovered from the Performer's trace (their
/// order and the frame's time are exact; move coordinates come from
/// the rig's cursor, which the move just set).
@MainActor
final class RecordingHand {
    let rig: TestRig
    private(set) var performer: Performer
    private let tap: RecordingTapOutput
    private(set) var log: [RecordedEvent] = []

    /// `seedCursor`: record the cursor's starting point as a move, so
    /// a replay starts from the same place (see `replayStartsAtZero`).
    init(rig: TestRig, seedCursor: Bool = true) {
        self.rig = rig
        performer = Performer(rig: rig)
        tap = RecordingTapOutput(inner: rig.output, clock: rig.clock)
        rig.engine.setOutput(tap)
        log.append(.sessionStarted(time: rig.clock.time, threshold: rig.engine.threshold))
        if seedCursor {
            log.append(.nativeMove(time: rig.clock.time, x: rig.clock.cursor.x, y: rig.clock.cursor.y))
        }
    }

    var outputs: [RecordedEvent] { log.filter(\.isOutput) }

    private func flush() {
        log += tap.captured
        tap.captured = []
    }

    func frame(_ contacts: [Contact], pointer: Int32? = nil, native: NativeButton = .auto, nativeFirst: Bool = false) {
        let t = rig.clock.time
        let mark = performer.trace.count
        performer.frame(contacts, pointer: pointer, native: native, nativeFirst: nativeFirst)
        for line in performer.trace[mark...] {
            let text = line.drop { $0 != " " }.dropFirst()
            if text.hasPrefix("frame") {
                log.append(.frame(time: t, touches: contacts.map(\.sample)))
            } else if text.hasPrefix("native move") {
                log.append(.nativeMove(time: t, x: rig.clock.cursor.x, y: rig.clock.cursor.y))
            } else if text.hasPrefix("native leftMouseDown") {
                log.append(.nativeDown(time: t))
            } else if text.hasPrefix("native leftMouseUp") {
                log.append(.nativeUp(time: t))
            }
        }
        flush()
    }

    func lift() { frame([]) }
    func wait(_ seconds: Double) { performer.wait(seconds) }

    func setThreshold(_ value: Double) {
        rig.engine.threshold = value
        log.append(.thresholdChanged(time: rig.clock.time, value: value))
    }

    func externalMouseMove(to point: ClickPoint) {
        performer.externalMouseMove(to: point)
        log.append(.nativeMove(time: rig.clock.time, x: point.x, y: point.y))
        flush()
    }

    func externalMouseClick() {
        log.append(.nativeDown(time: rig.clock.time))
        _ = rig.nativeDown()
        rig.advance(0.08)
        log.append(.nativeUp(time: rig.clock.time))
        _ = rig.nativeUp()
        flush()
    }

    /// The app's stop(): `reset()`. The recording format has no entry
    /// for it — only its outputs land in the log.
    func stopApp() {
        rig.engine.reset()
        flush()
    }

    /// The app's start() after a stop: a new event tap (fresh native
    /// pairing state) and a new `sessionStarted` entry.
    func startApp() {
        performer = Performer(rig: rig)
        log.append(.sessionStarted(time: rig.clock.time, threshold: rig.engine.threshold))
    }

    // Gesture building blocks, mirroring Gestures.swift through this
    // recorder's `frame`.

    func press(_ p: Press, lift doLift: Bool = true) {
        var nativeFired = false
        for pressure in p.curve {
            let jab = p.nativeFirst && !nativeFired && pressure >= performer.nativeThreshold
            if jab { nativeFired = true }
            frame([Contact(id: p.finger, x: p.x, y: p.y, pressure: pressure, major: p.major)], pointer: p.finger, nativeFirst: jab)
        }
        if doLift { lift() }
    }

    func multiClick(_ count: Int, gap: Double, _ p: Press) {
        for i in 0 ..< count {
            if i > 0 { wait(gap) }
            press(p)
        }
    }

    func slide(finger: Int32, from: (Double, Double), by: (Double, Double), frames: Int,
               pressure: (Double) -> Double, others: [Contact] = []) {
        for i in 0 ... frames {
            let t = Double(i) / Double(max(1, frames))
            frame(others + [Contact(id: finger, x: from.0 + by.0 * t, y: from.1 + by.1 * t, pressure: pressure(t))], pointer: finger)
        }
    }

    func drag(_ p: Press, dx: Double, dy: Double, frames: Int, dipTo: Double) {
        for i in 0 ... max(1, p.rampFrames) {
            let pr = p.landing + (p.peak - p.landing) * Double(i) / Double(max(1, p.rampFrames))
            frame([Contact(id: p.finger, x: p.x, y: p.y, pressure: pr, major: p.major)], pointer: p.finger)
        }
        for _ in 0 ..< max(1, p.holdFrames / 2) {
            frame([Contact(id: p.finger, x: p.x, y: p.y, pressure: p.peak, major: p.major)], pointer: p.finger)
        }
        slide(finger: p.finger, from: (p.x, p.y), by: (dx, dy), frames: frames) { t in p.peak - (p.peak - dipTo) * sin(t * .pi) }
        let end = (p.x + dx, p.y + dy)
        frame([Contact(id: p.finger, x: end.0, y: end.1, pressure: p.peak, major: p.major)], pointer: p.finger)
        for i in 1 ... max(1, p.releaseFrames) {
            let pr = p.peak + (p.landing - p.peak) * Double(i) / Double(max(1, p.releaseFrames))
            frame([Contact(id: p.finger, x: end.0, y: end.1, pressure: pr, major: p.major)], pointer: p.finger)
        }
        lift()
    }

    func scroll(fingers n: Int, dy: Double, frames: Int, heavy: Double?, landingSpike: Bool) {
        func contacts(_ t: Double, landed: Bool, moving: Bool) -> [Contact] {
            (0 ..< n).map { k in
                var pressure = landed ? 18.0 + Double(k) * 2 : 10
                if landed, !moving, landingSpike, k == 0 { pressure = 65 }
                if moving, k == 0, let heavy { pressure = heavy }
                return Contact(id: Int32(k + 1), x: 0.35 + Double(k) * 0.06, y: 0.45 + dy * t, pressure: pressure)
            }
        }
        for k in 1 ..< n { frame(Array(contacts(0, landed: false, moving: false).prefix(k))) }
        frame(contacts(0, landed: true, moving: false))
        for i in 1 ... frames { frame(contacts(Double(i) / Double(frames), landed: true, moving: true)) }
        for k in stride(from: n - 1, through: 1, by: -1) { frame(Array(contacts(1, landed: true, moving: true).prefix(k))) }
        lift()
    }

    func twoFingerClick(peak: Double) {
        for i in 0 ... 7 {
            let p = 8 + (peak - 8) * min(1, Double(i) / 4)
            frame([Contact(id: 1, x: 0.45, y: 0.5, pressure: p), Contact(id: 2, x: 0.55, y: 0.5, pressure: p)], native: .none)
        }
        lift()
    }

    func restingFingerClick(rest restPressure: Double, _ p: Press) {
        let rest = Contact(id: 9, x: 0.4, y: 0.85, pressure: restPressure, major: 13)
        for _ in 0 ..< 38 { frame([rest]) } // a resting finger has been resting
        for pressure in p.curve {
            frame([rest, Contact(id: p.finger, x: p.x, y: p.y, pressure: pressure, major: p.major)], pointer: p.finger)
        }
        frame([rest])
        lift()
    }
}

// MARK: - Lifecycle: stop / restart

/// The app's stop() (menu toggle off, quit, failed tap-to-click
/// restore) calls `reset()` and tears down the touch stream and the
/// event tap; start() brings both back. A restart is modelled as a
/// fresh Performer on the same rig: a new event tap knows nothing of
/// native presses the old one saw.
@MainActor
@Suite("Robustness: stop and restart mid-gesture")
struct RobustLifecycleTests {
    @Test("Stop mid-click: exactly one release, then a fresh click after restart")
    func stopMidClick() {
        let rig = TestRig()
        let before = Performer(rig: rig)
        Robust.feed(before, [8, 30, 55, 70, 70])
        #expect(rig.engine.buttonDown)

        let mark = rig.output.events.count
        let t = rig.clock.time
        rig.engine.reset()
        #expect(Array(rig.output.events[mark...]) == [
            .up(t: t, at: ClickPoint(x: 500, y: 500), clickState: 1, number: 1),
            .haptic(t: t, down: false),
        ])
        #expect(!rig.engine.buttonDown)
        #expect(!rig.engine.dragLatched)
        #expect(!rig.engine.isLocked)

        // Off: the finger eases off and lifts unseen. Then restart.
        before.wait(1.0)
        let after = Performer(rig: rig)
        after.perform(.click(.light()))
        #expect(after.violations().isEmpty, "\(after.report())")
        #expect(after.clicks.count == 2)
        #expect(after.clicks.last?.number == 2)
        #expect(after.clicks.last?.clickState == 1)
        #expect(after.clicks.last?.upAt != nil)
    }

    @Test("Stop mid-drag (latched): one release, late moves are not dragged, next drag is a new press")
    func stopMidLatchedDrag() {
        let rig = TestRig()
        let before = Performer(rig: rig)
        Robust.feed(before, [8, 40, 70, 70])
        before.slide(finger: 1, from: (0.5, 0.5), by: (0.1, 0), frames: 10, pressure: { _ in 70 })
        #expect(rig.engine.dragLatched)

        let mark = rig.output.events.count
        rig.engine.reset()
        let tail = Array(rig.output.events[mark...])
        #expect(tail.count == 2, "\(tail)")
        if case let .up(_, at, state, number)? = tail.first {
            #expect(state == 1)
            #expect(number == 1)
            #expect(at == rig.clock.cursor) // dropped where the cursor is
        } else {
            Issue.record("expected the held drag's up, got \(tail)")
        }
        #expect(!rig.engine.dragLatched)
        #expect(!rig.engine.buttonDown)

        // A move already in flight when the tap goes away must not be
        // answered with a dragged event.
        #expect(rig.move(to: ClickPoint(x: 650, y: 500)) == false)
        #expect(rig.output.events.count == mark + 2)

        before.wait(1.0)
        let after = Performer(rig: rig)
        after.perform(.drag(press: .light(), dx: 0.1, dy: 0, frames: 15, dipTo: 50))
        #expect(after.violations().isEmpty, "\(after.report())")
        #expect(after.clicks.count == 2)
        #expect(after.clicks.last?.number == 2)
        #expect(after.clicks.last?.isDrag == true)
    }

    @Test("Reset mid-scroll while frames keep arriving: the gate re-classifies, no click")
    func stopMidScroll() {
        let rig = TestRig()
        let p = Performer(rig: rig)
        func scrollFrame(_ i: Int) {
            let y = 0.4 + 0.015 * Double(i)
            p.frame([Robust.finger(1, 60, x: 0.45, y: y), Robust.finger(2, 22, x: 0.55, y: y)], native: .none)
        }
        for i in 0 ..< 6 { scrollFrame(i) }
        #expect(rig.engine.gestureMoved)
        rig.engine.reset()
        #expect(!rig.engine.gestureMoved)
        for i in 6 ..< 20 { scrollFrame(i) }
        #expect(rig.engine.gestureMoved)
        p.lift()
        #expect(p.clicks.isEmpty, "\(p.report())")

        p.wait(0.6)
        p.perform(.click(.light()))
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1)
        #expect(p.clicks.first?.clickState == 1)
    }

    @Test("Reset while locked by a two-finger press: the fingers still pressing re-lock, no left click")
    func stopWhileLocked() {
        let rig = TestRig()
        let p = Performer(rig: rig)
        func both(_ a: Double, _ b: Double) {
            p.frame([Robust.finger(1, a, x: 0.45), Robust.finger(2, b, x: 0.55)], native: .none)
        }
        both(40, 40)
        both(80, 80)
        #expect(rig.engine.isLocked)
        rig.engine.reset()
        #expect(!rig.engine.isLocked)
        both(85, 85)
        both(85, 85)
        both(60, 60)
        both(30, 30)
        #expect(rig.engine.isLocked)
        p.lift()
        #expect(!rig.engine.isLocked)
        #expect(p.clicks.isEmpty, "\(p.report())")

        p.wait(0.6)
        p.perform(.click(.light()))
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1)
        #expect(p.clicks.first?.number == 1)
    }

    @Test("Reset mid-jab (tap-fired click): one release; the in-flight native up is still swallowed")
    func stopMidJab() {
        let rig = TestRig()
        let p = Performer(rig: rig)
        p.frame([Robust.finger(1, 8)], pointer: 1)
        p.frame([Robust.finger(1, 150)], pointer: 1, nativeFirst: true)
        #expect(rig.engine.buttonDown)

        let mark = rig.output.events.count
        let t = rig.clock.time
        rig.engine.reset()
        #expect(Array(rig.output.events[mark...]) == [
            .up(t: t, at: ClickPoint(x: 500, y: 500), clickState: 1, number: 1),
            .haptic(t: t, down: false),
        ])
        // The finger lets go 8 ms later: macOS's native up arrives
        // inside the 150 ms echo window and is swallowed — the native
        // down was swallowed too, so apps see nothing unpaired.
        p.frame([Robust.finger(1, 10)], pointer: 1)
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1)

        p.wait(0.6)
        p.perform(.click(.light()))
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 2)
        #expect(p.clicks.last?.number == 2)
        #expect(p.clicks.last?.clickState == 1)
    }

    @Test("Reset is idempotent: stopping twice releases once")
    func resetTwice() {
        let rig = TestRig()
        let p = Performer(rig: rig)
        Robust.feed(p, [8, 70, 70])
        rig.engine.reset()
        rig.engine.reset()
        rig.engine.reset()
        let ups = rig.output.events.filter { if case .up = $0 { true } else { false } }
        #expect(ups.count == 1)
        #expect(Invariants.check(rig.output.events, doubleClickInterval: 0.5, settled: true).isEmpty)
    }

    /// LightClickEngine.stop() calls `core.reset()` and only then
    /// cancels the listening task; a frame the touch stream had
    /// already handed to that task still runs `processFrame` (the
    /// loop has no `Task.isCancelled` check before it). The engine
    /// cannot know the stream stopped: a pressing finger in that
    /// late frame presses again — and with the stream gone, nothing
    /// releases it. Pinned so the platform-side guard has a reason.
    @Test("A frame delivered after reset re-presses: the platform must drop late frames")
    func lateFrameAfterResetRePresses() {
        let rig = TestRig()
        let p = Performer(rig: rig)
        Robust.feed(p, [8, 70])
        rig.engine.reset()
        rig.frame(rig.touch(1, 70)) // the late frame
        #expect(rig.engine.buttonDown)
        rig.advance(5) // no more frames: the app is off
        #expect(rig.engine.buttonDown)
        rig.engine.reset() // only the next stop or a lift frees it
        #expect(!rig.engine.buttonDown)
        #expect(Robust.downNumbers(rig.output.events) == [1, 2])
        #expect(Invariants.check(rig.output.events, doubleClickInterval: 0.5, settled: true).isEmpty)
    }

    /// The realistic way back on: the app is off, the user clicks the
    /// "Light-pressure click" menu item with the trackpad (a native
    /// click). NSMenu acts on the mouse-up — near 54 in the
    /// simulator's force model — and start() then feeds the engine
    /// the rest of that same press as it eases off. At the 40 preset
    /// the first frame (46) is "above the threshold" and clicks
    /// whatever lies under the closed menu.
    @Test("Re-enabling from the menu must not click again as the menu click's finger eases off")
    func reenableWhileMenuClickEasesOff() {
        let rig = TestRig(threshold: 40)
        let p = Performer(rig: rig)
        Robust.feed(p, [46, 38, 30, 22, 14, 8])
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        withKnownIssue("BUG: a press already past the threshold when the engine starts clicks on its way out") {
            #expect(p.clicks.isEmpty, "\(p.report())")
        }
    }
}

// MARK: - Threshold changed from the menu

@MainActor
@Suite("Robustness: threshold changes mid-gesture")
struct RobustThresholdTests {
    /// The user picks "Very light · 30 g" while on "Guarded · 80 g",
    /// with the app's own light click. NSMenu acts on our mouse-up
    /// (posted as the press eases below 56 = 70% of 80); the new
    /// threshold is live while the same finger is still easing off,
    /// so 38.5 — above 30 — presses again: a double-click (state 2)
    /// on whatever sat under the menu.
    @Test("Lowering the threshold from the menu must not click again as the finger eases off")
    func menuLowersThresholdMidRelease() {
        let rig = TestRig(threshold: 80)
        let p = Performer(rig: rig)
        let press = Press(peak: 130, rampFrames: 4, holdFrames: 4, releaseFrames: 8)
        var changed = false
        for pressure in press.curve {
            p.frame([Robust.finger(1, pressure)], pointer: 1)
            if !changed, !rig.engine.buttonDown, !p.clicks.isEmpty {
                rig.engine.threshold = 30
                changed = true
            }
        }
        p.lift()
        #expect(changed)
        #expect(p.violations().isEmpty, "\(p.report())")
        withKnownIssue("BUG: lowering the threshold re-arms a finger that is still easing off — phantom double-click") {
            #expect(p.clicks.count == 1, "\(p.report())")
        }
    }

    @Test("Lowering the threshold while a click is held keeps it held; it releases at the new line")
    func lowerWhileHeld() {
        let rig = TestRig(threshold: 80)
        let p = Performer(rig: rig)
        Robust.feed(p, [10, 40, 85, 85])
        #expect(rig.engine.buttonDown)
        rig.engine.threshold = 30
        Robust.feed(p, [85, 85, 85, 85, 85, 60, 40, 25])
        #expect(rig.engine.buttonDown) // 25 is above 21 (70% of 30)
        let releaseTime = rig.clock.time
        Robust.feed(p, [15])
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.clicks.first?.upAt == releaseTime)
    }

    /// Raising the threshold under a held (not yet dragging) click:
    /// 50 is below the new release line (56), so it releases on the
    /// next frame — one clean click, and the finger staying at 50
    /// never re-presses. Acceptable: the press no longer counts.
    @Test("Raising the threshold under a held click releases it once, without re-pressing")
    func raiseWhileHeld() {
        let rig = TestRig(threshold: 30)
        let p = Performer(rig: rig)
        Robust.feed(p, [10, 50, 50])
        #expect(rig.engine.buttonDown)
        rig.engine.threshold = 80
        let releaseTime = rig.clock.time
        Robust.feed(p, [50, 50, 50, 50, 50])
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1)
        #expect(p.clicks.first?.upAt == releaseTime)
    }

    @Test("Raising the threshold mid-drag keeps the latched drag held to the drop")
    func raiseMidLatchedDrag() {
        let rig = TestRig(threshold: 30)
        let p = Performer(rig: rig)
        Robust.feed(p, [10, 50, 50])
        p.slide(finger: 1, from: (0.5, 0.5), by: (0.1, 0), frames: 10, pressure: { _ in 50 })
        #expect(rig.engine.dragLatched)
        rig.engine.threshold = 80
        p.slide(finger: 1, from: (0.6, 0.5), by: (0.1, 0), frames: 10, pressure: { _ in 50 })
        #expect(rig.engine.buttonDown)
        Robust.feed(p, [20, 3], x: 0.7)
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.clicks.first?.isDrag == true)
        #expect((p.clicks.first?.travel ?? 0) > 190)
    }

    @Test("Changing the threshold between the halves of a double-click keeps the chain")
    func changeBetweenDoubleClickHalves() {
        let rig = TestRig(threshold: 50)
        let p = Performer(rig: rig)
        p.perform(.click(.quick()))
        rig.engine.threshold = 40
        p.wait(0.1)
        p.perform(.click(.quick()))
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(Robust.states(p) == [1, 2])
    }

    @Test("Changing the threshold during a two-finger lock neither clicks nor unlocks")
    func changeDuringLock() {
        let rig = TestRig(threshold: 50)
        let p = Performer(rig: rig)
        func both(_ v: Double) { p.frame([Robust.finger(1, v, x: 0.45), Robust.finger(2, v, x: 0.55)], native: .none) }
        both(40)
        both(80)
        #expect(rig.engine.isLocked)
        rig.engine.threshold = 30
        both(80)
        rig.engine.threshold = 80
        both(60)
        #expect(rig.engine.isLocked)
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.isEmpty)
    }
}

// MARK: - Double-click interval extremes

/// Accessibility › Pointer Control › Double-click speed ranges from
/// very fast (~0.15 s) to very slow (~5 s).
@MainActor
@Suite("Robustness: double-click interval extremes")
struct RobustIntervalTests {
    nonisolated static let intervals: [Double] = [0.15, 0.5, 5.0]

    @Test("0.15 s: a fast double-click chains, a relaxed one is two single clicks")
    func fastestInterval() {
        // Down to down = 8 frames (64 ms) + the gap.
        for (gap, expected) in [(0.04, [1, 2]), (0.12, [1, 1])] {
            let rig = TestRig(doubleClickInterval: 0.15)
            let p = Performer(rig: rig)
            p.perform(.multiClick(count: 2, gap: gap, press: .quick()))
            #expect(p.violations().isEmpty, "\(p.report())")
            #expect(Robust.states(p) == expected, "gap \(gap)\n\(p.report())")
        }
    }

    @Test("5 s: slow clicks at one spot keep chaining; moving away or waiting restarts")
    func slowestInterval() {
        let rig = TestRig(doubleClickInterval: 5)
        let p = Performer(rig: rig)
        p.perform(.click(.light()))
        p.wait(2)
        p.perform(.click(.light()))
        p.wait(2)
        p.perform(.click(.light()))
        p.externalMouseMove(to: ClickPoint(x: 600, y: 500))
        p.wait(1)
        p.perform(.click(.light()))
        p.wait(6)
        p.perform(.click(.light()))
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(Robust.states(p) == [1, 2, 3, 1, 1], "\(p.report())")
    }

    @Test("5 s: a drag 3 s after a click at the same spot is a double-click-drag")
    func slowIntervalDoubleClickDrag() {
        let rig = TestRig(doubleClickInterval: 5)
        let p = Performer(rig: rig)
        p.perform(.click(.quick()))
        p.wait(3)
        p.perform(.drag(press: .light(), dx: 0.15, dy: 0, frames: 20, dipTo: 55))
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 2)
        #expect(p.clicks.last?.clickState == 2)
        #expect(p.clicks.last?.isDrag == true)
    }

    @Test("A fast triple-click is 1-2-3 at every interval", arguments: intervals)
    func tripleClick(interval: Double) {
        let rig = TestRig(doubleClickInterval: interval)
        let p = Performer(rig: rig)
        p.perform(.multiClick(count: 3, gap: 0.03, press: .quick()))
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(Robust.states(p) == [1, 2, 3])
    }
}

// MARK: - Sensor glitches

/// Capacitive glitches never reach the force sensor, so glitch
/// frames use `native: .none` (macOS's own click is not involved).
@MainActor
@Suite("Robustness: sensor glitches")
struct RobustGlitchTests {
    nonisolated static let invalidReadings: [Double] = [-5, .nan]
    nonisolated static let spikes: [Double] = [10_000, .infinity]

    /// A reading that cannot be a real press (negative, NaN) is
    /// clamped to 0 — read as a full release — so one bad frame
    /// splits a held click into a double-click (state 1 then 2).
    @Test("One invalid pressure reading mid-hold must not split the click", arguments: invalidReadings)
    func invalidReadingMidHold(reading: Double) {
        let rig = TestRig()
        let p = Performer(rig: rig)
        var seen: [Double] = []
        rig.engine.onPressureChange = { seen.append($0) }
        Robust.feed(p, [8, 40, 70, 70, 70])
        p.frame([Robust.finger(1, reading)], pointer: 1, native: .none)
        Robust.feed(p, [70, 70, 40, 8])
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(!rig.engine.buttonDown)
        #expect(!seen.contains { $0.isNaN || $0 < 0 }) // the UI meter never sees garbage
        withKnownIssue("BUG (low): one invalid frame reads as a release — a held click becomes a double-click") {
            #expect(p.clicks.count == 1, "\(p.report())")
        }
    }

    @Test("Invalid readings on a hovering finger never click or stick")
    func invalidReadingsWhileHovering() {
        let rig = TestRig()
        let p = Performer(rig: rig)
        Robust.feed(p, [12, .nan, 12, -40, 12, .nan, -.infinity, 12], native: .none)
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.isEmpty)
    }

    /// A single-frame spike on a pointing finger is indistinguishable
    /// from a one-frame jab, so it clicks — once, released on the
    /// next frame, never stuck. (No plausibility cap on pressure;
    /// noted, not a bug on its own.)
    @Test("A single huge spike on a pointing finger clicks once and releases at once", arguments: spikes)
    func spikeWhilePointing(spike: Double) {
        let rig = TestRig()
        let p = Performer(rig: rig)
        Robust.feed(p, [15, 15, 15], native: .none)
        p.frame([Robust.finger(1, spike)], pointer: 1, native: .none)
        let spikeEnd = rig.clock.time
        Robust.feed(p, [15, 15], native: .none)
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1)
        #expect(p.clicks.first?.upAt == spikeEnd)
    }

    @Test("A huge one-frame spike mid-scroll does not click", arguments: spikes)
    func spikeMidScroll(spike: Double) {
        let rig = TestRig()
        let p = Performer(rig: rig)
        for i in 0 ..< 16 {
            let y = 0.4 + 0.015 * Double(i)
            p.frame([Robust.finger(1, i == 8 ? spike : 20, x: 0.45, y: y), Robust.finger(2, 22, x: 0.55, y: y)], native: .none)
        }
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.isEmpty, "\(p.report())")
    }

    @Test("A huge one-frame spike with a resting thumb does not click (dwell)")
    func spikeWithRestingThumb() {
        let rig = TestRig()
        let p = Performer(rig: rig)
        let thumb = Robust.finger(9, 12, x: 0.4, y: 0.85, major: 13)
        for i in 0 ..< 10 {
            p.frame([thumb, Robust.finger(1, i == 5 ? 10_000 : 15)], pointer: 1, native: .none)
        }
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.isEmpty, "\(p.report())")
    }

    @Test("A dropped-frame gap (80 ms) mid-press keeps one click")
    func droppedFramesMidPress() {
        let rig = TestRig()
        let p = Performer(rig: rig)
        Robust.feed(p, [8, 40, 70, 70])
        p.wait(0.08)
        Robust.feed(p, [70, 70, 40, 8])
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1)
        #expect((p.clicks.first?.duration ?? 0) > 0.08)
    }

    @Test("A dropped-frame gap (100 ms) mid-drag, finger jumping ahead, keeps one drag")
    func droppedFramesMidDrag() {
        let rig = TestRig()
        let p = Performer(rig: rig)
        Robust.feed(p, [8, 40, 70, 70])
        p.slide(finger: 1, from: (0.5, 0.5), by: (0.05, 0), frames: 5, pressure: { _ in 70 })
        p.wait(0.1)
        p.slide(finger: 1, from: (0.6, 0.5), by: (0.05, 0), frames: 5, pressure: { _ in 70 })
        Robust.feed(p, [70, 40, 3], x: 0.65)
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.clicks.first?.isDrag == true)
        #expect(abs((p.clicks.first?.travel ?? 0) - 150) < 0.001)
    }

    /// The touch stream stalls (main thread busy) after the finger
    /// lands; macOS's native press, decided by the force sensor in
    /// the HID system, arrives first — more than 150 ms after the
    /// last frame. The engine reads "no recent touch" as an external
    /// mouse and lets it through, then the next frame fires our own
    /// click: two clicks for one press, and the native up is later
    /// swallowed — apps never see the native down's release. The
    /// last frame still had a finger on the glass (no empty frame
    /// since), which the engine could use instead of the clock.
    @Test("A touch-stream stall before a firm press must not leak the native click")
    func stallBeforeNativePress() {
        let rig = TestRig()
        let p = Performer(rig: rig)
        Robust.feed(p, [10])
        p.wait(0.2)
        p.frame([Robust.finger(1, 130)], pointer: 1, nativeFirst: true)
        Robust.feed(p, [130, 130, 90, 60, 30, 8])
        p.lift()
        #expect(Invariants.check(p.events, doubleClickInterval: 0.5, settled: true).isEmpty, "\(p.report())")
        #expect(!rig.engine.buttonDown)
        withKnownIssue("BUG: after a ≥150 ms frame stall a trackpad press leaks as a native click and its up is swallowed") {
            #expect(p.leakedNativePresses == 0, "\(p.report())")
            #expect(p.violations().isEmpty, "\(p.report())")
        }
    }

    /// With a thumb resting, the dragging finger's contact drops out
    /// of one frame. The engine reads it as that finger lifting: the
    /// latched drag is released on the spot (dropped 50 px short of
    /// the target), and the rest of the slide is never re-pressed
    /// (the gate has classified the two-finger sequence as moving).
    @Test("The tracked finger vanishing for one frame mid-drag must not drop the drag")
    func trackedFingerDropoutMidDrag() {
        let rig = TestRig()
        let p = Performer(rig: rig)
        let thumb = Robust.finger(9, 12, x: 0.4, y: 0.85, major: 13)
        for _ in 0 ..< 38 { p.frame([thumb]) } // the thumb was already resting
        for pressure in [8.0, 40, 70, 70, 70, 70] {
            p.frame([thumb, Robust.finger(1, pressure)], pointer: 1)
        }
        p.slide(finger: 1, from: (0.5, 0.5), by: (0.1, 0), frames: 10, pressure: { _ in 70 }, others: [thumb])
        #expect(rig.engine.dragLatched)
        p.frame([thumb]) // finger 1 missing for one frame
        p.slide(finger: 1, from: (0.6, 0.5), by: (0.05, 0), frames: 5, pressure: { _ in 70 }, others: [thumb])
        for pressure in [40.0, 3] { p.frame([thumb, Robust.finger(1, pressure, x: 0.65)], pointer: 1) }
        p.frame([thumb])
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        withKnownIssue("BUG (low): a one-frame touch dropout drops a latched drag short of its target") {
            #expect(p.clicks.count == 1, "\(p.report())")
            #expect(abs((p.clicks.last?.travel ?? 0) - 150) < 0.001, "\(p.report())")
        }
    }

    @Test("Touch IDs reused for a new finger after a lift start a clean new press")
    func idReusedAfterLift() {
        let rig = TestRig()
        let p = Performer(rig: rig)
        p.perform(.click(Press(finger: 1, x: 0.3)))
        p.wait(0.6)
        p.perform(.click(Press(finger: 1, x: 0.7)))
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(Robust.downNumbers(p.events) == [1, 2])
        #expect(Robust.states(p) == [1, 1])
    }

    /// Thumb resting; the index finger clicks, lifts (the thumb keeps
    /// the touch session alive) and lands again a few mm away — a
    /// double-click as people actually make one — or anywhere else.
    static func thumbRestingClickTwice(secondID: Int32, secondX: Double) -> Performer {
        let rig = TestRig()
        let p = Performer(rig: rig)
        let thumb = Robust.finger(9, 12, x: 0.4, y: 0.85, major: 13)
        for _ in 0 ..< 38 { p.frame([thumb]) } // the thumb was already resting
        for pressure in Press.light().curve { p.frame([thumb, Robust.finger(1, pressure, x: 0.5)], pointer: 1) }
        for _ in 0 ..< 6 { p.frame([thumb]) }
        for pressure in Press.light().curve {
            p.frame([thumb, Robust.finger(secondID, pressure, x: secondX)], pointer: secondID)
        }
        p.frame([thumb])
        p.lift()
        return p
    }

    @Test("Thumb resting: the second click of a double-click by a finger with a new touch ID works")
    func thumbRestingNewID() {
        let p = Self.thumbRestingClickTwice(secondID: 2, secondX: 0.53)
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(Robust.states(p) == [1, 2], "\(p.report())")
    }

    /// Touch IDs are reused: after the index lifts, the next finger
    /// may come back as ID 1 a few mm away. The gesture gate must not
    /// read the jump from the lifted touch's old position as a flick
    /// (it once did: the sequence became a "scroll" and the light
    /// click was silently lost).
    @Test("Thumb resting: a click by a finger reusing a lifted touch ID must not be lost",
          arguments: [0.53, 0.8])
    func thumbRestingReusedID(secondX: Double) {
        let p = Self.thumbRestingClickTwice(secondID: 1, secondX: secondX)
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 2, "\(p.report())")
    }

    /// Two-finger scroll; one finger leaves and the remaining one
    /// presses hard enough for macOS's own (single-finger, left)
    /// click, ~95 here. The gate's scroll classification sticks
    /// until every finger lifts, so the engine swallows the native
    /// press without answering (its hard-press override needs 2x the
    /// threshold, 100) — and does not remember to swallow the
    /// matching native up, which reaches apps unpaired.
    @Test("A native press swallowed after a scroll must not lose the click or leak its release")
    func nativePressSwallowedAfterScroll() {
        let rig = TestRig()
        let p = Performer(rig: rig)
        for i in 0 ..< 10 {
            let y = 0.4 + 0.015 * Double(i)
            p.frame([Robust.finger(1, 20, x: 0.45, y: y), Robust.finger(2, 22, x: 0.55, y: y)], native: .none)
        }
        #expect(rig.engine.gestureMoved)
        Robust.feed(p, [20, 50, 80, 95, 95, 95, 60, 30, 10], x: 0.45, y: 0.535)
        p.lift()
        #expect(Invariants.check(p.events, doubleClickInterval: 0.5, settled: true).isEmpty, "\(p.report())")
        withKnownIssue("BUG: a native press swallowed during a sticky scroll classification loses the click and leaks its up") {
            #expect(p.violations().isEmpty, "\(p.report())")
            #expect(p.clicks.count == 1, "\(p.report())")
        }
    }

    /// A finger lifts and another lands with the same ID within one
    /// frame: the engine sees one contact jump across the pad and
    /// drop from 70 to 8. It must read as a release, then a new
    /// press — never as a 400 px drag.
    @Test("A touch ID handed to a new finger within one frame does not drag across the pad")
    func idReusedWithinOneFrame() {
        let rig = TestRig()
        let p = Performer(rig: rig)
        Robust.feed(p, [8, 40, 70, 70], x: 0.3)
        Robust.feed(p, [8, 40, 70, 70, 40, 8], x: 0.7)
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 2, "\(p.report())")
        #expect(p.clicks.allSatisfy { !$0.isDrag }, "\(p.report())")
    }

    @Test("A burst of frames with zero time advance is one click and does not disturb chaining")
    func zeroTimeBurst() {
        let rig = TestRig()
        let p = Performer(rig: rig)
        p.frameDT = 0
        p.perform(.click(.light()))
        p.frameDT = 0.008
        p.wait(0.1)
        p.perform(.click(.light()))
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(Robust.states(p) == [1, 2])
    }

    @Test("Every frame delivered twice: single-finger clicks, double-clicks and drags are unchanged")
    func duplicatedFramesSingleFinger() {
        func run(duplicate: Bool) -> [String] {
            let rig = TestRig()
            let p = Performer(rig: rig)
            func f(_ pressure: Double, x: Double = 0.5) {
                if duplicate {
                    p.frameDT = 0
                    p.frame([Robust.finger(1, pressure, x: x)], pointer: 1)
                    p.frameDT = 0.008
                }
                p.frame([Robust.finger(1, pressure, x: x)], pointer: 1)
            }
            for v in Press.light().curve { f(v) }
            p.lift()
            p.wait(0.1)
            for v in Press.quick().curve { f(v) }
            p.lift()
            p.wait(0.8)
            for v in [8.0, 40, 70, 70] { f(v) }
            for i in 0 ... 10 { f(70, x: 0.5 + 0.01 * Double(i)) }
            for v in [40.0, 3] { f(v, x: 0.6) }
            p.lift()
            #expect(p.violations().isEmpty, "\(p.report())")
            return p.clicks.map { "state \($0.clickState) drag \($0.isDrag) travel \(Int($0.travel))" }
        }
        let plain = run(duplicate: false)
        #expect(plain.count == 3)
        #expect(run(duplicate: true) == plain)
    }

    /// The multi-touch dwell counts frames, not time: a 2-frame
    /// landing spike (rejected by design) delivered twice is 4
    /// frames and passes the 3-frame dwell. The same applies to any
    /// trackpad reporting at a higher frame rate.
    @Test("Duplicated frames must not turn a 2-frame landing spike into a click")
    func duplicatedFramesFoolTheDwell() {
        func run(duplicate: Bool) -> Performer {
            let rig = TestRig()
            let p = Performer(rig: rig)
            func f(_ a: Double, _ b: Double, y: Double = 0.45) {
                let contacts = [Robust.finger(1, a, x: 0.4, y: y), Robust.finger(2, b, x: 0.5, y: y)]
                if duplicate {
                    p.frameDT = 0
                    p.frame(contacts, native: .none)
                    p.frameDT = 0.008
                }
                p.frame(contacts, native: .none)
            }
            f(10, 10)
            f(65, 20)
            f(65, 20)
            f(18, 20)
            for i in 1 ... 10 { f(18, 20, y: 0.45 + 0.015 * Double(i)) }
            p.lift()
            return p
        }
        let plain = run(duplicate: false)
        #expect(plain.clicks.isEmpty, "\(plain.report())")
        let doubled = run(duplicate: true)
        #expect(doubled.violations().isEmpty, "\(doubled.report())")
        // The dwell still counts frames, but fingers that land together
        // and press within 0.3 s are a multi-finger tap — never a click.
        #expect(doubled.clicks.isEmpty, "\(doubled.report())")
    }
}

// MARK: - Long sessions

@MainActor
@Suite("Robustness: long sessions")
struct RobustLongSessionTests {
    nonisolated static let seeds: [UInt64] = [2_024, 77_777]
    nonisolated static let holdPressures: [Double] = [70, 120]

    @Test("2,000 random gestures in one rig: numbers strictly increase, nothing sticks", arguments: seeds)
    func twoThousandGestures(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        let threshold = [30.0, 50, 80].randomElement(using: &rng)!
        let rig = TestRig(threshold: threshold, doubleClickInterval: 0.5)
        let p = Performer(rig: rig)
        var failure: String?
        for i in 0 ..< 2_000 {
            let pause = [0.0, 0.05, 0.12, 0.3, 0.6, 1.2].randomElement(using: &rng)!
            if pause > 0 { p.perform(.pause(pause)) }
            if Int.random(in: 0 ..< 15, using: &rng) == 0 {
                p.perform(.pause(0.3))
                p.perform(.externalMouseClick)
            }
            let gesture = FuzzTests.randomGesture(&rng)
            let produced = p.perform(gesture)
            var problems = expectationProblems(gesture.expectation(threshold: threshold), produced: produced)
            if i % 100 == 99 { problems += p.violations() }
            if !problems.isEmpty {
                failure = "seed \(seed) threshold \(threshold) gesture #\(i) \(gesture)\n" + p.report(problems, limit: 60)
                break
            }
        }
        #expect(failure == nil, "\(failure ?? "")")
        #expect(p.violations().isEmpty, "\(p.report(limit: 40))")
        let numbers = Robust.downNumbers(p.events)
        #expect(!numbers.isEmpty)
        #expect(numbers == Array(1 ... max(1, numbers.count)), "one event number per press, no gaps or repeats")
        #expect(p.clicks.allSatisfy { $0.upAt != nil })
        #expect(!rig.engine.buttonDown)
        #expect(!rig.engine.isLocked)
    }

    @Test("A 30-second press-and-hold is one press, released once", arguments: holdPressures)
    func thirtySecondHold(pressure: Double) {
        let rig = TestRig()
        let p = Performer(rig: rig)
        Robust.feed(p, [8, 40, pressure])
        let frames = Int(30 / p.frameDT)
        for i in 0 ..< frames {
            Robust.feed(p, [pressure + 5 * sin(Double(i) * 0.37)])
        }
        Robust.feed(p, [pressure * 0.5, 20, 5])
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect((p.clicks.first?.duration ?? 0) >= 30)
        #expect(p.leakedNativePresses == 0)
    }

    @Test("30 s with a thumb resting throughout: a click every second, each one clean")
    func thirtySecondsOfThumbRest() {
        let rig = TestRig()
        let p = Performer(rig: rig)
        let thumb = Robust.finger(9, 12, x: 0.4, y: 0.85, major: 13)
        for _ in 0 ..< 38 { p.frame([thumb]) } // the thumb was already resting
        for _ in 0 ..< 30 {
            for pressure in Press.light().curve { p.frame([thumb, Robust.finger(1, pressure)], pointer: 1) }
            while rig.clock.time.truncatingRemainder(dividingBy: 1) > 0.01 { p.frame([thumb]) }
        }
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report(limit: 40))")
        #expect(p.clicks.count == 30)
        #expect(p.clicks.allSatisfy { $0.clickState == 1 && !$0.isDrag })
    }

    /// The engine clock is system uptime: after a year without a
    /// reboot it is ~3e7 s. Every timing window (jab 150 ms, echo
    /// 150 ms, chord 100 ms, double-click) must behave the same.
    @Test("A year of uptime on the clock changes nothing")
    func largeUptime() {
        func run(start: Double) -> [String] {
            let rig = TestRig()
            rig.clock.time = start
            let p = Performer(rig: rig)
            for gesture in [Gesture.click(.light()), .multiClick(count: 3, gap: 0.08, press: .quick()), .click(.jab()),
                            .drag(press: .firm(), dx: 0.1, dy: 0.05, frames: 20, dipTo: 60),
                            .restingFingerClick(restPressure: 12, press: .light()), .chordMidClick(secondPeak: 90),
                            .externalMouseClick, .pause(0.6), .click(.firm())] {
                p.perform(gesture)
            }
            #expect(p.violations().isEmpty, "\(p.report())")
            return p.clicks.map { "#\($0.number) s\($0.clickState) d\($0.drags.count) " + String(format: "%.4f", $0.duration ?? -1) }
        }
        let base = run(start: 1_000)
        #expect(!base.isEmpty)
        #expect(run(start: 31_536_000) == base)
    }
}

// MARK: - Record / replay fidelity

@MainActor
@Suite("Robustness: record and replay")
struct RobustReplayTests {
    enum Scenario: String, CaseIterable, Sendable {
        case click, doubleClick, tripleClick, firmClick, jab, drag, doubleClickDrag
        case scroll, heavyScroll, twoFingerClick, restingFingerClick, thresholdChange, externalMouse
    }

    nonisolated static let scenarios = Scenario.allCases

    static func perform(_ scenario: Scenario, on hand: RecordingHand) {
        switch scenario {
        case .click: hand.press(.light())
        case .doubleClick: hand.multiClick(2, gap: 0.1, .quick())
        case .tripleClick: hand.multiClick(3, gap: 0.08, .quick())
        case .firmClick: hand.press(.firm())
        case .jab: hand.press(.jab())
        case .drag: hand.drag(.light(), dx: 0.2, dy: 0.05, frames: 25, dipTo: 30)
        case .doubleClickDrag:
            hand.press(.quick())
            hand.wait(0.1)
            hand.drag(.quick(), dx: 0.15, dy: 0, frames: 20, dipTo: 40)
        case .scroll: hand.scroll(fingers: 2, dy: 0.3, frames: 20, heavy: nil, landingSpike: true)
        case .heavyScroll: hand.scroll(fingers: 2, dy: -0.3, frames: 15, heavy: 110, landingSpike: false)
        case .twoFingerClick: hand.twoFingerClick(peak: 90)
        case .restingFingerClick: hand.restingFingerClick(rest: 12, .light())
        case .thresholdChange:
            hand.press(.light())
            hand.wait(0.2)
            hand.setThreshold(80)
            hand.press(.light()) // 70 < 80: nothing
            hand.wait(0.2)
            hand.setThreshold(30)
            hand.press(Press(peak: 45))
        case .externalMouse:
            hand.press(.light())
            hand.wait(0.3)
            hand.externalMouseMove(to: ClickPoint(x: 700, y: 300))
            hand.externalMouseClick()
            hand.wait(0.3)
            hand.press(.light())
        }
    }

    @Test("Recorded sessions round-trip through the file and replay to identical outputs", arguments: scenarios)
    func replayReproduces(scenario: Scenario) throws {
        let rig = TestRig()
        let hand = RecordingHand(rig: rig)
        Self.perform(scenario, on: hand)
        #expect(hand.performer.violations().isEmpty, "\(hand.performer.report())")
        #expect(!hand.outputs.isEmpty || [.scroll, .twoFingerClick].contains(scenario))

        let readBack = try Robust.roundTrip(hand.log)
        #expect(readBack == hand.log)
        let replayed = ReplayDriver.replay(events: readBack).outputs
        #expect(replayed == hand.outputs, "live:\n\(Robust.describe(hand.outputs))\nreplay:\n\(Robust.describe(replayed))")
    }

    @Test("A 300-gesture mixed session replays to identical outputs")
    func mixedSessionReplays() throws {
        var rng = SeededRNG(seed: 4_242)
        let rig = TestRig()
        let hand = RecordingHand(rig: rig)
        for _ in 0 ..< 300 {
            let pause = [0.0, 0.05, 0.12, 0.3, 0.6].randomElement(using: &rng)!
            if pause > 0 { hand.wait(pause) }
            switch Int.random(in: 0 ..< 10, using: &rng) {
            case 0, 1: hand.press(FuzzTests.randomPress(&rng))
            case 2: hand.multiClick(Int.random(in: 2 ... 3, using: &rng), gap: 0.08, FuzzTests.randomPress(&rng))
            case 3, 4:
                var p = FuzzTests.randomPress(&rng)
                p.peak = Double.random(in: 60 ... 150, using: &rng)
                hand.drag(p, dx: Double.random(in: -0.3 ... 0.3, using: &rng), dy: Double.random(in: -0.2 ... 0.2, using: &rng),
                          frames: Int.random(in: 8 ... 30, using: &rng), dipTo: Double.random(in: 8 ... p.peak, using: &rng))
            // Scroll load stays under macOS's own click (~90): with two
            // fingers on the glass a real Mac answers a force press
            // with a secondary click the tap never sees, which the
            // simulator does not model (see nativePressSwallowedAfterScroll).
            case 5: hand.scroll(fingers: Int.random(in: 2 ... 4, using: &rng), dy: Double.random(in: -0.4 ... 0.4, using: &rng),
                                frames: Int.random(in: 4 ... 25, using: &rng),
                                heavy: Bool.random(using: &rng) ? Double.random(in: 20 ... 85, using: &rng) : nil,
                                landingSpike: Bool.random(using: &rng))
            case 6: hand.twoFingerClick(peak: Double.random(in: 40 ... 140, using: &rng))
            case 7: hand.restingFingerClick(rest: Double.random(in: 4 ... 20, using: &rng), FuzzTests.randomPress(&rng))
            case 8: hand.setThreshold([30.0, 40, 50, 60, 80].randomElement(using: &rng)!)
            default:
                hand.wait(0.3)
                hand.externalMouseMove(to: ClickPoint(x: Double.random(in: 100 ... 1_400, using: &rng),
                                                      y: Double.random(in: 100 ... 800, using: &rng)))
                hand.externalMouseClick()
            }
        }
        #expect(hand.performer.violations().isEmpty, "\(hand.performer.report(limit: 40))")
        #expect(hand.outputs.count > 100)
        let readBack = try Robust.roundTrip(hand.log)
        #expect(readBack == hand.log)
        let replayed = ReplayDriver.replay(events: readBack).outputs
        let firstDiff = zip(replayed, hand.outputs).enumerated().first { $0.element.0 != $0.element.1 }
        #expect(replayed == hand.outputs,
                "counts live \(hand.outputs.count) replay \(replayed.count); first difference at \(firstDiff.map { "\($0.offset): live \($0.element.1) replay \($0.element.0)" } ?? "tail")")
    }

    /// The recording has no starting cursor position: until the first
    /// mouse move, the replay's cursor is (0, 0), so every click
    /// before it replays at the wrong place — and a click chain
    /// (5 px rule) can differ too.
    @Test("Replay must reproduce clicks made before the first mouse move")
    func replayStartsAtZero() {
        let rig = TestRig()
        let hand = RecordingHand(rig: rig, seedCursor: false)
        hand.press(.light())
        let replayed = ReplayDriver.replay(events: hand.log).outputs
        withKnownIssue("REPLAY GAP: no initial cursor in the recording — pre-move clicks replay at (0, 0)") {
            #expect(replayed == hand.outputs, "live:\n\(Robust.describe(hand.outputs))\nreplay:\n\(Robust.describe(replayed))")
        }
    }

    /// ReplayDriver hard-codes a 0.5 s double-click interval and the
    /// recording does not capture the user's setting: a session at
    /// 0.25 s replays two separate clicks as a double-click.
    @Test("Replay must use the session's double-click interval")
    func replayIgnoresInterval() {
        let rig = TestRig(doubleClickInterval: 0.25)
        let hand = RecordingHand(rig: rig)
        hand.press(.quick())
        hand.wait(0.3)
        hand.press(.quick())
        #expect(hand.performer.violations().isEmpty, "\(hand.performer.report())")
        let replayed = ReplayDriver.replay(events: hand.log).outputs
        withKnownIssue("REPLAY GAP: double-click interval not recorded; replay assumes 0.5 s") {
            #expect(replayed == hand.outputs, "live:\n\(Robust.describe(hand.outputs))\nreplay:\n\(Robust.describe(replayed))")
        }
    }

    /// stop() → reset() releases the held click (that up is
    /// recorded) but leaves no input entry, and `sessionStarted` on
    /// restart does not reset the replay engine: the replay keeps the
    /// press held and diverges from there.
    @Test("Replay must reproduce a stop and restart")
    func replayMissesStop() {
        let rig = TestRig()
        let hand = RecordingHand(rig: rig)
        hand.press(Press.light(), lift: false)
        hand.frame([Robust.finger(1, 70)], pointer: 1)
        hand.stopApp()
        hand.wait(1)
        hand.startApp()
        hand.press(.light())
        #expect(hand.performer.violations().isEmpty, "\(hand.performer.report())")
        let replayed = ReplayDriver.replay(events: hand.log).outputs
        withKnownIssue("REPLAY GAP: stop()/reset() is not recorded and sessionStarted does not reset the replay") {
            #expect(replayed == hand.outputs, "live:\n\(Robust.describe(hand.outputs))\nreplay:\n\(Robust.describe(replayed))")
        }
    }

    /// JSONEncoder refuses non-finite doubles; FrameRecorder swallows
    /// the error and writes nothing — the frame silently vanishes
    /// from the recording, so the very glitch being investigated is
    /// the one thing the replay never sees.
    @Test("A frame with a non-finite pressure must survive recording")
    func nonFiniteFrameDropped() throws {
        let rig = TestRig()
        let hand = RecordingHand(rig: rig)
        hand.frame([Robust.finger(1, 8)], pointer: 1)
        hand.frame([Robust.finger(1, 70)], pointer: 1)
        hand.frame([Robust.finger(1, .nan)], pointer: 1, native: .none)
        hand.frame([Robust.finger(1, 70)], pointer: 1)
        hand.lift()
        let readBack = try Robust.roundTrip(hand.log)
        let replayed = ReplayDriver.replay(events: readBack).outputs
        withKnownIssue("REPLAY GAP: frames with NaN/inf pressure are dropped from the recording") {
            #expect(readBack.count == hand.log.count)
            #expect(replayed == hand.outputs, "live:\n\(Robust.describe(hand.outputs))\nreplay:\n\(Robust.describe(replayed))")
        }
    }

    /// The recording matters most when the app died; a crash or kill
    /// mid-write leaves a partial last line, and `readEvents` then
    /// throws for the whole file instead of returning what was
    /// complete.
    @Test("A recording cut off mid-line must still read back its complete entries")
    func truncatedRecording() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sltp-robust-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try #require(FrameRecorder(url: url))
        let events: [RecordedEvent] = [
            .sessionStarted(time: 0, threshold: 50),
            .frame(time: 0.01, touches: [TouchSample(id: 1, x: 0.5, y: 0.5, pressure: 60, majorAxis: 10)]),
            .frame(time: 0.02, touches: []),
        ]
        for event in events { recorder.record(event) }
        recorder.close()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"frame":{"time":0.03,"tou"#.utf8))
        try handle.close()

        withKnownIssue("REPLAY GAP: a truncated last line makes the whole recording unreadable") {
            let readBack = try FrameRecorder.readEvents(from: url)
            #expect(readBack == events)
        }
    }
}
