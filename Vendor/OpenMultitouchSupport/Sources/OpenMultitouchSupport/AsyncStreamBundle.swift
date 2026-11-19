/*
 AsyncStreamBundle.swift

 Created by Takuto Nakamura on 2026/05/28.

 CI-HARNESS PATCH (test branch only — NOT upstream code):
 Upstream's version multicasts one AsyncStream via AsyncAlgorithms'
 share() and names the stream type with Swift 6.2's AsyncSequence
 Failure associated type (`AsyncStream<T>.__AsyncSequence_Failure`).
 Neither exists under the Swift 6.1 compiler used by this harness, so
 the bundle is reduced to the plain AsyncStream it wraps. That is
 behaviour-identical for this app: OMSManager.touchDataStream has
 exactly one consumer (LightClickEngine), and the base stream already
 used bufferingNewest(1), matching share's bufferingLatest(1) for a
 single subscriber. OMSManager itself is unmodified except for the
 declared type of touchDataStream.
 */

struct AsyncStreamBundle<T>: Sendable where T: Sendable {
    public let stream: AsyncStream<T>
    private let continuation: AsyncStream<T>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: T.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.stream = stream
        self.continuation = continuation
    }

    func send(_ value: T) {
        continuation.yield(value)
    }
}
