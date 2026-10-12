import Foundation

/// Hold & wiggle tunables. Distances in hand sizes (wrist → middle MCP), times in seconds.
public struct ShakeParams: Equatable, Codable {
    /// Hold the cursor still this long to click.
    public var dwellTime = 2.0
    /// "Still" = the cursor stays within this fraction of the screen width.
    public var dwellRadiusBox = 0.008
    /// Direction changes along one axis that start scrolling…
    public var reversals = 3
    /// …all within this window.
    public var window = 1.0
    /// A movement only counts as a stroke (and its end as a direction change) once it has
    /// travelled this far, so tracker jitter and small corrections never add up to a wiggle.
    public var minStroke = 0.25
    /// Scrolling ends when the palm stays below this speed (hand sizes per second)…
    public var exitStillSpeed = 0.5
    /// …for this long.
    public var exitStillTime = 0.5

    public init() {}
}

/// Counts direction changes of the palm along each axis. Three changes on one axis within the
/// window is a wiggle: the user wants to scroll along that axis.
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

    /// Feed the palm centroid (hand space). Returns a detection once a wiggle is complete.
    public mutating func update(centroid: Point2, handSize: Double, at time: Double) -> Detection? {
        let threshold = params.minStroke * max(handSize, 1e-4)
        let needed = max(params.reversals, 1)
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
