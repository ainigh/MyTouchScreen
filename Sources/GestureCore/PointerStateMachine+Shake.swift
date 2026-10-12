import Foundation

/// The gestures. Only two things are tracked on the pointing hand: the index fingertip and the
/// fist.
///
/// - Slow movement moves the cursor (it follows the index fingertip).
/// - Fast movement — as fast as a wiggle (`shake.freezeSpeed`) — never moves it: the cursor
///   freezes where it was just before the burst began and stays there until the hand has calmed
///   down, then carries on from that point. So a wiggle, a flick or the curl of a closing hand
///   leaves the cursor where the user aimed.
/// - A wiggle (`shake.reversals` direction changes along one axis) clicks, any time, with no
///   waiting: at the frozen point, or (a wiggle slow enough not to freeze) where the cursor was
///   when the wiggle began. A second wiggle soon after at the same spot is a double click.
/// - A fist presses where the cursor was just before the hand closed: a drag. The cursor then
///   follows the fist's palm (the curled finger is no use), with the same freeze on fast motion.
///   Opening the fist drops where the cursor is.
///
/// Both open palms held still engage / disengage (see `updatePalmEngagement`); the other hand
/// does nothing else. `preferredHand = .left` makes the left hand the pointing hand.
extension PointerStateMachine {
    // MARK: Hands

