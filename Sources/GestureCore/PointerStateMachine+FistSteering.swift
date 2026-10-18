import Foundation

/// Fist steering's state, reset whenever the gestures are.
struct FistSteerState {
    /// The pointing hand is a (steering) fist: the cursor follows the palm, sideways only.
    var isFist = false
    /// A fist forming: since when it was first seen, and where the cursor is held meanwhile
    /// (let go straight away if it was a flicker).
    var closing: (since: Double, point: Point2)?
    /// A steering fist seen open: since when (a frame or two of "open" doesn't end it).
    var openingSince: Double?
    /// Since when the fist has been still, toward a click.
    var stillSince: Double?
    /// This fist clicked; it moves before it can click again.
    var clicked = false
    /// This fist scrolled; it doesn't click (stopping after a scroll isn't a click).
    var scrolled = false
    var scrolling = false
    /// The scroll comes from the thumb (up / down), not from moving the fist.
    var byThumb = false
    var thumbScrollSince: Double = 0
    /// The thumb's direction once confirmed, and the reading being confirmed.
    var thumb: ThumbDirection?
    var thumbCandidate: ThumbDirection?
    var thumbCandidateSince: Double = 0
    /// The scroll's began phase went out (the real mouse may have suppressed it).
    var sentBegin = false
    /// Palm position (box units, filtered) where the fist formed, last moved sideways or last
    /// stopped scrolling: the scroll starts from clear vertical travel away from it.
    var anchor: Point2?
    var lastPalmY: Double?
    var lastPalmTime: Double = 0
    /// Scroll speed (points per second), averaged for the glide after the fist opens.
    var velocity: Double = 0
    /// Sub-point scroll carried over to the next frame.
    var remainder: Double = 0
    var palmFilter = OneEuroFilter2D(OneEuroParameters(minCutoff: 1.5, beta: 8))
}

/// Which way a fist's thumb sticks out.
enum ThumbDirection: Equatable { case up, down }

