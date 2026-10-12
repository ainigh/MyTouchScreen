# Recordings

Labeled hand-landmark sessions from the guided recording
(`GesturePointer --record recordings/session.json --script`, see `tools/tune.md`).

Every `*.json` here that has labeled `segments` is replayed by
`TuningTests.testCommittedRecordings`, which requires an F1 of at least 0.9 with the default
`VelocityParams`. The files contain only hand geometry (21 points per hand per frame) and
timestamps — no images.

`owner-freeform-2026-10-12.json` is the owner's first free-form session (Hold & wiggle, no
labels). `DwellShakeTests.testOwnerRecordingFingerWiggleScrollsAndLeftHandDrags` replays it: the
finger wags must scroll, the two left-hand-up stretches must each drag, and nothing may click.
