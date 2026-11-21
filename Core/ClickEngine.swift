import Foundation

/// The click-decision engine: touch frames and native mouse events
/// in, click actions out (through `ClickOutput`). This is the whole
/// behavioural core of Silent Light Trackpad, deliberately free of
/// platform APIs — no CGEvent, no OpenMultitouchSupport, no IOKit —
/// so it can be driven frame by frame in tests. Time, cursor
/// position and the system double-click interval are injected
/// providers; the app wires them to the real system, tests wire
/// them to a script.
@MainActor
public final class ClickEngine {
    /// Click threshold in app pressure units. The app persists and
    /// sets this from its menu; tests set it directly.
    public var threshold: Double = 50

    public var onPressureChange: ((Double) -> Void)?

    /// Whether our synthetic button is currently held down.
    public private(set) var buttonDown = false
    /// Whether the engine is locked until every finger lifts (a
    /// multi-finger press was recognised as a two-finger click).
    public var isLocked: Bool { waitForAllFingersToLift }
    /// Whether the current multi-touch sequence has been classified
    /// as a scroll/gesture by the movement gate.
    public private(set) var gestureMoved = false

    private let nowProvider: () -> Double
    private let cursorProvider: () -> ClickPoint
    private let doubleClickIntervalProvider: () -> Double
    private weak var output: ClickOutput?

    private var fingerID: Int32?
    // CLICK COUNT: see clickStateForDown(at:) below.
    private var clickCount = 0
    private var lastClickTime: Double = 0
    private var lastClickLocation = ClickPoint.zero
    private var waitForAllFingersToLift = false
    private var ignoreNativeMouseUpUntil: Double = 0
    // FAST-JAB FIX: last time a touch frame showed a finger on the
    // glass. The native-event handling uses it to tell a native press
    // that came from the trackpad (a touch is, or just was, active)
    // from one that came from an external mouse or another input
    // source (no touch anywhere near).
    private var lastTouchActivityTime: Double = 0
    // When the native-event path itself fired the currently held
    // click (the fast-jab path), the moment it did so; 0 while any
    // held click came from the pressure path. Lets the frame logic
    // tell "this presser owns the held click" apart from "a second
    // finger is chording against a click another finger is holding".
    private var tapFiredDownAt: Double = 0
    // DRAG LATCH: where the cursor was when the current click
    // fired, and whether the held click has moved far enough to
    // count as a drag (see handlePress). A latched drag releases
    // only at near-zero pressure or when every finger lifts.
    private var dragOrigin: ClickPoint?
    public private(set) var dragLatched = false
    // DRAG EVENT NUMBER: macOS treats a mouse-down / dragged /
    // mouse-up sequence as ONE drag only when every event in it
    // carries the same kCGMouseEventNumber (Chromium's remoting
    // injector documents the same requirement: mismatched numbers
    // and window dragging silently stops being a drag). A real
    // press gets one number from the hardware for its whole
    // sequence; a synthetic press must assign its own. The counter
    // increments once per press; the active press's number is
    // stamped on its down, every dragged event and its up.
    private var eventSequence = 0
    private var activeEventNumber = 0
    // SCROLL/GESTURE GATE: state for telling a two-finger
    // scroll/gesture apart from a press with a resting finger.
    // Anchors remember where each touch was when the current
    // multi-touch sequence began; if any finger travels from its
    // anchor, the sequence is a scroll/gesture (gestureMoved) and
    // clicks are suppressed until every finger lifts. The dwell
    // counter requires a multi-touch press to hold the threshold
    // for a few frames, so the pressure spike of fingers landing to
    // scroll never fires.
    private var activeTouchCount = 0
    private var touchAnchors: [Int32: ClickPoint] = [:]
    private var touchLastPositions: [Int32: ClickPoint] = [:]
    private var dwellFingerID: Int32?
    private var dwellFrames = 0
    private var hardDwellFingerID: Int32?
    private var hardDwellFrames = 0
    // SCROLL/GESTURE GATE: fingers that have travelled in the
    // current multi-touch sequence. Only two or more moving fingers
    // make a scroll/gesture; one finger moving while the others stay
    // put is pointing with a resting thumb (see updateGestureGate).
    private var movedFingers: Set<Int32> = []
    // TWO-FINGER CLICK: each finger's recent pressure readings
    // (engine time, pressure), kept for ~0.12 s, to tell a finger
    // that is pressing right now from one that is merely resting.
    private var pressureHistory: [Int32: [(t: Double, p: Double)]] = [:]
    // MULTI-FINGER TAP: when each finger currently on the glass first
    // touched down (engine time).
    private var touchLandedAt: [Int32: Double] = [:]
    // The fingers of the frame being processed (palms filtered out).
    private var currentFingers: [TouchSample] = []
    // SILENT CLICK: the held press was made while another finger
    // rested on the glass — it posts no haptic, down or up.
    private var silentPress = false
    // DOUBLE-TAP HOLD: when a double (or later) click's press eased
    // off while its finger stayed on the glass; nil otherwise.
    private var doubleTapHoldSince: Double?