/// Fist steering (`config.fistSteering`, on by default): the hand's shape picks the axis.
///
/// - Open hand: the cursor moves vertically only (following the fingertip).
/// - Fist: the cursor moves horizontally only, following the palm (a fist has no fingertip).
///   Moving the fist up and down scrolls instead; the cursor stays put.
/// - Thumb up / thumb down (`config.thumbScroll`): the fist scrolls up / down for as long as
///   it's held, faster the longer, and the cursor stays put (turning the wrist for a thumbs-down
///   moves the palm). It never clicks. A tucked thumb is the plain fist.
/// - A fist held still for `fistClickHold` clicks where the cursor is (the ring fills meanwhile).
///   It moves before it clicks again; a fist that scrolled doesn't click.
/// - Changing shape never drags the cursor: closing the hand pulls the fingertip down, so the
///   fist carries on from where the cursor was before the hand closed (`fistLookback`); opening
///   holds the cursor while the hand settles.
/// - A fist counts once held `shake.fistHoldTime` (the cursor waits meanwhile): the owner's
///   recording has 0.1–0.2 s fist flickers while the hand moves, which must neither switch the
///   axis nor scroll. A flicker lets the cursor go at once. A steering fist ends once the hand
///   has been open `openConfirmTime`.
///
/// The fist presets (fist click, fist drag) give way while fist steering is on.
extension PointerStateMachine {
    func updateFistSteering(_ hand: HandFrame, at time: Double, suppressed: Bool) -> StepOutput {
        var out = StepOutput()
        let closed = isClosed(.fist)
        if !steer.isFist {
            // Hold from the first frame a fist is seen, before the pose is confirmed: meanwhile
            // the curling fingertip would steer the cursor down.
            let forming = closed || primary.observedPose == .fist
            guard forming else {
                if steer.closing != nil {
                    // A flicker, not a fist: let the cursor go straight away.
                    steer.closing = nil
                    freeze?.since = -.infinity
                }
                return out
            }
            // Forming: hold the cursor where it is (a misread frame then costs nothing).
            let starting = steer.closing == nil
            let closing = steer.closing ?? (time, freeze?.point ?? lastEmittedCursor ?? cursor ?? cursorPoint(at: time))
            steer.closing = closing
            // Its own hold (an earlier click's could run out before the fist is confirmed).
            freezeCursor(at: closing.point, fresh: starting)
            if closed && time - closing.since >= config.shake.fistHoldTime {
                // A real fist: carry on from where the cursor was before the fingers began to
                // curl (they pulled it down a little before the fist was first seen).
                let point = freeze?.point == closing.point ? cursorPoint(at: closing.since - Self.fistLookback) : closing.point
                out.append(switchSteering(toFist: true, at: point, since: closing.since, hand, at: time,
                                          suppressed: suppressed))
            }
            return out
        }
        if !closed {
            let since = steer.openingSince ?? time
            steer.openingSince = since
            if time - since >= Self.openConfirmTime {
                let point = freeze?.point ?? lastEmittedCursor ?? cursor ?? cursorPoint(at: time)
                out.append(switchSteering(toFist: false, at: point, since: time, hand, at: time, suppressed: suppressed))
                return out
            }
        } else {
            steer.openingSince = nil
        }

        if let thumbed = updateThumbScroll(hand, at: time, suppressed: suppressed) {
            out.append(thumbed)
            return out
        }

        // Scroll with the palm's height.
        let palm = steer.palmFilter.filter(mapper.boxPoint(fromCamera: hand.palmCenter), at: time)
        let palmY = palm.y
        var anchor = steer.anchor ?? palm
        let travel = palm - anchor
        if !steer.scrolling && abs(travel.x) > abs(travel.y) {
            // Moving sideways: that's steering, so the scroll measures from here on.
            anchor = palm
        }
        steer.anchor = anchor
        if !steer.scrolling && abs(travel.y) > Self.scrollStartBox && abs(travel.y) > abs(travel.x) * Self.scrollDominance {
            steer.scrolling = true
            steer.scrolled = true
            steer.stillSince = nil
            steer.velocity = 0
            steer.remainder = 0
            steer.lastPalmY = palmY
            steer.lastPalmTime = time
            out.intents += momentum.stop()
            out.events.append(.scrollStarted)
            if !suppressed {
                steer.sentBegin = true
                out.intents.append(.scroll(dx: 0, dy: 0, phase: .began))
            }
        } else if steer.scrolling, let last = steer.lastPalmY, time > steer.lastPalmTime {
            let direction = config.naturalScrolling ? 1.0 : -1.0
            let scale = config.scrollPointsPerBox * config.scrollSpeed * direction
            let step = (palmY - last) * scale
            steer.velocity += (step / (time - steer.lastPalmTime) - steer.velocity) * 0.35
            let delta = step + steer.remainder
            steer.lastPalmY = palmY
            steer.lastPalmTime = time
            if abs(delta) < 0.5 {
                // Sub-point motion adds up rather than being lost or sent as noise.
                steer.remainder = delta
            } else {
                steer.remainder = 0
                if !suppressed {
                    if !steer.sentBegin {
                        steer.sentBegin = true
                        out.intents.append(.scroll(dx: 0, dy: 0, phase: .began))
                    }
                    out.intents.append(.scroll(dx: 0, dy: delta, phase: .changed))
                }
            }
        }

        // Click on a still fist.
        if steer.clicked && tipSpeed > Self.fistMoveSpeed { steer.clicked = false }
        // A thumb sticking out (even before it counts) is heading for a thumb scroll, not a click.
        guard !steer.scrolled, !steer.clicked, steer.thumbCandidate == nil else {
            steer.stillSince = nil
            return out
        }
        guard tipSpeed < Self.fistStillSpeed else {
            steer.stillSince = nil
            return out
        }
        let since = steer.stillSince ?? time
        steer.stillSince = since
        if time - since >= max(config.fistClickHold, 0.1), !suppressed {
            let point = freeze?.point ?? lastEmittedCursor ?? cursor ?? .zero
            steer.clicked = true
            steer.stillSince = nil
            freezeCursor(at: point, fresh: true)
            out.append(emitMove(point, suppressed: suppressed))
            out.append(click(at: point, time: time, window: config.shake.doubleClickWindow))
        }
        return out
    }

