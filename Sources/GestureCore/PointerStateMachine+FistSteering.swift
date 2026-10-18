import Foundation

/// Fist steering's state, reset whenever the gestures are.
struct FistSteerState {
    /// The pointing hand is a steering fist (thumb up or gripping): the cursor follows the palm.
    var isFist = false
    /// A fist forming: since when it was first seen, and where the cursor is held meanwhile
    /// (let go straight away if it was a flicker).
    var closing: (since: Double, point: Point2)?
    /// A steering fist seen open: since when (a frame or two of "open" doesn't end it).
    var openingSince: Double?
    /// The thumb is tucked in over the fingers (the grip: the mouse button), debounced.
    var thumbIn = false
    /// The thumb reading being confirmed, and since when.
    var thumbCandidate: Bool?
    var thumbCandidateSince: Double = 0
    /// The thumb is pressed (tucked): the cursor is held, toward a click, a scroll or a grab.
    var grip: Grip?
    /// The grip grabbed: the mouse button is down and the fist drags.
    var dragging = false
    var scrolling = false
    /// The scroll's began phase went out (the real mouse may have suppressed it).
    var sentBegin = false
    /// Palm position (box units, filtered) where the grip began: the scroll starts from clear
    /// vertical travel away from it.
    var anchor: Point2?
    var lastPalmY: Double?
    var lastPalmTime: Double = 0
    /// Scroll speed (points per second), averaged for the glide after the grip lets go.
    var velocity: Double = 0
    /// Sub-point scroll carried over to the next frame.
    var remainder: Double = 0
    var palmFilter = OneEuroFilter2D(OneEuroParameters(minCutoff: 1.5, beta: 8))
}

/// A thumb press in progress.
struct Grip {
    var since: Double
    /// Where the cursor is held, and where a click or a grab lands.
    var point: Point2
    /// A quick lift of the thumb clicks. Only a press from a thumb-up fist with the hand calm
    /// can: a fist made with the thumb already tucked, or a hand on the move, never clicks.
    var clickable: Bool
}