    public init(
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        cursorLocation: @escaping () -> ClickPoint = { .zero },
        doubleClickInterval: @escaping () -> Double = { 0.5 },
        output: ClickOutput? = nil
    ) {
        nowProvider = now
        cursorProvider = cursorLocation
        doubleClickIntervalProvider = doubleClickInterval
        self.output = output
    }

    public func setOutput(_ output: ClickOutput?) {
        self.output = output
    }

    // MARK: - Touch frames

    /// Process one frame of active touches (already filtered to
    /// active states by the platform layer; an empty array ends the
    /// current touch session).
    public func processFrame(_ touches: [TouchSample]) {
        // PALM REJECTION (matching native): macOS filters contacts
        // by size before anything else — a palm or the heel of a
        // hand is not a finger: it must not press, count as a
        // resting finger, or feed the gesture gate. The contact
        // ellipse's major axis is in millimetres; a firm fingertip
        // measures ~10 mm, so 20 mm is twice a finger and still
        // below a palm. The currently tracked finger is exempt — a
        // pressing finger flattens and its ellipse grows, and an
        // in-flight click must never be reclassified away mid-press.
        let fingers = touches.filter { $0.id == fingerID || $0.majorAxis < 20 }

        activeTouchCount = fingers.count
        currentFingers = fingers
        updatePressureHistory(fingers)
        updateGestureGate(fingers)

        if !fingers.isEmpty {
            lastTouchActivityTime = nowProvider()
        }

        if fingers.isEmpty {
            finishSequence()
            waitForAllFingersToLift = false
            return
        }

        guard !waitForAllFingersToLift else { return }

        // TWO-FINGER CLICK (from the scenario suite): real fingers
        // land light and press together, so by the time either is
        // over half the threshold one of them is already tracked,
        // and the "nobody tracked" lock below was never reached —
        // the tracked finger fired a LEFT click on top of macOS's
        // own secondary click. So, whenever no click is held: two or
        // more fingers pressing at the same moment is a two-finger
        // click — lock until every finger lifts. "Pressing" means
        // at least half the threshold AND risen by a quarter of the
        // threshold (12 units at least) within the last ~0.12 s: a
        // resting thumb holds
        // steady (even above half the threshold at low presets), a
        // co-pressing finger climbs.
        if !buttonDown, fingers.filter({ isCoPressing($0) }).count >= 2 {
            if fingerID != nil { resetSequence() }
            waitForAllFingersToLift = true
            return
        }

        // RESTING-FINGER SUPPORT (from the native-behaviour audit):
        // the original app demanded exactly ONE active touch — with
        // a thumb or second finger merely resting on the glass,
        // pressing with another finger produced no click at all and
        // locked input until every finger lifted. Native trackpads
        // click fine in that posture. So: follow ONE tracked finger
        // (the presser) and ignore the rest, with two safeguards —
        //  * two fingers pressing together is a two-finger click
        //    (native secondary click): never answer it with a left
        //    click; lock until all fingers lift;
        //  * a second finger pressing while our click is already
        //    down is the same chord: release ours and lock — unless
        //    the held click is the tap-fired one and belongs to
        //    that finger.
        // A second finger that only rests (low pressure) never
        // disturbs an ongoing click or drag.
        if let fingerID, let tracked = fingers.first(where: { $0.id == fingerID }) {
            if let presser = fingers.first(where: { $0.id != fingerID && max(0, $0.pressure) >= threshold }) {
                if buttonDown, nowProvider() - tapFiredDownAt > 0.1 {
                    // A second finger pressing while a pressure-path
                    // click is held: a chord — release ours and lock.
                    releaseButtonIfNeeded()
                    resetSequence()
                    waitForAllFingersToLift = true
                } else {
                    // No click down: the watched finger turned out
                    // to be the resting one — hand tracking to the
                    // presser. Or the held click is the tap-fired
                    // one (fast jab) and belongs to this very
                    // presser, the watched finger being a resting
                    // one: the presser owns the click — hand
                    // tracking over and keep it down, so a jab with
                    // a thumb resting can still hold and drag.
                    self.fingerID = presser.id
                    handlePress(presser)
                }
                return
            }
            handlePress(tracked)
            return
        }

        if fingerID != nil {
            // The tracked finger lifted while other (resting) touches
            // remain. End its sequence WITHOUT locking — a remaining
            // finger may still press on its own.
            releaseButtonIfNeeded()
            resetSequence()
        }

        // Nobody is tracked: two or more fingers already pressing
        // together means a two-finger click — lock, don't left-click.
        let pressing = fingers.filter { max(0, $0.pressure) >= threshold * 0.5 }
        if pressing.count > 1 {
            // Release first: a tap-fired click (fast jab landing as
            // another finger also presses) can be held at this point,
            // and the lock makes processFrame() ignore frames until
            // every finger lifts — never lock with the button down,
            // or the click would stay held for the whole lock.
            releaseButtonIfNeeded()
            waitForAllFingersToLift = true
            return
        }

        // Watch the strongest touch; resting fingers sit at low
        // pressure, so the one that presses stands out.
        guard let candidate = fingers.max(by: { max(0, $0.pressure) < max(0, $1.pressure) }) else { return }
        fingerID = candidate.id
        handlePress(candidate)
    }

