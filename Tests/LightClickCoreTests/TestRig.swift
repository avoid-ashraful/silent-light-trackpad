import XCTest
@testable import LightClickCore

/// Shared mutable clock + cursor for a rig: the engine's injected
/// providers read from here, so a test controls time and cursor
/// position by setting properties between frames.
final class RigClock {
    var time: Double = 1_000
    var cursor = ClickPoint(x: 500, y: 500)
}

/// Records every call the engine makes, as compact strings:
/// `down(1)@500,500`, `up(1)`, `hapticDown`, `hapticUp`.
@MainActor
final class FakeOutput: ClickOutput {
    var log: [String] = []

    func postMouseDown(at point: ClickPoint, clickState: Int) {
        log.append("down(\(clickState))@\(Int(point.x)),\(Int(point.y))")
    }

    func postMouseUp(at point: ClickPoint, clickState: Int) {
        log.append("up(\(clickState))")
    }

    func pulseHaptic(down: Bool) {
        log.append(down ? "hapticDown" : "hapticUp")
    }
}

/// A ClickEngine wired to a fake clock, a fake cursor and a
/// recording output, plus a small DSL for scripting frames.
@MainActor
final class TestRig {
    let clock = RigClock()
    let output = FakeOutput()
    let engine: ClickEngine

    init(threshold: Double = 50, doubleClickInterval: Double = 0.5) {
        let clock = self.clock
        engine = ClickEngine(
            now: { clock.time },
            cursorLocation: { clock.cursor },
            doubleClickInterval: { doubleClickInterval },
            output: output
        )
        engine.threshold = threshold
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

    var log: [String] { output.log }

    func clearLog() {
        output.log = []
    }
}

/// Base class: every engine test runs on the main actor, like the
/// engine itself.
@MainActor
class EngineTestCase: XCTestCase {
    func makeRig(threshold: Double = 50, doubleClickInterval: Double = 0.5) -> TestRig {
        TestRig(threshold: threshold, doubleClickInterval: doubleClickInterval)
    }
}
