import XCTest
@testable import GestureCore

/// The gestures: the cursor goes where the finger points (a laser pointer, at every speed), a
/// wiggle clicks where it began, a fist drags (open it to drop), two open palms toggle engagement.
final class WiggleClickTests: XCTestCase {
    private let config = GestureConfig()

    /// The other hand in a frame: its pose and offset (hand space) from its spot on the
    /// camera's right.
    private struct Other {
        var pose: HandPose
        var offset = Point2.zero
    }

    /// A right hand at a fixed spot plus `offset(t)` (hand space), pointing or (while `fist(t)`)
    /// a fist, optionally noisy, and another hand while `other(t)` returns one.
    private func stream(fps: Double = 60, duration: Double, noise: Double = 0,
                        fist: @escaping (Double) -> Bool = { _ in false },
                        other: @escaping (Double) -> Other? = { _ in nil },
                        offset: @escaping (Double) -> Point2) -> [TrackingFrame] {
        var rng = SeededRandom(seed: 5)
        return (0..<Int((duration * fps).rounded())).map { i in
            let t = Double(i) / fps
            var hand = MotionSynthetic.placedHand(tip: Point2(0.45, 0.45), size: 0.12, offset: offset(t))
            if fist(t) { hand.makeFist() }
            var hands = [hand.frame(at: t, noise: noise, rng: &rng)]
            if let spec = other(t) {
                var second = SyntheticHand(wrist: .zero)
                second.size = 0.12
                second.chirality = .left
                second.wrist = second.wristPlacing(indexTipAt: SyntheticHand.imagePoint(Point2(0.75, 0.45), offset: spec.offset))
                switch spec.pose {
                case .fist: second.makeFist()
                case .openPalm: second.makeOpenPalm()
                case .point: break
                }
                hands.append(second.frame(at: t, noise: noise, rng: &rng))
            }
            return TrackingFrame(timestamp: t, hands: hands)
        }
    }

    /// Move from the rest spot to `to` over `duration` starting at `start`.
    private func move(_ t: Double, start: Double, to: Point2, duration: Double = 0.5) -> Point2 {
        to * MotionSynthetic.minimumJerk((t - start) / duration)
    }

    /// Back-and-forth along `axis`: `count` strokes of `amplitude`, each `stroke` seconds long.
    private func wiggle(_ t: Double, start: Double, axis: Point2, amplitude: Double = 0.06, stroke: Double = 0.18,
                        count: Int = 4) -> Point2 {
        let u = (t - start) / stroke
        guard u > 0 else { return .zero }
        guard u < Double(count) else { return count % 2 == 1 ? axis * amplitude : .zero }
        let n = Int(u)
        let within = MotionSynthetic.minimumJerk(u - Double(n))
        return axis * (amplitude * (n % 2 == 0 ? within : 1 - within))
    }

    private func run(_ frames: [TrackingFrame], _ config: GestureConfig? = nil) -> [Evaluation.TimedOutput] {
        Evaluation.run(frames, config: config ?? self.config)
    }

    func testDefaults() {
        XCTAssertEqual(GestureConfig().shake.reversals, 2)
        XCTAssertEqual(GestureConfig().shake.window, 1.0)
    }

    // MARK: Pointing and click

    /// Move to a target (0.5–1.0 s), then `after(t)`.
    private func moveThen(fps: Double = 60, duration: Double = 5, noise: Double = 0.0008,
                          _ after: @escaping (Double) -> Point2) -> [TrackingFrame] {
        stream(fps: fps, duration: duration, noise: noise) { t in
            self.move(t, start: 0.5, to: Point2(0.08, 0.05)) + after(t)
        }
    }

    private func firstTime(_ outputs: [Evaluation.TimedOutput], _ test: (StepOutput) -> Bool) -> Double? {
        outputs.first { test($0.output) }?.time
    }

    func testStillHandNeverClicks() {
        for fps in [30.0, 60.0] {
            let out = Evaluation.merged(run(moveThen(fps: fps, duration: 6) { _ in .zero }))
            XCTAssertEqual(out.clicks.count + out.downs, 0, "resting never clicks (\(fps) fps)")
        }
        XCTAssertEqual(Evaluation.merged(run(stream(duration: 4) { _ in .zero })).clicks.count, 0)
    }

