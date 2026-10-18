import Foundation

/// The gestures. Only two things are tracked on the pointing hand: the index fingertip and the
/// fist.
///
/// - The cursor is a laser pointer: it goes where the index fingertip points (through the
///   calibration), at every speed, with no gain, freeze or accumulated offset. Smoothing only
///   removes tracker jitter (`PointerSmoother`).
/// - A wiggle (`shake.reversals` direction changes along one axis) clicks where the cursor was
///   when the wiggle began. The cursor then holds on the click point until the hand settles and
///   glides back under the fingertip. A second wiggle soon after at the same spot is a double
///   click.
/// - A fist presses where the cursor was just before the hand closed: a drag. The cursor then
///   follows the fist's palm (the curled finger is no use), offset so it starts at the pressed
///   point. Opening the fist drops where the cursor is.
///
/// Both open palms held still engage / disengage (see `updatePalmEngagement`); the other hand
/// does nothing else. `preferredHand = .left` makes the left hand the pointing hand.
extension PointerStateMachine {
    // MARK: Hands

    /// The pointing hand and the other hand. With two hands, position decides (more reliable
    /// than Vision's chirality): the user's right hand is on the camera's left. A lone hand
    /// always points: Vision's chirality flips now and then, and ignoring the hand on those
    /// frames made the cursor stop for no visible reason.
    func assignPointerAndOther(_ hands: [HandFrame], at time: Double) -> (HandFrame?, HandFrame?) {
        let pointerIsLeft = config.preferredHand == .left
        var pointer: HandFrame?
        var other: HandFrame?
        if hands.count >= 2 {
            let byX = hands.sorted { $0[.wrist].x < $1[.wrist].x }
            pointer = pointerIsLeft ? byX.last : byX.first
            other = pointerIsLeft ? byX.first : byX.last
        } else {
            pointer = hands.first
        }
        if let pointer {
            primaryLastPalm = pointer.palmCenter
            primaryLastSeen = time
        }
        return (pointer, other)
    }

    /// The point the cursor follows: the index fingertip, or the palm while dragging with a fist.
    func trackedPoint(_ hand: HandFrame) -> Point2 {
        state == .dragging ? hand.palmCenter : hand[.indexTip]
    }

    /// Tracked-point speed in hand sizes per second: the slower of the last two two-frame
    /// speeds. A one-frame tracker glitch (out and straight back) makes only one of them fast,
    /// so it never reads as fast motion; a real fast movement makes both fast.
    func updateTipSpeed(_ hand: HandFrame, at time: Double) {
        let tip = hand.handSpace(trackedPoint(hand))
        let size = max(hand.handSize, 1e-4)
        recentTips.append((time, tip))
        if recentTips.count > 4 { recentTips.removeFirst(recentTips.count - 4) }
        func speed(from a: (time: Double, point: Point2), to b: (time: Double, point: Point2)) -> Double {
            b.time > a.time ? b.point.distance(to: a.point) / size / (b.time - a.time) : 0
        }
        let n = recentTips.count
        latestTipSpeed = n >= 2 ? speed(from: recentTips[n - 2], to: recentTips[n - 1]) : 0
        if n >= 4 {
            tipSpeed = min(speed(from: recentTips[n - 3], to: recentTips[n - 1]),
                           speed(from: recentTips[n - 4], to: recentTips[n - 2]))
        } else if n >= 2 {
            tipSpeed = speed(from: recentTips[n - 2], to: recentTips[n - 1])
        } else {
            tipSpeed = 0
        latestTipSpeed = 0
        }
    }

    // MARK: Frame

