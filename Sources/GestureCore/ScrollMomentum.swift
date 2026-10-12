import Foundation

/// Inertial scrolling after a fist-scroll ends, with exponential friction — the same model the
/// trackpad uses, so it feels familiar. Driven by `tick(at:)`, which the app calls from its
/// display timer, so the glide is smooth even though the camera only delivers 30–60 fps.
public struct ScrollMomentum {
    public private(set) var velocity = Point2.zero   // points per second, content movement
    public private(set) var isActive = false
    private var lastTime: Double = 0
    private var friction: Double
    private var minSpeed: Double

    public init(friction: Double, minSpeed: Double) {
        self.friction = friction
        self.minSpeed = minSpeed
    }

    /// Begin gliding at `velocity`. Returns the momentum-began intent.
    public mutating func start(velocity: Point2, at time: Double) -> Intent {
        self.velocity = velocity
        lastTime = time
        isActive = true
        return .scroll(dx: 0, dy: 0, phase: .momentumBegan)
    }

    /// Advance the glide. Returns nothing when inactive, a momentum-changed delta while gliding,
    /// and momentum-ended once it has slowed below the threshold.
    public mutating func tick(at time: Double) -> [Intent] {
        guard isActive else { return [] }
        let dt = time - lastTime
        guard dt > 0 else { return [] }
        lastTime = time
        // Exact integral of v(t) = v0 * e^(-k t) over the step, so the distance is independent
        // of tick rate.
        let decay = exp(-friction * dt)
        let distanceFactor = (1 - decay) / friction
        let delta = velocity * distanceFactor
        velocity = velocity * decay
        if velocity.length < minSpeed {
            return stop()
        }
        return [.scroll(dx: delta.x, dy: delta.y, phase: .momentumChanged)]
    }

    /// Stop immediately (a new gesture started). Returns momentum-ended if it was active.
    public mutating func stop() -> [Intent] {
        guard isActive else { return [] }
        isActive = false
        velocity = .zero
        return [.scroll(dx: 0, dy: 0, phase: .momentumEnded)]
    }
}
