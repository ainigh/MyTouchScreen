# Wisp — point at your Mac, pinch to click

Wisp is a menu-bar app that turns your Mac's camera into a touch-free pointing device.
Point your index finger at the screen and a soft halo follows it. Pinch to click, hold the
pinch to drag, make a fist and move to scroll, pinch with both hands to zoom. It generates real
system input, so it works in every app.

Everything runs on the Mac: Apple's Vision framework finds 21 points on your hand, and no
video is stored or sent anywhere.

The app bundle is `GesturePointer.app`; inside, it calls itself **Wisp**.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon.
- Xcode command-line tools (`xcode-select --install`). Xcode itself is not needed.
- A camera: the built-in one works. An iPhone as a Continuity Camera at eye level works best.

## Build and run

```sh
make app      # builds release and assembles + ad-hoc signs GesturePointer.app
make run      # builds the app and opens it
```

Other targets: `make doctor` (health report), `make install` (copy to /Applications),
`make test` (core test suite), `make check` (static checks), `make clean`.

## First run: permissions

Wisp needs two permissions and asks for them in order in its Setup window:

1. **Camera** — click *Allow Camera*.
2. **Accessibility** — this lets Wisp move the pointer and click. Click *Open Accessibility
   Settings* and turn on **GesturePointer**.

   Grant it to **GesturePointer.app itself**, not to Terminal. macOS gives permissions to the
   app bundle, which is why `make app` exists. If you rebuild, macOS may treat the new build as
   a different app: if clicks stop working, turn the switch off and on again (or remove the
   entry with `−` and re-add the app).

Then pick a camera and either **Calibrate** (20 seconds: point at each corner as it lights up,
then pinch three times) or **Skip** to use a sensible default area. You can calibrate any
time from the menu bar (*Calibrate This Display…*); each display keeps its own calibration.

## Turning it on and off

- **Engage:** hold up an open palm, fingers spread, for about half a second. A ring fills and
  a chime plays. Or press **⌃⌥⌘G** (changeable in Settings).
- **Disengage:** the same palm (held a little longer), the same shortcut, or just drop your
  hand out of view for 2 seconds.
- While engaged, touching the real mouse or trackpad always wins: Wisp pauses for a moment.
- **Off** (menu bar → *Turn Wisp Off*) stops the camera completely.

Standby note: while disengaged with "Open palm toggles Wisp" enabled, the camera stays on (its
green light too) and Wisp looks at a few frames per second for your palm, using almost no CPU.
Turn that setting off to stop the camera whenever Wisp is disengaged and use the shortcut.

## Gesture cheat sheet

```
  POINT  — cursor follows        PINCH (tap) — click            PINCH twice — double click
                                                                 quickly
      |                              _                               _    _
      |                             ( )                             ( )  ( )
    __|__                          /_ \__                          /_ \ /_ \
   |  ___|                         |  ___|                          tap  tap
   | |___|                         | |___|
   |_____|                         |_____|

  PINCH + HOLD, move — drag      THUMB + MIDDLE — right click    FIST + move — scroll
                                                                 (let go while moving
     _ ~ ~ ~ ~ ~>                     |                           for momentum)
    ( )   hold 1/4 s                 _|                               ____
   /_ \__                           ( )|                             |####|  ^
   |  ___|                         /_ \|_                            |####|  |
   | |___|                         |  ___|                           |____|  v
   |_____|                         |_____|

  BOTH HANDS PINCH,              OPEN PALM, hold still —         THUMB + RING — app switcher
  move apart/together — zoom     engage / disengage              (off by default)

   <- ( )        ( ) ->            | | | |
       /_\      /_\                | | | |  /
                                   |       /
                                   |_______|
```

| Gesture | Action |
|---|---|
| Index finger pointing | Cursor follows the fingertip (smoothed, calibrated, mirrored) |
| Thumb + index pinch, quick | Left click |
| Two quick pinches | Double click |
| Pinch and hold ¼ s (or pinch and move) | Drag; open to drop |
| Thumb + middle pinch | Right click |
| Fist, then move | Scroll both ways; release while moving for momentum |
| Both hands pinching, move apart / together | Zoom in / out |
| Open palm held still | Engage / disengage |
| Thumb + ring pinch, slide sideways | ⌘⇥ app switcher (enable in Settings) |
| Hand held at a screen edge for 0.4 s | Move to the next display |
| Hover still (optional) | Dwell click (enable in Settings) |

