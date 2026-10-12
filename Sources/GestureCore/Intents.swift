import Foundation

/// Scroll phases, mirroring the trackpad model macOS apps expect: a gesture phase while the
/// fist is moving, then a separate momentum phase after release.
public enum ScrollPhase: String, Codable, Equatable {
    case began, changed, ended
    case momentumBegan, momentumChanged, momentumEnded
}

public enum ZoomPhase: String, Codable, Equatable {
    case began, changed, ended
}

/// Keys GestureCore may ask for. Deliberately tiny: the Mac layer maps each to a virtual key code.
public enum VirtualKey: String, Codable, Equatable {
    case tab, escape, equal, minus, command, shift
}

public struct KeyModifiers: OptionSet, Codable, Equatable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
}

public enum KeyAction: String, Codable, Equatable {
    case down, up, press
}

public struct KeyStroke: Equatable, Codable {
    public var key: VirtualKey
    public var modifiers: KeyModifiers
    public var action: KeyAction

    public init(_ key: VirtualKey, modifiers: KeyModifiers = [], action: KeyAction = .press) {
        self.key = key
        self.modifiers = modifiers
        self.action = action
    }
}

/// What GestureCore asks the operating system to do. Coordinates are global display points
/// with a top-left origin. The Mac layer (`InputSynth`) is a dumb, faithful translator of these.
public enum Intent: Equatable {
    /// Move the cursor. While the left button is down this becomes a drag.
    case move(x: Double, y: Double)
    /// Left button down / up (dragging).
    case down(x: Double, y: Double)
    case up(x: Double, y: Double)
    /// Complete left click. `count` 2 is a double click (sets the click-state field).
    case click(x: Double, y: Double, count: Int)
    case rightClick(x: Double, y: Double)
    /// Content-movement deltas in points: positive dx moves content right, positive dy moves
    /// content down (the natural-scrolling convention; the direction setting is applied in core).
    case scroll(dx: Double, dy: Double, phase: ScrollPhase)
    /// Multiplicative zoom since the previous zoom intent (1.1 = 10% larger).
    case zoom(factor: Double, phase: ZoomPhase)
    case key(KeyStroke)
}

/// Things that happened, for feedback (sounds, toasts, menu icon) rather than for input.
public enum PointerEvent: Equatable {
    case engaged
    case disengaged(DisengageReason)
    case clicked(count: Int)
    case rightClicked
    case dragStarted
    case dragEnded
    case scrollStarted
    case scrollEnded
    case zoomStarted
    case zoomEnded
    case appSwitcherOpened
    case appSwitcherClosed
    case displayChanged(String)
    case dwellClicked
    case externalMouseTookOver
    /// Velocity mode: a fast segment was classified (including "nothing"), for the overlay's
    /// result flash, the "why not?" readout and `tune`.
    case segmentClassified(SegmentReport)
}

public enum DisengageReason: String, Equatable, Codable {
    case palm, hotkey, handLost, menu
}
