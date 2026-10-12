# Tuning Wisp with a recording

Every gesture decision Wisp makes comes from the stream of hand landmarks. Record that stream
on your Mac, send the file back, and the exact session can be replayed — on any machine, with
no camera — until the thresholds feel right.

## Velocity mode: the guided session (start here)

Velocity mode (the default) decides clicks and scrolls from how fast and how far your whole hand
moves. Its thresholds (`VelocityParams`) were tuned against synthetic hands; your real hand is
what counts. The guided session records labeled examples of every gesture so `tune` can measure
exactly how Wisp classifies them and search for better thresholds.

### 1. Record (about 8 minutes)

```sh
~/Applications/GesturePointer.app/Contents/MacOS/GesturePointer --record ~/Desktop/session.json --script
```

Wisp engages by itself and shows a prompt in the middle of the screen. For each prompt it waits
1 second ("get ready"), then records for a few seconds (a red dot and a countdown show while it
records), then pauses 1 second. Every prompt comes 8 times, in this order:

| Prompt | What to do | Recorded |
|---|---|---|
| `click` | Hand still, then one quick tap down (and back) | 2 s |
| `right-click` | Hand still, then one quick tap sideways | 2 s |
| `double-click` | Two quick taps down | 2 s |
| `scroll-up` | One long, fast flick up | 2 s |
| `scroll-down` | One long, fast flick down | 2 s |
| `reposition-fast` | Move the pointer quickly somewhere else | 2 s |
| `reposition-slow` | Move the pointer slowly somewhere else | 3 s |
| `fine-target` | Tiny, careful pointer moves | 3 s |
| `drag` | Tap, then move slowly, then hold still | 3 s |
| `rest` | Hold your hand still | 5 s |
| `jitter` | Hold still; dim the lights if you can | 5 s |
| `out-of-frame` | Move your hand out of view and back | 3 s |

