# SPEC.md — Gesture Pointer for macOS

> **Gesture set superseded (Oct 2026, owner request):** pinch-to-click, pinch drag, fist scroll,
> two-hand pinch zoom, the app switcher, dwell click and the pinch calibration step were removed.
> Wisp now has one gesture model: the cursor follows the index finger while it moves calmly and
> freezes while it moves fast; a wiggle clicks any time; a fist drags; two open palms toggle.
> Two-fist zoom/scroll and the rest-to-lock step were removed later (owner request). See README →
> Gesture cheat sheet and DECISIONS.md. The rest of this spec still applies.

## The pitch

A menu-bar app that makes any Mac screen behave like a touch screen you don't have to touch.
Point your index finger at the screen and a cursor follows it. Pinch to click, hold the pinch to
drag, make a fist and move to scroll, pinch with both hands to zoom. It works in every app
because it generates real system input. It feels precise, fast and calm, not like a tech demo.

The owner has delegated all design decisions. Pick a name, a visual identity for the overlay,
and the exact gesture thresholds. Write the concept to `DECISIONS.md` before coding.

## User experience

### First run
1. App appears in the menu bar (no Dock icon). A welcome window explains the two permissions
   and asks for them in order: Camera, then Accessibility (open System Settings to the right
   pane via the `x-apple.systempreferences:` URL). Show live status of each.
2. Camera picker: list devices; prefer Continuity Camera (iPhone) if present, else built-in.
3. Calibration (20 seconds, skippable with sensible defaults): user points at the four
   corners of the screen in turn while the overlay highlights each corner; this defines the
   active box in camera space. Then a quick pinch test ("pinch three times") to set the pinch
   threshold for this hand size and distance.
4. Done. Overlay shows a cursor halo following the finger.

### Engagement
- Tracking is on only when engaged. Engage by raising an open palm toward the camera and
  holding it for ~600 ms (the overlay shows a filling ring), or via the global hotkey
  (default ⌃⌥⌘G). Disengage with the same gesture, the hotkey, or by lowering the hand out
  of frame for 2 s. When disengaged the real mouse works normally and the camera pauses.
- Engaged state is obvious: menu bar icon changes, overlay halo visible, a brief chime.

### Gesture set (the baseline; refine freely)
| Gesture | Action |
|---|---|
| Index finger pointing, hand in frame | Cursor follows index fingertip (filtered, mapped through calibration) |
| Thumb + index pinch (tap) | Left click |
| Pinch twice quickly | Double click |
| Pinch and hold > 250 ms, then move | Drag; release pinch to drop |
| Thumb + middle pinch | Right click |
| Fist (all fingers curled) + move hand | Scroll (vertical and horizontal), with momentum on release |
| Two hands, both pinching, move apart/together | Zoom (⌘+scroll events, or ⌘+/⌘- fallback per app) |
| Open palm held ~600 ms | Toggle engage / disengage |
| Thumb + ring pinch | ⌘Tab-style app switcher (hold to browse) — optional |
| Hand out of frame 2 s | Disengage |

Rules: pinch distance is normalized by hand size (wrist-to-middle-MCP) so it works at any
distance from the camera. Use hysteresis (enter at 0.35, exit at 0.5 of normalized, tune).
Minimum pinch duration 60 ms to count; refractory 120 ms. While pinching, freeze the cursor
to the position at pinch-start for the first 100 ms so clicks don't drift.

