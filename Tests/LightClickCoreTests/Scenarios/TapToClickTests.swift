import Foundation
import Testing
@testable import LightClickCore

// macOS's Tap to click, live on the device (a device recording showed
// it): every light tap makes the system post its own left-mouse-down
// and -up — ~0.2 s after the finger lifts, or as the next finger lands
// when it waits to see a double tap. Those clicks are macOS's: silent,
// with its own double tap and tap-and-drag. The engine must let them
// through untouched — no click of its own, no vibration, no held
// button. Timings below are taken from the recording.

@MainActor
private extension Performer {
    /// A light tap by finger `id`: on the glass `frames` frames at
    /// tap pressure (well below every threshold), then lifted.
    func tap(id: Int32 = 1, x: Double = 0.5, others: [Contact] = [], frames: Int = 8) {
        for i in 0 ..< frames {
            frame(others + [Contact(id: id, x: x, y: 0.5, pressure: [4, 9, 12, 10, 8][min(i, 4)])], pointer: id, native: .none)
        }
        frame(others, pointer: nil, native: .none)
    }

    /// A frame of `contacts` repeated for `seconds`.
    func hold(_ contacts: [Contact], for seconds: Double, pointer: Int32? = nil) {
        for _ in 0 ..< Int((seconds / frameDT).rounded()) { frame(contacts, pointer: pointer, native: .none) }
    }

    var hapticCount: Int { events.filter { if case .haptic = $0 { true } else { false } }.count }
}

@MainActor
@Suite("Tap to click: macOS's own tap clicks pass through")
struct TapToClickTests {
    static let thumb = Contact(id: 9, x: 0.68, y: 0.38, pressure: 29, major: 13)

    /// One tap; macOS posts its click 0.2 s after the lift.
    @Test func singleTap() {
        let p = Performer(rig: TestRig(threshold: 50))
        p.tap()
        p.wait(0.2)
        let down = p.rig.nativeDown()
        p.wait(0.005)
        let up = p.rig.nativeUp()
        #expect(!down && !up, "macOS's tap click must reach apps")
        #expect(p.events.isEmpty, "\(p.report())")
        #expect(!p.engine.buttonDown)
    }

