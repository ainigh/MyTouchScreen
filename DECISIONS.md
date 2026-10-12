# DECISIONS.md

One line per judgment call, newest at the bottom. All delegated by the owner.

## Concept
- Product name: **Wisp** — a small, calm light that follows your finger. The bundle/executable stays `GesturePointer` (as the build contract requires); "Wisp" is the display name, menu wording and overlay identity.
- Tone: quiet utility. No splash, no mascots; the overlay only says what changed, in two or three words.
- Accent color: Wisp Teal `#2EC4B6` (hover/engaged). State colors: pinch armed Amber `#FFB547`, dragging Violet `#8B7CF6`, scrolling Sky `#4D9DFF`, zooming Rose `#FF6B9A`, warning Coral `#FF6B5B`. All tested against both light and dark backgrounds by drawing on a translucent dark/light "puck" behind the ring.
- Typography: SF Pro Rounded (system font with `.rounded` design) for toasts and HUD labels; SF Mono (`monospacedSystemFont`) for numbers (fps, confidence, latency).
- Halo: 34 pt soft ring (2.5 pt stroke + 10 pt blurred glow) centered on the cursor; an inner progress arc fills as the pinch closes; a filled dot appears when the pinch is down.
- Menu-bar glyph: SF Symbols `hand.point.up.left` (standby), `hand.point.up.left.fill` (engaged), `hand.raised.slash` (off / missing permission).