No input reaches your Mac during the session (flicks won't click anything), but the overlay
still flashes what each gesture was classified as. When the last prompt is done the file is
saved and shown in Finder. Choosing **Stop Recording Session** in the menu (or quitting) ends
early and keeps the prompts finished so far.

The file holds joint coordinates (21 points per hand per frame), timestamps, the settings in
use and the labeled `segments: [{label, startTime, endTime}]`. No video.

### 2. Tune

Hand `session.json` to Claude Code with:

> Tune VelocityParams against recordings/session.json, update defaults, re-run tests.

Or run it yourself (any OS with Swift; `-c release` makes the grid search fast):

```sh
mkdir -p recordings && cp ~/Desktop/session.json recordings/
swift run -c release tune recordings/session.json            # or: make tune
swift run -c release tune recordings/session.json --config "Wisp Settings.json"
swift run -c release tune recordings/session.json --no-grid  # report only
```

`tune` prints:

1. **Confusion matrix** — rows are prompts, columns are what Wisp did (`click`, `double-click`,
   `right-click`, `scroll-up/down/left/right`, `drag`, `zoom`, `none`); `*` marks the expected
   cell. Prompts that should do nothing (`reposition-*`, `fine-target`, `rest`, `jitter`,
   `out-of-frame`) expect `none`.
2. **Precision / recall** per action, and the number of false alarms on do-nothing prompts.
3. **Measurements per prompt** — min / median / max of `T` (duration), `|d|` (net displacement,
   hand sizes), `L` (path length, hand sizes) and `vpeak` (peak speed, hand-space units per
   second) over every fast segment Wisp saw. Compare them with the thresholds in Settings →
   Gestures → Advanced: e.g. if your taps' `T` max is above `Tap: longest`, taps are being lost.
4. **Grid search** over `vEnter` (with `vExit` = ½ `vEnter`), `clickMaxDuration`,
   `clickMaxDisp`, `scrollMinDisp`, `scrollMinPeak`, and the set with the best F1. Ties keep the
   current values. If a winning value sits at the edge of its grid, `tune` says so: widen that
   axis (the `axes` list in `Sources/Tune/main.swift`) and run again.

Committed recordings live in `recordings/`; `swift test` replays every labeled one and requires
F1 ≥ 0.9 with the default parameters, so a future change can't silently break your hand.

Try the tool without a camera: `swift run tune --synthetic demo-session.json --fps 30`.

### 3. "It didn't click" — the why-not readout

Settings → Gestures → Feedback → **Show “why not?” readout**. After every fast hand movement
the bottom-left corner shows what Wisp measured and which rule decided, for example:

```
reposition — no click: hand wasn't still for 80 ms before
T 142 ms   |d| 0.31 hs   L 1.12 hs   vpeak 1.40 /s
axis vertical   reversed yes   still before no
```

Reproduce the problem, then paste those lines to Claude Code. The same numbers appear in
`gesture-replay` output (`segment` lines) when replaying any recording.

### What each Velocity threshold does

| Symptom | Parameter (Settings → Gestures → Advanced) | Direction |
|---|---|---|
| Taps missed ("no segment" in the readout) | Fast above (vEnter) | lower |
| Moving the pointer clicks | Still before a tap: for / below | raise "for", lower "below" |
| Taps read as "took too long" | Tap: longest | raise |
| Scrolls start when repositioning up/down | Scroll: peak speed without return, Scroll: shortest flick | raise |
| Flicks don't scroll | Scroll: shortest flick | lower |
| Double clicks come out as two clicks | Double click: within | raise |
| Clicking then moving away starts a drag | Drag: moving for, Drag: start within | raise "for", lower "within" |
| Drags drop too early / too late | Drop: still for | raise / lower |

## Pose mode (pinch / fist)

### 1. Record

For Pose mode (Settings → Gestures → Input model → Pose) a free-form recording is enough.
Either from the menu bar: **Record Session for Tuning** (saves `Wisp-<date>.json` to the
Desktop; choose **Stop Recording Session** when done), or from Terminal:

```sh
~/Applications/GesturePointer.app/Contents/MacOS/GesturePointer --record ~/Desktop/session.json
```

What to do while recording (about a minute is plenty):

1. Engage (open palm or ⌃⌥⌘G), then hold your pointing hand still for 5 s.
2. Sweep the cursor slowly across the screen, then quickly.
3. Ten single pinches at a comfortable pace, then three double pinches.
4. Two drags: pinch, hold, move, release.
5. Two right clicks (thumb + middle finger).
6. Fist-scroll down, then up, letting go mid-move once (momentum).
7. Anything that felt wrong — say what it was when you send the file
   ("the third click didn't register", "cursor drifts when I pinch").

The file holds only joint coordinates (21 points per hand) and the settings in use. No video.

### 2. Replay

On the Mac, with the real cursor (careful — it clicks):

```sh
~/Applications/GesturePointer.app/Contents/MacOS/GesturePointer --replay ~/Desktop/session.json
```

or safely, printing what would happen instead:

```sh
~/Applications/GesturePointer.app/Contents/MacOS/GesturePointer --replay ~/Desktop/session.json --dry-run
```

On any platform (this is what Claude uses on Linux):

```sh
swift run gesture-replay ~/Desktop/session.json --pose     # intents + events with timestamps
swift run gesture-replay ~/Desktop/session.json --moves    # include every cursor move
swift run gesture-replay session.json --config "Wisp Settings.json"   # try other settings
```

### 3. What to tune

| Symptom | Setting (Settings window → tab) | Direction |
|---|---|---|
| Cursor shimmers when hand is still | Steadiness, Rest lock (Pointer) | lower Steadiness / raise Rest lock |
| Cursor lags fast moves | Responsiveness (Pointer) | raise |
| Clicks fire when just moving fingers | Pinch closes at (Gestures) | lower |
| Pinches missed | Pinch closes at / Calibrate | raise, or re-run calibration |
| Accidental drags | Hold to drag (Gestures) | raise |
| Too much hand travel needed | Active area (Pointer) | lower |

Synthetic sessions for comparison: `swift run gesture-replay --synthetic demo demo.json` (Pose
gestures; replay it with `--pose`) or `--synthetic velocity` (one of each Velocity gesture).
