import XCTest
@testable import GestureCore

/// The click, drag and zoom presets. Each scenario rests the pointing hand first (so the cursor
/// is locked still), then makes the gesture.
final class GesturePresetTests: XCTestCase {
    private func config(click: ClickGesture = .wiggle, drag: DragGesture = .fistHold,
                        zoom: ZoomGesture = .off) -> GestureConfig {
        var c = GestureConfig.classic
        c.clickGesture = click
        c.dragGesture = drag
        c.zoomGesture = zoom
        return c
    }

    /// The pointing hand from `shape(t)`, at a fixed spot plus `offset(t)` (hand space), and the
    /// other hand while `other(t)` returns one.
    private func stream(duration: Double, fps: Double = 60, noise: Double = 0.0004,
                        offset: @escaping (Double) -> Point2 = { _ in .zero },
                        other: @escaping (Double) -> SyntheticHand? = { _ in nil },
                        shape: @escaping (Double, inout SyntheticHand) -> Void) -> [TrackingFrame] {
        SyntheticStream.generate(duration: duration, fps: fps, noise: noise, seed: 11) { t in
            var hand = MotionSynthetic.placedHand(tip: Point2(0.4, 0.45), size: 0.12, offset: offset(t))
            shape(t, &hand)
            return [hand] + (other(t).map { [$0] } ?? [])
        }
    }

    /// The other (left) hand on the camera's right, `lift` hand-space units higher.
    private func otherHand(lift: Double = 0, x: Double = 0.75, fist: Bool = false, pinch: Double = 0) -> SyntheticHand {
        var h = SyntheticHand(wrist: .zero)
        h.size = 0.12
        h.chirality = .left
        h.wrist = h.wristPlacing(indexTipAt: SyntheticHand.imagePoint(Point2(x, 0.45), offset: Point2(0, -lift)))
        if fist { h.makeFist() }
        h.pinchAmount = pinch
        return h
    }

    private func run(_ frames: [TrackingFrame], _ config: GestureConfig) -> StepOutput {
        Evaluation.merged(Evaluation.run(frames, config: config))
    }

    private func clicks(_ out: StepOutput) -> [Int] {
        out.intents.compactMap { if case let .click(_, _, count) = $0 { return count } else { return nil } }
    }

    private func downs(_ out: StepOutput) -> Int {
        out.intents.filter { if case .down = $0 { return true } else { return false } }.count
    }

    private func ups(_ out: StepOutput) -> Int {
        out.intents.filter { if case .up = $0 { return true } else { return false } }.count
    }

    private func zoomProduct(_ out: StepOutput) -> Double {
        out.intents.reduce(1) { if case let .zoom(f, .changed) = $1 { return $0 * f } else { return $0 } }
    }

    private func tap(_ t: Double, at start: Double, for duration: Double = 0.12) -> Double {
        SyntheticStream.tapAmount(at: t, start: start, duration: duration)
    }

    // MARK: Click

    func testPinchTapClicksOnceWhereThePointerRested() {
        let frames = stream(duration: 3) { t, h in h.pinchAmount = self.tap(t, at: 1.5) }
        let all = Evaluation.run(frames, config: config(click: .pinch))
        let out = Evaluation.merged(all)
        XCTAssertEqual(clicks(out), [1])
        XCTAssertEqual(downs(out), 0)
        // It lands where the cursor rested before the pinch pulled the fingertip.
        let rest = Evaluation.merged(all, to: 1.4).intents.compactMap { i -> Point2? in
            if case let .move(x, y) = i { return Point2(x, y) } else { return nil } }.last
        let clicked = out.intents.compactMap { i -> Point2? in
            if case let .click(x, y, _) = i { return Point2(x, y) } else { return nil } }.first
        if let rest, let clicked { XCTAssertLessThan(rest.distance(to: clicked), 8) } else { XCTFail("no rest or click") }
    }

    func testTwoQuickPinchesDoubleClick() {
        let frames = stream(duration: 3) { t, h in h.pinchAmount = max(self.tap(t, at: 1.5), self.tap(t, at: 1.8)) }
        XCTAssertEqual(clicks(run(frames, config(click: .pinch))), [1, 2])
    }

    func testPinchHeldWithoutPinchDragClicksOnce() {
        let frames = stream(duration: 3.5) { t, h in h.pinchAmount = self.tap(t, at: 1.5, for: 1.0) }
        let out = run(frames, config(click: .pinch, drag: .fistHold))
        XCTAssertEqual(clicks(out), [1])
        XCTAssertEqual(downs(out), 0)
    }

