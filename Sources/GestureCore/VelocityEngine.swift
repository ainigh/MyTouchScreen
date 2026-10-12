import Foundation

/// What a segment turned into once composite gestures are taken into account. Used for the
/// overlay's result flash, the "why not?" readout and `tune`'s confusion matrix.
public enum VelocityGesture: String, Codable, Equatable, CaseIterable {
    case click, doubleClick, rightClick
    case scrollUp, scrollDown, scrollLeft, scrollRight
    case dragStart, dragEnd, zoom
    case reposition, ignored
}

/// One classified segment, as reported to the overlay and to `tune`.
public struct SegmentReport: Equatable {
    /// Nil for a landmark glitch (no measurable segment).
    public var stats: SegmentStats?
    public var axis: SegmentAxis
    public var gesture: VelocityGesture
    public var rule: String
    /// When the segment was classified.
    public var time: Double
    /// Where the cursor was at the segment's anchor (global points), filled in by the state
    /// machine; the overlay flashes the result there.
    public var anchor: Point2?

    public init(stats: SegmentStats?, axis: SegmentAxis, gesture: VelocityGesture, rule: String, time: Double,
                anchor: Point2? = nil) {
        self.anchor = anchor
        self.stats = stats
        self.axis = axis
        self.gesture = gesture
        self.rule = rule
        self.time = time
    }
}

/// Hand-space decisions, for the state machine to turn into screen intents. Anchor times let
/// it look up where the cursor was before the segment ("tap where I was").
public enum VelocityAction: Equatable {
    case segmentStarted(anchorTime: Double)
    case segmentEnded(SegmentReport)
    case click(anchorTime: Double, count: Int)
    case rightClick(anchorTime: Double)
    /// `velocity` is the flick's direction × speed in points per second, in hand directions
    /// (x right, y down); the natural-scrolling choice is applied by the state machine.
    case scroll(anchorTime: Double, velocity: Point2)
    /// Mouse down at the last click's position.
    case dragBegan
    /// Mouse up: at the anchor of the releasing tap, or where the cursor is when released by
    /// holding still (`anchorTime` nil).
    case dragEnded(anchorTime: Double?)
    case zoomBegan
    case zoomChanged(factor: Double)
    case zoomEnded
}

/// Velocity mode's composite layer: double click, drag, two-hand zoom, refractory period and
/// the per-hand trackers underneath. Pure hand-space logic, deterministic from timestamps.
public struct VelocityEngine {
    public private(set) var params: VelocityParams
    public private(set) var primary: MotionTracker
    public private(set) var secondary: MotionTracker
    private var secondaryPresent = false

    private var lastClick: (time: Double, anchorCentroid: Point2, count: Int)?
    private var dragArm: (clickTime: Double, settled: Bool, candidateStart: Double?)?
    public private(set) var isDragging = false
    private var dragStillStart: Double?

    // Two hands in fast segments together: a zoom, never a click or scroll.
    private var primaryConsumed = false
    /// The consumed segment actually zoomed (for its report).
    private var consumedZoomed = false
    private var zoom: (start: Double, last: Double, active: Bool)?

    /// Relative change in hand spread before a two-hand gesture counts as a zoom.
    static let zoomStartChange = 0.08

    public init(params: VelocityParams) {
        self.params = params
        self.primary = MotionTracker(params: params)
        self.secondary = MotionTracker(params: params)
    }

    public mutating func updateParams(_ newParams: VelocityParams) {
        params = newParams
        primary.params = newParams
        secondary.params = newParams
    }

    public var isZooming: Bool { zoom?.active == true }
    public var inSegment: Bool { primary.inSegment }

    /// Forget all motion (engaged, disengaged, pointing hand replaced). Returns a zoom end if one
    /// was in progress; a drag in progress is the caller's to release.
    public mutating func reset() -> [VelocityAction] {
        let actions: [VelocityAction] = isZooming ? [.zoomEnded] : []
        primary = MotionTracker(params: params)
        secondary = MotionTracker(params: params)
        secondaryPresent = false
        lastClick = nil
        dragArm = nil
        isDragging = false
        dragStillStart = nil
        primaryConsumed = false
        consumedZoomed = false
        zoom = nil
        return actions
    }

