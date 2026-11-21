# Scenario tests

Realistic usage tests for the click engine: gestures performed the way a
hand on a real Mac would, checked against rules that must always hold.

Run: `./scripts/test.sh` (works with only the Command Line Tools; with
Xcode, plain `swift test` also runs the older XCTest suites).
Filter: `./scripts/test.sh --filter Drag`.

| File | What it holds |
|---|---|
| `GestureKit.swift` | `Performer` (frames at ~120 Hz, cursor follow, macOS's native click race), `Invariants`, `ClickRecord`, `SeededRNG` |
| `Gestures.swift` | `Press` curves and the `Gesture` vocabulary, each with the output it must produce |
| `GestureCatalogTests` | every gesture × every threshold preset |
| `FuzzTests` | seeded random sessions; `FUZZ_SEED=n` reruns one, `FUZZ_SESSIONS=n` scales up |
| `Click…`, `Drag…`, `ScrollGesture…`, `MultiFingerAndNative…`, `Robustness…ScenarioTests` | named real-world scenarios |
| `KnownLimitationTests` | tradeoffs the fuzzer found |

Behaviour that is wrong today is asserted the way it *should* be inside
`withKnownIssue("BUG: …")`: the suite stays green, and a test turns red
when the engine changes — remove its `withKnownIssue` once fixed.
`grep -rn 'withKnownIssue' Tests` lists every open issue.
