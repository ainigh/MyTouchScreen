import Foundation

/// Which input model drives clicks and scrolls.
///
/// - `dwellShake` (default, "Hold & wiggle"): every movement moves the cursor; holding still for
///   2 s clicks; wiggling back and forth 3 times within 1 s starts scrolling.
/// - `velocity`: the hand is a mouse. A short flick from stillness is a tap (click), a long
///   vertical flick is a scroll; no finger pose is needed for anything but engaging (SPEC-M7).
/// - `pose`: the original model: pinch to click/drag, fist to scroll, two pinches to zoom.
public enum InputModel: String, Codable, CaseIterable, Equatable {
    case dwellShake, velocity, pose
}

/// Which tap direction is the left click in Velocity mode.
public enum ClickAxis: String, Codable, CaseIterable, Equatable {
    /// Up/down tap = left click, sideways tap = right click.
    case vertical
    /// Sideways tap = left click, up/down tap = right click.
    case horizontal
    /// A tap in any direction is a left click; right click by tap is unavailable.
    case any
}

/// Every Velocity-mode tunable (SPEC-M7 → Parameters).
///
/// Units: velocities are hand-space units per second (hand space = camera image, mirrored,
/// measured in fractions of the image width on both axes); displacements are multiples of
/// `handSize` (wrist → middle MCP); times are seconds. Frame counts are converted to time at a
/// 60 Hz reference rate (`enterTime`, `exitTime`) so 30 fps and 60 fps cameras behave alike.
public struct VelocityParams: Equatable, Codable {
    public var vEnter = 0.9
    public var vExit = 0.45
    public var framesEnter = 2
    /// Spec default is 2; 4 (67 ms) because a tap reverses direction at its lowest point and
    /// the speed dips below `vExit` for ~2 frames there. See DECISIONS.md.
    public var framesExit = 4
    public var maxSegment = 0.45

    public var clickMaxDuration = 0.18
    public var clickMaxDisp = 0.9
    public var clickMaxPath = 1.6
    public var preClickStillV = 0.25
    public var preClickStillTime = 0.08

    public var scrollMinDisp = 1.6
    public var scrollMinPeak = 1.8
    public var returnFraction = 0.5
    /// Scroll speed in points per second for each hand-space unit per second of peak speed.
    public var scrollGain = 900.0
    /// Momentum keeps this fraction of its speed per 1/60 s (converted to a continuous rate).
    public var momentumDecay = 0.92

    public var axisRatio = 1.8

    public var doubleClickWindow = 0.30
    public var doubleClickDisp = 0.5

    public var dragStartWindow = 0.35
    public var dragMoveMin = 0.30
    /// How long movement above `dragMoveMin` must last before it is a drag rather than the
    /// start of the next tap (a tap's speed passes through `dragMoveMin` on its way up).
    public var dragConfirmTime = 0.10
    public var dragStillV = 0.12
    public var dragStillTime = 0.40

    public var twoHandWindow = 0.15
    public var coherenceAngle = 60.0
    public var glitchDisp = 2.5
    public var refractory = 0.12
    public var minConfidence = 0.5

    // Behaviour switches (Settings → Gestures).
    public var clickAxis: ClickAxis = .vertical
    public var rightClickEnabled = true
    public var dragEnabled = true

    public init() {}

    public static let `default` = VelocityParams()

    /// Frame counts are specified at this rate and converted to time.
    public static let referenceRate = 60.0

    /// Time a fast run must span (as frames × period) before a segment starts.
    public var enterTime: Double { Double(max(framesEnter, 1)) / Self.referenceRate }
    /// Time the speed must stay below `vExit` before a segment ends.
    public var exitTime: Double { Double(max(framesExit, 1)) / Self.referenceRate }
    /// `momentumDecay` per reference frame as a continuous decay rate (1/s), so the glide is
    /// the same whatever the tick rate.
    public var momentumFriction: Double {
        let decay = min(max(momentumDecay, 0.01), 0.999)
        return -log(decay) * Self.referenceRate
    }
}
