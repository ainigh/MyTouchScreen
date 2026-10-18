import XCTest
@testable import GestureCore

/// Fist steering (the default): open hand = vertical only, fist with the thumb up = horizontal
/// only, and the thumb is the button: a flick clicks, a grip moved up/down scrolls (content
/// follows the hand), a grip held still grabs and drags until the thumb lifts.
final class FistSteeringTests: XCTestCase {
    private let steering = GestureConfig()

    /// A right hand at a fixed spot plus `offset(t)` (hand space): a fist while `fist(t)`, its
    /// thumb sticking up while `thumbUp(t)` (otherwise tucked in over the fingers).
    private func stream(fps: Double = 60, duration: Double, noise: Double = 0,
                        fist: @escaping (Double) -> Bool = { _ in false },
                        thumbUp: @escaping (Double) -> Bool = { _ in false },
                        offset: @escaping (Double) -> Point2 = { _ in .zero }) -> [TrackingFrame] {
        var rng = SeededRandom(seed: 9)
        return (0..<Int((duration * fps).rounded())).map { i in
            let t = Double(i) / fps
            var hand = MotionSynthetic.placedHand(tip: Point2(0.45, 0.45), size: 0.12, offset: offset(t))
            if fist(t) { hand.makeFist() }
            var frame = hand.frame(at: t, noise: noise, rng: &rng)
            if fist(t) && thumbUp(t) { frame = raisedThumb(frame) }
            return TrackingFrame(timestamp: t, hands: [frame])
        }
    }

    /// `frame` with its thumb straightened and pointing up from beside the index knuckle (the
    /// synthetic hand can only tuck its thumb in a fist).
    private func raisedThumb(_ frame: HandFrame) -> HandFrame {
        var f = frame
        let size = f.handSize
        func image(_ metric: Point2) -> Point2 { Point2(metric.x, metric.y * f.imageAspect) }
        let base = f.metric(.indexMCP) + Point2(-0.15 * size, 0)
        f.points[Joint.thumbMP.rawValue] = image(base)
        f.points[Joint.thumbIP.rawValue] = image(base + Point2(0, -0.35 * size))
        f.points[Joint.thumbTip.rawValue] = image(base + Point2(0, -0.7 * size))
        return f
    }

    /// From `.zero` to `to` over `duration` starting at `start` (smooth, like a real reach).
    private func move(_ t: Double, start: Double, to: Point2, duration: Double = 0.5) -> Point2 {
        to * MotionSynthetic.minimumJerk((t - start) / duration)
    }

    /// Runs frames through a fresh engaged machine, keeping each frame's output and the cursor.
    private func run(_ frames: [TrackingFrame], _ config: GestureConfig? = nil)
        -> (log: [(time: Double, out: StepOutput, cursor: Point2?, progress: Double)], machine: PointerStateMachine) {
        let machine = engagedMachine(config ?? steering)
        let log = frames.map { frame -> (Double, StepOutput, Point2?, Double) in
            let out = machine.process(frame)
            return (frame.timestamp, out, machine.snapshot.cursor, machine.snapshot.clickProgress)
        }
        return (log.map { (time: $0.0, out: $0.1, cursor: $0.2, progress: $0.3) }, machine)
    }

    private func merged(_ log: [(time: Double, out: StepOutput, cursor: Point2?, progress: Double)],
                        from: Double = -.infinity, to: Double = .infinity) -> StepOutput {
        log.filter { $0.time >= from && $0.time <= to }.reduce(into: StepOutput()) { $0.append($1.out) }
    }

    private func cursor(at time: Double, _ log: [(time: Double, out: StepOutput, cursor: Point2?, progress: Double)]) -> Point2? {
        log.last { $0.time <= time }?.cursor
    }

