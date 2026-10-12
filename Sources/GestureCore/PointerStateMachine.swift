import Foundation

/// What the pointer is doing right now. Drives the overlay colour and the menu-bar icon.
public enum PointerState: String, Codable, Equatable {
    /// Not engaged: the real mouse is in charge and no input is generated.
    case idle
    /// Engaged but no hand is visible.
    case engaged
    /// Cursor follows the finger.
    case hover
    /// Fingers are closing toward a pinch.
    case pinchArmed
    /// Pinch is down; becomes a click on release or a drag on hold/move.
    case pinched
    case dragging
    case scrolling
    case zooming
    case switchingApps
    /// Velocity mode: the hand is in a fast segment (a flick that may become a click or scroll).
    case flicking
}

struct PointerSample {
    var time: Double
    var cursor: Point2
    var box: Point2
    var pinchDistance: Double
    var tipOffset: Point2
}

/// Read-only view of the machine after each step, for the overlay and HUD.
public struct PointerSnapshot: Equatable {
    public var state: PointerState = .idle
    public var isEngaged = false
    /// Where the cursor is (global points), when the machine is driving it.
    public var cursor: Point2?
    public var displayID: String?
    /// 0...1 as the fingers close (1 = pinch down).
    public var pinchProgress: Double = 0
    /// 0...1 while an open palm is held to toggle engagement.
    public var engageProgress: Double = 0
    /// 0...1 while hovering still with dwell-click enabled.
    public var dwellProgress: Double = 0
    /// 0...1 while the hand is held at a screen edge toward another display.
    public var displayJumpProgress: Double = 0
    public var hands: [HandFrame] = []
    public var primaryHandIndex: Int?
    public var pose: HandPose = .point
    public var outputSuppressed = false
    public var momentumActive = false
    public var inputModel: InputModel = .velocity
    /// Velocity mode: cursor positions since the current fast segment's anchor (empty when
    /// not in a segment), for the overlay's trail.
    public var segmentTrail: [Point2] = []
    /// Velocity mode: the most recent classified segment, for the "why not?" readout.
    public var lastSegment: SegmentReport?

    public init() {}
}

/// Intents for the OS plus events for feedback, produced by one step of the machine.
public struct StepOutput: Equatable {
    public var intents: [Intent] = []
    public var events: [PointerEvent] = []

    public init(intents: [Intent] = [], events: [PointerEvent] = []) {
        self.intents = intents
        self.events = events
    }

    mutating func append(_ other: StepOutput) {
        intents += other.intents
        events += other.events
    }
}

/// The gesture brain: tracking frames in, input intents out.
///
/// ```
/// idle ──palm hold / hotkey──▶ engaged ──hand seen──▶ hover ◀──────────────┐
///                                                      │ fingers close      │
///                                                      ▼                    │
///                                                  pinchArmed ──open───────▶┤
///                                                      │ pinch confirmed    │
///                                                      ▼                    │
///                                                   pinched ──release──▶ click
///                                                      │ hold 250 ms / move │
///                                                      ▼                    │
///                                                  dragging ──release──▶ up ┘
///  hover ──fist──▶ scrolling ──open──▶ momentum      two hands pinching ──▶ zooming
/// ```
///
/// All timing comes from frame timestamps, never the wall clock, so a replay reproduces a
/// live session exactly.
public final class PointerStateMachine {
    public internal(set) var config: GestureConfig
    public internal(set) var snapshot = PointerSnapshot()
    public private(set) var isEngaged = false
    public internal(set) var state: PointerState = .idle

    private var calibration: CalibrationSet
    var mapper: ActiveBoxMapper
    private var mapperDisplayID: String?
    var router: DisplayRouter
    var smoother: PointerSmoother
    private var scrollFilter: OneEuroFilter2D
    var momentum: ScrollMomentum

    // Hand slots: the pointing hand and an optional second hand (for zoom).
    private var primary: GestureDetector
    private var secondary: GestureDetector
    private var primaryLastPalm: Point2?
    private var secondaryLastPalm: Point2?
    private var primaryLastSeen: Double = -.infinity
    private var secondarySeen = false
    private var lastHandSeen: Double = -.infinity
    private var hadHandRecently = false

    // Pointer anchor hand-off (see `pointerReference`).
    private var anchorOffset: Point2?
    private var releaseBlend: (offset: Point2, start: Double)?

    // Cursor
    var cursor: Point2?
    var lastEmittedCursor: Point2?
    /// Recent pointer samples, for looking back to where the user was aiming before a pinch.
    var history: [PointerSample] = []
    var lastBox: Point2?