    // MARK: - Native mouse events (the event-tap decisions)

    /// A native left-mouse-down reached the event tap. Returns true
    /// when the event must be swallowed (it is the trackpad's own
    /// press, or a duplicate of ours); false when it belongs to
    /// another input source and must pass through untouched.
    public func handleNativeMouseDown() -> Bool {
        if buttonDown {
            // Our click is already down — the usual order, since the
            // light pressure click fires before the finger reaches
            // Apple's heavier native threshold. Swallow the native
            // press so one press stays one click.
            return true
        }
        if nowProvider() - lastTouchActivityTime <= 0.15 {
            // FAST-JAB FIX: a fast, hard jab can cross Apple's native
            // threshold before the next pressure frame is processed,
            // so the native click wins the race against the touch
            // stream and slips through as a real click — followed a
            // frame later by ours: one jab, two clicks. A native
            // press while a trackpad touch is active IS that press:
            // swallow it and answer with our own click right now —
            // the same click the pressure path posts, haptic and
            // click count included. (Unless the engine is locked for
            // a multi-finger press; then just swallow.) No recent
            // touch means an external mouse or another input source —
            // not ours; pass it through. And never answer during a
            // classified scroll/gesture: a native press surfacing
            // mid-scroll is swallowed, not converted into our click.
            if !waitForAllFingersToLift, !gestureMoved {
                fireButtonDown(fromTap: true)
            }
            return true
        }
        return false
    }

    /// A native left-mouse-up reached the event tap. Returns true
    /// when it must be swallowed: it pairs with a held synthetic
    /// click, or it is the native echo of a click we just released.
    public func handleNativeMouseUp() -> Bool {
        buttonDown || nowProvider() < ignoreNativeMouseUpUntil
    }

