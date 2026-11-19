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

        if buttonDown, type == .leftMouseDown {
            return nil
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

        if active.isEmpty {
            finishSequence()
            waitForAllFingersToLift = false
            return
        }

        guard !waitForAllFingersToLift else { return }
        guard active.count == 1, let touch = active.first else {
            if fingerID != nil {
                releaseButtonIfNeeded()
                resetSequence()
            }
            waitForAllFingersToLift = true
            return
        }

        if fingerID == nil {
            fingerID = touch.id
        }
        guard fingerID == touch.id else { return }

        let pressure = max(0, touch.pressure)
        onPressureChange?(pressure)

        if !buttonDown, pressure >= threshold {
            postMouseEvent(type: .leftMouseDown)
            buttonDown = true
            // HAPTIC FORK ADDITION: synthetic click haptic at the light threshold.
            HapticsController.shared.actuateClick(down: true)
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
        guard fingerID != nil else { return }
        releaseButtonIfNeeded()
        resetSequence()
    }

    private func releaseButtonIfNeeded() {
        guard buttonDown else { return }
        postMouseEvent(type: .leftMouseUp)
        // HAPTIC FORK ADDITION: release-phase haptic, mirroring a real click's up-stroke.
        HapticsController.shared.actuateClick(down: false)
        buttonDown = false
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
