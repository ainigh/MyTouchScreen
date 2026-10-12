import Foundation

/// Wiggle-click tunables. Distances in hand sizes (wrist → middle MCP), times in seconds.
public struct ShakeParams: Equatable, Codable {
    /// Direction changes along one axis that make the click wiggle (left-right-left)…
    public var reversals = 2
    /// …all within this window…
    public var window = 1.0
    /// …without resting at a turn for longer than this: a wiggle is one continuous back-and-forth.
    public var maxPause = 0.2
    /// A movement only counts as a stroke (and its end as a direction change) once it has
    /// travelled this far, so tracker jitter and small corrections never add up to a wiggle.
    public var minStroke = 0.25
    /// A second wiggle click within this long of the first, at the same spot, is a double click.
    public var doubleClickWindow = 1.5
    /// "The same spot" for a double click: within this fraction of the screen width (the second
    /// click then lands exactly on the first).
    public var doubleClickRadiusBox = 0.05
    /// A fist presses (starts a drag) once held this long. The owner's recording has fists
    /// flickering for 0.1–0.2 s while the hand moves; a meant fist is held longer.
    public var fistHoldTime = 0.25

    public init() {}
}

/// Counts direction changes of the fingertip along each axis. Enough changes on one axis within
/// the window is a wiggle: the click gesture.
public struct ShakeDetector {
    public var params: ShakeParams

    private struct AxisTracker {
        /// +1 / -1 once a stroke is under way.
        var direction = 0
        /// Furthest point of the current stroke.
        var extreme = 0.0
        var extremeTime = 0.0
        /// When the value first came close to where the extreme ended up (`turnValue`, within
        /// a fifth of a stroke), and the last time it was still that close: how long the hand
        /// paused at the turn. Jitter creeping the extreme along doesn't restart the pause.
        var nearExtremeSince = 0.0
        var nearExtremeUntil = 0.0
        var turnValue = 0.0
        /// When each counted direction change happened, and when its stroke began.
        var changes: [(time: Double, strokeStart: Double)] = []
        var strokeStart = 0.0
        var origin: Double?

        mutating func update(_ value: Double, at time: Double, threshold: Double, maxPause: Double,
                             minStrokeTime: Double) -> Bool {
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
                    startPause(value, at: time)
                } else if abs(value - start) < threshold * 0.25 {
                    // Still near the resting point: the stroke hasn't really begun yet.
                    strokeStart = time
                }
                return false
            }
            let band = threshold * 0.2
            if (value - extreme) * Double(direction) > 0 {
                extreme = value
                extremeTime = time
                if (value - turnValue) * Double(direction) > band { startPause(value, at: time) }
                nearExtremeUntil = time
                return false
            }
            if abs(value - extreme) < band { nearExtremeUntil = time }
            guard abs(value - extreme) >= threshold else { return false }
            // Turned back far enough: a direction change at the extreme…
            let paused = nearExtremeUntil - nearExtremeSince > maxPause
            let turnStart = extremeTime
            direction = -direction
            extreme = value
            extremeTime = time
            startPause(value, at: time)
            if turnStart - strokeStart < minStrokeTime {
                // A stroke no human makes: a tracker glitch (one frame out and back). Start over.
                self = AxisTracker()
                return false
            }
            if paused {
                // …unless the hand rested there first: then this is a fresh start, not part of a
                // back-and-forth (two pinches or taps a second apart are not a wiggle).
                changes.removeAll()
                strokeStart = turnStart
                return false
            }
            changes.append((turnStart, strokeStart))
            strokeStart = turnStart
            return true
        }

        private mutating func startPause(_ value: Double, at time: Double) {
            turnValue = value
            nearExtremeSince = time
            nearExtremeUntil = time
        }

        mutating func reset() { self = AxisTracker() }
    }

    private var x = AxisTracker()
    private var y = AxisTracker()

    /// Strokes quicker than this are tracker glitches, not hand movement.
    static let minStrokeTime = 0.07

    public init(params: ShakeParams) {
        self.params = params
    }

    public mutating func reset() {
        x.reset()
        y.reset()
    }

    public struct Detection: Equatable {
        public var vertical: Bool
        /// When the wiggle's first stroke began…
        public var startTime: Double
        /// …and when it turned back.
        public var firstTurnTime: Double
    }

    /// Feed the tracked point (hand space; the app uses the index fingertip). Returns a
    /// detection once a wiggle is complete.
    public mutating func update(point centroid: Point2, handSize: Double, at time: Double) -> Detection? {
        let threshold = params.minStroke * max(handSize, 1e-4)
        let needed = max(params.reversals, 1)
        for vertical in [true, false] {
            let value = vertical ? centroid.y : centroid.x
            var tracker = vertical ? y : x
            if tracker.update(value, at: time, threshold: threshold, maxPause: params.maxPause,
                              minStrokeTime: Self.minStrokeTime) {
                tracker.changes.removeAll { time - $0.time > params.window }
                if tracker.changes.count >= needed {
                    let first = tracker.changes[tracker.changes.count - needed]
                    reset()
                    return Detection(vertical: vertical, startTime: first.strokeStart, firstTurnTime: first.time)
                }
            }
            if vertical { y = tracker } else { x = tracker }
        }
        return nil
    }
}