    func testWiggleClicksRightAwayWhereThePointerWas() {
        for fps in [30.0, 60.0] {
            for axis in [Point2(1, 0), Point2(0, 1)] {
                // Left-right-left (two changes of direction) once the pointer is where the user
                // wants it. Nothing to wait for first.
                let frames = moveThen(fps: fps) { self.wiggle($0, start: 2.0, axis: axis, count: 3) }
                let outputs = run(frames)
                let out = Evaluation.merged(outputs)
                XCTAssertEqual(out.clicks.count, 1, "\(fps) fps, axis \(axis)")
                XCTAssertEqual(out.downs, 0, "a click wiggle never presses")
                guard let click = out.clicks.first, let arrived = Evaluation.merged(outputs, to: 2.0).moves.last else {
                    XCTFail("no click")
                    continue
                }
                XCTAssertEqual(click.0, arrived.x, accuracy: 8, "clicks where the pointer was (\(fps) fps, \(axis))")
                XCTAssertEqual(click.1, arrived.y, accuracy: 8)
                XCTAssertEqual(click.2, 1)
                let clickTime = firstTime(outputs) { !$0.clicks.isEmpty } ?? 9
                XCTAssertLessThan(clickTime, 2.0 + 0.6, "no waiting")
                // The cursor then sits on the click point while the hand settles.
                let afterClick = Evaluation.merged(outputs, from: clickTime + 0.001, to: clickTime + 0.1).moves
                XCTAssertTrue(afterClick.allSatisfy { $0.distance(to: Point2(click.0, click.1)) < 1 },
                              "held on the click point (\(fps) fps, \(axis))")
            }
        }
    }

    func testWiggleRightAfterArrivingClicks() {
        // No rest needed: a wiggle 0.1 s after the hand arrives clicks near where it arrived.
        let outputs = run(moveThen { self.wiggle($0, start: 1.1, axis: Point2(1, 0), count: 3) })
        let out = Evaluation.merged(outputs)
        XCTAssertEqual(out.clicks.count, 1)
        if let click = out.clicks.first, let arrived = Evaluation.merged(outputs, to: 1.1).moves.last {
            XCTAssertLessThan(Point2(click.0, click.1).distance(to: arrived), 30)
        }
    }

    /// Where the cursor ends up after the hand comes to rest at `to`, moving there by `path`.
    private func restingCursor(_ path: @escaping (Double) -> Point2, fps: Double = 60) -> Point2? {
        Evaluation.merged(run(moveThen(fps: fps, duration: 5, path))).moves.last
    }

    func testFastMoveGoesAllTheWayLikeALaserPointer() {
        for fps in [30.0, 60.0] {
            // A quick 0.25 s sweep and a calm 1.5 s move to the same spot end in the same place.
            let fast = restingCursor({ self.move($0, start: 1.5, to: Point2(0.1, 0.04), duration: 0.25) }, fps: fps)
            let slow = restingCursor({ self.move($0, start: 1.5, to: Point2(0.1, 0.04), duration: 1.5) }, fps: fps)
            guard let fast, let slow else { return XCTFail("no moves") }
            XCTAssertLessThan(fast.distance(to: slow), 6, "fast and slow moves land on the same spot (\(fps) fps)")
        }
    }

    func testCursorAlwaysEndsWhereTheHandPoints() {
        // Fast sweep right, then a slow move left: the cursor ends where a direct move would put
        // it. Nothing (no freeze, no gain) builds up an offset between hand and cursor.
        let detour = restingCursor { t in
            self.move(t, start: 1.5, to: Point2(0.1, 0), duration: 0.25)
                + self.move(t, start: 2.5, to: Point2(-0.05, 0), duration: 1.5)
        }
        let direct = restingCursor { self.move($0, start: 1.5, to: Point2(0.05, 0), duration: 0.8) }
        guard let detour, let direct else { return XCTFail("no moves") }
        XCTAssertLessThan(detour.distance(to: direct), 6)
    }