    func testOnByDefault() {
        XCTAssertTrue(GestureConfig().fistSteering)
        XCTAssertTrue(try GestureConfig.decodeLenient(Data(#"{"boxScale": 1}"#.utf8)).fistSteering,
                      "saved settings from before get it too")
    }

    func testThumbReading() {
        var fist = MotionSynthetic.placedHand(tip: Point2(0.45, 0.45), size: 0.12, offset: .zero)
        fist.makeFist()
        let frame = fist.frame(at: 0)
        XCTAssertEqual(PointerStateMachine.thumbTucked(frame), true, "a fist's tucked thumb")
        XCTAssertEqual(PointerStateMachine.thumbTucked(raisedThumb(frame)), false, "thumb up")
    }

    /// An open hand moving diagonally moves the cursor vertically only.
    func testOpenHandMovesVerticallyOnly() {
        let (log, _) = run(stream(duration: 2.5) { self.move($0, start: 0.5, to: Point2(0.08, 0.06)) })
        let moves = merged(log).moves
        guard let first = moves.first, let last = moves.last else { return XCTFail("no moves") }
        XCTAssertGreaterThan(abs(last.y - first.y), 60, "moved vertically")
        XCTAssertTrue(moves.allSatisfy { $0.x == first.x }, "never sideways")
    }

    /// A thumb-up fist moving diagonally moves the cursor horizontally only; closing the hand
    /// didn't pull the cursor down, and nothing clicks, scrolls or presses.
    func testThumbUpFistMovesHorizontallyOnly() {
        let frames = stream(duration: 3.5, fist: { $0 >= 1.0 }, thumbUp: { _ in true }) { t in
            self.move(t, start: 1.35, to: Point2(0.1, 0.03), duration: 0.6)
        }
        let (log, _) = run(frames)
        guard let before = cursor(at: 0.95, log), let end = cursor(at: 3.4, log) else { return XCTFail("no cursor") }
        XCTAssertEqual(end.y, before.y, accuracy: 0.5, "no vertical motion: not from closing, not from the fist")
        XCTAssertGreaterThan(end.x - before.x, 80, "the fist moved the cursor sideways")
        let out = merged(log)
        XCTAssertEqual([out.downs, out.clicks.count, out.scrolls(.began).count], [0, 0, 0])
    }

    /// Thumb in and straight back out (a flick) clicks once, where the cursor is, at either
    /// camera rate and with tracker noise.
    func testThumbFlickClicks() {
        for fps in [30.0, 60.0] {
            for noise in [0.0, 0.0006] {
                let frames = stream(fps: fps, duration: 3, noise: noise, fist: { $0 >= 1.0 },
                                    thumbUp: { $0 < 1.8 || $0 >= 1.95 })
                let (log, _) = run(frames)
                let out = merged(log)
                XCTAssertEqual(out.clicks.map(\.2), [1], "\(fps) fps, noise \(noise)")
                XCTAssertEqual(out.downs, 0)
                if let click = out.clicks.first, let before = cursor(at: 0.95, log) {
                    XCTAssertEqual(Point2(click.0, click.1).distance(to: before), 0, accuracy: 3)
                }
            }
        }
    }

    /// Two flicks in a row on the same spot make a double click.
    func testTwoFlicksDoubleClick() {
        let frames = stream(duration: 3.5, fist: { $0 >= 1.0 },
                            thumbUp: { !(($0 >= 1.8 && $0 < 1.95) || ($0 >= 2.3 && $0 < 2.45)) })
        XCTAssertEqual(merged(run(frames).log).clicks.map(\.2), [1, 2])
    }

    /// A press longer than a flick but shorter than a grab does nothing.
    func testSlowThumbPressDoesNothing() {
        let frames = stream(duration: 3, fist: { $0 >= 1.0 }, thumbUp: { $0 < 1.8 || $0 >= 2.25 })
        let out = merged(run(frames).log)
        XCTAssertEqual([out.clicks.count, out.downs], [0, 0])
    }

    /// One misread frame of a tucked thumb while the fist moves sideways is not a click.
    func testMisreadThumbFrameDoesNotClick() {
        let frames = stream(duration: 3.5, fist: { $0 >= 1.0 }, thumbUp: { abs($0 - 2.0) > 0.01 }) { t in
            self.move(t, start: 1.5, to: Point2(0.1, 0), duration: 1.0)
        }
        let out = merged(run(frames).log)
        XCTAssertEqual([out.clicks.count, out.downs, out.scrolls(.began).count], [0, 0, 0])
    }

    /// Grip (thumb in) and pull down: the content follows the hand (natural scrolling), the
    /// cursor stays put, nothing clicks, and lifting the thumb lets go.
    func testGripPullScrolls() {
        let frames = stream(duration: 3.5, fist: { $0 >= 1.0 }, thumbUp: { $0 < 1.5 || $0 >= 2.6 }) { t in
            self.move(t, start: 1.6, to: Point2(0, 0.06), duration: 0.5)
        }
        let (log, machine) = run(frames)
        let out = merged(log)
        XCTAssertEqual(out.scrolls(.began).count, 1)
        XCTAssertEqual(out.scrolls(.ended).count, 1)
        let content = out.scrolls(.changed).reduce(0) { $0 + $1.1 }
        XCTAssertGreaterThan(content, 40, "pulled down: content down")
        XCTAssertEqual([out.clicks.count, out.downs], [0, 0])
        guard let before = cursor(at: 0.95, log) else { return XCTFail("no cursor") }
        let during = log.filter { $0.time > 1.0 && $0.time < 3.4 }.compactMap(\.cursor)
        XCTAssertTrue(during.allSatisfy { $0.distance(to: before) < 1 }, "the cursor doesn't move")
        XCTAssertFalse(machine.snapshot.isScrolling)

        var reversed = steering
        reversed.naturalScrolling = false
        let opposite = merged(run(frames, reversed).log).scrolls(.changed).reduce(0) { $0 + $1.1 }
        XCTAssertLessThan(opposite, -40)
    }

    /// Hand over hand, like climbing a rope: grip and pull down, lift the thumb and reach back
    /// up, grip and pull down again. Two scrolls the same way; reaching back scrolls nothing
    /// and doesn't move the cursor.
    func testRopeClimbing() {
        // Pull down 1.6–2.1, reach up 2.4–2.9 (thumb up), pull down 3.2–3.7.
        func height(_ t: Double) -> Double {
            0.06 * (MotionSynthetic.minimumJerk((t - 1.6) / 0.5) - MotionSynthetic.minimumJerk((t - 2.4) / 0.5)
                    + MotionSynthetic.minimumJerk((t - 3.2) / 0.5))
        }
        let gripping: (Double) -> Bool = { ($0 >= 1.5 && $0 < 2.25) || ($0 >= 3.05 && $0 < 3.85) }
        let frames = stream(duration: 4.5, fist: { $0 >= 1.0 }, thumbUp: { !gripping($0) }) { Point2(0, height($0)) }
        let (log, _) = run(frames)
        let out = merged(log)
        XCTAssertEqual(out.scrolls(.began).count, 2)
        XCTAssertEqual(out.scrolls(.ended).count, 2)
        let reach = merged(log, from: 2.35, to: 3.0)
        XCTAssertTrue(reach.scrolls(.changed).isEmpty, "reaching back up doesn't scroll")
        let first = merged(log, to: 2.3).scrolls(.changed).reduce(0) { $0 + $1.1 }
        let second = merged(log, from: 3.0).scrolls(.changed).reduce(0) { $0 + $1.1 }
        XCTAssertGreaterThan(first, 40)
        XCTAssertGreaterThan(second, 40)
        guard let before = cursor(at: 0.95, log) else { return XCTFail("no cursor") }
        XCTAssertTrue(log.filter { $0.time > 1.0 }.compactMap(\.cursor).allSatisfy { abs($0.y - before.y) < 1 },
                      "the cursor never moves vertically")
        XCTAssertEqual([out.clicks.count, out.downs], [0, 0])
    }

    /// Grip and hold still: grab (the ring fills first). The fist then drags in any direction,
    /// and lifting the thumb drops.
    func testGripHoldGrabsAndDrags() {
        let frames = stream(duration: 4, fist: { $0 >= 1.0 }, thumbUp: { $0 < 1.5 || $0 >= 3.2 }) { t in
            self.move(t, start: 2.3, to: Point2(0.08, 0.05), duration: 0.6)
        }
        let (log, machine) = run(frames)
        let out = merged(log)
        XCTAssertEqual([out.downs, out.ups, out.clicks.count], [1, 1, 0])
        let downTime = log.first { $0.out.downs > 0 }?.time ?? 0
        XCTAssertEqual(downTime, 1.5 + 0.06 + 0.5, accuracy: 0.1, "grabs after the hold")
        XCTAssertTrue(log.contains { $0.time < downTime && $0.progress > 0.5 }, "the ring fills toward it")
        guard case let .down(dx, dy)? = out.intents.first(where: { if case .down = $0 { return true } else { return false } }),
              case let .up(ux, uy)? = out.intents.first(where: { if case .up = $0 { return true } else { return false } })
        else { return XCTFail("no press or release") }
        XCTAssertGreaterThan(ux - dx, 40, "dragged sideways")
        XCTAssertGreaterThan(uy - dy, 20, "and down: a grab drags in any direction")
        let upTime = log.first { $0.out.ups > 0 }?.time ?? 0
        XCTAssertEqual(upTime, 3.2 + 0.06, accuracy: 0.1, "drops when the thumb lifts")
        XCTAssertEqual(machine.state, .hover)
        XCTAssertTrue(machine.snapshot.isSteeringFist, "back to steering sideways")
    }

    /// A full fist made straight from the open hand (thumb already in) grips but can't click:
    /// lifting the thumb soon after just steers. Opening the hand mid-grab drops.
    func testFullFistFromOpenHand() {
        let lifted = stream(duration: 3, fist: { $0 >= 1.0 }, thumbUp: { $0 >= 1.4 })
        let out = merged(run(lifted).log)
        XCTAssertEqual([out.clicks.count, out.downs], [0, 0])

        let held = stream(duration: 3.5, fist: { $0 >= 1.0 && $0 < 2.6 })
        let grab = merged(run(held).log)
        XCTAssertEqual([grab.downs, grab.ups, grab.clicks.count], [1, 1, 0])
    }

    /// The fist presets come back when fist steering is off: a fist drags.
    func testFistDragsWhenSteeringIsOff() {
        let frames = stream(duration: 3.5, fist: { $0 >= 1.0 && $0 < 3.0 }) { t in
            self.move(t, start: 1.6, to: Point2(0.1, 0.04), duration: 0.6)
        }
        let classic = merged(run(frames, .classic).log)
        XCTAssertEqual([classic.downs, classic.ups], [1, 1])
    }

    /// The owner's free-form recording (natural fists, thumb tucked) with fist steering: every
    /// press is released and every scroll ends, and they happen only while a fist is held.
    func testOwnerRecordingSteering() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("recordings/owner-freeform-2026-10-12.json")
        let recorded = try Recording.load(from: url).rebased()
        let machine = PointerStateMachine(config: steering, displays: [testDisplay])
        _ = machine.setEngaged(true, at: 0)
        var log: [(Double, StepOutput)] = []
        for frame in recorded.frames { log.append((frame.timestamp, machine.process(frame))) }
        let out = log.reduce(into: StepOutput()) { $0.append($1.1) }
        XCTAssertEqual(out.downs, out.ups, "every grab is dropped")
        XCTAssertEqual(out.scrolls(.began).count, out.scrolls(.ended).count, "every scroll ends")
        let fists: [ClosedRange<Double>] = [12.4...14.0, 15.6...16.8, 56.1...57.8, 59.2...62.5]
        for (time, step) in log where step.downs > 0 || !step.scrolls(.began).isEmpty {
            XCTAssertTrue(fists.contains { $0.contains(time) }, "grab or scroll at \(time) s outside a held fist")
        }
    }
}
