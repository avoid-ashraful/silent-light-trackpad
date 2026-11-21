import Foundation
@testable import LightClickCore

// MARK: - What the engine produced, as structured values

/// One call the engine made on its output, with the rig-clock time
/// it happened at. Recorded by `FakeOutput.events`.
enum OutputEvent: Equatable, CustomStringConvertible {
    case down(t: Double, at: ClickPoint, clickState: Int, number: Int)
    case drag(t: Double, at: ClickPoint, clickState: Int, number: Int)
    case up(t: Double, at: ClickPoint, clickState: Int, number: Int)
    case haptic(t: Double, down: Bool)

    var time: Double {
        switch self {
        case let .down(t, _, _, _), let .drag(t, _, _, _), let .up(t, _, _, _), let .haptic(t, _): t
        }
    }

    var description: String {
        func p(_ point: ClickPoint) -> String { "\(Int(point.x.rounded())),\(Int(point.y.rounded()))" }
        return switch self {
        case let .down(t, at, s, n): String(format: "%.3f", t) + " down(state \(s), #\(n))@\(p(at))"
        case let .drag(t, at, s, n): String(format: "%.3f", t) + " drag(state \(s), #\(n))@\(p(at))"
        case let .up(t, at, s, n): String(format: "%.3f", t) + " up(state \(s), #\(n))@\(p(at))"
        case let .haptic(t, d): String(format: "%.3f", t) + (d ? " hapticDown" : " hapticUp")
        }
    }
}

/// One synthetic press as the rest of the system sees it: a
/// mouse-down, the dragged events posted while it was held, and its
/// mouse-up (nil while still held).
struct ClickRecord: CustomStringConvertible {
    var clickState: Int
    var number: Int
    var downAt: Double
    var downPoint: ClickPoint
    var drags: [ClickPoint] = []
    var upAt: Double?
    var upPoint: ClickPoint?

    /// How far the cursor travelled between the down and the up (or
    /// the last dragged event), in screen pixels.
    var travel: Double {
        guard let end = upPoint ?? drags.last else { return 0 }
        return hypot(end.x - downPoint.x, end.y - downPoint.y)
    }

    /// A press that moved more than 5 px while held: apps treat it
    /// as a drag (tab rearrange, text selection, file move).
    var isDrag: Bool { travel > 5 }
    var duration: Double? { upAt.map { $0 - downAt } }

    var description: String {
        "click(state \(clickState), #\(number), \(drags.count) drags, travel \(Int(travel)) px"
            + (duration.map { String(format: ", held %.3f s)", $0) } ?? ", STILL HELD)")
    }
}

/// Fold an output-event stream into presses. Malformed streams
/// (orphan ups, double downs) are reported by `Invariants`, not here;
/// this just makes a best effort.
func clickRecords(_ events: [OutputEvent]) -> [ClickRecord] {
    var records: [ClickRecord] = []
    var open: Int?
    for event in events {
        switch event {
        case let .down(t, at, s, n):
            records.append(ClickRecord(clickState: s, number: n, downAt: t, downPoint: at))
            open = records.count - 1
        case let .drag(_, at, _, _):
            if let open { records[open].drags.append(at) }
        case let .up(t, at, _, _):
            if let index = open {
                records[index].upAt = t
                records[index].upPoint = at
            }
            open = nil
        case .haptic:
            break
        }
    }
    return records
}

// MARK: - Rules that must hold after ANY input