    func updatePointerShake(_ hand: HandFrame, other: HandFrame?, at time: Double) -> StepOutput {
        var out = StepOutput()
        let suppressed = time < outputSuppressedUntil
        shakeDetector.params = config.shake
        if hand.confidence < Self.minMotionConfidence {
            // A frame Vision was unsure about: its landmarks are scattered, so it says nothing
            // about motion. Hold the cursor for this frame.
            return out
        }
        updateTipSpeed(hand, at: time)
        updateContactSensors(other: other, at: time)

        if bothPalmsOpen && state == .hover {
            // Two open palms are the engage / disengage gesture: hold the cursor where it is.
            if let point = lastEmittedCursor ?? cursor { freezeCursor(at: point) }
            freeze?.calmSince = nil
            shakeDetector.reset()
            return out
        }

        if let zoomed = updateZoom(hand, other: other, at: time, suppressed: suppressed) {
            return zoomed
        }

        if state == .dragging && dragReleased() {
            out.append(drop(at: time))
            return out
        }

        if state == .hover, let held = updatePendingContact(hand, at: time, suppressed: suppressed) {
            return held
        }

        out.append(updateCursor(hand, at: time, suppressed: suppressed))

        guard state == .hover else { return out }
        switch config.clickGesture {
        case .wiggle:
            // Wiggles click only with the button up (mid-drag they are just motion).
            if let sample = medianTip(),
               let wiggle = shakeDetector.update(point: sample.point, handSize: hand.handSize, at: sample.time) {
                let point = freeze?.point ?? wiggleClickPoint(wiggle)
                freezeCursor(at: point, fresh: true)
                out.append(emitMove(point, suppressed: suppressed))
                if !suppressed { out.append(click(at: point, time: time, window: config.shake.doubleClickWindow)) }
            }
        case .dwell:
            out.append(updateDwell(at: time, suppressed: suppressed))
        case .pinch, .middlePinch, .thumbTrigger, .quickFist:
            break
        }
        return out
    }

    /// The tracked point, median of the last three frames per axis (timed at the middle one): a
    /// one-frame tracker glitch disappears instead of looking like a stroke out and back.
    func medianTip() -> (time: Double, point: Point2)? {
        let n = recentTips.count
        guard n >= 3 else { return nil }
        let last3 = recentTips[(n - 3)...]
        func median(_ values: [Double]) -> Double { values.sorted()[1] }
        return (recentTips[n - 2].time, Point2(median(last3.map(\.point.x)), median(last3.map(\.point.y))))
    }

    // MARK: Cursor

    /// Moves the cursor to where the hand points, or keeps it on a held point (after a click, a
    /// drop or a fist) until the hand settles.
    private func updateCursor(_ hand: HandFrame, at time: Double, suppressed: Bool) -> StepOutput {
        let rawBox = mapper.boxPoint(fromCamera: trackedPoint(hand))
        lastRawBox = rawBox

        if var held = freeze {
            if tipSpeed < Self.settleSpeed {
                if held.calmSince == nil { held.calmSince = time }
            } else {
                held.calmSince = nil
            }
            let settled = held.calmSince.map { time - $0 >= Self.settleTime } ?? false
            if settled || time - held.since >= Self.maxHoldTime {
                // Settled (or the hand went on without pausing): glide from the held point back
                // under the fingertip.
                freeze = nil
                if let display = router.current {
                    let heldBox = ActiveBoxMapper.boxPoint(fromScreen: held.point, on: display)
                    if config.pointerResponse.isDirect && config.trajectory == .free {
                        glide = (heldBox - (rawBox + warpOffset), time)
                        smoother.reset(to: heldBox, at: time)
                    } else {
                        // Scaled response or straight lines: the cursor isn't under the finger
                        // anyway, so it simply carries on from the held point (a glide would be
                        // scaled, or bent onto one axis, and move a still cursor).
                        smoother.reset(hand: rawBox + warpOffset, cursor: heldBox, at: time)
                        if config.pointerResponse.isDirect { trajectoryLock.reset(holding: held.point) }
                    }
                }
            } else {
                freeze = held
                assist.reset()
                trajectoryLock.reset()
                cursor = held.point
                // Kept in the history: a wiggle that starts while the cursor is held (a double
                // click) clicks right here.
                remember(held.point, at: time)
                return emitMove(held.point, suppressed: suppressed)
            }
        }

        if latestTipSpeed >= Self.glitchSpeed && tipSpeed < Self.glitchSpeed / 2, let shown = lastEmittedCursor ?? cursor {
            // This frame alone jumped: most likely a tracker glitch. Hold the cursor for it; a
            // real fast move is confirmed by the next frame and followed from there.
            cursor = shown
            return StepOutput()
        }

        var box = rawBox + warpOffset + glideOffset(at: time)
        lastBox = box
        var out = StepOutput()
        if let jumped = router.update(box: box, at: time) {
            rebuildMapper()
            warpOffset = .zero
            glide = nil
            box = mapper.boxPoint(fromCamera: trackedPoint(hand))
            lastRawBox = box
            smoother.reset(to: box, at: time)
            assist.reset()
            trajectoryLock.reset()
            out.events.append(.displayChanged(jumped.id))
        }
        guard let display = router.current else { return out }
        let smoothed = ActiveBoxMapper.screenPoint(fromBox: smoother.process(box, at: time), on: display)
        // The trajectory shapes every cursor path, drags included.
        let finger = trajectoryLock.process(finger: smoothed, at: time, bounds: display.frame,
                                            trajectory: config.trajectory, turnSharpness: config.turnSharpness)
        let screen: Point2
        if state == .dragging {
            // A drag follows the fist as is: being pulled onto controls would drop things wrong.
            assist.reset()
            screen = finger
        } else {
            screen = assist.process(finger: finger, at: time, bounds: display.frame)
        }
        cursor = screen
        out.append(emitMove(screen, suppressed: suppressed))
        remember(lastEmittedCursor ?? screen, at: time)
        return out
    }

