import Foundation

/// Every tunable in the gesture pipeline. Codable so the settings window can export/import it
/// and so a replay can be re-run with exactly the settings it was recorded with.
///
/// Distances named `...Normalized` are divided by hand size (wrist → middle MCP).
/// Distances named `...Box` are in active-box units (1.0 = the full width of the screen).
public struct GestureConfig: Equatable, Codable {
    /// Hold & wiggle (dwell = click, wiggle = scroll) is the default; Velocity (flick = tap)
    /// and Pose (pinch/fist) stay available.
    public var inputModel: InputModel = .dwellShake
    /// Hold & wiggle thresholds.
    public var shake = ShakeParams()
    /// Velocity-mode thresholds (SPEC-M7).
    public var velocity = VelocityParams()

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

    // Pinch
    public var pinchEnter = 0.35
    public var pinchExit = 0.5
    /// Fingers closer than this "arm" the pinch: the pointer anchor switches from the fingertip
    /// to the palm so the click does not drift as the finger curls toward the thumb.
    public var pinchArm = 0.65
    public var pinchMinDuration = 0.06
    public var pinchRefractory = 0.12
    public var clickFreezeDuration = 0.10
    public var dragHoldDuration = 0.25
    public var dragStartDistanceBox = 0.012
    public var doubleClickInterval = 0.40
    public var doubleClickRadiusBox = 0.02
    /// A pinch must be this much smaller than the other fingers' pinches to be attributed to its
    /// finger; this stops a middle-finger pinch from also reading as an index pinch.
    public var pinchDominanceRatio = 0.75

    // Poses
    public var curlExtendedRatio = 1.45
    public var curlCurledRatio = 1.2
    public var poseConfirmDuration = 0.08

    // Engagement
    public var palmEngageEnabled = true
    public var palmEngageDuration = 0.6
    public var palmDisengageDuration = 0.8
    public var palmStillnessNormalized = 0.6   // max palm speed in hand sizes per second
    public var handLostTimeout = 2.0
    public var handDropoutGrace = 0.15

    // Scroll
    public var scrollSpeed = 1.0               // multiplier
    public var scrollPointsPerBox = 1600.0     // fist travel of one box width scrolls this much
    public var naturalScrolling = true
    public var momentumEnabled = true
    public var momentumFriction = 4.0          // 1/s exponential decay rate
    public var momentumMinSpeed = 40.0         // points/s below which momentum stops
    public var momentumStartSpeed = 120.0      // release speed needed to start momentum

    // Zoom
    public var zoomEnabled = true

    // App switcher (thumb + ring)
    public var appSwitcherEnabled = false
    public var appSwitcherStepBox = 0.08

    // Multi-display
    public var displayJumpDwell = 0.4

    // Dwell click
    public var dwellClickEnabled = false
    public var dwellClickDelay = 0.8
    public var dwellRadiusBox = 0.008

    // Hand preference for the pointing hand when two are visible.
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

    /// Overlay `incoming` on `defaults`, recursing into nested objects (`velocity`, `filter`),
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