    /// A native mouse-moved or left-mouse-dragged event reached
    /// the event tap. While our synthetic button is held, the
    /// movement belongs to our press: returns true (the platform
    /// layer swallows the native event) and posts our own dragged
    /// event in its place — a first-class event built exactly like
    /// our down/up, carrying the press's click state and event
    /// number. (The original app instead mutated the moved event's
    /// type in the tap; the mutated event kept the hardware
    /// movement's own event number and a click state of 0, so the
    /// sequence's numbers never matched the down's and macOS did
    /// not treat it as a single drag — tab drags in Chromium
    /// browsers and window drags in Mission Control silently never
    /// started, while AppKit drag sessions, which the window
    /// server drives itself once initiated, survived.) With no
    /// button held, returns false and the event passes untouched.
    public func handleNativeMouseMove(at point: ClickPoint) -> Bool {
        guard buttonDown else { return false }
        output?.postMouseDragged(
            at: point,
            clickState: max(clickCount, 1),
            eventNumber: activeEventNumber
        )
        return true
    }

    // MARK: - Lifecycle

    /// Stop semantics for the decision state: release any held
    /// click and clear every sequence, lock and gate. (The platform
    /// layer handles its own teardown — event tap, touch stream —
    /// separately.)
    public func reset() {
        releaseButtonIfNeeded()
        dragLatched = false
        dragOrigin = nil
        resetSequence()
        waitForAllFingersToLift = false
        touchAnchors = [:]
        touchLastPositions = [:]
        gestureMoved = false
        dwellFingerID = nil
        dwellFrames = 0
        hardDwellFingerID = nil
        hardDwellFrames = 0
        activeTouchCount = 0
        movedFingers = []
        pressureHistory = [:]
        touchLandedAt = [:]
        currentFingers = []
    }

    // MARK: - Gesture gate

    /// SCROLL/GESTURE GATE bookkeeping, run on every frame before
    /// any click logic: anchor each touch when it joins a
    /// multi-touch sequence, and mark a finger as moved once it has
    /// travelled ~2 mm from its anchor (0.02 in the trackpad's
    /// normalised coordinates) or ~1.2 mm in a single frame — a
    /// flick's speed gives it away before its travel does. The
    /// sequence is a scroll/gesture once TWO or more fingers have
    /// moved: scrolls, swipes, pinches and rotations move every
    /// finger, while one finger moving with the others still is
    /// pointing (or dragging) with a resting thumb, which macOS
    /// treats as ordinary pointing — the original rule (any one
    /// finger moving) killed every light click after the index
    /// moved the cursor while a thumb rested, until the thumb
    /// lifted. The classification sticks until every finger lifts —
    /// a finger that keeps gliding after the other one leaves is
    /// still scrolling, not pressing.
    private func updateGestureGate(_ active: [TouchSample]) {
        if active.isEmpty {
            touchAnchors = [:]
            touchLastPositions = [:]
            movedFingers = []
            gestureMoved = false
            dwellFingerID = nil
            dwellFrames = 0
            hardDwellFingerID = nil
            hardDwellFrames = 0
            return
        }
        let ids = Set(active.map(\.id))
        movedFingers = movedFingers.intersection(ids)
        // RESTING FINGERS OUTLAST A GESTURE: once every finger that
        // moved has lifted, the fingers still down never moved —
        // a thumb resting through a scroll. The scroll is over; they
        // must not keep it alive (light clicks stayed dead until the
        // thumb lifted). A finger that moved and is still down keeps
        // the classification: it is still gliding.
        if gestureMoved, movedFingers.isEmpty {
            gestureMoved = false
            hardDwellFingerID = nil
            hardDwellFrames = 0
        }
        guard active.count >= 2 else {
            // A lone finger is never a gesture by itself. Forget the
            // anchors so the next multi-touch sequence anchors fresh:
            // a stale position for a lifted (or since-moved) touch
            // would read as a jump the moment a second finger lands —
            // and touch IDs are reused (a reused ID's old spot looked
            // like a flick, killing the click).
            touchAnchors = [:]
            touchLastPositions = [:]
            return
        }
        touchAnchors = touchAnchors.filter { ids.contains($0.key) }
        touchLastPositions = touchLastPositions.filter { ids.contains($0.key) }
        for touch in active {
            // VELOCITY TRIGGER: per-frame displacement of this finger.
            if let last = touchLastPositions[touch.id] {
                let vx = touch.x - last.x
                let vy = touch.y - last.y
                if vx * vx + vy * vy > 0.000144 {
                    movedFingers.insert(touch.id)
                }
            }
            touchLastPositions[touch.id] = ClickPoint(x: touch.x, y: touch.y)

            if let anchor = touchAnchors[touch.id] {
                let dx = touch.x - anchor.x
                let dy = touch.y - anchor.y
                if dx * dx + dy * dy > 0.0004 {
                    movedFingers.insert(touch.id)
                }
            } else {
                touchAnchors[touch.id] = ClickPoint(x: touch.x, y: touch.y)
            }
        }
        if movedFingers.count >= 2 {
            gestureMoved = true
        }
    }

