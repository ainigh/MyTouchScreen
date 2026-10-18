# Wisp — point at your Mac, wiggle to click

Wisp is a menu-bar app that turns your Mac's camera into a touch-free pointing device.
Point your right index finger at the screen and the cursor goes where it points — like an
invisible laser pointer or a stick touching the screen: fast or slow, the cursor is always
under your finger, and it holds still while your hand does. Wiggle your finger to click where
you were pointing, or make a fist to grab and drag (open it to drop). It generates real system
input, so it works in every app.

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

**Permissions after an update.** The app is ad-hoc signed with a requirement of just its bundle
identifier (`app.wisp.GesturePointer`), so macOS keeps the Camera and Accessibility grants
across updates. (Builds before this change were tied to their exact binary, which is why the
Accessibility switch could look on but not work until removed and re-added.) If that ever
happens anyway, Wisp notices on launch that an earlier build was trusted and this one isn't,
clears its own stale entry and asks again, so you only turn the switch on; the Setup window's
*Open Accessibility Settings* button does the same. To sign with your own certificate instead,
create a "Code Signing" certificate in Keychain Access (Certificate Assistant → Create a
Certificate…, type *Code Signing*), then run
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

Then pick a camera and either **Calibrate** (15 seconds: point at each corner as it lights up)
or **Skip** to use a sensible default area. You can calibrate any
time from the menu bar (*Calibrate This Display…*); each display keeps its own calibration.

## Turning it on and off

- **Engage:** hold up **both hands** as open palms, fingers spread, for about half a second
  (one palm alone does nothing). A ring fills and
  a chime plays. Or press **⌃⌥⌘G** (changeable in Settings).
- **Disengage:** both palms again (held a little longer) or the same shortcut. Taking your hand
  out of view does *not* turn Wisp off: point again and the cursor follows straight away.
- While engaged, touching the real mouse or trackpad always wins: Wisp pauses for a moment.
- **Off** (menu bar → *Turn Wisp Off*) stops the camera completely.

Standby note: while disengaged with "Both open palms toggle Wisp" enabled, the camera stays on (its
green light too) and Wisp looks at a few frames per second for your palms, using almost no CPU.
Turn that setting off to stop the camera whenever Wisp is disengaged and use the shortcut.

## Gesture cheat sheet

Your **right hand** points. The other hand only joins in to turn Wisp on and off. Wisp tracks
two things: your **index finger** and your **fist**.

**A laser pointer.** The cursor goes where your fingertip points, at any speed, with nothing
in between: no slow-down for slow movements, no freezing on fast ones, no drift. A still hand
locks the cursor in place (tracker jitter never reaches the screen); the first real movement
unlocks it and it catches up exactly with your finger.

| Hands | What you do | Action |
|---|---|---|
| right | point | Cursor goes where the fingertip points |
| right | **wiggle** (left-right-left, or up-down-up) | Left click where you were pointing just before the wiggle; the cursor waits there a moment (outer ring lit), then returns under your finger. Wiggle again within 1.5 s for a double click |
| right | make a **fist** and hold it a moment (¼ s) | Press where the cursor was before your hand closed, and drag: the cursor follows the fist |
| right | **open** the fist | Drop where the cursor is |
| both | **open palms**, held still | Engage / disengage |

That table is the default. **Settings → Gestures** (or the menu bar's Click / Drag / Zoom /
Cursor Speed submenus) switches between presets, exactly one of each at a time:

- **Click:** wiggle · pinch (thumb + index) · middle pinch (thumb + middle) · thumb trigger
  (finger gun) · quick fist · dwell (hold still; the ring fills, then it clicks).
- **Drag:** hold a fist · fist to grab, fist to drop · hold a pinch · hold a middle pinch ·
  hold the thumb trigger · off. When click and drag share a hand shape, a quick one clicks
  and a held one drags.
- **Zoom** (sent as ⌘+/⌘− or ⌘-scroll): off · two fists pulled apart · two pinches pulled apart ·
  the other hand's fist raised / lowered · the other hand's pinch raised / lowered.
- **Trajectory** (default: straight lines; Settings → Pointer or menu → *Trajectory*): the
  cursor moves only horizontally or only vertically, whichever way your hand mostly goes, so a
  wavy sideways sweep draws a straight horizontal line and an up-down curve a straight vertical
  one. It switches direction only on a sharp turn (*Turn needed to change direction*, Gentle ↔
  Sharp). To go diagonally, go across then turn. Motion dropped across the line is made up as you
  keep moving, so the cursor drifts back under your finger. *Free* follows the hand in any
  direction. Applies to every cursor speed, target assist and drags.
- **Cursor speed:** direct (1:1) and eight speed-dependent gains (see `PointerResponse`).
- **Target assist** (on by default; menu → *Target Assist*, tuned in Settings → Targets): near a
  button, link, menu, checkbox or text field the cursor slows down, so the same hand movement
  aims more finely there, and a hand that stops just beside one gets pulled onto it. Targets
  you're heading for act from further away; ones you pass beside, and fast moves across the
  screen, are left alone. Moving on brings the cursor back under your finger. It reads what's on
  screen through the Accessibility permission Wisp already has.

Notes for the defaults: engaging never clicks by itself, and resting never clicks — **only a
wiggle does**: pinches, single taps and hovering never click. A fist that flickers for a moment while you
move doesn't start a drag. There's no right click or scroll, and zoom is off unless you pick a zoom preset. With two monitors the
cursor stays on the monitor the mouse pointer was on when Wisp engaged (Settings → Pointer).
Wiggling the index finger works as well as wiggling the whole hand. Wisp stays on while your
hand is out of view (it just watches at a lower frame rate until the hand is back); only the
palms, the shortcut or the menu turn it off.
Left-handed? Settings → Pointer → *Pointing hand: Left* swaps the roles.

