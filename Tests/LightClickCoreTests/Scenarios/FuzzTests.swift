import Foundation
import Testing
@testable import LightClickCore

/// Random, realistic usage sessions: sequences of gestures with
/// random parameters and random pauses between them (short pauses
/// let presses chain into double/triple clicks across gestures),
/// at random thresholds. After every gesture the stream must keep
/// every invariant and the gesture must produce what it promises.
///
/// Deterministic: a failure prints its seed and the full gesture
/// list; rerun one seed with `FUZZ_SEED=<seed> ./scripts/test.sh
/// --filter Fuzz`. Raise the session count with `FUZZ_SESSIONS`.
@MainActor
@Suite("Fuzz: random usage sessions")
struct FuzzTests {
    static func randomPress(_ rng: inout SeededRNG, finger: Int32 = 1) -> Press {
        var p = Press(finger: finger)
        p.x = Double.random(in: 0.3 ... 0.7, using: &rng)
        p.y = Double.random(in: 0.3 ... 0.7, using: &rng)
        p.landing = Double.random(in: 4 ... 15, using: &rng)
        p.peak = Double.random(in: 20 ... 160, using: &rng)
        p.rampFrames = Int.random(in: 1 ... 6, using: &rng)
        p.holdFrames = Int.random(in: 0 ... 12, using: &rng)
        p.releaseFrames = Int.random(in: 1 ... 5, using: &rng)
        p.jitter = Bool.random(using: &rng) ? Double.random(in: 0 ... 6, using: &rng) : 0
        p.nativeFirst = p.peak > 90 && Int.random(in: 0 ..< 4, using: &rng) == 0
        return p
    }

    static func randomGesture(_ rng: inout SeededRNG) -> Gesture {
        switch Int.random(in: 0 ..< 15, using: &rng) {
        case 0, 1:
            return .click(randomPress(&rng))
        case 2:
            return .multiClick(count: Int.random(in: 2 ... 4, using: &rng), gap: Double.random(in: 0.04 ... 0.3, using: &rng),
                               press: randomPress(&rng))
        case 3:
            return .point(dx: Double.random(in: -0.3 ... 0.3, using: &rng), dy: Double.random(in: -0.3 ... 0.3, using: &rng),
                          frames: Int.random(in: 3 ... 30, using: &rng), pressure: Double.random(in: 5 ... 20, using: &rng))
        case 4, 5:
            var p = randomPress(&rng)
            p.peak = Double.random(in: 60 ... 150, using: &rng)
            return .drag(press: p, dx: Double.random(in: -0.3 ... 0.3, using: &rng), dy: Double.random(in: -0.2 ... 0.2, using: &rng),
                         frames: Int.random(in: 8 ... 40, using: &rng), dipTo: Double.random(in: 8 ... p.peak, using: &rng))
        case 6:
            return .doubleClickDrag(gap: Double.random(in: 0.05 ... 0.3, using: &rng), dx: Double.random(in: -0.2 ... 0.2, using: &rng),
                                    frames: Int.random(in: 8 ... 30, using: &rng))
        case 7:
            return .thumbHoldIndexDrag(thumbPeak: Double.random(in: 60 ... 120, using: &rng), dx: Double.random(in: -0.25 ... 0.25, using: &rng),
                                       frames: Int.random(in: 8 ... 30, using: &rng))
        case 8, 9:
            let heavy: Double? = Bool.random(using: &rng) ? Double.random(in: 20 ... 75, using: &rng) : nil
            return .scroll(fingers: [2, 2, 2, 3, 4].randomElement(using: &rng)!,
                           dx: Double.random(in: -0.4 ... 0.4, using: &rng), dy: Double.random(in: -0.4 ... 0.4, using: &rng),
                           frames: Int.random(in: 4 ... 30, using: &rng), heavy: heavy, landingSpike: Bool.random(using: &rng))
        case 10:
            return Bool.random(using: &rng)
                ? .pinch(spread: Double.random(in: -0.12 ... 0.25, using: &rng), frames: Int.random(in: 5 ... 25, using: &rng),
                         pressure: Double.random(in: 10 ... 40, using: &rng))
                : .rotate(degrees: Double.random(in: -90 ... 90, using: &rng), frames: Int.random(in: 5 ... 25, using: &rng),
                          pressure: Double.random(in: 10 ... 40, using: &rng))
        case 11:
            return .twoFingerClick(peak: Double.random(in: 40 ... 140, using: &rng), offsetFrames: Int.random(in: 0 ... 2, using: &rng))
        case 12:
            return .restingFingerClick(restPressure: Double.random(in: 4 ... 22, using: &rng), press: randomPress(&rng, finger: 1))
        case 13:
            return .palmRest(palmPressure: Double.random(in: 30 ... 120, using: &rng), frames: Int.random(in: 2 ... 15, using: &rng),
                             fingerPress: Bool.random(using: &rng) ? randomPress(&rng) : nil)
        default:
            return .chordMidClick(secondPeak: Double.random(in: 50 ... 140, using: &rng))
        }
    }

    /// Run one session; returns a failure report, or nil.
    static func runSession(seed: UInt64, gestures count: Int) -> String? {
        var rng = SeededRNG(seed: seed)
        let threshold = [30.0, 40, 50, 60, 80].randomElement(using: &rng)!
        let interval = [0.25, 0.5, 0.8].randomElement(using: &rng)!
        let rig = TestRig(threshold: threshold, doubleClickInterval: interval)
        let performer = Performer(rig: rig)
        var done: [String] = []
        for _ in 0 ..< count {
            // Between gestures: often fast enough to chain clicks.
            let pause = [0.0, 0.05, 0.12, 0.3, 0.6, 1.2].randomElement(using: &rng)!
            if pause > 0 {
                performer.perform(.pause(pause))
                done.append("pause(\(pause))")
            }
            // An external mouse click, sometimes — after a settle
            // pause (see NativeEdgeTests for the sub-150 ms window).
            if Int.random(in: 0 ..< 12, using: &rng) == 0 {
                performer.perform(.pause(0.3))
                performer.perform(.externalMouseClick)
                done.append("pause(0.3) externalMouseClick")
            }
            let gesture = randomGesture(&rng)
            let produced = performer.perform(gesture)
            done.append(gesture.description)
            let problems = performer.violations()
                + expectationProblems(gesture.expectation(threshold: threshold), produced: produced)
            if !problems.isEmpty {
                return "seed \(seed) (threshold \(threshold), double-click interval \(interval)) failed after:\n  "
                    + done.joined(separator: "\n  ") + "\n" + performer.report(problems, limit: 60)
            }
        }
        return nil
    }

    @Test("Random sessions keep every invariant")
    func randomSessions() {
        let env = ProcessInfo.processInfo.environment
        if let one = env["FUZZ_SEED"].flatMap(UInt64.init) {
            let failure = Self.runSession(seed: one, gestures: 12)
            #expect(failure == nil, "\(failure ?? "")")
            return
        }
        let sessions = env["FUZZ_SESSIONS"].flatMap(Int.init) ?? 1_500
        var failures: [String] = []
        for seed in 1 ... UInt64(sessions) {
            if let failure = Self.runSession(seed: seed, gestures: 12) {
                failures.append(failure)
                if failures.count >= 3 { break }
            }
        }
        #expect(failures.isEmpty, "\(failures.count)+ failing sessions; first:\n\(failures.first ?? "")")
    }
}
