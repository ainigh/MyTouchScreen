# PROGRESS.md

Resume from the first unchecked item. Tick only after verification per `CLAUDE.md`.

## Setup
- [x] Read CLAUDE.md, SPEC.md, PROGRESS.md
- [x] Concept (name, overlay identity, accent color, font) written to DECISIONS.md
- [x] Swift toolchain available in sandbox? version 6.0.3 (installed it? yes — swift.org Ubuntu 24.04 tarball into /opt/swift)
- [x] Package.swift with GestureCore + GesturePointerApp targets, Mac files guarded, tools/check.sh, first commit

## M1 — GestureCore
- [x] HandFrame, OneEuroFilter, Calibration, GestureDetector, PointerStateMachine, Intents, Replay
- [x] Synthetic stream generator (steady, jitter, fast ramp, pinch taps, double pinch, drag, fist scroll, palm hold, hand lost)
- [x] Tests green on Linux (59 tests, `swift test`)
- [x] Committed

## M2 — Camera and tracking
- [ ] Camera.swift (device list, Continuity Camera preference, 720p, best fps)
- [ ] HandTracker.swift (Vision, background queue, frame dropping, y-flip, chirality)
- [ ] main.swift flags: --record --replay --no-overlay --doctor
- [ ] Linux build still green with guards; tools/check.sh green
- [ ] Committed

## M3 — Pointer, click, permissions, menu bar
- [ ] InputSynth: move, down/up, click, double, right, drag
- [ ] Permissions flow + welcome window
- [ ] MenuBar: enable/disable, status icon, quit
- [ ] Engage/disengage: hotkey + palm hold + out-of-frame timeout; camera pauses when disengaged
- [ ] Line-by-line review of Mac files done
- [ ] Committed

## M4 — Full gesture set
- [ ] Scroll with phases + momentum
- [ ] Two-hand zoom
- [ ] App switcher gesture (or dropped with reason)
- [ ] Precision mode, multi-display jump, dwell-click option
- [ ] Core tests extended
- [ ] Committed

## M5 — Overlay, calibration, settings, sounds
- [ ] Overlay windows per screen: halo, pinch ring, state colors, toasts
- [ ] PiP camera preview with skeleton
- [ ] Calibration flow (corners + pinch test), per-display storage
- [ ] SwiftUI settings window, UserDefaults, export/import
- [ ] Sound generation script + playback, toggle
- [ ] Launch at login
- [ ] Committed

## M6 — Packaging, feel, docs
- [ ] Makefile (build, app, run, install, doctor, clean), scripts/make-app.sh, Info.plist, codesign
- [ ] Threshold sanity pass against synthetic data; tools/tune.md
- [ ] README.md complete including "If the build fails"
- [ ] Committed

## Final pass
- [ ] grep repo for TODO, FIXME, placeholder, stub, "not implemented" — none
- [ ] swift test green; tools/check.sh green; Linux swift build green with Mac target guarded
- [ ] Every Mac file re-read once more for: imports, main-thread UI, queues, retain cycles, CGEvent API names, Info.plist keys
- [ ] GestureCore imports Foundation only
- [ ] DECISIONS.md complete, dropped items explained
- [ ] Release commit

## Owner handoff (for the human, after Claude is done)
1. `xcode-select --install` if not already done.
2. `make app && make run`.
3. Grant Camera, then Accessibility to GesturePointer.app.
4. If the build fails, paste the full terminal output to Claude Code with "fix this build error".
5. Optionally run with `--record session.json` for a minute and hand the file back for tuning.

## Notes / blockers
- M1: `swift build --target GestureCore`, `swift test` (59 tests) and full `swift build` all green on Linux with Swift 6.0.3. Core also covers M4's gestures (scroll momentum, zoom, app switcher, precision, display jump, dwell), tested here.
