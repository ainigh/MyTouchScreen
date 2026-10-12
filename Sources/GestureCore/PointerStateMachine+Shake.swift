import Foundation

/// Hold & wiggle (the default input model):
/// - every movement moves the cursor (fingertip, smoothed exactly as in the other models);
/// - holding the cursor still for `shake.dwellTime` clicks, once, where it rests;
/// - wiggling the hand back and forth (`shake.reversals` direction changes along one axis within
///   `shake.window`) puts the cursor back where the wiggle started and enters scroll mode: the
///   palm's movement along that axis then scrolls, until the hand holds still;
/// - the open palm engages and disengages as always.
extension PointerStateMachine {
    func updatePointerShake(_ hand: HandFrame, at time: Double) -> StepOutput {
        var out = StepOutput()
        let suppressed = time < outputSuppressedUntil
        shakeDetector.params = config.shake

        if state == .scrolling {
            out.append(updateShakeScroll(hand, at: time, suppressed: suppressed))
            return out
        }

        // Cursor: the fingertip, with the offset left by a warp draining as the hand moves.
        let rawBox = mapper.boxPoint(fromCamera: hand[.indexTip])
        if let previous = lastRawBox, warpOffset != .zero {
            let drain = min((rawBox - previous).length / Self.warpDrainBox, 1)
            warpOffset = warpOffset * (1 - drain)
            if warpOffset.length < 1e-5 { warpOffset = .zero }
        }
        lastRawBox = rawBox
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

        if let wiggle = shakeDetector.update(centroid: hand.motionCentroid, handSize: hand.handSize, at: time) {
            // The wiggle moved the cursor around; scroll from where it started.
            let anchor = cursorAt(wiggle.startTime)
            out.intents += momentum.stop()
            if !suppressed { out.append(warp(to: anchor, at: time)) }
            cursor = anchor
            state = .scrolling
            shakeScrollVertical = wiggle.vertical
            shakeStillSince = nil
            dwellAnchor = nil
            scrollFilter.reset(to: mapper.boxPoint(fromCamera: hand.palmCenter), at: time)
            scrollLastPalm = nil
            scrollRemainder = .zero
            if !suppressed {
                out.intents.append(.scroll(dx: 0, dy: 0, phase: .began))
                out.events.append(.scrollStarted)
            }
            return out
        }

        out.append(emitMove(screen, suppressed: suppressed))
        if dwellAnchor == nil {
            // Just engaged (or the real mouse just let go): the cursor has to go somewhere and
            // settle before holding still clicks, so engaging never clicks by itself.
            dwellAnchor = (time, screen)
            dwellLatched = true
        }
        out.append(updateDwell(screen, at: time, suppressed: suppressed))
        return out
    }

    /// Scroll mode: the palm's movement along the wiggle's axis scrolls (content follows the
    /// hand with natural scrolling); holding still ends it. The cursor stays put meanwhile.
    private func updateShakeScroll(_ hand: HandFrame, at time: Double, suppressed: Bool) -> StepOutput {
        var out = StepOutput()
        if palmSpeed < config.shake.exitStillSpeed {
            if shakeStillSince == nil { shakeStillSince = time }
            if time - (shakeStillSince ?? time) >= config.shake.exitStillTime {
                return endShakeScroll(at: time)
            }
        } else {
            shakeStillSince = nil
        }

        let palmBox = scrollFilter.filter(mapper.boxPoint(fromCamera: hand.palmCenter), at: time)
        defer {
            scrollLastPalm = palmBox
            scrollLastTime = time
        }
        guard let last = scrollLastPalm, time > scrollLastTime else { return out }
        let direction = config.naturalScrolling ? 1.0 : -1.0
        let scale = config.scrollPointsPerBox * config.scrollSpeed * direction
        var step = (palmBox - last) * scale
        if shakeScrollVertical { step.x = 0 } else { step.y = 0 }
        let delta = step + scrollRemainder
        // Sub-point deltas accumulate instead of being lost or sent as noise.
        if abs(delta.x) < 0.5 && abs(delta.y) < 0.5 {
            scrollRemainder = delta
            return out
        }
        scrollRemainder = .zero
        guard !suppressed else { return out }
        out.intents.append(.scroll(dx: delta.x, dy: delta.y, phase: .changed))
        return out
    }

    private func endShakeScroll(at time: Double) -> StepOutput {
        state = .hover
        shakeStillSince = nil
        shakeDetector.reset()
        // Keep the cursor where it was held instead of jumping to wherever the hand is now.
        if let cursor {
            reanchor(at: cursor, time: time)
            // A finished scroll is not the start of a dwell click.
            dwellAnchor = (time, cursor)
            dwellLatched = true
        }
        return StepOutput(intents: [.scroll(dx: 0, dy: 0, phase: .ended)], events: [.scrollEnded])
    }
}