    /// TWO-FINGER CLICK / MULTI-FINGER TAP bookkeeping: keep each
    /// finger's readings from the last ~0.12 s and when it landed;
    /// forget lifted fingers.
    private func updatePressureHistory(_ fingers: [TouchSample]) {
        let now = nowProvider()
        let ids = Set(fingers.map(\.id))
        pressureHistory = pressureHistory.filter { ids.contains($0.key) }
        touchLandedAt = touchLandedAt.filter { ids.contains($0.key) }
        for finger in fingers {
            if touchLandedAt[finger.id] == nil { touchLandedAt[finger.id] = now }
            var history = pressureHistory[finger.id] ?? []
            history.append((now, max(0, finger.pressure)))
            history.removeAll { now - $0.t > 0.12 }
            pressureHistory[finger.id] = history
        }
    }

    /// Whether `touch` is pressing right now (two-finger click
    /// detection): at least half the threshold, and risen within the
    /// last ~0.12 s by a quarter of the threshold — and by at least
    /// 12 units, since contact readings are absolute: scroll and
    /// resting fingers wobble by up to ~8 units whatever the preset,
    /// which at the lightest presets is more than a quarter of the
    /// threshold.
    private func isCoPressing(_ touch: TouchSample) -> Bool {
        let pressure = max(0, touch.pressure)
        guard pressure >= threshold * 0.5, let history = pressureHistory[touch.id],
              let lowest = history.map(\.p).min() else { return false }
        return pressure - lowest >= max(threshold * 0.25, 12)
    }

    /// MULTI-FINGER TAP: whether `touch` is pressing as part of a
    /// two- or three-finger tap — another finger touched down within
    /// 0.1 s of it, and the press comes within 0.3 s of them landing.
    /// That is macOS's secondary click, look-up and friends, never a
    /// left click. A thumb that was already resting landed long
    /// before the finger that presses; fingers set down together and
    /// left to rest press later than any tap does.
    private func isMultiFingerTap(_ touch: TouchSample) -> Bool {
        guard let landed = touchLandedAt[touch.id] else { return false }
        let now = nowProvider()
        return currentFingers.contains { other in
            guard other.id != touch.id, let otherLanded = touchLandedAt[other.id] else { return false }
            return abs(otherLanded - landed) <= 0.1 && now - max(otherLanded, landed) <= 0.3
        }
    }

    /// Whether a press by the currently handled finger may fire now.
    /// During a classified scroll/gesture: only a sustained hard
    /// press (below). With two or more fingers down and no gesture:
    /// only once the press has held the threshold for 3 frames — a
    /// deliberate press with a resting finger holds; the landing
    /// spike of a scroll crosses and falls back within a frame or
    /// two. Single-finger presses are unaffected and still fire on
    /// the first frame, exactly as before.
    private func clickGateAllowsPress() -> Bool {
        if gestureMoved {
            // HARD-PRESS OVERRIDE (matching native): the native
            // button channel is never vetoed by the gesture layer —
            // press hard enough mid-scroll and a real Mac clicks.
            // Mirror it: a finger holding twice the click threshold
            // for 2 frames is a deliberate press, not scroll load.
            // Ordinary scrolling sustains nothing near that, so
            // accidental scroll clicks stay dead.
            return hardDwellFrames >= 2
        }
        if activeTouchCount >= 2, dwellFrames < 3 { return false }
        return true
    }

