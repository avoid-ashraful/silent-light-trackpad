import XCTest
@testable import LightClickCore

/// The frame recorder: its JSON Lines format must round-trip
/// losslessly, and replaying a recording's inputs through a fresh
/// engine must reproduce the outputs the session recorded — the
/// property that turns a field report into a failing test.
@MainActor
final class RecorderTests: EngineTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sltp-recording-\(UUID().uuidString).jsonl")
    }

    func testRecordingRoundTripsLosslessly() throws {
        let events: [RecordedEvent] = [
            .sessionStarted(time: 1.0, threshold: 50),
            .frame(time: 1.01, touches: [TouchSample(id: 1, x: 0.5, y: 0.5, pressure: 60, majorAxis: 10)]),
            .nativeDown(time: 1.02),
            .nativeMove(time: 1.03, x: 100, y: 200),
            .nativeUp(time: 1.04),
            .thresholdChanged(time: 1.05, value: 40),
            .outputDown(time: 1.01, x: 500, y: 500, clickState: 1),
            .outputHaptic(time: 1.01, down: true),
            .outputUp(time: 1.10, x: 500, y: 500, clickState: 1),
            .outputHaptic(time: 1.10, down: false),
            .frame(time: 1.20, touches: []),
        ]
        let url = tempURL()
        let recorder = FrameRecorder(url: url)
        XCTAssertNotNil(recorder)
        for event in events { recorder?.record(event) }
        recorder?.close()

        let readBack = try FrameRecorder.readEvents(from: url)
        XCTAssertEqual(readBack, events)
        try? FileManager.default.removeItem(at: url)
    }

    func testRecordingIsOneJSONLinePerEvent() throws {
        let url = tempURL()
        let recorder = FrameRecorder(url: url)
        XCTAssertNotNil(recorder)
        recorder?.record(.nativeDown(time: 1))
        recorder?.record(.nativeUp(time: 2))
        recorder?.record(.nativeDown(time: 3))
        recorder?.close()

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 3)
        try? FileManager.default.removeItem(at: url)
    }

    func testReplayReproducesASimpleClick() {
        let events: [RecordedEvent] = [
            .sessionStarted(time: 0, threshold: 50),
            .frame(time: 0.01, touches: [TouchSample(id: 1, x: 0.5, y: 0.5, pressure: 60, majorAxis: 10)]),
            .frame(time: 0.10, touches: []),
        ]
        let result = ReplayDriver.replay(events: events)
        XCTAssertEqual(result.outputs, [
            .outputDown(time: 0.01, x: 0, y: 0, clickState: 1),
            .outputHaptic(time: 0.01, down: true),
            .outputUp(time: 0.10, x: 0, y: 0, clickState: 1),
            .outputHaptic(time: 0.10, down: false),
        ])
    }

    func testReplayOfAScrollSessionProducesNoClicks() {
        var events: [RecordedEvent] = [.sessionStarted(time: 0, threshold: 50)]
        var y = 0.50
        for i in 0 ..< 5 {
            events.append(.frame(time: 0.01 * Double(i + 1), touches: [
                TouchSample(id: 1, x: 0.40, y: y, pressure: 60, majorAxis: 10),
                TouchSample(id: 2, x: 0.60, y: y + 0.05, pressure: 20, majorAxis: 10),
            ]))
            y += 0.015
        }
        events.append(.nativeDown(time: 0.06)) // a native press surfacing mid-scroll
        events.append(.frame(time: 0.07, touches: []))

        let result = ReplayDriver.replay(events: events)
        XCTAssertEqual(result.outputs, [])
    }

    func testReplayMatchesTheSessionsRecordedOutputs() {
        // A session as the debug build would record it: inputs and
        // outputs interleaved. The replay must produce exactly the
        // recorded outputs.
        let touch = TouchSample(id: 1, x: 0.5, y: 0.5, pressure: 60, majorAxis: 10)
        let events: [RecordedEvent] = [
            .sessionStarted(time: 0, threshold: 50),
            .nativeMove(time: 0.005, x: 500, y: 500),
            .frame(time: 0.01, touches: [touch]),
            .outputDown(time: 0.01, x: 500, y: 500, clickState: 1),
            .outputHaptic(time: 0.01, down: true),
            .frame(time: 0.10, touches: []),
            .outputUp(time: 0.10, x: 500, y: 500, clickState: 1),
            .outputHaptic(time: 0.10, down: false),
        ]
        let result = ReplayDriver.replay(events: events)
        XCTAssertEqual(result.outputs, events.filter(\.isOutput))
    }

    func testReplayAppliesThresholdChanges() {
        let touch = TouchSample(id: 1, x: 0.5, y: 0.5, pressure: 60, majorAxis: 10)
        let events: [RecordedEvent] = [
            .sessionStarted(time: 0, threshold: 80),
            .frame(time: 0.01, touches: [touch]), // 60 < 80: no click
            .thresholdChanged(time: 0.05, value: 40),
            .frame(time: 0.06, touches: [touch]), // now it fires
        ]
        let result = ReplayDriver.replay(events: events)
        XCTAssertEqual(result.outputs, [
            .outputDown(time: 0.06, x: 0, y: 0, clickState: 1),
            .outputHaptic(time: 0.06, down: true),
        ])
    }
}
