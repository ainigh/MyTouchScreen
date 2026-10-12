import Foundation

/// Hold & wiggle (the default input model). The right hand points; the left hand is a modifier.
///
/// Right hand alone:
/// - movement moves the cursor;
/// - holding the cursor still for `shake.lockTime` locks it in place. When the hand moves again
///   the cursor stays locked for `shake.wakeTime` more: a wiggle (`shake.clickReversals`
///   direction changes) within that time clicks where the cursor is locked, and the cursor stays
///   locked, waiting for the next movement, so wiggling again clicks again (a double click when
///   quick). No wiggle in that time: the cursor unlocks and follows the hand from where it was.
///   This is the only way this model clicks;
/// - wiggling while the cursor moves (`shake.reversals` direction changes along one axis within
///   `shake.window`) puts the cursor back where the wiggle started and enters scroll mode: the
///   fingertip's movement along that axis scrolls, until the hand holds still.
///
/// Left hand visible (any pose, anywhere):
/// - the right hand's movement drags: the button goes down where the cursor was when the left
///   hand appeared, as soon as the right hand clearly moves; the left hand leaving drops;
/// - a wiggle zooms instead of scrolling: after it, moving up / right zooms in, down / left out,
///   until the hand holds still.
///
/// Both hands up as open palms engage and disengage; while they are up nothing else happens.
/// `preferredHand = .left` swaps the roles for left-handed use.
extension PointerStateMachine {
    // MARK: Hands

    /// The pointing hand and the modifier hand. With two hands, position decides (more reliable
    /// than Vision's chirality): the user's right hand is on the camera's left.
    func assignPointerAndModifier(_ hands: [HandFrame], at time: Double) -> (HandFrame?, HandFrame?, Bool) {
        let pointerIsLeft = config.preferredHand == .left
        var pointer: HandFrame?
        var modifier: HandFrame?
        if hands.count >= 2 {
            let byX = hands.sorted { $0[.wrist].x < $1[.wrist].x }
            pointer = pointerIsLeft ? byX.last : byX.first
            modifier = pointerIsLeft ? byX.first : byX.last
        } else if let only = hands.first {
            let modifierChirality: Chirality = pointerIsLeft ? .right : .left
            if only.chirality == modifierChirality { modifier = only } else { pointer = only }
        }
        if let pointer {
            primaryLastPalm = pointer.palmCenter
            primaryLastSeen = time
        }
        return (pointer, modifier, false)
    }

    /// Debounced modifier presence: Vision drops a hand for a frame now and then, which must not
    /// drop a drag, and a one-frame ghost hand must not start one.
    func updateModifier(_ hand: HandFrame?, at time: Double) {
        if hand != nil {
            if modifierSince == nil { modifierSince = time }
            modifierLastSeen = time
        } else if let last = modifierLastSeen, time - last > config.shake.modifierGoneTime {
            modifierSince = nil
            modifierLastSeen = nil
        }
    }

    var modifierPresent: Bool {
        guard let since = modifierSince, let last = modifierLastSeen else { return false }
        return last - since >= config.shake.modifierAppearTime
    }

    /// Fingertip speed in hand sizes per second, lightly smoothed. Everything in this model
    /// follows the fingertip — the point the cursor follows — because people wiggle and move the
    /// finger as often as the whole hand (the owner's first recording: the palm stayed put while
    /// the index finger wagged).
    func updateTipSpeed(_ hand: HandFrame, at time: Double) {
        let tip = hand.handSpace(hand[.indexTip])
        if let last = lastTip, time > last.time {
            let instant = tip.distance(to: last.point) / max(hand.handSize, 1e-4) / (time - last.time)
            tipSpeed += (instant - tipSpeed) * 0.4
        }
        lastTip = (time, tip)
    }

    // MARK: Frame

