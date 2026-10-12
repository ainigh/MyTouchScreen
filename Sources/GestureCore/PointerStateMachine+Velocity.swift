import Foundation

/// Velocity mode (SPEC-M7): the fingertip drives the cursor exactly as in Pose mode, and the
/// palm centroid's velocity drives clicks, scrolls, drags and zoom through `VelocityEngine`.
/// This file turns the engine's hand-space decisions into screen intents.
extension PointerStateMachine {
    /// Fraction of the warp offset that remains after the hand moves one box width outside a
    /// flick: the cursor re-converges on the absolute hand mapping gradually, hidden inside
    /// ordinary movement, so the reach to every screen edge comes back.
    static let warpDrainBox = 0.5

    func resetVelocity() {
        _ = velocityEngine.reset()
        shakeDetector.reset()
        shakeStillSince = nil
        dragPress = nil
        dragSettleSince = nil
        warpOffset = .zero
        lastRawBox = nil
        trailAnchorTime = nil
    }

    func updatePointerVelocity(_ hand: HandFrame, secondary secondaryHand: HandFrame?, at time: Double) -> StepOutput {
        var out = StepOutput()
        let suppressed = time < outputSuppressedUntil
        let actions = velocityEngine.update(primary: MotionSample(hand),
                                            secondary: secondaryHand.map { MotionSample($0) })

        // Cursor: the fingertip, live, during flicks too (freezing would delay every reposition).
        let rawBox = mapper.boxPoint(fromCamera: hand[.indexTip])
        if let previous = lastRawBox, !velocityEngine.inSegment, warpOffset != .zero {
            let drain = min((rawBox - previous).length / Self.warpDrainBox, 1)
            warpOffset = warpOffset * (1 - drain)
            if warpOffset.length < 1e-5 { warpOffset = .zero }
        }
        lastRawBox = rawBox
        var box = rawBox + warpOffset
        lastBox = box

        if state == .hover || state == .dragging {
            if let jumped = router.update(box: box, at: time) {
                rebuildMapper()
                warpOffset = .zero
                box = mapper.boxPoint(fromCamera: hand[.indexTip])
                lastRawBox = box
                smoother.reset(to: box, at: time)
                out.events.append(.displayChanged(jumped.id))
            }
        }
        guard let display = router.current else { return out }

        let smoothed = smoother.process(box, at: time)
        let screen = ActiveBoxMapper.screenPoint(fromBox: smoothed, on: display)
        // Two-hand zoom holds the cursor still: apps zoom around it.
        if state != .zooming {
            cursor = screen
            out.append(emitMove(screen, suppressed: suppressed))
        }
        history.append(PointerSample(time: time, cursor: cursor ?? screen, box: smoothed, pinchDistance: 1,
                                     tipOffset: .zero))
        history.removeAll { time - $0.time > Self.historySpan }
        if state == .hover { out.append(updateDwell(screen, at: time, suppressed: suppressed)) }

        for action in actions {
            out.append(perform(action, at: time, suppressed: suppressed))
        }
        return out
    }

    // MARK: Actions