    func remember(_ point: Point2, at time: Double) {
        cursorHistory.append((time, point))
        cursorHistory.removeAll { time - $0.time > Self.historyLength }
    }

    /// What is left of a glide back under the fingertip: it shrinks to nothing over `glideTime`.
    func glideOffset(at time: Double) -> Point2 {
        guard let current = glide else { return .zero }
        let remaining = 1 - (time - current.start) / Self.glideTime
        guard remaining > 0 else {
            glide = nil
            return .zero
        }
        // Ease out: most of the way in the first half, so the cursor is soon under the finger.
        return current.offset * (remaining * remaining)
    }

    /// The cursor stays at `point` until the hand settles (at most `maxHoldTime`). `fresh` starts
    /// a new hold (a click, a press, a drop) rather than moving the current one.
    func freezeCursor(at point: Point2, fresh: Bool = false) {
        if freeze == nil || fresh { freeze = CursorFreeze(point: point, since: lastTime) } else { freeze?.point = point }
        freeze?.calmSince = nil
        cursor = point
    }

    /// Where a wiggle clicks: where the cursor was as the hand set off on the wiggle's first
    /// stroke. The move that brought the hand there and a first wag in the same direction make
    /// one stroke, so rather than the stroke's start take its last calm moment before the wag:
    /// the latest point, before the stroke's final fast stretch into the turn, at which the
    /// cursor was (nearly) as still as it got. The cursor is already smoothed (and locked still
    /// while the hand rests), which makes its speed a clean signal; the turn itself is slow too,
    /// so it has to be skipped.
    func wiggleClickPoint(_ wiggle: ShakeDetector.Detection) -> Point2 {
        let fallback = cursorPoint(at: wiggle.startTime)
        let stroke = cursorHistory.filter { $0.time >= wiggle.startTime && $0.time <= wiggle.firstTurnTime }
        // Cursor speed since the previous sample.
        let speeds = stroke.map { sample -> Double in
            guard let earlier = cursorHistory.last(where: { $0.time < sample.time }) else { return 0 }
            return sample.point.distance(to: earlier.point) / (sample.time - earlier.time)
        }
        guard let slowest = speeds.min(), let fastest = speeds.max() else { return fallback }
        let calm = max(slowest * 1.5, fastest * Self.calmFraction)
        guard let lastFast = speeds.lastIndex(where: { $0 > calm }),
              let lastCalm = speeds[..<lastFast].lastIndex(where: { $0 <= calm }) else { return fallback }
        return stroke[lastCalm].point
    }

    /// Where the cursor was shown at `time` (the latest point at or before it), or now.
    func cursorPoint(at time: Double) -> Point2 {
        cursorHistory.last { $0.time <= time }?.point ?? cursorHistory.first?.point
            ?? lastEmittedCursor ?? cursor ?? .zero
    }

