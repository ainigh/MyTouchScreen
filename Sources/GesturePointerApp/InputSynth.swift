#if canImport(AppKit)
import CoreGraphics
import Foundation
import GestureCore
import QuartzCore

/// How two-hand zoom is delivered to apps.
enum ZoomStyle: String, CaseIterable, Codable {
    /// ⌘= / ⌘− key presses: works in browsers, Preview, Pages, Finder, most document apps.
    case keyboard
    /// ⌘ + scroll wheel: smoother in apps that support it (maps, design tools).
    case commandScroll

    var label: String {
        switch self {
        case .keyboard: return "⌘+ / ⌘− keys"
        case .commandScroll: return "⌘ + scroll"
        }
    }
}

/// Translates GestureCore intents into CGEvents posted to the HID event tap.
///
/// Thread-safe in the sense that matters here: it is only ever called from the pipeline's
/// serial queue. CGEvent creation and posting do not require the main thread.
final class InputSynth {
    /// Stamped into every event we post (`eventSourceUserData`) so our own events can be told
    /// apart from the user's real mouse. ASCII "WISP".
    static let eventMarker: Int64 = 0x5749_5350

    private let source: CGEventSource?
    private var leftButtonDown = false
    private var commandHeld = false
    private var scrollRemainder = (dx: 0.0, dy: 0.0)
    private var zoomLogAccumulator = 0.0
    private var lastLocation: CGPoint?

    var zoomStyle: ZoomStyle = .keyboard
    /// When false, intents are only logged (used by `--replay --dry-run`).
    var postsEvents = true
    var log: ((String) -> Void)?

    /// Recent cursor positions we posted, readable from any thread, so the main thread's
    /// mouse monitor can recognise our own events even if the user-data marker is lost.
    private let recentLock = NSLock()
    private var recentPosts: [(time: Double, point: CGPoint)] = []

    init() {
        source = CGEventSource(stateID: .hidSystemState)
        // By default, posting a synthetic event suppresses the real mouse and keyboard for
        // 0.25 s. The user's own input must always win, so turn that off.
        source?.localEventsSuppressionInterval = 0
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
    }

    // MARK: Intents

    func perform(_ intent: Intent) {
        log?(String(describing: intent))
        guard postsEvents else { return }
        switch intent {
        case let .move(x, y):
            let p = CGPoint(x: x, y: y)
            postMouse(leftButtonDown ? .leftMouseDragged : .mouseMoved, at: p, button: .left)
        case let .down(x, y):
            let p = CGPoint(x: x, y: y)
            postMouse(.leftMouseDown, at: p, button: .left)
            leftButtonDown = true
        case let .up(x, y):
            postMouse(.leftMouseUp, at: CGPoint(x: x, y: y), button: .left)
            leftButtonDown = false
        case let .click(x, y, count):
            let p = CGPoint(x: x, y: y)
            postMouse(.leftMouseDown, at: p, button: .left, clickState: Int64(count))
            postMouse(.leftMouseUp, at: p, button: .left, clickState: Int64(count))
        case let .rightClick(x, y):
            let p = CGPoint(x: x, y: y)
            postMouse(.rightMouseDown, at: p, button: .right)
            postMouse(.rightMouseUp, at: p, button: .right)
        case let .scroll(dx, dy, phase):
            postScroll(dx: dx, dy: dy, phase: phase)
        case let .zoom(factor, phase):
            postZoom(factor: factor, phase: phase)
        case let .key(stroke):
            postKey(stroke)
        }
    }

    /// Release anything we are holding (mouse button, ⌘). Called on disengage and quit, so a
    /// crash-free exit can never leave the system with a stuck button or modifier.
    func releaseAll() {
        guard postsEvents else { return }
        if leftButtonDown, let p = lastLocation ?? CGEvent(source: nil)?.location {
            postMouse(.leftMouseUp, at: p, button: .left)
            leftButtonDown = false
        }
        if commandHeld {
            postKeyCode(KeyCode.command, down: false, flags: [])
            commandHeld = false
        }
    }