    // Pinch / click
    private var pinchFinger: PinchFinger?
    private var pinchStart: Double = 0
    private var clickPoint = Point2.zero
    private var clickBox = Point2.zero
    private var ignoreCurrentPinch = false
    /// True only between an emitted `.down` and its `.up`, so a drag that began while output was
    /// suppressed never sends an unmatched mouse-up.
    var buttonDown = false
    var lastClick: (time: Double, point: Point2, count: Int)?

    // Scroll
    private var scrollLastPalm: Point2?
    private var scrollLastTime: Double = 0
    private var scrollVelocity = Point2.zero
    private var scrollRemainder = Point2.zero

    // Zoom
    private var zoomLastDistance: Double?

    // App switcher
    private var switcherOriginX: Double = 0
    private var switcherSteps = 0

    // Engagement by palm
    private var palmHoldStart: Double?
    private var palmLatched = false
    private var palmSpeed: Double = 0
    private var palmSpeedLast: (time: Double, point: Point2)?

    // Dwell click
    private var dwellAnchor: (time: Double, point: Point2)?
    private var dwellLatched = false

    // Velocity mode (see PointerStateMachine+Velocity.swift).
    var velocityEngine: VelocityEngine
    /// Box-space offset added to the fingertip after the cursor was warped back to a segment's
    /// anchor, so the cursor stays where it was put instead of jumping back to the hand.
    var warpOffset = Point2.zero
    var lastRawBox: Point2?
    var trailAnchorTime: Double?

    // Real mouse takes priority.
    var outputSuppressedUntil: Double = -.infinity

    var lastTime: Double = 0

    public init(config: GestureConfig = .default,
                displays: [DisplayInfo] = [DisplayInfo(id: "main", frame: Rect(x: 0, y: 0, width: 1728, height: 1117))],
                calibration: CalibrationSet = CalibrationSet()) {
        self.config = config
        self.calibration = calibration
        self.router = DisplayRouter(displays: displays, dwell: config.displayJumpDwell)
        let displayID = displays.first?.id ?? "main"
        self.mapper = ActiveBoxMapper(profile: calibration.profile(for: displayID),
                                      boxScale: config.boxScale, edgeOvershoot: config.edgeOvershoot)
        self.mapperDisplayID = displayID
        self.smoother = PointerSmoother(config: config)
        self.scrollFilter = OneEuroFilter2D(config.filter)
        self.momentum = ScrollMomentum(friction: Self.momentumFriction(config), minSpeed: config.momentumMinSpeed)
        self.velocityEngine = VelocityEngine(params: config.velocity)
        self.primary = GestureDetector(config: Self.detectorConfig(config, calibration.profile(for: displayID)))
        self.secondary = GestureDetector(config: Self.detectorConfig(config, calibration.profile(for: displayID)))
        snapshot.displayID = displayID
    }

    // MARK: - Configuration

    /// Apply new settings. Switching the input model ends whatever the old model was doing
    /// (the returned intents release a held button), so nothing is left stuck.
    @discardableResult
    public func updateConfig(_ newConfig: GestureConfig) -> StepOutput {
        var out = StepOutput()
        if newConfig.inputModel != config.inputModel && isEngaged {
            out.append(cancelActiveGestures(at: lastTime))
            primary.reset()
            secondary.reset()
            history.removeAll()
            anchorOffset = nil
            releaseBlend = nil
        }
        config = newConfig
        router.dwell = newConfig.displayJumpDwell
        smoother.updateConfig(newConfig)
        scrollFilter.parameters = newConfig.filter
        momentum.updateParameters(friction: Self.momentumFriction(newConfig), minSpeed: newConfig.momentumMinSpeed)
        velocityEngine.updateParams(newConfig.velocity)
        rebuildMapper(force: true)
        refreshSnapshot(at: lastTime)
        return out
    }

    /// Pose mode uses its own friction setting; Velocity mode derives it from `momentumDecay`.
    static func momentumFriction(_ config: GestureConfig) -> Double {
        config.inputModel == .velocity ? config.velocity.momentumFriction : config.momentumFriction
    }

    public func setCalibration(_ set: CalibrationSet) {
        calibration = set
        rebuildMapper(force: true)
    }

    public func setDisplays(_ displays: [DisplayInfo]) {
        router.setDisplays(displays)
        rebuildMapper(force: true)
    }

    /// Calibration profiles carry per-user pinch thresholds; those override the config ones.
    private static func detectorConfig(_ config: GestureConfig, _ profile: CalibrationProfile) -> GestureConfig {
        var c = config
        if profile.isCalibrated {
            c.pinchEnter = profile.pinchEnter
            c.pinchExit = profile.pinchExit
        }
        return c
    }

