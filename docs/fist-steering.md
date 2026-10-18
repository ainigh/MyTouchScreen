# Fist steering

*Your hand's shape picks the direction. Open hand: up and down. Fist: left and right.*

Fist steering is Wisp's default way of moving the cursor (Settings → Pointer → **Fist steering**,
or menu bar → **Fist Steering**). It turns pointing into two simple, separate controls instead of
one free-floating one, so the cursor goes exactly where you mean and never drifts sideways while
you aim up or down (or the other way round).

## The idea in one picture

```
        open hand ✋                         fist ✊
   ┌──────────────────┐            ┌──────────────────────────┐
   │        ▲         │            │                          │
   │        │         │            │  ◀──────  cursor  ──────▶ │
   │     cursor       │            │                          │
   │        │         │            │  ▲ up/down = SCROLL       │
   │        ▼         │            │  ● still   = CLICK        │
   └──────────────────┘            └──────────────────────────┘
   moves vertically only            moves horizontally only
```

Think of it as an Etch A Sketch with the knob chosen by your hand: the open hand turns the
vertical knob, the fist turns the horizontal one. To reach something up and to the right, raise
your open hand to its height, close your hand, and slide the fist across.

## What each hand does

| Hand | Move up / down | Move left / right | Hold still |
|---|---|---|---|
| **Open hand** (pointing) | cursor moves up / down | nothing (ignored) | nothing — the cursor rests |
| **Fist** | **scrolls** the page; the cursor stays put | cursor moves left / right | **clicks** after 0.6 s (the ring fills) |

Everything else is unchanged: both open palms still turn Wisp on and off, the wiggle still clicks
with the open hand, and the shortcut still kills it instantly.

## How a moment plays out

```
 open hand ──(fist seen)──▶ forming ──(held 0.25 s)──▶ fist
    ▲                         │                          │
    │                   (opens again:                    ├─ slide sideways → cursor moves ←→
    │                    just a flicker,                 ├─ move up/down  → scroll (+ glide on release)
    │                    cursor let go)                  ├─ hold still    → click (once; move to re-arm)
    │                         │                          │
    └─────────────────────────┴───────(open 0.08 s)──────┘
```

1. **Forming a fist.** The moment Wisp sees a fist, it holds the cursor still. Curling your fingers
   pulls your fingertip down, and without the hold that would drag the cursor down too.
2. **Confirming.** A fist counts once it has been held for 0.25 s. Shorter "fists" are flickers:
   hands half-close for a split second while they move. Those let the cursor go straight away and
   change nothing. When the fist is confirmed, the cursor steps back to where it was just before
   your fingers began to curl, and from then on follows your fist's palm.
3. **In the fist.** Sliding sideways moves the cursor. Moving up or down by a clear amount
   (mostly vertical, not a sideways slide that wobbles) starts a scroll. Holding still clicks.
4. **Opening.** Once the hand has been open for a moment, the cursor follows your fingertip
   again, vertically. It holds briefly while your fingers straighten, then carries on from
   where it was.

## Clicking with a still fist

- **Make a fist and hold it still:** it clicks after **0.6 s** (adjustable from 0.3 to 1.5 s).
  The ring around the cursor fills meanwhile, so you can see it coming and move to cancel.
- **Slide the fist onto something, then hold still:** it clicks there. Arriving and stopping is
  the click.
- **One click per stop.** After a click, the fist has to move before it can click again, so a fist
  held for a long time doesn't machine-gun clicks.
- **Scrolling cancels the click** for the rest of that fist: stopping after a scroll is not a
  click. Open and close your hand to click after scrolling.
- A double click is two still-fist clicks on the same spot close together, or the wiggle.

## Scrolling with a fist

- **Up and down only.** The fist's vertical movement scrolls; the cursor stays exactly where it is,
  because in a fist the cursor only moves sideways.
- **It starts on purpose.** The fist must move about 4% of the screen height, and mostly
  vertically (at least 1.5× more up/down than sideways), before scrolling starts. A sideways slide
  that wobbles, or a fist held still to click, never scrolls by accident.
- **Direction** follows macOS's *Natural scrolling* setting by default: with it on, moving the fist
  down moves the content down, like dragging the page.
- **Glide.** Open your hand while the fist is still moving and the page glides on and slows
  naturally, like a trackpad flick.
- **Speed and direction:** Settings → Pointer → *Fist scroll speed*, and *Scroll direction follows
  the system* (untick it to choose the direction for Wisp alone).

## How it fits with the other settings

| Setting | With fist steering on |
|---|---|
| **Trajectory** (straight lines / free) | Rests: the hand's shape picks the axis instead of the hand's direction. |
| **Cursor speed** presets | Still apply to how far the cursor moves. |
| **Target assist** | Still applies: the cursor slows near buttons and settles onto them. A resting cursor can be pulled onto a target slightly off its axis. |
| **Fist drag** / **quick-fist click** presets | Give way: the fist is busy steering. To drag, pick a pinch or the thumb trigger in Settings → Gestures. |
| **Wiggle click** | Works with the open hand. A fist's back-and-forth is steering, never a wiggle. |
| **Two open palms** | Still turn Wisp on and off. |

Turning fist steering off brings back the previous behaviour exactly: the Trajectory setting, the
fist dragging, and so on.

## Why it is built this way

- **Two separate axes beat one diagonal.** Aiming a camera-tracked finger at a small target is
  hard because every small tremor moves the cursor in two directions at once. Splitting the job
  means each movement can only disturb one coordinate, and the other one stays exactly put.
- **Hand shape is an unmistakable switch.** Switching axes by direction alone (the *straight
  lines* trajectory) has to guess, from how sharply you turn, whether you meant to change
  direction. A fist removes the guess.
- **The fist doubles as the button.** You're already making a fist to move sideways, so stopping
  on the target and holding still is the shortest possible way to click there. Up/down is free in
  a fist, which makes it the natural place for scrolling.
- **The timings come from real hands.** The 0.25 s confirmation comes from a recorded session in
  which hands made 0.1–0.2 s "fists" while just moving. The holds around closing and opening the
  hand exist because changing hand shape moves the fingertip even when the arm stays still.

## Tuning

| You notice… | Try |
|---|---|
| Clicks happen when you only paused | Settings → Pointer → *Hold a still fist to click* toward **Long**. |
| Clicking feels slow | Same slider toward **Quick**. |
| Scrolling is too fast or too slow | *Fist scroll speed*. |
| Scrolling goes the wrong way | Settings → Pointer → untick *Scroll direction follows the system* and set *Natural scrolling* yourself (or change it in System Settings). |
| You want to drag | Gestures tab → Drag: a pinch or the thumb trigger. |
| You'd rather point freely | Turn *Fist steering* off (menu bar or Settings → Pointer). |

If something misfires, use **Record Session for Tuning** in the menu, reproduce it, and send the
file back. The recording replays exactly, fist steering included, through `gesture-replay` on any
machine.

## Where it lives in the code

- `Sources/GestureCore/PointerStateMachine+FistSteering.swift`: the mode: forming and
  confirming the fist, scroll, still-fist click, and the hand-shape switch.
- `Sources/GestureCore/TrajectoryLock.swift`: keeps the cursor on one axis. Fist steering tells it
  which axis (`forcedAxis`).
- `Tests/GestureCoreTests/FistSteeringTests.swift`: what the mode promises, including a replay of
  a real recorded session.
- Settings: `GestureConfig.fistSteering` (on by default) and `fistClickHold`. Scroll speed and
  direction are `scrollSpeed` and `naturalScrolling`.
