import Testing
@testable import LightClickCore

// Behaviour asked for after trying the app on the device:
//  * two/three-finger taps must not click or vibrate;
//  * a light click beside a resting thumb clicks, silently (like a
//    macOS tap);
//  * "tap, tap, keep resting and slide" selects word by word.

private let thresholds: [Double] = [30, 40, 50, 60, 80]

@MainActor private func haptics(_ p: Performer) -> Int {
    p.events.filter { if case .haptic = $0 { true } else { false } }.count
}

@MainActor
private extension Performer {
    /// One frame of `contacts`, the cursor following `pointer`.
    func hold(_ contacts: [Contact], frames: Int, pointer: Int32? = nil, native: NativeButton = .auto) {
        for _ in 0 ..< frames { frame(contacts, pointer: pointer, native: native) }
    }

    /// A light tap/press by finger 1 at (x, 0.5) following `curve`,
    /// beside `others`; the finger stays on the glass afterwards
    /// unless `lift`.
    func pressCurve(_ curve: [Double], x: Double = 0.5, others: [Contact] = [], lift doLift: Bool) {
        for p in curve { frame(others + [Contact(id: 1, x: x, y: 0.5, pressure: p)], pointer: 1) }
        if doLift { frame(others, pointer: nil) }
    }
}

// MARK: - Multi-finger taps

@MainActor
@Suite("On-device feedback: two- and three-finger taps")
struct MultiFingerTapTests {
    /// A two-finger tap: the fingers land up to 24 ms apart, one
    /// reaches past the threshold for a few frames while the other
    /// stays light, the contacts' centres wobble as the pads land.
    /// macOS answers with its own secondary click (no left events);
    /// the app must neither left-click nor vibrate.
    @Test(arguments: thresholds, [0, 1, 2, 3])
    func twoFingerTap(threshold: Double, staggerFrames: Int) {
        let p = Performer(rig: TestRig(threshold: threshold))
        let firm = [0.1, 0.3, 0.5, 0.7, 0.9, 1.0, 1.0, 1.0, 0.6, 0.3].map { 8 + (threshold * 1.4 - 8) * $0 }
        let total = staggerFrames + firm.count
        for i in 0 ..< total {
            let wobble = (i % 2 == 0 ? 0.004 : -0.004)
            var contacts = [Contact(id: 1, x: 0.45 + wobble, y: 0.5, pressure: i < firm.count ? firm[i] : 10)]
            if i >= staggerFrames {
                contacts.append(Contact(id: 2, x: 0.56 - wobble, y: 0.5, pressure: 14 + Double(i % 3) * 3))
            }
            p.frame(contacts, pointer: nil, native: .none)
        }
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.isEmpty, "\(p.report())")
        #expect(haptics(p) == 0, "a two-finger tap must not vibrate\n\(p.report())")
    }

    /// Known limit: when one finger of the tap lands alone and is
    /// already past the threshold before the other touches down
    /// (~30 ms+ apart), it is a one-finger click by the time the
    /// second finger appears — the click and its vibration are
    /// already out. (Unchanged from before; waiting on every
    /// one-finger click to rule this out would add latency.)
    @Test func tapWhoseFirstFingerClicksBeforeTheSecondLands() {
        let p = Performer(rig: TestRig(threshold: 50))
        for (i, k) in [0.3, 0.8, 1.0, 1.0, 1.0, 1.0, 0.6, 0.3].enumerated() {
            var contacts = [Contact(id: 1, x: 0.45, y: 0.5, pressure: 8 + 62 * k)]
            if i >= 4 { contacts.append(Contact(id: 2, x: 0.56, y: 0.5, pressure: 15)) }
            p.frame(contacts, pointer: nil, native: .none)
        }
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        withKnownIssue("A finger that clicks alone before the tap's second finger lands is a one-finger click") {
            #expect(p.clicks.isEmpty, "\(p.report())")
        }
    }

    /// Three-finger tap (look up / data detectors).
    @Test(arguments: thresholds)
    func threeFingerTap(threshold: Double) {
        let p = Performer(rig: TestRig(threshold: threshold))
        for (i, k) in [0.2, 0.5, 0.9, 1.0, 1.0, 1.0, 0.6, 0.2].enumerated() {
            p.frame([
                Contact(id: 1, x: 0.40, y: 0.5, pressure: 10 + 8 * k),
                Contact(id: 2, x: 0.50, y: 0.5 + (i % 2 == 0 ? 0.003 : 0), pressure: 8 + (threshold * 1.3 - 8) * k),
                Contact(id: 3, x: 0.60, y: 0.5, pressure: i == 0 ? 6 : 12 + 6 * k),
            ], pointer: nil, native: .none)
        }
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.isEmpty, "\(p.report())")
        #expect(haptics(p) == 0)
    }

    /// Two fingers set down together and left to rest; a while later
    /// one of them presses: that is a click (silent — a finger rests
    /// beside it), not a tap.
    @Test(arguments: thresholds)
    func fingersSetDownTogetherThenOnePressesLater(threshold: Double) {
        let p = Performer(rig: TestRig(threshold: threshold))
        let other = Contact(id: 2, x: 0.6, y: 0.55, pressure: 13)
        p.hold([Contact(id: 1, x: 0.5, y: 0.5, pressure: 12), other], frames: 50)
        p.pressCurve(Press(peak: min(threshold * 1.4, 85), holdFrames: 4).curve, others: [other], lift: true)
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(haptics(p) == 0)
    }

    /// After a two-finger tap, an ordinary click works (the lock
    /// clears when every finger lifts) and vibrates as usual.
    @Test(arguments: thresholds)
    func ordinaryClickAfterTwoFingerTap(threshold: Double) {
        let p = Performer(rig: TestRig(threshold: threshold))
        for k in [0.2, 0.6, 1.0, 1.0, 1.0, 0.4] {
            p.frame([Contact(id: 1, x: 0.45, y: 0.5, pressure: 8 + (threshold * 1.4 - 8) * k),
                     Contact(id: 2, x: 0.56, y: 0.5, pressure: 15)], pointer: nil, native: .none)
        }
        p.lift()
        p.wait(0.6)
        p.perform(.click(Press(peak: threshold * 1.4)))
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.map(\.clickState) == [1], "\(p.report())")
        #expect(haptics(p) == 2)
    }
}