    func rebuildMapper(force: Bool = false) {
        let id = router.current?.id ?? "main"
        guard force || id != mapperDisplayID else { return }
        let profile = calibration.profile(for: id)
        mapper = ActiveBoxMapper(profile: profile, boxScale: config.boxScale, edgeOvershoot: config.edgeOvershoot)
        mapperDisplayID = id
        primary.config = Self.detectorConfig(config, profile)
        secondary.config = Self.detectorConfig(config, profile)
        snapshot.displayID = id
    }

    // MARK: - External control

    /// Engage or disengage from outside (hotkey, menu). Always safe to call.
    public func setEngaged(_ engaged: Bool, reason: DisengageReason = .hotkey, at time: Double,
                           mouseLocation: Point2? = nil) -> StepOutput {
        var out = StepOutput()
        guard engaged != isEngaged else { return out }
        if engaged {
            isEngaged = true
            state = .engaged
            if let mouseLocation {
                router.focus(containing: mouseLocation)
                rebuildMapper()
            }
            smoother.reset()
            cursor = nil
            lastEmittedCursor = nil
            history.removeAll()
            resetVelocity()
            lastHandSeen = time
            hadHandRecently = false
            out.events.append(.engaged)
        } else {
            out.append(cancelActiveGestures(at: time))
            out.append(StepOutput(intents: momentum.stop()))
            isEngaged = false
            state = .idle
            cursor = nil
            out.events.append(.disengaged(reason))
        }
        palmHoldStart = nil
        palmLatched = true // the palm that toggled must open/close before it can toggle again
        refreshSnapshot(at: time)
        return out
    }

    /// The real mouse moved. Hand output pauses briefly so the user always wins, and the
    /// pointer moves to whichever display the mouse is on.
    public func noteExternalMouse(at location: Point2, time: Double) -> StepOutput {
        var out = StepOutput()
        let wasSuppressed = time < outputSuppressedUntil
        outputSuppressedUntil = time + 0.8
        router.focus(containing: location)
        rebuildMapper()
        if isEngaged && !wasSuppressed {
            out.events.append(.externalMouseTookOver)
        }
        if state == .dragging && config.inputModel == .velocity {
            // Same rule as below, but Velocity mode has no pinch to wait out: back to hover.
            if buttonDown {
                buttonDown = false
                out.intents.append(.up(x: location.x, y: location.y))
                out.events.append(.dragEnded)
            }
            velocityEngine.cancelDrag()
            state = .hover
        } else if state == .dragging {
            // Our synthetic button is still down, so the real mouse would drag whatever the
            // hand grabbed. Let go where the real mouse is (never warp it back), and treat the
            // rest of this pinch as a pause so its release does nothing.
            if buttonDown {
                buttonDown = false
                out.intents.append(.up(x: location.x, y: location.y))
                out.events.append(.dragEnded)
            }
            state = .pinched
            ignoreCurrentPinch = true
        }
        lastEmittedCursor = location
        return out
    }

    /// True while something between camera frames needs `tick(at:)` (a scroll glide). The app
    /// runs its tick timer only while this holds, so an engaged but still hand costs no timer.
    public var needsTicks: Bool { momentum.isActive }

    /// Drive time-based effects (scroll momentum) between camera frames.
    public func tick(at time: Double) -> StepOutput {
        let intents = momentum.tick(at: time)
        snapshot.momentumActive = momentum.isActive
        return StepOutput(intents: intents)
    }

    // MARK: - Frames

    public func process(_ frame: TrackingFrame) -> StepOutput {
        let time = frame.timestamp
        lastTime = time
        var out = StepOutput()

        let (primaryHand, secondaryHand, primaryReplaced) = assignHands(frame.hands, at: time)
        snapshot.hands = frame.hands
        if primaryReplaced && isEngaged {
            // A different hand took over the pointer (the old one left while another stayed in
            // view). Its detector was reset, so it will never report the old pinch or fist
            // ending: release whatever the old hand was holding now.
            out.append(cancelActiveGestures(at: time))
            anchorOffset = nil
            releaseBlend = nil
            history.removeAll()
        }

        // Engagement toggle by open palm, evaluated in every state.
        if let hand = primaryHand {
            // Velocity mode still runs the detector: the open palm is its one pose (engage).
            let events = primary.update(hand)
            if config.inputModel == .pose {
                out.append(handleDetectorEvents(events, isPrimary: true, hand: hand, at: time))
            }
            out.append(updatePalmEngagement(hand, at: time))
        }
        if let hand = secondaryHand {
            let events = secondary.update(hand)
            if config.inputModel == .pose {
                out.append(handleDetectorEvents(events, isPrimary: false, hand: hand, at: time))
            }
        } else if secondarySeen {
            // Second hand left: forget it, and end a zoom it was part of.
            secondarySeen = false
            secondaryLastPalm = nil
            secondary.reset()
            if state == .zooming && isEngaged && config.inputModel == .pose { out.append(endZoom()) }
        }

        guard isEngaged else {
            refreshSnapshot(at: time)
            return out
        }

        if let hand = primaryHand {
            lastHandSeen = time
            hadHandRecently = true
            if state == .engaged { state = .hover }
            if config.inputModel == .velocity {
                out.append(updatePointerVelocity(hand, secondary: secondaryHand, at: time))
            } else {
                out.append(updatePointer(hand, secondary: secondaryHand, at: time))
            }
        } else {
            out.append(handleMissingHand(at: time))
        }

        refreshSnapshot(at: time)
        return out
    }

