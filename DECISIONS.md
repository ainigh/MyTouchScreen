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

## Technical

## Dropped or changed spec items
