import XCTest
@testable import GestureCore

/// Hold & wiggle, the default input model: hold still 2 s = click, three direction changes
/// along one axis within 1 s = scroll, everything else moves the cursor.
final class DwellShakeTests: XCTestCase {
    private let config = GestureConfig()

    /// A right pointing hand at a fixed spot plus `offset(t)` (hand space), optionally noisy,
    /// and a left hand (an open palm on the camera's right) while `left(t)` is true.
    private func stream(fps: Double = 60, duration: Double, noise: Double = 0,
                        left: @escaping (Double) -> Bool = { _ in false },
                        offset: @escaping (Double) -> Point2) -> [TrackingFrame] {
        var rng = SeededRandom(seed: 5)
        return (0..<Int((duration * fps).rounded())).map { i in
            let t = Double(i) / fps
            let hand = VelocitySynthetic.placedHand(tip: Point2(0.45, 0.45), size: 0.12, offset: offset(t))
            var hands = [hand.frame(at: t, noise: noise, rng: &rng)]
            if left(t) {
                var other = SyntheticHand(wrist: .zero)
                other.size = 0.12
                other.chirality = .left
                other.makeOpenPalm()
                other.wrist = other.wristPlacing(indexTipAt: Point2(0.8, 0.4))
                hands.append(other.frame(at: t, noise: noise, rng: &rng))
            }
            return TrackingFrame(timestamp: t, hands: hands)
        }
    }

    /// Move from the rest spot to `to` over `duration` starting at `start`.
    private func move(_ t: Double, start: Double, to: Point2, duration: Double = 0.5) -> Point2 {
        to * VelocitySynthetic.minimumJerk((t - start) / duration)
    }

    /// Back-and-forth along `axis`: `count` strokes of `amplitude`, each `stroke` seconds long.
    private func wiggle(_ t: Double, start: Double, axis: Point2, amplitude: Double = 0.06, stroke: Double = 0.18,
                        count: Int = 4) -> Point2 {
        let u = (t - start) / stroke
        guard u > 0 else { return .zero }
        guard u < Double(count) else { return count % 2 == 1 ? axis * amplitude : .zero }
        let n = Int(u)
        let within = VelocitySynthetic.minimumJerk(u - Double(n))
        return axis * (amplitude * (n % 2 == 0 ? within : 1 - within))
    }

    private func run(_ frames: [TrackingFrame], _ config: GestureConfig? = nil) -> [Evaluation.TimedOutput] {
        Evaluation.run(frames, config: config ?? self.config)
    }

    func testHoldAndWiggleIsTheDefault() {
        XCTAssertEqual(GestureConfig().inputModel, .dwellShake)
        XCTAssertEqual(GestureConfig().shake.lockTime, 1.0)
        XCTAssertEqual(GestureConfig().shake.wakeTime, 1.0)
        XCTAssertEqual(GestureConfig().shake.clickReversals, 2)
        XCTAssertEqual(GestureConfig().shake.reversals, 3)
        XCTAssertEqual(GestureConfig().shake.window, 1.0)
    }

    // MARK: Lock and click

    /// Move to a target (0.5–1.0 s), rest there (locks around 2.0 s), then `after(t)` from 2.5 s.
    private func restThen(fps: Double = 60, duration: Double = 6, noise: Double = 0.0008,
                          _ after: @escaping (Double) -> Point2) -> [TrackingFrame] {
        stream(fps: fps, duration: duration, noise: noise) { t in
            self.move(t, start: 0.5, to: Point2(0.08, 0.05)) + after(t)
        }
    }

    private func firstTime(_ outputs: [Evaluation.TimedOutput], _ test: (StepOutput) -> Bool) -> Double? {
        outputs.first { test($0.output) }?.time
    }

