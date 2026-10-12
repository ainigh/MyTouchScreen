import Foundation

/// Hold & wiggle (the default input model).
///
/// One hand (the pointing hand):
/// - movement moves the cursor (it follows the index fingertip);
/// - holding the cursor still for `shake.lockTime` locks it in place. When the hand moves again
///   the cursor stays locked for `shake.wakeTime` more — the wake window. No gesture in that
///   time: the cursor unlocks and goes to where the hand points;
/// - a wiggle (`shake.reversals` direction changes along one axis) while locked or in the wake
///   window clicks where the cursor is locked. The cursor stays locked, waiting for the next
///   movement, so wiggling again clicks again (a double click when quick). This is the only way
///   this model clicks;
/// - a fist while locked or in the wake window presses there: a drag. The cursor then follows
///   the fist (its palm, since the curled finger is no use) under the same lock rules: it locks
///   when the fist rests and waits a second after it moves on. Opening the fist drops where the
///   cursor is — the locked point if it rested — and leaves the cursor locked there.
///
/// Two hands:
/// - both open palms, held still: engage / disengage (see `updatePalmEngagement`);
/// - both fists: zoom and scroll (see `TwoFistGesture`). When the fists rest, their last stroke
///   decides: spread wider → zoom in, closer → zoom out, both moved one way → scroll that way.
///   The cursor stays locked throughout.
///
/// `preferredHand = .left` makes the left hand the pointing hand.
extension PointerStateMachine {
    // MARK: Hands

    /// The pointing hand and the other hand. With two hands, position decides (more reliable
    /// than Vision's chirality): the user's right hand is on the camera's left. One hand points
    /// only if it is the pointing hand by chirality, so a lone other hand never moves the cursor.
    func assignPointerAndOther(_ hands: [HandFrame], at time: Double) -> (HandFrame?, HandFrame?, Bool) {
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
        return (pointer, other, false)
    }

    /// The point the cursor follows: the index fingertip, or the palm while dragging with a fist.
    func trackedPoint(_ hand: HandFrame) -> Point2 {
        state == .dragging ? hand.palmCenter : hand[.indexTip]
    }

    /// Tracked-point speed in hand sizes per second, lightly smoothed.
    func updateTipSpeed(_ hand: HandFrame, at time: Double) {
        let tip = hand.handSpace(trackedPoint(hand))
        if let last = lastTip, time > last.time {
            let instant = tip.distance(to: last.point) / max(hand.handSize, 1e-4) / (time - last.time)
            tipSpeed += (instant - tipSpeed) * 0.4
        }
        lastTip = (time, tip)
    }

    // MARK: Frame

    func updatePointerShake(_ hand: HandFrame, other: HandFrame?, at time: Double) -> StepOutput {
        var out = StepOutput()
        let suppressed = time < outputSuppressedUntil
        shakeDetector.params = config.shake
        updateTipSpeed(hand, at: time)
        let isFist = primary.state.pose == .fist

        if bothPalmsOpen && state == .hover {
            // Two open palms are the engage / disengage gesture: hold the cursor where it is.
            holdCursorLocked(hand, at: time)
            return out
        }

        // Two fists: zoom / scroll. Never from a drag (its button is down).
        if state == .twoFists || (state == .hover && other != nil && isFist) {
            out.append(updateTwoFists(hand, other: other, at: time, suppressed: suppressed))
            if state == .twoFists { return out }
        }

        if state == .dragging && !isFist {
            out.append(drop(hand, at: time))
            return out
        }

        // Cursor: the tracked point, with the offset left by a lock draining as the hand moves.
        let rawBox = mapper.boxPoint(fromCamera: trackedPoint(hand))
        if let previous = lastRawBox, warpOffset != .zero, state != .dragging {
            let drain = min((rawBox - previous).length / Self.warpDrainBox, 1)
            warpOffset = warpOffset * (1 - drain)
            if warpOffset.length < 1e-5 { warpOffset = .zero }
        }
        lastRawBox = rawBox
        if let lock = cursorLock {
            out.append(updateLockedCursor(lock, hand: hand, isFist: isFist, other: other, at: time,
                                          suppressed: suppressed))
            if cursorLock != nil { return out }
        }
        var box = rawBox + warpOffset
        lastBox = box
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
        history.append(PointerSample(time: time, cursor: screen, box: box, pinchDistance: 1, tipOffset: .zero))
        history.removeAll { time - $0.time > Self.historySpan }

        out.append(emitMove(screen, suppressed: suppressed))
        if [.hover, .dragging].contains(state) && !suppressed {
            updateLockArming(screen, hand: hand, at: time)
        }
        return out
    }

    // MARK: Lock