    func testPinchIsIgnoredByTheWiggleDefault() {
        let frames = stream(duration: 3) { t, h in h.pinchAmount = self.tap(t, at: 1.5) }
        XCTAssertEqual(clicks(run(frames, config())), [])
    }

    func testMiddlePinchClicks() {
        let frames = stream(duration: 3) { t, h in
            h.pinchFinger = .middle
            h.pinchAmount = self.tap(t, at: 1.5)
        }
        XCTAssertEqual(clicks(run(frames, config(click: .middlePinch))), [1])
    }

    /// Finger gun: thumb up (cocked), then down against the index: one click per pull.
    func testThumbTriggerClicksOnEachPull() {
        let frames = stream(duration: 4) { t, h in
            let down = (t > 1.5 && t < 1.7) || (t > 2.6 && t < 2.8)
            h.thumbSpread = down ? 0 : 1
        }
        XCTAssertEqual(clicks(run(frames, config(click: .thumbTrigger))).count, 2)
    }

    /// A thumb resting against the index from the start never clicks: it must be cocked first.
    func testThumbTriggerNeedsCocking() {
        let frames = stream(duration: 3) { _, h in h.thumbSpread = 0 }
        XCTAssertEqual(clicks(run(frames, config(click: .thumbTrigger))), [])
    }

    func testQuickFistClicksAndHeldFistStillDrags() {
        let quick = stream(duration: 3) { t, h in if t > 1.5 && t < 1.65 { h.makeFist() } }
        let quickOut = run(quick, config(click: .quickFist))
        XCTAssertEqual(clicks(quickOut), [1])
        XCTAssertEqual(downs(quickOut), 0)

        let held = stream(duration: 4) { t, h in if t > 1.5 && t < 2.8 { h.makeFist() } }
        let heldOut = run(held, config(click: .quickFist))
        XCTAssertEqual(clicks(heldOut), [])
        XCTAssertEqual(downs(heldOut), 1)
        XCTAssertEqual(ups(heldOut), 1)
    }

    func testDwellClicksOncePerStop() {
        let frames = stream(duration: 6, offset: { t in
            // Rest, move away at 2.5 s, rest again.
            Point2(0.1, 0) * MotionSynthetic.minimumJerk((t - 2.5) / 0.5)
        }) { _, _ in }
        XCTAssertEqual(clicks(run(frames, config(click: .dwell))).count, 2)
    }

    func testDwellProgressFillsBeforeTheClick() {
        let machine = PointerStateMachine(config: config(click: .dwell), displays: [Evaluation.defaultDisplay])
        _ = machine.setEngaged(true, at: 0)
        var peak = 0.0
        for frame in stream(duration: 0.8, noise: 0) { _, _ in } {
            _ = machine.process(frame)
            peak = max(peak, machine.snapshot.clickProgress)
        }
        XCTAssertGreaterThan(peak, 0.3)
        XCTAssertLessThan(peak, 1)
    }

    // MARK: Drag

    func testPinchHoldDragsAndQuickPinchStillClicks() {
        let frames = stream(duration: 5, offset: { t in Point2(0.08, 0.04) * MotionSynthetic.minimumJerk((t - 2.0) / 0.5) }) { t, h in
            h.pinchAmount = self.tap(t, at: 1.5, for: 1.6)
        }
        let out = run(frames, config(click: .pinch, drag: .pinchHold))
        XCTAssertEqual(downs(out), 1)
        XCTAssertEqual(ups(out), 1)
        XCTAssertEqual(clicks(out), [])

        let quick = stream(duration: 3) { t, h in h.pinchAmount = self.tap(t, at: 1.5) }
        let quickOut = run(quick, config(click: .pinch, drag: .pinchHold))
        XCTAssertEqual(clicks(quickOut), [1])
        XCTAssertEqual(downs(quickOut), 0)
    }

    func testFistToggleKeepsTheButtonDownUntilTheNextFist() {
        let all = Evaluation.run(stream(duration: 5, offset: { t in Point2(0.08, 0) * MotionSynthetic.minimumJerk((t - 2.2) / 0.5) }) { t, h in
            if (t > 1.5 && t < 1.95) || (t > 3.5 && t < 3.9) { h.makeFist() }
        }, config: config(drag: .fistToggle))
        let whileOpen = Evaluation.merged(all, to: 3.4)
        XCTAssertEqual(downs(whileOpen), 1)
        XCTAssertEqual(ups(whileOpen), 0, "opening the hand must not drop")
        XCTAssertEqual(ups(Evaluation.merged(all)), 1)
    }