    func testHoldingStillLocksTheCursorAndNeverClicks() {
        for fps in [30.0, 60.0] {
            let frames = restThen(fps: fps) { _ in .zero }
            let machine = PointerStateMachine(config: config, displays: [testDisplay])
            _ = machine.setEngaged(true, at: 0)
            var out = StepOutput()
            for frame in frames { out.append(machine.process(frame)) }
            XCTAssertEqual(out.clicks.count + out.downs, 0, "resting never clicks (\(fps) fps)")
            XCTAssertNotNil(machine.cursorLock, "a resting cursor is locked (\(fps) fps)")
            XCTAssertEqual(machine.snapshot.dwellProgress, 1, "the ring shows the lock")
        }
    }

    func testEngagingWithAStillHandDoesNotClick() {
        let frames = stream(duration: 4) { _ in .zero }
        XCTAssertEqual(Evaluation.merged(run(frames)).clicks.count, 0)
    }

    func testWiggleAfterRestingClicksWhereTheCursorIsLocked() {
        for fps in [30.0, 60.0] {
            for axis in [Point2(1, 0), Point2(0, 1)] {
                // Left-right-left (two changes of direction), starting 2.5 s.
                let frames = restThen(fps: fps) { self.wiggle($0, start: 2.5, axis: axis, count: 3) }
                let outputs = run(frames)
                let out = Evaluation.merged(outputs)
                XCTAssertEqual(out.clicks.count, 1, "\(fps) fps, axis \(axis)")
                XCTAssertEqual(out.scrolls(.began).count + out.downs, 0, "a click wiggle never scrolls or presses")
                guard let click = out.clicks.first, let rest = Evaluation.merged(outputs, to: 2.0).moves.last else {
                    XCTFail("no click")
                    continue
                }
                XCTAssertEqual(click.0, rest.x, accuracy: 0.01, "clicks exactly where the pointer rests")
                XCTAssertEqual(click.1, rest.y, accuracy: 0.01)
                XCTAssertEqual(click.2, 1)
                // The pointer never moved: not during the wiggle, not after it.
                XCTAssertTrue(Evaluation.merged(outputs, from: 2.0).moves.allSatisfy { $0.distance(to: rest) < 0.01 },
                              "the cursor stays locked through and after the click (\(fps) fps)")
            }
        }
    }

    func testMovingWithoutAWiggleUnlocksOneSecondAfterTheMoveStarts() {
        for fps in [30.0, 60.0] {
            let frames = restThen(fps: fps) { self.move($0, start: 2.5, to: Point2(0.1, -0.08), duration: 0.5) }
            let outputs = run(frames)
            let out = Evaluation.merged(outputs)
            XCTAssertEqual(out.clicks.count, 0, "\(fps) fps")
            guard let rest = Evaluation.merged(outputs, to: 2.0).moves.last else { return XCTFail("no moves") }
            let firstMove = outputs.first { $0.time > 2.0 && $0.output.moves.contains { $0.distance(to: rest) > 1 } }?.time ?? 0
            XCTAssertGreaterThan(firstMove, 2.5 + 0.9, "the cursor waits about a second (\(fps) fps)")
            XCTAssertLessThan(firstMove, 2.5 + 1.3, "…then follows the hand (\(fps) fps)")
            // And it ends up where the hand points, as if it had followed all along.
            let free = Evaluation.merged(run(stream(fps: fps, duration: 6, noise: 0.0008) { t in
                self.move(t, start: 0.5, to: Point2(0.08, 0.05)) + self.move(t, start: 0.9, to: Point2(0.1, -0.08), duration: 0.5)
            })).moves.last
            if let end = out.moves.last, let free {
                XCTAssertEqual(end.x, free.x, accuracy: 12)
                XCTAssertEqual(end.y, free.y, accuracy: 12)
            }
        }
    }

