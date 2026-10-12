# SPEC-M7 — Velocity gestures

> **Removed (Oct 2026, owner request):** Velocity mode, its `tune` tool and the guided recording
> were taken out with every other way of clicking except the lock-then-wiggle click. Kept for
> history; see DECISIONS.md.

This amendment adds a second input model, **Velocity mode**, alongside the existing pinch-based
model (now called **Pose mode**). Velocity mode becomes the default once its acceptance tests
pass. Pose mode stays selectable in Settings. Everything else in `SPEC.md` still applies.

Read this after `CLAUDE.md`, `SPEC.md` and `PROGRESS.md`. Add the M7 section at the bottom of
this file to `PROGRESS.md` and work it like any other milestone.

## Why

Finger-pose classification (pinch, fist) is fragile: it depends on distance, lighting, hand
angle and chirality. The velocity of the whole hand is robust to all of those. Velocity mode
uses a single mental model: the hand is a mouse, a flick is a tap, a swipe is a scroll. No
finger pose is ever required for pointing, clicking or scrolling.

## Signals

All computed in **hand space** (camera-normalized coordinates, mirrored), not screen space, so
thresholds don't depend on screen size or active-box scale.

- `tip`: index fingertip, 1€-filtered as today. Drives the cursor.
- `centroid`: mean of wrist and the four MCP knuckles (index, middle, ring, little). Drives all
  velocity logic. It is far steadier than any fingertip.
- `v`: centroid velocity, units per second, from a light filter (e.g. 1€ with higher cutoff than
  the pointer, or a 3-frame linear fit). Never from the pointer's heavily smoothed signal.
- `handSize`: wrist → middle MCP distance. All displacement thresholds are expressed as
  multiples of `handSize` so they are distance-invariant.
- `confidence`: Vision's per-hand confidence; frames below `minConfidence` are ignored by the
  velocity logic (the pointer may still coast on its filter).

## State machine

```
disengaged ──(engage gesture / hotkey)──▶ hover
hover: cursor follows tip.
       if |v| > vEnter for ≥ framesEnter consecutive frames → fastSegment (anchor = tip position
       at first fast frame, t0 = its time, keep moving cursor live)
fastSegment: accumulate path; track peak |v|, net displacement, path length, dominant axis,
       reversal (sign change of velocity along dominant axis after the peak).
       when |v| < vExit for ≥ framesExit frames, or duration > maxSegment → classify
classify (see table) → click / rightClick / scroll / reposition → hover
```

Hysteresis: `vExit < vEnter`. Everything is parameterized (see Parameters).

### Classification

Let `d` = net displacement of the centroid from anchor, `L` = path length, `T` = duration,
`axis` = dominant axis of `d`, `vpeak` = peak speed, `reversed` = whether the hand came back
toward the anchor after the peak (final position within `returnFraction` of the peak excursion).

| Condition | Result |
|---|---|
| `T < clickMaxDuration` and `|d| < clickMaxDisp` and `L < clickMaxPath` and axis vertical | **Left click** at anchor; cursor warped to anchor |
| same but axis horizontal | **Right click** at anchor; cursor warped to anchor |
| `|d| ≥ scrollMinDisp` and axis vertical and (`reversed` or `vpeak > scrollMinPeak`) | **Scroll**: initial velocity = `k · vpeak` in the flick's direction, then momentum decay; cursor warped to anchor |
| `|d| ≥ scrollMinDisp` and axis horizontal and `reversed` | **Horizontal scroll** (same rule) |
| anything else | **Reposition**: no action; cursor stays where the live movement left it |

Axis is "vertical" when `|dy| > axisRatio · |dx|`; "horizontal" when the reverse; otherwise
ambiguous → reposition.

### Composite gestures

- **Double click:** two left clicks within `doubleClickWindow` and within `doubleClickDisp` of
  each other. Post as a proper double click (click count 2), not two singles.
- **Drag:** a left click followed within `dragStartWindow` by sustained movement
  (|v| > `dragMoveMin` for `framesEnter` frames) → mouse down at the click anchor, then dragged
  events follow `tip`. Release when the hand is still (|v| < `dragStillV`) for `dragStillTime`,
  or on another flick. A second flick while dragging is consumed as the release, not a click.
- **Zoom:** two hands both in `fastSegment` within `twoHandWindow` with their centroids moving
  apart or together → ⌘+scroll zoom events proportional to the rate of distance change; no
  click or scroll is emitted for either hand.
- **Engage/disengage:** unchanged (palm hold or hotkey). Palm detection is the one pose
  Velocity mode still uses; it can't be a flick because flicks mean things while engaged.
- **Out of frame:** unchanged.

### Cursor behavior during fast segments

Move the cursor live during the segment. On click/right-click/scroll, warp it back to the
anchor in a single `mouseMoved` event. On reposition, leave it. The warp happens within one
frame of segment end, so the user sees "tap where I was." Do not freeze the cursor during
fast segments; it adds latency to every reposition.

### Noise rejection (required, not optional)

- `framesEnter ≥ 2` coherent frames above `vEnter`, where coherent means the velocity direction
  changes by < `coherenceAngle` between frames.
- Ignore any segment whose anchor frame or peak frame had `confidence < minConfidence`.
- A single-frame jump larger than `glitchDisp` (landmark glitch) resets the segment entirely.
- Refractory period `refractory` after any emitted click/scroll during which no new segment
  can start.
- Clicks require the hand to have been in `hover` with |v| < `preClickStillV` for at least
  `preClickStillTime` before the segment. (A tap starts from stillness; a reposition that
  happens to be short does not.)

## Parameters