    // MARK: Mouse

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int64 = 1) {
        guard point.x.isFinite, point.y.isFinite else { return }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        if let last = lastLocation, type == .mouseMoved || type == .leftMouseDragged {
            // Relative deltas, for apps (and games) that read motion rather than position.
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - last.x).rounded()))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - last.y).rounded()))
        }
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        event.post(tap: .cghidEventTap)
        lastLocation = point
        let now = CACurrentMediaTime()
        recentLock.lock()
        recentPosts.append((now, point))
        recentPosts.removeAll { now - $0.time > 0.5 }
        recentLock.unlock()
    }

    /// True if we posted a mouse event at (about) this location in the last half second.
    func isOwnEvent(at location: CGPoint) -> Bool {
        let now = CACurrentMediaTime()
        recentLock.lock()
        defer { recentLock.unlock() }
        return recentPosts.contains { now - $0.time <= 0.5 && abs($0.point.x - location.x) < 2 && abs($0.point.y - location.y) < 2 }
    }

    // MARK: Scroll

    // Values of CGScrollPhase / CGMomentumScrollPhase, spelled out so the mapping is explicit.
    private enum PhaseValue {
        static let none: Int64 = 0
        static let began: Int64 = 1
        static let changed: Int64 = 2
        static let ended: Int64 = 4
        static let momentumBegin: Int64 = 1
        static let momentumContinue: Int64 = 2
        static let momentumEnd: Int64 = 3
    }

    private func postScroll(dx: Double, dy: Double, phase: ScrollPhase, flags: CGEventFlags = []) {
        // Pixel scroll events carry integers; keep the fractions for the next event so slow
        // scrolling is smooth instead of stalling.
        let totalX = dx + scrollRemainder.dx
        let totalY = dy + scrollRemainder.dy
        guard totalX.isFinite, totalY.isFinite else { return }
        let wheelX = min(max(totalX, -10_000), 10_000).rounded(.towardZero)
        let wheelY = min(max(totalY, -10_000), 10_000).rounded(.towardZero)
        scrollRemainder = (totalX - wheelX, totalY - wheelY)
        if phase == .began || phase == .ended || phase == .momentumEnded { scrollRemainder = (0, 0) }

        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(wheelY), wheel2: Int32(wheelX),
                                  wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        var scrollPhase = PhaseValue.none
        var momentumPhase = PhaseValue.none
        switch phase {
        case .began: scrollPhase = PhaseValue.began
        case .changed: scrollPhase = PhaseValue.changed
        case .ended: scrollPhase = PhaseValue.ended
        case .momentumBegan: momentumPhase = PhaseValue.momentumBegin
        case .momentumChanged: momentumPhase = PhaseValue.momentumContinue
        case .momentumEnded: momentumPhase = PhaseValue.momentumEnd
        }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        if !flags.isEmpty { event.flags = flags }
        event.post(tap: .cghidEventTap)
    }

    // MARK: Zoom

    private func postZoom(factor: Double, phase: ZoomPhase) {
        switch zoomStyle {
        case .commandScroll:
            let scrollPhase: ScrollPhase = phase == .began ? .began : (phase == .ended ? .ended : .changed)
            // ~8 points of scroll per 1% of zoom feels proportional in apps that zoom on ⌘-scroll.
            postScroll(dx: 0, dy: Foundation.log(factor) * 800, phase: scrollPhase, flags: .maskCommand)
        case .keyboard:
            if phase != .changed {
                zoomLogAccumulator = 0
                return
            }
            // One ⌘= / ⌘− per 18% change in hand spread, which matches typical zoom steps.
            zoomLogAccumulator += Foundation.log(factor)
            let step = Foundation.log(1.18)
            while zoomLogAccumulator >= step {
                zoomLogAccumulator -= step
                postKeyPress(KeyCode.equal, flags: .maskCommand)
            }
            while zoomLogAccumulator <= -step {
                zoomLogAccumulator += step
                postKeyPress(KeyCode.minus, flags: .maskCommand)
            }
        }
    }

    // MARK: Keys

    /// Virtual key codes (kVK_* from HIToolbox's Events.h, ANSI layout).
    enum KeyCode {
        static let tab: CGKeyCode = 0x30
        static let escape: CGKeyCode = 0x35
        static let equal: CGKeyCode = 0x18
        static let minus: CGKeyCode = 0x1B
        static let command: CGKeyCode = 0x37
        static let shift: CGKeyCode = 0x38
    }

    private func keyCode(for key: VirtualKey) -> CGKeyCode {
        switch key {
        case .tab: return KeyCode.tab
        case .escape: return KeyCode.escape
        case .equal: return KeyCode.equal
        case .minus: return KeyCode.minus
        case .command: return KeyCode.command
        case .shift: return KeyCode.shift
        }
    }

    private func flags(for modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) || commandHeld { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        return flags
    }

    private func postKey(_ stroke: KeyStroke) {
        let code = keyCode(for: stroke.key)
        if stroke.key == .command {
            // Holding ⌘ (app switcher): the modifier state lives in the HID system state.
            switch stroke.action {
            case .down:
                commandHeld = true
                postKeyCode(code, down: true, flags: .maskCommand)
            case .up:
                commandHeld = false
                postKeyCode(code, down: false, flags: [])
            case .press:
                postKeyCode(code, down: true, flags: .maskCommand)
                postKeyCode(code, down: false, flags: [])
            }
            return
        }
        let eventFlags = flags(for: stroke.modifiers)
        switch stroke.action {
        case .down: postKeyCode(code, down: true, flags: eventFlags)
        case .up: postKeyCode(code, down: false, flags: eventFlags)
        case .press: postKeyPress(code, flags: eventFlags)
        }
    }

    private func postKeyPress(_ code: CGKeyCode, flags: CGEventFlags) {
        postKeyCode(code, down: true, flags: flags)
        postKeyCode(code, down: false, flags: flags)
    }

    private func postKeyCode(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        event.post(tap: .cghidEventTap)
    }
}
#endif
