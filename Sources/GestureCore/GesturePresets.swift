import Foundation

/// A hand shape that acts like a button: it is either closed (pressed) or open. Click and drag
/// presets are built on these (see `PointerStateMachine+Presets.swift`).
public enum HandContact: String, Codable, CaseIterable {
    /// All four fingers curled.
    case fist
    /// Thumb tip on the index fingertip.
    case indexPinch
    /// Thumb tip on the middle fingertip (the pointing index finger barely moves).
    case middlePinch
    /// Finger gun: the thumb, held up, comes down against the side of the index finger.
    case thumbTrigger
}

/// How a click is made. Exactly one is active.
public enum ClickGesture: String, Codable, CaseIterable, Equatable {
    case wiggle
    case pinch
    case middlePinch
    case thumbTrigger
    case quickFist
    case dwell

    public var title: String {
        switch self {
        case .wiggle: return "Wiggle"
        case .pinch: return "Pinch (thumb + index)"
        case .middlePinch: return "Middle pinch (thumb + middle)"
        case .thumbTrigger: return "Thumb trigger (finger gun)"
        case .quickFist: return "Quick fist"
        case .dwell: return "Dwell (hold still)"
        }
    }

    public var summary: String {
        switch self {
        case .wiggle: return "Wiggle your finger left-right-left. Wiggle twice for a double click."
        case .pinch: return "Tap your thumb on your index fingertip. Two quick taps double-click."
        case .middlePinch: return "Tap your thumb on your middle fingertip; the pointing finger stays put, so the click lands exactly."
        case .thumbTrigger: return "Point like a finger gun, thumb up; bring the thumb down against your index finger to click."
        case .quickFist: return "Close your hand into a fist and open it again quickly."
        case .dwell: return "Hold the cursor still for a moment; the ring fills, then it clicks. Move away to click again."
        }
    }

    /// Short phrase for the menu's status line.
    public var hint: String {
        switch self {
        case .wiggle: return "wiggle to click"
        case .pinch: return "pinch to click"
        case .middlePinch: return "middle-pinch to click"
        case .thumbTrigger: return "thumb down to click"
        case .quickFist: return "quick fist to click"
        case .dwell: return "hold still to click"
        }
    }

    /// The contact that clicks (nil: not a contact gesture).
    public var contact: HandContact? {
        switch self {
        case .wiggle, .dwell: return nil
        case .pinch: return .indexPinch
        case .middlePinch: return .middlePinch
        case .thumbTrigger: return .thumbTrigger
        case .quickFist: return .fist
        }
    }
}

/// How a drag (button held down) is made. Exactly one is active.
public enum DragGesture: String, Codable, CaseIterable, Equatable {
    case fistHold
    case fistToggle
    case pinchHold
    case middlePinchHold
    case thumbTriggerHold
    case off

    public var title: String {
        switch self {
        case .fistHold: return "Hold a fist"
        case .fistToggle: return "Fist to grab, fist to drop"
        case .pinchHold: return "Hold a pinch"
        case .middlePinchHold: return "Hold a middle pinch"
        case .thumbTriggerHold: return "Hold the thumb trigger"
        case .off: return "Off"
        }
    }

    public var summary: String {
        switch self {
        case .fistHold: return "Make a fist and hold it a moment to grab; move; open your hand to drop."
        case .fistToggle: return "Make a fist to grab, open your hand and point to move, make a fist again to drop."
        case .pinchHold: return "Pinch thumb and index and hold to grab; move; let go to drop. A quick pinch is still a click if pinch clicks."
        case .middlePinchHold: return "Pinch thumb and middle finger and hold to grab; move; let go to drop."
        case .thumbTriggerHold: return "Hold the finger-gun thumb down to grab; move; lift it to drop."
        case .off: return "No dragging by hand."
        }
    }

