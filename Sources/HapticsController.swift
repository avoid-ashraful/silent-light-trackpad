import Foundation
import IOKit

private typealias CreateDevice = @convention(c) () -> UnsafeMutableRawPointer?
private typealias GetActuator = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
private typealias GetEnabled = @convention(c) (UnsafeMutableRawPointer) -> Int
private typealias SetEnabled = @convention(c) (UnsafeMutableRawPointer, Int) -> Int32
private typealias ReleaseDevice = @convention(c) (UnsafeMutableRawPointer) -> Void

// HAPTIC FORK ADDITION: individual actuation, as used by niw/HapticKey and
// RithvikVatti/thockplus (both MIT). System actuations stay disabled (so the
// heavy native click never fires late), and this fires one synthetic
// actuation exactly when the light-pressure click triggers.
private typealias CreateActuatorFromDeviceID = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
private typealias OpenActuatorFn = @convention(c) (CFTypeRef) -> Int32
private typealias CloseActuatorFn = @convention(c) (CFTypeRef) -> Int32
private typealias ActuateFn = @convention(c) (CFTypeRef, Int32, UInt32, Float32, Float32) -> Int32

@MainActor
final class HapticsController {
    static let shared = HapticsController()

    private let handle: UnsafeMutableRawPointer?
    private let createDevice: CreateDevice?
    private let getActuator: GetActuator?
    private let getEnabled: GetEnabled?
    private let setEnabled: SetEnabled?
    private let releaseDevice: ReleaseDevice?
    private(set) var isEnabled: Bool?

    // HAPTIC FORK ADDITION
    private let createActuator: CreateActuatorFromDeviceID?
    private let openActuatorFn: OpenActuatorFn?
    private let closeActuatorFn: CloseActuatorFn?
    private let actuateFn: ActuateFn?
    private var actuatorRef: CFTypeRef?

    /// Actuation IDs are the predefined MultitouchSupport waveforms:
    /// 3 = weak, 4 = medium, 6 = strong (HapticKey's mapping).
    /// Change this one value to 3 if medium feels too strong.
    var clickActuationID: Int32 = 4

    /// User-toggleable click haptic (menu: "Click haptic feedback").
    /// Persisted, default ON. When OFF the app behaves like upstream:
    /// light click with no haptic at all.
    var clickHapticEnabled: Bool {
        didSet { UserDefaults.standard.set(clickHapticEnabled, forKey: Self.clickHapticKey) }
    }
    private static let clickHapticKey = "clickHapticEnabled"

    private init() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        handle = dlopen(path, RTLD_NOW)
        createDevice = Self.symbol("MTDeviceCreateDefault", in: handle)
        getActuator = Self.symbol("MTDeviceGetMTActuator", in: handle)
        getEnabled = Self.symbol("MTActuatorGetSystemActuationsEnabled", in: handle)
        setEnabled = Self.symbol("MTActuatorSetSystemActuationsEnabled", in: handle)
        releaseDevice = Self.symbol("MTDeviceRelease", in: handle)
        createActuator = Self.symbol("MTActuatorCreateFromDeviceID", in: handle)
        openActuatorFn = Self.symbol("MTActuatorOpen", in: handle)
        closeActuatorFn = Self.symbol("MTActuatorClose", in: handle)
        actuateFn = Self.symbol("MTActuatorActuate", in: handle)
        let defaults = UserDefaults.standard
        clickHapticEnabled = defaults.object(forKey: Self.clickHapticKey) as? Bool ?? true
    }

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer?) -> T? {
        guard let handle, let raw = dlsym(handle, name) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }

    func setEnabled(_ enabled: Bool) -> Bool {
        guard let createDevice, let getActuator, let getEnabled, let setEnabled, let releaseDevice,
              let device = createDevice() else {
            isEnabled = nil
            return false
        }
        defer { releaseDevice(device) }
        guard let actuator = getActuator(device), setEnabled(actuator, enabled ? 1 : 0) == 0 else {
            isEnabled = nil
            return false
        }
        isEnabled = getEnabled(actuator) == 1
        return isEnabled == enabled
    }

    // MARK: - HAPTIC FORK ADDITION

    /// Fire one synthetic click haptic. `down == true` is the press phase
    /// (HapticKey uses unknown3 = 2.0), `down == false` is the release
    /// phase (unknown3 = 0.0).
    func actuateClick(down: Bool) {
        guard clickHapticEnabled else { return }
        guard ensureActuatorOpen(), let actuatorRef, let actuateFn else { return }
        let phase: Float32 = down ? 2.0 : 0.0
        if actuateFn(actuatorRef, clickActuationID, 0, 0.0, phase) != 0 {
            // Reopen once and retry, mirroring HapticKey's recovery.
            // Note: `actuatorRef` here is still the guard-bound (now closed)
            // ref, so the reopened one must come from the property itself.
            closeActuatorIfOpen()
            guard ensureActuatorOpen(), let reopenedRef = self.actuatorRef else { return }
            _ = actuateFn(reopenedRef, clickActuationID, 0, 0.0, phase)
        }
    }

    private func ensureActuatorOpen() -> Bool {
        if actuatorRef != nil { return true }
        guard let createActuator, let openActuatorFn else { return false }

        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleMultitouchDevice")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            let current = service
            service = IOIteratorNext(iterator)
            defer { IOObjectRelease(current) }
            var props: Unmanaged<CFMutableDictionary>? = nil
            guard IORegistryEntryCreateCFProperties(current, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let actSupported = dict["ActuationSupported"] as? Bool, actSupported,
                  let mtID = dict["Multitouch ID"] as? UInt64 ?? (dict["Multitouch ID"] as? NSNumber)?.uint64Value
            else { continue }

            guard let ref = createActuator(mtID)?.takeRetainedValue() else { continue }
            guard openActuatorFn(ref) == 0 else { continue }
            actuatorRef = ref
            return true
        }
        return false
    }

    private func closeActuatorIfOpen() {
        if let actuatorRef, let closeActuatorFn {
            _ = closeActuatorFn(actuatorRef)
        }
        actuatorRef = nil
    }
}