    /// The pointing hand and the other hand. With two hands, position decides (more reliable
    /// than Vision's chirality): the user's right hand is on the camera's left. One hand points
    /// only if it is the pointing hand by chirality, so a lone other hand never moves the cursor.
    func assignPointerAndOther(_ hands: [HandFrame], at time: Double) -> (HandFrame?, HandFrame?) {
        let pointerIsLeft = config.preferredHand == .left
        var pointer: HandFrame?
        var other: HandFrame?
        if hands.count >= 2 {
            let byX = hands.sorted { $0[.wrist].x < $1[.wrist].x }
            pointer = pointerIsLeft ? byX.last : byX.first
            other = pointerIsLeft ? byX.first : byX.last
        } else if let only = hands.first {
            let otherChirality: Chirality = pointerIsLeft ? .right : .left
            if only.chirality == otherChirality { other = only } else { pointer = only }
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
        let isFist = primary.state.pose == .fist
        if !isFist && primary.observedPose != .fist { fistNeedsOpenHand = false }

        if bothPalmsOpen && state == .hover {
            // Two open palms are the engage / disengage gesture: hold the cursor where it is.
            if let point = lastEmittedCursor ?? cursor { freezeCursor(at: point) }
            freeze?.calmSince = nil
            shakeDetector.reset()
            return out
        }

        if state == .dragging && !isFist {
            out.append(drop(at: time))
            return out
        }

        if state == .hover && isFist && !fistNeedsOpenHand {
            // Hold the cursor where it was before the hand closed; press once the fist has been
            // held a moment (a fist that flickers for a few frames while moving never presses).
            let pending = pendingFist ?? (time, freeze?.point ?? cursorPoint(at: time - config.poseConfirmDuration - Self.fistLookback))
            pendingFist = pending
            freezeCursor(at: pending.point)
            if time - pending.since >= config.shake.fistHoldTime {
                out.append(press(hand, at: pending.point, time: time, suppressed: suppressed))
            } else {
                out.append(emitMove(pending.point, suppressed: suppressed))
            }
            return out
        }
        pendingFist = nil

        out.append(updateCursor(hand, at: time, suppressed: suppressed))

        // Wiggles click only with the button up (mid-drag they are just motion).
        if state == .hover, let sample = medianTip(),
           let wiggle = shakeDetector.update(point: sample.point, handSize: hand.handSize, at: sample.time) {
            let point = freeze?.point ?? cursorPoint(at: wiggle.startTime)
            freezeCursor(at: point)
            out.append(emitMove(point, suppressed: suppressed))
            if !suppressed { out.append(wiggleClick(at: point, time: time)) }
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

    /// Moves the cursor with the hand, or holds it frozen while the hand moves fast.
    private func updateCursor(_ hand: HandFrame, at time: Double, suppressed: Bool) -> StepOutput {
        // The tracked point, with the offset left by a freeze draining as the hand really moves
        // (not with resting jitter, which adds up to a lot of path).
        let rawBox = mapper.boxPoint(fromCamera: trackedPoint(hand))
        if let previous = lastRawBox, warpOffset != .zero, state != .dragging, tipSpeed > config.shake.resumeSpeed {
            let drain = min((rawBox - previous).length / Self.warpDrainBox, 1)
            warpOffset = warpOffset * (1 - drain)
            if warpOffset.length < 1e-5 { warpOffset = .zero }
        }
        lastRawBox = rawBox

        if freeze == nil && tipSpeed >= config.shake.freezeSpeed, let current = lastEmittedCursor ?? cursor {
            // Freeze where the cursor was before the burst began (the smoothed speed lags a
            // couple of frames behind the hand, and the cursor followed it meanwhile).
            let calm = lastCalmCursor.flatMap { time - $0.time <= Self.calmLookback ? $0.point : nil }
            freezeCursor(at: calm ?? current)
        }
        if var frozen = freeze {
            if tipSpeed < config.shake.resumeSpeed {
                if frozen.calmSince == nil { frozen.calmSince = time }
            } else {
                frozen.calmSince = nil
            }
            if let calmSince = frozen.calmSince, time - calmSince >= config.shake.resumeTime {
                // Calm again: carry on from the frozen point with the hand where it is now.
                freeze = nil
                reanchor(at: frozen.point, time: time)
            } else {
                freeze = frozen
                cursor = frozen.point
                return emitMove(frozen.point, suppressed: suppressed)
            }
        }

        if latestTipSpeed >= config.shake.freezeSpeed, let shown = lastEmittedCursor ?? cursor {
            // This frame alone looks fast: hold the cursor for it. If the next frame confirms the
            // burst, the cursor freezes having never moved; if it was a glitch, it carries on.
            cursor = shown
            return StepOutput()
        }

        var box = rawBox + warpOffset
        lastBox = box
        var out = StepOutput()
        if let jumped = router.update(box: box, at: time) {
            rebuildMapper()
            warpOffset = .zero
            box = mapper.boxPoint(fromCamera: trackedPoint(hand))
            lastRawBox = box
            smoother.reset(to: box, at: time)
            out.events.append(.displayChanged(jumped.id))
        }
        guard let display = router.current else { return out }
        let screen = ActiveBoxMapper.screenPoint(fromBox: smoother.process(box, at: time), on: display)
        cursor = screen
        let before = lastEmittedCursor ?? screen
        out.append(emitMove(screen, suppressed: suppressed))
        let shown = lastEmittedCursor ?? screen
        cursorHistory.append((time, shown))
        cursorHistory.removeAll { time - $0.time > Self.historyLength }
        // Where the cursor was *before* this frame: the speed estimate trails the hand by a frame
        // or so, so this frame's move may already belong to the burst.
        if tipSpeed < config.shake.freezeSpeed * Self.calmFraction { lastCalmCursor = (time, before) }
        return out
    }

    /// The cursor stays at `point` until the hand calms down.
    func freezeCursor(at point: Point2) {
        if freeze == nil { freeze = CursorFreeze(point: point) } else { freeze?.point = point }
        freeze?.calmSince = nil
        cursor = point
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
    /// The cursor counts as "before the burst" while the hand is slower than this fraction of
    /// the freeze speed…
    static let calmFraction = 0.5
    /// …and such a position is used for a freeze up to this long afterwards.
    static let calmLookback = 0.3
    /// A fist presses where the cursor was this long before the pose was confirmed (beyond the
    /// confirmation delay itself): the curling fingertip drags the cursor down meanwhile.
    static let fistLookback = 0.12

    // MARK: Click

    private func wiggleClick(at point: Point2, time: Double) -> StepOutput {
        var count = 1
        let radius = (router.current?.frame.width ?? 1500) * config.shake.doubleClickRadiusBox
        if let last = lastClick, time - last.time <= config.shake.doubleClickWindow,
           last.point.distance(to: point) <= radius {
            count = min(last.count + 1, 3)
        }
        lastClick = (time, point, count)
        return StepOutput(intents: [.click(x: point.x, y: point.y, count: count)], events: [.clicked(count: count)])
    }

    // MARK: Drag

    /// The hand closed into a fist: press where the cursor was before it closed.
    private func press(_ hand: HandFrame, at point: Point2, time: Double, suppressed: Bool) -> StepOutput {
        var out = StepOutput()
        pendingFist = nil
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
        freezeCursor(at: point)
        cursorHistory.removeAll()
        lastCalmCursor = nil
        return out
    }

    /// The fist opened: release where the cursor is and hold it there until the hand settles,
    /// so opening the hand (which swings the fingertip back out) doesn't move it.
    private func drop(at time: Double) -> StepOutput {
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
        freezeCursor(at: point)
        cursorHistory.removeAll()
        lastCalmCursor = nil
        shakeDetector.reset()
        return out
    }
}

/// The cursor held still while the hand moves fast.
struct CursorFreeze {
    /// Where the cursor is held (screen points).
    var point: Point2
    /// Since when the hand has been calm (below `resumeSpeed`), if it is.
    var calmSince: Double?
}