Define these as one `VelocityParams` struct in `GestureCore` with these defaults and expose them
all in Settings under an "Advanced" disclosure. Units: hand-space (normalized camera coords)
per second for velocities, multiples of `handSize` for displacements, seconds for times.

```
vEnter            0.9   /s      vExit           0.45  /s
framesEnter       2             framesExit      2
maxSegment        0.45  s
clickMaxDuration  0.18  s       clickMaxDisp    0.9 ×handSize   clickMaxPath 1.6 ×handSize
preClickStillV    0.25  /s      preClickStillTime 0.08 s
scrollMinDisp     1.6 ×handSize scrollMinPeak   1.8 /s          returnFraction 0.5
scrollGain k      900  px/s per (/s)   momentumDecay 0.92 per frame at 60 Hz  (frame-rate corrected)
axisRatio         1.8
doubleClickWindow 0.30  s       doubleClickDisp 0.5 ×handSize
dragStartWindow   0.35  s       dragMoveMin     0.30 /s         dragStillV 0.12 /s  dragStillTime 0.40 s
twoHandWindow     0.15  s
coherenceAngle    60   °        glitchDisp      2.5 ×handSize
refractory        0.12  s       minConfidence   0.5
```

These are starting points. Final values come from recordings (below). Record what changed and
why in `DECISIONS.md`.

Frame-rate independence: all per-frame constants (`framesEnter`, `momentumDecay`) must be
expressed internally as time and derived from the measured camera rate, so 30 fps and 60 fps
behave the same.

## Scroll output

Post `CGEvent` scroll-wheel events with `.pixel` units at the display's refresh rate (use a
`CVDisplayLink` or a 60–120 Hz timer) with proper phases: `began` on the first event, `changed`
while velocity is user-driven, then `ended`, then momentum phase `begin`/`continue`/`end` while
decaying. Stop momentum immediately if the hand starts a new fast segment. Natural scrolling
follows the system setting. Horizontal scroll uses wheel 2.

## Recording and tuning protocol

The classifier is tuned against the owner's real hand. Add `tools/tune.md` with this protocol,
and support it in the app:

1. `GesturePointer --record session.json --script` runs a guided session: the overlay shows a
   prompt, waits 1 s, then records the next N seconds and tags the frames with the prompt's
   label. Prompts, in order, each repeated 8 times with a 1-second gap:
   `click`, `right-click`, `double-click`, `scroll-up`, `scroll-down`, `reposition-fast`,
   `reposition-slow`, `fine-target`, `drag`, `rest` (hand still for 5 s), `jitter` (hand
   still, poor lighting if possible), `out-of-frame`.
2. The JSON has a `segments: [{label, startTime, endTime}]` array alongside the frames.
3. `swift run tune session.json` (a small executable target in the package, Linux-buildable,
   Foundation only) replays the file through `VelocityClassifier`, prints a confusion matrix
   (labels × emitted intents), per-label precision/recall, and the distribution of `T`, `|d|`,
   `L`, `vpeak` for each label. It then runs a coarse grid search over the key thresholds and
   prints the parameter set with the best F1, with a warning if that set is near the edge of
   the grid.
4. Commit recordings under `recordings/` (they are small JSON, no PII beyond hand geometry).
   Tests load them.

Until the owner provides recordings, the synthetic generator in `Replay.swift` must produce
each labeled class with realistic timing and noise, and the tests below run against that.

## Settings additions

Input model: Velocity (default) / Pose. Click axis (vertical/horizontal/any). Right-click
enabled. Drag enabled. Scroll gain and momentum. Precision slow-gain. "Advanced" disclosure
with every `VelocityParams` field and a "Reset to tuned defaults" button.

## Overlay additions

- During a fast segment, draw a short trail from the anchor so the user sees what the system
  sees.
- On classification, flash the result at the anchor: a small ripple for click, a double ripple
  for double click, a ring for right click, an arrow for scroll direction. Fade in 300 ms.
- A "why not?" debug toggle (off by default) that shows the last segment's `T`, `|d|`, `L`,
  `vpeak`, axis, reversed, and which rule fired. This is how the owner reports "it didn't
  click" problems.

## M7 — Velocity gestures (add to PROGRESS.md)

- [ ] `VelocityParams`, centroid + velocity estimation, segment tracker, `VelocityClassifier` in GestureCore
- [ ] Composite gestures: double click, drag, two-hand zoom; refractory; noise rejection
- [ ] Synthetic generator produces every labeled class with timing/noise variation
- [ ] Tests: each class classified correctly ≥ 95% over 200 synthetic samples; `rest` and `jitter` produce zero intents; `reposition-fast` produces zero clicks/scrolls; click lands at anchor; scroll momentum decays monotonically and stops on new segment; frame-rate independence (same input at 30 and 60 fps → same intents)
- [ ] `tune` executable: confusion matrix, stats, grid search; Linux-buildable
- [ ] App: input-model switch, scroll output with phases at display rate, cursor warp, overlay trail/ripples, "why not?" debug, guided `--record --script`
- [ ] `tools/tune.md` written; Settings updated; DECISIONS.md updated
- [ ] Linux `swift build` + `swift test` green; `tools/check.sh` green; Mac files reviewed
- [ ] Committed: `M7: velocity gestures`

## Owner loop after M7

1. `make app && make run`, switch Input model to Velocity, try it for a few minutes.
2. Run the guided recording, then hand `session.json` to Claude Code with: "Tune VelocityParams
   against recordings/session.json, update defaults, re-run tests."
3. If a specific gesture misfires, turn on "why not?", reproduce it, and paste the numbers.
