import Foundation

/// Coarse hand shape, independent of pinching.
public enum HandPose: String, Codable, Equatable {
    /// Anything that is not a fist or an open palm: pointing, relaxed, mid-transition.
    case point
    /// All four fingers curled. Drives scrolling.
    case fist
    /// All five digits extended. Held still, it toggles engagement.
    case openPalm
}

/// Geometric measurements of one hand, all normalized by hand size.
public struct HandFeatures: Equatable {
    public var handSize: Double
    public var pinchDistance: [PinchFinger: Double]
    /// wrist→tip divided by wrist→MCP for index, middle, ring, little. ~1.8 straight, ~0.8 curled.
    public var curlRatios: [Double]
    /// Thumb tip to index MCP, normalized. Large when the thumb is spread out.
    public var thumbSpread: Double
    public var palmCenter: Point2
    public var indexTip: Point2
    public var indexMCP: Point2

    public init(_ hand: HandFrame) {
        let size = hand.handSize
        handSize = size
        var pinches: [PinchFinger: Double] = [:]
        for finger in PinchFinger.allCases {
            pinches[finger] = hand.pinchDistanceNormalized(finger)
        }
        pinchDistance = pinches
        let fingers: [(Joint, Joint)] = [(.indexMCP, .indexTip), (.middleMCP, .middleTip),
                                         (.ringMCP, .ringTip), (.littleMCP, .littleTip)]
        curlRatios = fingers.map { mcp, tip in
            hand.distance(.wrist, tip) / max(hand.distance(.wrist, mcp), 1e-6)
        }
        thumbSpread = hand.distance(.thumbTip, .indexMCP) / size
        palmCenter = hand.palmCenter
        indexTip = hand[.indexTip]
        indexMCP = hand[.indexMCP]
    }

    public var indexPinch: Double { pinchDistance[.index] ?? 1 }

    /// Smallest pinch distance over the three fingers, and which finger it is.
    public var closestPinch: (finger: PinchFinger, distance: Double) {
        var best: (PinchFinger, Double) = (.index, indexPinch)
        for finger in PinchFinger.allCases {
            let d = pinchDistance[finger] ?? 1
            if d < best.1 { best = (finger, d) }
        }
        return best
    }
}

/// Classifies one hand over time: pose with confirmation delay, and pinches with hysteresis,
/// a minimum duration, a release confirmation and a refractory period.
///
/// One detector instance follows one physical hand (the pointer state machine keeps one per
/// tracked hand slot), because every guard here depends on history.
public struct GestureDetector {
    public struct State: Equatable {
        public var pose: HandPose = .point
        /// The confirmed active pinch, if any.
        public var pinch: PinchFinger?
        /// When the confirmed pinch actually started (first frame under the enter threshold),
        /// which is up to `pinchMinDuration` before it was confirmed.
        public var pinchStartTime: Double = 0
        /// True once fingers are close enough that a pinch is likely coming.
        public var armed = false
        /// 0 at the arm threshold, 1 at the enter threshold, for the progress ring.
        public var pinchProgress: Double = 0
        public var features: HandFeatures?
    }

    public enum Event: Equatable {
        case pinchBegan(PinchFinger, startTime: Double)
        case pinchEnded(PinchFinger)
        case poseChanged(HandPose)
    }

    public var config: GestureConfig
    public private(set) var state = State()

    private var pinchCandidate: (finger: PinchFinger, since: Double)?
    private var releaseCandidateSince: Double?
    private var refractoryUntil: Double = -.infinity
    private var poseCandidate: (pose: HandPose, since: Double)?

    public init(config: GestureConfig) {
        self.config = config
    }

    public mutating func reset() {
        state = State()
        pinchCandidate = nil
        releaseCandidateSince = nil
        poseCandidate = nil
    }

    /// Feed one observation of this hand. Returns the transitions that happened on this frame.
    public mutating func update(_ hand: HandFrame) -> [Event] {
        let features = HandFeatures(hand)
        let time = hand.timestamp
        state.features = features
        var events: [Event] = []

        updatePose(features, time: time, events: &events)
        updatePinch(features, time: time, events: &events)
        return events
    }