    /// Hands seen with less confidence than this don't move the cursor or count toward a wiggle.
    static let minMotionConfidence = 0.5
    /// How long the cursor's recent positions are kept (a wiggle is at most `shake.window` long).
    static let historyLength = 1.5
    /// The cursor counts as calm (before a wiggle set off) below this fraction of its top speed
    /// during the wiggle's first stroke.
    static let calmFraction = 0.1
    /// A held cursor (after a click, a drop or a fist) lets go once the tracked point has been
    /// slower than this (hand sizes per second; a resting fingertip jitters at 0.35–0.8)…
    static let settleSpeed = 1.2
    /// …for this long, then glides back under the fingertip over `glideTime`.
    static let settleTime = 0.15
    static let glideTime = 0.15
    /// A hold never lasts longer than this, so moving straight on after a click never leaves
    /// the cursor behind.
    static let maxHoldTime = 0.6
    /// One frame faster than this (hand sizes per second) while the frames around it are slow is
    /// a tracker glitch, not hand movement.
    static let glitchSpeed = 5.0
    /// A fist presses where the cursor was this long before the pose was confirmed (beyond the
    /// confirmation delay itself): the curling fingertip drags the cursor down meanwhile.
    static let fistLookback = 0.12

    // MARK: Click

    /// Clicks at `point`; a click within `window` of the last one at the same spot is a double
    /// (or triple) click.
    func click(at point: Point2, time: Double, window: Double) -> StepOutput {
        var count = 1
        var point = point
        let radius = (router.current?.frame.width ?? 1500) * config.shake.doubleClickRadiusBox
        if let last = lastClick, time - last.time <= window,
           last.point.distance(to: point) <= radius {
            // Same spot: click exactly where the first one landed, as a double click must.
            count = min(last.count + 1, 3)
            point = last.point
        }
        lastClick = (time, point, count)
        assist.noteClick(at: point, time: time)
        return StepOutput(intents: [.click(x: point.x, y: point.y, count: count)], events: [.clicked(count: count)])
    }

    // MARK: Drag

    /// The hand closed into a fist: press where the cursor was before it closed.
    func press(_ hand: HandFrame, at point: Point2, time: Double, suppressed: Bool) -> StepOutput {
        var out = StepOutput()
        pendingContact = nil
        toggleOpenedSincePress = false
        dwell = nil
        state = .dragging
        shakeDetector.reset()
        if !suppressed {
            out.intents.append(.down(x: point.x, y: point.y))
            out.events.append(.dragStarted)
            buttonDown = true
            lastEmittedCursor = point
        }
        // The cursor now follows the palm, offset so that it starts at the pressed point. It
        // stays there until the hand has settled from closing.
        lastRawBox = mapper.boxPoint(fromCamera: hand.palmCenter)
        reanchor(at: point, time: time)
        recentTips.removeAll()
        tipSpeed = 0
        latestTipSpeed = 0
        freezeCursor(at: point, fresh: true)
        cursorHistory.removeAll()
        return out
    }

    /// The fist opened: release where the cursor is and hold it there until the hand settles,
    /// so opening the hand (which swings the fingertip back out) doesn't move it.
    func drop(at time: Double) -> StepOutput {
        let point = freeze?.point ?? lastEmittedCursor ?? cursor ?? .zero
        var out = StepOutput()
        if buttonDown {
            buttonDown = false
            out = StepOutput(intents: [.up(x: point.x, y: point.y)], events: [.dragEnded])
        }
        state = .hover
        recentTips.removeAll()
        tipSpeed = 0
        latestTipSpeed = 0
        warpOffset = .zero
        glide = nil
        freezeCursor(at: point, fresh: true)
        cursorHistory.removeAll()
        shakeDetector.reset()
        return out
    }
}

/// The cursor held on a point until the hand settles.
struct CursorFreeze {
    /// Where the cursor is held (screen points).
    var point: Point2
    /// When the hold began.
    var since: Double
    /// Since when the hand has been calm (below `settleSpeed`), if it is.
    var calmSince: Double?
}
