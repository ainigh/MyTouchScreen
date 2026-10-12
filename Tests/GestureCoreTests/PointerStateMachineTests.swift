import XCTest
@testable import GestureCore

final class PointerStateMachineTests: XCTestCase {
    func testHoverMovesCursorOnlyWhenEngaged() {
        let frames = SyntheticStream.ramp(from: Point2(0.6, 0.45), to: Point2(0.4, 0.45), duration: 0.5)
        let idle = PointerStateMachine(displays: [testDisplay])
        XCTAssertTrue(drive(idle, frames).intents.isEmpty, "a disengaged machine must never move the cursor")

        let machine = engagedMachine()
        let out = drive(machine, frames)
        let moves = out.moves
        XCTAssertGreaterThan(moves.count, 5)
        // Hand moves toward the camera's left = the user's right: cursor moves right (mirrored).
        XCTAssertGreaterThan(moves.last!.x, moves.first!.x + 300)
    }

    func testSingleTapClicksOnce() {
        let machine = engagedMachine()
        let out = drive(machine, SyntheticStream.pinchTaps(at: [0.6]))
        XCTAssertEqual(out.clicks.count, 1)
        XCTAssertEqual(out.clicks.first?.2, 1)
        XCTAssertEqual(out.downs, 0, "a quick tap is a click, not a drag")
        XCTAssertTrue(out.events.contains(.clicked(count: 1)))
    }

    func testClickLandsWhereThePointerWasBeforeThePinch() {
        let machine = engagedMachine()
        let out = drive(machine, SyntheticStream.pinchTaps(at: [0.8], tapDuration: 0.15))
        let lastMoveBeforeClick = out.moves.last!
        let click = out.clicks.first!
        XCTAssertEqual(click.0, lastMoveBeforeClick.x, accuracy: 3)
        XCTAssertEqual(click.1, lastMoveBeforeClick.y, accuracy: 3)
    }

    func testTwoQuickPinchesDoubleClick() {
        let machine = engagedMachine()
        let out = drive(machine, SyntheticStream.pinchTaps(at: [0.6, 0.85]))
        XCTAssertEqual(out.clicks.map { $0.2 }, [1, 2])
        guard out.clicks.count == 2 else { return }
        XCTAssertEqual(out.clicks[0].0, out.clicks[1].0)
        XCTAssertEqual(out.clicks[0].1, out.clicks[1].1)
    }

    func testSlowPinchesAreTwoSingleClicks() {
        let machine = engagedMachine()
        let out = drive(machine, SyntheticStream.pinchTaps(at: [0.6, 1.4]))
        XCTAssertEqual(out.clicks.map { $0.2 }, [1, 1])
    }

    func testHoldAndMoveDrags() {
        let machine = engagedMachine()
        let out = drive(machine, SyntheticStream.drag())
        XCTAssertEqual(out.downs, 1)
        XCTAssertEqual(out.ups, 1)
        XCTAssertEqual(out.clicks.count, 0)
        // Down, then moves, then up, in that order.
        let downIndex = out.intents.firstIndex { if case .down = $0 { return true } else { return false } }!
        let upIndex = out.intents.firstIndex { if case .up = $0 { return true } else { return false } }!
        let movesDuringDrag = out.intents[downIndex..<upIndex].filter { if case .move = $0 { return true } else { return false } }
        XCTAssertGreaterThan(movesDuringDrag.count, 5)
        if case let .down(x0, _) = out.intents[downIndex], case let .up(x1, _) = out.intents[upIndex] {
            // Hand moved toward the camera's left: drop point is to the right of the pick-up.
            XCTAssertGreaterThan(x1 - x0, 200)
        }
        XCTAssertTrue(out.events.contains(.dragStarted))
        XCTAssertTrue(out.events.contains(.dragEnded))
    }

    func testDragStartsOnlyAfterHoldThreshold() {
        // A 200 ms still pinch (below the 250 ms hold) is a click; 400 ms is a press-and-hold.
        let short = drive(engagedMachine(), SyntheticStream.pinchTaps(at: [0.6], tapDuration: 0.2))
        XCTAssertEqual(short.clicks.count, 1)
        XCTAssertEqual(short.downs, 0)
        let long = drive(engagedMachine(), SyntheticStream.pinchTaps(at: [0.6], tapDuration: 0.4))
        XCTAssertEqual(long.clicks.count, 0)
        XCTAssertEqual(long.downs, 1)
        XCTAssertEqual(long.ups, 1)
    }

