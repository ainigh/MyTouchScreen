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

## M7 — Velocity gestures (SPEC-M7)
- [x] `VelocityParams`, centroid + velocity estimation, segment tracker, `VelocityClassifier` in GestureCore
- [x] Composite gestures: double click, drag, two-hand zoom; refractory; noise rejection
- [x] Synthetic generator produces every labeled class with timing/noise variation
- [x] Tests: each class classified correctly ≥ 95% over 200 synthetic samples; `rest` and `jitter` produce zero intents; `reposition-fast` produces zero clicks/scrolls; click lands at anchor; scroll momentum decays monotonically and stops on new segment; frame-rate independence (same input at 30 and 60 fps → same intents)
- [x] `tune` executable: confusion matrix, stats, grid search; Linux-buildable
- [x] App: input-model switch, scroll output with phases at display rate, cursor warp, overlay trail/ripples, "why not?" debug, guided `--record --script`
- [x] `tools/tune.md` written; Settings updated; DECISIONS.md updated
- [x] Linux `swift build` + `swift test` green; `tools/check.sh` green; Mac files reviewed
- [x] Committed: `M7: velocity gestures`

## Hold & wiggle default (owner request)
- [x] `ShakeDetector` + `ShakeParams`, `dwellShake` input model as default (dwell 2 s = click, 3 direction changes in 1 s = scroll mode, palm on/off)
- [x] Tests: 2 s hold clicks once, engaging never clicks, ordinary moves never click/scroll, wiggle scrolls on its axis, 2 changes / slow / tiny wiggles don't, mode switch ends scroll
- [x] Settings (third model + Hold & wiggle section), menu hint, welcome text, README, DECISIONS
- [x] Linux build + 118 tests green; check.sh green; Mac files reviewed (not compiled)
- [x] Committed

## Hold & wiggle: left-hand modifier (owner request)
- [x] Right hand points; left hand up = drag (press on clear move), left down = drop; left up + wiggle = zoom; no right click
- [x] Pointer stays on the largest display (setting to restore edge jumps)
- [x] Tests: drag press/drop position and timing, small-move drag, left-hand dropout, zoom in/out with no press, left hand alone never points, largest display
- [x] Settings, menu hint, README, DECISIONS; Linux build + tests + check.sh green; Mac files reviewed (not compiled)
- [x] Committed
- [ ] Parked: calibration by demonstrating each gesture (owner idea, later)

## Owner recording + engaged-display (owner request)
- [x] Analysed `recordings/owner-freeform-2026-10-12.json`: wiggles were finger wags → Hold & wiggle follows the fingertip; stillness and dwell thresholds set from measured real jitter
- [x] Pointer stays on the display the mouse is on at engage (palm, hotkey or menu); no edge jumps
- [x] Regression test replays the owner recording; 129 tests, build, check.sh green; Mac change (pipeline passes the mouse location while disengaged) reviewed, not compiled
- [x] Committed

## Lock & wiggle click, fist drag, two-fist zoom/scroll, two-palm toggle (owner request)
- [x] Rest 1 s locks the cursor; it stays locked 1 s after the next movement; a wiggle then clicks (only click; double click by wiggling again); a fist then drags, opening it drops
- [x] Two fists: last stroke before resting zooms (spread) or scrolls (both move); other hand no longer a modifier; one-hand wiggle scroll removed
- [x] Both open palms toggle engagement (one palm does nothing), all models
- [x] Tests (138): lock, click position, wake timing, double click, fist drag/drop, two-fist zoom in/out/ratchet, scroll down/sideways/ratchet, palms; owner recording re-baselined
- [x] Settings, hints, README, DECISIONS; Linux build + tests + check.sh green; Mac changes (strings, Theme case, settings sliders) reviewed, not compiled
- [x] Committed

## Owner handoff (for the human, after Claude is done)
1. `xcode-select --install` if not already done.
2. `make app && make run`.
3. Grant Camera, then Accessibility to GesturePointer.app.
4. If the build fails, paste the full terminal output to Claude Code with "fix this build error".
5. Optionally run with `--record session.json` for a minute and hand the file back for tuning.

## Notes / blockers
- Toolchain note (Oct 2026): on this sandbox CPU the Swift 6.0.3 `swift-driver` binary dies with "Illegal instruction"; symlinking `swift`, `swiftc` and `swift-driver` to `swift-frontend` (the legacy driver) in /opt/swift/usr/bin makes `swift build` / `swift test` work.
- M7 (Oct 2026): 105 tests green on Linux (Swift 6.0.3), full `swift build` (incl. the new `tune` target) and check.sh green. Velocity accuracy on 200 synthetic samples per class, half at 30 fps: click 197, right-click 199, double-click 193, scroll-up 200, scroll-down 200, reposition-fast/slow 200, fine-target 200, drag 199, rest 200, jitter 200, out-of-frame 200, zoom 200. Thresholds are tuned against synthetic hands only — no owner recording yet (see "Owner loop after M7" in SPEC-M7). Mac layer (input-model switch, overlay trail/flash/why-not readout, settings, guided `--record --script`) written and independently reviewed (no compile issues found; guided-session warm-up, sounds, disengage-on-finish, run-loop mode and overlay-rebuild fixes applied) but NOT compiled — no macOS here.
- Fix pass (Oct 2026): 77 tests green on Linux (Swift 6.0.3), full `swift build` and check.sh green. Core: tick timer only while gliding (`needsTicks`), settings change mid-glide no longer drops momentum-ended (regression test). Mac (review only, not compiled): launch-at-login toggle reflects the real state after a failed change, camera restarts after runtime errors with backoff, reconnecting the chosen camera picks it back up.
- Bug-hunt pass (Oct 2026): 75 tests green on Linux (Swift 6.0.3). Core: stuck button/scroll on hand swap, unmatched mouse-up, real mouse taking over mid-drag, NaN/trap guards for imported settings and replay aspect. Mac (review only, not compiled): delegate lifetime + SIGINT/SIGTERM quit path, calibration window never closing, real mouse blocked during synthetic drag, camera fps exception, mirroring pinned off, kill hotkey with revoked camera, quit-time stray clicks, settings re-apply hitch, updater bundle name + commit/codesign verification, CI script injection, BSD-sed check.sh.
- Mac layer second review (independent, compiler-focused) found and fixed: an inaccessible memberwise init, `log` shadowed by a property, `Joint` ambiguous with macOS 15 SDK's Vision, `Rect` ambiguous with MacTypes, SwiftUI views needing @MainActor on the macOS 14 SDK. Plus runtime fixes (no camera prompt before onboarding, NaN guard, queue-confined output options, hotkey toggles from the machine's own state).
- Mac layer (M2–M5) is written and reviewed but has NOT been compiled: no macOS here. A GitHub Actions workflow (macOS 14) was added to compile it, but every job failed instantly with no logs — Actions minutes/billing aren't available to this private repo. The workflow now runs on pull requests and on demand only. First owner build may surface errors: README → "If the build fails".
- M1: `swift build --target GestureCore`, `swift test` (59 tests) and full `swift build` all green on Linux with Swift 6.0.3. Core also covers M4's gestures (scroll momentum, zoom, app switcher, precision, display jump, dwell), tested here.