    /// Thumb resting (pressure ~29, as recorded), index taps; macOS
    /// clicks 0.21 s later while the thumb still rests. No vibration,
    /// and an ordinary light press afterwards still clicks (silently,
    /// beside the thumb).
    @Test(arguments: [30.0, 40, 50, 60, 80])
    func thumbRestingIndexTap(threshold: Double) {
        let p = Performer(rig: TestRig(threshold: threshold))
        p.hold([Self.thumb], for: 0.9)
        p.tap(id: 1, x: 0.51, others: [Self.thumb], frames: 18)
        p.hold([Self.thumb], for: 0.21)
        let down = p.rig.nativeDown()
        p.hold([Self.thumb], for: 0.01)
        let up = p.rig.nativeUp()
        #expect(!down && !up, "macOS's tap click must reach apps")
        #expect(p.events.isEmpty, "\(p.report())")

        p.hold([Self.thumb], for: 0.8)
        for pressure in Press(peak: min(threshold * 1.4, 85), holdFrames: 5).curve {
            p.frame([Self.thumb, Contact(id: 1, x: 0.5, y: 0.5, pressure: pressure)], pointer: 1, native: .none)
        }
        p.hold([Self.thumb], for: 0.1)
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "a press after the tap still clicks\n\(p.report())")
        #expect(p.hapticCount == 0, "\(p.report())")
    }

    /// Double tap to select a word: macOS posts the first tap's click
    /// as the second finger lands (13–28 ms in), then the second
    /// click with its up ~30 ms after the second lift. The first
    /// click's up never reached the event tap in the recording. Both
    /// pass, nothing is held, nothing vibrates — and a press a while
    /// later is an ordinary click again.
    @Test(arguments: [true, false])
    func doubleTapSelectsWord(firstUpArrives: Bool) {
        let p = Performer(rig: TestRig(threshold: 50))
        p.tap(frames: 7)
        p.wait(0.1)
        p.frame([Contact(id: 1, x: 0.5, y: 0.5, pressure: 2)], pointer: 1, native: .none)
        p.frame([Contact(id: 1, x: 0.5, y: 0.5, pressure: 8)], pointer: 1, native: .none)
        var passed = [!p.rig.nativeDown()]
        if firstUpArrives { passed.append(!p.rig.nativeUp()) }
        p.tap(frames: 3)
        p.wait(0.027)
        passed.append(!p.rig.nativeDown())
        p.wait(0.004)
        passed.append(!p.rig.nativeUp())
        #expect(passed.allSatisfy { $0 }, "every tap-click event must reach apps: \(passed)")
        #expect(p.events.isEmpty, "\(p.report())")
        #expect(!p.engine.buttonDown, "the second tap must not leave a button held")

        p.wait(0.8)
        p.perform(.click(Press(peak: 70)))
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.map(\.clickState) == [1], "\(p.report())")
        #expect(p.hapticCount == 2)
    }

    /// Triple tap: three tap clicks, all macOS's.
    @Test func tripleTap() {
        let p = Performer(rig: TestRig(threshold: 50))
        var passed: [Bool] = []
        p.tap(frames: 7)
        for _ in 0 ..< 2 {
            p.wait(0.1)
            p.frame([Contact(id: 1, x: 0.5, y: 0.5, pressure: 3)], pointer: 1, native: .none)
            p.frame([Contact(id: 1, x: 0.5, y: 0.5, pressure: 7)], pointer: 1, native: .none)
            passed.append(!p.rig.nativeDown())
            p.tap(frames: 4)
        }
        p.wait(0.025)
        passed.append(!p.rig.nativeDown())
        passed.append(!p.rig.nativeUp())
        #expect(passed.allSatisfy { $0 }, "\(passed)")
        #expect(p.events.isEmpty, "\(p.report())")
        #expect(!p.engine.buttonDown)
    }

    /// Tap, then tap-rest-and-slide (macOS's tap and drag, selecting
    /// text): macOS holds its button from the second landing; the
    /// dragged events and the final up are all macOS's. Pressing
    /// past the threshold mid-drag must not add a click of ours.
    @Test(arguments: [20.0, 75])
    func tapAndDragSelectsText(peakDuringDrag: Double) {
        let p = Performer(rig: TestRig(threshold: 50))
        p.tap(frames: 8)
        p.wait(0.1)
        p.frame([Contact(id: 1, x: 0.48, y: 0.65, pressure: 0)], pointer: 1, native: .none)
        var passed = [!p.rig.nativeDown()]
        var swallowedMoves = 0
        for i in 0 ..< 160 {
            let x = 0.48 - 0.13 * Double(i) / 160
            let pressure = 8 + (peakDuringDrag - 8) * sin(Double(i) / 160 * .pi)
            p.frame([Contact(id: 1, x: x, y: 0.65, pressure: pressure)], pointer: nil, native: .none)
            if p.rig.move(to: ClickPoint(x: 500 - Double(i) * 0.8, y: 400), dragging: true) { swallowedMoves += 1 }
        }
        p.lift()
        passed.append(!p.rig.nativeUp())
        #expect(passed.allSatisfy { $0 }, "\(passed)")
        #expect(swallowedMoves == 0)
        #expect(p.events.isEmpty, "\(p.report())")
        #expect(!p.engine.buttonDown)
    }

    /// A quick light press past the threshold is our click — and, with
    /// Tap to click live, macOS may count it as a tap and post a click
    /// of its own as the next finger lands. That duplicate is
    /// swallowed with its up: one press, one click.
    @Test func lightPressThatMacOSAlsoTaps() {
        let p = Performer(rig: TestRig(threshold: 50))
        p.pressCurve([10, 40, 70, 70, 40, 10])
        p.wait(0.1)
        p.frame([Contact(id: 1, x: 0.5, y: 0.5, pressure: 4)], pointer: 1, native: .none)
        let down = p.rig.nativeDown()
        p.wait(0.004)
        let up = p.rig.nativeUp()
        p.lift()
        #expect(down && up, "macOS's duplicate tap click and its up are swallowed")
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
    }

    /// A tap click whose up never arrives must not block pressure
    /// clicks for longer than half a second.
    @Test func lostTapClickUpDoesNotBlockClicks() {
        let p = Performer(rig: TestRig(threshold: 50))
        p.hold([Self.thumb], for: 0.5)
        p.tap(id: 1, others: [Self.thumb], frames: 10)
        p.hold([Self.thumb], for: 0.2)
        #expect(!p.rig.nativeDown())
        p.hold([Self.thumb], for: 0.6)
        for pressure in Press(peak: 70, holdFrames: 5).curve {
            p.frame([Self.thumb, Contact(id: 1, x: 0.5, y: 0.5, pressure: pressure)], pointer: 1, native: .none)
        }
        p.hold([Self.thumb], for: 0.1)
        p.lift()
        #expect(p.clicks.count == 1, "\(p.report())")
    }

    /// The recorded session itself (threshold 50): a thumb resting
    /// while the index taps, double taps on words, tap-and-drag over
    /// text — 50 s of real touches and the native tap clicks macOS
    /// posted. The build that recorded it answered 20 of those taps
    /// with clicks and vibrations of its own; now there must be none.
    @Test func recordedTapToClickSession() throws {
        let url = try #require(Bundle.module.url(forResource: "tap-to-click-session", withExtension: "jsonl", subdirectory: "Fixtures"))
        let events = try FrameRecorder.readEvents(from: url)
        #expect(events.count > 4_000)
        let result = ReplayDriver.replay(events: events)
        #expect(result.outputs.isEmpty, "\(result.outputs.prefix(12))")
        #expect(!result.engine.buttonDown)
    }
}

@MainActor
private extension Performer {
    func pressCurve(_ curve: [Double]) {
        for pressure in curve { frame([Contact(id: 1, x: 0.5, y: 0.5, pressure: pressure)], pointer: 1, native: .none) }
        lift()
    }
}
