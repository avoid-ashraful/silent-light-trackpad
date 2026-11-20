@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import LightClickCore
import OpenMultitouchSupport

/// Platform shell around `ClickEngine` (LightClickCore): owns the
/// OpenMultitouchSupport touch stream, the CGEvent tap, CGEvent
/// posting and the haptic actuator, and feeds everything to the
/// decision engine. All click behaviour lives in the core; this
/// class only translates between the core and macOS.
@MainActor
final class LightClickEngine {
    static let shared = LightClickEngine()

    static let injectedMarker: Int64 = 0x534C_5450 // "SLTP"

    var threshold: Float {
        didSet {
            UserDefaults.standard.set(threshold, forKey: "pressureThreshold")
            core.threshold = Double(threshold)
            recorder?.record(.thresholdChanged(time: CACurrentMediaTime(), value: Double(threshold)))
        }
    }

    var onPressureChange: ((Float) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    var isRunning: Bool {
        listeningTask != nil && eventTap != nil
    }

    /// The decision engine. Exposed within the app target so the
    /// debug menu can inspect recording state; behaviour changes go
    /// through the core's own API.
    let core: ClickEngine

    /// Where the frame recording is being written (debug builds
    /// only; nil in release builds).
    private(set) var recordingURL: URL?

    private let systemOutput: SystemClickOutput
    private let recorder: FrameRecorder?
    private let manager = OMSManager.shared
    private var listeningTask: Task<Void, Never>?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?

    private init() {
        threshold = UserDefaults.standard.float(forKey: "pressureThreshold")

        #if FRAME_RECORDING
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/SilentLightTrackpad", isDirectory: true)
            let url = logsDir.appendingPathComponent("frames-\(stamp).jsonl")
            recorder = FrameRecorder(url: url)
            recordingURL = recorder != nil ? url : nil
        #else
            recorder = nil
            recordingURL = nil
        #endif

        let recorderBox = recorder
        systemOutput = SystemClickOutput(record: { recorderBox?.record($0) })
        core = ClickEngine(
            now: { CACurrentMediaTime() },
            cursorLocation: {
                let point = CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
                return ClickPoint(x: Double(point.x), y: Double(point.y))
            },
            doubleClickInterval: { NSEvent.doubleClickInterval },
            output: systemOutput
        )
        core.threshold = Double(threshold)
        core.onPressureChange = { [weak self] pressure in
            self?.onPressureChange?(Float(pressure))
        }
    }

    func start() -> Bool {
        guard !isRunning else { return true }
        guard installEventTap() else { return false }

        listeningTask = Task { [weak self, manager] in
            for await touches in manager.touchDataStream {
                guard let self else { return }
                let samples = touches.compactMap(Self.sample(from:))
                recorder?.record(.frame(time: CACurrentMediaTime(), touches: samples))
                core.processFrame(samples)
            }
            guard !Task.isCancelled else { return }
            self?.stop()
        }

        guard manager.startListening() else {
            stop()
            return false
        }
        recorder?.record(.sessionStarted(time: CACurrentMediaTime(), threshold: Double(threshold)))
        onStateChange?(true)
        return true
    }

    func stop() {
        core.reset()
        listeningTask?.cancel()
        listeningTask = nil
        _ = manager.stopListening()
        if let eventTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventTapSource = nil
        eventTap = nil
        onStateChange?(false)
    }

    /// Map one raw touch to the core's sample type; touches that are
    /// not in an active state (leaving, etc.) drop out, exactly as
    /// the core's frame contract expects.
    private static func sample(from touch: OMSTouchData) -> TouchSample? {
        switch touch.state {
        case .starting, .making, .touching, .breaking:
            break
        default:
            return nil
        }
        return TouchSample(
            id: touch.id,
            x: Double(touch.position.x),
            y: Double(touch.position.y),
            pressure: Double(touch.pressure),
            majorAxis: Double(touch.axis.major)
        )
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

        if type == .mouseMoved || type == .leftMouseDragged {
            let location = event.location
            recorder?.record(.nativeMove(time: CACurrentMediaTime(), x: Double(location.x), y: Double(location.y)))
            // While our synthetic button is held, this movement
            // belongs to our press: the core answers with its own
            // dragged event — built like our down/up, with the
            // press's click state and event number, which is what
            // makes macOS treat the sequence as a single drag —
            // and the native event is swallowed. (Mutating the
            // moved event's type, as the original app did, kept
            // the hardware event number and broke drags in
            // Chromium browsers and Mission Control.) With no
            // button held the event passes untouched.
            if core.handleNativeMouseMove(at: ClickPoint(x: Double(location.x), y: Double(location.y))) {
                return nil
            }
        }

        if type == .leftMouseDown {
            recorder?.record(.nativeDown(time: CACurrentMediaTime()))
            if core.handleNativeMouseDown() {
                return nil
            }
        }

        if type == .leftMouseUp {
            recorder?.record(.nativeUp(time: CACurrentMediaTime()))
            if core.handleNativeMouseUp() {
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }
}

/// The core's hands and voice on a real Mac: posts the synthetic
/// CGEvents (with the injected marker, the click state the core
/// computed, and the live modifier flags) and fires the synthetic
/// haptic. In the debug build it also records every output into the
/// frame recording.
@MainActor
private final class SystemClickOutput: ClickOutput {
    private let record: (RecordedEvent) -> Void

    init(record: @escaping (RecordedEvent) -> Void) {
        self.record = record
    }

    func postMouseDown(at point: ClickPoint, clickState: Int, eventNumber: Int) {
        post(type: .leftMouseDown, at: point, clickState: clickState, eventNumber: eventNumber)
        record(.outputDown(time: CACurrentMediaTime(), x: point.x, y: point.y, clickState: clickState))
    }

    func postMouseDragged(at point: ClickPoint, clickState: Int, eventNumber: Int) {
        post(type: .leftMouseDragged, at: point, clickState: clickState, eventNumber: eventNumber)
        record(.outputDragged(time: CACurrentMediaTime(), x: point.x, y: point.y, clickState: clickState))
    }

    func postMouseUp(at point: ClickPoint, clickState: Int, eventNumber: Int) {
        post(type: .leftMouseUp, at: point, clickState: clickState, eventNumber: eventNumber)
        record(.outputUp(time: CACurrentMediaTime(), x: point.x, y: point.y, clickState: clickState))
    }

    func pulseHaptic(down: Bool) {
        HapticsController.shared.actuateClick(down: down)
        record(.outputHaptic(time: CACurrentMediaTime(), down: down))
    }

    private func post(type: CGEventType, at point: ClickPoint, clickState: Int, eventNumber: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: CGPoint(x: point.x, y: point.y),
            mouseButton: .left
        ) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: LightClickEngine.injectedMarker)
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        // DRAG EVENT NUMBER: every event of one press — down,
        // dragged, up — carries the same kCGMouseEventNumber.
        // Without it macOS does not treat the sequence as a single
        // drag (Chromium's remoting injector documents the same
        // requirement), and stream-driven drags — browser tabs,
        // Mission Control windows — never start.
        event.setIntegerValueField(.mouseEventNumber, value: Int64(eventNumber))
        // MODIFIER KEYS (fork fix, from the native-behaviour audit): a
        // real click carries the modifiers held at that moment —
        // Cmd+click opens a link in a new tab, Ctrl+click acts as a
        // secondary click, Shift+click extends a selection. Copy the
        // live HID modifier state explicitly so modified clicks
        // behave exactly like native ones.
        event.flags = CGEventSource.flagsState(.hidSystemState)
        event.post(tap: .cghidEventTap)
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