    func testAfterAClickTheCursorStaysLockedUntilOneSecondAfterTheNextMove() {
        // Click wiggle at 2.5 s, rest, then move away at 4.0 s.
        let frames = restThen(duration: 7) { t in
            self.wiggle(t, start: 2.5, axis: Point2(1, 0), count: 3) + self.move(t, start: 4.0, to: Point2(-0.12, 0.06))
        }
        let outputs = run(frames)
        XCTAssertEqual(Evaluation.merged(outputs).clicks.count, 1)
        guard let rest = Evaluation.merged(outputs, to: 2.0).moves.last else { return XCTFail("no moves") }
        let firstMove = outputs.first { $0.time > 2.0 && $0.output.moves.contains { $0.distance(to: rest) > 1 } }?.time ?? 0
        XCTAssertGreaterThan(firstMove, 4.0 + 0.9)
        XCTAssertLessThan(firstMove, 4.0 + 1.3)
    }

    func testTwoQuickWigglesDoubleClick() {
        let frames = restThen(duration: 6) { t in
            self.wiggle(t, start: 2.5, axis: Point2(1, 0), count: 3) + self.wiggle(t, start: 3.2, axis: Point2(1, 0), count: 3)
        }
        let clicks = Evaluation.merged(run(frames)).clicks
        XCTAssertEqual(clicks.map(\.2), [1, 2])
    }

    func testAWiggleTooLateAfterTheMoveStartsDoesNotClick() {
        // A slow back-and-forth: its second change of direction comes after the wake window.
        let frames = restThen(duration: 7) { self.wiggle($0, start: 2.5, axis: Point2(1, 0), stroke: 0.6, count: 3) }
        XCTAssertEqual(Evaluation.merged(run(frames)).clicks.count, 0)
    }

    func testOrdinaryMovementNeverClicksOrScrolls() {
        // (A quick double tap is down-up-down-up: three direction changes, i.e. a wiggle.)
        for label in [GestureLabel.repositionFast, .repositionSlow, .fineTarget, .click, .drag] {
            for i in 0..<40 {
                let sample = VelocitySynthetic.sample(label, fps: i % 2 == 0 ? 60 : 30, seed: UInt64(i + 1))
                let out = Evaluation.merged(run(sample.frames))
                XCTAssertEqual(out.scrolls(.began).count, 0, "\(label.rawValue) \(i) scrolled")
                XCTAssertEqual(out.clicks.count + out.rightClicks + out.downs, 0, "\(label.rawValue) \(i) clicked")
            }
        }
    }

    // MARK: Scroll

    func testThreeDirectionChangesWithinASecondScrollsAlongThatAxis() {
        for fps in [30.0, 60.0] {
            // Wiggle up/down (4 strokes = 3 direction changes in ~0.7 s) before the cursor has
            // rested long enough to lock, then move the hand down.
            let frames = stream(fps: fps, duration: 4) { t in
                self.wiggle(t, start: 0.6, axis: Point2(0, 1)) + self.move(t, start: 1.6, to: Point2(0, 0.12))
            }
            let outputs = run(frames)
            let out = Evaluation.merged(outputs)
            XCTAssertEqual(out.scrolls(.began).count, 1, "\(fps) fps")
            XCTAssertEqual(out.scrolls(.ended).count, 1, "scroll ends when the hand holds still (\(fps) fps)")
            let changed = out.scrolls(.changed)
            XCTAssertGreaterThan(changed.map(\.1).reduce(0, +), 100, "moving down scrolls content down (natural)")
            XCTAssertEqual(changed.map { abs($0.0) }.reduce(0, +), 0, "vertical wiggle scrolls vertically only")
            XCTAssertEqual(out.clicks.count, 0, "a wiggle and a scroll never click")
            // The cursor goes back to where the wiggle started and stays there while scrolling.
            let before = Evaluation.merged(outputs, to: 0.6).moves.last
            let began = outputs.first { $0.output.scrolls(.began).count > 0 }?.time ?? 0
            let ended = outputs.first { $0.output.scrolls(.ended).count > 0 }?.time ?? 0
            XCTAssertGreaterThan(ended, 2.0, "still scrolling while the hand moves (\(fps) fps)")
            let during = Evaluation.merged(outputs, from: began + 0.001, to: ended - 0.001).moves
            XCTAssertEqual(during.count, 0, "cursor holds still while scrolling")
            if let before, let warp = Evaluation.merged(outputs, from: 0.6, to: 1.5).moves.last {
                XCTAssertEqual(warp.x, before.x, accuracy: 3)
                XCTAssertEqual(warp.y, before.y, accuracy: 3)
            }
        }
    }

