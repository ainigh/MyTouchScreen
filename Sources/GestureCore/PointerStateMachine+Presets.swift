import Foundation

/// A hand shape treated as a button, debounced. It only closes after being seen open (`armed`),
/// so a hand that arrives already pinched, or a fist still held after a zoom, never presses by
/// itself.
struct ContactSensor {
    private(set) var isClosed = false
    private(set) var armed = false
    private var closingSince: Double?

    /// `raw`: true = closed this frame, false = clearly open, nil = in between (hysteresis band,
    /// or a reading that says nothing): the sensor keeps its state.
    mutating func update(raw: Bool?, at time: Double, confirm: Double) {
        switch raw {
        case false?:
            isClosed = false
            closingSince = nil
            armed = true
        case true?:
            guard !isClosed, armed else { return }
            let since = closingSince ?? time
            closingSince = since
            if time - since >= confirm {
                isClosed = true
                closingSince = nil
            }
        case nil:
            if !isClosed { closingSince = nil }
        }
    }

    mutating func disarm() {
        isClosed = false
        armed = false
        closingSince = nil
    }
}

/// A contact being held toward a click or a press.
struct PendingContact {
    var kind: HandContact
    var since: Double
    /// Where the click or press lands: where the cursor was just before the hand changed shape.
    var point: Point2
    var clicked = false
}

/// The click / drag / zoom presets (`config.clickGesture`, `dragGesture`, `zoomGesture`).
///
/// - A contact that only clicks clicks as soon as it is confirmed closed.
/// - A contact that only drags presses once held for its hold time; releasing drops.
/// - A contact that does both clicks on a quick release and presses when held.
/// - `fistToggle` presses on one fist and drops on the next.
/// - Dwell clicks once the cursor has stayed put for `contact.dwellTime`.
/// - Zoom holds the cursor (apps zoom around it) and sends `.zoom` intents from the change in
///   distance between the hands, or the other hand's height.
extension PointerStateMachine {
    // MARK: Sensors

    /// Update every contact sensor of the pointing hand, plus the other hand's pinch (zoom).
    func updateContactSensors(other: HandFrame?, at time: Double) {
        let isFist = primary.state.pose == .fist
        let observedFist = primary.observedPose == .fist
        // The fist is already debounced by the pose classifier.
        sensors[.fist, default: ContactSensor()].update(
            raw: isFist ? true : (observedFist ? nil : false), at: time, confirm: 0)
        let c = config.contact
        if let f = primary.state.features {
            // While the hand is a fist, its tucked thumb says nothing about pinches or triggers.
            func raw(_ distance: Double, close: Double, open: Double) -> Bool? {
                if observedFist || isFist { return nil }
                return distance < close ? true : (distance > open ? false : nil)
            }
            sensors[.indexPinch, default: ContactSensor()].update(
                raw: raw(f.pinchDistance[.index] ?? 1, close: c.pinchClose, open: c.pinchOpen), at: time, confirm: c.confirmTime)
            sensors[.middlePinch, default: ContactSensor()].update(
                raw: raw(f.pinchDistance[.middle] ?? 1, close: c.pinchClose, open: c.pinchOpen), at: time, confirm: c.confirmTime)
            sensors[.thumbTrigger, default: ContactSensor()].update(
                raw: raw(f.thumbSpread, close: c.triggerClose, open: c.triggerOpen), at: time, confirm: c.confirmTime)
        }

        otherHandZoomContact = false
        if let other {
            let pinch = other.pinchDistanceNormalized(.index)
            let otherFist = secondary.state.pose == .fist || secondary.observedPose == .fist
            otherPinchSensor.update(raw: otherFist ? nil : (pinch < c.pinchClose ? true : (pinch > c.pinchOpen ? false : nil)),
                                    at: time, confirm: c.confirmTime)
            switch config.zoomGesture.contact {
            case .fist?: otherHandZoomContact = otherFist
            case .indexPinch?: otherHandZoomContact = otherPinchSensor.isClosed || pinch < c.pinchClose
            default: break
            }
        } else {
            otherPinchSensor.disarm()
        }
    }

    func isClosed(_ kind: HandContact) -> Bool { sensors[kind]?.isClosed ?? false }

    /// Forget every contact: each must be seen open again before it can press or click.
    func disarmContacts() {
        for kind in HandContact.allCases { sensors[kind, default: ContactSensor()].disarm() }
        pendingContact = nil
    }

