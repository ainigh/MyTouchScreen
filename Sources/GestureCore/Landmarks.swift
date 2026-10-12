import Foundation

/// The 21 hand joints, in the same order MediaPipe and most literature use, so recordings are
/// easy to compare with other tools. Vision's joint names map onto these one-to-one.
public enum Joint: Int, CaseIterable, Codable {
    case wrist = 0
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip

    public static let count = 21
}

/// Which hand the tracker believes this is (from the person's point of view).
public enum Chirality: String, Codable {
    case left, right, unknown
}

/// One fingertip used for pinching against the thumb.
public enum PinchFinger: String, Codable, CaseIterable {
    case index, middle, ring

    var tip: Joint {
        switch self {
        case .index: return .indexTip
        case .middle: return .middleTip
        case .ring: return .ringTip
        }
    }
}

/// A single observed hand at one instant.
///
/// Coordinates are normalized camera-image coordinates with a **top-left origin** and **no
/// mirroring** (exactly what the camera sees, y flipped from Vision's bottom-left origin).
/// Mirroring is a property of the calibration mapping, not of the data, so a recording replays
/// identically regardless of display settings.
public struct HandFrame: Equatable {
    public var points: [Point2]
    /// Per-joint confidence in 0...1. A joint Vision did not return has confidence 0 and its
    /// point is a best-effort estimate (see `HandTracker`).
    public var jointConfidences: [Double]
    public var chirality: Chirality
    /// Overall observation confidence in 0...1.
    public var confidence: Double
    /// Seconds on a monotonic clock (camera presentation time in the app).
    public var timestamp: Double
    /// Image width / height. Normalized coordinates stretch differently in x and y (1280x720
    /// is 16:9), so every distance is measured after undoing that stretch; otherwise a pinch
    /// would read differently depending on how the hand is rotated.
    public var imageAspect: Double

    public init(points: [Point2], jointConfidences: [Double]? = nil, chirality: Chirality,
                confidence: Double, timestamp: Double, imageAspect: Double = 16.0 / 9.0) {
        precondition(points.count == Joint.count, "HandFrame needs exactly 21 points")
        self.points = points
        self.imageAspect = imageAspect
        self.jointConfidences = jointConfidences ?? Array(repeating: confidence, count: Joint.count)
        self.chirality = chirality
        self.confidence = confidence
        self.timestamp = timestamp
    }

    public subscript(_ joint: Joint) -> Point2 { points[joint.rawValue] }

    /// The joint in isotropic units (fractions of the image width in both axes), for measuring.
    public func metric(_ joint: Joint) -> Point2 {
        let p = points[joint.rawValue]
        return Point2(p.x, p.y / imageAspect)
    }

    /// Isotropic distance between two joints, in fractions of the image width.
    public func distance(_ a: Joint, _ b: Joint) -> Double {
        metric(a).distance(to: metric(b))
    }

    /// Wrist to middle-finger MCP: the most rigid span of the hand, used to normalize every
    /// other distance so thresholds hold at any distance from the camera.
    public var handSize: Double {
        max(distance(.wrist, .middleMCP), 1e-6)
    }

    /// Thumb tip to fingertip distance divided by hand size.
    public func pinchDistanceNormalized(_ finger: PinchFinger) -> Double {
        distance(.thumbTip, finger.tip) / handSize
    }

    /// Centroid of the wrist and the four finger MCPs. It barely moves when fingers curl,
    /// which makes it the right thing to track for fist-scroll and as a stable pointer anchor.
    public var palmCenter: Point2 {
        let joints: [Joint] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        var sum = Point2.zero
        for j in joints { sum += self[j] }
        return sum / Double(joints.count)
    }
}

/// Everything the tracker saw in one camera frame (zero, one or two hands).
public struct TrackingFrame: Equatable {
    public var timestamp: Double
    public var hands: [HandFrame]

    public init(timestamp: Double, hands: [HandFrame]) {
        self.timestamp = timestamp
        self.hands = hands
    }
}
