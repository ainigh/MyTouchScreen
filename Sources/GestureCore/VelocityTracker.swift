import Foundation

// MARK: - Hand-space signals

extension HandFrame {
    /// A camera point in hand space: mirrored (the user's right is +x) and isotropic (fractions
    /// of the image width on both axes, +y down). Velocity thresholds are expressed here, so
    /// they don't depend on screen size or the calibrated active box.
    public func handSpace(_ p: Point2) -> Point2 {
        Point2(1 - p.x, p.y / imageAspect)
    }

    /// Mean of the wrist and the four finger MCPs, in hand space. Curling or spreading fingers
    /// barely moves it, so it is the steady signal all velocity logic runs on.
    public var motionCentroid: Point2 { handSpace(palmCenter) }
}

/// One hand observation reduced to what the velocity logic needs.
public struct MotionSample: Equatable {
    public var time: Double
    public var centroid: Point2
    public var handSize: Double
    public var confidence: Double

    public init(time: Double, centroid: Point2, handSize: Double, confidence: Double) {
        self.time = time
        self.centroid = centroid
        self.handSize = handSize
        self.confidence = confidence
    }

    public init(_ hand: HandFrame) {
        self.init(time: hand.timestamp, centroid: hand.motionCentroid, handSize: hand.handSize,
                  confidence: hand.confidence)
    }
}

/// Centroid velocity from a least-squares line through the samples of the last 40 ms (three
/// frames at 60 fps, two at 30 fps). Light enough to react within a frame or two; never derived
/// from the pointer's heavily smoothed signal.
struct VelocityEstimator {
    static let window = 0.04
    private var samples: [(time: Double, point: Point2)] = []

    mutating func reset() { samples.removeAll() }

    mutating func add(_ point: Point2, at time: Double) -> Point2 {
        if let last = samples.last, time <= last.time { samples.removeLast() }
        samples.append((time, point))
        // Keep the samples inside the window, but always at least two (after a dropped frame
        // the previous sample may be older than the window).
        while samples.count > 2, time - samples[0].time > Self.window {
            samples.removeFirst()
        }
        guard samples.count >= 2 else { return .zero }
        let n = Double(samples.count)
        let meanT = samples.reduce(0) { $0 + $1.time } / n
        let meanP = samples.reduce(Point2.zero) { $0 + $1.point } / n
        var stt = 0.0
        var stp = Point2.zero
        for s in samples {
            let dt = s.time - meanT
            stt += dt * dt
            stp += (s.point - meanP) * dt
        }
        guard stt > 1e-12 else { return .zero }
        return stp / stt
    }
}

// MARK: - Segments

public enum SegmentAxis: String, Codable, Equatable {
    case vertical, horizontal, ambiguous
}

/// Measurements of one finished fast segment, normalized by hand size. These are exactly the
/// numbers the classifier and the "why not?" overlay use.
public struct SegmentStats: Equatable {
    /// Time of the last sample before the first fast frame: where the user "was".
    public var anchorTime: Double
    /// First fast frame.
    public var startTime: Double
    /// `T`: first fast frame to the first frame of the final slow run.
    public var duration: Double
    /// `d`: centroid displacement from the anchor at the end, in hand sizes (x right, y down).
    public var displacement: Point2
    /// Largest displacement from the anchor during the segment, in hand sizes.
    public var excursion: Point2
    /// `L`: path length in hand sizes.
    public var pathLength: Double
    /// `vpeak`: peak centroid speed, hand-space units per second.
    public var peakSpeed: Double
    /// The hand came back at least `returnFraction` of the way from its furthest point.
    public var reversed: Bool
    /// The hand was still for `preClickStillTime` right before the segment.
    public var startedFromStill: Bool
    /// The anchor and peak frames were both above `minConfidence`.
    public var confident: Bool
    /// Ended by `maxSegment` rather than by the hand slowing down.
    public var timedOut: Bool
    /// Anchor centroid in hand space (for double-click distance).
    public var anchorCentroid: Point2
    public var handSize: Double

    public var distance: Double { displacement.length }
}

/// What a `MotionTracker` noticed in one sample.
public enum MotionEvent: Equatable {
    case segmentStarted(anchorTime: Double, startTime: Double)
    case segmentEnded(SegmentStats)
    /// A single-frame jump larger than `glitchDisp`: any segment in progress is dropped.
    case glitch(time: Double)
}

/// Per-hand fast-segment tracker (SPEC-M7 state machine, minus classification):
/// hover ⇄ fastSegment with hysteresis (`vEnter`/`vExit`), coherence and confidence checks.
public struct MotionTracker {
    public var params: VelocityParams

    private var estimator = VelocityEstimator()
    private var last: (time: Double, centroid: Point2, velocity: Point2)?
    /// Smoothed frame period, for turning frame counts into time.
    private var period = 1.0 / 60.0
    private var smoothedHandSize: Double?
    /// A low-confidence frame was skipped since the last used sample.
    private var bridgedLowConfidence = false
    private var lastLowConfidenceTime = -Double.infinity