    /// The pointing hand belongs to a two-hand zoom (made or forming): it can't click or press.
    var zoomClaimsPointingHand: Bool {
        config.zoomGesture.usesPointingHand && (zoomMetric != nil || otherHandZoomContact)
    }

    // MARK: Click and press

    /// A contact being held: keeps the cursor on its point, then clicks or presses. Returns nil
    /// when no contact is in progress (the cursor follows the hand as usual).
    func updatePendingContact(_ hand: HandFrame, at time: Double, suppressed: Bool) -> StepOutput? {
        let clickKind = config.clickGesture.contact
        let dragKind = config.dragGesture.contact
        if pendingContact == nil {
            guard !zoomClaimsPointingHand else { return nil }
            let candidates = [dragKind, clickKind].compactMap { $0 }
            guard let kind = candidates.first(where: isClosed) else { return nil }
            let clickOnly = kind == clickKind && kind != dragKind
            if clickOnly && time - lastContactRelease < config.contact.refractoryTime { return nil }
            let point = freeze?.point ?? cursorPoint(at: time - lookback(kind))
            pendingContact = PendingContact(kind: kind, since: time, point: point)
        }
        guard var pending = pendingContact else { return nil }
        var out = StepOutput()

        if !isClosed(pending.kind) {
            // Released before pressing: a click when the same contact also drags (a tap).
            pendingContact = nil
            lastContactRelease = time
            let shared = pending.kind == clickKind && pending.kind == dragKind
            if shared && !pending.clicked && time - pending.since <= config.contact.tapMaxDuration && !suppressed {
                freezeCursor(at: pending.point, fresh: true)
                out.append(emitMove(pending.point, suppressed: suppressed))
                out.append(click(at: pending.point, time: time, window: config.contact.doubleClickWindow))
                return out
            }
            return nil
        }

        freezeCursor(at: pending.point)
        if zoomClaimsPointingHand {
            // The other hand is joining a two-hand zoom: wait, never press.
            out.append(emitMove(pending.point, suppressed: suppressed))
            return out
        }
        if pending.kind == dragKind && !pending.clicked && time - pending.since >= holdTime(pending.kind) {
            out.append(press(hand, at: pending.point, time: time, suppressed: suppressed))
            return out
        }
        if pending.kind == clickKind && pending.kind != dragKind && !pending.clicked && !suppressed {
            pending.clicked = true
            freezeCursor(at: pending.point, fresh: true)
            out.append(emitMove(pending.point, suppressed: suppressed))
            out.append(click(at: pending.point, time: time, window: config.contact.doubleClickWindow))
            pendingContact = pending
            return out
        }
        pendingContact = pending
        out.append(emitMove(pending.point, suppressed: suppressed))
        return out
    }

    /// While dragging: has the drag gesture let go?
    func dragReleased() -> Bool {
        guard let kind = config.dragGesture.contact else { return true }
        if config.dragGesture == .fistToggle {
            // Opening the hand keeps the button down; the next fist drops.
            if !isClosed(.fist) { toggleOpenedSincePress = true }
            return toggleOpenedSincePress && isClosed(.fist)
        }
        return !isClosed(kind)
    }

    /// How long a contact must be held to press (drag).
    func holdTime(_ kind: HandContact) -> Double {
        kind == .fist ? config.shake.fistHoldTime : config.contact.holdToDragTime
    }

    /// How far back to look for where the cursor was before the hand changed shape (closing the
    /// hand or pinching drags the fingertip, and with it the cursor, along).
    func lookback(_ kind: HandContact) -> Double {
        kind == .fist ? config.poseConfirmDuration + Self.fistLookback : config.contact.confirmTime + Self.pinchLookback
    }

    static let pinchLookback = 0.1

    // MARK: Dwell

    func updateDwell(at time: Double, suppressed: Bool) -> StepOutput {
        guard let shown = lastEmittedCursor ?? cursor else { return StepOutput() }
        let radius = (router.current?.frame.width ?? 1500) * config.contact.dwellRadiusBox
        guard var current = dwell, current.point.distance(to: shown) <= radius else {
            dwell = DwellState(point: shown, since: time)
            return StepOutput()
        }
        guard current.armed, time - current.since >= config.contact.dwellTime, !suppressed else { return StepOutput() }
        // Clicked: no more until the cursor moves away.
        current.armed = false
        dwell = current
        freezeCursor(at: shown, fresh: true)
        return click(at: shown, time: time, window: 0)
    }