    func testMiddlePinchRightClicks() {
        let out = drive(engagedMachine(), SyntheticStream.pinchTaps(at: [0.6], finger: .middle))
        XCTAssertEqual(out.rightClicks, 1)
        XCTAssertEqual(out.clicks.count, 0)
    }

    func testFistScrollWithMomentum() {
        let machine = engagedMachine()
        let out = drive(machine, SyntheticStream.fistScroll(offset: Point2(0, 0.15)))
        XCTAssertEqual(out.scrolls(.began).count, 1)
        let changes = out.scrolls(.changed)
        XCTAssertGreaterThan(changes.count, 5)
        // Hand moved down: natural scrolling moves content down (positive dy).
        XCTAssertGreaterThan(changes.map { $0.1 }.reduce(0, +), 100)
        XCTAssertEqual(out.scrolls(.ended).count, 1)
        XCTAssertEqual(out.scrolls(.momentumBegan).count, 1)
        let momentum = out.scrolls(.momentumChanged)
        XCTAssertGreaterThan(momentum.count, 5)
        // Momentum decays monotonically.
        let magnitudes = momentum.map { abs($0.1) }
        XCTAssertTrue(zip(magnitudes, magnitudes.dropFirst()).allSatisfy { $0 >= $1 })
        XCTAssertEqual(out.scrolls(.momentumEnded).count, 1)
        XCTAssertTrue(out.moves.isEmpty || out.moves.count < 40)
    }

    func testReverseScrollDirectionSetting() {
        var config = GestureConfig.default
        config.naturalScrolling = false
        let out = drive(engagedMachine(config), SyntheticStream.fistScroll(offset: Point2(0, 0.15)))
        XCTAssertLessThan(out.scrolls(.changed).map { $0.1 }.reduce(0, +), -100)
    }

    func testStillFistDoesNotMomentum() {
        let out = drive(engagedMachine(), SyntheticStream.fistScroll(offset: .zero))
        XCTAssertEqual(out.scrolls(.momentumBegan).count, 0)
    }

    func testPalmHoldEngagesOnlyAfterHoldDuration() {
        // 0.4 s is too short.
        let short = PointerStateMachine(displays: [testDisplay])
        drive(short, SyntheticStream.palmHold(hold: 0.4))
        XCTAssertFalse(short.isEngaged)

        let machine = PointerStateMachine(displays: [testDisplay])
        let out = drive(machine, SyntheticStream.palmHold(hold: 1.0))
        XCTAssertTrue(machine.isEngaged)
        XCTAssertEqual(out.events.filter { $0 == .engaged }.count, 1, "holding longer must not toggle again")
    }

    func testPalmHoldDisengages() {
        let machine = engagedMachine()
        let out = drive(machine, SyntheticStream.palmHold(hold: 1.2))
        XCTAssertFalse(machine.isEngaged)
        XCTAssertTrue(out.events.contains(.disengaged(.palm)))
    }

    func testHandLostDisengagesAfterTimeout() {
        let machine = engagedMachine()
        let frames = SyntheticStream.handLost(visibleUntil: 0.5, duration: 2.3)
        drive(machine, frames)
        XCTAssertTrue(machine.isEngaged, "1.8 s without a hand is still within the 2 s timeout")
        let longer = engagedMachine()
        let out = drive(longer, SyntheticStream.handLost(visibleUntil: 0.5, duration: 3.0))
        XCTAssertFalse(longer.isEngaged)
        XCTAssertTrue(out.events.contains(.disengaged(.handLost)))
    }

    func testHandLostDuringDragReleasesButton() {
        let machine = engagedMachine()
        var frames = SyntheticStream.pinchTaps(at: [0.5], tapDuration: 5, duration: 1.2)
        frames += SyntheticStream.generate(duration: 0.5, start: 1.2) { _ in [] }
        let out = drive(machine, frames)
        XCTAssertEqual(out.downs, 1)
        XCTAssertEqual(out.ups, 1, "a lost hand must never leave the mouse button held")
    }