    // Fast run (before a segment starts).
    private var runFrames = 0
    private var runStart: Double = 0
    private var runAnchor: (time: Double, centroid: Point2, confident: Bool)?
    private var runFirstConfident = true
    private var runCoherent = false

    // Stillness before a segment.
    private var stillStart: Double?
    private var lastStillRun: (start: Double, end: Double)?
    /// The last sample that was still: where the hand "was" before a flick.
    private var lastStillSample: (time: Double, centroid: Point2)?

    /// No segment may start before this time (set after an emitted click or scroll).
    public var refractoryUntil = -Double.infinity

    private struct Segment {
        var anchorTime: Double
        var startTime: Double
        var anchorCentroid: Point2
        var lastCentroid: Point2
        var path: Double = 0
        var excursion = Point2.zero
        var peakSpeed: Double = 0
        var peakConfident = true
        var anchorConfident: Bool
        var slowStart: Double?
        var startedFromStill: Bool
        var handSizeSum: Double = 0
        var handSizeCount = 0
    }
    private var segment: Segment?

    public init(params: VelocityParams) {
        self.params = params
    }

    // MARK: Read-only state

    public var inSegment: Bool { segment != nil }
    public var segmentStartTime: Double? { segment?.startTime }
    public var segmentAnchorTime: Double? { segment?.anchorTime }
    /// Latest centroid velocity (hand-space units per second).
    public var velocity: Point2 { last?.velocity ?? .zero }
    public var speed: Double { velocity.length }
    public var centroid: Point2? { last?.centroid }
    public var framePeriod: Double { period }
    public var handSize: Double { smoothedHandSize ?? 0.1 }

    public mutating func reset() {
        let keep = params
        let refractory = refractoryUntil
        self = MotionTracker(params: keep)
        refractoryUntil = refractory
    }

    /// Drop the segment in progress without classifying it (hand lost, hand swapped).
    public mutating func abortSegment() {
        segment = nil
        runFrames = 0
    }

    // MARK: Update

    public mutating func update(_ sample: MotionSample) -> [MotionEvent] {
        // Low-confidence frames are ignored by the velocity logic; the next good frame notes
        // that it bridged one, so a segment anchored or peaking there can be rejected.
        guard sample.confidence >= params.minConfidence else {
            bridgedLowConfidence = true
            lastLowConfidenceTime = sample.time
            return []
        }
        let bridged = bridgedLowConfidence
        bridgedLowConfidence = false

        if let size = smoothedHandSize {
            smoothedHandSize = size + (sample.handSize - size) * 0.2
        } else {
            smoothedHandSize = sample.handSize
        }
        let handSize = max(smoothedHandSize ?? sample.handSize, 1e-4)

        var events: [MotionEvent] = []
        if let previous = last {
            let dt = sample.time - previous.time
            if dt > 0 {
                period += (min(max(dt, 1.0 / 240.0), 0.1) - period) * 0.1
            }
            // A landmark glitch: one frame far from the last. Forget everything about motion.
            if sample.centroid.distance(to: previous.centroid) > params.glitchDisp * handSize {
                estimator.reset()
                _ = estimator.add(sample.centroid, at: sample.time)
                last = (sample.time, sample.centroid, .zero)
                segment = nil
                runFrames = 0
                stillStart = nil
                lastStillRun = nil
                lastStillSample = nil
                return [.glitch(time: sample.time)]
            }
        }

        let velocity = estimator.add(sample.centroid, at: sample.time)
        let speed = velocity.length
        let previous = last
        last = (sample.time, sample.centroid, velocity)

        updateStillness(speed: speed, at: sample.time)

        if segment != nil {
            if let ended = advanceSegment(sample, speed: speed, bridged: bridged, handSize: handSize) {
                events.append(.segmentEnded(ended))
            }
            return events
        }

        // Hover: look for a coherent fast run.
        guard sample.time >= refractoryUntil else {
            runFrames = 0
            return events
        }
        guard speed > params.vEnter else {
            runFrames = 0
            return events
        }
        // Coherent: the direction changed by less than `coherenceAngle` since the previous
        // frame. A hand starting from rest has no previous direction to disagree with.
        let coherentWithPrevious: Bool = {
            guard let previous else { return false }
            guard previous.velocity.length >= params.preClickStillV else { return true }
            return angleDegrees(previous.velocity, velocity) < params.coherenceAngle
        }()
        if runFrames == 0 || !coherentWithPrevious {
            runFrames = 1
            runStart = sample.time
            // Anchor: where the hand was before it started moving. By the first frame above
            // vEnter the hand has already travelled a little (the speed estimate needs a frame or
            // two to rise), so prefer the last still sample when it is recent.
            if let still = lastStillSample, sample.time - still.time <= Self.stillToFastGap {
                runAnchor = (still.time, still.centroid, true)
            } else if let previous {
                runAnchor = (previous.time, previous.centroid, true)
            } else {
                runAnchor = (sample.time, sample.centroid, true)
            }
            runFirstConfident = !bridged
            // A first frame that turned sharply from earlier motion starts a run but can't
            // complete one on its own.
            runCoherent = coherentWithPrevious
        } else {
            runFrames += 1
            runCoherent = true
        }
        // Frames × period ≥ framesEnter reference frames (two frames at 60 fps, one at 30 fps),
        // every frame coherent with the one before.
        let span = sample.time - runStart + period
        if runCoherent && span >= params.enterTime - 0.25 / VelocityParams.referenceRate,
           let anchor = runAnchor {
            let still: Bool = {
                guard let run = lastStillRun else { return false }
                let held = run.end - run.start + period
                return held >= params.preClickStillTime - 0.25 / VelocityParams.referenceRate
                    && runStart - run.end <= Self.stillToFastGap
            }()
            // A low-confidence frame anywhere from just before the anchor to the first fast frame
            // means the anchor itself can't be trusted.
            let anchorDoubtful = lastLowConfidenceTime > anchor.time - period * 1.5 && lastLowConfidenceTime <= runStart
            var s = Segment(anchorTime: anchor.time, startTime: runStart, anchorCentroid: anchor.centroid,
                            lastCentroid: anchor.centroid,
                            anchorConfident: anchor.confident && runFirstConfident && !anchorDoubtful,
                            startedFromStill: still)
            s.handSizeSum = handSize
            s.handSizeCount = 1
            segment = s
            runFrames = 0
            events.append(.segmentStarted(anchorTime: anchor.time, startTime: runStart))
            // Account for the frames of the run itself (path, excursion, peak).
            if let ended = advanceSegment(sample, speed: speed, bridged: bridged, handSize: handSize) {
                events.append(.segmentEnded(ended))
            }
        }
        return events
    }