    /// 0…1 toward a dwell click, starting once the cursor has been still for a moment (so the
    /// ring doesn't flicker on every pause).
    func dwellProgress(at time: Double) -> Double {
        guard config.clickGesture == .dwell, state == .hover, let current = dwell, current.armed else { return 0 }
        let grace = 0.25
        return clamp01((time - current.since - grace) / max(config.contact.dwellTime - grace, 1e-6))
    }

    // MARK: Zoom

    /// The zoom measurement this frame, as a log zoom level (nil: the zoom gesture isn't made).
    private func zoomLevel(_ hand: HandFrame, other: HandFrame?) -> Double? {
        guard let other else { return nil }
        func midPinch(_ h: HandFrame) -> Point2 { h.handSpace((h[.thumbTip] + h[.indexTip]) * 0.5) }
        func spread(_ a: Point2, _ b: Point2) -> Double? {
            let d = a.distance(to: b)
            return d > 1e-4 ? log(d) : nil
        }
        let perHandSize = log(max(config.contact.zoomPerHandSize, 1.01))
        switch config.zoomGesture {
        case .off:
            return nil
        case .twoFistSpread:
            guard primary.state.pose == .fist, secondary.state.pose == .fist else { return nil }
            return spread(hand.handSpace(hand.palmCenter), other.handSpace(other.palmCenter))
        case .twoPinchSpread:
            guard isClosed(.indexPinch), otherPinchSensor.isClosed else { return nil }
            return spread(midPinch(hand), midPinch(other))
        case .otherFistUpDown:
            guard secondary.state.pose == .fist else { return nil }
            return -other.handSpace(other.palmCenter).y / other.handSize * perHandSize
        case .otherPinchUpDown:
            guard otherPinchSensor.isClosed else { return nil }
            return -midPinch(other).y / other.handSize * perHandSize
        }
    }

    /// Runs the zoom gesture. Returns the frame's output when zoom owns the frame (starting,
    /// zooming or ending), nil otherwise.
    func updateZoom(_ hand: HandFrame, other: HandFrame?, at time: Double, suppressed: Bool) -> StepOutput? {
        var out = StepOutput()
        guard let level = zoomLevel(hand, other: other) else {
            guard zoomMetric != nil else { return nil }
            out.append(endZoom())
            return out
        }
        guard let previous = zoomMetric else {
            // Only from plain pointing: never in the middle of a drag.
            guard state == .hover else { return nil }
            zoomMetric = level
            pendingContact = nil
            shakeDetector.reset()
            dwell = nil
            if let point = freeze?.point ?? lastEmittedCursor ?? cursor { freezeCursor(at: point, fresh: true) }
            zoomSentBegin = !suppressed
            if !suppressed { out.intents.append(.zoom(factor: 1, phase: .began)) }
            out.events.append(.zoomStarted)
            return out
        }
        // Zooming: the cursor stays put (apps zoom around it).
        if let point = freeze?.point ?? cursor { freezeCursor(at: point, fresh: true) }
        let change = level - previous
        if abs(change) >= Self.zoomStep {
            zoomMetric = level
            if !suppressed {
                if !zoomSentBegin {
                    zoomSentBegin = true
                    out.intents.append(.zoom(factor: 1, phase: .began))
                }
                out.intents.append(.zoom(factor: exp(change), phase: .changed))
            }
        }
        return out
    }

    /// Smallest change in log zoom worth sending (about 1%): tracker jitter stays out.
    static let zoomStep = 0.01

    /// Ends a zoom cleanly; the hand shapes that made it must open before they do anything else.
    func endZoom() -> StepOutput {
        guard zoomMetric != nil else { return StepOutput() }
        zoomMetric = nil
        var out = StepOutput(events: [.zoomEnded])
        if zoomSentBegin { out.intents.append(.zoom(factor: 1, phase: .ended)) }
        zoomSentBegin = false
        disarmContacts()
        return out
    }
}

/// Where the cursor has been holding still, toward a dwell click.
struct DwellState {
    var point: Point2
    var since: Double
    var armed = true
}