/// Properties of the output stream that no input sequence may ever
/// break. Each returns human-readable violations (empty = OK), so a
/// fuzz failure prints exactly what went wrong.
enum Invariants {
    /// Check the stream produced so far.
    /// - `doubleClickInterval`: the rig's interval, for chain rules.
    /// - `settled`: true when every finger has lifted and the stream
    ///   is complete — then no press may still be held.
    static func check(
        _ events: [OutputEvent],
        doubleClickInterval: Double,
        settled: Bool
    ) -> [String] {
        var problems: [String] = []
        var open: (state: Int, number: Int, at: ClickPoint, t: Double)?
        var lastNumber = 0
        var lastTime = -Double.infinity
        var previousDown: (state: Int, at: ClickPoint, t: Double)?

        for (i, event) in events.enumerated() {
            let here = "event \(i) [\(event)]"
            if event.time < lastTime { problems.append("\(here): time went backwards") }
            lastTime = event.time

            // Haptics are welded to button transitions: one pulse
            // right after each down / up, never anywhere else.
            if case let .haptic(_, down) = event {
                let previous = i > 0 ? events[i - 1] : nil
                switch (down, previous) {
                case (true, .down?), (false, .up?): break
                default: problems.append("\(here): haptic not directly after a matching \(down ? "down" : "up")")
                }
                continue
            }
            if case .down = event {
                if i + 1 >= events.count || events[i + 1] != .haptic(t: event.time, down: true) {
                    problems.append("\(here): down without its hapticDown")
                }
            }
            if case .up = event {
                if i + 1 >= events.count || events[i + 1] != .haptic(t: event.time, down: false) {
                    problems.append("\(here): up without its hapticUp")
                }
            }

            switch event {
            case let .down(t, at, state, number):
                if open != nil { problems.append("\(here): down while a press is already held (double down)") }
                if number <= lastNumber { problems.append("\(here): event number \(number) not above previous \(lastNumber)") }
                lastNumber = number
                // Click chain (double/triple click): state must be
                // previous+1 exactly when the press is within the
                // interval and 5 px of the previous press, else 1.
                var expected = 1
                if let prev = previousDown,
                   t - prev.t <= doubleClickInterval,
                   pow(at.x - prev.at.x, 2) + pow(at.y - prev.at.y, 2) <= 25 {
                    expected = prev.state + 1
                }
                if state != expected { problems.append("\(here): click state \(state), expected \(expected)") }
                previousDown = (state, at, t)
                open = (state, number, at, t)
            case let .drag(_, _, state, number):
                guard let held = open else {
                    problems.append("\(here): dragged event with no press held")
                    continue
                }
                if number != held.number { problems.append("\(here): drag carries #\(number), press is #\(held.number)") }
                if state != held.state { problems.append("\(here): drag carries state \(state), press is \(held.state)") }
            case let .up(_, _, state, number):
                guard let held = open else {
                    problems.append("\(here): up with no press held (orphan up)")
                    continue
                }
                if number != held.number { problems.append("\(here): up carries #\(number), press is #\(held.number)") }
                if state != held.state { problems.append("\(here): up carries state \(state), press is \(held.state)") }
                open = nil
            case .haptic:
                break
            }
        }
        if settled, let held = open {
            problems.append("press #\(held.number) still held after every finger lifted (stuck button)")
        }
        return problems
    }
}

// MARK: - Deterministic randomness

/// SplitMix64: tiny, fast, and the same sequence on every machine,
/// so a fuzz failure reproduces from its seed alone.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - The simulated hand + macOS

/// One finger (or palm) on the glass in a single frame.
struct Contact: Equatable, CustomStringConvertible {
    var id: Int32
    var x: Double
    var y: Double
    var pressure: Double
    /// Contact ellipse major axis, mm: ~10 fingertip, 12–14 thumb,
    /// 25+ palm (the engine ignores ≥ 20 unless already tracked).
    var major: Double = 10

    var sample: TouchSample { TouchSample(id: id, x: x, y: y, pressure: pressure, majorAxis: major) }
    var description: String { String(format: "f%d(%.2f,%.2f p%.0f%@)", id, x, y, pressure, major >= 20 ? " palm" : "") }
}

/// How macOS's own (native, force-sensor) click behaves for a
/// frame. The app disables tap-to-click and keeps native clicks
/// from reaching apps by swallowing them in its event tap, so the
/// only native events the engine sees are left-mouse-down/up when a
/// press gets hard enough, and mouse-moved/dragged as the cursor
/// moves.
enum NativeButton {
    /// Decide from the contacts: a left click when the strongest
    /// contact crosses `nativeThreshold` and it is the only finger
    /// pressing; a two-finger press is macOS's secondary click,
    /// which posts right-mouse events the app never sees.
    case auto
    /// macOS posts no left-button event for this frame's press.
    case none
}

/// Drives a `TestRig` like a real hand on a real Mac: feeds touch
/// frames at the trackpad's frame rate, moves the cursor (and sends
/// the native mouse-moved / dragged events the event tap sees) when
/// a pointing finger slides, and fires macOS's native left click
/// when a press gets hard enough — before or after the touch frame,
/// as configured. It also checks the native-event contract: every
/// native press the engine swallows must have its release swallowed
/// too, and vice versa.
@MainActor
final class Performer {
    let rig: TestRig
    /// Seconds between touch frames (~120 Hz).
    var frameDT = 0.008
    /// Pressure (app units) at which macOS's own click fires. The
    /// macOS "Light" setting measures at roughly 90 here.
    var nativeThreshold = 90.0
    /// Cursor pixels per unit of pad travel.
    var padToScreen = 1_000.0
    /// What the performer did, in order — printed on failures.
    private(set) var trace: [String] = []
    /// Native-event contract violations (see class doc).
    private(set) var nativeProblems: [String] = []

    private var lastContacts: [Int32: Contact] = [:]
    private var nativeLeftDown = false
    private var nativeDownSwallowed = false
    /// Native left presses that reached apps while a finger was on
    /// the glass — each is an extra click on top of the engine's.
    private(set) var leakedNativePresses = 0

    init(rig: TestRig) { self.rig = rig }

    var engine: ClickEngine { rig.engine }
    var events: [OutputEvent] { rig.output.events }
    var clicks: [ClickRecord] { clickRecords(events) }
    var cursor: ClickPoint { rig.clock.cursor }

    func note(_ text: String) { trace.append(String(format: "%.3f ", rig.clock.time) + text) }