// MARK: - Silent clicks beside a resting finger

@MainActor
@Suite("On-device feedback: silent click beside a resting thumb")
struct SilentClickTests {
    static let thumb = Contact(id: 9, x: 0.4, y: 0.88, pressure: 13, major: 13)

    /// Thumb resting, index clicks lightly: one click, no vibration.
    @Test(arguments: thresholds)
    func lightClickBesideRestingThumbIsSilent(threshold: Double) {
        let p = Performer(rig: TestRig(threshold: threshold))
        p.hold([Self.thumb], frames: 40)
        p.pressCurve(Press(peak: min(threshold * 1.4, 85), holdFrames: 5).curve, others: [Self.thumb], lift: true)
        p.hold([Self.thumb], frames: 10)
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(haptics(p) == 0, "\(p.report())")
    }

    /// The same click with no thumb on the glass vibrates, press and
    /// release.
    @Test(arguments: thresholds)
    func lightClickAloneVibrates(threshold: Double) {
        let p = Performer(rig: TestRig(threshold: threshold))
        p.pressCurve(Press(peak: threshold * 1.4, holdFrames: 5).curve, lift: true)
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1)
        #expect(haptics(p) == 2)
    }

    /// A double-click beside a resting thumb: both silent, chained.
    @Test(arguments: thresholds)
    func doubleClickBesideRestingThumbIsSilent(threshold: Double) {
        let p = Performer(rig: TestRig(threshold: threshold))
        p.hold([Self.thumb], frames: 40)
        p.pressCurve(Press.quick().curve.map { min($0 * threshold / 50, 85) }, others: [Self.thumb], lift: true)
        p.hold([Self.thumb], frames: 10)
        p.pressCurve(Press.quick().curve.map { min($0 * threshold / 50, 85) }, others: [Self.thumb], lift: true)
        p.hold([Self.thumb], frames: 10)
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.map(\.clickState) == [1, 2], "\(p.report())")
        #expect(haptics(p) == 0)
    }

    /// A hard jab that trips macOS's own click is a physical-strength
    /// click: it still vibrates with a thumb resting, as on a real Mac.
    @Test func jabBesideRestingThumbStillVibrates() {
        let p = Performer(rig: TestRig(threshold: 50))
        p.hold([Self.thumb], frames: 40)
        var fired = false
        for pressure in Press.jab().curve {
            let jab = !fired && pressure >= p.nativeThreshold
            if jab { fired = true }
            p.frame([Self.thumb, Contact(id: 1, x: 0.5, y: 0.5, pressure: pressure)], pointer: 1, nativeFirst: jab)
        }
        p.hold([Self.thumb], frames: 5)
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(haptics(p) == 2, "\(p.report())")
    }
}

// MARK: - Double-tap hold (select word by word)