    /// Release any active pinch (hand lost). Returns the end event if one was active.
    public mutating func forceRelease(at time: Double) -> [Event] {
        pinchCandidate = nil
        releaseCandidateSince = nil
        guard let finger = state.pinch else { return [] }
        state.pinch = nil
        refractoryUntil = time + config.pinchRefractory
        return [.pinchEnded(finger)]
    }

    // MARK: Pose

    private func rawPose(_ f: HandFeatures) -> HandPose {
        let allCurled = f.curlRatios.allSatisfy { $0 < config.curlCurledRatio }
        if allCurled { return .fist }
        let allExtended = f.curlRatios.allSatisfy { $0 > config.curlExtendedRatio }
        let noPinch = f.closestPinch.distance > config.pinchExit
        if allExtended && f.thumbSpread > 0.55 && noPinch { return .openPalm }
        return .point
    }

    private mutating func updatePose(_ f: HandFeatures, time: Double, events: inout [Event]) {
        let observed = rawPose(f)
        if observed == state.pose {
            poseCandidate = nil
            return
        }
        if let candidate = poseCandidate, candidate.pose == observed {
            if time - candidate.since >= config.poseConfirmDuration {
                state.pose = observed
                poseCandidate = nil
                events.append(.poseChanged(observed))
            }
        } else {
            poseCandidate = (observed, time)
        }
    }

    // MARK: Pinch

    private mutating func updatePinch(_ f: HandFeatures, time: Double, events: inout [Event]) {
        let closest = f.closestPinch
        let enter = config.pinchEnter
        let exit = config.pinchExit

        // Progress ring: 0 at the arm distance, 1 at the enter distance.
        let progressSpan = max(config.pinchArm - enter, 1e-6)
        state.pinchProgress = state.pinch != nil ? 1 : clamp01((config.pinchArm - closest.distance) / progressSpan)

        if let active = state.pinch {
            state.armed = true
            let d = f.pinchDistance[active] ?? 1
            if d > exit {
                // Require the release to persist briefly so one glitched landmark frame can
                // never drop a drag.
                if let since = releaseCandidateSince {
                    if time - since >= 0.03 {
                        state.pinch = nil
                        releaseCandidateSince = nil
                        // Refractory counts from when the fingers actually opened, not from
                        // the confirmation frame, or quick double pinches would be eaten.
                        refractoryUntil = since + config.pinchRefractory
                        state.armed = closest.distance < config.pinchArm
                        events.append(.pinchEnded(active))
                    }
                } else {
                    releaseCandidateSince = time
                }
            } else {
                releaseCandidateSince = nil
            }
            return
        }

        state.armed = closest.distance < config.pinchArm && state.pose != .fist

        // No pinches in a fist (the thumb rests on the curled index) or during refractory.
        let indexCurled = f.curlRatios[0] < config.curlCurledRatio
        guard state.pose != .fist, !indexCurled, time >= refractoryUntil else {
            pinchCandidate = nil
            return
        }

        if let candidate = pinchCandidate {
            let d = f.pinchDistance[candidate.finger] ?? 1
            if d > exit {
                // Opened again before the minimum duration: accidental contact, ignore.
                pinchCandidate = nil
            } else if time - candidate.since >= config.pinchMinDuration {
                state.pinch = candidate.finger
                state.pinchStartTime = candidate.since
                state.pinchProgress = 1
                pinchCandidate = nil
                events.append(.pinchBegan(candidate.finger, startTime: candidate.since))
            }
            return
        }

        if closest.distance < enter && isDominant(closest.finger, f) {
            pinchCandidate = (closest.finger, time)
            // A zero minimum duration confirms immediately (used by tests and replays).
            if config.pinchMinDuration <= 0 {
                updatePinch(f, time: time, events: &events)
            }
        }
    }

    /// The pinching finger must be clearly closer to the thumb than the others.
    private func isDominant(_ finger: PinchFinger, _ f: HandFeatures) -> Bool {
        let d = f.pinchDistance[finger] ?? 1
        for other in PinchFinger.allCases where other != finger {
            let od = f.pinchDistance[other] ?? 1
            if d > od * config.pinchDominanceRatio && od < config.pinchExit { return false }
        }
        return true
    }
}