    func testHorizontalWiggleScrollsSideways() {
        let frames = stream(duration: 4) { t in
            self.wiggle(t, start: 0.6, axis: Point2(1, 0)) + self.move(t, start: 1.6, to: Point2(0.12, 0))
        }
        let out = Evaluation.merged(run(frames))
        XCTAssertEqual(out.scrolls(.began).count, 1)
        let changed = out.scrolls(.changed)
        XCTAssertGreaterThan(abs(changed.map(\.0).reduce(0, +)), 100)
        XCTAssertEqual(changed.map { abs($0.1) }.reduce(0, +), 0)
    }

    func testTwoDirectionChangesAreJustMovement() {
        // While the cursor moves; a still hand would make this the click wiggle.
        let frames = stream(duration: 3) { self.wiggle($0, start: 0.6, axis: Point2(0, 1), count: 3) }
        let out = Evaluation.merged(run(frames))
        XCTAssertEqual(out.scrolls(.began).count + out.clicks.count, 0)
    }

    func testSlowBackAndForthIsJustMovement() {
        // Four strokes, but spread over 2.4 s: never three changes within one second.
        let frames = stream(duration: 5) { self.wiggle($0, start: 0.6, axis: Point2(0, 1), stroke: 0.6) }
        let out = Evaluation.merged(run(frames))
        XCTAssertEqual(out.scrolls(.began).count + out.clicks.count, 0)
    }

    func testTinyTremorIsNotAWiggle() {
        // Before and after the cursor locks: a tremor neither scrolls nor clicks.
        let frames = stream(duration: 4) { self.wiggle($0, start: 0.5, axis: Point2(0, 1), amplitude: 0.01, stroke: 0.1, count: 30) }
        let out = Evaluation.merged(run(frames))
        XCTAssertEqual(out.scrolls(.began).count + out.clicks.count, 0)
    }

    func testDetectorCountsChangesPerAxis() {
        var detector = ShakeDetector(params: ShakeParams())
        var detections: [ShakeDetector.Detection] = []
        for i in 0..<120 {
            let t = Double(i) / 60
            let y = wiggle(t, start: 0.2, axis: Point2(0, 1)).y
            if let d = detector.update(point: Point2(0.5, 0.3 + y), handSize: 0.12, at: t) { detections.append(d) }
        }
        XCTAssertEqual(detections.count, 1)
        XCTAssertEqual(detections.first?.vertical, true)
        XCTAssertEqual(detections.first?.startTime ?? -1, 0.2, accuracy: 0.05)
    }

    // MARK: Left hand: drag and zoom

    func testLeftHandTurnsMovementIntoADragAndDropsWhenItLeaves() {
        for fps in [30.0, 60.0] {
            // Left hand up from 1.0 to 3.0 s; the right hand moves at 1.5 s.
            let frames = stream(fps: fps, duration: 4, noise: 0.0006, left: { $0 >= 1.0 && $0 < 3.0 }) {
                self.move($0, start: 1.5, to: Point2(0.15, 0.05), duration: 0.6)
            }
            let outputs = run(frames)
            let out = Evaluation.merged(outputs)
            XCTAssertEqual(out.downs, 1, "\(fps) fps")
            XCTAssertEqual(out.ups, 1, "\(fps) fps")
            XCTAssertEqual(out.clicks.count + out.rightClicks, 0)
            XCTAssertEqual(out.scrolls(.began).count + out.zooms.count, 0)
            // Pressed where the cursor was when the left hand came up, dropped after it left.
            let before = Evaluation.merged(outputs, to: 1.0).moves.last
            if let before, case let .down(x, y)? = out.intents.first(where: { if case .down = $0 { return true } else { return false } }) {
                XCTAssertEqual(x, before.x, accuracy: 3)
                XCTAssertEqual(y, before.y, accuracy: 3)
            } else {
                XCTFail("no press")
            }
            let upTime = outputs.first { $0.output.ups > 0 }?.time ?? 0
            XCTAssertGreaterThan(upTime, 3.0)
            XCTAssertLessThan(upTime, 3.0 + 0.4)
        }
    }

