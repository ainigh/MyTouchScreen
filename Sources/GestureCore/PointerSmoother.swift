import Foundation

/// Turns a noisy box-space pointer sample into a cursor position that is rock steady at rest
/// and snappy in motion, without ever changing *where* it points: the output always converges
/// on the input (no gain, no accumulated offset), so the cursor behaves like a laser pointer.
/// Two stages, in order:
///
/// 1. **1€ filter** — adaptive low-pass: heavy smoothing when slow, light when fast.
/// 2. **Rest lock** — the output is a "puck" dragged by the filtered point on a leash; it does
///    not move at all until the leash is taut. While moving the leash is a point or two long.
///    Once the filtered point has stayed within `restDeadZoneBox` of its average for
///    `restLockDelay`, the cursor locks on that average (where the still hand points) and the
///    leash grows to the rest radius, so tracker jitter never reaches the screen. Leaving the
///    lock needs a clear move (twice the radius) or one that lasts `escapeConfirmTime`; the
///    leash then shortens over ~100 ms, so the cursor catches up exactly with the hand.
public struct PointerSmoother {
    public var config: GestureConfig
    private var filter: OneEuroFilter2D
    private var puck: Point2?
    private var leash: Double
    /// Since when the filtered point has stayed within the rest radius of `restAverage`: once
    /// that lasts `restLockDelay`, the cursor locks.
    private var stillSince: Double?
    /// The filtered point averaged over the last ~0.5 s while still: where a still hand points.
    /// The locked cursor settles there.
    private var restAverage: Point2?
    /// Since when the filtered point has been just outside the rest lock (less than twice its
    /// radius). Staying out for `escapeConfirmTime` confirms it's the hand moving rather than the
    /// filtered jitter of a still hand wandering out for a frame or two.
    private var escapeSince: Double?
    static let escapeConfirmTime = 0.06
    /// Time constant of `restAverage`.
    static let restAverageTime = 0.5
    /// A locked cursor steps onto the rest average once it is this fraction of the rest radius
    /// away (a hand creeping slowly); smaller differences are left alone.
    static let resettleFraction = 0.5
    private var lastTime: Double?

    public init(config: GestureConfig) {
        self.config = config
        self.filter = OneEuroFilter2D(config.filter)
        self.leash = config.deadZoneBox
    }

    public mutating func updateConfig(_ config: GestureConfig) {
        self.config = config
        filter.parameters = config.filter
    }

    /// Smoothed speed of the hand in box units per second.
    public var speed: Double { filter.speed }

    public mutating func reset(to point: Point2? = nil, at time: Double = 0) {
        leash = config.deadZoneBox
        restAverage = nil
        stillSince = nil
        escapeSince = nil
        lastTime = nil
        if let point {
            filter.reset(to: point, at: time)
            puck = point
        } else {
            filter.reset()
            puck = nil
        }
    }

    public mutating func process(_ raw: Point2, at time: Double) -> Point2 {
        let target = filter.filter(raw, at: time)
        let dt = lastTime.map { max(time - $0, 0) } ?? 0
        lastTime = time
        guard let current = puck else {
            puck = target
            startStillness(at: target, time: time)
            return target
        }
        // Stillness is judged against the rest radius, not the (tiny) moving leash: a still hand's
        // filtered point keeps wandering a few points, and must still count as still.
        if let average = restAverage, target.distance(to: average) <= config.restDeadZoneBox {
            let settled = average.lerp(to: target, 1 - exp(-dt / Self.restAverageTime))
            restAverage = settled
            if time - (stillSince ?? time) >= config.restLockDelay {
                // Locked: hold the cursor on where the still hand points. The moving leash (or
                // the hand creeping) can leave it a few points short; it steps onto the average
                // once that is clearly elsewhere, and otherwise never twitches.
                leash = max(leash, config.restDeadZoneBox)
                escapeSince = nil
                if settled.distance(to: current) > config.restDeadZoneBox * Self.resettleFraction {
                    puck = settled
                }
                return puck ?? target
            }
        } else {
            startStillness(at: target, time: time)
        }

        let pull = target - current
        let distance = pull.length
        let locked = leash > config.deadZoneBox * 1.5
        if distance > leash && locked && distance < leash * 2 {
            // Just outside the rest lock: wait for confirmation. A real movement stays outside
            // (and a big one is far out at once, which unlocks straight away).
            if escapeSince == nil { escapeSince = time }
            if time - (escapeSince ?? time) < Self.escapeConfirmTime { return current }
        }
        escapeSince = nil
        if distance > leash {
            // Moving: follow, and shorten the leash toward the moving length over ~100 ms so
            // breaking out of the rest lock never produces a jump, and the cursor ends up where
            // the hand points.
            puck = current + pull * ((distance - leash) / distance)
            let shrink = 1 - exp(-dt / 0.1)
            leash += (config.deadZoneBox - leash) * shrink
        }
        return puck ?? target
    }

    private mutating func startStillness(at point: Point2, time: Double) {
        stillSince = time
        restAverage = point
    }
}