    public var hint: String {
        switch self {
        case .fistHold: return "fist to drag"
        case .fistToggle: return "fist to grab / drop"
        case .pinchHold: return "hold a pinch to drag"
        case .middlePinchHold: return "hold a middle pinch to drag"
        case .thumbTriggerHold: return "hold the thumb down to drag"
        case .off: return ""
        }
    }

    public var contact: HandContact? {
        switch self {
        case .fistHold, .fistToggle: return .fist
        case .pinchHold: return .indexPinch
        case .middlePinchHold: return .middlePinch
        case .thumbTriggerHold: return .thumbTrigger
        case .off: return nil
        }
    }
}

/// How zoom is made. Zoom goes to apps as ⌘+/⌘− or ⌘-scroll (General settings).
public enum ZoomGesture: String, Codable, CaseIterable, Equatable {
    case off
    case twoFistSpread
    case twoPinchSpread
    case otherFistUpDown
    case otherPinchUpDown

    public var title: String {
        switch self {
        case .off: return "Off"
        case .twoFistSpread: return "Two fists, pull apart"
        case .twoPinchSpread: return "Two pinches, pull apart"
        case .otherFistUpDown: return "Other hand's fist, up / down"
        case .otherPinchUpDown: return "Other hand's pinch, up / down"
        }
    }

    public var summary: String {
        switch self {
        case .off: return "No zooming by hand."
        case .twoFistSpread: return "Make a fist with both hands; pull them apart to zoom in, together to zoom out."
        case .twoPinchSpread: return "Pinch with both hands; pull them apart to zoom in, together to zoom out."
        case .otherFistUpDown: return "Keep pointing; make a fist with the other hand and raise it to zoom in, lower it to zoom out."
        case .otherPinchUpDown: return "Keep pointing; pinch with the other hand and raise it to zoom in, lower it to zoom out."
        }
    }

    public var hint: String {
        switch self {
        case .off: return ""
        case .twoFistSpread: return "two fists to zoom"
        case .twoPinchSpread: return "two pinches to zoom"
        case .otherFistUpDown: return "other fist up/down to zoom"
        case .otherPinchUpDown: return "other pinch up/down to zoom"
        }
    }

    /// Both hands take part (the pointing hand can't click or drag meanwhile).
    var usesPointingHand: Bool { self == .twoFistSpread || self == .twoPinchSpread }

    /// The contact the zooming hand(s) make.
    var contact: HandContact? {
        switch self {
        case .off: return nil
        case .twoFistSpread, .otherFistUpDown: return .fist
        case .twoPinchSpread, .otherPinchUpDown: return .indexPinch
        }
    }
}

/// Thresholds for the pinch and thumb-trigger contacts, dwell clicks and zoom. Distances are in
/// hand sizes (wrist → middle MCP).
public struct ContactParams: Equatable, Codable {
    /// A pinch closes below this thumb-to-fingertip distance and opens above `pinchOpen`; the
    /// gap is the hysteresis that stops a borderline pinch from chattering.
    public var pinchClose = 0.3
    public var pinchOpen = 0.45
    /// The thumb trigger closes when the thumb tip comes within this of the index knuckle, and
    /// is open (cocked) once it is beyond `triggerOpen`.
    public var triggerClose = 0.5
    public var triggerOpen = 0.65
    /// A pinch or trigger must stay closed this long to count (accidental brushes don't).
    public var confirmTime = 0.05
    /// Held this long (pinch / trigger drags), the contact presses instead of clicking.
    public var holdToDragTime = 0.35
    /// When one contact both clicks and drags, a tap longer than this is neither.
    public var tapMaxDuration = 0.6
    /// Two contact clicks within this long at the same spot make a double click.
    public var doubleClickWindow = 0.5
    /// No new contact click this soon after the last one ends (bounce).
    public var refractoryTime = 0.12
    /// Dwell: hold the cursor within this fraction of the screen width…
    public var dwellRadiusBox = 0.012
    /// …for this long to click.
    public var dwellTime = 0.9
    /// Zoom: moving the zooming hand up by one hand size zooms in by this factor.
    public var zoomPerHandSize = 2.0

    public init() {}
}
