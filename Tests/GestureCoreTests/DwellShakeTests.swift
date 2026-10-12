import XCTest
@testable import GestureCore

/// Hold & wiggle, the default input model: rest 1 s = the cursor locks; in the second after the
/// hand moves again a wiggle clicks and a fist drags (open it to drop); two fists zoom and
/// scroll by their last stroke before resting; two open palms toggle engagement.
final class DwellShakeTests: XCTestCase {
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
        XCTAssertEqual(GestureConfig().shake.lockTime, 1.0)
        XCTAssertEqual(GestureConfig().shake.wakeTime, 1.0)
        XCTAssertEqual(GestureConfig().shake.reversals, 2)
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
            XCTAssertEqual(machine.snapshot.lockProgress, 1, "the ring shows the lock")
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
        // (A quick double tap is down-up-down-up: a wiggle, so it is left out.)
        for label in [GestureLabel.repositionFast, .repositionSlow, .fineTarget, .click, .drag] {
            for i in 0..<40 {
                let sample = MotionSynthetic.sample(label, fps: i % 2 == 0 ? 60 : 30, seed: UInt64(i + 1))
                let out = Evaluation.merged(run(sample.frames))
                XCTAssertEqual(out.scrolls(.began).count, 0, "\(label.rawValue) \(i) scrolled")
                XCTAssertEqual(out.clicks.count + out.downs, 0, "\(label.rawValue) \(i) clicked")
            }
        }
    }

    func testTinyTremorIsNotAWiggle() {
        // Before and after the cursor locks: a tremor never clicks.
        let frames = stream(duration: 4) { self.wiggle($0, start: 0.5, axis: Point2(0, 1), amplitude: 0.01, stroke: 0.1, count: 30) }
        XCTAssertEqual(Evaluation.merged(run(frames)).clicks.count, 0)
    }

    func testAWiggleWhileTheCursorMovesDoesNothing() {
        // Wiggling is only a click while the cursor is locked; there is no one-hand scroll.
        let frames = stream(duration: 3) { self.wiggle($0, start: 0.4, axis: Point2(0, 1), count: 6) }
        let out = Evaluation.merged(run(frames))
        XCTAssertEqual(out.clicks.count + out.scrolls(.began).count + out.zooms.count + out.downs, 0)
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

    /// Rest (locks around 2 s), fist at 2.5 s, move the fist at 3.0 s, rest, open it at `open`.
    private func fistDrag(fps: Double = 60, to: Point2 = Point2(0.1, 0.04), open: Double = 5.5) -> [TrackingFrame] {
        stream(fps: fps, duration: open + 1.5, noise: 0.0006, fist: { $0 >= 2.5 && $0 < open }) { t in
            self.move(t, start: 0.5, to: Point2(0.08, 0.05)) + self.move(t, start: 3.0, to: to, duration: 0.5)
        }
    }

    func testFistInTheWakeWindowPressesAndOpeningItDrops() {
        for fps in [30.0, 60.0] {
            let outputs = run(fistDrag(fps: fps))
            let out = Evaluation.merged(outputs)
            XCTAssertEqual(out.downs, 1, "\(fps) fps")
            XCTAssertEqual(out.ups, 1, "\(fps) fps")
            XCTAssertEqual(out.clicks.count + out.scrolls(.began).count + out.zooms.count, 0)
            guard let rest = Evaluation.merged(outputs, to: 2.0).moves.last,
                  case let .down(x, y)? = out.intents.first(where: { if case .down = $0 { return true } else { return false } }),
                  case let .up(ux, uy)? = out.intents.first(where: { if case .up = $0 { return true } else { return false } })
            else { return XCTFail("no press or release (\(fps) fps)") }
            // Pressed exactly where the cursor was locked, as soon as the fist formed.
            XCTAssertEqual(x, rest.x, accuracy: 0.01)
            XCTAssertEqual(y, rest.y, accuracy: 0.01)
            let downTime = firstTime(outputs) { $0.downs > 0 } ?? 0
            XCTAssertLessThan(downTime, 2.8)
            // The dragged item waited a second after the fist moved, then went where it went.
            let dragMoves = Evaluation.merged(outputs, from: downTime + 0.001, to: 5.5).moves
            XCTAssertTrue(Evaluation.merged(outputs, from: downTime, to: 3.9).moves.allSatisfy { $0.distance(to: rest) < 1 })
            XCTAssertGreaterThan(dragMoves.last.map { $0.x - rest.x } ?? 0, 100, "dragged right (\(fps) fps)")
            // Dropped where the cursor rested, after the fist opened.
            let upTime = firstTime(outputs) { $0.ups > 0 } ?? 0
            XCTAssertGreaterThanOrEqual(upTime, 5.5)
            XCTAssertLessThan(upTime, 5.7)
            if let last = dragMoves.last {
                XCTAssertEqual(ux, last.x, accuracy: 1)
                XCTAssertEqual(uy, last.y, accuracy: 1)
            }
            // Opening the hand doesn't move the cursor.
            XCTAssertTrue(Evaluation.merged(outputs, from: upTime).moves.allSatisfy { $0.distance(to: Point2(ux, uy)) < 1 })
        }
    }

    func testOpeningTheFistBeforeMovingDropsInPlace() {
        // Fist at 2.5 s, opened at 3.0 s without moving: a press and release at the locked point.
        let frames = stream(duration: 5, noise: 0.0006, fist: { $0 >= 2.5 && $0 < 3.0 }) {
            self.move($0, start: 0.5, to: Point2(0.08, 0.05))
        }
        let out = Evaluation.merged(run(frames))
        XCTAssertEqual(out.downs, 1)
        XCTAssertEqual(out.ups, 1)
    }

    func testFistWhileTheCursorMovesDoesNotPress() {
        // Moving the whole time (never rests a second), fist halfway.
        let frames = stream(duration: 4, fist: { $0 >= 1.0 && $0 < 2.0 }) { t in
            Point2(0.08 * sin(t * 2.5), 0.04 * cos(t * 2.5))
        }
        XCTAssertEqual(Evaluation.merged(run(frames)).downs, 0)
    }

    func testFistWithTheOtherHandUpDoesNotPress() {
        let frames = stream(duration: 5, fist: { $0 >= 2.5 }, other: { _ in Other(pose: .point) }) {
            self.move($0, start: 0.5, to: Point2(0.08, 0.05))
        }
        let out = Evaluation.merged(run(frames))
        XCTAssertEqual(out.downs + out.clicks.count + out.zooms.count, 0)
    }

    // MARK: Two fists

    /// Both fists from `start`; the right hand moves by `right(t)`, the other hand by `left(t)`.
    private func twoFists(duration: Double = 6, start: Double = 1.5,
                          right: @escaping (Double) -> Point2, left: @escaping (Double) -> Point2) -> [TrackingFrame] {
        stream(duration: duration, noise: 0.0006, fist: { $0 >= start },
               other: { $0 >= start - 0.3 ? Other(pose: $0 >= start ? .fist : .point, offset: left($0)) : nil },
               offset: right)
    }

    private func zoomFactors(_ out: StepOutput) -> [Double] {
        out.zooms.filter { $0.1 == .changed }.map(\.0)
    }

    func testWideningFistsAndRestingZoomsIn() {
        // Each fist moves 0.06 outward at 2.0 s (offsets are as the user sees them: the right
        // hand moves right, the other hand left).
        let frames = twoFists(right: { self.move($0, start: 2.0, to: Point2(0.06, 0)) },
                              left: { self.move($0, start: 2.0, to: Point2(-0.06, 0)) })
        let out = Evaluation.merged(run(frames))
        let factors = zoomFactors(out)
        XCTAssertEqual(factors.count, 1, "one zoom, when the fists rest")
        XCTAssertGreaterThan(factors.first ?? 0, 1.2)
        XCTAssertEqual(out.zooms.first?.1, .began)
        XCTAssertEqual(out.zooms.last?.1, .ended)
        XCTAssertEqual(out.downs + out.clicks.count + out.scrolls(.began).count, 0)
    }

    func testNarrowingFistsZoomsOut() {
        let frames = twoFists(right: { self.move($0, start: 2.0, to: Point2(-0.05, 0)) },
                              left: { self.move($0, start: 2.0, to: Point2(0.05, 0)) })
        let factors = zoomFactors(Evaluation.merged(run(frames)))
        XCTAssertEqual(factors.count, 1)
        XCTAssertLessThan(factors.first ?? 9, 0.8)
    }

    func testCloseThenWidenThenRestZoomsInAgain() {
        // Two ratchet strokes: close up then widen, rest; close up then widen, rest.
        func spread(_ t: Double) -> Double {
            -0.05 * MotionSynthetic.minimumJerk((t - 2.0) / 0.4) + 0.05 * MotionSynthetic.minimumJerk((t - 2.4) / 0.4)
                - 0.05 * MotionSynthetic.minimumJerk((t - 3.6) / 0.4) + 0.05 * MotionSynthetic.minimumJerk((t - 4.0) / 0.4)
        }
        let frames = twoFists(duration: 6, right: { Point2(spread($0), 0) }, left: { Point2(-spread($0), 0) })
        let out = Evaluation.merged(run(frames))
        let factors = zoomFactors(out)
        XCTAssertEqual(factors.count, 2, "\(factors)")
        XCTAssertTrue(factors.allSatisfy { $0 > 1.2 }, "both rests end on a widening stroke: zoom in (\(factors))")
    }

    func testCursorStaysPutDuringTwoFists() {
        let frames = twoFists(right: { self.move($0, start: 2.0, to: Point2(0.06, 0.03)) },
                              left: { self.move($0, start: 2.0, to: Point2(-0.06, 0.03)) })
        let outputs = run(frames)
        guard let before = Evaluation.merged(outputs, to: 1.5).moves.last else { return XCTFail("no moves") }
        XCTAssertTrue(Evaluation.merged(outputs, from: 1.5).moves.allSatisfy { $0.distance(to: before) < 1 })
    }

    private func scrollTotal(_ out: StepOutput) -> Point2 {
        out.intents.reduce(Point2.zero) { sum, intent in
            if case let .scroll(dx, dy, phase) = intent, phase == .changed || phase == .momentumChanged {
                return sum + Point2(dx, dy)
            }
            return sum
        }
    }

    func testBothFistsMovingDownScrollsDown() {
        let frames = twoFists(right: { self.move($0, start: 2.0, to: Point2(0, 0.08)) },
                              left: { self.move($0, start: 2.0, to: Point2(0, 0.08)) })
        let out = Evaluation.merged(run(frames))
        XCTAssertEqual(out.scrolls(.began).count, 1)
        let total = scrollTotal(out)
        XCTAssertGreaterThan(total.y, 100, "content follows the fists down (natural scrolling)")
        XCTAssertEqual(total.x, 0)
        XCTAssertEqual(zoomFactors(out).count + out.downs + out.clicks.count, 0)
    }

    func testBothFistsMovingLeftScrollsSideways() {
        let frames = twoFists(right: { self.move($0, start: 2.0, to: Point2(-0.08, 0)) },
                              left: { self.move($0, start: 2.0, to: Point2(-0.08, 0)) })
        let total = scrollTotal(Evaluation.merged(run(frames)))
        XCTAssertLessThan(total.x, -100)
        XCTAssertEqual(total.y, 0)
    }

    func testRaiseThenLowerAndRestScrollsByTheLastStroke() {
        // Up (a return stroke), then down, then rest: scrolls down, like the zoom ratchet.
        func dy(_ t: Double) -> Double {
            -0.06 * MotionSynthetic.minimumJerk((t - 2.0) / 0.4) + 0.08 * MotionSynthetic.minimumJerk((t - 2.4) / 0.5)
        }
        let frames = twoFists(right: { Point2(0, dy($0)) }, left: { Point2(0, dy($0)) })
        let out = Evaluation.merged(run(frames))
        XCTAssertEqual(out.scrolls(.began).count, 1)
        XCTAssertGreaterThan(scrollTotal(out).y, 100)
    }

    func testFistsHeldStillDoNothing() {
        let frames = twoFists(right: { _ in .zero }, left: { _ in .zero })
        let out = Evaluation.merged(run(frames))
        XCTAssertEqual(out.zooms.count + out.scrolls(.began).count + out.downs + out.clicks.count, 0)
    }

    func testOtherHandAloneNeverPoints() {
        let otherOnly = stream(duration: 3, other: { _ in Other(pose: .point) }) { _ in .zero }.map {
            TrackingFrame(timestamp: $0.timestamp, hands: Array($0.hands.dropFirst()))
        }
        let out = Evaluation.merged(run(otherOnly))
        XCTAssertEqual(out.moves.count + out.clicks.count, 0, "the other hand alone never points")
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
    /// finger wags while moving, the left hand raised twice, and a brief fist after a rest at
    /// ~16 s. They engaged with one palm, which no longer toggles, so the replay engages as the
    /// hotkey would.
    func testOwnerRecordingOnlyTheFistAfterARestPresses() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("recordings/owner-freeform-2026-10-12.json")
        var recorded = try Recording.load(from: url).rebased()
        // Replay with the settings it was recorded with, but today's Hold & wiggle defaults.
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
        // Wags while moving and the raised left hand (no longer a modifier) do nothing.
        XCTAssertEqual(out.clicks.count + out.scrolls(.began).count + out.zooms.count, 0)
        XCTAssertEqual(out.downs, 1)
        XCTAssertEqual(out.ups, 1)
        XCTAssertTrue(log.contains { (15.5...17).contains($0.0) && $0.1.downs > 0 })
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
