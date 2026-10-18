import Foundation

/// Every tunable in the gesture pipeline. Codable so the settings window can export/import it
/// and so a replay can be re-run with exactly the settings it was recorded with.
///
/// Distances named `...Normalized` are divided by hand size (wrist → middle MCP).
/// Distances named `...Box` are in active-box units (1.0 = the full width of the screen).
public struct GestureConfig: Equatable, Codable {
    /// Lock, wiggle click, fist drag and two-fist thresholds.
    public var shake = ShakeParams()

    // Gesture presets: which hand shape clicks, drags and zooms (exactly one of each).
    public var clickGesture: ClickGesture = .wiggle
    public var dragGesture: DragGesture = .fistHold
    public var zoomGesture: ZoomGesture = .off
    /// Pinch / thumb-trigger / dwell / zoom thresholds for those presets.
    public var contact = ContactParams()

    // Pointer filtering. The cursor is a laser pointer: it goes exactly where the fingertip
    // points (through the calibration), at every speed. These only decide how much tracker
    // jitter is smoothed away; `steadiness` sets all of them from one slider.
    public var filter = OneEuroParameters(minCutoff: 0.6, beta: 14.0, derivativeCutoff: 1.0)
    /// Dead zone while moving: the cursor trails the filtered point by at most this much, which
    /// at any real speed is a fraction of one frame of motion.
    public var deadZoneBox = 0.001
    /// Dead zone once the cursor has rested for `restLockDelay`: residual jitter of a still hand
    /// stays below this, which is what makes the cursor *rock steady*.
    public var restDeadZoneBox = 0.005
    public var restLockDelay = 0.2
    /// Sensitivity: scale of the active box (smaller = less hand motion per screen).
    public var boxScale = 1.0
    public var edgeOvershoot = 0.04
    /// Cursor speed vs hand speed (presets to try). `.direct` is the laser pointer.
    public var pointerResponse: PointerResponse = .direct
    /// Slow down near, and pull into, the buttons and links the hand is reaching for.
    public var assist = TargetAssistParams()

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
    /// A hand missing for longer than this ends a drag (so the button never sticks). Wisp stays
    /// engaged however long the hand is gone: only the palms, the hotkey or the menu turn it off.
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
    /// One knob for all the pointer smoothing, 0 (snappy: least lag, a little jitter) … 1 (steady:
    /// no jitter, a little lag on slow moves). 0.5 is the default tuning. Reading it back gives the
    /// position the current filter corresponds to.
    ///
    /// Tuned on the owner's recording and on a still hand with 0.003 box (≈5 pt) of tracker noise
    /// per frame: at 0.5 the resting cursor moves about 6 pt in 5 s, and a moving cursor is a
    /// median 17 pt behind the hand.
    public var steadiness: Double {
        get { clamp01(log(filter.minCutoff / Self.snappyMinCutoff) / log(Self.steadyMinCutoff / Self.snappyMinCutoff)) }
        set {
            let s = clamp01(newValue.isFinite ? newValue : 0.5)
            filter.minCutoff = Self.snappyMinCutoff * pow(Self.steadyMinCutoff / Self.snappyMinCutoff, s)
            filter.beta = 20 - 12 * s
            restDeadZoneBox = 0.003 + 0.004 * s
        }
    }

    static let snappyMinCutoff = 1.2
    static let steadyMinCutoff = 0.3

    /// The pointer smoothing back at its defaults (reach and gestures untouched).
    public mutating func resetPointerTuning() {
        let defaults = GestureConfig()
        filter = defaults.filter
        deadZoneBox = defaults.deadZoneBox
        restDeadZoneBox = defaults.restDeadZoneBox
        restLockDelay = defaults.restLockDelay
        pointerResponse = defaults.pointerResponse
    }

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