/// Fist steering (`config.fistSteering`, on by default). The thumb is the mouse button.
///
/// - **Open hand** (the "about to shake hands" position, thumb up): the cursor moves vertically
///   only, following the fingertip.
/// - **Fist, thumb up** ("hold"): the cursor moves horizontally only, following the palm (a fist
///   has no fingertip). Making it never clicks.
/// - **Thumb tucked in** (a full fist, "grip"): the button. The cursor can't move.
///   - Lift the thumb quickly (a flick, under `flickMaxTime`): **click**.
///   - Move the gripping fist up or down: **scroll**; the content follows the hand, like pulling
///     a rope. Lifting the thumb lets go (with a glide if the hand was still moving), and the
///     thumb-up fist can then move back without scrolling: hand over hand, like climbing.
///   - Hold the grip still for `gripDragHold`: **grab** (mouse down; the ring fills meanwhile).
///     The cursor then follows the fist in any direction; lifting the thumb (or opening the
///     hand) **drops**.
/// - Changing shape never drags the cursor: the cursor holds from the first frame a fist is
///   seen, and the fist carries on from where it was before the fingers began to curl. A fist
///   counts once held `shake.fistHoldTime` (the owner's recording has 0.1–0.2 s fist flickers
///   while moving, which let the cursor go at once); it ends once the hand has been open
///   `openConfirmTime`, and the cursor then holds while the fingers straighten.
/// - The thumb reading is debounced (`thumbConfirmTime`) with hysteresis between "tucked" and
///   "out", so a misread frame neither presses nor clicks.
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
                out.append(switchSteering(toFist: true, at: point, hand, at: time, suppressed: suppressed))
            }
            return out
        }
        if steerHandOpened(at: time) {
            let point = freeze?.point ?? lastEmittedCursor ?? cursor ?? cursorPoint(at: time)
            out.append(switchSteering(toFist: false, at: point, hand, at: time, suppressed: suppressed))
            return out
        }

        guard steer.thumbIn else {
            out.append(releaseGrip(at: time, suppressed: suppressed))
            return out
        }

        // The grip: the cursor stays put while the thumb is pressed.
        let grip = steer.grip ?? startGrip(at: time)
        freezeCursor(at: grip.point, fresh: true)
        out.append(updateGripScroll(hand, at: time, suppressed: suppressed))
        if !steer.scrolling && time - grip.since >= max(config.gripDragHold, 0.1) {
            // Held still: grab. The fist now drags, in any direction, until the thumb lifts.
            steer.grip = nil
            steer.dragging = true
            out.append(press(hand, at: grip.point, time: time, suppressed: suppressed))
        }
        return out
    }

    /// The thumb and the open hand, read every frame while steering (pointing or dragging).
    func updateSteeringHand(_ hand: HandFrame, at time: Double) {
        if isClosed(.fist) {
            steer.openingSince = nil
        } else if steer.openingSince == nil {
            steer.openingSince = time
        }
        let reading = Self.thumbTucked(hand)
        if reading != steer.thumbCandidate {
            steer.thumbCandidate = reading
            steer.thumbCandidateSince = time
        }
        if let reading, reading != steer.thumbIn, time - steer.thumbCandidateSince >= Self.thumbConfirmTime {
            steer.thumbIn = reading
        }
    }

    /// The steering fist has been open long enough to count as opened.
    func steerHandOpened(at time: Double) -> Bool {
        guard let since = steer.openingSince else { return false }
        return time - since >= Self.openConfirmTime
    }

    /// While a steering fist drags: the thumb lifted or the hand opened drops.
    var steeringDragReleased: Bool { !steer.thumbIn || steerHandOpened(at: lastTime) }

    /// The steering drag dropped: the fist (if still a fist, thumb up) steers sideways again,
    /// carrying on from the drop point.
    func finishSteeringDrop(_ hand: HandFrame, at time: Double) {
        steer.dragging = false
        steer.grip = nil
        guard let point = freeze?.point else { return }
        lastRawBox = mapper.boxPoint(fromCamera: trackedPoint(hand))
        reanchor(at: point, time: time)
        trajectoryLock.reset(holding: point)
    }

    private func startGrip(at time: Double) -> Grip {
        let point = freeze?.point ?? lastEmittedCursor ?? cursor ?? cursorPoint(at: time)
        let grip = Grip(since: time, point: point, clickable: tipSpeed < Self.clickMaxSpeed)
        steer.grip = grip
        steer.anchor = nil
        return grip
    }

    /// The thumb lifted: a quick press clicks, a scroll lets go; otherwise the fist just steers
    /// on from where the cursor was held.
    private func releaseGrip(at time: Double, suppressed: Bool) -> StepOutput {
        guard let grip = steer.grip else { return StepOutput() }
        steer.grip = nil
        if steer.scrolling {
            freeze?.since = -.infinity
            return endFistScroll(at: time)
        }
        if grip.clickable && time - grip.since <= Self.flickMaxTime && !suppressed {
            freezeCursor(at: grip.point, fresh: true)
            var out = emitMove(grip.point, suppressed: suppressed)
            out.append(click(at: grip.point, time: time, window: config.shake.doubleClickWindow))
            return out
        }
        freeze?.since = -.infinity
        return StepOutput()
    }

    /// Scrolls while the gripping fist moves up or down (the content follows the hand).
    private func updateGripScroll(_ hand: HandFrame, at time: Double, suppressed: Bool) -> StepOutput {
        var out = StepOutput()
        let palm = steer.palmFilter.filter(mapper.boxPoint(fromCamera: hand.palmCenter), at: time)
        let anchor = steer.anchor ?? palm
        steer.anchor = anchor
        let travel = palm - anchor
        if !steer.scrolling {
            guard abs(travel.y) > Self.scrollStartBox && abs(travel.y) > abs(travel.x) * Self.scrollDominance else {
                return out
            }
            steer.scrolling = true
            steer.grip?.clickable = false
            steer.velocity = 0
            steer.remainder = 0
            steer.lastPalmY = palm.y
            steer.lastPalmTime = time
            out.intents += momentum.stop()
            out.events.append(.scrollStarted)
            if !suppressed {
                steer.sentBegin = true
                out.intents.append(.scroll(dx: 0, dy: 0, phase: .began))
            }
            return out
        }
        guard let last = steer.lastPalmY, time > steer.lastPalmTime else { return out }
        let direction = config.naturalScrolling ? 1.0 : -1.0
        let step = (palm.y - last) * config.scrollPointsPerBox * config.scrollSpeed * direction
        steer.velocity += (step / (time - steer.lastPalmTime) - steer.velocity) * 0.35
        let delta = step + steer.remainder
        steer.lastPalmY = palm.y
        steer.lastPalmTime = time
        guard abs(delta) >= 0.5 else {
            // Sub-point motion adds up rather than being lost or sent as noise.
            steer.remainder = delta
            return out
        }
        steer.remainder = 0
        guard !suppressed else { return out }
        if !steer.sentBegin {
            steer.sentBegin = true
            out.intents.append(.scroll(dx: 0, dy: 0, phase: .began))
        }
        out.intents.append(.scroll(dx: 0, dy: delta, phase: .changed))
        return out
    }

    /// The hand closed into a fist or opened: the cursor now follows the other point (palm or
    /// fingertip) on the other axis, continuing from `point`.
    private func switchSteering(toFist fist: Bool, at point: Point2, _ hand: HandFrame, at time: Double,
                                suppressed: Bool) -> StepOutput {
        var out = endFistScroll(at: time)
        // The thumb and the open hand keep being read across the change.
        var next = FistSteerState()
        next.isFist = fist
        next.thumbIn = steer.thumbIn
        next.thumbCandidate = steer.thumbCandidate
        next.thumbCandidateSince = steer.thumbCandidateSince
        next.openingSince = steer.openingSince
        steer = next
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
            // A fist made with the thumb already tucked grips straight away, but can't click.
            freeze = nil
            cursor = point
            if steer.thumbIn { steer.grip = Grip(since: time, point: point, clickable: false) }
        } else {
            // Extending fingers swing the fingertip up: wait for the hand to settle.
            freezeCursor(at: point, fresh: true)
        }
        out.append(emitMove(point, suppressed: suppressed))
        return out
    }

    /// Ends a grip scroll: the gesture's ended phase, then a glide if the fist was still moving.
    func endFistScroll(at time: Double) -> StepOutput {
        guard steer.scrolling else { return StepOutput() }
        var out = StepOutput(events: [.scrollEnded])
        if steer.sentBegin {
            out.intents.append(.scroll(dx: 0, dy: 0, phase: .ended))
            if abs(steer.velocity) > Self.momentumStartSpeed {
                out.intents.append(momentum.start(velocity: Point2(0, steer.velocity), at: time))
            }
        }
        steer.scrolling = false
        steer.sentBegin = false
        steer.velocity = 0
        steer.remainder = 0
        steer.anchor = nil
        return out
    }

    /// Whether the thumb is tucked in over the curled fingers (true), clearly out (false), or
    /// in between (nil: keep the last reading). Measured as the thumb tip's distance to the
    /// nearest joint of the curled index and middle fingers, so it works whichever way the
    /// wrist is turned.
    static func thumbTucked(_ hand: HandFrame) -> Bool? {
        guard hand.jointConfidences[Joint.thumbTip.rawValue] >= 0.3 else { return nil }
        let fingers: [Joint] = [.indexMCP, .indexPIP, .indexDIP, .indexTip, .middlePIP, .middleDIP, .middleTip]
        let nearest = fingers.map { hand.distance(.thumbTip, $0) }.min() ?? 1
        let distance = nearest / hand.handSize
        if distance < thumbTuckedBelow { return true }
        if distance > thumbOutAbove { return false }
        return nil
    }

    /// 0…1 toward a grab while the thumb is held down still (after a short grace, so a click
    /// doesn't flash the ring).
    func gripProgress(at time: Double) -> Double {
        guard config.fistSteering, state == .hover, let grip = steer.grip, !steer.scrolling else { return 0 }
        let grace = 0.15
        let hold = max(config.gripDragHold, 0.1)
        return clamp01((time - grip.since - grace) / max(hold - grace, 1e-6))
    }

    /// Thumb tip nearer than this to the curled fingers (hand sizes): tucked in…
    static let thumbTuckedBelow = 0.28
    /// …further than this: out (up). In between keeps the last reading.
    static let thumbOutAbove = 0.4
    /// A thumb reading counts once it has held this long (a misread frame does nothing).
    static let thumbConfirmTime = 0.06
    /// A thumb press shorter than this is a click.
    static let flickMaxTime = 0.4
    /// A press made while the hand moves faster than this (hand sizes per second) can't click.
    static let clickMaxSpeed = 2.5
    /// The gripping palm has to move this far up or down (box heights) before it scrolls…
    static let scrollStartBox = 0.04
    /// …and mostly up or down: vertical travel at least this many times the sideways travel.
    static let scrollDominance = 1.5
    /// A steering fist seen open this long has opened (a misread frame or two doesn't end it).
    static let openConfirmTime = 0.08
    /// A grip scroll still moving faster than this (points per second) when the thumb lifts
    /// glides on.
    static let momentumStartSpeed = 150.0
}
