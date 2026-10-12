import Foundation

/// Scroll phases, mirroring the trackpad model macOS apps expect: a gesture phase, then a
/// separate momentum phase (the glide).
public enum ScrollPhase: String, Codable, Equatable {
    case began, changed, ended
    case momentumBegan, momentumChanged, momentumEnded
}

public enum ZoomPhase: String, Codable, Equatable {
    case began, changed, ended
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
    /// Content-movement deltas in points: positive dx moves content right, positive dy moves
    /// content down (the natural-scrolling convention; the direction setting is applied in core).
    case scroll(dx: Double, dy: Double, phase: ScrollPhase)
    /// Multiplicative zoom since the previous zoom intent (1.1 = 10% larger).
    case zoom(factor: Double, phase: ZoomPhase)
}

/// Things that happened, for feedback (sounds, toasts, menu icon) rather than for input.
public enum PointerEvent: Equatable {
    case engaged
    case disengaged(DisengageReason)
    case clicked(count: Int)
    case dragStarted
    case dragEnded
    case scrollStarted
    case scrollEnded
    case zoomStarted
    case zoomEnded
    case displayChanged(String)
    case externalMouseTookOver
}

public enum DisengageReason: String, Equatable, Codable {
    case palm, hotkey, handLost, menu
}
