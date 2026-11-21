# Silent Light Trackpad — Haptic Fork (prepared for Ash, 2026-11-19)

Upstream: https://github.com/ruodou233/silent-light-trackpad (MIT, commit f359923)
Problem with upstream for Ash: it fully disables the haptic actuator, so the
light click is completely silent / feel-less.

## What this fork changes (3 files, search for "HAPTIC FORK")
1. `Sources/HapticsController.swift`
   - Keeps system actuations DISABLED (otherwise the heavy native click would
     still fire later, at Apple's Light threshold, as a second/late haptic).
   - Adds individual actuation via the private MultitouchSupport symbols
     `MTActuatorCreateFromDeviceID` / `MTActuatorOpen` / `MTActuatorActuate`,
     finding the built-in trackpad through IOKit (`AppleMultitouchDevice`,
     `ActuationSupported`, `Multitouch ID`) — the exact approach used by
     niw/HapticKey and RithvikVatti/thockplus (both MIT).
   - Waveform strength is user-selectable in the menu's **Haptic
     strength** section: Low = actuation ID 3 (weak), Medium = 4
     (default), High = 6 (strong). Persisted as `clickActuationID`;
     picking a strength fires one sample pulse so it can be felt at once.
2. `Sources/LightClickEngine.swift`
   - When raw pressure crosses your chosen threshold (30/40/50/60/80 g presets):
     posts the left-mouse-down AND fires the press-phase actuation
     (actuate with unknown3 = 2.0, HapticKey's begin phase).
   - On release: posts left-mouse-up AND fires the release-phase actuation
     (unknown3 = 0.0, HapticKey's end phase).
   - Snappy release: upstream only posted mouse-up when every finger had
     fully left the glass, so the click stayed held after you eased off
     the pressure. The fork releases as soon as pressure falls below 70%
     of the press threshold — the click ends when the press ends. Holding
     pressure still holds the button (click-hold / drag unaffected).
   - Click counting: macOS computes the click state (1/2/3) itself for
     real presses and taps, but not for software-posted events, and
     upstream never set it — so double/triple presses never selected a
     word/line. The fork sets `mouseEventClickState` the way the system
     does (chained presses within the user's double-click interval and
     5 px), restoring double-click word and triple-click line selection.
   - Modifier keys: the fork copies the live HID modifier state onto
     every synthetic down/up (`CGEventSource.flagsState`), so Cmd+click,
     Ctrl+click (secondary click), Shift+click and Option+click behave
     like native clicks instead of plain ones.
   - Resting fingers: upstream required exactly one active touch, so
     pressing while a thumb/finger rested on the pad produced no click
     and locked input until all fingers lifted. The fork tracks the
     pressing finger by pressure and ignores resting touches, while
     still refusing to answer a genuine two-finger press (both fingers
     pressing together, or a second press mid-click) with a left click —
     that stays the native secondary click.
   - Fast-jab double-fire: a fast, hard press could cross Apple's
     native threshold before the next pressure frame arrived, letting
     the native click slip through the event tap, followed a frame
     later by the app's own — one jab, two clicks. The fork's tap now
     recognises a native press that belongs to the trackpad (a touch
     is, or just was, active), swallows it, and answers with the app's
     own click on the spot. Native presses with no touch behind them
     (external mouse, other input sources) pass through untouched.
     A follow-up interaction review hardened the corners: a tap-fired
     click is attributed to the finger that pressed (so jabbing while
     a thumb rests hands tracking to the jabbing finger instead of
     being misread as a chord and killed), the two-finger lock never
     engages while a click is held, and a held click is always
     released when the touch session ends.
   - Scroll clicks: with two or more fingers on the glass, the
     strongest finger crossing the threshold mid-scroll used to fire
     a click (pressures are per-finger, never summed — one loaded
     finger is enough). The fork now classifies multi-touch movement:
     if any finger travels ~2 mm from where the multi-touch sequence
     began, the sequence is a scroll/gesture and clicks are
     suppressed until all fingers lift; a genuine press with a
     resting finger must additionally hold the threshold for 3
     frames, which filters out the landing spike when fingers come
     down to scroll. Single-finger presses are unchanged and still
     fire instantly; the same gate also covers most three-finger
     gesture cases.
   - Drag event numbers: even with the latch, tab drags in
     Chromium browsers and window drags in Mission Control never
     started, while Finder drags worked. Root cause: macOS treats
     a down / dragged / up sequence as one drag only when every
     event shares the same kCGMouseEventNumber (Chromium's own
     remoting injector documents the requirement). Upstream
     mutated hardware mouseMoved events into dragged ones in its
     event tap, so the dragged events kept the hardware movements'
     unrelated event numbers and a click state of 0. The fork now
     assigns each press an event number (incremented per press)
     stamped on its down, its up, and a dragged event the engine
     itself posts for every movement while the button is held —
     the native movement is swallowed and replaced, never mutated.
   - Drag latch: the snappy release (70% of threshold) also fired
     mid-drag — sliding a finger sideways rolls the contact, the
     pressure reading dips, and the button let go a fraction of a
     second into the drag, cancelling browser tab drags outright
     (Finder drags only dropped early, which looked like success).
     Once a held click has moved the cursor ~5 px it is a drag and
     latches like a physical button: it releases only when pressure
     falls to ~10% of the threshold or every finger lifts. Clicks
     that never move keep the snappy release unchanged.
   - Native-parity round (after researching how macOS itself does
     it — the native click is one fused strain-gauge force computed
     in firmware, a signal MultitouchSupport never exposes, so the
     fork matches the decision logic instead): palm rejection —
     contacts whose ellipse major axis is ≥ 20 mm (a firm fingertip
     measures ~10 mm) are not fingers and are filtered out before
     all click/gate logic, with the tracked finger exempt so a
     flattening press is never reclassified mid-click; a hard-press
     override — during a classified scroll, a finger sustaining
     twice the threshold for 2 frames still clicks, mirroring the
     native button channel that gestures never veto; and a velocity
     trigger — a finger moving ~1.2 mm in a single frame classifies
     the sequence as a gesture immediately, without waiting for
     the ~2 mm anchor travel to accumulate.
   - Scenario-suite round (bugs found by the gesture scenario tests
     and fuzzing in `Tests/LightClickCoreTests/Scenarios`):
     two-finger click — real fingers land light and press together,
     so one was already tracked before either reached half the
     threshold and the lock was never reached: the tracked finger
     fired a LEFT click on top of macOS's secondary click. Now, while
     no click is held, two fingers pressing at the same moment (each
     ≥ half the threshold and risen by ≥ a quarter of it, 12 units
     at least, within ~0.12 s) lock until every finger lifts; a
     resting thumb holds steady, so it never counts. Resting thumb
     vs. the scroll gate — one finger moving beside a still thumb
     classified the sequence as a scroll, killing every light click
     until the thumb lifted (pointing then clicking is the main thing
     that posture is for). A scroll/gesture now needs TWO moving
     fingers; once every finger that moved has lifted, the still
     ones left are resting and the classification clears; and the
     gate forgets lifted touches' positions, so a reused touch ID is
     no longer misread as a flick.
   - On-device feedback round: two/three-finger taps vibrated (one
     firm finger of the tap fired a left click) — fingers that touch
     down within 0.1 s of each other and press within 0.3 s of
     landing are now a multi-finger tap: no left click, no haptic,
     locked until every finger lifts. A light click beside a resting
     finger is SILENT (no haptic), as a macOS tap is; physical-strength
     clicks (a jab that trips macOS's own click, the hard-press
     override) still pulse. Double-tap hold: "tap, tap, keep resting
     and slide" selects word by word — a double (or later) click
     whose finger stays on the glass stays held: sliding makes it a
     latched drag released at lift, lifting releases it, pressing
     again re-clicks (triple), resting still for 0.8 s lets it go.
   - Drag deltas: the engine-posted dragged events (see "Drag event
     numbers") were built from scratch, so they carried zero
     movement deltas and zero button pressure. Apps that move things
     by NSEvent.deltaX/deltaY instead of by location — the macOS
     screenshot selection box could not be moved or resized — saw a
     drag that never moved. Each dragged event now carries the deltas
     of the native movement it replaces, and down/dragged events
     report full button pressure (none on release), like a real
     button.
3. `Sources/AppDelegate.swift` — the haptics menu item is no longer a
   disabled status label. Upstream it was created with `action: nil` and
   `isEnabled = false` ("Haptics: fully disabled"), so its state could
   never be changed. It is now a real toggle, **Click haptic feedback**:
   clickable, checkmark state persisted in UserDefaults
   (`clickHapticEnabled` in HapticsController, default ON). ON = the
   synthetic haptic fires at the light threshold; OFF = upstream's fully
   silent light click. Toggling it ON fires one sample pulse.
   The Sensitivity list also adds a selectable **30 g** preset, so any one
   of 30 / 40 / 50 / 60 / 80 can be chosen; the click and the synthetic
   haptic both fire at whichever threshold is selected.

## Testing
The click-decision logic lives in `Core/` (the `LightClickCore`
library target) — a platform-free engine that consumes touch frames
and native-event decisions and emits clicks/haptics through a
protocol, with time, cursor position and the double-click interval
injected. `Sources/` is a thin macOS shell around it (touch stream,
event tap, CGEvent posting, actuator). The suite in
`Tests/LightClickCoreTests/` drives the engine frame by frame and
asserts the exact output sequence for every behaviour in this fork:
press/release and hysteresis, click counting, thresholds, resting
fingers, the two-finger lock and chords, the fast-jab path and its
interactions, the scroll/gesture gate (dwell, anchor travel,
velocity trigger), palm rejection, the hard-press override, the
drag latch, drag event numbers and dragged-event replacement,
native-event swallow/pass decisions, and reset. CI runs `swift test` on
every push; a regression fails the build before it can merge.

Frame recording (debug builds): build with `FRAME_RECORDING=1
./build-app.sh` and the app records every touch frame, native
event and output to `~/Library/Logs/SilentLightTrackpad/
frames-<time>.jsonl` (the menu shows it is on). Replaying a
recording's inputs through a fresh engine (`ReplayDriver` in
`Core/FrameRecording.swift`) reproduces its outputs exactly — so a
field report becomes a test: record the misbehaviour, replay it,
watch it fail, fix, watch it pass. Release builds compile the
recorder out entirely.

What the suite cannot do: it runs the *decision logic*, not the
app on a real trackpad — CGEvent posting, modifier flags, the
actuator and all timing feel still need on-device confirmation.

## Build & install (must be done on the Mac — needs Xcode / Swift 6.2)
    ./build-app.sh
    # First REMOVE / restore the upstream app:
    #   In the upstream app's menu choose "Restore everything and quit..."
    #   so native haptics + your original Tap to Click setting come back.
    ditto "dist/Silent Light Trackpad.app" "/Applications/Silent Light Trackpad.app"
    open "/Applications/Silent Light Trackpad.app"
Then re-grant Accessibility (the rebuilt app may need it again), pick any
preset — 30, 40, 50, 60, or 80 g — and click. You should get the light
click WITH a haptic thock at that selected threshold.

## Honest limits
- Compiled and logic-tested in CI on every change (see Testing
  above); the sandbox itself is Linux with no macOS/Xcode, so
  on-device feel remains the final check for each build.
- Same upstream limits apply: private API (may break on a macOS update),
  ad-hoc signed / not notarized, built-in trackpad only, Tap to Click is
  temporarily disabled while it runs, gram presets are uncalibrated.
- If it feels double / late: you restored-and-relaunched wrong, or system
  actuations got re-enabled — quit via "Restore everything and quit...",
  confirm a normal press clicks with haptics again, then relaunch the fork.
- If the haptic is too strong/weak: change clickActuationID 4 -> 3 or 6,
  rebuild, reinstall.
