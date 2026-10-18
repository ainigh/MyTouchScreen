# Fist steering

*Your hand's shape picks the direction, and your thumb is the mouse button.*

Fist steering is Wisp's default way of moving the cursor (Settings → Pointer → **Fist steering**,
or menu bar → **Fist Steering**). Each hand shape does one thing, so every movement can only do
what that shape is for:

| Hand | What it does |
|---|---|
| ✋ **Open hand**, thumb up (as if about to shake hands) | Moves the cursor **up and down** only |
| ✊👍 **Fist, thumb up** ("hold") | Moves the cursor **left and right** only |
| ✊ **Thumb tucked in** (a full fist, "grip") | **The mouse button.** The cursor can't move. |

Pressing the button, which means tucking the thumb in, is what clicks, scrolls and drags:

| With the thumb tucked in… | Result |
|---|---|
| Lift it again straight away (a **flick**) | **Click** (two flicks: double click) |
| Move the fist **up or down** | **Scroll**: the page follows your hand, like pulling a rope |
| Hold the fist **still** for half a second (the ring fills) | **Grab**: mouse down. The fist then drags in any direction; lift the thumb to **drop**. |

## The idea

Start in the handshake position. Your hand is upright, thumb on top, and moving it up and down
moves the cursor up and down. Close your fingers into a fist but keep the thumb up: now your hand
"holds" the cursor, and moving it moves the cursor sideways only. Up and down do nothing in this
shape, so the height you just set stays exactly where it is.

The thumb then works like a mouse button sitting on top of your fist. Press it down onto your
fingers and the cursor freezes. Press and release it quickly and that's a click. Keep it pressed
and you're gripping: pull your fist down and the page comes down with it, as if you were pulling
on a rope.

```
   ✋ open hand ──── fingers close, thumb stays up ───▶ ✊👍 fist, thumb up
   (up / down)  ◀──────────── hand opens ──────────────  (left / right)
                                                           │      ▲
                                             thumb tucks in│      │thumb lifts
                                                           ▼      │
                                                      ✊ grip (cursor held)
                                                ┌─────────┼──────────────┐
                                        lifted at once  moved up/down   held still ½ s
                                             CLICK        SCROLL          GRAB → drag → lift = DROP
```

## Scrolling like a rope

Gripping and pulling scrolls the page with your hand: pull down and the page comes down, which
shows what's above. To keep going, go hand over hand, as if climbing a rope:

1. **Grip** (tuck the thumb) and **pull** your fist down. The page scrolls.
2. **Let go** by lifting the thumb. If your hand was still moving, the page glides on and slows down.
3. **Reach back up** with the thumb still up. Your fist is in "hold" mode, which only moves
   sideways, so the cursor doesn't move and nothing scrolls.
4. **Grip and pull again.**

To scroll the other way (like pulling a rope up out of the ground), grip and push up, let go, and
reach back down.

The page follows your hand when macOS's *Natural scrolling* is on, which is the default. If you
turn natural scrolling off in System Settings, or untick *Scroll direction follows the system* in
Wisp, it goes the other way.

## Dragging and dropping

1. Move the cursor onto the item: up and down with the open hand, left and right with the thumb-up fist.
2. **Grip** (tuck the thumb) and **hold still**. The ring around the cursor fills, and after half
   a second the item is grabbed (mouse down).
3. **Move your fist** anywhere. While dragging the cursor moves in **any direction**, not just
   sideways, because items need to go anywhere.
4. **Lift the thumb** to drop. Opening the whole hand drops too.

Grabbing and scrolling start the same way, by tucking the thumb. What you do next decides which:
move up or down straight away and it scrolls; hold still and it grabs. That's how a touch screen
tells a swipe from a long press.

## The small print (why it behaves as it does)

- **Closing your hand never moves the cursor.** Curling your fingers pulls your fingertip down,
  which would drag the cursor down too. So the cursor holds from the first moment Wisp sees a
  fist, and then carries on from where it was before your fingers began to curl.
- **A fist counts after a quarter of a second.** Hands half-close for a split second while they
  move (a recorded session is full of these). Those flickers change nothing, and the cursor is
  let go at once.
- **The thumb is read carefully.** "Tucked in" means the thumb tip is close to your curled fingers,
  and "up" means it's clearly away from them. Anything in between keeps the last reading. A
  change only counts once it has lasted a few frames, so one misread frame can't press or click.
- **Only a deliberate flick clicks.** It has to start from a thumb-up fist, with your hand calm,
  and be quick (under 0.4 s). A full fist made straight from the open hand, with the thumb
  already tucked, grips but doesn't click when you lift the thumb. A press longer than a flick
  but shorter than a grab does nothing.
- **Scrolling has to be on purpose.** While gripping, the fist must move clearly up or down
  (about 4% of the screen height, and mostly vertically) before it scrolls.
- **Opening the hand** returns to up-and-down pointing. The cursor waits a moment while your
  fingers straighten, because that swings the fingertip.
- **The thumb thresholds are a first guess.** They were tuned on synthetic hands only (the thumb
  tip within 0.28 hand sizes of the curled fingers counts as tucked; beyond 0.4 counts as up). If
  clicks misfire or the thumb isn't recognised, record a session (see Tuning).

## How it fits with the other settings

| Setting | With fist steering on |
|---|---|
| **Trajectory** (straight lines / free) | Rests: the hand's shape picks the axis. |
| **Cursor speed** presets | Still apply to how far the cursor moves. |
| **Target assist** | Still applies: the cursor slows near buttons and settles onto them. |
| **Drag** presets (Gestures tab) | The grip drags instead. Pinch and thumb-trigger presets still work too. The fist presets apply only with fist steering off. |
| **Wiggle click** | Still works with the open hand. |
| **Two open palms** | Still turn Wisp on and off. |

Turning fist steering off brings back the previous behaviour exactly.

## Tuning

| You notice… | Try |
|---|---|
| Grabs happen when you meant to click | Flick faster, or set *Hold the grip still to grab* toward **Long**. |
| Grabbing takes too long | The same slider toward **Quick**. |
| Scrolling is too fast or too slow | *Grip scroll speed*. |
| Scrolling goes the wrong way for you | Untick *Scroll direction follows the system* and set *Natural scrolling* yourself. |
| The thumb isn't recognised, or clicks happen by themselves | Record a session (below) and send it. The thumb thresholds need real hands. |
| You'd rather point freely | Turn *Fist steering* off (menu bar or Settings → Pointer). |

**Record Session for Tuning** in the menu saves exactly what the camera saw. Reproduce the
problem and send the file. It replays the same way on any machine through `gesture-replay`.

## Where it lives in the code

- `Sources/GestureCore/PointerStateMachine+FistSteering.swift`: the mode. It covers the fist
  forming, the thumb reading, the grip (click, scroll, grab) and the drop.
- `Sources/GestureCore/TrajectoryLock.swift`: keeps the cursor on one axis. Fist steering tells it
  which axis (`forcedAxis`); a grab drags freely.
- `Tests/GestureCoreTests/FistSteeringTests.swift`: what the mode promises:
  - flick, double flick, slow press and misread frame
  - grip scroll and rope climbing
  - grab and drop, and a full fist made straight from the open hand
  - a replay of a real recorded session
- Settings: `GestureConfig.fistSteering` (on by default) and `gripDragHold` (0.5 s). Scroll speed
  and direction are `scrollSpeed` and `naturalScrolling`.
