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
- NOT compiled or tested by Muse — this sandbox is Linux, there is no
  macOS/Xcode here. The code follows two working MIT projects symbol-for-
  symbol, but treat the first build as an experiment.
- Same upstream limits apply: private API (may break on a macOS update),
  ad-hoc signed / not notarized, built-in trackpad only, Tap to Click is
  temporarily disabled while it runs, gram presets are uncalibrated.
- If it feels double / late: you restored-and-relaunched wrong, or system
  actuations got re-enabled — quit via "Restore everything and quit...",
  confirm a normal press clicks with haptics again, then relaunch the fork.
- If the haptic is too strong/weak: change clickActuationID 4 -> 3 or 6,
  rebuild, reinstall.