    func testSlowMovementMovesTheCursor() {
        let frames = moveThen(duration: 5) { self.move($0, start: 1.5, to: Point2(0.1, 0.04), duration: 1.5) }
        let outputs = run(frames)
        guard let arrived = Evaluation.merged(outputs, to: 1.5).moves.last,
              let end = Evaluation.merged(outputs).moves.last else { return XCTFail("no moves") }
        XCTAssertGreaterThan(end.x - arrived.x, 200, "a calm move moves the cursor")
    }

    func testSmallMovesAreNotSwallowed() {
        // A 10 pt-ish nudge from a resting cursor moves it by about that much (no gain < 1, no
        // stick-slip): "it doesn't move enough" was the owner's complaint.
        let still = restingCursor { _ in .zero }
        let nudged = restingCursor { self.move($0, start: 2.0, to: Point2(0.004, 0), duration: 0.4) }
        guard let still, let nudged else { return XCTFail("no moves") }
        // 0.004 image widths through the default box: 0.004 / 0.42 × 1.08 × 1727 ≈ 17.8 pt.
        XCTAssertEqual(nudged.x - still.x, 17.8, accuracy: 5)
    }

    func testSlowWiggleWhileMovingClicksWhereItBegan() {
        // A wiggle too slow to freeze the cursor still clicks, where the cursor was as it began.
        let frames = moveThen { self.wiggle($0, start: 1.2, axis: Point2(1, 0), amplitude: 0.04, stroke: 0.3, count: 3) }
        let outputs = run(frames)
        let out = Evaluation.merged(outputs)
        XCTAssertEqual(out.clicks.count, 1)
        guard let click = out.clicks.first, let start = Evaluation.merged(outputs, to: 1.2).moves.last else {
            return XCTFail("no click")
        }
        XCTAssertEqual(click.0, start.x, accuracy: 15)
        XCTAssertEqual(click.1, start.y, accuracy: 15)
    }

    func testTwoQuickWigglesDoubleClick() {
        let frames = moveThen { t in
            self.wiggle(t, start: 1.2, axis: Point2(1, 0), count: 3) + self.wiggle(t, start: 2.0, axis: Point2(1, 0), count: 3)
        }
        let clicks = Evaluation.merged(run(frames)).clicks
        XCTAssertEqual(clicks.map(\.2), [1, 2])
    }

    func testOrdinaryMovementNeverClicks() {
        // (A quick double tap is down-up-down-up: a wiggle, so it is left out.)
        for label in [GestureLabel.repositionFast, .repositionSlow, .fineTarget, .click, .drag, .rest, .jitter,
                      .outOfFrame] {
            for i in 0..<40 {
                let sample = MotionSynthetic.sample(label, fps: i % 2 == 0 ? 60 : 30, seed: UInt64(i + 1))
                let out = Evaluation.merged(run(sample.frames))
                XCTAssertEqual(out.clicks.count + out.downs, 0, "\(label.rawValue) \(i) clicked")
            }
        }
    }

    func testTinyTremorIsNotAWiggle() {
        let frames = stream(duration: 4) { self.wiggle($0, start: 0.5, axis: Point2(0, 1), amplitude: 0.01, stroke: 0.1, count: 30) }
        XCTAssertEqual(Evaluation.merged(run(frames)).clicks.count, 0)
    }

    func testDetectorCountsChangesPerAxis() {
        var detector = ShakeDetector(params: ShakeParams())
        var detections: [ShakeDetector.Detection] = []
        for i in 0..<120 {
            let t = Double(i) / 60
            let y = wiggle(t, start: 0.2, axis: Point2(0, 1), count: 3).y
            if let d = detector.update(point: Point2(0.5, 0.3 + y), handSize: 0.12, at: t) { detections.append(d) }
        }
        XCTAssertEqual(detections.count, 1)
        XCTAssertEqual(detections.first?.vertical, true)
        XCTAssertEqual(detections.first?.startTime ?? -1, 0.2, accuracy: 0.05)
    }

    // MARK: Fist drag

