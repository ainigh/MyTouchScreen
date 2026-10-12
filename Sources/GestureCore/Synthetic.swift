import Foundation

/// Deterministic pseudo-random numbers (SplitMix64), so synthetic noise is identical on every
/// platform and every run. `SystemRandomNumberGenerator` would make tests flaky.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Standard normal (Box–Muller).
    public mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// A parametric hand: enough anatomy to exercise every classifier in GestureCore with
/// realistic proportions (a right hand, palm toward the camera, fingers up).
public struct SyntheticHand {
    /// Wrist position in normalized image coordinates.
    public var wrist: Point2
    /// Wrist → middle MCP length in fractions of the image width (~0.1 at arm's length).
    public var size: Double = 0.1
    /// 0 = straight, 1 = fully curled; index, middle, ring, little.
    public var curl: [Double] = [0, 0.6, 0.6, 0.6]
    /// 0 = thumb resting beside the index, 1 = spread wide.
    public var thumbSpread: Double = 0
    /// Which fingertip the thumb is pinching toward, and how far (1 = touching).
    public var pinchFinger: PinchFinger = .index
    public var pinchAmount: Double = 0
    public var chirality: Chirality = .right
    public var imageAspect: Double = 16.0 / 9.0
    public var confidence: Double = 0.95

    public init(wrist: Point2) {
        self.wrist = wrist
    }

    // Hand-local template in hand-size units, wrist at origin, +x toward the thumb, -y up.
    static let extended: [Point2] = [
        Point2(0, 0),
        Point2(0.25, -0.2), Point2(0.48, -0.42), Point2(0.62, -0.62), Point2(0.72, -0.82),
        Point2(0.3, -0.95), Point2(0.33, -1.33), Point2(0.35, -1.57), Point2(0.37, -1.78),
        Point2(0, -1), Point2(0, -1.42), Point2(0, -1.68), Point2(0, -1.9),
        Point2(-0.25, -0.95), Point2(-0.28, -1.33), Point2(-0.3, -1.56), Point2(-0.32, -1.74),
        Point2(-0.48, -0.85), Point2(-0.53, -1.13), Point2(-0.56, -1.31), Point2(-0.58, -1.46),
    ]
    static let curled: [[Point2]] = [
        [Point2(0.32, -1.2), Point2(0.3, -1.0), Point2(0.27, -0.8)],
        [Point2(0, -1.25), Point2(0, -1.03), Point2(0, -0.82)],
        [Point2(-0.27, -1.18), Point2(-0.27, -0.98), Point2(-0.25, -0.8)],
        [Point2(-0.52, -1.05), Point2(-0.5, -0.9), Point2(-0.46, -0.75)],
    ]
    static let thumbSpreadTip = Point2(0.97, -0.6)
    static let thumbSpreadIP = Point2(0.78, -0.5)
    static let thumbTuckedTip = Point2(0.33, -0.7)
    static func pinchMeeting(_ finger: PinchFinger) -> Point2 {
        switch finger {
        case .index: return Point2(0.55, -1.2)
        case .middle: return Point2(0.33, -1.25)
        case .ring: return Point2(0.18, -1.15)
        }
    }

    /// Local landmark positions before placement.
    func localPoints() -> [Point2] {
        var p = Self.extended
        // Fingers: blend each of PIP, DIP, TIP toward the curled pose.
        for finger in 0..<4 {
            let base = 5 + finger * 4
            let c = clamp01(curl[finger])
            for j in 0..<3 {
                p[base + 1 + j] = p[base + 1 + j].lerp(to: Self.curled[finger][j], c)
            }
        }
        // Thumb: spread outward for an open palm, tuck in across the palm for a fist.
        let s = clamp01(thumbSpread)
        p[Joint.thumbTip.rawValue] = p[Joint.thumbTip.rawValue].lerp(to: Self.thumbSpreadTip, s)
        p[Joint.thumbIP.rawValue] = p[Joint.thumbIP.rawValue].lerp(to: Self.thumbSpreadIP, s)
        let meanCurl = curl.reduce(0, +) / 4
        if meanCurl > 0.8 {
            let tuck = (meanCurl - 0.8) / 0.2
            p[Joint.thumbTip.rawValue] = p[Joint.thumbTip.rawValue].lerp(to: Self.thumbTuckedTip, tuck)
        }
        // Pinch: thumb tip and fingertip converge on a meeting point, stopping a fingertip's
        // thickness apart (~0.14 hand sizes), as real landmarks do.
        let a = clamp01(pinchAmount)
        if a > 0 {
            let meet = Self.pinchMeeting(pinchFinger)
            let tip = pinchFinger.tip.rawValue
            let dip = tip - 1
            p[tip] = p[tip].lerp(to: meet + Point2(-0.04, -0.06), a)
            p[dip] = p[dip].lerp(to: meet + Point2(-0.1, -0.2), a * 0.7)
            p[Joint.thumbTip.rawValue] = p[Joint.thumbTip.rawValue].lerp(to: meet + Point2(0.04, 0.06), a)
        }
        return p
    }

