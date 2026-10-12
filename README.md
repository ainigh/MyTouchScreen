# Wisp — point at your Mac, hold still to click

Wisp is a menu-bar app that turns your Mac's camera into a touch-free pointing device.
Point your right index finger at the screen and a soft halo follows it. By default (*Hold &
wiggle*) every movement moves the cursor, holding still for 2 seconds clicks, wiggling your
hand back and forth scrolls, and raising your left hand turns movement into a drag (lower it to
drop; wiggle with it up to zoom). Two other input models are one switch away in Settings: *Velocity*
(tap the air to click, flick to scroll) and *Pose* (pinch to click, fist to scroll). It
generates real system input, so it works in every app.

Everything runs on the Mac: Apple's Vision framework finds 21 points on your hand, and no
video is stored or sent anywhere.

The app bundle is `GesturePointer.app`; inside, it calls itself **Wisp**.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon.
- Xcode command-line tools (`xcode-select --install`). Xcode itself is not needed.
- A camera: the built-in one works. An iPhone as a Continuity Camera at eye level works best.

## Install

The repository is private, so installing goes through gh (GitHub's command line tool), signed
in. The installer sets gh up if it's missing (it needs [Homebrew](https://brew.sh) for that).
Paste this in Terminal:

```bash
gh api -H "Accept: application/vnd.github.raw" repos/ainigh/MyTouchScreen/contents/install.sh | bash
```

It downloads the latest release into `~/Applications/GesturePointer.app` and opens it. If there's
no release yet (GitHub Actions hasn't built one), it builds from the source instead. That needs
Apple's command line tools (`xcode-select --install`) with Swift 5.9 or newer; if those are older
but an Xcode 15 or newer is installed, it uses that Xcode.

To install a branch that isn't merged yet, build it here and follow that branch for updates:

```bash
gh api -H "Accept: application/vnd.github.raw" "repos/ainigh/MyTouchScreen/contents/install.sh?ref=BRANCH" | WISP_BRANCH=BRANCH bash
```

If the new copy quits as soon as it opens, the installer puts the one you had back and says where
the crash report is. Running the install line again is always safe: it reinstalls.

## Updates

Wisp follows `main` (or the branch it was installed from). It checks at launch, every 6 hours,
and when you choose **Check for Updates…** in the menu-bar menu. The menu always shows the
version and commit you're on. When the branch has a commit this copy wasn't built from, a toast
says so and the menu offers:

- **Update to v1.0.N**: GitHub already built that commit. Wisp downloads it, swaps itself and
  reopens.
- **Update (build here)**: GitHub hasn't built it (the build is still running, or Actions is off
  for the repository). Wisp downloads that commit's source, builds it for this Mac, swaps itself
  and reopens. This takes a minute or two; the build output goes to
  `~/Library/Logs/Wisp/update.log`.

If an update fails, **Copy Update Details** copies the error and the end of the log, ready to
paste to Claude Code.

GitHub Actions (`.github/workflows/build.yml`) tests and builds every push, and publishes a
release (`v1.0.<run number>`, with `GesturePointer.zip`) for every push to `main`.

**Permissions after an update.** The app is ad-hoc signed, so macOS treats each new build as a
new app and may ask for Camera and Accessibility again; Wisp's Setup window comes up when it
needs them. If Accessibility is already switched on but Wisp still asks, remove GesturePointer
from the list with **−** and turn it on again. To keep permissions across updates, sign with your
own certificate: create a "Code Signing" certificate in Keychain Access (Certificate Assistant →
Create a Certificate…, type *Code Signing*), then run
`defaults write app.wisp.GesturePointer signIdentity "THE CERTIFICATE NAME"` once. Updates built
on your Mac are then signed with it.

## Build it yourself

```sh
make app      # builds release into build/GesturePointer.app (and build/GesturePointer.zip)
make install  # copies it into ~/Applications and opens it
make run      # builds and opens it from build/
```

Other targets: `make doctor` (health report), `make test` (core test suite), `make check`
(static checks), `make clean`. A copy you build yourself still checks for updates and follows
`main`.

## First run: permissions

Wisp needs two permissions and asks for them in order in its Setup window:

1. **Camera** — click *Allow Camera*.
2. **Accessibility** — this lets Wisp move the pointer and click. Click *Open Accessibility
   Settings* and turn on **GesturePointer**.

   Grant it to **GesturePointer.app itself**, not to Terminal. macOS gives permissions to the
   app bundle. After an update or a rebuild, macOS may treat the new build as a different app:
   if clicks stop working, remove the entry with `−` and turn it on again when Wisp asks (see
   Updates).

Then pick a camera and either **Calibrate** (20 seconds: point at each corner as it lights up,
then pinch three times) or **Skip** to use a sensible default area. You can calibrate any
time from the menu bar (*Calibrate This Display…*); each display keeps its own calibration.

## Turning it on and off

- **Engage:** hold up **both hands** as open palms, fingers spread, for about half a second
  (one palm alone does nothing). A ring fills and
  a chime plays. Or press **⌃⌥⌘G** (changeable in Settings).
- **Disengage:** both palms again (held a little longer), the same shortcut, or just drop your
  hand out of view for 2 seconds.
- While engaged, touching the real mouse or trackpad always wins: Wisp pauses for a moment.
- **Off** (menu bar → *Turn Wisp Off*) stops the camera completely.

Standby note: while disengaged with "Both open palms toggle Wisp" enabled, the camera stays on (its
green light too) and Wisp looks at a few frames per second for your palms, using almost no CPU.
Turn that setting off to stop the camera whenever Wisp is disengaged and use the shortcut.

## Gesture cheat sheet — Hold & wiggle (default)

Your **right hand** points. The left hand only joins in for two-hand gestures.

**The lock.** Hold the cursor still for 1 second and it **locks** (the outer ring fills, then
stays full). When you move again, the cursor stays locked for **1 more second** (the ring drains)
— that second is when you click or grab. Do nothing and the cursor unlocks and jumps to where you
point.

| Hands | What you do | Action |
|---|---|---|
| right | point and move | Cursor follows the fingertip |
| right | rest 1 s, then **wiggle** (left-right-left) within the next second | Left click where the cursor is locked. It stays locked, so wiggle again for a double click |
| right | rest 1 s, then make a **fist** within the next second | Press there and drag: the cursor follows the fist (same lock rules — rest, then it waits a second after you move on) |
| right | **open** the fist | Drop where the cursor is (the locked point if it rested) |
| both | **fists**, spread apart, rest | Zoom in |
| both | fists, bring together, rest | Zoom out |
| both | fists, move both the same way, rest | Scroll that way (content follows the fists) |
| both | **open palms**, held still | Engage / disengage |

Notes: only the **last stroke before you rest** counts for two fists — close them, widen them,
rest: zoom in again (a ratchet, like lifting a mouse). Raise-then-lower and rest scrolls down.
The cursor stays put during two-fist gestures. Engaging never clicks by itself, and resting
never clicks — only a wiggle does. There's no right click in this model. With two monitors the
cursor stays on the monitor the mouse pointer was on when Wisp engaged (Settings → Pointer).
Wiggling the index finger works as well as wiggling the whole hand.
Left-handed? Settings → Gestures → *Pointing hand: Left* swaps the roles.

## Gesture cheat sheet — Velocity mode

No finger pose needed: Wisp watches how fast and how far your whole hand moves. Tiny or slow
movements just move the cursor; only short, quick taps and long, fast flicks do something.

| Gesture | Action |
|---|---|
| Point and move | Cursor follows the fingertip, live, even during flicks |
| Hold still a moment, then one quick tap down and back | Left click — where the cursor was before the tap |
| Two quick taps | Double click |
| Quick tap sideways | Right click (Settings can swap axes or make any tap a left click) |
| Long, fast flick up / down | Scroll, with momentum; the cursor snaps back to where the flick started |
| Flick sideways and back | Horizontal scroll |
| Tap, then move within ⅓ s | Drag from the tap; hold still ½ s (or tap again) to drop |
| Both hands moving apart / together quickly | Zoom in / out |
| Open palm held still | Engage / disengage (the one pose Velocity mode uses) |

Tips: a tap is short — like tapping a table, a few centimetres, out and back in about 0.15 s —
and starts from a still hand. Moving the pointer quickly up or down at full speed scrolls; move
diagonally or a bit slower to reposition. A new flick stops a scroll glide immediately. If a
gesture doesn't do what you expect, turn on the "why not?" readout (Settings → Gestures) and see
`tools/tune.md`.

## Gesture cheat sheet — Pose mode

Settings → Gestures → Input model → **Pose (pinch)**.

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

- **Velocity mode:** during a flick a short trail runs from where it started; when it's
  classified, a flash appears there — a ripple for a click, a double ripple for a double click,
  a ring for a right click, an arrow for the scroll direction. The optional **"why not?"
  readout** (bottom-left) shows the last flick's duration, distance, path, peak speed, axis and
  the rule that decided.
- **Halo** around the cursor, colour-coded: teal = pointing, amber = fingers closing (the inner
  ring fills as the pinch closes), violet = dragging, blue = scrolling, rose = zooming.
- **Outer ring** fills during a palm hold (engage/disengage) or a dwell click; in Hold & wiggle it
  fills as the cursor settles, stays full while locked and drains through the second after you move.
- **Edge glow** while you hold the cursor against an edge to jump displays.
- **Toasts** at the top of the screen for state changes ("Engaged", "Standing by", "Camera
  paused", "Accessibility permission needed").
- **Camera preview** (menu → *Show Camera Preview*): a small mirrored picture with the tracked
  hand skeleton, which hand it is and the tracking confidence. Drag it anywhere; it snaps to the
  nearest corner.
- When disengaged, only a tiny dot in the bottom-right corner remains (can be turned off).

## Settings

Menu bar → *Settings…*

- **Pointer:** *Stay on the display the mouse is on when Wisp engages* (on by default; off =
  edge jumps between displays), *Active area* (how much hand movement covers the screen), *Steadiness* and
  *Responsiveness* (the 1€ filter's min cutoff and beta), *Rest lock* (how firmly a still cursor
  holds), *Precision* (slow movements are scaled down for fine targeting).
- **Gestures:** *Input model* (Hold & wiggle / Velocity / Pose). Hold & wiggle: how long a rest locks the cursor and
  how long it stays locked after you move, how still is still, the click wiggle (changes of
  direction, within how long, smallest stroke), the double-click window, and for two fists the
  smallest stroke, rest time and zoom strength; scroll speed and direction. Velocity: which tap direction is the left
  click, right click and drag on/off, scroll gain and momentum, scroll direction (follows the
  system by default), the "why not?" readout, and an *Advanced* section with every Velocity
  threshold plus *Reset to tuned defaults*. Pose: pinch thresholds, hold-to-drag time, scroll speed and direction, momentum,
  zoom on/off and how zoom is sent (⌘+/⌘− keys, or ⌘+scroll), app switcher, dwell click,
  palm-to-engage, which hand points.
- **Camera:** device (automatic prefers an iPhone), resolution (720p recommended), preview,
  skeleton, calibration.
- **General:** shortcut, sounds, status dot, launch at login, export/import settings as JSON,
  reset to defaults.

## Troubleshooting

Run `~/Applications/GesturePointer.app/Contents/MacOS/GesturePointer --doctor` (or `make doctor`
in a checkout) first. It prints permissions, cameras, displays and measures the camera's
frame rate and Vision's speed for 5 seconds, and lists anything wrong.

| Problem | Fix |
|---|---|
| Halo moves but nothing clicks or moves | Accessibility isn't granted to *this build* of GesturePointer.app. Toggle it off/on in System Settings → Privacy & Security → Accessibility. |
| Menu-bar icon shows a warning triangle | A permission is missing: menu → *Setup & Permissions…* |
| Cursor shimmers | Better light on your hand; Settings → Pointer → lower *Steadiness* or raise *Rest lock*. |
| Cursor feels sluggish | Raise *Responsiveness*; check `make doctor` shows ≥ 30 fps. |
| Velocity: taps missed, or moving the pointer clicks/scrolls | Turn on the "why not?" readout (Settings → Gestures), reproduce it, and paste the readout to Claude Code — or record a guided session (`tools/tune.md`). |
| Pose: clicks fire by themselves / are missed | Re-run *Calibrate This Display…* (it learns your pinch), or adjust *Pinch closes at*. |
| Can't reach screen corners | Calibrate, or lower *Active area*. |
| Shortcut does nothing | Another app owns it; pick another in Settings → General. |
| An update failed | Menu → **Copy Update Details**, paste it to Claude Code. Or rerun the install line. |
| Need help tuning | Record a guided session (`--record session.json --script`, see `tools/tune.md`) and send the file. |

Command-line flags (run the binary inside the bundle,
`~/Applications/GesturePointer.app/Contents/MacOS/GesturePointer`):

```
--record <file.json>   record the hand-landmark stream while running
--script               with --record: guided tuning session (prompts + labeled segments)
--replay <file.json>   drive the app from a recording instead of the camera, then quit
--dry-run              with --replay: print intents instead of moving the cursor
--no-overlay           no overlay; print one line per camera frame (fps, landmarks)
--doctor               health report, then exit
```

## If the build fails

This app was written on Linux, where Apple's frameworks can't be compiled; the gesture engine
(`GestureCore`) is fully tested there, and the macOS layer is compiled by the repository's CI on
macOS. If `make app` fails on your Mac anyway:

1. Run `make app 2>&1 | tee build.log` (for the installer: rerun the install line and copy all
   of its output; for an in-app update: menu → **Copy Update Details**).
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
Sources/Tune/               tune: confusion matrix + grid search over a labeled recording
recordings/                 labeled sessions the tests replay (see tools/tune.md)
Tests/GestureCoreTests/     `swift test`
install.sh                  one-line install (release, or build from source), with rollback
scripts/make-app.sh         bundle + sign + zip (CI, the installer and the updater all use it)
tools/check.sh, tools/tune.md
```

Design decisions and every tuned threshold, with reasons, are in `DECISIONS.md`.
