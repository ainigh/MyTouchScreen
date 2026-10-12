import Foundation

/// What the pointer is doing.
public enum PointerState: String, Codable, Equatable {
    /// Not engaged: the real mouse is in charge and no input is generated.
    case idle
    /// Engaged but no hand is visible.
    case engaged
    /// The cursor follows the finger (or is locked, waiting for a wiggle or a fist).
    case hover
    /// A fist pressed the button and the cursor follows it.
    case dragging
    /// Both hands are fists; when they rest, their last stroke zooms or scrolls.
    case twoFists
}

/// Read-only view of the machine after each step, for the overlay and HUD.
public struct PointerSnapshot: Equatable {
    public var state: PointerState = .idle
    public var isEngaged = false
    /// Where the cursor is (global points), when the machine is driving it.
    public var cursor: Point2?
    public var displayID: String?
    /// 0...1 while both open palms are held to toggle engagement.
    public var engageProgress: Double = 0
    /// The lock ring: fills while the cursor settles, 1 while locked, drains through the wake
    /// window (the second in which a wiggle clicks and a fist presses).
    public var lockProgress: Double = 0
    /// 0...1 while the hand is held at a screen edge toward another display.
    public var displayJumpProgress: Double = 0
    public var hands: [HandFrame] = []
    public var primaryHandIndex: Int?
    public var pose: HandPose = .point
    public var outputSuppressed = false
    public var momentumActive = false

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

/// The gesture brain: tracking frames in, input intents out (see PointerStateMachine+Shake.swift
/// for the gestures).
///
/// ```
/// idle ──both palms / hotkey──▶ engaged ──hand seen──▶ hover ──rest 1 s──▶ locked
///                                                        ▲                   │ move: 1 s window
///                                                        │                   ├─ wiggle ──▶ click (stays locked)
///                                                        │                   ├─ fist ───▶ dragging ──open──▶ drop
///                                                        └──── window ends ──┘
///  hover ──two fists──▶ twoFists ──rest──▶ zoom / scroll by the last stroke
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
    var momentum: ScrollMomentum

    // Hand slots: the pointing hand and the other hand (two-hand gestures only).
    var primary: GestureDetector
    var secondary: GestureDetector
    var primaryLastPalm: Point2?
    var primaryLastSeen: Double = -.infinity
    private var secondarySeen = false
    private var lastHandSeen: Double = -.infinity
    private var hadHandRecently = false

    // Cursor
    var cursor: Point2?
    var lastEmittedCursor: Point2?
    var lastBox: Point2?
    /// Box-space offset added to the tracked point so the cursor starts a drag exactly where
    /// the button went down (the palm sits below the fingertip) or carries on after a lock.
    var warpOffset = Point2.zero
    var lastRawBox: Point2?
    /// True only between an emitted `.down` and its `.up`, so a drag that began while output was
    /// suppressed never sends an unmatched mouse-up.
    var buttonDown = false
    var lastClick: (time: Double, point: Point2, count: Int)?

    // Engagement by palms
    private var palmHoldStart: Double?
    private var palmLatched = false
    private var palmSpeed: Double = 0
    private var palmSpeedLast: (time: Double, point: Point2)?
    private var secondaryPalmSpeed: Double = 0
    private var secondaryPalmSpeedLast: (time: Double, point: Point2)?
    private var notBothPalmsSince: Double?
    private static let palmPairGrace = 0.3
    /// Both hands are open palms this frame: the engage / disengage gesture, so nothing else
    /// may act on them.
    var bothPalmsOpen = false

    // Lock, click, drag, two fists (see PointerStateMachine+Shake.swift).
    /// Where and since when the cursor has been still (toward a lock).
    var dwellAnchor: (time: Double, point: Point2)?
    var cursorLock: CursorLock?
    var shakeDetector: ShakeDetector
    var twoFists: TwoFistGesture?
    var twoFistsGoneSince: Double?
    var tipSpeed: Double = 0
    var lastTip: (time: Double, point: Point2)?

    /// Where the real mouse pointer is, kept up to date by the app while disengaged, so a palm
    /// engage can start on that display.
    public var realMouseLocation: Point2?

    // Real mouse takes priority.
    var outputSuppressedUntil: Double = -.infinity

    var lastTime: Double = 0

    public init(config: GestureConfig = .default,
                displays: [DisplayInfo] = [DisplayInfo(id: "main", frame: Rect(x: 0, y: 0, width: 1728, height: 1117))],
                calibration: CalibrationSet = CalibrationSet()) {
        self.config = config
        self.calibration = calibration
        self.router = DisplayRouter(displays: displays, dwell: config.displayJumpDwell)
        self.router.locked = config.stayOnEngagedDisplay
        let displayID = displays.first?.id ?? "main"
        self.mapper = ActiveBoxMapper(profile: calibration.profile(for: displayID),
                                      boxScale: config.boxScale, edgeOvershoot: config.edgeOvershoot)
        self.mapperDisplayID = displayID
        self.smoother = PointerSmoother(config: config)
        self.momentum = ScrollMomentum(friction: config.momentumFriction, minSpeed: config.momentumMinSpeed)
        self.shakeDetector = ShakeDetector(params: config.shake)
        self.primary = GestureDetector(config: config)
        self.secondary = GestureDetector(config: config)
        snapshot.displayID = displayID
    }