    /// Place the hand in the image and add optional per-joint noise (normalized image units,
    /// measured along x).
    public func frame(at time: Double, noise: Double = 0, rng: inout SeededRandom) -> HandFrame {
        let mirror: Double = chirality == .left ? -1 : 1
        let points = localPoints().map { local -> Point2 in
            let x = wrist.x + local.x * size * mirror + (noise > 0 ? rng.gaussian() * noise : 0)
            let y = wrist.y + (local.y * size + (noise > 0 ? rng.gaussian() * noise : 0)) * imageAspect
            return Point2(x, y)
        }
        return HandFrame(points: points, chirality: chirality, confidence: confidence,
                         timestamp: time, imageAspect: imageAspect)
    }

    public func frame(at time: Double) -> HandFrame {
        var rng = SeededRandom(seed: 0)
        return frame(at: time, noise: 0, rng: &rng)
    }

    /// Wrist position that puts this hand's (unpinched) index fingertip at `tip`.
    public func wristPlacing(indexTipAt tip: Point2) -> Point2 {
        let local = localPoints()[Joint.indexTip.rawValue]
        let mirror: Double = chirality == .left ? -1 : 1
        return Point2(tip.x - local.x * size * mirror, tip.y - local.y * size * imageAspect)
    }

    // Common poses.
    public static func pointing(tipAt tip: Point2) -> SyntheticHand {
        var h = SyntheticHand(wrist: .zero)
        h.wrist = h.wristPlacing(indexTipAt: tip)
        return h
    }

    public mutating func makeFist() {
        curl = [1, 1, 1, 1]
        thumbSpread = 0
        pinchAmount = 0
    }

    public mutating func makeOpenPalm() {
        curl = [0, 0, 0, 0]
        thumbSpread = 1
        pinchAmount = 0
    }
}

/// Builds frame streams for tests and demos. Every scenario is deterministic.
public enum SyntheticStream {
    /// Sample `handsAt` at `fps` for `duration` seconds starting at `start`.
    public static func generate(duration: Double, fps: Double = 30, start: Double = 0,
                                noise: Double = 0, seed: UInt64 = 1,
                                handsAt: (Double) -> [SyntheticHand]) -> [TrackingFrame] {
        var rng = SeededRandom(seed: seed)
        let count = Int((duration * fps).rounded())
        return (0..<count).map { i in
            let t = start + Double(i) / fps
            let hands = handsAt(t).map { $0.frame(at: t, noise: noise, rng: &rng) }
            return TrackingFrame(timestamp: t, hands: hands)
        }
    }

    /// Pinch amount for a tap that starts at `start`, closes over `ramp`, holds until
    /// `start + duration` and opens over `ramp`.
    public static func tapAmount(at t: Double, start: Double, duration: Double, ramp: Double = 0.05) -> Double {
        if t < start || t > start + duration + ramp { return 0 }
        if t < start + ramp { return (t - start) / ramp }
        if t <= start + duration { return 1 }
        return 1 - (t - start - duration) / ramp
    }

    /// A still pointing hand at `tip` (optionally with tracker jitter).
    public static func steady(tip: Point2 = Point2(0.5, 0.45), duration: Double = 2,
                              fps: Double = 30, noise: Double = 0, seed: UInt64 = 7) -> [TrackingFrame] {
        generate(duration: duration, fps: fps, noise: noise, seed: seed) { _ in [.pointing(tipAt: tip)] }
    }