    // MARK: Hand assignment

    /// Keeps the pointing hand stable across frames: nearest-neighbour to its last palm
    /// position, with the preferred hand (or the user's right-most hand) chosen when it is new.
    private func assignHands(_ hands: [HandFrame], at time: Double) -> (HandFrame?, HandFrame?, Bool) {
        guard !hands.isEmpty else { return (nil, nil, false) }
        var remaining = hands
        var primaryHand: HandFrame?
        var primaryReplaced = false

        let primaryRecentlySeen = time - primaryLastSeen <= max(config.handDropoutGrace, 0.3)
        if let last = primaryLastPalm, primaryRecentlySeen {
            let nearest = remaining.enumerated().min { $0.element.palmCenter.distance(to: last) < $1.element.palmCenter.distance(to: last) }
            // With one hand in view, a big jump is still that hand: a fast flick at 30 fps moves
            // the palm a third of the image between frames. With two, stay strict.
            let maxJump = hands.count == 1 ? 0.6 : 0.25
            if let nearest, nearest.element.palmCenter.distance(to: last) < maxJump {
                primaryHand = nearest.element
                remaining.remove(at: nearest.offset)
            }
        }
        if primaryHand == nil {
            let preferred = remaining.firstIndex { $0.chirality == config.preferredHand && config.preferredHand != .unknown }
            // Without a preference, take the hand on the user's right: the camera's left,
            // i.e. the smallest un-mirrored x.
            let index = preferred ?? remaining.indices.min { remaining[$0][.wrist].x < remaining[$1][.wrist].x }!
            primaryHand = remaining.remove(at: index)
            if primaryLastPalm != nil {
                primary.reset()
                primaryReplaced = true
            }
        }
        primaryLastPalm = primaryHand?.palmCenter
        primaryLastSeen = time

        var secondaryHand: HandFrame?
        if !remaining.isEmpty {
            if let last = secondaryLastPalm {
                secondaryHand = remaining.min { $0.palmCenter.distance(to: last) < $1.palmCenter.distance(to: last) }
            } else {
                secondaryHand = remaining.first
            }
            if !secondarySeen { secondary.reset() }
            secondarySeen = true
            secondaryLastPalm = secondaryHand?.palmCenter
        }
        return (primaryHand, secondaryHand, primaryReplaced)
    }

    // MARK: Engagement by palm

    private func updatePalmEngagement(_ hand: HandFrame, at time: Double) -> StepOutput {
        // Palm speed in hand sizes per second, lightly smoothed.
        let palm = hand.palmCenter
        if let last = palmSpeedLast, time > last.time {
            let moved = Point2(palm.x - last.point.x, (palm.y - last.point.y) / hand.imageAspect).length
        let instant = moved / hand.handSize / (time - last.time)
            palmSpeed += (instant - palmSpeed) * 0.4
        }
        palmSpeedLast = (time, palm)

        guard config.palmEngageEnabled else {
            palmHoldStart = nil
            return StepOutput()
        }
        let isPalm = primary.state.pose == .openPalm
        if !isPalm {
            palmLatched = false
            palmHoldStart = nil
            return StepOutput()
        }
        let busy = [.pinched, .dragging, .scrolling, .zooming, .switchingApps, .flicking].contains(state)
        guard !palmLatched, !busy, palmSpeed < config.palmStillnessNormalized else {
            palmHoldStart = nil
            return StepOutput()
        }
        if palmHoldStart == nil { palmHoldStart = time }
        let needed = isEngaged ? config.palmDisengageDuration : config.palmEngageDuration
        if time - (palmHoldStart ?? time) >= needed {
            let out = setEngaged(!isEngaged, reason: .palm, at: time)
            palmLatched = true
            return out
        }
        return StepOutput()
    }

    private func engageProgress(at time: Double) -> Double {
        guard let start = palmHoldStart else { return 0 }
        let needed = isEngaged ? config.palmDisengageDuration : config.palmEngageDuration
        return clamp01((time - start) / max(needed, 1e-6))
    }

    // MARK: Missing hand