    func testTwoHandPinchZooms() {
        let machine = engagedMachine()
        let out = drive(machine, SyntheticStream.twoHandZoom(spreadChange: 0.12))
        let zooms = out.zooms
        XCTAssertEqual(zooms.first?.1, .began)
        XCTAssertEqual(zooms.last?.1, .ended)
        let total = zooms.filter { $0.1 == .changed }.map { $0.0 }.reduce(1, *)
        XCTAssertGreaterThan(total, 1.3, "hands moving apart zoom in")
        XCTAssertEqual(out.clicks.count, 0, "a zoom must not also click")
        XCTAssertEqual(out.downs, 0)

        let inward = drive(engagedMachine(), SyntheticStream.twoHandZoom(spreadChange: -0.1))
        let inTotal = inward.zooms.filter { $0.1 == .changed }.map { $0.0 }.reduce(1, *)
        XCTAssertLessThan(inTotal, 0.8)
    }

    func testAppSwitcherWhenEnabled() {
        var config = GestureConfig.default
        config.appSwitcherEnabled = true
        let out = drive(engagedMachine(config), SyntheticStream.pinchTaps(at: [0.5], tapDuration: 0.4, finger: .ring))
        XCTAssertEqual(out.intents.first { if case .key = $0 { return true } else { return false } },
                       .key(KeyStroke(.command, action: .down)))
        XCTAssertEqual(out.intents.last { if case .key = $0 { return true } else { return false } },
                       .key(KeyStroke(.command, action: .up)))

        let disabled = drive(engagedMachine(), SyntheticStream.pinchTaps(at: [0.5], tapDuration: 0.4, finger: .ring))
        XCTAssertFalse(disabled.intents.contains { if case .key = $0 { return true } else { return false } })
        XCTAssertEqual(disabled.clicks.count, 0)
    }

    func testDwellClick() {
        var config = GestureConfig.default
        config.dwellClickEnabled = true
        let out = drive(engagedMachine(config), SyntheticStream.steady(duration: 2.5))
        XCTAssertEqual(out.clicks.count, 1, "dwell clicks once, then waits for movement")
        XCTAssertTrue(out.events.contains(.dwellClicked))
        XCTAssertEqual(drive(engagedMachine(), SyntheticStream.steady(duration: 2.5)).clicks.count, 0)
    }

    func testExternalMouseSuppressesOutput() {
        let machine = engagedMachine()
        let frames = SyntheticStream.ramp(from: Point2(0.6, 0.45), to: Point2(0.4, 0.45), duration: 1.0)
        var out = StepOutput()
        for frame in frames {
            if abs(frame.timestamp - 0.8) < 0.001 {
                out.append(machine.noteExternalMouse(at: Point2(10, 10), time: frame.timestamp))
            }
            let step = machine.process(frame)
            if frame.timestamp > 0.8 && frame.timestamp < 1.55 {
                XCTAssertTrue(step.intents.isEmpty, "the real mouse wins for a moment")
            }
            out.append(step)
        }
        XCTAssertTrue(out.events.contains(.externalMouseTookOver))
    }

    func testStillHandWithJitterKeepsCursorStill() {
        let machine = engagedMachine()
        let out = drive(machine, SyntheticStream.steady(duration: 5, noise: 0.0015))
        // After settling, essentially no movement is emitted.
        let lateMoves = out.moves.dropFirst(20)
        var travel = 0.0
        for (a, b) in zip(lateMoves, lateMoves.dropFirst()) { travel += a.distance(to: b) }
        XCTAssertLessThan(travel, 20, "cursor drifted \(travel) pt on a still hand")
    }

    func testDisengageReleasesHeldButton() {
        let machine = engagedMachine()
        _ = drive(machine, SyntheticStream.pinchTaps(at: [0.5], tapDuration: 5, duration: 1.2))
        let out = machine.setEngaged(false, reason: .hotkey, at: 1.3)
        XCTAssertEqual(out.ups, 1)
        XCTAssertEqual(out.events.last, .disengaged(.hotkey))
    }

    /// A second, idle hand in view at the camera's right while `primary` does its thing.
    private func withBystanderHand(_ frames: [TrackingFrame], primaryUntil: Double) -> [TrackingFrame] {
        var bystander = SyntheticHand.pointing(tipAt: Point2(0.8, 0.45))
        bystander.chirality = .left
        bystander.wrist = bystander.wristPlacing(indexTipAt: Point2(0.8, 0.45))
        return frames.map { frame in
            let other = bystander.frame(at: frame.timestamp)
            let own = frame.timestamp < primaryUntil ? frame.hands : []
            return TrackingFrame(timestamp: frame.timestamp, hands: own + [other])
        }
    }