    func testDragOffNeverPresses() {
        let frames = stream(duration: 4) { t, h in if t > 1.5 && t < 3 { h.makeFist() } }
        XCTAssertEqual(downs(run(frames, config(drag: .off))), 0)
    }

    // MARK: Zoom

    func testTwoFistsSpreadingZoomIn() {
        let out = run(SyntheticStream.twoFists(spreadChange: 0.12), config(zoom: .twoFistSpread))
        XCTAssertEqual(out.events.filter { $0 == .zoomStarted }.count, 1)
        XCTAssertTrue(out.intents.contains(.zoom(factor: 1, phase: .began)))
        XCTAssertGreaterThan(zoomProduct(out), 1.25)
        XCTAssertEqual(downs(out), 0, "the pointing fist must not drag while zooming")
    }

    func testTwoFistsClosingZoomOut() {
        let out = run(SyntheticStream.twoFists(spreadChange: -0.08), config(zoom: .twoFistSpread))
        XCTAssertLessThan(zoomProduct(out), 0.8)
    }

    func testTwoPinchesSpreadingZoomIn() {
        let frames = stream(duration: 3, offset: { t in Point2(0.04, 0) * MotionSynthetic.minimumJerk((t - 1.5) / 0.5) },
                            other: { t in self.otherHand(x: 0.7 + 0.04 * MotionSynthetic.minimumJerk((t - 1.5) / 0.5),
                                                         pinch: t > 1.0 && t < 2.5 ? 1 : 0) }) { t, h in
            h.pinchAmount = t > 1.0 && t < 2.5 ? 1 : 0
        }
        let out = run(frames, config(click: .pinch, zoom: .twoPinchSpread))
        XCTAssertGreaterThan(zoomProduct(out), 1.1)
        XCTAssertEqual(clicks(out), [], "the pointing pinch belongs to the zoom")
    }

    func testOtherHandFistRaisedZoomsInWhileThePointerHolds() {
        let frames = stream(duration: 3, other: { t in
            self.otherHand(lift: 0.1 * MotionSynthetic.minimumJerk((t - 1.4) / 0.6), fist: t > 1.0 && t < 2.4)
        }) { _, _ in }
        let out = run(frames, config(zoom: .otherFistUpDown))
        XCTAssertGreaterThan(zoomProduct(out), 1.3)
        XCTAssertEqual(downs(out), 0)
    }

    func testOtherHandPinchLoweredZoomsOut() {
        let frames = stream(duration: 3, other: { t in
            self.otherHand(lift: -0.1 * MotionSynthetic.minimumJerk((t - 1.4) / 0.6), pinch: t > 1.0 && t < 2.4 ? 1 : 0)
        }) { _, _ in }
        XCTAssertLessThan(zoomProduct(run(frames, config(zoom: .otherPinchUpDown))), 0.8)
    }

    func testZoomOffIgnoresTwoFists() {
        let out = run(SyntheticStream.twoFists(), config())
        XCTAssertFalse(out.events.contains(.zoomStarted))
    }

    func testHandLostMidZoomEndsIt() {
        var frames = SyntheticStream.twoFists()
        frames = Array(frames.prefix { $0.timestamp < 1.3 })
        frames += SyntheticStream.handLost(visibleUntil: 0, duration: 0.5).map { TrackingFrame(timestamp: $0.timestamp + 1.3, hands: []) }
        let out = run(frames, config(zoom: .twoFistSpread))
        XCTAssertEqual(out.events.filter { $0 == .zoomStarted }.count, 1)
        XCTAssertEqual(out.events.filter { $0 == .zoomEnded }.count, 1)
        XCTAssertTrue(out.intents.contains(.zoom(factor: 1, phase: .ended)))
    }

    // MARK: Settings

    func testOldSettingsDecodeWithTodaysGestures() throws {
        let c = try GestureConfig.decodeLenient(Data(#"{"boxScale": 1.1}"#.utf8))
        XCTAssertEqual(c.clickGesture, .wiggle)
        XCTAssertEqual(c.dragGesture, .fistHold)
        XCTAssertEqual(c.zoomGesture, .off)
        var changed = GestureConfig()
        changed.clickGesture = .dwell
        changed.zoomGesture = .otherPinchUpDown
        let round = try GestureConfig.decodeLenient(JSONEncoder().encode(changed))
        XCTAssertEqual(round.clickGesture, .dwell)
        XCTAssertEqual(round.zoomGesture, .otherPinchUpDown)
    }
}
