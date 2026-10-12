import Foundation

/// How fast the cursor moves relative to the hand, as a function of hand speed. Every preset is
/// two gains: one for a slow hand, one for a fast hand, blended smoothly in between. A gain of 1
/// means "the cursor moves exactly as far as the hand points"; 2 means twice as far; 0.5 half.
///
/// `.direct` (1 / 1) is the laser pointer: the cursor stays exactly under where the finger
/// points. Every other preset moves the cursor by *scaled hand motion*, so cursor and finger
/// drift apart; like a mouse, the screen edge is where they meet again (push past the edge,
/// come back, and the cursor has caught up).
public enum PointerResponse: String, Codable, CaseIterable, Equatable {
    /// Mouse speed = hand speed.
    case direct
    /// Hand slows down → cursor speeds up; otherwise mouse speed = hand speed.
    case slowBoost
    /// Hand speeds up → cursor slows down; otherwise mouse speed = hand speed.
    case fastDamp
    /// Hand slows down → cursor speeds up, hand speeds up → cursor slows down.
    case inverted
    /// Classic mouse acceleration: slow hand = fine aim, fast hand = covers the screen.
    case accelerated
    /// Slow hand = fine aim (half speed); otherwise mouse speed = hand speed.
    case fineAim
    /// Fast hand = long reach (2.5×); otherwise mouse speed = hand speed.
    case fastReach
    /// Twice the hand's motion at every speed: small movements cross the screen.
    case double
    /// Half the hand's motion at every speed: big movements, fine aim everywhere.
    case half

    public var title: String {
        switch self {
        case .direct: return "Direct (1:1)"
        case .slowBoost: return "Slow hand boosts"
        case .fastDamp: return "Fast hand damps"
        case .inverted: return "Inverted (slow boosts, fast damps)"
        case .accelerated: return "Accelerated (like a mouse)"
        case .fineAim: return "Fine aim when slow"
        case .fastReach: return "Long reach when fast"
        case .double: return "Double (2×)"
        case .half: return "Half (0.5×)"
        }
    }

    public var summary: String {
        switch self {
        case .direct: return "Cursor speed = hand speed. The cursor stays exactly where your finger points."
        case .slowBoost: return "Moving slowly, the cursor goes 2× as far; at normal speed it matches your hand."
        case .fastDamp: return "Moving fast, the cursor goes half as far; at slow speed it matches your hand."
        case .inverted: return "Slow moves go 2× as far, fast moves half as far."
        case .accelerated: return "Slow moves go half as far for precise aim; fast moves go 2× as far to cross the screen."
        case .fineAim: return "Slow moves go half as far for precise aim; faster moves match your hand."
        case .fastReach: return "Fast moves go 2.5× as far; slower moves match your hand."
        case .double: return "The cursor always moves 2× as far as your hand."
        case .half: return "The cursor always moves half as far as your hand."
        }
    }

    /// Gain at or below `PointerGain.slowSpeed`.
    public var slowGain: Double {
        switch self {
        case .direct, .fastDamp, .fastReach: return 1
        case .slowBoost, .inverted, .double: return 2
        case .accelerated, .fineAim, .half: return 0.5
        }
    }

    /// Gain at or above `PointerGain.fastSpeed`.
    public var fastGain: Double {
        switch self {
        case .direct, .slowBoost, .fineAim: return 1
        case .fastDamp, .inverted, .half: return 0.5
        case .accelerated, .double: return 2
        case .fastReach: return 2.5
        }
    }

    /// True when the cursor is the plain laser pointer (no gain stage at all).
    public var isDirect: Bool { slowGain == 1 && fastGain == 1 }

    /// Gain for a hand moving at `speed` box widths per second: `slowGain` below `slowSpeed`,
    /// `fastGain` above `fastSpeed`, smoothstep in between so the cursor never lurches.
    public func gain(atSpeed speed: Double) -> Double {
        let t = clamp01((speed - PointerGain.slowSpeed) / (PointerGain.fastSpeed - PointerGain.slowSpeed))
        let eased = t * t * (3 - 2 * t)
        return slowGain + (fastGain - slowGain) * eased
    }
}

/// Applies a `PointerResponse` to the smoothed pointer: the cursor moves by the hand's motion
/// times the speed-dependent gain, and is kept on the screen (box 0…1) like a mouse.
struct PointerGain {
    /// Hand speeds (box widths per second) where the "slow" and "fast" gains apply. Careful aim
    /// is well under 0.15 screen widths per second; a flick across the screen is over 1.
    static let slowSpeed = 0.15
    static let fastSpeed = 1.0

    private var lastHand: Point2?
    private var cursor: Point2?

    mutating func reset(to point: Point2?) {
        lastHand = point
        cursor = point
    }

    mutating func reset(hand: Point2, cursor: Point2) {
        lastHand = hand
        self.cursor = cursor
    }

    mutating func apply(_ hand: Point2, speed: Double, response: PointerResponse) -> Point2 {
        guard !response.isDirect, let previous = lastHand, let current = cursor else {
            reset(to: hand)
            return hand
        }
        lastHand = hand
        let moved = current + (hand - previous) * response.gain(atSpeed: speed)
        let kept = Point2(clamp01(moved.x), clamp01(moved.y))
        cursor = kept
        return kept
    }
}
