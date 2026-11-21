import Testing
@testable import LightClickCore

/// Every gesture in the vocabulary, performed from rest at every
/// threshold preset: the output must satisfy the invariants and the
/// gesture's own expectation. This is the grid that guards the
/// basics — a new gesture added to `Gesture` should be added here.
@MainActor
@Suite("Gesture catalog × thresholds")
struct GestureCatalogTests {
    nonisolated static let thresholds: [Double] = [30, 40, 50, 60, 80]

    static let catalog: [Gesture] = [
        .click(.light()),
        .click(.firm()),
        .click(.jab()),
        .click(Press(peak: 45)), // under the default threshold
        .multiClick(count: 2, gap: 0.12, press: .quick()),
        .multiClick(count: 3, gap: 0.10, press: .quick()),
        .multiClick(count: 2, gap: 0.12, press: .firm()),
        .point(dx: 0.2, dy: 0.05, frames: 20, pressure: 15),
        .drag(press: .light(), dx: 0.25, dy: 0, frames: 30, dipTo: 25),
        .drag(press: .firm(), dx: 0.1, dy: 0.2, frames: 25, dipTo: 40),
        .doubleClickDrag(gap: 0.1, dx: 0.15, frames: 20),
        .thumbHoldIndexDrag(thumbPeak: 85, dx: 0.2, frames: 20),
        .scroll(fingers: 2, dx: 0, dy: 0.3, frames: 20, heavy: nil, landingSpike: false),
        .scroll(fingers: 2, dx: 0, dy: -0.3, frames: 15, heavy: 60, landingSpike: true),
        .scroll(fingers: 3, dx: 0.35, dy: 0, frames: 15, heavy: nil, landingSpike: false),
        .scroll(fingers: 4, dx: -0.35, dy: 0, frames: 15, heavy: nil, landingSpike: true),
        .pinch(spread: 0.2, frames: 15, pressure: 25),
        .rotate(degrees: 60, frames: 15, pressure: 25),
        .twoFingerClick(peak: 80, offsetFrames: 0),
        .twoFingerClick(peak: 80, offsetFrames: 2),
        .restingFingerClick(restPressure: 12, press: .light()),
        .palmRest(palmPressure: 80, frames: 10, fingerPress: nil),
        .palmRest(palmPressure: 60, frames: 5, fingerPress: .light()),
        .chordMidClick(secondPeak: 90),
        .externalMouseClick,
    ]

    @Test(arguments: thresholds)
    func everyGestureFromRest(threshold: Double) {
        for gesture in Self.catalog {
            let rig = TestRig(threshold: threshold)
            let performer = Performer(rig: rig)
            let produced = performer.perform(gesture)
            let problems = performer.violations()
                + expectationProblems(gesture.expectation(threshold: threshold), produced: produced)
            #expect(problems.isEmpty, "\(gesture) at threshold \(threshold)\n\(performer.report(problems))")
        }
    }
}
