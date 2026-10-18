import Foundation

/// The shape of the cursor's path, whatever the hand does. Applies to everything that moves
/// the cursor: pointing at any cursor speed, target assist and drags.
public enum Trajectory: String, Codable, CaseIterable, Equatable {
    /// Horizontal or vertical only, like an Etch A Sketch: the cursor follows the dominant
    /// direction of the hand and switches only on a sharp turn.
    case straight
    /// Any direction: the cursor follows the hand's path as is.
    case free

    public var title: String {
        switch self {
        case .straight: return "Straight lines (horizontal or vertical)"
        case .free: return "Free (any direction)"
        }
    }

    public var summary: String {
        switch self {
        case .straight: return "The cursor moves only horizontally or only vertically, whichever way your hand mostly goes. A wavy sideways move draws a straight horizontal line; turn sharply to switch."
        case .free: return "The cursor follows your hand in any direction."
        }
    }
}

/// Locks the cursor's motion to one axis at a time (`Trajectory.straight`).
///
/// - A movement from rest picks the axis the hand mostly moves along.
/// - While locked, only that axis of the hand's motion moves the cursor: wobble across it is
///   dropped, so a wavy horizontal sweep is a straight horizontal line.
/// - The axis switches only on a sharp turn: over the last `windowTime`, the hand went at least
///   `switchTravel` points across the axis, at an angle steeper than the turn angle (55° at the
///   default `turnSharpness`). A 45° diagonal therefore stays on the axis it started on.
/// - The motion dropped across the axis leaves the cursor off the finger. Moving along an axis
///   makes that axis's difference up gradually (0.8 of the hand's travel), never by itself, so the
///   cursor is still for a still hand and comes back under the finger over normal use.
///
/// Works in screen points on the smoothed pointer; timing comes from frame timestamps.
public struct TrajectoryLock {
    public enum Axis: Equatable { case horizontal, vertical }

    public private(set) var axis: Axis?
    private var cursor: Point2?
    private var lastFinger: Point2?
    /// The hand's recent motion, to read its direction over a few frames rather than one.
    private var recent: [(time: Double, delta: Point2)] = []
    /// When the hand last moved noticeably: after a rest the next movement picks its axis afresh.
    private var lastMotion: Double = -.infinity

    /// Recent motion is summed over this long.
    static let windowTime = 0.15
    /// Recent motion this long counts as movement (below it: still or jitter).
    static let moveTravel = 4.0
    /// A turn needs at least this much travel across the axis…
    static let switchTravel = 12.0
    /// …at an angle from `gentlestTurn` (turnSharpness 0) to `sharpestTurn` (1), degrees.
    static let gentlestTurn = 35.0
    static let sharpestTurn = 75.0
    /// Still this long, and the next movement picks its own axis.
    static let restTime = 0.25
    /// Fraction of the hand's travel along the axis that makes up for earlier dropped motion.
    static let catchUp = 0.8

    public init() {}

    public mutating func reset() {
        axis = nil
        cursor = nil
        lastFinger = nil
        recent.removeAll()
        lastMotion = -.infinity
    }

    /// Start over with the cursor at `point` wherever the finger is (after a click or a drop
    /// held the cursor): it carries on from there instead of jumping to the finger.
    public mutating func reset(holding point: Point2) {
        reset()
        cursor = point
    }

    /// Where the cursor goes, given where the (smoothed) finger points this frame.
    public mutating func process(finger: Point2, at time: Double, bounds: Rect,
                                 trajectory: Trajectory, turnSharpness: Double) -> Point2 {
        guard trajectory == .straight else {
            reset()
            return finger
        }
        guard let previousFinger = lastFinger, var next = cursor else {
            lastFinger = finger
            if cursor == nil { cursor = finger }
            return cursor ?? finger
        }
        let moved = finger - previousFinger
        lastFinger = finger
        recent.append((time, moved))
        recent.removeAll { time - $0.time > Self.windowTime }
        let window = recent.reduce(Point2.zero) { $0 + $1.delta }

        if window.length >= Self.moveTravel {
            if time - lastMotion > Self.restTime {
                // Setting off from rest: go the way the hand mostly goes.
                axis = abs(window.x) >= abs(window.y) ? .horizontal : .vertical
            }
            lastMotion = time
        }
        if let current = axis {
            let along = current == .horizontal ? window.x : window.y
            let across = current == .horizontal ? window.y : window.x
            let sharpness = turnSharpness.isFinite ? clamp01(turnSharpness) : 0.5
            let angle = (Self.gentlestTurn + (Self.sharpestTurn - Self.gentlestTurn) * sharpness) * .pi / 180
            if abs(across) >= Self.switchTravel && abs(across) > abs(along) * tan(angle) {
                axis = current == .horizontal ? .vertical : .horizontal
            }
        }

        switch axis {
        case .horizontal:
            next.x = Self.follow(next.x, finger: finger.x, moved: moved.x)
        case .vertical:
            next.y = Self.follow(next.y, finger: finger.y, moved: moved.y)
        case nil:
            break // Not moving yet: hold.
        }
        next = Point2(clamp(next.x, bounds.minX, bounds.maxX - 1), clamp(next.y, bounds.minY, bounds.maxY - 1))
        cursor = next
        return next
    }

    /// One axis: move with the hand, plus a share of the hand's travel toward where the finger
    /// points (making up motion dropped while the other axis was active).
    private static func follow(_ value: Double, finger: Double, moved: Double) -> Double {
        let next = value + moved
        let gap = finger - next
        let step = min(abs(gap), abs(moved) * catchUp)
        return next + (gap < 0 ? -step : step)
    }
}
