import Foundation

/// Turns a noisy box-space pointer sample into a cursor position that is rock steady at rest
/// and snappy in motion. Three stages, in order:
///
/// 1. **1€ filter** — adaptive low-pass: heavy smoothing when slow, light when fast.
/// 2. **Precision gain** — below a speed threshold the cursor moves at a fraction of the hand's
///    speed for fine targeting. The difference accumulates as an offset that drains away during
///    fast motion, so the hand-to-screen mapping is always restored.
/// 3. **Dead zone** — the output is a "puck" dragged by the filtered point on a leash; it does
///    not move at all until the leash is taut, so residual jitter never reaches the screen. The
///    leash is longer once the cursor has rested for a moment (a still hand is locked in place)
///    and shortens smoothly as soon as the hand moves (so motion stays responsive).
public struct PointerSmoother {
    public var config: GestureConfig
    private var filter: OneEuroFilter2D
    private var precisionOffset = Point2.zero
    private var lastFiltered: Point2?
    private var puck: Point2?
    private var leash: Double
    private var stillSince: Double?
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
        precisionOffset = .zero
        leash = config.deadZoneBox
        stillSince = nil
        lastTime = nil
        if let point {
            filter.reset(to: point, at: time)
            lastFiltered = point
            puck = point
        } else {
            filter.reset()
            lastFiltered = nil
            puck = nil
        }
    }

    public mutating func process(_ raw: Point2, at time: Double) -> Point2 {
        let filtered = filter.filter(raw, at: time)
        defer { lastFiltered = filtered }

        if config.precisionEnabled, let previous = lastFiltered {
            let delta = filtered - previous
            let speed = filter.speed
            if speed < config.precisionSpeedBox {
                // Slow: give back part of the motion, scaled smoothly so there is no seam at
                // the threshold (gain ramps from precisionGain at rest to 1 at the threshold).
                let t = speed / config.precisionSpeedBox
                let gain = config.precisionGain + (1 - config.precisionGain) * t * t
                precisionOffset -= delta * (1 - gain)
                let limit = config.precisionMaxOffsetBox
                let length = precisionOffset.length
                if length > limit { precisionOffset = precisionOffset * (limit / length) }
            } else {
                // Fast: drain the offset proportionally to how far the hand travelled, so the
                // correction is hidden inside a large, fast movement.
                let drain = min(delta.length / max(config.precisionMaxOffsetBox, 1e-6), 1)
                precisionOffset = precisionOffset * (1 - drain)
            }
        }

        let target = filtered + precisionOffset
        let dt = lastTime.map { max(time - $0, 0) } ?? 0
        lastTime = time
        guard let current = puck else {
            puck = target
            stillSince = time
            return target
        }
        let pull = target - current
        let distance = pull.length
        if distance > leash {
            // Moving: follow, and shorten the leash toward the moving length over ~100 ms so
            // breaking out of the rest lock never produces a jump.
            puck = current + pull * ((distance - leash) / distance)
            let shrink = 1 - exp(-dt / 0.1)
            leash += (config.deadZoneBox - leash) * shrink
            stillSince = nil
        } else {
            if stillSince == nil { stillSince = time }
            if time - (stillSince ?? time) >= config.restLockDelay {
                // Lengthening the leash while the puck is inside it has no visible effect.
                leash = max(leash, config.restDeadZoneBox)
            }
        }
        return puck ?? target
    }
}