    /// Holding the cursor within `dwellRadiusBox` for `lockTime` locks it.
    private func updateLockArming(_ screen: Point2, hand: HandFrame, at time: Double) {
        let radius = (router.current?.frame.width ?? 1500) * config.shake.dwellRadiusBox
        guard let anchor = dwellAnchor, anchor.point.distance(to: screen) <= radius else {
            dwellAnchor = (time, screen)
            return
        }
        if time - anchor.time >= config.shake.lockTime {
            // Lock where the pointer visibly is, so a click or press lands exactly there.
            lockCursor(at: lastEmittedCursor ?? screen, hand: hand, at: time)
        }
    }

    func lockCursor(at point: Point2, hand: HandFrame, at time: Double) {
        cursorLock = CursorLock(point: point, rest: hand.handSpace(trackedPoint(hand)), since: time)
        cursor = point
        dwellAnchor = nil
        shakeDetector.reset()
    }

    /// Keep (or put) the cursor locked where it is and wait for the hand to settle before the
    /// next movement counts: used while the hands do something else (palms, fists).
    private func holdCursorLocked(_ hand: HandFrame, at time: Double) {
        if cursorLock == nil, let point = lastEmittedCursor ?? cursor {
            lockCursor(at: point, hand: hand, at: time)
        }
        cursorLock?.settling = true
        cursorLock?.wakeStart = nil
        shakeDetector.reset()
    }

    /// The cursor stays put. Moving the hand opens the wake window; in it (or before it) a wiggle
    /// clicks and a fist presses. A real move without either unlocks when the window ends.
    private func updateLockedCursor(_ lock: CursorLock, hand: HandFrame, isFist: Bool, other: HandFrame?,
                                    at time: Double, suppressed: Bool) -> StepOutput {
        var lock = lock
        var out = StepOutput()
        cursor = lock.point
        history.append(PointerSample(time: time, cursor: lock.point, box: lastBox ?? .zero, pinchDistance: 1, tipOffset: .zero))
        history.removeAll { time - $0.time > Self.historySpan }

        let tip = hand.handSpace(trackedPoint(hand))
        let size = max(hand.handSize, 1e-4)
        if lock.settling {
            // The tail of a gesture is not "the next movement": wait for the hand to stop.
            if tipSpeed < config.shake.exitStillSpeed { lock.restFrom(tip) }
        } else if lock.wakeStart == nil && tip.distance(to: lock.rest) / size >= config.shake.wakeDistance {
            lock.wakeStart = time
        }
        let inWindow = lock.wakeStart.map { time - $0 <= config.shake.wakeTime } ?? true

        if state == .hover && isFist && other == nil && inWindow {
            // Press where the cursor is locked; the fist drags from here.
            state = .dragging
            if !suppressed {
                out.intents.append(.down(x: lock.point.x, y: lock.point.y))
                out.events.append(.dragStarted)
                buttonDown = true
                lastEmittedCursor = lock.point
            }
            // The cursor now follows the palm, offset so that it starts at the pressed point; start
            // the lock afresh from it.
            lastRawBox = mapper.boxPoint(fromCamera: hand.palmCenter)
            reanchor(at: lock.point, time: time)
            lock.restFrom(hand.handSpace(trackedPoint(hand)))
            lock.settling = true
            lastTip = nil
            cursorLock = lock
            shakeDetector.reset()
            return out
        }

        // Wiggles click only with the button up (mid-drag they are just motion).
        let wiggle = state == .hover
            ? shakeDetector.update(point: tip, handSize: hand.handSize, at: time)
            : nil
        if wiggle != nil && (inWindow || lock.settling) {
            if !suppressed { out.append(wiggleClick(at: lock.point, time: time)) }
            // Still locked: once the hand stops, the next movement opens a new window (and a
            // wiggle that just keeps going clicks again: a double click).
            lock.settling = true
            lock.wakeStart = nil
        } else if let wakeStart = lock.wakeStart, time - wakeStart > config.shake.wakeTime {
            if tip.distance(to: lock.rest) / size >= config.shake.minStroke {
                // The hand went somewhere: the cursor follows.
                unlockCursor(lock, at: time)
                return out
            }
            // Only a fidget, or a wiggle that didn't finish: stay locked.
            lock.restFrom(tip)
            shakeDetector.reset()
        }
        cursorLock = lock
        return out
    }

    private func wiggleClick(at point: Point2, time: Double) -> StepOutput {
        var count = 1
        let radius = (router.current?.frame.width ?? 1500) * config.shake.dwellRadiusBox
        if let last = lastClick, time - last.time <= config.shake.doubleClickWindow,
           last.point.distance(to: point) <= radius {
            count = min(last.count + 1, 3)
        }
        lastClick = (time, point, count)
        return StepOutput(intents: [.click(x: point.x, y: point.y, count: count)], events: [.clicked(count: count)])
    }