    private func perform(_ action: VelocityAction, at time: Double, suppressed: Bool) -> StepOutput {
        var out = StepOutput()
        switch action {
        case let .segmentStarted(anchorTime):
            // A new flick stops a glide immediately, like touching a trackpad.
            out.intents += momentum.stop()
            trailAnchorTime = anchorTime
            if state == .hover { state = .flicking }

        case var .segmentEnded(report):
            trailAnchorTime = nil
            if state == .flicking { state = .hover }
            report.anchor = report.stats.map { cursorAt($0.anchorTime) }
            snapshot.lastSegment = report
            out.events.append(.segmentClassified(report))

        case let .click(anchorTime, count):
            var point = cursorAt(anchorTime)
            // macOS only counts a double click when both clicks land on (nearly) the same pixel.
            if count > 1, let last = lastClick { point = last.point }
            lastClick = (time, point, count)
            guard !suppressed else { break }
            out.append(warp(to: point, at: time))
            out.intents.append(.click(x: point.x, y: point.y, count: count))
            out.events.append(.clicked(count: count))

        case let .rightClick(anchorTime):
            let point = cursorAt(anchorTime)
            lastClick = nil
            guard !suppressed else { break }
            out.append(warp(to: point, at: time))
            out.intents.append(.rightClick(x: point.x, y: point.y))
            out.events.append(.rightClicked)

        case let .scroll(anchorTime, velocity):
            let point = cursorAt(anchorTime)
            guard !suppressed else { break }
            out.append(warp(to: point, at: time))
            // Content follows the flick with natural scrolling, and moves against it otherwise.
            let content = velocity * (config.naturalScrolling ? 1 : -1)
            let frame = 1 / VelocityParams.referenceRate
            out.intents.append(.scroll(dx: 0, dy: 0, phase: .began))
            out.intents.append(.scroll(dx: content.x * frame, dy: content.y * frame, phase: .changed))
            out.intents.append(.scroll(dx: 0, dy: 0, phase: .ended))
            out.events.append(.scrollStarted)
            out.events.append(.scrollEnded)
            out.intents.append(momentum.start(velocity: content, at: time))

        case .dragBegan:
            let point = lastClick?.point ?? cursor ?? .zero
            lastClick = nil
            state = .dragging
            guard !suppressed else { break }
            out.intents.append(.down(x: point.x, y: point.y))
            buttonDown = true
            lastEmittedCursor = point
            out.events.append(.dragStarted)
            // Catch up with the hand, which has already started moving.
            if let cursor { out.append(emitMove(cursor, suppressed: false)) }

        case let .dragEnded(anchorTime):
            state = .hover
            guard buttonDown else { break }
            if let anchorTime {
                // Released by a tap: drop where the tap started, not where the tap moved to.
                let point = cursorAt(anchorTime)
                out.append(warp(to: point, at: time))
                buttonDown = false
                out.intents.append(.up(x: point.x, y: point.y))
                out.events.append(.dragEnded)
            } else {
                out.append(releaseButton())
            }

        case .zoomBegan:
            guard config.zoomEnabled else { break }
            state = .zooming
            out.intents.append(.zoom(factor: 1, phase: .began))
            out.events.append(.zoomStarted)

        case let .zoomChanged(factor):
            guard config.zoomEnabled, !suppressed else { break }
            out.intents.append(.zoom(factor: factor, phase: .changed))

        case .zoomEnded:
            guard state == .zooming else { break }
            state = .hover
            // The cursor was held during the zoom; keep it there rather than jumping to the hand.
            if let cursor { reanchor(at: cursor, time: time) }
            out.intents.append(.zoom(factor: 1, phase: .ended))
            out.events.append(.zoomEnded)
        }
        return out
    }

    /// Put the cursor back at `point` with one move and keep it there: the smoother restarts at
    /// that point and the fingertip mapping picks up an offset that drains as the hand moves on.
    func warp(to point: Point2, at time: Double) -> StepOutput {
        reanchor(at: point, time: time)
        cursor = point
        lastEmittedCursor = point
        return StepOutput(intents: [.move(x: point.x, y: point.y)])
    }

    func reanchor(at point: Point2, time: Double) {
        guard let display = router.current, let raw = lastRawBox else { return }
        let box = ActiveBoxMapper.boxPoint(fromScreen: point, on: display)
        warpOffset = box - raw
        smoother.reset(to: box, at: time)
    }

    /// Where the cursor was at `time` (the last pointer sample at or before it).
    func cursorAt(_ time: Double) -> Point2 {
        if let sample = history.last(where: { $0.time <= time + 1e-9 }) { return sample.cursor }
        return history.first?.cursor ?? cursor ?? .zero
    }

    /// Cursor positions since the current segment's anchor, for the overlay trail.
    func segmentTrail() -> [Point2] {
        guard let anchor = trailAnchorTime, isEngaged else { return [] }
        return history.filter { $0.time >= anchor - 1e-9 }.map(\.cursor)
    }
}