    // MARK: - Press handling

    private func handlePress(_ touch: TouchSample) {
        let pressure = max(0, touch.pressure)
        onPressureChange?(pressure)

        // SCROLL/GESTURE GATE: track how long this finger has been
        // pressing at/above the threshold (see clickGateAllowsPress).
        if pressure >= threshold {
            if dwellFingerID == touch.id {
                dwellFrames += 1
            } else {
                dwellFingerID = touch.id
                dwellFrames = 1
            }
        } else if dwellFingerID == touch.id {
            dwellFrames = 0
        }

        // HARD-PRESS OVERRIDE bookkeeping: how long this finger has
        // been pressing at/above twice the threshold (see
        // clickGateAllowsPress).
        if pressure >= threshold * 2 {
            if hardDwellFingerID == touch.id {
                hardDwellFrames += 1
            } else {
                hardDwellFingerID = touch.id
                hardDwellFrames = 1
            }
        } else if hardDwellFingerID == touch.id {
            hardDwellFrames = 0
        }

        // DOUBLE-TAP HOLD, re-press: pressing again while a double
        // click is held by a resting finger is the next click of the
        // chain (triple click) — let the held one go first.
        if buttonDown, doubleTapHoldSince != nil, !dragLatched, pressure >= threshold {
            releaseButtonIfNeeded()
        }

        if !buttonDown, pressure >= threshold, clickGateAllowsPress() {
            if !gestureMoved, activeTouchCount >= 2, isMultiFingerTap(touch) {
                // MULTI-FINGER TAP (from on-device feedback): two or
                // three fingers that touched down together and one
                // of them reached the threshold — a two/three-finger
                // tap or click. macOS never answers that with a left
                // click (or a vibration); lock until every finger
                // lifts. (A classified scroll is exempt: there the
                // only way here is the deliberate hard-press
                // override.)
                resetSequence()
                waitForAllFingersToLift = true
                return
            }
            fireButtonDown()
        }

        // DRAG LATCH: once a held click has actually moved the
        // cursor ~5 px it is a drag, not a click — and a drag must
        // hold like a physical button. A physical button latches:
        // once it clicks, it stays down until the press is nearly
        // fully released; it does not pop back up at the first
        // ease. Sliding a finger sideways rolls the contact, so the
        // capacitive pressure reading dips mid-drag — under the
        // plain 70% release line below, that dip posted mouse-up a
        // fraction of a second into the drag and cancelled it
        // (browser tab drags died outright; Finder drags merely
        // dropped early, which looked like success). So once the
        // cursor has travelled, the drag is latched and only a
        // near-full release — or lifting every finger, which
        // finishSequence already handles — lets go.
        if buttonDown, !dragLatched, let dragOrigin {
            let cursor = cursorProvider()
            let dx = cursor.x - dragOrigin.x
            let dy = cursor.y - dragOrigin.y
            if dx * dx + dy * dy > 25 {
                dragLatched = true
            }
        }

        // SNAPPY RELEASE (from on-device feedback): the original app
        // only released the button when every finger had fully left
        // the glass, so easing off the pressure changed nothing: the
        // click stayed held until the finger was lifted off the
        // trackpad entirely, and felt long and stretched. A real
        // click ends when the press ends. Release as soon as
        // pressure falls back below 70% of the press threshold; the
        // 30% hysteresis band keeps pressure jitter near the
        // threshold from flickering the button. Keeping pressure up
        // still holds the button, so click-hold and click-drag keep
        // working, and pressing again re-clicks (which is also what
        // makes double-clicks possible). The one exception is a
        // latched drag (above): its release line is ~10% of the
        // threshold — near zero — so a pressure dip mid-drag can
        // never let go early.
        if buttonDown, pressure <= (dragLatched ? threshold * 0.1 : threshold * 0.7) {
            // DOUBLE-TAP HOLD (from on-device feedback): "tap, tap,
            // keep the finger resting and slide" selects word by word
            // on macOS. The second click's press eases off at once —
            // the finger only rests — so the snappy release used to
            // let go before the slide began, and the slide just moved
            // the pointer. So a double (or later) click whose finger
            // stays on the glass stays held: sliding turns it into a
            // latched drag (released at lift); lifting releases it;
            // pressing again re-clicks; resting still for 0.8 s lets
            // it go.
            let now = nowProvider()
            if clickCount >= 2, !dragLatched {
                if doubleTapHoldSince == nil { doubleTapHoldSince = now }
                if let since = doubleTapHoldSince, now - since >= 0.8 {
                    releaseButtonIfNeeded()
                }
            } else {
                releaseButtonIfNeeded()
            }
        } else if buttonDown, doubleTapHoldSince != nil, dragLatched {
            // The held double click started sliding: it is a drag now.
            doubleTapHoldSince = nil
        }
    }