    private func handleMissingHand(at time: Double) -> StepOutput {
        var out = StepOutput()
        let missingFor = time - lastHandSeen
        if missingFor > config.handDropoutGrace && hadHandRecently {
            // Brief dropouts are bridged; a real loss releases everything so nothing sticks.
            hadHandRecently = false
            out.append(cancelActiveGestures(at: time))
            primary.reset()
            anchorOffset = nil
            releaseBlend = nil
            history.removeAll()
            smoother.reset()
            state = .engaged
        }
        if missingFor > config.handLostTimeout {
            out.append(setEngaged(false, reason: .handLost, at: time))
        }
        return out
    }

    /// Ends any in-progress drag, scroll, zoom or app switch cleanly so no button or modifier
    /// is ever left held down.
    private func cancelActiveGestures(at time: Double) -> StepOutput {
        var out = StepOutput()
        switch state {
        case .dragging:
            out.append(releaseButton())
        case .scrolling:
            out.intents.append(.scroll(dx: 0, dy: 0, phase: .ended))
            out.events.append(.scrollEnded)
        case .zooming:
            out.append(endZoom())
        case .switchingApps:
            out.intents.append(.key(KeyStroke(.escape, modifiers: [.command])))
            out.intents.append(.key(KeyStroke(.command, action: .up)))
            out.events.append(.appSwitcherClosed)
        default:
            break
        }
        pinchFinger = nil
        ignoreCurrentPinch = false
        scrollLastPalm = nil
        // Any zoom end was emitted above; the engine's own copy would duplicate it.
        resetVelocity()
        if isEngaged { state = .engaged }
        return out
    }

    // MARK: Detector events

    private func handleDetectorEvents(_ events: [GestureDetector.Event], isPrimary: Bool,
                                      hand: HandFrame, at time: Double) -> StepOutput {
        var out = StepOutput()
        guard isEngaged else { return out }
        for event in events {
            switch event {
            case let .pinchBegan(finger, startTime):
                if isPrimary {
                    out.append(primaryPinchBegan(finger, startTime: startTime, hand: hand, at: time))
                } else if finger == .index {
                    out.append(maybeStartZoom(at: time))
                }
            case let .pinchEnded(finger):
                if isPrimary {
                    out.append(primaryPinchEnded(finger, at: time))
                } else if state == .zooming {
                    out.append(endZoom())
                    // The other hand is still pinching; its release must not click.
                    ignoreCurrentPinch = true
                    state = .hover
                }
            case let .poseChanged(pose):
                if isPrimary { out.append(primaryPoseChanged(pose, hand: hand, at: time)) }
            }
        }
        return out
    }

    private func primaryPinchBegan(_ finger: PinchFinger, startTime: Double, hand: HandFrame,
                                   at time: Double) -> StepOutput {
        var out = StepOutput(intents: momentum.stop())
        guard [.hover, .pinchArmed, .engaged].contains(state) else { return out }
        pinchFinger = finger
        pinchStart = startTime
        ignoreCurrentPinch = false
        let aim = closureStart(before: startTime)
        clickPoint = aim?.cursor ?? cursor ?? .zero
        clickBox = aim?.box ?? lastBox ?? .zero
        dwellAnchor = nil

        switch finger {
        case .index:
            state = .pinched
            if secondarySeen && secondary.state.pinch == .index {
                out.append(maybeStartZoom(at: time))
            }
        case .middle:
            state = .pinched
            if time >= outputSuppressedUntil {
                out.intents.append(.rightClick(x: clickPoint.x, y: clickPoint.y))
                out.events.append(.rightClicked)
            }
        case .ring:
            if config.appSwitcherEnabled && time >= outputSuppressedUntil {
                state = .switchingApps
                switcherOriginX = lastBox?.x ?? 0.5
                switcherSteps = 0
                out.intents.append(.key(KeyStroke(.command, action: .down)))
                out.intents.append(.key(KeyStroke(.tab, modifiers: [.command])))
                out.events.append(.appSwitcherOpened)
            } else {
                // Without the switcher a ring pinch is just a pause: freeze, no action.
                state = .pinched
                ignoreCurrentPinch = true
            }
        }
        return out
    }

    private func primaryPinchEnded(_ finger: PinchFinger, at time: Double) -> StepOutput {
        var out = StepOutput()
        defer {
            pinchFinger = nil
            ignoreCurrentPinch = false
        }
        let suppressed = time < outputSuppressedUntil
        switch state {
        case .pinched where finger == .index && !ignoreCurrentPinch:
            state = .hover
            guard !suppressed else { return out }
            var point = clickPoint
            var count = 1
            if let last = lastClick, time - last.time <= config.doubleClickInterval,
               point.distance(to: last.point) <= doubleClickRadiusPoints() {
                count = min(last.count + 1, 3)
                // Reuse the first click's exact position: macOS only counts a double click
                // when both clicks land on (nearly) the same pixel.
                point = last.point
            }
            out.intents.append(.click(x: point.x, y: point.y, count: count))
            out.events.append(.clicked(count: count))
            lastClick = (time, point, count)
        case .dragging:
            state = .hover
            out.append(releaseButton())
        case .switchingApps:
            state = .hover
            out.intents.append(.key(KeyStroke(.command, action: .up)))
            out.events.append(.appSwitcherClosed)
        case .zooming:
            out.append(endZoom())
            state = .hover
        case .pinched:
            state = .hover
        default:
            break
        }
        return out
    }