    func testPointingHandLeavingMidDragWhileOtherHandStaysReleasesButton() {
        // Regression: the remaining hand became primary and the detector was reset silently,
        // so no pinch-ended ever arrived and the button stayed down for good.
        let drag = SyntheticStream.pinchTaps(at: [0.5], tapDuration: 5, duration: 2.0)
        let out = drive(engagedMachine(), withBystanderHand(drag, primaryUntil: 1.2))
        XCTAssertEqual(out.downs, 1)
        XCTAssertEqual(out.ups, 1, "a hand swap must never leave the mouse button held")
        XCTAssertTrue(out.events.contains(.dragEnded))
    }

    func testPointingHandLeavingMidScrollWhileOtherHandStaysEndsScroll() {
        let scroll = SyntheticStream.fistScroll(offset: Point2(0, 0.15), openAtEnd: false)
        let machine = engagedMachine()
        let out = drive(machine, withBystanderHand(scroll, primaryUntil: 0.9))
        XCTAssertEqual(out.scrolls(.began).count, 1)
        XCTAssertEqual(out.scrolls(.ended).count, 1, "the scroll gesture must be closed")
        XCTAssertNotEqual(machine.state, .scrolling)
    }

    func testDragStartedWhileMouseSuppressedSendsNoUnmatchedUp() {
        // Regression: the drag began while the real mouse had priority (no down sent), but
        // releasing the pinch still sent a mouse-up, which would cut short a real drag.
        let machine = engagedMachine()
        var out = StepOutput()
        for frame in SyntheticStream.pinchTaps(at: [0.5], tapDuration: 0.5, duration: 1.6) {
            if abs(frame.timestamp - 0.6) < 0.001 {
                out.append(machine.noteExternalMouse(at: Point2(10, 10), time: frame.timestamp))
            }
            out.append(machine.process(frame))
        }
        XCTAssertEqual(out.downs, 0)
        XCTAssertEqual(out.ups, 0)
        XCTAssertFalse(out.events.contains(.dragEnded))
        XCTAssertEqual(machine.state, .hover)
    }

    func testRealMouseDuringHandDragReleasesButtonWhereTheMouseIs() {
        // Regression: the synthetic button stayed down when the user grabbed the real mouse
        // mid-drag, so the real mouse kept dragging whatever the hand had picked up.
        let machine = engagedMachine()
        var out = StepOutput()
        var tookOver = false
        for frame in SyntheticStream.pinchTaps(at: [0.5], tapDuration: 0.8, duration: 1.8) {
            out.append(machine.process(frame))
            if !tookOver && machine.state == .dragging && frame.timestamp >= 1.0 {
                out.append(machine.noteExternalMouse(at: Point2(10, 10), time: frame.timestamp))
                tookOver = true
            }
        }
        XCTAssertTrue(tookOver)
        XCTAssertEqual(out.downs, 1)
        XCTAssertEqual(out.ups, 1)
        XCTAssertEqual(out.intents.last { if case .up = $0 { return true } else { return false } },
                       .up(x: 10, y: 10))
        XCTAssertTrue(out.clicks.isEmpty)
        XCTAssertEqual(machine.state, .hover)
    }

    func testAppSwitcherWithZeroStepDoesNotTrap() {
        // Regression: Int(x / 0) trapped on an imported settings file with a zero step.
        var config = GestureConfig.default
        config.appSwitcherEnabled = true
        config.appSwitcherStepBox = 0
        let out = drive(engagedMachine(config), SyntheticStream.pinchTaps(at: [0.5], tapDuration: 0.4, finger: .ring))
        XCTAssertEqual(out.intents.last { if case .key = $0 { return true } else { return false } },
                       .key(KeyStroke(.command, action: .up)))
    }

    func testMomentumWithZeroFrictionStaysFinite() {
        // Regression: friction 0 made the glide distance 0/0 = NaN.
        var momentum = ScrollMomentum(friction: 0, minSpeed: 40)
        _ = momentum.start(velocity: Point2(0, 1000), at: 0)
        var t = 0.0
        var ended = false
        while t < 120 && !ended {
            t += 1.0 / 60
            for intent in momentum.tick(at: t) {
                guard case let .scroll(dx, dy, phase) = intent else { continue }
                XCTAssertTrue(dx.isFinite && dy.isFinite)
                if phase == .momentumEnded { ended = true }
            }
        }
        XCTAssertTrue(ended, "momentum must always come to rest")
    }
}