    func testLeftHandUpWithoutMovingDoesNothing() {
        let frames = stream(duration: 4, left: { $0 >= 1.0 && $0 < 3.0 }) { _ in .zero }
        let out = Evaluation.merged(run(frames))
        XCTAssertEqual(out.downs + out.ups + out.clicks.count, 0)
    }

    func testSmallMoveThenStillAlsoDrags() {
        let frames = stream(duration: 4, left: { $0 >= 1.0 && $0 < 3.2 }) {
            self.move($0, start: 1.4, to: Point2(0.03, 0), duration: 0.3)   // 0.25 hand sizes
        }
        let outputs = run(frames)
        let out = Evaluation.merged(outputs)
        XCTAssertEqual(out.downs, 1)
        XCTAssertEqual(out.ups, 1)
        let downTime = outputs.first { $0.output.downs > 0 }?.time ?? 0
        XCTAssertLessThan(downTime, 3.0, "committed by holding still, before the left hand left")
    }

    func testOneFrameLeftHandDropoutDoesNotDrop() {
        let frames = stream(duration: 4, left: { $0 >= 1.0 && $0 < 3.0 && abs($0 - 2.5) > 0.01 }) {
            self.move($0, start: 1.5, to: Point2(0.15, 0), duration: 0.6)
        }
        let outputs = run(frames)
        XCTAssertEqual(Evaluation.merged(outputs).ups, 1)
        XCTAssertGreaterThan(outputs.first { $0.output.ups > 0 }?.time ?? 0, 3.0)
    }

    func testWiggleWithLeftHandUpZoomsInsteadOfScrolling() {
        for fps in [30.0, 60.0] {
            // Wiggle up/down with the left hand up, then move the right hand up: zoom in.
            let frames = stream(fps: fps, duration: 4.5, left: { $0 >= 0.8 && $0 < 4.0 }) { t in
                self.wiggle(t, start: 1.2, axis: Point2(0, 1)) + self.move(t, start: 2.2, to: Point2(0, -0.12))
            }
            let out = Evaluation.merged(run(frames))
            XCTAssertEqual(out.zooms.first?.1, .began, "\(fps) fps")
            XCTAssertTrue(out.zooms.contains { $0.1 == .ended }, "\(fps) fps")
            let total = out.zooms.filter { $0.1 == .changed }.map(\.0).reduce(1, *)
            XCTAssertGreaterThan(total, 1.3, "moving up zooms in (\(fps) fps)")
            XCTAssertEqual(out.downs + out.clicks.count + out.scrolls(.began).count, 0, "no press, click or scroll (\(fps) fps)")
        }
    }

    func testMovingDownAfterAZoomWiggleZoomsOut() {
        let frames = stream(duration: 4.5, left: { $0 >= 0.8 && $0 < 4.0 }) { t in
            self.wiggle(t, start: 1.2, axis: Point2(0, 1)) + self.move(t, start: 2.2, to: Point2(0, 0.12))
        }
        let total = Evaluation.merged(run(frames)).zooms.filter { $0.1 == .changed }.map(\.0).reduce(1, *)
        XCTAssertLessThan(total, 0.77)
    }