    /// Mouse-up for the drag in progress, only if its mouse-down was actually sent.
    func releaseButton() -> StepOutput {
        guard buttonDown else { return StepOutput() }
        buttonDown = false
        let p = cursor ?? clickPoint
        return StepOutput(intents: [.up(x: p.x, y: p.y)], events: [.dragEnded])
    }

    private func doubleClickRadiusPoints() -> Double {
        (router.current?.frame.width ?? 1500) * config.doubleClickRadiusBox
    }

    private func primaryPoseChanged(_ pose: HandPose, hand: HandFrame, at time: Double) -> StepOutput {
        var out = StepOutput()
        if pose == .fist && [.hover, .pinchArmed].contains(state) {
            out.intents += momentum.stop()
            state = .scrolling
            scrollFilter.reset(to: mapper.boxPoint(fromCamera: hand.palmCenter), at: time)
            scrollLastPalm = nil
            scrollVelocity = .zero
            scrollRemainder = .zero
            out.intents.append(.scroll(dx: 0, dy: 0, phase: .began))
            out.events.append(.scrollStarted)
        } else if pose != .fist && state == .scrolling {
            state = .hover
            out.intents.append(.scroll(dx: 0, dy: 0, phase: .ended))
            out.events.append(.scrollEnded)
            if config.momentumEnabled && scrollVelocity.length >= config.momentumStartSpeed {
                out.intents.append(momentum.start(velocity: scrollVelocity, at: time))
            }
            // Re-seed the pointer so the cursor does not leap after the hand reopens.
            if let c = cursor, let display = router.current {
                smoother.reset(to: ActiveBoxMapper.boxPoint(fromScreen: c, on: display), at: time)
            }
            anchorOffset = nil
            releaseBlend = nil
        }
        return out
    }

    // MARK: Zoom

    private func maybeStartZoom(at time: Double) -> StepOutput {
        guard config.zoomEnabled, state == .pinched, pinchFinger == .index,
              primary.state.pinch == .index, secondary.state.pinch == .index else { return StepOutput() }
        state = .zooming
        zoomLastDistance = nil
        return StepOutput(intents: [.zoom(factor: 1, phase: .began)], events: [.zoomStarted])
    }

    func endZoom() -> StepOutput {
        zoomLastDistance = nil
        if state == .zooming { state = .hover }
        ignoreCurrentPinch = true
        return StepOutput(intents: [.zoom(factor: 1, phase: .ended)], events: [.zoomEnded])
    }

    private func pinchPoint(_ hand: HandFrame) -> Point2 {
        hand[.thumbTip].lerp(to: hand[.indexTip], 0.5)
    }

    // MARK: Pointer

    /// The camera-space point that drives the cursor.
    ///
    /// Normally the index fingertip. But a pinch moves the fingertip toward the thumb, which
    /// would drag the cursor off its target just before clicking. So as soon as the fingers start
    /// closing ("armed"), the reference switches to the index MCP knuckle — which barely moves
    /// during a pinch — plus the fingertip offset captured at that moment, making the switch
    /// seamless. When the pinch fully opens again, the offset blends back to the fingertip over
    /// 200 ms so there is no jump either way.
    private func pointerReference(_ hand: HandFrame, at time: Double) -> Point2 {
        let tip = hand[.indexTip]
        let knuckle = hand[.indexMCP]
        let anchored = primary.state.armed || primary.state.pinch != nil
            || state == .dragging || state == .pinched || state == .zooming || state == .switchingApps
        if anchored {
            // Use the fingertip offset from the moment the fingers *started* closing: at 30 fps
            // a quick pinch is already half closed by the first armed frame.
            if anchorOffset == nil {
                anchorOffset = closureStart(before: time)?.tipOffset ?? (tip - knuckle)
            }
            releaseBlend = nil
            return knuckle + (anchorOffset ?? .zero)
        }
        if let offset = anchorOffset {
            // Leaving anchor mode: remember how far the anchored point is from the tip.
            releaseBlend = ((knuckle + offset) - tip, time)
            anchorOffset = nil
        }
        if let blend = releaseBlend {
            let t = (time - blend.start) / 0.2
            if t >= 1 {
                releaseBlend = nil
            } else {
                return tip + blend.offset * (1 - t)
            }
        }
        return tip
    }