    // MARK: - Configuration

    /// Apply new settings.
    @discardableResult
    public func updateConfig(_ newConfig: GestureConfig) -> StepOutput {
        config = newConfig
        router.dwell = newConfig.displayJumpDwell
        router.locked = newConfig.stayOnEngagedDisplay
        smoother.updateConfig(newConfig)
        momentum.updateParameters(friction: newConfig.momentumFriction, minSpeed: newConfig.momentumMinSpeed)
        primary.config = newConfig
        secondary.config = newConfig
        rebuildMapper(force: true)
        refreshSnapshot(at: lastTime)
        return StepOutput()
    }

    public func setCalibration(_ set: CalibrationSet) {
        calibration = set
        rebuildMapper(force: true)
    }

    public func setDisplays(_ displays: [DisplayInfo]) {
        router.setDisplays(displays)
        rebuildMapper(force: true)
    }

    func rebuildMapper(force: Bool = false) {
        let id = router.current?.id ?? "main"
        guard force || id != mapperDisplayID else { return }
        mapper = ActiveBoxMapper(profile: calibration.profile(for: id), boxScale: config.boxScale,
                                 edgeOvershoot: config.edgeOvershoot)
        mapperDisplayID = id
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
            resetGestures()
            lastHandSeen = time
            hadHandRecently = false
            out.events.append(.engaged)
        } else {
            out.append(cancelActiveGestures())
            out.append(StepOutput(intents: momentum.stop()))
            isEngaged = false
            state = .idle
            cursor = nil
            out.events.append(.disengaged(reason))
        }
        palmHoldStart = nil
        palmLatched = true // the palms that toggled must drop before they can toggle again
        refreshSnapshot(at: time)
        return out
    }

    /// The real mouse moved. Hand output pauses briefly so the user always wins, and the
    /// pointer moves to whichever display the mouse is on (unless it stays on the engage display).
    public func noteExternalMouse(at location: Point2, time: Double) -> StepOutput {
        var out = StepOutput()
        let wasSuppressed = time < outputSuppressedUntil
        outputSuppressedUntil = time + 0.8
        if !config.stayOnEngagedDisplay {
            router.focus(containing: location)
            rebuildMapper()
        }
        if isEngaged && !wasSuppressed {
            out.events.append(.externalMouseTookOver)
        }
        // A locked hand cursor is stale once the real mouse has moved; start over from the hand.
        cursorLock = nil
        dwellAnchor = nil
        if state == .dragging {
            // Our synthetic button is still down, so the real mouse would drag whatever the fist
            // grabbed. Let go where the real mouse is (never warp it back).
            if buttonDown {
                buttonDown = false
                out.intents.append(.up(x: location.x, y: location.y))
                out.events.append(.dragEnded)
            }
            state = .hover
            warpOffset = .zero
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

        let (primaryHand, secondaryHand) = assignPointerAndOther(frame.hands, at: time)
        snapshot.hands = frame.hands

        // Pose classification (fist, open palm) for both hands, in every state.
        if let hand = primaryHand { _ = primary.update(hand) }
        if let hand = secondaryHand {
            if !secondarySeen {
                secondary.reset()
                secondarySeen = true
            }
            _ = secondary.update(hand)
        } else if secondarySeen {
            secondarySeen = false
            secondary.reset()
        }
        out.append(updatePalmEngagement(primaryHand, secondaryHand, at: time))

        guard isEngaged else {
            refreshSnapshot(at: time)
            return out
        }

        if let hand = primaryHand {
            lastHandSeen = time
            hadHandRecently = true
            if state == .engaged { state = .hover }
            out.append(updatePointerShake(hand, other: secondaryHand, at: time))
        } else {
            out.append(handleMissingHand(at: time))
        }

        refreshSnapshot(at: time)
        return out
    }

    // MARK: Engagement by palms

    /// Palm speed in hand sizes per second, lightly smoothed.
    private static func updateSpeed(_ speed: inout Double, last: inout (time: Double, point: Point2)?,
                                    hand: HandFrame?, at time: Double) {
        guard let hand else {
            speed = 0
            last = nil
            return
        }
        let palm = hand.palmCenter
        if let previous = last, time > previous.time {
            let moved = Point2(palm.x - previous.point.x, (palm.y - previous.point.y) / hand.imageAspect).length
            let instant = moved / hand.handSize / (time - previous.time)
            speed += (instant - speed) * 0.4
        }
        last = (time, palm)
    }

    /// Both hands held up as still open palms toggle engagement. One palm alone does nothing:
    /// a single open hand is too easy to show by accident (reaching, waving, gesturing).
    private func updatePalmEngagement(_ hand: HandFrame?, _ other: HandFrame?, at time: Double) -> StepOutput {
        Self.updateSpeed(&palmSpeed, last: &palmSpeedLast, hand: hand, at: time)
        Self.updateSpeed(&secondaryPalmSpeed, last: &secondaryPalmSpeedLast, hand: other, at: time)
        bothPalmsOpen = hand != nil && other != nil
            && primary.state.pose == .openPalm && secondary.state.pose == .openPalm

        guard config.palmEngageEnabled else {
            palmHoldStart = nil
            return StepOutput()
        }
        if !bothPalmsOpen {
            // Not both palms for a moment (Vision drops a hand for a frame, a re-seen hand takes
            // a few frames to classify) neither restarts the hold nor re-arms the toggle; for
            // longer, it does both.
            if notBothPalmsSince == nil { notBothPalmsSince = time }
            if time - (notBothPalmsSince ?? time) > Self.palmPairGrace {
                palmLatched = false
                palmHoldStart = nil
            }
            return StepOutput()
        }
        notBothPalmsSince = nil
        let busy = [.dragging, .twoFists].contains(state)
        let still = max(palmSpeed, secondaryPalmSpeed) < config.palmStillnessNormalized
        guard !palmLatched, !busy, still else {
            palmHoldStart = nil
            return StepOutput()
        }
        if palmHoldStart == nil { palmHoldStart = time }
        let needed = isEngaged ? config.palmDisengageDuration : config.palmEngageDuration
        if time - (palmHoldStart ?? time) >= needed {
            // Engaging by palm starts on the display the real mouse pointer is on.
            let out = setEngaged(!isEngaged, reason: .palm, at: time,
                                 mouseLocation: isEngaged ? nil : realMouseLocation)
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
            out.append(cancelActiveGestures())
            primary.reset()
            smoother.reset()
            state = .engaged
        }
        if missingFor > config.handLostTimeout {
            out.append(setEngaged(false, reason: .handLost, at: time))
        }
        return out
    }

    /// Ends a drag cleanly so the button is never left held down, and forgets any lock or
    /// two-fist gesture.
    private func cancelActiveGestures() -> StepOutput {
        var out = StepOutput()
        if buttonDown, let point = lastEmittedCursor ?? cursor {
            buttonDown = false
            out.intents.append(.up(x: point.x, y: point.y))
            out.events.append(.dragEnded)
        }
        resetGestures()
        if isEngaged { state = .engaged }
        return out
    }

    func resetGestures() {
        shakeDetector.reset()
        cursorLock = nil
        dwellAnchor = nil
        twoFists = nil
        twoFistsGoneSince = nil
        warpOffset = .zero
        lastRawBox = nil
        lastTip = nil
    }

    // MARK: Cursor helpers

    /// How far the hand must move (box widths) for a leftover offset to drain away completely:
    /// the cursor re-converges on the absolute hand mapping gradually, hidden inside ordinary
    /// movement, so the reach to every screen edge comes back.
    static let warpDrainBox = 0.5

    /// Make the cursor continue from `point` with the hand where it is now.
    func reanchor(at point: Point2, time: Double) {
        guard let display = router.current, let raw = lastRawBox else { return }
        let box = ActiveBoxMapper.boxPoint(fromScreen: point, on: display)
        warpOffset = box - raw
        smoother.reset(to: box, at: time)
    }

    func emitMove(_ p: Point2, suppressed: Bool) -> StepOutput {
        guard !suppressed else { return StepOutput() }
        if let last = lastEmittedCursor, last.distance(to: p) < 0.25 { return StepOutput() }
        lastEmittedCursor = p
        return StepOutput(intents: [.move(x: p.x, y: p.y)])
    }

    /// Fills while the cursor settles toward a lock, stays full while locked, and drains through
    /// the wake window (wiggle or make a fist before it empties).
    private func lockProgress(at time: Double) -> Double {
        guard isEngaged, [.hover, .dragging].contains(state) else { return 0 }
        if let lock = cursorLock {
            guard let wake = lock.wakeStart else { return 1 }
            return clamp01(1 - (time - wake) / max(config.shake.wakeTime, 1e-6))
        }
        guard let anchor = dwellAnchor else { return 0 }
        // Show nothing for the first quarter so ordinary pauses do not flash the ring.
        let t = (time - anchor.time) / max(config.shake.lockTime, 1e-6)
        return t < 0.25 ? 0 : clamp01((t - 0.25) / 0.75)
    }

    // MARK: Snapshot

    private func refreshSnapshot(at time: Double) {
        snapshot.state = state
        snapshot.isEngaged = isEngaged
        snapshot.cursor = isEngaged ? cursor : nil
        snapshot.displayID = router.current?.id
        snapshot.engageProgress = engageProgress(at: time)
        snapshot.lockProgress = lockProgress(at: time)
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