## Gesture thresholds and feel
- Pointer filtering happens in *active-box units* (1.0 = full screen width), so settings are independent of display size. Defaults: 1€ minCutoff 0.6 Hz, beta 6, dCutoff 1 Hz — fast sweeps (screen width in 0.6 s) lag < 0.5 frame; chosen from a grid search in the test suite.
- Added a two-length "leash" dead zone after the 1€ filter: 0.0015 box while moving, 0.005 box (≈9 pt) once still for 250 ms. With Vision-like jitter of 6–8 pt RMS this holds the cursor at exactly 0 movement; the 1€ filter alone cannot get below ~1 pt/frame without becoming sluggish.
- Precision mode: below 0.12 box/s, hand motion is scaled by 0.45 (ramping smoothly to 1 at the threshold); the offset this creates is capped at 0.06 box and drained during fast movement so the absolute hand→screen mapping always comes back.
- Pinch: enter 0.35, exit 0.5 (normalized by wrist→middle-MCP), minimum 60 ms, refractory 120 ms counted from when the fingers opened (counting from the release *confirmation* swallowed real double pinches at 30 fps), release must persist 30 ms so a single glitched frame can't drop a drag.
- Pinch arm distance 0.65: as fingers close, the pointer anchor switches from the fingertip to the index knuckle plus the fingertip offset captured when the closure *began*; the click lands where the user was aiming even though the fingertip moves ~0.5 hand-sizes during a pinch. The pinch-start look-back walks back through recent samples while the fingers were further apart (≤ 400 ms).
- Drag: pinch held 250 ms, or moved > 0.012 box after the 100 ms freeze. Double click: within 400 ms and 2% of screen width; the second click reuses the first click's exact position.
- Right click fires on pinch confirmation (no hold semantics to wait for), so it feels instant.
- Fist = all four fingers' tip→wrist / MCP→wrist ratio < 1.2; extended > 1.45; poses need 80 ms to confirm. Pinches are ignored while the index is curled so a fist never clicks.
- Open palm engage: 600 ms to engage, 800 ms to disengage (slightly longer so an open hand used for pointing doesn't drop out), palm must be still (< 0.6 hand-sizes/s). The palm that toggled must change pose before it can toggle again.
- Hand dropout grace 150 ms (Vision misses frames); after that any held button/modifier is released. Lost for 2 s → disengage.
- Scroll: one box of fist travel = 1600 pt × speed; natural direction by default; momentum with exponential friction 4/s, starts above 120 pt/s, stops below 40 pt/s, integrated exactly so it is tick-rate independent.
- Zoom: ratio of the distance between the two pinch points, normalized by mean hand size (moving both hands toward the camera doesn't zoom). Zoom suppresses the primary hand's click.
- Display jump: 400 ms at an edge with a neighbour in that direction; the hand must return inside (8% margin) before jumping again, otherwise a hand resting at the edge would ping-pong.
- Dwell click (off by default): 800 ms within 0.8% of screen width; fires once, then needs movement.
- Real mouse wins: any real mouse movement suppresses hand output for 0.8 s and moves the pointer to the mouse's display.
- Default (uncalibrated) active box: 42% × 46% of the camera image centered at (0.5, 0.45), mirrored, with 4% overshoot past each edge so the menu bar and Dock are reachable without stretching.

## Technical
- Landmark coordinates are stored un-mirrored, top-left origin, normalized to the image; every distance is measured after undoing the 16:9 stretch (`HandFrame.imageAspect`), otherwise pinch and curl ratios change as the hand rotates.
- Calibration uses a homography (not bilinear) from the four pointed corners, because pointing from an angle produces a perspective-distorted quad. Mirroring falls out of the calibration for free.
- `GestureConfig` decoding is lenient (missing keys keep defaults) so exported settings survive app updates.
- Replay format: one JSON document, one frame per line, written incrementally; a file cut off by a crash is repaired on load by closing the array after the last complete frame.
- Threading: camera frame queue runs Vision synchronously (AVFoundation's `alwaysDiscardsLateVideoFrames` drops frames while it's busy, so nothing queues); frames hop to a serial pipeline queue that owns the state machine and posts CGEvents directly; the main thread only gets coalesced snapshots (at most one pending hop), so UI can never add cursor latency.
- Frame timestamps are `CACurrentMediaTime()` at arrival rather than sample-buffer PTS: the same clock as the momentum ticks, without depending on the capture session's clock.
- `CGEventSource.localEventsSuppressionInterval = 0`: by default synthetic events suppress the real mouse/keyboard for 250 ms, which would violate "never swallow real mouse input".
- Our events carry `eventSourceUserData = "WISP"`; the real-mouse monitor also ignores events within 2 pt of a position we posted in the last 0.5 s, in case the marker doesn't survive into NSEvent.
- Global hotkey uses Carbon `RegisterEventHotKey`: permission-free, consumes the keystroke, decades-stable. (Event tap / NSEvent monitor would leak the key to the front app.)
- Standby: when disengaged with palm-engage on, the camera keeps running but Vision only processes 8 fps (software throttle — changing the device frame rate at runtime risks AVFoundation exceptions). With palm-engage off, the camera stops completely. This resolves the spec's tension between "camera pauses when disengaged" and "engage by raising a palm". The camera light stays on in standby; README says so.
- Sounds are synthesized at launch from recipes in `GestureCore/SoundSynth.swift` (testable on Linux) instead of a build-time script: no binary assets, no extra build step that could fail.
- PiP preview mirrors the video with a layer transform and maps skeleton points itself (aspect-fill math), rather than relying on connection mirroring and `layerPointConverted`, whose behaviour with mirrored, y-up macOS layers I can't verify without a Mac.
- Mac UI classes are `@MainActor`; closures that run on background queues are built in `nonisolated static` helpers so they never inherit main-actor isolation; main hops use `MainActor.assumeIsolated` inside `DispatchQueue.main.async`.
- Display identity = display UUID (`CGDisplayCreateUUIDFromDisplayID`), so per-display calibration survives reboots and re-plugging.
- Replay in the app starts engaged and quits when done; `--dry-run` prints intents instead of posting. `gesture-replay` (Foundation-only executable) does the same on any OS.
- Added a GitHub Actions workflow (macOS 14 + Linux) so the Mac layer is actually compiled; the repo is private, so each push costs macOS runner minutes. The owner can delete `.github/workflows/build.yml` if unwanted.
- Swift tools version 5.9 (Swift 5 language mode) so the Mac layer's GCD/delegate code doesn't need Swift 6 strict-concurrency annotations to compile.

## Technical

## Dropped or changed spec items
- App switcher (thumb + ring pinch → ⌘⇥, slide to browse) is implemented but **off by default**: Vision's ring-finger tip is the least reliable joint, and an accidental ⌘⇥ is disruptive. One toggle in Settings → Gestures.
- Zoom "per app" choice became one global setting (⌘+/⌘− keys by default, or ⌘+scroll): there's no reliable way to know which apps zoom on ⌘-scroll, and a hard-coded list would rot.
- "Camera pauses when disengaged" → standby at 8 fps Vision while palm-engage is on (see Technical); full stop when it's off or Wisp is turned off.
- Sounds generated at launch, not by a build script (see Technical).
- No app icon file: an `.icns` is a binary asset; the app lives in the menu bar and uses SF Symbols there.

## Install and updates (modelled on ainigh/tool-mac-tool)
- One-line install through `gh` (`install.sh`): the repository is private, so gh signed in is the one auth path that works for both the release download and the source tarball. Release first; build from source when there's no release, `WISP_FROM_SOURCE=1`, or `WISP_BRANCH` is set. Keeps the previous copy until the new one is seen running for 8 s, else restores it.
- Installs into `~/Applications` (no admin rights, same as tool-mac-tool); `make install` now uses the same place so there's one copy to grant permissions to.
- In-app updater follows the branch recorded in Info.plist (`WispBranch`) and compares the branch head with `WispCommit`; prebuilt when the latest release was made from that exact commit, else builds here with `scripts/make-app.sh`. The decision logic (`UpdatePlan`, `Version`, `Release`, `Commit`, Swift version parsing) lives in GestureCore and is tested on Linux.
- Release versions are `1.0.<CI run number>`; local/source builds are `1.0-<short sha>`.
- `make-app.sh` now writes to `build/` and produces `GesturePointer.zip`, so CI, the installer and the updater all build the same way. Requires Swift ≥ 5.9 (the package's tools version), with an installed-Xcode fallback.
- Optional `WISP_SIGN_IDENTITY` / `signIdentity` default: ad-hoc signatures change every build, so macOS forgets Camera/Accessibility grants after an update; a stable self-made code-signing certificate keeps them. Optional because creating a certificate needs the user.
- The updater disengages Wisp before restarting so no button or modifier can be left held.
- CI back to running on every push (as in tool-mac-tool) since releases come from pushes to main; when Actions isn't available, installs and updates fall back to building on the Mac.
- When a different hand takes over as the pointing hand, any drag/scroll/zoom/app-switch the old hand held is cancelled immediately (mouse-up / scroll ended), since the reset detector will never report its end.
- A drag that began while real-mouse priority suppressed output sends neither down nor up; the mouse-up is only emitted if its mouse-down was sent.
- Out-of-range imported settings are bounded where they could crash or NaN: app-switcher step floor 0.01 box, momentum friction floor 0.1/s, non-positive box scale treated as 1; replay frames with non-positive image aspect are rejected.
- Updater verifies the new bundle before swapping it in: same bundle id, `WispCommit` equal to the commit being installed, and `codesign --verify --deep --strict` (catches truncated or tampered bundles; authenticity rests on HTTPS/gh from GitHub). It looks for `GesturePointer.app` (what make-app.sh zips), not the installed copy's possibly renamed bundle name.
- The camera preview pins its connection's mirroring off; the mirror comes only from the layer transform, so the skeleton overlay always lines up whatever the per-camera default is.
- check.sh uses POSIX `[[:space:]]` rather than `\s` so `make check` also works with macOS's BSD sed.
- The camera's data-output connection pins mirroring off too (automatic adjustment disabled), so Vision always sees the unmirrored image GestureCore assumes, whatever the camera.
- Camera asks for 60 fps only when a frame-rate range of the chosen format contains it; otherwise it takes the format's own maximum, since an unsupported frame duration raises an uncatchable exception.
- InputSynth permits local mouse/keyboard events in the remote-mouse-drag suppression state as well, so the real mouse keeps working during a pinch-drag.
- Quit (menu, Ctrl-C or SIGTERM) disengages the state machine, releases held buttons/modifiers and stops InputSynth posting before exit; the hotkey always disengages, even if camera access was revoked.
- If the real mouse moves during a hand drag, the synthetic button is released at the real mouse position and the rest of that pinch is ignored, so the real mouse never drags what the hand grabbed.
