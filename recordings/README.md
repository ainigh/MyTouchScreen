# Recordings

Labeled hand-landmark sessions from the guided recording
(`GesturePointer --record recordings/session.json --script`, see `tools/tune.md`).

Every `*.json` here that has labeled `segments` is replayed by
`TuningTests.testCommittedRecordings`, which requires an F1 of at least 0.9 with the default
`VelocityParams`. The files contain only hand geometry (21 points per hand per frame) and
timestamps — no images.

None are committed yet: the defaults were tuned against the synthetic generator
(`VelocitySynthetic`) until the owner records a session.
