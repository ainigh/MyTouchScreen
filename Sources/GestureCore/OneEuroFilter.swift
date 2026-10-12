import Foundation

/// Parameters of the 1€ filter (Casiez, Roussel & Vogel, CHI 2012).
///
/// - `minCutoff` (Hz): cutoff when the signal is still. Lower = steadier, laggier at rest.
/// - `beta`: how fast the cutoff rises with speed. Higher = snappier, noisier when moving.
/// - `derivativeCutoff` (Hz): smoothing of the speed estimate itself.
///
/// Units of `beta` are 1/(signal unit per second). GestureCore filters the pointer in
/// *active-box units* (0...1 across the calibrated box), so the defaults are expressed there.
public struct OneEuroParameters: Equatable, Codable {
    public var minCutoff: Double
    public var beta: Double
    public var derivativeCutoff: Double

    public init(minCutoff: Double, beta: Double, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }
}

/// Exponential smoothing factor for a first-order low-pass at `cutoff` Hz sampled every `dt` s.
@inline(__always)
func smoothingFactor(cutoff: Double, dt: Double) -> Double {
    let tau = 1.0 / (2.0 * Double.pi * max(cutoff, 1e-6))
    return 1.0 / (1.0 + tau / max(dt, 1e-6))
}

/// 1€ filter for a scalar signal.
public struct OneEuroFilter {
    public var parameters: OneEuroParameters
    private var lastValue: Double?
    private var lastDerivative: Double = 0
    private var lastTime: Double = 0

    public init(_ parameters: OneEuroParameters) {
        self.parameters = parameters
    }

    public mutating func reset() {
        lastValue = nil
        lastDerivative = 0
    }

    public mutating func filter(_ value: Double, at time: Double) -> Double {
        guard let previous = lastValue else {
            lastValue = value
            lastTime = time
            return value
        }
        // A non-increasing timestamp (duplicate frame) must not divide by zero; treat it as
        // one nominal 60 Hz step rather than exploding the derivative.
        let dt = time > lastTime ? time - lastTime : 1.0 / 60.0
        lastTime = time

        let rawDerivative = (value - previous) / dt
        let alphaD = smoothingFactor(cutoff: parameters.derivativeCutoff, dt: dt)
        lastDerivative += alphaD * (rawDerivative - lastDerivative)

        let cutoff = parameters.minCutoff + parameters.beta * abs(lastDerivative)
        let alpha = smoothingFactor(cutoff: cutoff, dt: dt)
        let result = previous + alpha * (value - previous)
        lastValue = result
        return result
    }
}

/// 1€ filter for a 2-D point.
///
/// Unlike two independent scalar filters, the cutoff is driven by the *speed* (magnitude of the
/// 2-D velocity), so a diagonal movement is exactly as snappy as a horizontal one and both axes
/// stay in phase — a cursor that lags more in y than in x feels like it is curving.
public struct OneEuroFilter2D {
    public var parameters: OneEuroParameters
    private var lastValue: Point2?
    private var lastVelocity = Point2.zero
    private var lastTime: Double = 0

    public init(_ parameters: OneEuroParameters) {
        self.parameters = parameters
    }

    public mutating func reset() {
        lastValue = nil
        lastVelocity = .zero
    }

    /// Re-seed the filter at a position without smoothing in from the old one (used when the
    /// pointer jumps to another display or after the hand reappears).
    public mutating func reset(to value: Point2, at time: Double) {
        lastValue = value
        lastVelocity = .zero
        lastTime = time
    }

    /// Smoothed speed in signal units per second (useful for precision mode).
    public var speed: Double { lastVelocity.length }

    public mutating func filter(_ value: Point2, at time: Double) -> Point2 {
        guard let previous = lastValue else {
            lastValue = value
            lastTime = time
            return value
        }
        let dt = time > lastTime ? time - lastTime : 1.0 / 60.0
        lastTime = time

        let rawVelocity = (value - previous) / dt
        let alphaD = smoothingFactor(cutoff: parameters.derivativeCutoff, dt: dt)
        lastVelocity = lastVelocity.lerp(to: rawVelocity, alphaD)

        let cutoff = parameters.minCutoff + parameters.beta * lastVelocity.length
        let alpha = smoothingFactor(cutoff: cutoff, dt: dt)
        let result = previous.lerp(to: value, alpha)
        lastValue = result
        return result
    }
}
