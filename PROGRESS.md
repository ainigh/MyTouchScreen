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
- [x] Camera.swift (device list, Continuity Camera preference, 720p, best fps)
- [x] HandTracker.swift (Vision, background queue, frame dropping, y-flip, chirality)
- [x] main.swift flags: --record --replay --no-overlay --doctor (+ --dry-run, --help)
- [x] Linux build still green with guards; tools/check.sh green
- [x] Committed

## M3 — Pointer, click, permissions, menu bar
- [x] InputSynth: move, down/up, click, double, right, drag
- [x] Permissions flow + welcome window
- [x] MenuBar: enable/disable, status icon, quit
- [x] Engage/disengage: hotkey + palm hold + out-of-frame timeout; camera pauses when disengaged (standby rules in DECISIONS)
- [x] Line-by-line review of Mac files done
- [x] Committed

## M4 — Full gesture set
- [x] Scroll with phases + momentum
- [x] Two-hand zoom
- [x] App switcher gesture (implemented, off by default — reason in DECISIONS)
- [x] Precision mode, multi-display jump, dwell-click option
- [x] Core tests extended
- [x] Committed

## M5 — Overlay, calibration, settings, sounds
- [x] Overlay windows per screen: halo, pinch ring, state colors, toasts
- [x] PiP camera preview with skeleton
- [x] Calibration flow (corners + pinch test), per-display storage
- [x] SwiftUI settings window, UserDefaults, export/import
- [x] Sound generation + playback, toggle (synthesized at launch from GestureCore recipes)
- [x] Launch at login
- [x] Committed

## M6 — Packaging, feel, docs
- [x] Makefile (build, app, run, install, doctor, clean), scripts/make-app.sh, Info.plist, codesign
- [x] Threshold sanity pass against synthetic data (30/60 fps, with noise); tools/tune.md
- [x] README.md complete including "If the build fails"
- [x] Committed

## Final pass
- [x] grep repo for TODO, FIXME, placeholder, stub, "not implemented" — none
- [x] swift test green; tools/check.sh green; Linux swift build green with Mac target guarded
- [x] Every Mac file re-read once more for: imports, main-thread UI, queues, retain cycles, CGEvent API names, Info.plist keys
- [x] GestureCore imports Foundation only
- [x] DECISIONS.md complete, dropped items explained
- [x] Release commit

## Owner handoff (for the human, after Claude is done)
1. `xcode-select --install` if not already done.
2. `make app && make run`.
3. Grant Camera, then Accessibility to GesturePointer.app.
4. If the build fails, paste the full terminal output to Claude Code with "fix this build error".
5. Optionally run with `--record session.json` for a minute and hand the file back for tuning.

## Notes / blockers
- Mac layer second review (independent, compiler-focused) found and fixed: an inaccessible memberwise init, `log` shadowed by a property, `Joint` ambiguous with macOS 15 SDK's Vision, `Rect` ambiguous with MacTypes, SwiftUI views needing @MainActor on the macOS 14 SDK. Plus runtime fixes (no camera prompt before onboarding, NaN guard, queue-confined output options, hotkey toggles from the machine's own state).
- Mac layer (M2–M5) is written and reviewed but has NOT been compiled: no macOS here. A GitHub Actions workflow (macOS 14) was added to compile it, but every job failed instantly with no logs — Actions minutes/billing aren't available to this private repo. The workflow now runs on pull requests and on demand only. First owner build may surface errors: README → "If the build fails".
- M1: `swift build --target GestureCore`, `swift test` (59 tests) and full `swift build` all green on Linux with Swift 6.0.3. Core also covers M4's gestures (scroll momentum, zoom, app switcher, precision, display jump, dwell), tested here.