    private func updatePointer(_ hand: HandFrame, secondary secondaryHand: HandFrame?, at time: Double) -> StepOutput {
        var out = StepOutput()
        let suppressed = time < outputSuppressedUntil

        if state == .hover || state == .pinchArmed {
            state = primary.state.armed ? .pinchArmed : .hover
        }

        // Scrolling uses the palm, not the pointer; the cursor stays put.
        if state == .scrolling {
            out.append(updateScroll(hand, at: time, suppressed: suppressed))
            return out
        }
        if state == .zooming, let other = secondaryHand {
            out.append(updateZoom(hand, other, suppressed: suppressed))
            return out
        }

        let reference = pointerReference(hand, at: time)
        let box = mapper.boxPoint(fromCamera: reference)
        lastBox = box

        if state == .hover || state == .pinchArmed || state == .dragging {
            if let jumped = router.update(box: box, at: time) {
                rebuildMapper()
                let newBox = mapper.boxPoint(fromCamera: reference)
                smoother.reset(to: newBox, at: time)
                out.events.append(.displayChanged(jumped.id))
            }
        }
        guard let display = router.current else { return out }

        let smoothed = smoother.process(mapper.boxPoint(fromCamera: reference), at: time)
        let screen = ActiveBoxMapper.screenPoint(fromBox: smoothed, on: display)
        cursor = screen
        let closest = primary.state.features?.closestPinch.distance ?? 1
        history.append(PointerSample(time: time, cursor: screen, box: smoothed, pinchDistance: closest,
                                     tipOffset: hand[.indexTip] - hand[.indexMCP]))
        history.removeAll { time - $0.time > Self.historySpan }

        switch state {
        case .pinched:
            // Freeze at the pinch-start position for a moment so the click lands where aimed.
            let held = time - pinchStart
            if pinchFinger == .index && !ignoreCurrentPinch {
                let moved = (smoothed - clickBox).length
                let pastFreeze = held >= config.clickFreezeDuration
                if held >= config.dragHoldDuration || (pastFreeze && moved >= config.dragStartDistanceBox) {
                    state = .dragging
                    if !suppressed {
                        out.intents.append(.down(x: clickPoint.x, y: clickPoint.y))
                        out.events.append(.dragStarted)
                        buttonDown = true
                        lastEmittedCursor = clickPoint
                    }
                    out.append(emitMove(screen, suppressed: suppressed))
                }
            } else if held >= config.clickFreezeDuration && pinchFinger != .middle {
                out.append(emitMove(screen, suppressed: suppressed))
            }
        case .switchingApps:
            out.append(updateAppSwitcher(box: smoothed, suppressed: suppressed))
        case .hover, .pinchArmed, .dragging:
            out.append(emitMove(screen, suppressed: suppressed))
            if state == .hover { out.append(updateDwell(screen, at: time, suppressed: suppressed)) }
        default:
            break
        }
        return out
    }

    func emitMove(_ p: Point2, suppressed: Bool) -> StepOutput {
        guard !suppressed else { return StepOutput() }
        if let last = lastEmittedCursor, last.distance(to: p) < 0.25 { return StepOutput() }
        lastEmittedCursor = p
        return StepOutput(intents: [.move(x: p.x, y: p.y)])
    }

    /// The sample from when the fingers began closing for the pinch that is under way at `time`:
    /// walk back while the fingers were further apart on the previous sample, up to 400 ms.
    /// The cursor drifts a little during that closure (the fingertip moves toward the thumb);
    /// this is where the user was actually aiming.
    private func closureStart(before time: Double) -> PointerSample? {
        guard var index = history.lastIndex(where: { $0.time <= time + 1e-9 }) else { return history.first }
        let limit = history[index].time - 0.4
        while index > 0 {
            let earlier = history[index - 1]
            guard earlier.time >= limit, earlier.pinchDistance > history[index].pinchDistance + 0.005 else { break }
            index -= 1
        }
        return history[index]
    }

    // MARK: Scroll

    private func updateScroll(_ hand: HandFrame, at time: Double, suppressed: Bool) -> StepOutput {
        let palmBox = scrollFilter.filter(mapper.boxPoint(fromCamera: hand.palmCenter), at: time)
        defer {
            scrollLastPalm = palmBox
            scrollLastTime = time
        }
        guard let last = scrollLastPalm, time > scrollLastTime else { return StepOutput() }
        let dt = time - scrollLastTime
        let direction = config.naturalScrolling ? 1.0 : -1.0
        let scale = config.scrollPointsPerBox * config.scrollSpeed * direction
        let delta = (palmBox - last) * scale + scrollRemainder
        // Velocity for momentum: an exponential average, so one shaky last frame does not
        // decide how far the content glides.
        let instant = (palmBox - last) * scale / dt
        scrollVelocity = scrollVelocity.lerp(to: instant, 0.35)
        // Sub-point deltas accumulate instead of being lost or sent as noise.
        if abs(delta.x) < 0.5 && abs(delta.y) < 0.5 {
            scrollRemainder = delta
            return StepOutput()
        }
        scrollRemainder = .zero
        guard !suppressed else { return StepOutput() }
        return StepOutput(intents: [.scroll(dx: delta.x, dy: delta.y, phase: .changed)])
    }