### Pointer quality
- 1€ filter on the fingertip, defaults tuned for a 30 fps camera; re-tune if 60 fps.
- Calibrated active box: a sub-region of camera space maps to the whole screen so small hand
  motions cover the screen. Soft edge clamp. Mirror the camera (the user's right = screen right).
- Multi-display: the cursor lives on the display that contains the current cursor; a hand
  moved to the edge for 400 ms jumps to the adjacent display. Calibration stored per display.
- Precision mode: when the hand moves slowly, apply a gain < 1 for fine targeting (the 1€
  filter already helps; add explicit slow-gain if needed).
- Optional dwell-click for accessibility: hover still for 800 ms → click (off by default).

### Overlay (AppKit, transparent, click-through, all screens, above everything)
- Cursor halo: a soft ring around the system cursor, color-coded by state (hover, pinch
  armed, dragging, scrolling). A pinch-progress ring fills as fingers close.
- Picture-in-picture camera thumbnail (toggleable, draggable corner) with the 21-point
  skeleton drawn, hand chirality labeled, confidence shown.
- Toasts for state changes ("Engaged", "Camera paused", "Accessibility permission needed").
- Hidden entirely when disengaged except a tiny status glyph (also toggleable).
- Visual identity: pick a font (system or SF Mono), an accent color, and stick to it. Dark and
  light mode both look right.

### Menu bar
Enable/disable, engagement status, camera picker, Calibrate…, Settings…, Show camera preview,
Launch at login, Quit. Icon reflects state (idle / engaged / no permission).

### Settings (SwiftUI window, persisted in UserDefaults)
Sensitivity (active box scale), filter minCutoff and beta, pinch thresholds, scroll speed and
natural direction, dwell-click toggle and delay, engage gesture on/off, hotkey, camera device
and resolution, show skeleton, sounds on/off, reset to defaults, export/import settings JSON.

### Sounds
Subtle, optional: engage chime, click tick, drag start/drop, scroll momentum fade. Use
`NSSound` with short synthesized WAVs generated at build time by a script, or `AudioToolbox`
system sounds. No bundled binary assets in git; generate them.

### CLI flags
`--record path.json` (write HandFrame stream while running), `--replay path.json` (drive the
pipeline from a recording, no camera), `--no-overlay`, `--doctor` (print permissions, cameras,
displays, fps measured over 5 s, then exit).

## Technical notes

- **Camera:** `AVCaptureSession` at 1280×720, highest fps the device supports (request 60 if
  available), `kCVPixelFormatType_32BGRA`, sample buffer delegate on a serial background queue,
  `alwaysDiscardsLateVideoFrames = true`.
- **Vision:** one `VNDetectHumanHandPoseRequest` per frame, `maximumHandCount = 2`, run via
  `VNImageRequestHandler(cvPixelBuffer:orientation:)`. Convert normalized points to `HandFrame`
  (flip y; Vision's origin is bottom-left). Skip a frame if the previous request is still
  running.
- **Input:** `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)` for
  move/down/up/dragged; `CGEvent(scrollWheelEvent2Source:units:wheelCount:wheel1:wheel2:wheel3:)`
  with `.pixel` units and scroll phase fields (`.scrollWheelEventScrollPhase`,
  `.scrollWheelEventMomentumPhase`) so apps treat it like trackpad scrolling; keyboard via
  `CGEvent(keyboardEventSource:virtualKey:keyDown:)` with modifier flags. Post to
  `.cghidEventTap`. Mouse coordinates are in global display space with top-left origin.
- **Overlay:** `NSWindow` with `.borderless`, `backgroundColor = .clear`, `isOpaque = false`,
  `ignoresMouseEvents = true`, `level = .screenSaver`, `collectionBehavior = [.canJoinAllSpaces,
  .fullScreenAuxiliary, .stationary]`, one per `NSScreen`, drawing with Core Animation layers.
- **Permissions:** `AVCaptureDevice.requestAccess(for: .video)`;
  `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`. Explain in the UI that
  the `.app` bundle must be the thing granted (not Terminal), which is why `make app` exists.
- **Bundle:** `scripts/make-app.sh` builds release, creates `GesturePointer.app/Contents/{MacOS,Resources}`,
  copies the binary and `Info.plist`, writes `PkgInfo`, runs `codesign --force --deep -s -`.
  `make run` opens it. `make install` copies to `/Applications`.
- **Global hotkey:** a `CGEvent` tap (listen-only) or `NSEvent.addGlobalMonitorForEvents`; the
  tap route requires Accessibility, which the app already needs.
- **Launch at login:** `SMAppService.mainApp.register()` (macOS 13+).

## Milestones and acceptance criteria

### M1 — GestureCore
- `HandFrame`, 1€ filter (1-D and 2-D), calibration mapping, gesture detector with hysteresis,
  pointer state machine emitting `Intent`s, JSON replay format with a synthetic generator.
- Tests: filter smooths a jittery stationary signal to < 0.3 px movement and tracks a fast
  ramp with < 1 frame lag; pinch enters/exits at the right thresholds and never flickers on
  noisy input; double-pinch timing; drag threshold; fist scroll produces scroll intents with
  momentum; engage gesture requires the hold duration; mapping hits screen corners from
  calibrated corners; replay round-trips.
- `swift build` and `swift test` green on Linux. Committed.

### M2 — Camera and tracking (Mac layer, written not run)
- Camera session, device enumeration, Vision tracker producing `HandFrame`s at camera rate,
  `--record`, `--replay`, `--doctor`. `main.swift` runs headless printing one line per frame
  with fps and landmark count when `--no-overlay`.
- Package builds on Linux with Mac files guarded; `tools/check.sh` green. Committed.

### M3 — Pointer and click, permissions, menu bar
- `InputSynth` with move/click/double/right/drag; `Permissions` flow and welcome window;
  `MenuBar` with enable/disable and quit; engage/disengage via hotkey and palm hold.
- Mac files reviewed line by line per `CLAUDE.md`. Committed.

### M4 — Full gesture set
- Scroll with phases and momentum, two-hand zoom, app-switcher gesture (or drop with reason),
  precision mode, multi-display jump, dwell-click option. Core tests extended for each.
  Committed.

### M5 — Overlay, calibration, settings, sounds
- Overlay windows with halo, progress ring, PiP skeleton, toasts; calibration flow; SwiftUI
  settings; sound generation script; launch at login. Committed.

### M6 — Packaging, feel, docs
- `Makefile`, `scripts/make-app.sh`, `Info.plist`, ad-hoc signing, `make install`.
- Default thresholds re-checked against synthetic data; a `tools/tune.md` explaining how to
  record a session with `--record` and send it back for tuning.
- `README.md`: what it is, requirements, `make app && make run`, permissions walkthrough,
  gesture cheat sheet with ASCII hand sketches, settings guide, troubleshooting, "If the build
  fails" instructions. Committed as `Release: <name> v1.0`.

## Explicitly delegated

Name, overlay look, exact thresholds, which optional gestures survive, menu wording, sound
design, and anything not specified. Make it feel like an Apple-quality utility.