    /// Arrive (0.5–1.0 s), fist at 1.5 s, move the fist at 2.0 s, rest, open it at `open`.
    private func fistDrag(fps: Double = 60, to: Point2 = Point2(0.1, 0.04), open: Double = 4.0) -> [TrackingFrame] {
        stream(fps: fps, duration: open + 1.5, noise: 0.0006, fist: { $0 >= 1.5 && $0 < open }) { t in
            self.move(t, start: 0.5, to: Point2(0.08, 0.05)) + self.move(t, start: 2.0, to: to, duration: 1.0)
        }
    }

    func testFistPressesWhereThePointerWasAndOpeningItDrops() {
        for fps in [30.0, 60.0] {
            let outputs = run(fistDrag(fps: fps))
            let out = Evaluation.merged(outputs)
            XCTAssertEqual(out.downs, 1, "\(fps) fps")
            XCTAssertEqual(out.ups, 1, "\(fps) fps")
            XCTAssertEqual(out.clicks.count, 0)
            guard let arrived = Evaluation.merged(outputs, to: 1.49).moves.last,
                  case let .down(x, y)? = out.intents.first(where: { if case .down = $0 { return true } else { return false } }),
                  case let .up(ux, uy)? = out.intents.first(where: { if case .up = $0 { return true } else { return false } })
            else { return XCTFail("no press or release (\(fps) fps)") }
            // Pressed where the pointer was before the hand closed, as soon as the fist formed.
            XCTAssertEqual(x, arrived.x, accuracy: 3)
            XCTAssertEqual(y, arrived.y, accuracy: 3)
            let downTime = firstTime(outputs) { $0.downs > 0 } ?? 0
            XCTAssertLessThan(downTime, 1.5 + 0.45, "pressed once the fist is held a moment")
            let dragMoves = Evaluation.merged(outputs, from: downTime + 0.001, to: 4.0).moves
            XCTAssertGreaterThan(dragMoves.last.map { $0.x - arrived.x } ?? 0, 100, "dragged right (\(fps) fps)")
            // Dropped where the cursor was, after the fist opened, and opening the hand doesn't
            // move the cursor.
            let upTime = firstTime(outputs) { $0.ups > 0 } ?? 0
            XCTAssertGreaterThanOrEqual(upTime, 4.0)
            XCTAssertLessThan(upTime, 4.2)
            if let last = dragMoves.last {
                XCTAssertEqual(ux, last.x, accuracy: 1)
                XCTAssertEqual(uy, last.y, accuracy: 1)
            }
            XCTAssertTrue(Evaluation.merged(outputs, from: upTime).moves.allSatisfy { $0.distance(to: Point2(ux, uy)) < 8 }, "opening the hand doesn't move the cursor")
        }
    }

    func testOpeningTheFistBeforeMovingDropsInPlace() {
        let frames = stream(duration: 4, noise: 0.0006, fist: { $0 >= 1.5 && $0 < 2.0 }) {
            self.move($0, start: 0.5, to: Point2(0.08, 0.05))
        }
        let out = Evaluation.merged(run(frames))
        XCTAssertEqual(out.downs, 1)
        XCTAssertEqual(out.ups, 1)
    }

    func testBriefFistDoesNotPress() {
        let frames = stream(duration: 3, noise: 0.0006, fist: { $0 >= 1.5 && $0 < 1.65 }) {
            self.move($0, start: 0.5, to: Point2(0.08, 0.05))
        }
        XCTAssertEqual(Evaluation.merged(run(frames)).downs, 0)
    }

    func testFistHeldWhileEngagingDoesNotPress() {
        let frames = stream(duration: 3, fist: { _ in true }) { _ in .zero }
        XCTAssertEqual(Evaluation.merged(run(frames)).downs, 0)
    }

    func testTwoFistsNeitherZoomNorScroll() {
        // Two-hand zoom and scroll are gone: only the pointing hand's fist counts (a drag).
        let frames = stream(duration: 5, noise: 0.0006, fist: { $0 >= 1.5 },
                            other: { $0 >= 1.2 ? Other(pose: $0 >= 1.5 ? .fist : .point,
                                                        offset: self.move($0, start: 2.0, to: Point2(-0.06, 0.04))) : nil }) {
            self.move($0, start: 2.0, to: Point2(0.06, 0.04))
        }
        let out = Evaluation.merged(run(frames))
        XCTAssertEqual(out.zooms.count + out.scrolls(.began).count + out.clicks.count, 0)
        XCTAssertEqual(out.downs, 1)
    }

