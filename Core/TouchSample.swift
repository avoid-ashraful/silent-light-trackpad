import Foundation

/// One active touch on the trackpad, in the engine's own units —
/// the boundary type between the platform layer (which reads
/// OpenMultitouchSupport) and the click-decision logic. Only touches
/// in an active state are ever turned into samples; a frame with no
/// samples means "no fingers on the glass".
public struct TouchSample: Equatable, Codable, Sendable {
    /// Stable per-contact identifier for the life of the contact.
    public var id: Int32
    /// Normalised position on the pad, 0...1 on each axis.
    public var x: Double
    public var y: Double
    /// Capacitive contact "pressure" (a contact-area proxy) in the
    /// app's display units; the click threshold uses the same units.
    public var pressure: Double
    /// Contact ellipse major axis in millimetres (palm detection).
    public var majorAxis: Double

    public init(id: Int32, x: Double, y: Double, pressure: Double, majorAxis: Double) {
        self.id = id
        self.x = x
        self.y = y
        self.pressure = pressure
        self.majorAxis = majorAxis
    }
}

/// A point in global screen coordinates (top-left origin), used for
/// posted click positions and click-chain distance checks.
public struct ClickPoint: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = ClickPoint(x: 0, y: 0)
}

/// Everything the decision engine wants done in the real world.
/// The app implements this with CGEvent posting plus the haptic
/// actuator; tests implement it with a recorder and assert on the
/// exact sequence of calls. Main-actor bound, like the engine
/// itself: every producer and consumer lives on the main actor.
@MainActor
public protocol ClickOutput: AnyObject {
    func postMouseDown(at point: ClickPoint, clickState: Int)
    func postMouseUp(at point: ClickPoint, clickState: Int)
    func pulseHaptic(down: Bool)
}
