import Foundation

/// Kinds of hand motion the synthetic generator produces. They come from the retired Velocity
/// model's tuning session; the tests now use them to check that none of these ordinary
/// movements clicks, presses or scrolls in Hold & wiggle.
public enum GestureLabel: String, Codable, CaseIterable, Equatable {
    case click
    case rightClick = "right-click"
    case doubleClick = "double-click"
    case scrollUp = "scroll-up"
    case scrollDown = "scroll-down"
    case repositionFast = "reposition-fast"
    case repositionSlow = "reposition-slow"
    case fineTarget = "fine-target"
    case drag
    case rest
    case jitter
    case outOfFrame = "out-of-frame"
    case zoom
}

/// A labeled stretch of a recording: frames in `startTime...endTime` show `label`.
public struct LabeledSegment: Codable, Equatable {
    public var label: String
    public var startTime: Double
    public var endTime: Double

    public init(label: String, startTime: Double, endTime: Double) {
        self.label = label
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// Synthetic hand motions with realistic timing and noise: minimum-jerk hand
/// motion, per-joint tracker noise, slow sway, timestamp jitter, dropped frames, and (for
/// `jitter`) low-confidence garbage frames and single-frame landmark glitches. Every sample is
/// deterministic from its seed.
public enum MotionSynthetic {
    public struct Sample {
        public var label: GestureLabel
        public var frames: [TrackingFrame]
        /// Where the labeled gesture happens (lead-in and tail excluded).
        public var segment: LabeledSegment
    }

    /// Minimum-jerk position profile, 0 → 1 over u in 0...1 (bell-shaped speed, like a reach).
    static func minimumJerk(_ u: Double) -> Double {
        let x = clamp01(u)
        return x * x * x * (10 + x * (-15 + 6 * x))
    }

    /// Out to `amplitude` along `direction` over `outTime`, back over `backTime` (0 = stay).
    static func stroke(_ t: Double, direction: Point2, amplitude: Double, outTime: Double, backTime: Double) -> Point2 {
        guard t > 0 else { return .zero }
        if t <= outTime { return direction * (amplitude * minimumJerk(t / outTime)) }
        guard backTime > 0 else { return direction * amplitude }
        return direction * (amplitude * (1 - minimumJerk((t - outTime) / backTime)))
    }

    static func unit(angleDegrees: Double) -> Point2 {
        let a = angleDegrees * .pi / 180
        return Point2(cos(a), sin(a))
    }

    private static func uniform(_ rng: inout SeededRandom, _ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * rng.unit()
    }

    /// One labeled gesture with a still lead-in and a tail. `clean` turns off every source of
    /// noise (tracker noise, sway, timestamp jitter, dropped and bad frames) but keeps the
    /// seeded gesture, so the same motion can be compared at different frame rates.
    public static func sample(_ label: GestureLabel, fps: Double = 60, seed: UInt64, start: Double = 0,
                              clean: Bool = false) -> Sample {
        var rng = SeededRandom(seed: seed &* 0x9E37_79B9 &+ UInt64(GestureLabel.allCases.firstIndex(of: label) ?? 0))
        let size = uniform(&rng, 0.10, 0.14)
        let base = Point2(uniform(&rng, 0.4, 0.6), uniform(&rng, 0.38, 0.52))
        let lead = uniform(&rng, 0.6, 0.9)
        var noise = uniform(&rng, 0.0006, 0.0014)
        let sway = (amplitude: uniform(&rng, 0.001, 0.003), frequency: uniform(&rng, 0.3, 0.8),
                    phase: uniform(&rng, 0, 2 * .pi))
        var garbageRate = 0.0, glitchRate = 0.0
        var dropRate = 0.01

        // Motion of the hand in hand space (x right, y down, image-width units) after `lead`.
        var motion: (Double) -> Point2 = { _ in .zero }
        var visible: (Double) -> Bool = { _ in true }
        var secondHand: ((Double) -> Point2)?
        var gestureLength = 0.5
        var tail = 0.8

        func tapParameters() -> (amplitude: Double, out: Double, back: Double) {
            (uniform(&rng, 0.55, 0.75) * size, uniform(&rng, 0.06, 0.085), uniform(&rng, 0.07, 0.10))
        }

        switch label {
        case .click, .rightClick:
            let tap = tapParameters()
            let deviation = uniform(&rng, -15, 15)
            let angle: Double
            if label == .click {
                angle = (rng.unit() < 0.8 ? 90 : -90) + deviation
            } else {
                angle = (rng.unit() < 0.5 ? 0 : 180) + deviation
            }
            let direction = unit(angleDegrees: angle)
            motion = { stroke($0, direction: direction, amplitude: tap.amplitude, outTime: tap.out, backTime: tap.back) }
            gestureLength = tap.out + tap.back

        case .doubleClick:
            let first = tapParameters(), second = tapParameters()
            let gap = uniform(&rng, 0.20, 0.27)
            let direction = unit(angleDegrees: 90 + uniform(&rng, -12, 12))
            let secondStart = first.out + first.back + gap
            motion = { t in
                stroke(t, direction: direction, amplitude: first.amplitude, outTime: first.out, backTime: first.back)
                    + stroke(t - secondStart, direction: direction, amplitude: second.amplitude,
                             outTime: second.out, backTime: second.back)
            }
            gestureLength = secondStart + second.out + second.back

        case .scrollUp, .scrollDown:
            let amplitude = uniform(&rng, 1.9, 3.0) * size
            let out = uniform(&rng, 0.10, 0.15)
            let direction = unit(angleDegrees: (label == .scrollUp ? -90 : 90) + uniform(&rng, -12, 12))
            if rng.unit() < 0.5 {
                // Flick and come straight back.
                let back = uniform(&rng, 0.15, 0.25)
                motion = { stroke($0, direction: direction, amplitude: amplitude, outTime: out, backTime: back) }
                gestureLength = out + back
            } else {
                // Flick, pause, then drift back slowly (that return must not scroll again).
                let pause = uniform(&rng, 0.35, 0.6)
                let back = 1.875 * amplitude / uniform(&rng, 0.7, 1.3)
                motion = { t in
                    t < out + pause
                        ? stroke(t, direction: direction, amplitude: amplitude, outTime: out, backTime: 0)
                        : direction * amplitude - stroke(t - out - pause, direction: direction, amplitude: amplitude,
                                                         outTime: back, backTime: 0)
                }
                gestureLength = out + pause + back
            }

        case .repositionFast:
            let amplitude = uniform(&rng, 2.0, 4.5) * size
            let horizontal = rng.unit() < 0.6
            let angle: Double
            let peak: Double
            if horizontal {
                // Mostly sideways or diagonal: any speed.
                angle = (rng.unit() < 0.5 ? 0 : 180) + uniform(&rng, -55, 55)
                peak = uniform(&rng, 1.2, 3.0)
            } else {
                // Up/down moves stay below the scroll peak speed (a fast vertical flick *is* a scroll).
                angle = (rng.unit() < 0.5 ? 90 : -90) + uniform(&rng, -20, 20)
                peak = uniform(&rng, 1.0, 1.55)
            }
            let duration = 1.875 * amplitude / peak
            let direction = unit(angleDegrees: angle)
            motion = { stroke($0, direction: direction, amplitude: amplitude, outTime: duration, backTime: 0) }
            gestureLength = duration

        case .repositionSlow:
            let amplitude = uniform(&rng, 1.0, 3.0) * size
            let duration = 1.875 * amplitude / uniform(&rng, 0.3, 0.75)
            let direction = unit(angleDegrees: uniform(&rng, 0, 360))
            motion = { stroke($0, direction: direction, amplitude: amplitude, outTime: duration, backTime: 0) }
            gestureLength = duration

        case .fineTarget:
            var moves: [(start: Double, direction: Point2, amplitude: Double, duration: Double)] = []
            var t = 0.0
            for _ in 0..<3 {
                let amplitude = uniform(&rng, 0.1, 0.3) * size
                let duration = uniform(&rng, 0.3, 0.6)
                moves.append((t, unit(angleDegrees: uniform(&rng, 0, 360)), amplitude, duration))
                t += duration + uniform(&rng, 0.2, 0.4)
            }
            motion = { time in
                moves.reduce(Point2.zero) { sum, m in
                    sum + stroke(time - m.start, direction: m.direction, amplitude: m.amplitude,
                                 outTime: m.duration, backTime: 0)
                }
            }
            gestureLength = t

        case .drag:
            let tap = tapParameters()
            let tapDirection = unit(angleDegrees: 90 + uniform(&rng, -12, 12))
            // A deliberate drag: the hand sets off within a fraction of a second of the tap.
            let pause = uniform(&rng, 0.08, 0.2)
            let amplitude = uniform(&rng, 1.5, 2.5) * size
            let duration = 1.875 * amplitude / uniform(&rng, 0.6, 0.9)
            let direction = unit(angleDegrees: uniform(&rng, 0, 360))
            let moveStart = tap.out + tap.back + pause
            motion = { t in
                stroke(t, direction: tapDirection, amplitude: tap.amplitude, outTime: tap.out, backTime: tap.back)
                    + stroke(t - moveStart, direction: direction, amplitude: amplitude, outTime: duration, backTime: 0)
            }
            gestureLength = moveStart + duration
            tail = 1.0

        case .rest:
            gestureLength = 5

        case .jitter:
            gestureLength = 5
            noise = uniform(&rng, 0.002, 0.0035)
            garbageRate = 0.04
            glitchRate = 0.01

        case .outOfFrame:
            // Leave quickly through the nearest side, stay out, come back somewhere else.
            let side: Double = base.x < 0.5 ? -1 : 1
            let exit = 0.25
            let away = uniform(&rng, 0.8, 1.4)
            let returnSpot = Point2(uniform(&rng, -0.08, 0.08), uniform(&rng, -0.05, 0.05))
            motion = { t in
                if t < exit { return Point2(-side * 0.7 * minimumJerk(t / exit), 0) }
                return returnSpot
            }
            visible = { t in t < 0 || t < exit * 0.6 || t > exit + away }
            gestureLength = exit + away + 0.2

        case .zoom:
            let amplitude = uniform(&rng, 1.3, 2.2) * size
            let out = uniform(&rng, 0.14, 0.22)
            let offset = uniform(&rng, 0, 0.05)
            let apart = rng.unit() < 0.5 ? 1.0 : -1.0
            // Primary hand (the user's right) moves right when spreading; the other moves left.
            motion = { stroke($0, direction: Point2(apart, 0), amplitude: amplitude, outTime: out, backTime: 0) }
            secondHand = { stroke($0 - offset, direction: Point2(-apart, 0), amplitude: amplitude, outTime: out, backTime: 0) }
            gestureLength = out + offset
        }

        let duration = lead + gestureLength + tail
        if clean {
            noise = 0
            garbageRate = 0
            glitchRate = 0
            dropRate = 0
        }
        var frames: [TrackingFrame] = []
        let count = Int((duration * fps).rounded())
        var frameRng = SeededRandom(seed: seed &+ 0xA5A5)
        // A two-hand sample puts the primary on the user's right (camera's left).
        let primaryBase = secondHand == nil ? base : Point2(0.38, base.y)
        let secondaryBase = Point2(0.66, base.y)
        for i in 0..<count {
            let nominal = start + Double(i) / fps
            let t = clean ? nominal : nominal + uniform(&frameRng, -0.002, 0.002)
            let local = t - start - lead
            if frameRng.unit() < dropRate || !visible(local) {
                frames.append(TrackingFrame(timestamp: t, hands: []))
                continue
            }
            let swayOffset = clean ? Point2.zero : Point2(sway.amplitude * sin(2 * .pi * sway.frequency * t + sway.phase),
                                    sway.amplitude * 0.6 * cos(2 * .pi * sway.frequency * 0.7 * t + sway.phase))
            var hands: [HandFrame] = []
            var hand = placedHand(tip: primaryBase, size: size, offset: motion(local) + swayOffset)
            var frameNoise = noise
            if frameRng.unit() < garbageRate {
                // A frame Vision was unsure about: landmarks scattered, low confidence.
                hand.confidence = uniform(&frameRng, 0.15, 0.45)
                hand.wrist += Point2(uniform(&frameRng, -1, 1), uniform(&frameRng, -1, 1)) * size
                frameNoise = noise * 4
            } else if frameRng.unit() < glitchRate {
                // A confident single-frame glitch: the whole hand jumps.
                hand.wrist += Point2(3 * size, 0)
            }
            hands.append(hand.frame(at: t, noise: frameNoise, rng: &frameRng))
            if let secondHand {
                var other = placedHand(tip: secondaryBase, size: size, offset: secondHand(local) + swayOffset)
                other.chirality = .left
                other.wrist = other.wristPlacing(indexTipAt: SyntheticHand.imagePoint(secondaryBase, offset: secondHand(local) + swayOffset))
                hands.append(other.frame(at: t, noise: noise, rng: &frameRng))
            }
            frames.append(TrackingFrame(timestamp: t, hands: hands))
        }
        let segment = LabeledSegment(label: label.rawValue, startTime: start + lead - 0.05,
                                     endTime: start + lead + gestureLength + tail)
        return Sample(label: label, frames: frames, segment: segment)
    }

    /// A pointing hand whose index tip sits at `tip` moved by `offset` (hand space).
    static func placedHand(tip: Point2, size: Double, offset: Point2) -> SyntheticHand {
        var hand = SyntheticHand(wrist: .zero)
        hand.size = size
        hand.wrist = hand.wristPlacing(indexTipAt: SyntheticHand.imagePoint(tip, offset: offset))
        return hand
    }
}

extension SyntheticHand {
    /// Image point (un-mirrored, top-left origin) for a hand-space `offset` from `tip`.
    static func imagePoint(_ tip: Point2, offset: Point2, aspect: Double = 16.0 / 9.0) -> Point2 {
        Point2(tip.x - offset.x, tip.y + offset.y * aspect)
    }
}