@MainActor
@Suite("On-device feedback: double-tap, rest and slide")
struct DoubleTapHoldTests {
    /// First tap of a double-tap: light press, lift.
    static func firstTap(_ p: Performer, threshold: Double) {
        p.pressCurve([8, threshold * 0.8, threshold * 1.3, threshold * 1.3, threshold * 0.5, 8], lift: true)
        p.lift()
        p.wait(0.1)
    }

    /// Second tap: light press, then the finger only rests (12).
    static func secondTapThenRest(_ p: Performer, threshold: Double) {
        p.pressCurve([8, threshold * 0.8, threshold * 1.3, threshold * 1.3, threshold * 0.5, 12], lift: false)
    }

    /// Tap, tap, keep the finger resting and slide: the second click
    /// stays held and the slide drags with click state 2 (word-by-word
    /// selection); it lets go when the finger lifts.
    @Test(arguments: thresholds)
    func tapTapRestAndSlideSelectsByWord(threshold: Double) {
        let p = Performer(rig: TestRig(threshold: threshold))
        Self.firstTap(p, threshold: threshold)
        Self.secondTapThenRest(p, threshold: threshold)
        p.hold([Contact(id: 1, x: 0.5, y: 0.5, pressure: 12)], frames: 6, pointer: 1)
        p.slide(finger: 1, from: (0.5, 0.5), by: (0.15, 0), frames: 25, pressure: { _ in 12 })
        let endOfSlide = p.rig.clock.time
        p.lift()
        let clicks = p.clicks
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(clicks.map(\.clickState) == [1, 2], "\(p.report())")
        #expect(clicks.last?.isDrag == true, "\(p.report())")
        #expect((clicks.last?.travel ?? 0) > 120, "\(p.report())")
        #expect((clicks.last?.upAt ?? 0) >= endOfSlide - 1e-9, "released before the finger lifted\n\(p.report())")
    }

    /// An ordinary double-click (the finger lifts right after the
    /// second tap) is unchanged: two clicks, nothing dragged.
    @Test(arguments: thresholds)
    func ordinaryDoubleClickUnchanged(threshold: Double) {
        let p = Performer(rig: TestRig(threshold: threshold))
        Self.firstTap(p, threshold: threshold)
        Self.secondTapThenRest(p, threshold: threshold)
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.map(\.clickState) == [1, 2], "\(p.report())")
        #expect(p.clicks.allSatisfy { !$0.isDrag })
    }

    /// Double-tap, then the finger just rests without moving: the
    /// held click lets go after 0.8 s, never stuck.
    @Test func restingStillLetsGoAfterAWhile() {
        let p = Performer(rig: TestRig(threshold: 50))
        Self.firstTap(p, threshold: 50)
        Self.secondTapThenRest(p, threshold: 50)
        let restStart = p.rig.clock.time
        p.hold([Contact(id: 1, x: 0.5, y: 0.5, pressure: 12)], frames: 150, pointer: 1)
        #expect(!p.engine.buttonDown, "still held after 1.2 s of resting\n\(p.report())")
        let up = p.clicks.last?.upAt ?? 0
        #expect(up - restStart >= 0.7 && up - restStart <= 0.9, "\(p.report())")
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.map(\.clickState) == [1, 2])
    }

    /// Double-tap, rest, then press again without lifting: a triple
    /// click (select the line).
    @Test(arguments: thresholds)
    func tapTapRestPressAgainIsTripleClick(threshold: Double) {
        let p = Performer(rig: TestRig(threshold: threshold))
        Self.firstTap(p, threshold: threshold)
        Self.secondTapThenRest(p, threshold: threshold)
        p.hold([Contact(id: 1, x: 0.5, y: 0.5, pressure: 12)], frames: 3, pointer: 1)
        p.pressCurve([threshold * 0.8, threshold * 1.3, threshold * 1.3, threshold * 0.5, 12], lift: true)
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.map(\.clickState) == [1, 2, 3], "\(p.report())")
    }

    /// A SINGLE tap followed by resting and sliding only moves the
    /// pointer: single clicks keep the snappy release.
    @Test(arguments: thresholds)
    func singleTapThenSlideJustPoints(threshold: Double) {
        let p = Performer(rig: TestRig(threshold: threshold))
        Self.secondTapThenRest(p, threshold: threshold)
        p.slide(finger: 1, from: (0.5, 0.5), by: (0.15, 0), frames: 25, pressure: { _ in 12 })
        p.lift()
        #expect(p.violations().isEmpty, "\(p.report())")
        #expect(p.clicks.count == 1, "\(p.report())")
        #expect(p.clicks.first?.isDrag == false, "\(p.report())")
    }
}