    func testLoneHandPointsWhateverVisionCallsIt() {
        // Vision's chirality flips now and then; a lone hand labelled "left" used to be ignored,
        // which stopped the cursor for no visible reason.
        let mislabelled = stream(duration: 3) { self.move($0, start: 0.5, to: Point2(0.08, 0.05)) }.map { frame in
            TrackingFrame(timestamp: frame.timestamp, hands: frame.hands.map { var h = $0; h.chirality = .left; return h })
        }
        let out = Evaluation.merged(run(mislabelled))
        XCTAssertGreaterThan(out.moves.count, 10)
        XCTAssertEqual(out.clicks.count + out.downs, 0)
    }

    private let small = DisplayInfo(id: "S", frame: Rect(x: 0, y: 0, width: 1440, height: 900))
    private let big = DisplayInfo(id: "B", frame: Rect(x: 1440, y: 0, width: 2560, height: 1440))

    func testPointerStaysOnTheDisplayTheMouseWasOnWhenEngaged() {
        for (mouse, id, range) in [(Point2(100, 100), "S", 0.0..<1440.0), (Point2(2000, 300), "B", 1440.0..<4000.0)] {
            let machine = PointerStateMachine(config: config, displays: [small, big])
            _ = machine.setEngaged(true, at: 0, mouseLocation: mouse)
            var out = StepOutput()
            // Sweep to the far edge and hold there: no jump to the other display.
            for frame in stream(duration: 3, offset: { self.move($0, start: 0.5, to: Point2(0.4, 0), duration: 0.6) }) {
                out.append(machine.process(frame))
            }
            XCTAssertEqual(machine.snapshot.displayID, id)
            XCTAssertFalse(out.moves.isEmpty)
            XCTAssertTrue(out.moves.allSatisfy { range.contains($0.x) }, "every move stays on \(id)")
            XCTAssertFalse(out.events.contains { if case .displayChanged = $0 { return true } else { return false } })
            // Touching the real mouse on the other display doesn't move the hand's display.
            _ = machine.noteExternalMouse(at: id == "S" ? Point2(2000, 300) : Point2(100, 100), time: 3.1)
            XCTAssertEqual(machine.snapshot.displayID, id)
        }
    }

    func testPalmEngageStartsOnTheMousesDisplay() {
        let machine = PointerStateMachine(config: config, displays: [small, big])
        machine.realMouseLocation = Point2(2000, 300)
        for frame in SyntheticStream.palmHold(hold: 1.0) { _ = machine.process(frame) }
        XCTAssertTrue(machine.isEngaged)
        XCTAssertEqual(machine.snapshot.displayID, "B")
    }

    // MARK: Owner recording