    /// The hand closed into a fist or opened: the cursor now follows the other point (palm or
    /// fingertip) on the other axis, continuing from `point`, held while the hand settles. A
    /// fist counts as still since `since` (when the hand closed), toward a click.
    private func switchSteering(toFist fist: Bool, at point: Point2, since: Double, _ hand: HandFrame,
                                at time: Double, suppressed: Bool) -> StepOutput {
        var out = endFistScroll(at: time)
        steer = FistSteerState()
        steer.isFist = fist
        steer.stillSince = fist ? since : nil
        recentTips.removeAll()
        tipSpeed = 0
        latestTipSpeed = 0
        shakeDetector.reset()
        glide = nil
        lastRawBox = mapper.boxPoint(fromCamera: trackedPoint(hand))
        reanchor(at: point, time: time)
        trajectoryLock.reset(holding: point)
        assist.reset()
        if fist {
            // The hand settled while the fist was confirmed (the cursor waited): carry on now.
            freeze = nil
            cursor = point
        } else {
            // Extending fingers swing the fingertip up: wait for the hand to settle.
            freezeCursor(at: point, fresh: true)
        }
        out.append(emitMove(point, suppressed: suppressed))
        return out
    }

    /// Ends a fist scroll: the gesture's ended phase, then a glide if the fist was still moving.
    func endFistScroll(at time: Double) -> StepOutput {
        guard steer.scrolling else { return StepOutput() }
        var out = StepOutput(events: [.scrollEnded])
        if steer.sentBegin {
            out.intents.append(.scroll(dx: 0, dy: 0, phase: .ended))
            if !steer.byThumb && abs(steer.velocity) > Self.momentumStartSpeed {
                out.intents.append(momentum.start(velocity: Point2(0, steer.velocity), at: time))
            }
        }
        steer.scrolling = false
        steer.byThumb = false
        steer.sentBegin = false
        steer.velocity = 0
        steer.remainder = 0
        steer.anchor = nil
        return out
    }

    // MARK: Thumb scroll

    /// Thumb up / down scrolls. Returns the frame's output while the thumb owns the fist, nil
    /// when it doesn't (a tucked thumb: the fist moves, scrolls and clicks as usual).
    private func updateThumbScroll(_ hand: HandFrame, at time: Double, suppressed: Bool) -> StepOutput? {
        let reading = config.thumbScroll ? Self.thumbDirection(hand) : nil
        if reading != steer.thumbCandidate {
            steer.thumbCandidate = reading
            steer.thumbCandidateSince = time
        }
        let confirm = reading == nil ? Self.thumbTuckTime : Self.thumbConfirmTime
        if steer.thumb != reading && time - steer.thumbCandidateSince >= confirm {
            steer.thumb = reading
        }
        var out = StepOutput()
        guard let direction = steer.thumb else {
            guard steer.byThumb else { return nil }
            // Thumb tucked back: the plain fist again (its scroll measures afresh).
            out.append(endFistScroll(at: time))
            return out
        }
        if !steer.byThumb {
            out.append(endFistScroll(at: time))
            steer.scrolling = true
            steer.byThumb = true
            steer.scrolled = true
            steer.stillSince = nil
            steer.remainder = 0
            steer.thumbScrollSince = time
            steer.lastPalmTime = time
            out.intents += momentum.stop()
            out.events.append(.scrollStarted)
        }
        // The cursor stays put: re-hold it every frame (turning the wrist moves the palm).
        let point = freeze?.point ?? lastEmittedCursor ?? cursor ?? .zero
        freezeCursor(at: point, fresh: true)
        let dt = min(max(time - steer.lastPalmTime, 0), 0.1)
        steer.lastPalmTime = time
        // Up shows what's above (content moves down), whatever the natural-scrolling setting.
        let ramp = clamp01((time - steer.thumbScrollSince) / Self.thumbRampTime)
        let speed = (Self.thumbScrollStartSpeed + (Self.thumbScrollTopSpeed - Self.thumbScrollStartSpeed) * ramp)
            * max(config.scrollSpeed, 0.05)
        let delta = speed * dt * (direction == .up ? 1 : -1) + steer.remainder
        guard abs(delta) >= 0.5, !suppressed else {
            steer.remainder = suppressed ? 0 : delta
            return out
        }
        steer.remainder = 0
        if !steer.sentBegin {
            steer.sentBegin = true
            out.intents.append(.scroll(dx: 0, dy: 0, phase: .began))
        }
        out.intents.append(.scroll(dx: 0, dy: delta, phase: .changed))
        return out
    }