    /// The caller released the drag itself (real mouse took over, hand lost).
    public mutating func cancelDrag() {
        isDragging = false
        dragArm = nil
        dragStillStart = nil
    }

    public mutating func update(primary primarySample: MotionSample, secondary secondarySample: MotionSample?) -> [VelocityAction] {
        let time = primarySample.time
        var actions: [VelocityAction] = []

        // Second hand: tracked only to recognise two-hand gestures.
        var secondaryEnded = false
        if let secondarySample {
            secondaryPresent = true
            for event in secondary.update(secondarySample) {
                if case .segmentEnded = event { secondaryEnded = true }
                if case .glitch = event { secondaryEnded = true }
            }
        } else if secondaryPresent {
            secondaryPresent = false
            secondary = MotionTracker(params: params)
            secondaryEnded = true
        }

        for event in primary.update(primarySample) {
            switch event {
            case let .segmentStarted(anchorTime, _):
                dragArm?.candidateStart = nil
                dragStillStart = nil
                actions.append(.segmentStarted(anchorTime: anchorTime))
            case .glitch:
                let wasConsumed = primaryConsumed
                primaryConsumed = false
                if wasConsumed { actions += endZoom() }
                actions.append(.segmentEnded(SegmentReport(stats: nil, axis: .ambiguous, gesture: .ignored,
                                                           rule: "ignored: landmark glitch", time: time)))
            case let .segmentEnded(stats):
                actions += segmentEnded(stats, at: time)
            }
        }

        actions += updateTwoHands(secondaryEnded: secondaryEnded)

        if !primary.inSegment {
            actions += updateDrag(at: time)
        }
        return actions
    }

    // MARK: Segment results

    private mutating func segmentEnded(_ stats: SegmentStats, at time: Double) -> [VelocityAction] {
        let result = VelocityClassifier.classify(stats, params)
        var actions: [VelocityAction] = []
        func report(_ gesture: VelocityGesture, _ rule: String) {
            actions.append(.segmentEnded(SegmentReport(stats: stats, axis: result.axis, gesture: gesture,
                                                       rule: rule, time: time)))
        }

        if primaryConsumed {
            primaryConsumed = false
            let zoomed = consumedZoomed || isZooming
            consumedZoomed = false
            actions += endZoom()
            report(zoomed ? .zoom : .ignored, zoomed ? "zoom: two hands" : "ignored: both hands moved together")
            return actions
        }

        if isDragging {
            switch result.segmentClass {
            case .leftClick, .rightClick:
                isDragging = false
                dragStillStart = nil
                primary.refractoryUntil = time + params.refractory
                actions.append(.dragEnded(anchorTime: stats.anchorTime))
                report(.dragEnd, "drop: tap while dragging")
            case .scroll, .reposition:
                report(.reposition, "dragging")
            }
            return actions
        }

        let dragWindowOpen = params.dragEnabled && dragArm.map { stats.startTime - $0.clickTime <= params.dragStartWindow } == true
        switch result.segmentClass {
        case .leftClick:
            var count = 1
            if let last = lastClick, last.count == 1,
               stats.startTime - last.time <= params.doubleClickWindow,
               stats.anchorCentroid.distance(to: last.anchorCentroid) / stats.handSize <= params.doubleClickDisp {
                count = 2
            }
            lastClick = (time, stats.anchorCentroid, count)
            dragArm = (count == 1 && params.dragEnabled) ? (time, false, nil) : nil
            primary.refractoryUntil = time + params.refractory
            actions.append(.click(anchorTime: stats.anchorTime, count: count))
            report(count == 2 ? .doubleClick : .click, count == 2 ? "double click: second tap in time" : result.rule)
        case .rightClick:
            lastClick = nil
            dragArm = nil
            primary.refractoryUntil = time + params.refractory
            actions.append(.rightClick(anchorTime: stats.anchorTime))
            report(.rightClick, result.rule)
        case .scroll, .reposition:
            if dragWindowOpen {
                // A fast move right after a click: the drag started faster than the slow path
                // could confirm. Press at the click and catch up to the hand.
                dragArm = nil
                lastClick = nil
                isDragging = true
                actions.append(.dragBegan)
                report(.dragStart, "drag: moved right after a click")
            } else if case let .scroll(direction) = result.segmentClass {
                lastClick = nil
                dragArm = nil
                primary.refractoryUntil = time + params.refractory
                let velocity = direction * (params.scrollGain * stats.peakSpeed)
                actions.append(.scroll(anchorTime: stats.anchorTime, velocity: velocity))
                let gesture: VelocityGesture = direction.y < 0 ? .scrollUp : direction.y > 0 ? .scrollDown
                    : direction.x < 0 ? .scrollLeft : .scrollRight
                report(gesture, result.rule)
            } else {
                report(.reposition, result.rule)
            }
        }
        return actions
    }