    // MARK: Zoom

    private func updateZoom(_ a: HandFrame, _ b: HandFrame, suppressed: Bool) -> StepOutput {
        // Distance between the two pinch points, normalized by mean hand size so moving both
        // hands toward the camera does not read as a zoom.
        let size = (a.handSize + b.handSize) / 2
        let pa = pinchPoint(a), pb = pinchPoint(b)
        let distance = Point2(pa.x - pb.x, (pa.y - pb.y) / a.imageAspect).length / size
        defer { zoomLastDistance = distance }
        guard let last = zoomLastDistance, last > 0 else { return StepOutput() }
        let factor = distance / last
        guard abs(log(factor)) > 0.004, !suppressed else {
            zoomLastDistance = last
            return StepOutput()
        }
        return StepOutput(intents: [.zoom(factor: factor, phase: .changed)])
    }

    // MARK: App switcher

    private func updateAppSwitcher(box: Point2, suppressed: Bool) -> StepOutput {
        // Bounded so a zero step setting or a far-off-box sample can never trap converting an
        // infinite or huge value to Int, or spin out thousands of Tab presses.
        let travel = clamp(box.x - switcherOriginX, -1, 1)
        let steps = Int((travel / max(config.appSwitcherStepBox, 0.01)).rounded(.towardZero))
        var out = StepOutput()
        guard !suppressed else { return out }
        while switcherSteps < steps {
            switcherSteps += 1
            out.intents.append(.key(KeyStroke(.tab, modifiers: [.command])))
        }
        while switcherSteps > steps {
            switcherSteps -= 1
            out.intents.append(.key(KeyStroke(.tab, modifiers: [.command, .shift])))
        }
        return out
    }

    // MARK: Dwell click

    func updateDwell(_ p: Point2, at time: Double, suppressed: Bool) -> StepOutput {
        guard config.dwellClickEnabled, !suppressed else {
            dwellAnchor = nil
            return StepOutput()
        }
        let radius = (router.current?.frame.width ?? 1500) * config.dwellRadiusBox
        guard let anchor = dwellAnchor, anchor.point.distance(to: p) <= radius else {
            dwellAnchor = (time, p)
            dwellLatched = false
            return StepOutput()
        }
        if !dwellLatched && time - anchor.time >= config.dwellClickDelay {
            dwellLatched = true
            return StepOutput(intents: [.click(x: anchor.point.x, y: anchor.point.y, count: 1)],
                              events: [.dwellClicked])
        }
        return StepOutput()
    }

    private func dwellProgress(at time: Double) -> Double {
        guard config.dwellClickEnabled, state == .hover, !dwellLatched, let anchor = dwellAnchor else { return 0 }
        // Show nothing for the first quarter so ordinary pauses do not flash the ring.
        let t = (time - anchor.time) / max(config.dwellClickDelay, 1e-6)
        return t < 0.25 ? 0 : clamp01((t - 0.25) / 0.75)
    }

    /// How much pointer history is kept: enough to find a velocity segment's anchor after the
    /// longest segment plus its exit time, and a pinch's closure start.
    static let historySpan = 1.0

    // MARK: Snapshot

    private func refreshSnapshot(at time: Double) {
        snapshot.state = state
        snapshot.isEngaged = isEngaged
        snapshot.cursor = isEngaged ? cursor : nil
        snapshot.displayID = router.current?.id
        snapshot.pinchProgress = isEngaged && config.inputModel == .pose ? primary.state.pinchProgress : 0
        snapshot.inputModel = config.inputModel
        snapshot.segmentTrail = segmentTrail()
        snapshot.engageProgress = engageProgress(at: time)
        snapshot.dwellProgress = dwellProgress(at: time)
        snapshot.displayJumpProgress = router.jumpProgress(at: time)
        snapshot.pose = primary.state.pose
        snapshot.outputSuppressed = time < outputSuppressedUntil
        snapshot.momentumActive = momentum.isActive
        if let palm = primaryLastPalm, time - primaryLastSeen < 0.01 {
            snapshot.primaryHandIndex = snapshot.hands.firstIndex { $0.palmCenter == palm }
        } else {
            snapshot.primaryHandIndex = nil
        }
    }
}
