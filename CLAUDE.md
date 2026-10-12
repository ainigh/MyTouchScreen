# CLAUDE.md — How to work on this repo

You are building **a native macOS menu-bar app that turns a webcam into a touch-free pointing
device**: the user points at the screen and pinches to click, with the rest of the gesture set
defined in `SPEC.md`. The owner will not be present while you work. Read this file, then
`SPEC.md`, then `PROGRESS.md`, and work until every milestone is checked off.

## Operating rules (non-negotiable)

1. **Never stop to ask a question.** Every judgment call is delegated to you. Decide, write one
   line in `DECISIONS.md`, keep going.
2. **Never ship placeholders.** No `TODO`, `fatalError("not implemented")`, stubbed gestures or
   commented-out features. A spec item either works or is removed with a reason in `DECISIONS.md`.
3. **One milestone at a time**, each leaving the app usable. Verify, commit, tick, next.
4. **Commit often**, one per milestone minimum: `M3: cursor control, click, permissions flow`.
5. **If interrupted**, the next session resumes from the first unchecked item in `PROGRESS.md`.
   Keep `PROGRESS.md` and `DECISIONS.md` accurate at all times.
6. **Finish strong.** Complete the Final pass in `PROGRESS.md`, then write `README.md`.

## Your environment vs the target

You are almost certainly running on Linux. The target is macOS 14+ on Apple Silicon. Therefore:

- **You cannot compile AppKit, AVFoundation, Vision or Quartz code.** You can still write it well.
  Use mainstream, long-stable APIs you are confident about; avoid anything introduced in the
  last two OS releases; avoid clever generics or protocol tricks in the Mac layer.
- **Everything that can be platform-independent must be.** Put it in the `GestureCore` package
  target (Foundation only) and test it with `swift test`.
- **Install a Swift toolchain in your sandbox if one isn't present** (swift.org publishes Linux
  tarballs; `swiftly` also works). Then `swift build --target GestureCore` and `swift test` are
  your main verification. If you truly cannot get Swift running, say so in `PROGRESS.md` and
  verify the core by careful review plus a Python re-implementation of the filter math in
  `tools/` used to cross-check expected values in the Swift tests.
- **The Mac layer gets compiled by the owner.** Make that loop painless: a `Makefile` with
  `make build`, `make app`, `make run`, `make doctor`; errors that are specific; a README section
  "If the build fails" telling the owner to paste the full output back to you.
- **Design for replay.** The app must be able to record landmark streams to JSON (`--record`) and
  run from a recording with no camera (`--replay`). Every tricky gesture bug can then be
  reproduced on Linux against `GestureCore`.

## Hard technical constraints

- Swift 5.9+, Swift Package Manager only. **No Xcode project, no CocoaPods/SPM third-party
  dependencies, no Python runtime, no ML model downloads.** Apple frameworks only.
- macOS 14 (Sonoma) minimum. Apple Silicon.
- Hand tracking via `Vision` (`VNDetectHumanHandPoseRequest`). Camera via `AVFoundation`.
  Input via `CoreGraphics` `CGEvent` posted to `.cghidEventTap`. Overlay via `AppKit`.
- Ships as `GesturePointer.app` assembled by `scripts/make-app.sh` from the SPM binary plus an
  `Info.plist` (`LSUIElement=true`, `NSCameraUsageDescription`), ad-hoc codesigned.
  No Xcode required anywhere in the workflow; command-line tools are enough.
- Must run as a menu-bar app with no Dock icon.

## Required architecture

```
Package.swift
Sources/
  GestureCore/                 Foundation only. No AppKit/Vision/CoreGraphics imports.
    Landmarks.swift            HandFrame {21 points, chirality, confidence, timestamp}
    OneEuroFilter.swift        1€ filter for 1-D and 2-D signals
    Calibration.swift          active-box ↔ screen mapping, per-display
    GestureDetector.swift      pinch/fist/palm/point classification with hysteresis
    PointerStateMachine.swift  idle → engaged → hover → pinchArmed → clicked / dragging / scrolling
    Intents.swift              output enum: move(x,y), down, up, click, rightClick, scroll(dx,dy,phase), zoom(f), key(...)
    Replay.swift               JSON record/replay of HandFrame streams
  GesturePointerApp/           macOS only.
    main.swift                 arg parsing (--record, --replay, --no-overlay, --doctor), run loop
    Camera.swift               AVCaptureSession, device picker (incl. Continuity Camera), 720p, fps
    HandTracker.swift          Vision request on a background queue, frame dropping, → HandFrame
    InputSynth.swift           Intents → CGEvent (move, click, drag, scroll with phases, keys)
    Overlay.swift              transparent click-through NSWindow per screen, cursor halo, HUD
    MenuBar.swift              NSStatusItem, enable/disable, calibrate, settings, quit
    Settings.swift             UserDefaults-backed; SwiftUI settings window
    Permissions.swift          camera + Accessibility prompts and status
Tests/GestureCoreTests/
scripts/make-app.sh  Info.plist  Makefile  tools/
```

## Verification before ticking a milestone

1. `swift build --target GestureCore` and `swift test` pass on Linux (or the fallback above).
2. Every Mac-layer file is reviewed for: correct imports, main-thread rules (AppKit on main,
   Vision off main), retain cycles in closures, `@MainActor`/`DispatchQueue.main` where UI is
   touched, and `CGEvent` field names.
3. `swift build` of the whole package is attempted; it will fail on Linux at the Mac imports, but
   the error must be *only* missing Apple modules, never syntax or type errors in your code.
   (Guard Mac files with `#if canImport(AppKit)` so the Linux build of the package skips them
   cleanly; then a full `swift build` on Linux should succeed with the app target empty.)
4. `tools/check.sh`: no TODO/FIXME/placeholder strings; every file in `Sources/GestureCore`
   imports only Foundation; `Info.plist` has the required keys; `make-app.sh` is executable.
5. Update `PROGRESS.md` with what was and wasn't verifiable.

## Quality bar

- Latency is the product. Camera frame → cursor move must stay under ~40 ms. Never block the
  camera queue; drop frames rather than queue them.
- The cursor must be *rock steady* when the hand is still and *snappy* when it moves. That is
  what the 1€ filter is for; tune `minCutoff` and `beta`, expose them in settings.
- Clicks must never double-fire or fire on accidental finger contact. Hysteresis on pinch
  distance, a minimum pinch duration, and a short refractory period.
- The overlay must look designed: a soft cursor halo, a pinch-progress ring, a subtle hand
  skeleton in the optional camera picture-in-picture, clean typography, dark-mode friendly.
- Respect the user: no cursor movement when disengaged, an obvious way to disengage with the
  hand itself, a global hotkey to kill it instantly, and never swallow real mouse input.
- CPU under ~10% of one core while tracking; near zero when disengaged (pause the camera).

## Style

Small files, clear names (`pinchDistanceNormalized`, not `d2`), comments for the why. Keep the
Mac layer boring and the core clever.