    // MARK: Drag

    private mutating func updateDrag(at time: Double) -> [VelocityAction] {
        let speed = primary.speed
        if isDragging {
            if speed < params.dragStillV {
                if dragStillStart == nil { dragStillStart = time }
                if time - (dragStillStart ?? time) + primary.framePeriod >= params.dragStillTime {
                    isDragging = false
                    dragStillStart = nil
                    return [.dragEnded(anchorTime: nil)]
                }
            } else {
                dragStillStart = nil
            }
            return []
        }
        guard var arm = dragArm else { return [] }
        if !arm.settled {
            // Let the tap itself finish settling before watching for drag movement.
            if speed < params.dragMoveMin { arm.settled = true }
        } else if speed > params.dragMoveMin {
            if arm.candidateStart == nil { arm.candidateStart = time }
            if time - (arm.candidateStart ?? time) + primary.framePeriod >= params.dragConfirmTime {
                dragArm = nil
                lastClick = nil
                isDragging = true
                return [.dragBegan]
            }
        } else {
            arm.candidateStart = nil
        }
        if arm.candidateStart == nil && time - arm.clickTime > params.dragStartWindow {
            dragArm = nil
        } else {
            dragArm = arm
        }
        return []
    }

    // MARK: Two hands

    private mutating func updateTwoHands(secondaryEnded: Bool) -> [VelocityAction] {
        var actions: [VelocityAction] = []
        if !primaryConsumed, primary.inSegment, secondary.inSegment,
           let a = primary.segmentStartTime, let b = secondary.segmentStartTime,
           abs(a - b) <= params.twoHandWindow, let spread = handSpread() {
            primaryConsumed = true
            consumedZoomed = false
            zoom = (spread, spread, false)
        }
        guard let current = zoom else { return actions }
        if secondaryEnded || !secondary.inSegment {
            // The second hand stopped: the gesture is over (the primary's segment stays
            // consumed until it ends).
            actions += endZoom()
            return actions
        }
        guard let spread = handSpread(), current.start > 0, current.last > 0 else { return actions }
        if !current.active {
            if abs(log(spread / current.start)) >= log(1 + Self.zoomStartChange) {
                zoom = (current.start, spread, true)
                consumedZoomed = true
                actions.append(.zoomBegan)
                actions.append(.zoomChanged(factor: spread / current.start))
            }
        } else {
            let factor = spread / current.last
            if abs(log(factor)) > 0.002 {
                zoom = (current.start, spread, true)
                actions.append(.zoomChanged(factor: factor))
            }
        }
        return actions
    }

    /// Distance between the two centroids in mean hand sizes (moving both hands toward the
    /// camera changes both, so the ratio stays put).
    private func handSpread() -> Double? {
        guard let a = primary.centroid, let b = secondary.centroid else { return nil }
        let size = (primary.handSize + secondary.handSize) / 2
        return a.distance(to: b) / max(size, 1e-4)
    }

    private mutating func endZoom() -> [VelocityAction] {
        let wasActive = isZooming
        zoom = nil
        return wasActive ? [.zoomEnded] : []
    }
}
