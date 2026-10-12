import Foundation

/// Coarse hand shape, independent of pinching.
public enum HandPose: String, Codable, Equatable {
    /// Anything that is not a fist or an open palm: pointing, relaxed, mid-transition.
    case point
    /// All four fingers curled. Drags (one hand) or zooms and scrolls (two hands).
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

/// Classifies one hand's pose over time, with a confirmation delay so a one-frame misread never
/// starts a drag, a two-fist gesture or the palm toggle.
///
/// One detector instance follows one physical hand (the pointer state machine keeps one per
/// tracked hand slot), because the confirmation depends on history.
public struct GestureDetector {
    public struct State: Equatable {
        public var pose: HandPose = .point
        public var features: HandFeatures?
    }

    public enum Event: Equatable {
        case poseChanged(HandPose)
    }

    public var config: GestureConfig
    public private(set) var state = State()
    /// This frame's pose before confirmation (a fist shows here a few frames before `state`).
    public private(set) var observedPose: HandPose?

    private var poseCandidate: (pose: HandPose, since: Double)?

    public init(config: GestureConfig) {
        self.config = config
    }

    public mutating func reset() {
        state = State()
        observedPose = nil
        poseCandidate = nil
    }

    /// Feed one observation of this hand. Returns the pose change confirmed on this frame, if any.
    @discardableResult
    public mutating func update(_ hand: HandFrame) -> [Event] {
        let features = HandFeatures(hand)
        state.features = features
        let observed = rawPose(features)
        observedPose = observed
        if observed == state.pose {
            poseCandidate = nil
            return []
        }
        if let candidate = poseCandidate, candidate.pose == observed {
            if hand.timestamp - candidate.since >= config.poseConfirmDuration {
                state.pose = observed
                poseCandidate = nil
                return [.poseChanged(observed)]
            }
        } else {
            poseCandidate = (observed, hand.timestamp)
        }
        return []
    }

    private func rawPose(_ f: HandFeatures) -> HandPose {
        let allCurled = f.curlRatios.allSatisfy { $0 < config.curlCurledRatio }
        if allCurled { return .fist }
        let allExtended = f.curlRatios.allSatisfy { $0 > config.curlExtendedRatio }
        // An open palm has the thumb spread and clear of every fingertip.
        let thumbClear = f.closestPinch.distance > config.palmThumbClearance
        if allExtended && f.thumbSpread > 0.55 && thumbClear { return .openPalm }
        return .point
    }
}
