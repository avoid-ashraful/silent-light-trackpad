@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import OpenMultitouchSupport

@MainActor
final class LightClickEngine {
    static let shared = LightClickEngine()

    static let injectedMarker: Int64 = 0x534C_5450 // "SLTP"

    var threshold: Float {
        didSet { UserDefaults.standard.set(threshold, forKey: "pressureThreshold") }
    }

    var onPressureChange: ((Float) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    var isRunning: Bool {
        listeningTask != nil && eventTap != nil
    }

    private let manager = OMSManager.shared
    private var listeningTask: Task<Void, Never>?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?

    private var fingerID: Int32?
    private var buttonDown = false
    // CLICK COUNT (fork fix): see clickState(for:at:) below.
    private var clickCount = 0
    private var lastClickTime: CFTimeInterval = 0
    private var lastClickLocation = CGPoint.zero
    private var waitForAllFingersToLift = false
    private var ignoreNativeMouseUpUntil: CFTimeInterval = 0
    // FAST-JAB FIX: last time a touch frame showed a finger on the glass.
    // The event tap uses it to tell a native press that came from the
    // trackpad (a touch is, or just was, active) from one that came from
    // an external mouse or another input source (no touch anywhere near).
    private var lastTouchActivityTime: CFTimeInterval = 0
    // When the event tap itself fired the currently held click (the
    // fast-jab path), the moment it did so; 0 while any held click came
    // from the pressure path. Lets the frame logic tell "this presser
    // owns the held click" apart from "a second finger is chording
    // against a click another finger is holding".
    private var tapFiredDownAt: CFTimeInterval = 0

    private init() {
        threshold = UserDefaults.standard.float(forKey: "pressureThreshold")
    }

    func start() -> Bool {
        guard !isRunning else { return true }
        guard installEventTap() else { return false }

        listeningTask = Task { [weak self, manager] in
            for await touches in manager.touchDataStream {
                guard let self else { return }
                self.process(touches)
            }
            guard !Task.isCancelled else { return }
            self?.stop()
        }

        guard manager.startListening() else {
            stop()
            return false
        }
        onStateChange?(true)
        return true
    }

    func stop() {
        releaseButtonIfNeeded()
        listeningTask?.cancel()
        listeningTask = nil
        _ = manager.stopListening()
        if let eventTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventTapSource = nil
        eventTap = nil
        resetSequence()
        waitForAllFingersToLift = false
        onStateChange?(false)
    }

    private func installEventTap() -> Bool {
        let mask = CGEventMask(
            (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.leftMouseUp.rawValue)
                | (1 << CGEventType.mouseMoved.rawValue)
                | (1 << CGEventType.leftMouseDragged.rawValue)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: pointer
        ) else { return false }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func filter(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.injectedMarker {
            return Unmanaged.passUnretained(event)
        }

        if buttonDown, type == .mouseMoved {
            event.type = .leftMouseDragged
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown {
            if buttonDown {
                // Our click is already down — the usual order, since the
                // light pressure click fires before the finger reaches
                // Apple's heavier native threshold. Swallow the native
                // press so one press stays one click.
                return nil
            }
            if CACurrentMediaTime() - lastTouchActivityTime <= 0.15 {
                // FAST-JAB FIX (fork fix): a fast, hard jab can cross
                // Apple's native threshold before the next pressure frame
                // is processed, so the native click wins the race against
                // the touch stream and slips through as a real click —
                // followed a frame later by ours: one jab, two clicks.
                // A native press while a trackpad touch is active IS
                // that press: swallow it and answer with our own click
                // right now — the same event the pressure path posts,
                // haptic and click count included. (Unless the engine is
                // locked for a multi-finger press; then just swallow.)
                // No recent touch means an external mouse or another
                // input source — not ours; fall through and pass it.
                if !waitForAllFingersToLift {
                    fireButtonDown(fromTap: true)
                }
                return nil
            }
        }

        if type == .leftMouseUp,
           buttonDown || CACurrentMediaTime() < ignoreNativeMouseUpUntil {
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func process(_ touches: [OMSTouchData]) {
        let active = touches.filter {
            switch $0.state {
            case .starting, .making, .touching, .breaking: true
            default: false
            }
        }

        if !active.isEmpty {
            lastTouchActivityTime = CACurrentMediaTime()
        }

        if active.isEmpty {
            finishSequence()
            waitForAllFingersToLift = false
            return
        }

        guard !waitForAllFingersToLift else { return }

        // RESTING-FINGER SUPPORT (fork fix, from the native-behaviour
        // audit): upstream demanded exactly ONE active touch — with a
        // thumb or second finger merely resting on the glass, pressing
        // with another finger produced no click at all and locked input
        // until every finger lifted. Native trackpads click fine in
        // that posture. So: follow ONE tracked finger (the presser) and
        // ignore the rest, with two safeguards —
        //  * two fingers pressing together is a two-finger click
        //    (native secondary click): never answer it with a left
        //    click; lock until all fingers lift, as upstream did;
        //  * a second finger pressing while our click is already down
        //    is the same chord: release ours and lock — unless the held
        //    click is the tap-fired one and belongs to that finger.
        // A second finger that only rests (low pressure) never disturbs
        // an ongoing click or drag.
        if let fingerID, let tracked = active.first(where: { $0.id == fingerID }) {
            if let presser = active.first(where: { $0.id != fingerID && max(0, $0.pressure) >= threshold }) {
                if buttonDown, CACurrentMediaTime() - tapFiredDownAt > 0.1 {
                    // A second finger pressing while a pressure-path
                    // click is held: a chord — release ours and lock.
                    releaseButtonIfNeeded()
                    resetSequence()
                    waitForAllFingersToLift = true
                } else {
                    // No click down: the watched finger turned out to be
                    // the resting one — hand tracking to the presser.
                    // Or the held click is the tap-fired one (fast jab)
                    // and belongs to this very presser, the watched
                    // finger being a resting one: the presser owns the
                    // click — hand tracking over and keep it down, so a
                    // jab with a thumb resting can still hold and drag.
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
        let pressing = active.filter { max(0, $0.pressure) >= threshold * 0.5 }
        if pressing.count > 1 {
            // Release first: a tap-fired click (fast jab landing as
            // another finger also presses) can be held at this point,
            // and the lock makes process() ignore frames until every
            // finger lifts — never lock with the button down, or the
            // click would stay held for the whole lock.
            releaseButtonIfNeeded()
            waitForAllFingersToLift = true
            return
        }

        // Watch the strongest touch; resting fingers sit at low
        // pressure, so the one that presses stands out.
        guard let candidate = active.max(by: { max(0, $0.pressure) < max(0, $1.pressure) }) else { return }
        fingerID = candidate.id
        handlePress(candidate)
    }

    private func handlePress(_ touch: OMSTouchData) {
        let pressure = max(0, touch.pressure)
        onPressureChange?(pressure)

        if !buttonDown, pressure >= threshold {
            fireButtonDown()
        }

        // SNAPPY RELEASE (fork fix, from Ash's on-device feedback): upstream
        // only released the button in finishSequence() — when every finger
        // had fully left the glass — so easing off the pressure changed
        // nothing: the click stayed held until the finger was lifted off
        // the trackpad entirely, and felt long and stretched. A real click
        // ends when the press ends. Release as soon as pressure falls back
        // below 70% of the press threshold; the 30% hysteresis band keeps
        // pressure jitter near the threshold from flickering the button.
        // Keeping pressure up still holds the button, so click-hold and
        // click-drag keep working, and pressing again re-clicks (which is
        // also what makes double-clicks possible).
        if buttonDown, pressure <= threshold * 0.7 {
            releaseButtonIfNeeded()
        }
    }

    private func finishSequence() {
        // Release unconditionally (releaseButtonIfNeeded self-guards):
        // a tap-fired click can be held while no finger is tracked, and
        // a held click must never outlive its touch session.
        releaseButtonIfNeeded()
        if fingerID != nil { resetSequence() }
    }

    /// Post our synthetic mouse-down and mark the button held. Shared by
    /// the pressure path (handlePress) and the event tap's fast-jab path
    /// (filter), so both produce the identical click: marker, click
    /// count, modifier flags and the synthetic haptic. The tap path
    /// passes fromTap so the frame logic can attribute the held click
    /// to the finger whose native press the tap just answered.
    private func fireButtonDown(fromTap: Bool = false) {
        postMouseEvent(type: .leftMouseDown)
        buttonDown = true
        tapFiredDownAt = fromTap ? CACurrentMediaTime() : 0
        // HAPTIC FORK ADDITION: synthetic click haptic at the light threshold.
        HapticsController.shared.actuateClick(down: true)
    }

    private func releaseButtonIfNeeded() {
        guard buttonDown else { return }
        postMouseEvent(type: .leftMouseUp)
        // HAPTIC FORK ADDITION: release-phase haptic, mirroring a real click's up-stroke.
        HapticsController.shared.actuateClick(down: false)
        buttonDown = false
        tapFiredDownAt = 0
        ignoreNativeMouseUpUntil = CACurrentMediaTime() + 0.15
    }

    private func resetSequence() {
        fingerID = nil
        onPressureChange?(0)
    }

    private func postMouseEvent(type: CGEventType) {
        let location = CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.injectedMarker)
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState(for: type, at: location)))
        // MODIFIER KEYS (fork fix, from the native-behaviour audit): a real
        // click carries the modifiers held at that moment — Cmd+click opens
        // a link in a new tab, Ctrl+click acts as a secondary click,
        // Shift+click extends a selection. The engine never set flags on
        // its synthetic events, leaving that to undocumented event-source
        // inheritance. Copy the live HID modifier state explicitly so
        // modified clicks behave exactly like native ones.
        event.flags = CGEventSource.flagsState(.hidSystemState)
        event.post(tap: .cghidEventTap)
    }

    /// CLICK COUNT (fork fix, from Ash's on-device report): selecting a
    /// word on double-click / a line on triple-click is driven by the
    /// event's click state. macOS computes that itself for real presses
    /// and taps, but NOT for software-posted events — and upstream never
    /// set it, so every synthetic click arrived as click #1 and a fast
    /// double press looked like two unrelated single clicks. Mirror the
    /// system: a press within the user's double-click interval and a few
    /// pixels of the previous one bumps the count (2 = word, 3 = line);
    /// anything else restarts at 1. The matching mouse-up carries the
    /// same count.
    private func clickState(for type: CGEventType, at location: CGPoint) -> Int {
        if type == .leftMouseDown {
            let now = CACurrentMediaTime()
            let dx = location.x - lastClickLocation.x
            let dy = location.y - lastClickLocation.y
            let chained = now - lastClickTime <= NSEvent.doubleClickInterval
                && dx * dx + dy * dy <= 25
            clickCount = chained ? clickCount + 1 : 1
            lastClickTime = now
            lastClickLocation = location
        }
        return max(clickCount, 1)
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<LightClickEngine>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated { engine.filter(type: type, event: event) }
}