    /// Leave the lock: the cursor goes to where the hand points now, so a move made during the
    /// wake window isn't lost. Mid-drag that is the palm plus the offset fixed when the fist
    /// pressed; hovering it is the fingertip itself.
    func unlockCursor(_ lock: CursorLock, at time: Double) {
        cursorLock = nil
        if state != .dragging { warpOffset = .zero }
        cursor = lock.point
        dwellAnchor = nil
        shakeDetector.reset()
    }

    // MARK: Drag

    /// The fist opened: release where the cursor is and keep it locked there, so opening the
    /// hand (which swings the fingertip back out) doesn't move it.
    private func drop(_ hand: HandFrame, at time: Double) -> StepOutput {
        let point = cursorLock?.point ?? lastEmittedCursor ?? cursor ?? .zero
        var out = StepOutput()
        if buttonDown {
            buttonDown = false
            out = StepOutput(intents: [.up(x: point.x, y: point.y)], events: [.dragEnded])
        }
        state = .hover
        lastTip = nil
        lockCursor(at: point, hand: hand, at: time)
        cursorLock?.settling = true
        return out
    }

    // MARK: Two fists

    private func updateTwoFists(_ hand: HandFrame, other: HandFrame?, at time: Double, suppressed: Bool) -> StepOutput {
        let bothFists = other != nil && primary.state.pose == .fist && secondary.state.pose == .fist
        if bothFists, let other {
            twoFistsGoneSince = nil
            let midCamera = (hand.palmCenter + other.palmCenter) * 0.5
            let mid = mapper.boxPoint(fromCamera: midCamera)
            let handSize = (hand.handSize + other.handSize) / 2
            let spread = hand.handSpace(hand.palmCenter).distance(to: hand.handSpace(other.palmCenter)) / max(handSize, 1e-4)
            // Box space covered by one hand size here (the mapping isn't uniform).
            let boxPerHand = mapper.boxPoint(fromCamera: midCamera + Point2(handSize, 0)).distance(to: mid)
            guard state == .twoFists, var gesture = twoFists else {
                state = .twoFists
                twoFists = TwoFistGesture(params: config.shake, mid: mid, spread: spread, at: time)
                holdCursorLocked(hand, at: time)
                return StepOutput(intents: momentum.stop())
            }
            gesture.params = config.shake
            let result = gesture.update(mid: mid, spread: spread, boxPerHand: boxPerHand, at: time)
            twoFists = gesture
            guard let result, !suppressed else { return StepOutput() }
            return twoFistOutput(result, at: time)
        }
        guard state == .twoFists else { return StepOutput() }
        // A fist opened or a hand dropped out: give Vision a moment before ending.
        if twoFistsGoneSince == nil { twoFistsGoneSince = time }
        if time - (twoFistsGoneSince ?? time) >= config.shake.fistGoneTime {
            endTwoFists()
            holdCursorLocked(hand, at: time)
        }
        return StepOutput()
    }

    func endTwoFists() {
        if state == .twoFists { state = .hover }
        twoFists = nil
        twoFistsGoneSince = nil
    }

    private func twoFistOutput(_ result: TwoFistGesture.Result, at time: Double) -> StepOutput {
        switch result {
        case let .zoom(factor):
            return StepOutput(intents: [.zoom(factor: 1, phase: .began), .zoom(factor: factor, phase: .changed),
                                        .zoom(factor: 1, phase: .ended)],
                              events: [.zoomStarted, .zoomEnded])
        case let .scroll(dx, dy):
            // Content follows the fists with natural scrolling. A small step now, the rest as a
            // glide, so a whole stroke's scroll doesn't land as one jump.
            let direction = config.naturalScrolling ? 1.0 : -1.0
            let total = Point2(dx, dy) * (config.scrollPointsPerBox * config.scrollSpeed * direction)
            let now = total * Self.twoFistScrollImmediate
            var intents: [Intent] = momentum.stop()
            intents += [.scroll(dx: 0, dy: 0, phase: .began), .scroll(dx: now.x, dy: now.y, phase: .changed),
                        .scroll(dx: 0, dy: 0, phase: .ended)]
            // A glide at v0 under friction k covers v0 / k in total.
            let friction = Self.momentumFriction(config)
            intents.append(momentum.start(velocity: (total - now) * friction, at: time))
            return StepOutput(intents: intents, events: [.scrollStarted, .scrollEnded])
        }
    }

    static let twoFistScrollImmediate = 0.15
}

/// Hold & wiggle's locked cursor.
struct CursorLock {
    /// Where the cursor is held (screen points).
    var point: Point2
    /// The tracked point (hand space) the hand rests from; moving `wakeDistance` from it wakes.
    var rest: Point2
    var since: Double
    /// When the hand started moving again, if it has: the wake window's start.
    var wakeStart: Double?
    /// Just finished a gesture: waiting for the hand to stop before watching for the next movement.
    var settling = false

    /// Wait for the next movement from here.
    mutating func restFrom(_ tip: Point2) {
        rest = tip
        wakeStart = nil
        settling = false
    }
}
