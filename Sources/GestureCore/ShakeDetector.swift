import Foundation

/// Hold & wiggle tunables. Distances in hand sizes (wrist → middle MCP), times in seconds.
public struct ShakeParams: Equatable, Codable {
    /// Hold the cursor still this long and it locks in place.
    public var lockTime = 1.0
    /// "Still" = the cursor stays within this fraction of the screen width. A calm real
    /// fingertip drifts the cursor 25–40 pt over a couple of seconds (owner's recording), so
    /// this is wider than the Pose-mode dwell radius.
    public var dwellRadiusBox = 0.025
    /// A locked cursor wakes when the fingertip moves this far (hand sizes) from where it rested…
    public var wakeDistance = 0.12
    /// …and stays put this long after that: a wiggle within this time clicks where it is locked.
    public var wakeTime = 1.0
    /// Direction changes along one axis that make the click wiggle (left-right-left)…
    public var clickReversals = 2
    /// A second wiggle click within this long of the first, at the same spot, is a double click.
    public var doubleClickWindow = 1.5
    /// Direction changes along one axis that start scrolling (while the cursor is moving)…
    public var reversals = 3
    /// …all within this window.
    public var window = 1.0
    /// A movement only counts as a stroke (and its end as a direction change) once it has
    /// travelled this far, so tracker jitter and small corrections never add up to a wiggle.
    public var minStroke = 0.25
    /// Scrolling ends when the fingertip stays below this speed (hand sizes per second)…
    /// A resting real fingertip jitters at 0.35–0.8 hand sizes/s (owner's recording).
    public var exitStillSpeed = 1.2
    /// …for this long.
    public var exitStillTime = 0.5

    // Left hand = modifier (drag, and a wiggle zooms).
    /// The left hand must be seen this long before it counts (a one-frame ghost doesn't)…
    public var modifierAppearTime = 0.1
    /// …and missing this long before it counts as gone (Vision drops hands for a frame).
    public var modifierGoneTime = 0.25
    /// With the left hand up, the right hand moving this far (hand sizes) presses and drags.
    /// Smaller moves wait, so a wiggle can still become a zoom without pressing anything.
    public var dragCommitDistance = 0.6
    /// A smaller move (at least this far) commits when the hand then holds still, or when the
    /// left hand drops.
    public var dragSmallDistance = 0.15
    public var dragSettleTime = 0.3
    /// Zoom mode: moving the palm this far (fraction of the screen width) doubles the zoom.
    public var zoomDoublingBox = 0.25

    public init() {}
}

/// Counts direction changes of the fingertip along each axis. Enough changes on one axis within
/// the window is a wiggle: a click while the cursor is locked, a scroll while it moves.
public struct ShakeDetector {
    public var params: ShakeParams

    private struct AxisTracker {
        /// +1 / -1 once a stroke is under way.
        var direction = 0
        /// Furthest point of the current stroke.
        var extreme = 0.0
        var extremeTime = 0.0
        /// When each counted direction change happened, and when its stroke began.
        var changes: [(time: Double, strokeStart: Double)] = []
        var strokeStart = 0.0
        var origin: Double?

        mutating func update(_ value: Double, at time: Double, threshold: Double) -> Bool {
            guard let start = origin else {
                origin = value
                extreme = value
                extremeTime = time
                strokeStart = time
                return false
            }
            if direction == 0 {
                // First stroke: wait for a clear move away from where the hand rested.
                if abs(value - start) >= threshold {
                    direction = value > start ? 1 : -1
                    extreme = value
                    extremeTime = time
                } else if abs(value - start) < threshold * 0.25 {
                    // Still near the resting point: the stroke hasn't really begun yet.
                    strokeStart = time
                }
                return false
            }
            if (value - extreme) * Double(direction) > 0 {
                extreme = value
                extremeTime = time
                return false
            }
            guard abs(value - extreme) >= threshold else { return false }
            // Turned back far enough: a direction change at the extreme.
            changes.append((extremeTime, strokeStart))
            strokeStart = extremeTime
            direction = -direction
            extreme = value
            extremeTime = time
            return true
        }

        mutating func reset() { self = AxisTracker() }
    }

    private var x = AxisTracker()
    private var y = AxisTracker()

    public init(params: ShakeParams) {
        self.params = params
    }

    public mutating func reset() {
        x.reset()
        y.reset()
    }

    public struct Detection: Equatable {
        public var vertical: Bool
        /// When the wiggle's first stroke began: where the cursor "was".
        public var startTime: Double
    }

    /// Feed the tracked point (hand space; the app uses the index fingertip). Returns a
    /// detection once a wiggle of `reversals` direction changes (default: `params.reversals`)
    /// is complete.
    public mutating func update(point centroid: Point2, handSize: Double, at time: Double,
                                reversals: Int? = nil) -> Detection? {
        let threshold = params.minStroke * max(handSize, 1e-4)
        let needed = max(reversals ?? params.reversals, 1)
        for vertical in [true, false] {
            let value = vertical ? centroid.y : centroid.x
            var tracker = vertical ? y : x
            if tracker.update(value, at: time, threshold: threshold) {
                tracker.changes.removeAll { time - $0.time > params.window }
                if tracker.changes.count >= needed {
                    let start = tracker.changes[tracker.changes.count - needed].strokeStart
                    reset()
                    return Detection(vertical: vertical, startTime: start)
                }
            }
            if vertical { y = tracker } else { x = tracker }
        }
        return nil
    }
}