## The overlay

- **Halo** around the cursor, colour-coded: teal = pointing, violet with a centre dot = fist
  drag.
- **Outer ring** fills during the two-palm hold (engage/disengage); while pointing it shows
  full while the cursor waits on a click, press or drop point for your hand to settle.
- **Ripple** where a wiggle clicked (a double ripple for a double click).
- **Target outline**: a soft teal outline around the control target assist is drawing the
  cursor to, stronger as the pull grows. Settings → Targets can also outline every target found,
  to see what Wisp sees while tuning.
- **Edge glow** while you hold the cursor against an edge to jump displays.
- **Toasts** at the top of the screen for state changes ("Engaged", "Standing by", "Camera
  paused", "Accessibility permission needed").
- **Camera preview** (menu → *Show Camera Preview*): a small mirrored picture with the tracked
  hand skeleton, which hand it is and the tracking confidence. Drag it anywhere; it snaps to the
  nearest corner.
- When disengaged, only a tiny dot in the bottom-right corner remains (can be turned off).

## Settings

Menu bar → *Settings…*

- **Pointer:** a short "how it works"; *Trajectory* (straight lines or free, and how sharp a turn
  switches direction); then three things. *Steadiness* (Snappy ↔ Steady): move
  it toward Steady if the cursor shivers while your hand is still, toward Snappy if it trails
  behind your finger. *Hand movement to cover the screen* (Less ↔ More). *Pointing hand*. With
  more than one display, *Stay on the display the mouse is on when Wisp turns on*.
- **Targets** (target assist): on/off, then sliders to experiment with while pointing —
  *Slow down on targets*, *Magnet*, *Reach*, *Anticipate where I'm heading*, *Get back under my
  finger* — which kinds of control count (buttons, links, menus, checkboxes/tabs, text fields;
  list rows and other clickable things are off by default), and the two outlines.
- **General:** the on/off shortcut and *Both open palms turn Wisp on and off*, sounds, status
  dot, launch at login, export/import settings as JSON, reset to defaults. (The wiggle and fist
  timings are still in the exported JSON for anyone who wants to fine-tune them.)
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
| Halo moves but nothing clicks or moves | Accessibility isn't granted to *this build* of GesturePointer.app. Menu → *Setup & Permissions…* → *Open Accessibility Settings* (it clears the stale entry), then turn GesturePointer on. |
| Menu-bar icon shows a warning triangle | A permission is missing: menu → *Setup & Permissions…* |
| Cursor won't go diagonally / turns when you don't mean it to | That's the straight-line trajectory. Settings → Pointer → *Turn needed to change direction*: toward Gentle to switch more easily, toward Sharp to switch less; or pick *Free*. |
| Cursor feels sticky or gets pulled where you don't want | Settings → Targets: lower *Slow down on targets* or *Magnet*, or untick the kind of control that gets in the way (or menu → *Target Assist* to switch it off). |
| Target assist does nothing in an app | Turn on *Outline every target found* (Settings → Targets): if nothing is outlined, that app doesn't expose its controls to Accessibility (some games, canvases and Java apps). Chrome/Electron apps are asked to expose them, which can take a second the first time. |
| Cursor shivers while your hand is still | Better light on your hand; Settings → Pointer → move *Steadiness* toward Steady. |
| Cursor trails behind your finger | Settings → Pointer → move *Steadiness* toward Snappy; check `make doctor` shows ≥ 30 fps. |
| Cursor isn't where you point | Calibrate (Settings → Camera → *Calibrate…*): point at each corner when asked. |
| Wiggles don't click, or clicks happen by themselves | Record a session (below) and send it. (The wiggle thresholds are in the exported settings JSON under `shake`.) |
| Can't reach screen corners | Calibrate, or move *Hand movement to cover the screen* toward Less. |
| Shortcut does nothing | Another app owns it; pick another in Settings → General. |
| An update failed | Menu → **Copy Update Details**, paste it to Claude Code. Or rerun the install line. |
| Need help tuning | Record a minute of use (`--record session.json`) and send the file: `gesture-replay` replays it on any computer. |

Command-line flags (run the binary inside the bundle,
`~/Applications/GesturePointer.app/Contents/MacOS/GesturePointer`):

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

1. Run `make app 2>&1 | tee build.log` (for the installer: rerun the install line and copy all
   of its output; for an in-app update: menu → **Copy Update Details**).
2. Paste the **entire** output (or attach `build.log`) to Claude Code with the words
   **"fix this build error"**. Include the first error, not only the last lines — the first
   error is usually the real one.
3. Also include the output of `sw_vers` and `swift --version`.

## How it's built

```
Sources/GestureCore/        Foundation-only gesture engine (filters, calibration, pose
                            classifier, state machine, replay, sound synthesis) — tested on Linux
Sources/GesturePointerApp/  macOS shell: camera, Vision, CGEvent input, overlay, menu, settings
Sources/GestureReplay/      gesture-replay: run a recording through the engine on any OS
recordings/                 real sessions the tests replay
Tests/GestureCoreTests/     `swift test`
install.sh                  one-line install (release, or build from source), with rollback
scripts/make-app.sh         bundle + sign + zip (CI, the installer and the updater all use it)
tools/check.sh
```

Design decisions and every tuned threshold, with reasons, are in `DECISIONS.md`.
