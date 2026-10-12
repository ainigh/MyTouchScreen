import Foundation

/// Every tunable in the gesture pipeline. Codable so the settings window can export/import it
/// and so a replay can be re-run with exactly the settings it was recorded with.
///
/// Distances named `...Normalized` are divided by hand size (wrist → middle MCP).
/// Distances named `...Box` are in active-box units (1.0 = the full width of the screen).
public struct GestureConfig: Equatable, Codable {
    /// Lock, wiggle click, fist drag and two-fist thresholds.
    public var shake = ShakeParams()

    // Pointer filtering
    public var filter = OneEuroParameters(minCutoff: 0.6, beta: 6.0, derivativeCutoff: 1.0)
    /// Dead zone while moving: the cursor trails the filtered point by at most this much, which
    /// at any real speed is a fraction of one frame of motion.
    public var deadZoneBox = 0.0015
    /// Dead zone once the cursor has rested for `restLockDelay`: residual jitter of a still hand
    /// stays below this, which is what makes the cursor *rock steady* (≈9 pt on a laptop screen).
    public var restDeadZoneBox = 0.005
    public var restLockDelay = 0.25
    /// Precision mode: below `precisionSpeedBox` the cursor moves at `precisionGain` of the
    /// hand's speed. The accumulated offset drains away when the hand moves fast again, so the
    /// absolute mapping is restored.
    public var precisionEnabled = true
    public var precisionSpeedBox = 0.12
    public var precisionGain = 0.45
    public var precisionMaxOffsetBox = 0.06
    /// Sensitivity: scale of the active box (smaller = less hand motion per screen).
    public var boxScale = 1.0
    public var edgeOvershoot = 0.04

    // Poses
    public var curlExtendedRatio = 1.45
    public var curlCurledRatio = 1.2
    public var poseConfirmDuration = 0.08
    /// An open palm's thumb tip is at least this far (hand sizes) from every fingertip.
    public var palmThumbClearance = 0.5

    // Engagement
    public var palmEngageEnabled = true
    public var palmEngageDuration = 0.6
    public var palmDisengageDuration = 0.8
    public var palmStillnessNormalized = 0.6   // max palm speed in hand sizes per second
    public var handLostTimeout = 2.0
    public var handDropoutGrace = 0.15

    // Scroll (two fists)
    public var scrollSpeed = 1.0               // multiplier
    public var scrollPointsPerBox = 1600.0     // fist travel of one box width scrolls this much
    public var naturalScrolling = true
    public var momentumFriction = 4.0          // 1/s exponential decay rate of the glide
    public var momentumMinSpeed = 40.0         // points/s below which the glide stops

    // Multi-display
    /// The hand stays on the display the mouse pointer was on when Wisp engaged (no edge
    /// jumps; moving the real mouse to another display while engaged doesn't move it either).
    public var stayOnEngagedDisplay = true
    public var displayJumpDwell = 0.4

    /// Which hand points: `.left` makes the left hand the pointing hand.
    public var preferredHand: Chirality = .unknown

    public init() {}

    public static let `default` = GestureConfig()
}

extension GestureConfig {
    /// Decode settings JSON written by any version: keys missing from `data` keep their default
    /// values and unknown keys are ignored. Synthesized `Codable` would reject a file exported
    /// before a setting existed, which would make "import settings" brittle across updates.
    public static func decodeLenient(_ data: Data) throws -> GestureConfig {
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GestureConfig()))
        guard var merged = defaults as? [String: Any],
              let incoming = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Settings JSON must be an object"))
        }
        merged = mergeLenient(defaults: merged, incoming: incoming)
        return try JSONDecoder().decode(GestureConfig.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    /// Overlay `incoming` on `defaults`, recursing into nested objects (`shake`, `filter`),
    /// so a file missing one nested key still keeps that key's default.
    private static func mergeLenient(defaults: [String: Any], incoming: [String: Any]) -> [String: Any] {
        var merged = defaults
        for (key, value) in incoming {
            guard let existing = merged[key] else { continue }
            if let nestedDefaults = existing as? [String: Any], let nestedIncoming = value as? [String: Any] {
                merged[key] = mergeLenient(defaults: nestedDefaults, incoming: nestedIncoming)
            } else {
                merged[key] = value
            }
        }
        return merged
    }
}