    /// Feed one frame.
    /// - `pointer`: the finger whose travel moves the cursor this
    ///   frame (nil for scrolls/swipes/pinches — the cursor stays).
    /// - `native`: native-click model (see `NativeButton`).
    /// - `nativeFirst`: when the native press fires on this frame,
    ///   deliver it BEFORE the frame (a fast jab winning the race).
    func frame(_ contacts: [Contact], pointer: Int32? = nil, native: NativeButton = .auto, nativeFirst: Bool = false) {
        // Decide the native button transition for this frame.
        var wantDown = nativeLeftDown
        if case .auto = native {
            let strongest = contacts.filter { $0.major < 20 }.map(\.pressure).max() ?? 0
            let pressingFingers = contacts.filter { $0.major < 20 && $0.pressure >= 25 }.count
            if !nativeLeftDown {
                wantDown = strongest >= nativeThreshold && pressingFingers <= 1
            } else {
                wantDown = strongest >= nativeThreshold * 0.6
            }
        } else {
            wantDown = false
        }
        if contacts.isEmpty { wantDown = false }

        if nativeFirst, wantDown, !nativeLeftDown { nativeDownNow() }

        note("frame " + (contacts.isEmpty ? "[lifted]" : contacts.map(\.description).joined(separator: " ")))
        rig.frame(contacts.map(\.sample))

        // Cursor: the pointing finger's travel moves it, and the
        // event tap sees a native moved/dragged event.
        if let pointer, let now = contacts.first(where: { $0.id == pointer }), let before = lastContacts[pointer] {
            let dx = (now.x - before.x) * padToScreen
            let dy = (now.y - before.y) * padToScreen
            if dx != 0 || dy != 0 {
                let target = ClickPoint(x: cursor.x + dx, y: cursor.y + dy)
                note(String(format: "native move → %.0f,%.0f", target.x, target.y))
                rig.move(to: target)
            }
        }

        if wantDown, !nativeLeftDown { nativeDownNow() }
        if !wantDown, nativeLeftDown { nativeUpNow() }

        lastContacts = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
        rig.advance(frameDT)
    }

    private func nativeDownNow() {
        let swallowed = rig.nativeDown()
        note("native leftMouseDown → \(swallowed ? "swallowed" : "PASSED THROUGH")")
        nativeLeftDown = true
        nativeDownSwallowed = swallowed
        if !swallowed, !lastContacts.isEmpty { leakedNativePresses += 1 }
    }

    private func nativeUpNow() {
        let swallowed = rig.nativeUp()
        note("native leftMouseUp → \(swallowed ? "swallowed" : "passed through")")
        if swallowed != nativeDownSwallowed {
            nativeProblems.append(String(
                format: "%.3f: native down was %@ but its up was %@ (apps see an unpaired button event)",
                rig.clock.time,
                nativeDownSwallowed ? "swallowed" : "passed through",
                swallowed ? "swallowed" : "passed through"
            ))
        }
        nativeLeftDown = false
    }

    /// All fingers off the glass.
    func lift() { frame([]) }

    /// Nothing on the glass for `seconds` (no frames arrive).
    func wait(_ seconds: Double) {
        note(String(format: "wait %.3f s", seconds))
        rig.advance(seconds)
    }

    /// An external mouse (or other input source) clicks: native
    /// down and up with no touch behind them. Returns whether each
    /// was swallowed (both must be false for a real mouse).
    @discardableResult
    func externalMouseClick(holdFor seconds: Double = 0.08) -> (down: Bool, up: Bool) {
        let down = rig.nativeDown()
        rig.advance(seconds)
        let up = rig.nativeUp()
        note("external mouse click → down \(down ? "swallowed" : "passed"), up \(up ? "swallowed" : "passed")")
        return (down, up)
    }

    /// External mouse movement (no touch): the cursor moves; the
    /// event tap sees a moved event.
    func externalMouseMove(to point: ClickPoint) {
        note(String(format: "external mouse move → %.0f,%.0f", point.x, point.y))
        rig.move(to: point)
    }

    /// Every invariant violation so far, including native pairing.
    /// `settled` defaults to "the last frame had no fingers".
    func violations(settled: Bool? = nil) -> [String] {
        let settled = settled ?? lastContacts.isEmpty
        var problems = Invariants.check(events, doubleClickInterval: rig.doubleClickInterval, settled: settled)
        if settled, engine.buttonDown { problems.append("engine still reports buttonDown after every finger lifted") }
        if settled, engine.isLocked { problems.append("engine still locked after every finger lifted") }
        return problems + nativeProblems
    }

    /// A failure report: the violations, the output stream and the
    /// performed trace (last `limit` lines).
    func report(_ extra: [String] = [], limit: Int = 120) -> String {
        let v = violations() + extra
        return (["violations:"] + v.map { "  " + $0 }
            + ["output:"] + events.map { "  \($0)" }
            + ["trace (last \(limit)):"] + trace.suffix(limit).map { "  " + $0 }).joined(separator: "\n")
    }
}