    /// Which way the thumb sticks out of a fist, if it clearly does: well away from the index
    /// knuckle, its last two segments pointing mostly up or down (in camera space, so it works
    /// whichever way the wrist is turned). A tucked thumb is nil.
    static func thumbDirection(_ hand: HandFrame) -> ThumbDirection? {
        let size = hand.handSize
        guard hand.jointConfidences[Joint.thumbTip.rawValue] >= 0.3,
              hand.distance(.thumbTip, .indexMCP) / size > thumbOutSpread else { return nil }
        let along = hand.metric(.thumbTip) - hand.metric(.thumbMP)
        let length = along.length
        guard length / size > thumbOutLength else { return nil }
        let vertical = along.y / length
        if vertical < -thumbVertical { return .up }
        if vertical > thumbVertical { return .down }
        return nil
    }

    /// Thumb tip at least this far from the index knuckle (hand sizes): sticking out, not tucked.
    static let thumbOutSpread = 0.6
    /// Thumb MP → tip at least this long (hand sizes): straightened.
    static let thumbOutLength = 0.3
    /// …and pointing within about 40° of straight up or down.
    static let thumbVertical = 0.75
    /// A thumb direction counts after this long; a tucked thumb ends the scroll after this long.
    static let thumbConfirmTime = 0.15
    static let thumbTuckTime = 0.1
    /// Thumb scroll speed (points per second at scroll speed 1): from the start speed to the top
    /// speed over the ramp time, so a short hold nudges and a long hold travels.
    static let thumbScrollStartSpeed = 400.0
    static let thumbScrollTopSpeed = 1600.0
    static let thumbRampTime = 2.0

    /// 0…1 toward a still-fist click (after a short grace, so the ring doesn't flicker).
    func fistClickProgress(at time: Double) -> Double {
        guard config.fistSteering, state == .hover, steer.isFist, !steer.clicked, !steer.scrolled,
              let since = steer.stillSince else { return 0 }
        let grace = 0.15
        let hold = max(config.fistClickHold, 0.1)
        return clamp01((time - since - grace) / max(hold - grace, 1e-6))
    }

    /// The palm has to move this far up or down (box heights) before a fist scrolls, so a fist
    /// held still for a click, or moved sideways, doesn't scroll by accident.
    static let scrollStartBox = 0.04
    /// …and mostly up or down: vertical travel at least this many times the sideways travel.
    static let scrollDominance = 1.5
    /// A steering fist seen open this long has opened (a misread frame or two doesn't end it).
    static let openConfirmTime = 0.08
    /// A fist slower than this (hand sizes per second) counts as still, toward a click…
    static let fistStillSpeed = 1.0
    /// …and one faster than this has moved on, so it may click again.
    static let fistMoveSpeed = 2.0
    /// A fist scroll still moving faster than this (points per second) when the hand opens
    /// glides on.
    static let momentumStartSpeed = 150.0
}