    func updatePointerShake(_ hand: HandFrame, modifier: HandFrame?, at time: Double) -> StepOutput {
        var out = StepOutput()
        let suppressed = time < outputSuppressedUntil
        shakeDetector.params = config.shake
        updateTipSpeed(hand, at: time)
        updateModifier(modifier, at: time)
        let modified = modifierPresent

        if bothPalmsOpen && [.hover, .dragReady].contains(state) {
            // Two open palms are the engage / disengage gesture, not a drag: hold the cursor
            // where it is (a lock, so lowering the hands doesn't fling it anywhere).
            state = .hover
            dragPress = nil
            dragSettleSince = nil
            shakeDetector.reset()
            if let point = lastEmittedCursor ?? cursor, cursorLock == nil {
                lockCursor(at: point, hand: hand, at: time)
            }
            cursorLock?.restFrom(hand.handSpace(hand[.indexTip]))
            return out
        }

        switch state {
        case .scrolling:
            if modified {
                out.append(endShakeMode(hand, at: time))
            } else {
                out.append(updateShakeMode(hand, at: time, suppressed: suppressed))
                return out
            }
        case .zooming:
            if !modified {
                out.append(endShakeMode(hand, at: time))
            } else {
                out.append(updateShakeMode(hand, at: time, suppressed: suppressed))
                return out
            }
        case .dragging where !modified:
            // Left hand gone: drop where the cursor is.
            state = .hover
            out.append(releaseButton())
            dragPress = nil
        case .dragReady where !modified:
            // Left hand gone before the drag committed: a small move still counts as a drag.
            out.append(commitDragIfMoved(hand, at: time, suppressed: suppressed, minimum: config.shake.dragSmallDistance))
            if state == .dragging {
                out.append(releaseButton())
            }
            state = .hover
            dragPress = nil
        case .hover where modified:
            // The left hand came up: a drag presses where the cursor is, locked or not.
            if let lock = cursorLock { unlockCursor(lock, at: time, continueFromLock: true) }
            state = .dragReady
            dragPress = (cursor ?? .zero, hand.handSpace(hand[.indexTip]), time)
            dragSettleSince = nil
            dwellAnchor = nil
            shakeDetector.reset()
        default:
            break
        }

        // Cursor: the fingertip, with the offset left by a warp draining as the hand moves.
        let rawBox = mapper.boxPoint(fromCamera: hand[.indexTip])
        if let previous = lastRawBox, warpOffset != .zero {
            let drain = min((rawBox - previous).length / Self.warpDrainBox, 1)
            warpOffset = warpOffset * (1 - drain)
            if warpOffset.length < 1e-5 { warpOffset = .zero }
        }
        lastRawBox = rawBox
        if state == .hover, let lock = cursorLock {
            out.append(updateLockedCursor(lock, hand: hand, at: time, suppressed: suppressed))
            if cursorLock != nil { return out }
        }
        var box = rawBox + warpOffset
        lastBox = box
        if let jumped = router.update(box: box, at: time) {
            rebuildMapper()
            warpOffset = .zero
            box = mapper.boxPoint(fromCamera: hand[.indexTip])
            lastRawBox = box
            smoother.reset(to: box, at: time)
            out.events.append(.displayChanged(jumped.id))
        }
        guard let display = router.current else { return out }
        let screen = ActiveBoxMapper.screenPoint(fromBox: smoother.process(box, at: time), on: display)
        cursor = screen
        history.append(PointerSample(time: time, cursor: screen, box: box, pinchDistance: 1, tipOffset: .zero))
        history.removeAll { time - $0.time > Self.historySpan }

        // A wiggle scrolls; with the left hand up it zooms. Mid-drag it is just drag motion.
        if state == .dragging {
            shakeDetector.reset()
        } else if let wiggle = shakeDetector.update(point: hand.handSpace(hand[.indexTip]), handSize: hand.handSize, at: time) {
            out.append(enterShakeMode(zoom: state == .dragReady, wiggle: wiggle, hand: hand, at: time,
                                      suppressed: suppressed))
            return out
        }

        if state == .dragReady {
            out.append(commitDragIfMoved(hand, at: time, suppressed: suppressed, minimum: config.shake.dragCommitDistance))
            if state == .dragReady && settledAfterSmallMove(hand, at: time) {
                out.append(commitDragIfMoved(hand, at: time, suppressed: suppressed, minimum: config.shake.dragSmallDistance))
            }
        }

        // While a drag is armed but not yet pressed, the cursor still moves (the press lands
        // where the left hand appeared and catches up).
        out.append(emitMove(screen, suppressed: suppressed))
        if state == .hover && !suppressed {
            updateLockArming(screen, hand: hand, at: time)
        }
        return out
    }

    // MARK: Lock and click

    /// Holding the cursor within `dwellRadiusBox` for `lockTime` locks it.
    private func updateLockArming(_ screen: Point2, hand: HandFrame, at time: Double) {
        let radius = (router.current?.frame.width ?? 1500) * config.shake.dwellRadiusBox
        guard let anchor = dwellAnchor, anchor.point.distance(to: screen) <= radius else {
            dwellAnchor = (time, screen)
            return
        }
        if time - anchor.time >= config.shake.lockTime {
            // Lock where the pointer visibly is, so the click lands exactly there.
            lockCursor(at: lastEmittedCursor ?? screen, hand: hand, at: time)
        }
    }