Tips: keep your hand about an arm's length from the camera, in front of you rather than in
front of your face. Pinch firmly and briefly. Clicks land where you were pointing just before
your fingers started closing, so you don't need to hold perfectly still.

## The overlay

- **Halo** around the cursor, colour-coded: teal = pointing, amber = fingers closing (the inner
  ring fills as the pinch closes), violet = dragging, blue = scrolling, rose = zooming.
- **Outer ring** fills during a palm hold (engage/disengage) or a dwell click.
- **Edge glow** while you hold the cursor against an edge to jump displays.
- **Toasts** at the top of the screen for state changes ("Engaged", "Standing by", "Camera
  paused", "Accessibility permission needed").
- **Camera preview** (menu → *Show Camera Preview*): a small mirrored picture with the tracked
  hand skeleton, which hand it is and the tracking confidence. Drag it anywhere; it snaps to the
  nearest corner.
- When disengaged, only a tiny dot in the bottom-right corner remains (can be turned off).

## Settings

Menu bar → *Settings…*

- **Pointer:** *Active area* (how much hand movement covers the screen), *Steadiness* and
  *Responsiveness* (the 1€ filter's min cutoff and beta), *Rest lock* (how firmly a still cursor
  holds), *Precision* (slow movements are scaled down for fine targeting).
- **Gestures:** pinch thresholds, hold-to-drag time, scroll speed and direction, momentum,
  zoom on/off and how zoom is sent (⌘+/⌘− keys, or ⌘+scroll), app switcher, dwell click,
  palm-to-engage, which hand points.
- **Camera:** device (automatic prefers an iPhone), resolution (720p recommended), preview,
  skeleton, calibration.
- **General:** shortcut, sounds, status dot, launch at login, export/import settings as JSON,
  reset to defaults.

## Troubleshooting

Run `make doctor` first. It prints permissions, cameras, displays and measures the camera's
frame rate and Vision's speed for 5 seconds, and lists anything wrong.

| Problem | Fix |
|---|---|
| Halo moves but nothing clicks or moves | Accessibility isn't granted to *this build* of GesturePointer.app. Toggle it off/on in System Settings → Privacy & Security → Accessibility. |
| Menu-bar icon shows a warning triangle | A permission is missing: menu → *Setup & Permissions…* |
| Cursor shimmers | Better light on your hand; Settings → Pointer → lower *Steadiness* or raise *Rest lock*. |
| Cursor feels sluggish | Raise *Responsiveness*; check `make doctor` shows ≥ 30 fps. |
| Clicks fire by themselves / are missed | Re-run *Calibrate This Display…* (it learns your pinch), or adjust *Pinch closes at*. |
| Can't reach screen corners | Calibrate, or lower *Active area*. |
| Shortcut does nothing | Another app owns it; pick another in Settings → General. |
| Need help tuning | Record a session (see `tools/tune.md`) and send the file. |

Command-line flags (run the binary inside the bundle,
`GesturePointer.app/Contents/MacOS/GesturePointer`):

```
--record <file.json>   record the hand-landmark stream while running
--replay <file.json>   drive the app from a recording instead of the camera, then quit
--dry-run              with --replay: print intents instead of moving the cursor
--no-overlay           no overlay; print one line per camera frame (fps, landmarks)
--doctor               health report, then exit
```

## If the build fails

This app was written on Linux, where Apple's frameworks can't be compiled; the gesture engine
(`GestureCore`) is fully tested there, and the macOS layer is compiled by the repository's CI on
macOS. If `make app` fails on your Mac anyway:

1. Run `make app 2>&1 | tee build.log`.
2. Paste the **entire** output (or attach `build.log`) to Claude Code with the words
   **"fix this build error"**. Include the first error, not only the last lines — the first
   error is usually the real one.
3. Also include the output of `sw_vers` and `swift --version`.

## How it's built

```
Sources/GestureCore/        Foundation-only gesture engine (filters, calibration,
                            classifier, state machine, replay, sound synthesis) — tested on Linux
Sources/GesturePointerApp/  macOS shell: camera, Vision, CGEvent input, overlay, menu, settings
Sources/GestureReplay/      gesture-replay: run a recording through the engine on any OS
Tests/GestureCoreTests/     `swift test`
scripts/make-app.sh         bundle + ad-hoc codesign
tools/check.sh, tools/tune.md
```

Design decisions and every tuned threshold, with reasons, are in `DECISIONS.md`.