    /// The fast run must begin within this long after the hand was last still for a tap to count
    /// as "starting from stillness": speed passes `preClickStillV` a frame or two before `vEnter`.
    static let stillToFastGap = 0.1

    private mutating func updateStillness(speed: Double, at time: Double) {
        if speed < params.preClickStillV {
            if stillStart == nil { stillStart = time }
            lastStillRun = (stillStart ?? time, time)
            if let centroid = last?.centroid { lastStillSample = (time, centroid) }
        } else {
            stillStart = nil
        }
    }

    private mutating func advanceSegment(_ sample: MotionSample, speed: Double, bridged: Bool,
                                         handSize: Double) -> SegmentStats? {
        guard var s = segment else { return nil }
        s.path += sample.centroid.distance(to: s.lastCentroid)
        s.lastCentroid = sample.centroid
        let offset = sample.centroid - s.anchorCentroid
        if offset.length > s.excursion.length { s.excursion = offset }
        if speed > s.peakSpeed {
            s.peakSpeed = speed
            s.peakConfident = !bridged
        }
        s.handSizeSum += handSize
        s.handSizeCount += 1

        if speed < params.vExit {
            if s.slowStart == nil { s.slowStart = sample.time }
        } else {
            s.slowStart = nil
        }
        let slowFor = s.slowStart.map { sample.time - $0 + period } ?? 0
        let settled = s.slowStart != nil && slowFor >= params.exitTime - 0.25 / VelocityParams.referenceRate
        let timedOut = sample.time - s.startTime > params.maxSegment
        guard settled || timedOut else {
            segment = s
            return nil
        }
        segment = nil
        let size = max(s.handSizeSum / Double(max(s.handSizeCount, 1)), 1e-4)
        let excursion = s.excursion / size
        let displacement = offset / size
        let returned = excursion.length > 1e-9
            && displacement.length <= (1 - params.returnFraction) * excursion.length
        let end = settled ? (s.slowStart ?? sample.time) : sample.time
        return SegmentStats(anchorTime: s.anchorTime, startTime: s.startTime,
                            duration: max(end - s.startTime, 0), displacement: displacement,
                            excursion: excursion, pathLength: s.path / size, peakSpeed: s.peakSpeed,
                            reversed: returned, startedFromStill: s.startedFromStill,
                            confident: s.anchorConfident && s.peakConfident, timedOut: !settled,
                            anchorCentroid: s.anchorCentroid, handSize: size)
    }
}

/// Angle between two vectors in degrees (0...180).
func angleDegrees(_ a: Point2, _ b: Point2) -> Double {
    let la = a.length, lb = b.length
    guard la > 1e-12, lb > 1e-12 else { return 180 }
    let cosine = clamp((a.x * b.x + a.y * b.y) / (la * lb), -1, 1)
    return acos(cosine) * 180 / .pi
}
