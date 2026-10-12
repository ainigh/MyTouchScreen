# Recordings

Real hand-landmark sessions recorded with `GesturePointer --record recordings/<name>.json`.
The files contain only hand geometry (21 points per hand per frame) and timestamps — no images.
Replay one on any computer with `swift run gesture-replay recordings/<name>.json`.

`owner-freeform-2026-10-12.json` is the owner's first free-form session (pointing, finger wags
while moving, the left hand raised twice, a brief fist after a rest and longer fists while
moving). `WiggleClickTests.testOwnerRecordingFistsDragAndNothingElsePresses` replays it: nothing
scrolls or zooms, every press is released, and presses happen only during the held fists.