    func lockCursor(at point: Point2, hand: HandFrame, at time: Double) {
        cursorLock = CursorLock(point: point, rest: hand.handSpace(hand[.indexTip]), since: time)
        cursor = point
        dwellAnchor = nil
        shakeDetector.reset()
    }

    /// The cursor stays put. Moving the hand opens the wake window: a wiggle in it clicks (and the
    /// lock waits for the next movement); a real move without a wiggle unlocks when it ends.
    private func updateLockedCursor(_ lock: CursorLock, hand: HandFrame, at time: Double,
                                    suppressed: Bool) -> StepOutput {
        var lock = lock
        var out = StepOutput()
        cursor = lock.point
        history.append(PointerSample(time: time, cursor: lock.point, box: lastBox ?? .zero, pinchDistance: 1, tipOffset: .zero))
        history.removeAll { time - $0.time > Self.historySpan }

        let tip = hand.handSpace(hand[.indexTip])
        let size = max(hand.handSize, 1e-4)
        if lock.settling {
            // The tail of a click wiggle is not "the next movement": wait for the hand to stop.
            if tipSpeed < config.shake.exitStillSpeed { lock.restFrom(tip) }
        } else if lock.wakeStart == nil && tip.distance(to: lock.rest) / size >= config.shake.wakeDistance {
            lock.wakeStart = time
        }
        let wiggle = shakeDetector.update(point: tip, handSize: hand.handSize, at: time,
                                          reversals: config.shake.clickReversals)
        let inWindow = lock.settling || lock.wakeStart.map { time - $0 <= config.shake.wakeTime } ?? false
        if wiggle != nil && inWindow {
            if !suppressed { out.append(wiggleClick(at: lock.point, time: time)) }
            // Still locked: once the hand stops, the next movement opens a new window (and a
            // wiggle that just keeps going clicks again: a double click).
            lock.settling = true
            lock.wakeStart = nil
        } else if let wakeStart = lock.wakeStart, time - wakeStart > config.shake.wakeTime {
            if tip.distance(to: lock.rest) / size >= config.shake.minStroke {
                // The hand went somewhere: the cursor follows from where it was locked.
                unlockCursor(lock, at: time, continueFromLock: false)
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

    /// Leave the lock. After a wake the cursor goes to where the hand points (it is a pointer);
    /// a drag starting from a lock carries on from the locked point instead, so it doesn't drag
    /// across the screen to catch up with the hand.
    func unlockCursor(_ lock: CursorLock, at time: Double, continueFromLock: Bool) {
        cursorLock = nil
        if continueFromLock { reanchor(at: lock.point, time: time) }
        cursor = lock.point
        dwellAnchor = nil
        shakeDetector.reset()
    }

    // MARK: Drag

    /// Press at the drag's start and catch up to the cursor once the right hand has moved
    /// `minimum` hand sizes from where it was when the left hand appeared. Waiting for a clear
    /// move is what lets a wiggle (zoom) start without pressing anything.
    private func commitDragIfMoved(_ hand: HandFrame, at time: Double, suppressed: Bool, minimum: Double) -> StepOutput {
        guard state == .dragReady, let press = dragPress else { return StepOutput() }
        let moved = hand.handSpace(hand[.indexTip]).distance(to: press.centroid) / max(hand.handSize, 1e-4)
        guard moved >= minimum else { return StepOutput() }
        state = .dragging
        dwellAnchor = nil
        guard !suppressed else { return StepOutput() }
        var out = StepOutput(intents: [.down(x: press.point.x, y: press.point.y)], events: [.dragStarted])
        buttonDown = true
        lastEmittedCursor = press.point
        if let cursor { out.append(emitMove(cursor, suppressed: false)) }
        return out
    }

    /// A small move followed by holding still also commits (dragging a slider a little).
    private func settledAfterSmallMove(_ hand: HandFrame, at time: Double) -> Bool {
        guard tipSpeed < config.shake.exitStillSpeed else {
            dragSettleSince = nil
            return false
        }
        if dragSettleSince == nil { dragSettleSince = time }
        return time - (dragSettleSince ?? time) >= config.shake.dragSettleTime
    }

    // MARK: Scroll / zoom mode

    private func enterShakeMode(zoom: Bool, wiggle: ShakeDetector.Detection, hand: HandFrame, at time: Double,
                                suppressed: Bool) -> StepOutput {
        var out = StepOutput(intents: momentum.stop())
        // The wiggle moved the cursor around; work from where it started.
        let anchor = cursorAt(wiggle.startTime)
        if !suppressed { out.append(warp(to: anchor, at: time)) }
        cursor = anchor
        state = zoom ? .zooming : .scrolling
        shakeScrollVertical = wiggle.vertical
        shakeStillSince = nil
        dwellAnchor = nil
        scrollFilter.reset(to: mapper.boxPoint(fromCamera: hand[.indexTip]), at: time)
        scrollLastPalm = nil
        scrollRemainder = .zero
        guard !suppressed else { return out }
        if zoom {
            out.intents.append(.zoom(factor: 1, phase: .began))
            out.events.append(.zoomStarted)
        } else {
            out.intents.append(.scroll(dx: 0, dy: 0, phase: .began))
            out.events.append(.scrollStarted)
        }
        return out
    }

    /// The fingertip's movement along the wiggle's axis scrolls (content follows the hand with
    /// natural scrolling) or zooms (up / right = in); holding still ends it. The cursor stays.
    private func updateShakeMode(_ hand: HandFrame, at time: Double, suppressed: Bool) -> StepOutput {
        if tipSpeed < config.shake.exitStillSpeed {
            if shakeStillSince == nil { shakeStillSince = time }
            if time - (shakeStillSince ?? time) >= config.shake.exitStillTime {
                return endShakeMode(hand, at: time)
            }
        } else {
            shakeStillSince = nil
        }

        let tipBox = scrollFilter.filter(mapper.boxPoint(fromCamera: hand[.indexTip]), at: time)
        defer {
            scrollLastPalm = tipBox
            scrollLastTime = time
        }
        guard let last = scrollLastPalm, time > scrollLastTime else { return StepOutput() }
        let moved = tipBox - last

        if state == .zooming {
            // Box y grows downward, so "up" is negative y.
            let along = shakeScrollVertical ? -moved.y : moved.x
            let factor = exp(along * log(2) / max(config.shake.zoomDoublingBox, 0.01))
            guard abs(log(factor)) > 0.002, !suppressed else { return StepOutput() }
            return StepOutput(intents: [.zoom(factor: factor, phase: .changed)])
        }

        let direction = config.naturalScrolling ? 1.0 : -1.0
        var step = moved * (config.scrollPointsPerBox * config.scrollSpeed * direction)
        if shakeScrollVertical { step.x = 0 } else { step.y = 0 }
        let delta = step + scrollRemainder
        // Sub-point deltas accumulate instead of being lost or sent as noise.
        if abs(delta.x) < 0.5 && abs(delta.y) < 0.5 {
            scrollRemainder = delta
            return StepOutput()
        }
        scrollRemainder = .zero
        guard !suppressed else { return StepOutput() }
        return StepOutput(intents: [.scroll(dx: delta.x, dy: delta.y, phase: .changed)])
    }

    /// Leave scroll or zoom mode. With the left hand still up, a new drag is armed from here.
    private func endShakeMode(_ hand: HandFrame, at time: Double) -> StepOutput {
        let wasZoom = state == .zooming
        shakeStillSince = nil
        shakeDetector.reset()
        // Keep the cursor where it was held instead of jumping to wherever the hand is now.
        if let cursor { reanchor(at: cursor, time: time) }
        if modifierPresent, let cursor {
            state = .dragReady
            dragPress = (cursor, hand.handSpace(hand[.indexTip]), time)
            dragSettleSince = nil
        } else {
            state = .hover
            // Holding still after the scroll locks the cursor like any other rest.
            if let cursor { dwellAnchor = (time, cursor) }
        }
        return wasZoom
            ? StepOutput(intents: [.zoom(factor: 1, phase: .ended)], events: [.zoomEnded])
            : StepOutput(intents: [.scroll(dx: 0, dy: 0, phase: .ended)], events: [.scrollEnded])
    }
}

/// Hold & wiggle's locked cursor.
struct CursorLock {
    /// Where the cursor is held (screen points).
    var point: Point2
    /// The fingertip (hand space) the hand rests from; moving `wakeDistance` from it wakes.
    var rest: Point2
    var since: Double
    /// When the hand started moving again, if it has: the wake window's start.
    var wakeStart: Double?
    /// Just clicked: waiting for the wiggling hand to stop before watching for the next movement.
    var settling = false

    /// Wait for the next movement from here.
    mutating func restFrom(_ tip: Point2) {
        rest = tip
        wakeStart = nil
        settling = false
    }
}