    /// The owner's first free-form session (recordings/owner-freeform-2026-10-12.json): pointing,
    /// finger wags while moving, the left hand raised twice, and fists — a brief one after a rest
    /// at ~16 s and longer ones while moving at ~13 s, ~57 s and ~60–62 s. They engaged with one
    /// palm, which doesn't toggle, so the replay engages as the hotkey would. Under "a wiggle
    /// clicks any time" the wags click; every fist held a moment drags, and nothing else presses.
    func testOwnerRecordingFistsDragAndNothingElsePresses() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("recordings/owner-freeform-2026-10-12.json")
        var recorded = try Recording.load(from: url).rebased()
        // Replay with the settings it was recorded with, but today's gesture defaults.
        guard let json = recorded.info["config"], var settings = try? GestureConfig.decodeLenient(Data(json.utf8)) else {
            return XCTFail("recording has no config")
        }
        settings.shake = ShakeParams()
        recorded.info["config"] = nil
        let machine = PointerStateMachine(config: settings, displays: [testDisplay])
        _ = machine.setEngaged(true, at: recorded.frames.first?.timestamp ?? 0)
        var log: [(Double, StepOutput)] = []
        for frame in recorded.frames { log.append((frame.timestamp, machine.process(frame))) }
        let out = log.reduce(into: StepOutput()) { $0.append($1.1) }
        XCTAssertFalse(out.events.contains(.disengaged(.palm)), "one palm never toggles")
        XCTAssertGreaterThan(out.moves.count, 100)
        XCTAssertEqual(out.scrolls(.began).count + out.zooms.count, 0)
        XCTAssertEqual(out.downs, out.ups, "every press is released")
        // Presses only where the owner held a fist.
        let fists: [ClosedRange<Double>] = [12.6...13.8, 15.8...16.6, 56.3...57.6, 59.4...62.3]
        let pressTimes = log.filter { $0.1.downs > 0 }.map(\.0)
        XCTAssertTrue(pressTimes.contains { (15.8...16.6).contains($0) }, "the fist after the rest drags")
        for time in pressTimes {
            XCTAssertTrue(fists.contains { $0.contains(time) }, "press at \(time) s outside a held fist")
        }
    }

    // MARK: Engagement and modes

    func testBothPalmsStillToggleEngagement() {
        let machine = PointerStateMachine(config: config, displays: [testDisplay])
        var out = StepOutput()
        for frame in SyntheticStream.palmHold(hold: 1.0) { out.append(machine.process(frame)) }
        XCTAssertTrue(out.events.contains(.engaged))
        XCTAssertTrue(machine.isEngaged)
        // Both palms again: off, without pressing, clicking or dragging anything on the way.
        out = StepOutput()
        for frame in SyntheticStream.palmHold(hold: 1.2) {
            out.append(machine.process(TrackingFrame(timestamp: frame.timestamp + 2, hands: frame.hands)))
        }
        XCTAssertTrue(out.events.contains(.disengaged(.palm)))
        XCTAssertFalse(machine.isEngaged)
        XCTAssertEqual(out.downs + out.clicks.count + out.scrolls(.began).count + out.zooms.count, 0)
    }

    func testOnePalmDoesNotToggleEngagement() {
        do {
            let machine = PointerStateMachine(config: config, displays: [testDisplay])
            var out = StepOutput()
            for frame in SyntheticStream.palmHold(hold: 1.5, bothHands: false) { out.append(machine.process(frame)) }
            XCTAssertFalse(machine.isEngaged)
            _ = machine.setEngaged(true, at: 3)
            for frame in SyntheticStream.palmHold(hold: 1.5, bothHands: false) {
                out.append(machine.process(TrackingFrame(timestamp: frame.timestamp + 3, hands: frame.hands)))
            }
            XCTAssertTrue(machine.isEngaged, "one palm doesn't disengage either")
        }
    }

    func testBriefDropoutOfOneHandDoesNotRestartThePalmHold() {
        let frames = SyntheticStream.palmHold(hold: 1.0).map { frame -> TrackingFrame in
            // The left hand vanishes for one frame halfway through the hold.
            abs(frame.timestamp - 0.6) < 0.01 ? TrackingFrame(timestamp: frame.timestamp, hands: Array(frame.hands.prefix(1))) : frame
        }
        let machine = PointerStateMachine(config: config, displays: [testDisplay])
        var engagedAt: Double?
        for frame in frames where machine.process(frame).events.contains(.engaged) { engagedAt = frame.timestamp }
        XCTAssertLessThan(engagedAt ?? 99, 0.3 + config.palmEngageDuration + 0.15)
    }

    func testSettingsChangeMidDragKeepsTheDrag() {
        let machine = PointerStateMachine(config: config, displays: [testDisplay])
        _ = machine.setEngaged(true, at: 0)
        var out = StepOutput()
        for frame in fistDrag() where frame.timestamp < 3.2 { out.append(machine.process(frame)) }
        XCTAssertEqual(machine.state, .dragging)
        var changed = config
        changed.scrollSpeed = 2
        out.append(machine.updateConfig(changed))
        XCTAssertEqual(machine.state, .dragging)
        for frame in fistDrag() where frame.timestamp >= 3.2 { out.append(machine.process(frame)) }
        XCTAssertEqual(out.downs, 1)
        XCTAssertEqual(out.ups, 1)
    }
}