    private func finishSequence() {
        // Release unconditionally (releaseButtonIfNeeded
        // self-guards): a tap-fired click can be held while no
        // finger is tracked, and a held click must never outlive its
        // touch session.
        releaseButtonIfNeeded()
        if fingerID != nil { resetSequence() }
    }

    /// Post our synthetic mouse-down and mark the button held.
    /// Shared by the pressure path (handlePress) and the
    /// native-event path's fast-jab handling, so both produce the
    /// identical click: click count, position and the synthetic
    /// haptic. The tap path passes fromTap so the frame logic can
    /// attribute the held click to the finger whose native press
    /// the tap just answered.
    private func fireButtonDown(fromTap: Bool = false) {
        let location = cursorProvider()
        eventSequence += 1
        activeEventNumber = eventSequence
        output?.postMouseDown(
            at: location,
            clickState: clickStateForDown(at: location),
            eventNumber: activeEventNumber
        )
        buttonDown = true
        tapFiredDownAt = fromTap ? nowProvider() : 0
        dragOrigin = location
        dragLatched = false
        doubleTapHoldSince = nil
        // SILENT CLICK (from on-device feedback): with another finger
        // resting on the glass, macOS answers a light tap with a
        // click but no vibration — so a light press made beside a
        // resting finger clicks silently. Physical-strength clicks
        // still pulse, as a real Mac's do: a jab that tripped macOS's
        // own click (the native path) and the hard-press override
        // mid-gesture. Alone on the glass, the synthetic click haptic
        // plays at the light threshold.
        silentPress = !fromTap && !gestureMoved && activeTouchCount >= 2
        if !silentPress {
            output?.pulseHaptic(down: true)
        }
    }

    private func releaseButtonIfNeeded() {
        guard buttonDown else { return }
        output?.postMouseUp(
            at: cursorProvider(),
            clickState: max(clickCount, 1),
            eventNumber: activeEventNumber
        )
        // Release-phase haptic, mirroring a real click's up-stroke
        // (none for a silent click).
        if !silentPress {
            output?.pulseHaptic(down: false)
        }
        silentPress = false
        doubleTapHoldSince = nil
        buttonDown = false
        tapFiredDownAt = 0
        dragLatched = false
        dragOrigin = nil
        ignoreNativeMouseUpUntil = nowProvider() + 0.15
    }

    private func resetSequence() {
        fingerID = nil
        onPressureChange?(0)
    }

    /// CLICK COUNT (from on-device reports): selecting a word on
    /// double-click / a line on triple-click is driven by the
    /// event's click state. macOS computes that itself for real
    /// presses and taps, but NOT for software-posted events — and
    /// the original app never set it, so every synthetic click
    /// arrived as click #1 and a fast double press looked like two
    /// unrelated single clicks. Mirror the system: a press within
    /// the user's double-click interval and a few pixels of the
    /// previous one bumps the count (2 = word, 3 = line); anything
    /// else restarts at 1. The matching mouse-up carries the same
    /// count.
    private func clickStateForDown(at location: ClickPoint) -> Int {
        let now = nowProvider()
        let dx = location.x - lastClickLocation.x
        let dy = location.y - lastClickLocation.y
        let chained = now - lastClickTime <= doubleClickIntervalProvider()
            && dx * dx + dy * dy <= 25
        clickCount = chained ? clickCount + 1 : 1
        lastClickTime = now
        lastClickLocation = location
        return max(clickCount, 1)
    }
}