    func testRightClickIsGone() {
        // Sideways taps and a lone left hand never right-click (or click) in this model.
        let sample = VelocitySynthetic.sample(.rightClick, fps: 60, seed: 2)
        XCTAssertEqual(Evaluation.merged(run(sample.frames)).rightClicks, 0)
        let leftOnly = stream(duration: 3, left: { _ in true }) { _ in .zero }.map {
            TrackingFrame(timestamp: $0.timestamp, hands: Array($0.hands.dropFirst()))
        }
        let out = Evaluation.merged(run(leftOnly))
        XCTAssertEqual(out.moves.count + out.clicks.count + out.rightClicks, 0, "the left hand alone never points")
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

    /// The owner's first free-form session (recordings/owner-freeform-2026-10-12.json): they
    /// wagged the index finger while the palm stayed put, and raised the left hand twice. They
    /// engaged with one palm, which no longer toggles, so the replay engages as the hotkey would.
    func testOwnerRecordingFingerWiggleScrollsAndLeftHandDrags() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("recordings/owner-freeform-2026-10-12.json")
        var recorded = try Recording.load(from: url).rebased()
        // Replay with the settings it was recorded with, but today's Hold & wiggle defaults.
        if let json = recorded.info["config"], var settings = try? GestureConfig.decodeLenient(Data(json.utf8)) {
            settings.shake = ShakeParams()
            recorded.info["config"] = nil
            let machine = PointerStateMachine(config: settings, displays: [testDisplay])
            _ = machine.setEngaged(true, at: recorded.frames.first?.timestamp ?? 0)
            var log: [(Double, StepOutput)] = []
            for frame in recorded.frames { log.append((frame.timestamp, machine.process(frame))) }
            func any(_ range: ClosedRange<Double>, _ test: (StepOutput) -> Bool) -> Bool {
                log.contains { range.contains($0.0) && test($0.1) }
            }
            XCTAssertFalse(log.contains { $0.1.events.contains(.disengaged(.palm)) }, "one palm never toggles")
            // Finger wags (while the cursor was moving, so not locked): sideways around 29–32 s, up/down around 32–33 s and 39–41 s.
            XCTAssertTrue(any(29...32.5) { $0.scrolls(.began).count > 0 }, "sideways finger wag scrolls")
            XCTAssertTrue(any(39...41.5) { $0.scrolls(.began).count > 0 }, "up/down finger wag scrolls")
            // Left hand up 40–53 s and 70–78 s: drag and drop, once each.
            XCTAssertTrue(any(41...53) { $0.downs > 0 })
            XCTAssertTrue(any(70...78) { $0.downs > 0 })
            XCTAssertEqual(log.reduce(0) { $0 + $1.1.downs }, log.reduce(0) { $0 + $1.1.ups })
            XCTAssertEqual(log.reduce(0) { $0 + $1.1.clicks.count + $1.1.rightClicks }, 0,
                           "no wiggle came right after a rest, so nothing clicks")
        } else {
            XCTFail("recording has no config")
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
        for config in [config, .pose, .velocityMode] {
            let machine = PointerStateMachine(config: config, displays: [testDisplay])
            var out = StepOutput()
            for frame in SyntheticStream.palmHold(hold: 1.5, bothHands: false) { out.append(machine.process(frame)) }
            XCTAssertFalse(machine.isEngaged, "\(config.inputModel)")
            _ = machine.setEngaged(true, at: 3)
            for frame in SyntheticStream.palmHold(hold: 1.5, bothHands: false) {
                out.append(machine.process(TrackingFrame(timestamp: frame.timestamp + 3, hands: frame.hands)))
            }
            XCTAssertTrue(machine.isEngaged, "one palm doesn't disengage either (\(config.inputModel))")
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

    func testSwitchingModelMidScrollEndsTheScroll() {
        let frames = stream(duration: 1.8) { t in
            self.wiggle(t, start: 0.6, axis: Point2(0, 1)) + self.move(t, start: 1.4, to: Point2(0, 0.12), duration: 1)
        }
        let machine = PointerStateMachine(config: config, displays: [testDisplay])
        _ = machine.setEngaged(true, at: 0)
        for frame in frames { _ = machine.process(frame) }
        XCTAssertEqual(machine.state, .scrolling)
        let switched = machine.updateConfig(.velocityMode)
        XCTAssertEqual(switched.scrolls(.ended).count, 1)
    }
}