    /// The fingertip sweeps linearly from `from` to `to` over `duration`.
    public static func ramp(from: Point2, to: Point2, duration: Double, fps: Double = 30,
                            lead: Double = 0.5) -> [TrackingFrame] {
        generate(duration: lead + duration + 0.5, fps: fps) { t in
            let u = clamp01((t - lead) / duration)
            return [.pointing(tipAt: from.lerp(to: to, u))]
        }
    }

    /// Both hands held up as still open palms for `hold` seconds starting at `start` (the
    /// engage toggle), then the right hand points again and the left goes down. With
    /// `bothHands: false` only the right hand opens (which must not toggle).
    public static func palmHold(start: Double = 0.3, hold: Double = 1.0, fps: Double = 30,
                                tail: Double = 0.6, bothHands: Bool = true) -> [TrackingFrame] {
        generate(duration: start + hold + tail, fps: fps) { t in
            var hand = SyntheticHand.pointing(tipAt: Point2(0.5, 0.45))
            guard t >= start && t < start + hold else { return [hand] }
            hand.makeOpenPalm()
            guard bothHands else { return [hand] }
            var left = SyntheticHand.pointing(tipAt: Point2(0.78, 0.45))
            left.chirality = .left
            left.makeOpenPalm()
            left.wrist = left.wristPlacing(indexTipAt: Point2(0.78, 0.45))
            return [hand, left]
        }
    }

    /// Hand visible until `visibleUntil`, then gone for the rest of `duration`.
    public static func handLost(visibleUntil: Double = 0.5, duration: Double = 3.0, fps: Double = 30) -> [TrackingFrame] {
        generate(duration: duration, fps: fps) { t in
            t < visibleUntil ? [.pointing(tipAt: Point2(0.5, 0.45))] : []
        }
    }

    /// Rest the pointing hand (the cursor locks after 1 s), then wiggle left-right-left at
    /// `wiggleAt`: a click.
    public static func wiggleClick(wiggleAt: Double = 2.0, fps: Double = 30) -> [TrackingFrame] {
        generate(duration: wiggleAt + 2, fps: fps) { t in
            let u = (t - wiggleAt) / 0.18
            let along = u <= 0 || u >= 3 ? (u >= 3 ? 1.0 : 0.0) : (Int(u) % 2 == 0 ? u - Double(Int(u)) : 1 - (u - Double(Int(u))))
            return [.pointing(tipAt: Point2(0.5 - 0.06 * along, 0.45))]
        }
    }

    /// Rest, make a fist at `fistAt`, move it by `offset` (image units) a moment later, rest,
    /// then open it: a drag and drop.
    public static func fistDrag(fistAt: Double = 2.0, offset: Point2 = Point2(-0.1, 0.05),
                                fps: Double = 30) -> [TrackingFrame] {
        let open = fistAt + 3
        return generate(duration: open + 1.5, fps: fps) { t in
            var hand = SyntheticHand.pointing(tipAt: Point2(0.5, 0.45))
            hand.wrist += offset * clamp01((t - fistAt - 0.5) / 0.5)
            if t >= fistAt && t < open { hand.makeFist() }
            return [hand]
        }
    }

    /// Two fists from `start`, then (from `start + 0.4`, over 0.5 s) spreading apart by
    /// `spreadChange` (> 0 zooms in, < 0 out) and both moving by `shift` (image units: scroll),
    /// then resting.
    public static func twoFists(start: Double = 0.5, spreadChange: Double = 0.12, shift: Point2 = .zero,
                                fps: Double = 30) -> [TrackingFrame] {
        generate(duration: start + 2.5, fps: fps) { t in
            let u = clamp01((t - start - 0.4) / 0.5)
            let half = 0.12 + spreadChange / 2 * u
            let center = Point2(0.5, 0.45) + shift * u
            var right = SyntheticHand.pointing(tipAt: Point2(center.x - half, center.y))
            var left = SyntheticHand.pointing(tipAt: Point2(center.x + half, center.y))
            left.chirality = .left
            left.wrist = left.wristPlacing(indexTipAt: Point2(center.x + half, center.y))
            if t >= start {
                right.makeFist()
                left.makeFist()
            }
            return [right, left]
        }
    }
}
