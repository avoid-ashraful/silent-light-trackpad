import Foundation
@testable import LightClickCore
#if canImport(XCTest)
import XCTest
#endif

/// Shared mutable clock + cursor for a rig: the engine's injected
/// providers read from here, so a test controls time and cursor
/// position by setting properties between frames.
final class RigClock {
    var time: Double = 1_000
    var cursor = ClickPoint(x: 500, y: 500)
}

/// Records every call the engine makes, as compact strings:
/// `down(1)@500,500`, `drag(1)@520,500`, `up(1)`, `hapticDown`,
/// `hapticUp`. The event number stamped on each posted mouse
/// event is recorded in parallel in `numbers`.
/// `events` keeps the same calls as structured, timestamped values
/// for the scenario kit's analysis (Scenarios/GestureKit.swift).
@MainActor
final class FakeOutput: ClickOutput {
    var log: [String] = []
    var numbers: [Int] = []
    var events: [OutputEvent] = []
    var now: () -> Double = { 0 }

    func postMouseDown(at point: ClickPoint, clickState: Int, eventNumber: Int) {
        log.append("down(\(clickState))@\(Int(point.x)),\(Int(point.y))")
        numbers.append(eventNumber)
        events.append(.down(t: now(), at: point, clickState: clickState, number: eventNumber))
    }

    func postMouseDragged(at point: ClickPoint, clickState: Int, eventNumber: Int) {
        log.append("drag(\(clickState))@\(Int(point.x)),\(Int(point.y))")
        numbers.append(eventNumber)
        events.append(.drag(t: now(), at: point, clickState: clickState, number: eventNumber))
    }

    func postMouseUp(at point: ClickPoint, clickState: Int, eventNumber: Int) {
        log.append("up(\(clickState))")
        numbers.append(eventNumber)
        events.append(.up(t: now(), at: point, clickState: clickState, number: eventNumber))
    }

    func pulseHaptic(down: Bool) {
        log.append(down ? "hapticDown" : "hapticUp")
        events.append(.haptic(t: now(), down: down))
    }
}

/// A ClickEngine wired to a fake clock, a fake cursor and a
/// recording output, plus a small DSL for scripting frames.
@MainActor
final class TestRig {
    let clock = RigClock()
    let output = FakeOutput()
    let engine: ClickEngine

    let doubleClickInterval: Double

    init(threshold: Double = 50, doubleClickInterval: Double = 0.5) {
        let clock = self.clock
        self.doubleClickInterval = doubleClickInterval
        engine = ClickEngine(
            now: { clock.time },
            cursorLocation: { clock.cursor },
            doubleClickInterval: { doubleClickInterval },
            output: output
        )
        engine.threshold = threshold
        output.now = { clock.time }
    }

    /// Build one touch sample. Defaults: centre of the pad, a
    /// fingertip-sized contact (10 mm major axis).
    func touch(
        _ id: Int32,
        _ pressure: Double,
        x: Double = 0.5,
        y: Double = 0.5,
        major: Double = 10
    ) -> TouchSample {
        TouchSample(id: id, x: x, y: y, pressure: pressure, majorAxis: major)
    }

    /// Feed one frame of touches.
    func frame(_ touches: TouchSample...) {
        engine.processFrame(touches)
    }

    func frame(_ touches: [TouchSample]) {
        engine.processFrame(touches)
    }

    /// Feed an empty frame (all fingers lifted).
    func liftAll() {
        engine.processFrame([])
    }

    /// Advance the fake clock (seconds).
    func advance(_ dt: Double) {
        clock.time += dt
    }

    /// A native left-mouse-down reaching the tap; returns true when
    /// the engine says "swallow it".
    @discardableResult
    func nativeDown() -> Bool {
        engine.handleNativeMouseDown()
    }

    @discardableResult
    func nativeUp() -> Bool {
        engine.handleNativeMouseUp()
    }

    /// A native mouse move (or native dragged event) reaching the
    /// tap at a screen point; the rig's cursor moves there too, as
    /// the real cursor would be. Returns true when the engine
    /// swallowed the native event and answered with its own
    /// dragged event.
    @discardableResult
    func move(to point: ClickPoint) -> Bool {
        clock.cursor = point
        return engine.handleNativeMouseMove(at: point)
    }

    var log: [String] { output.log }
    var numbers: [Int] { output.numbers }

    func clearLog() {
        output.log = []
        output.numbers = []
        output.events = []
    }
}

#if canImport(XCTest)
/// Base class: every engine test runs on the main actor, like the
/// engine itself.
@MainActor
class EngineTestCase: XCTestCase {
    func makeRig(threshold: Double = 50, doubleClickInterval: Double = 0.5) -> TestRig {
        TestRig(threshold: threshold, doubleClickInterval: doubleClickInterval)
    }
}
#endif
