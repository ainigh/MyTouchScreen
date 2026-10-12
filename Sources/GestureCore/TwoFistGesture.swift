import Foundation

/// Both hands held as fists. While they move nothing happens; when they come to rest, the last
/// stroke decides: the spread between the fists grew → zoom in, shrank → zoom out; both fists
/// moved the same way → scroll that way. Only the last stroke counts, so closing the fists
/// together and widening them again before resting zooms in again (a ratchet), like lifting a
/// mouse to keep moving the same way.
public struct TwoFistGesture {
    public enum Result: Equatable {
        /// Multiply the zoom by `factor` (> 1 = in).
        case zoom(factor: Double)
        /// The fists' midpoint moved this far in box space (y grows downward).
        case scroll(dx: Double, dy: Double)
    }

    /// One value's current stroke: where it started (the last turning point) and how far it got.
    struct Stroke {
        var start: Double
        var extreme: Double
        var direction = 0

        init(_ value: Double) {
            start = value
            extreme = value
        }

        mutating func update(_ value: Double, threshold: Double) {
            if direction == 0 {
                if abs(value - start) >= threshold {
                    direction = value > start ? 1 : -1
                    extreme = value
                }
                return
            }
            if (value - extreme) * Double(direction) > 0 {
                extreme = value
            } else if abs(value - extreme) >= threshold {
                // Turned back far enough: the previous stroke was a return, a new one starts.
                start = extreme
                direction = -direction
                extreme = value
            }
        }

        func delta(to value: Double) -> Double { value - start }
    }

    public var params: ShakeParams
    private var x: Stroke
    private var y: Stroke
    private var spread: Stroke
    /// Recent samples, for a speed measured over `speedSpan` rather than frame to frame: two
    /// hands' landmark jitter adds up, and a per-frame speed never looks still.
    private var recent: [(time: Double, mid: Point2, spread: Double)] = []
    static let speedSpan = 0.15
    private var restSince: Double?
    /// True once the hands have moved since the last rest, so one rest fires once.
    private var moved = false

    /// `mid`: the fists' midpoint in box space. `spread`: the distance between them in hand
    /// sizes. `boxPerHand`: how much box space one hand size covers there (for thresholds).
    public init(params: ShakeParams, mid: Point2, spread: Double, at time: Double) {
        self.params = params
        x = Stroke(mid.x)
        y = Stroke(mid.y)
        self.spread = Stroke(spread)
        recent = [(time, mid, spread)]
    }

    public mutating func update(mid: Point2, spread value: Double, boxPerHand: Double, at time: Double) -> Result? {
        let perHand = max(boxPerHand, 1e-6)
        recent.append((time, mid, value))
        while recent.count > 2 && time - recent[1].time >= Self.speedSpan { recent.removeFirst() }
        var speed = 0.0
        if let oldest = recent.first, time - oldest.time > 1e-6 {
            let travelled = max(mid.distance(to: oldest.mid) / perHand, abs(value - oldest.spread))
            speed = travelled / (time - oldest.time)
        }
        x.update(mid.x, threshold: params.twoHandStroke * perHand)
        y.update(mid.y, threshold: params.twoHandStroke * perHand)
        spread.update(value, threshold: params.twoHandStroke)

        guard speed < params.twoHandRestSpeed else {
            restSince = nil
            moved = true
            return nil
        }
        if restSince == nil { restSince = time }
        guard moved, time - (restSince ?? time) >= params.twoHandRestTime else { return nil }
        moved = false
        defer { restart(mid: mid, spread: value) }

        let dx = x.delta(to: mid.x)
        let dy = y.delta(to: mid.y)
        let zoomAmount = abs(spread.delta(to: value))
        let scrollAmount = max(abs(dx), abs(dy)) / perHand
        guard max(zoomAmount, scrollAmount) >= params.twoHandStroke else { return nil }
        if zoomAmount >= scrollAmount {
            let ratio = max(value, 1e-3) / max(spread.start, 1e-3)
            return .zoom(factor: pow(ratio, params.zoomGain))
        }
        // One axis: the one the fists mostly moved along.
        return abs(dy) >= abs(dx) ? .scroll(dx: 0, dy: dy) : .scroll(dx: dx, dy: 0)
    }

    /// The next gesture is measured from here.
    private mutating func restart(mid: Point2, spread value: Double) {
        x = Stroke(mid.x)
        y = Stroke(mid.y)
        spread = Stroke(value)
    }
}
