import Foundation

/// One entry in a frame-recording file (JSON Lines: one JSON object
/// per line). A recording captures everything the decision engine
/// saw — touch frames, native mouse events, threshold changes — and
/// everything it did (posted clicks, haptic pulses), each stamped
/// with the engine clock. Replaying the input entries through a
/// fresh `ClickEngine` (see `ReplayDriver`) must reproduce the
/// output entries exactly: that is what turns a field report ("it
/// clicked while I was scrolling") into a failing test.
public enum RecordedEvent: Equatable, Codable {
    case sessionStarted(time: Double, threshold: Double)
    case frame(time: Double, touches: [TouchSample])
    case nativeDown(time: Double)
    case nativeUp(time: Double)
    case nativeMove(time: Double, x: Double, y: Double)
    case thresholdChanged(time: Double, value: Double)
    case outputDown(time: Double, x: Double, y: Double, clickState: Int)
    case outputUp(time: Double, x: Double, y: Double, clickState: Int)
    case outputHaptic(time: Double, down: Bool)

    /// The engine-clock time this entry was recorded at.
    public var time: Double {
        switch self {
        case let .sessionStarted(time, _),
             let .frame(time, _),
             let .nativeDown(time),
             let .nativeUp(time),
             let .nativeMove(time, _, _),
             let .thresholdChanged(time, _),
             let .outputDown(time, _, _, _),
             let .outputUp(time, _, _, _),
             let .outputHaptic(time, _):
            time
        }
    }

    /// True for entries the engine produced (as opposed to inputs
    /// it consumed).
    public var isOutput: Bool {
        switch self {
        case .outputDown, .outputUp, .outputHaptic: true
        default: false
        }
    }
}

/// Appends `RecordedEvent`s to a JSON Lines file. Used by the
/// debug build of the app; errors are swallowed — recording must
/// never take the app down.
public final class FrameRecorder {
    private var handle: FileHandle?
    private let encoder = JSONEncoder()

    public init?(url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
        } catch {
            return nil
        }
    }

    public func record(_ event: RecordedEvent) {
        guard let handle, let data = try? encoder.encode(event) else { return }
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data([0x0A]))
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }

    /// Read back a recording file written by `record(_:)`.
    public static func readEvents(from url: URL) throws -> [RecordedEvent] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try data.split(separator: 0x0A).map { line in
            try decoder.decode(RecordedEvent.self, from: Data(line))
        }
    }
}

/// Drives a `ClickEngine` from recorded input entries and collects
/// what it produces, so a recording can be replayed in a test (or a
/// future diagnostic tool) and its outputs compared against the
/// outputs the original session recorded.
@MainActor
public enum ReplayDriver {
    public struct Result {
        /// The output entries the replay produced, in order.
        public var outputs: [RecordedEvent]
        public var engine: ClickEngine
    }

    @MainActor
    private final class CollectingOutput: ClickOutput {
        var events: [RecordedEvent] = []
        var now: () -> Double = { 0 }

        func postMouseDown(at point: ClickPoint, clickState: Int) {
            events.append(.outputDown(time: now(), x: point.x, y: point.y, clickState: clickState))
        }

        func postMouseUp(at point: ClickPoint, clickState: Int) {
            events.append(.outputUp(time: now(), x: point.x, y: point.y, clickState: clickState))
        }

        func pulseHaptic(down: Bool) {
            events.append(.outputHaptic(time: now(), down: down))
        }
    }

    /// Replay `events` (inputs are consumed; recorded outputs in the
    /// list are ignored). The engine clock follows each entry's
    /// recorded time, the cursor follows recorded mouse moves, and
    /// the threshold follows session/threshold entries.
    public static func replay(events: [RecordedEvent], defaultThreshold: Double = 50) -> Result {
        var clock: Double = 0
        var cursor = ClickPoint.zero
        let collector = CollectingOutput()
        collector.now = { clock }
        let engine = ClickEngine(
            now: { clock },
            cursorLocation: { cursor },
            doubleClickInterval: { 0.5 },
            output: collector
        )
        engine.threshold = defaultThreshold

        for event in events {
            clock = event.time
            switch event {
            case let .sessionStarted(_, threshold):
                engine.threshold = threshold
            case let .frame(_, touches):
                engine.processFrame(touches)
            case .nativeDown:
                _ = engine.handleNativeMouseDown()
            case .nativeUp:
                _ = engine.handleNativeMouseUp()
            case let .nativeMove(_, x, y):
                cursor = ClickPoint(x: x, y: y)
            case let .thresholdChanged(_, value):
                engine.threshold = value
            case .outputDown, .outputUp, .outputHaptic:
                break // Outputs are what the replay produces, not inputs.
            }
        }
        return Result(outputs: collector.events, engine: engine)
    }
}
