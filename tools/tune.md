# Tuning Wisp with a recording

Every gesture decision Wisp makes comes from the stream of hand landmarks. Record that stream
on your Mac, send the file back, and the exact session can be replayed — on any machine, with
no camera — until the thresholds feel right.

## 1. Record

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

## 2. Replay

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
swift run gesture-replay ~/Desktop/session.json            # intents + events with timestamps
swift run gesture-replay ~/Desktop/session.json --moves    # include every cursor move
swift run gesture-replay session.json --config "Wisp Settings.json"   # try other settings
```

## 3. What to tune

| Symptom | Setting (Settings window → tab) | Direction |
|---|---|---|
| Cursor shimmers when hand is still | Steadiness, Rest lock (Pointer) | lower Steadiness / raise Rest lock |
| Cursor lags fast moves | Responsiveness (Pointer) | raise |
| Clicks fire when just moving fingers | Pinch closes at (Gestures) | lower |
| Pinches missed | Pinch closes at / Calibrate | raise, or re-run calibration |
| Accidental drags | Hold to drag (Gestures) | raise |
| Too much hand travel needed | Active area (Pointer) | lower |

Synthetic sessions for comparison: `swift run gesture-replay --synthetic demo demo.json`.
