import XCTest
@testable import GestureCore

/// Fist steering (the default): open hand = vertical only, fist = horizontal only; a fist moved
/// up and down scrolls, a fist held still clicks, and changing shape never drags the cursor.
final class FistSteeringTests: XCTestCase {
    private let steering = GestureConfig()

    /// A right hand at a fixed spot plus `offset(t)` (hand space), a fist while `fist(t)`.
    private func stream(fps: Double = 60, duration: Double, noise: Double = 0,
                        fist: @escaping (Double) -> Bool = { _ in false },
                        offset: @escaping (Double) -> Point2 = { _ in .zero }) -> [TrackingFrame] {
        var rng = SeededRandom(seed: 9)
        return (0..<Int((duration * fps).rounded())).map { i in
            let t = Double(i) / fps
            var hand = MotionSynthetic.placedHand(tip: Point2(0.45, 0.45), size: 0.12, offset: offset(t))
            if fist(t) { hand.makeFist() }
            return TrackingFrame(timestamp: t, hands: [hand.frame(at: t, noise: noise, rng: &rng)])
        }
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

    /// An open hand moving diagonally moves the cursor vertically only.
    func testOpenHandMovesVerticallyOnly() {
        let (log, _) = run(stream(duration: 2.5) { self.move($0, start: 0.5, to: Point2(0.08, 0.06)) })
        let moves = merged(log).moves
        guard let first = moves.first, let last = moves.last else { return XCTFail("no moves") }
        XCTAssertGreaterThan(abs(last.y - first.y), 60, "moved vertically")
        XCTAssertTrue(moves.allSatisfy { $0.x == first.x }, "never sideways")
    }

    /// A fist moving diagonally moves the cursor horizontally only, and closing the hand didn't
    /// pull the cursor down.
    func testFistMovesHorizontallyOnlyAndClosingDoesNotDragTheCursor() {
        // Moves off 0.35 s after closing (before a still fist would click).
        let frames = stream(duration: 3.5, fist: { $0 >= 1.0 }) { t in
            self.move(t, start: 1.35, to: Point2(0.1, 0.012), duration: 0.6)
        }
        let (log, _) = run(frames)
        guard let before = cursor(at: 0.95, log), let end = cursor(at: 3.4, log) else { return XCTFail("no cursor") }
        XCTAssertEqual(end.y, before.y, accuracy: 0.5, "no vertical motion: not from closing, not from the fist")
        XCTAssertGreaterThan(end.x - before.x, 80, "the fist moved the cursor sideways")
        let out = merged(log)
        XCTAssertEqual(out.downs, 0, "the fist doesn't drag")
        XCTAssertEqual(out.scrolls(.began).count, 0, "a sideways fist doesn't scroll")
    }

    /// A fist held still clicks once, where the cursor was before the hand closed, with the ring
    /// filling first.
    func testStillFistClicksOnce() {
        for fps in [30.0, 60.0] {
            let (log, _) = run(stream(fps: fps, duration: 3, noise: 0.0006, fist: { $0 >= 1.0 }))
            let out = merged(log)
            XCTAssertEqual(out.clicks.count, 1, "\(fps) fps")
            XCTAssertEqual(out.downs, 0)
            guard let click = out.clicks.first, let before = cursor(at: 0.95, log),
                  let clickTime = log.first(where: { !$0.out.clicks.isEmpty })?.time else { return XCTFail("no click") }
            XCTAssertEqual(Point2(click.0, click.1).distance(to: before), 0, accuracy: 3)
            XCTAssertEqual(clickTime, 1.0 + 0.6, accuracy: 0.25, "after the hold time")
            XCTAssertTrue(log.contains { $0.time < clickTime && $0.progress > 0.5 }, "the ring fills toward it")
        }
    }

    /// Move the fist sideways onto something, then hold still: that clicks there.
    func testFistMovedThenHeldClicksAtTheNewSpot() {
        let frames = stream(duration: 4, fist: { $0 >= 1.0 }) { t in
            self.move(t, start: 1.3, to: Point2(0.08, 0), duration: 0.5)
        }
        let (log, _) = run(frames)
        let out = merged(log, from: 1.75)
        XCTAssertEqual(out.clicks.count, 1)
        if let click = out.clicks.first, let start = cursor(at: 0.95, log) {
            XCTAssertGreaterThan(click.0 - start.x, 60, "clicked where the fist went")
        }
    }

    /// A fist moved up and down scrolls (natural direction: down moves the content down), the
    /// cursor stays put, and stopping afterwards doesn't click.
    func testFistUpAndDownScrollsWithoutMovingTheCursor() {
        let frames = stream(duration: 4, fist: { $0 >= 1.0 && $0 < 3.5 }) { t in
            self.move(t, start: 1.3, to: Point2(0, 0.06), duration: 0.5)
        }
        let (log, machine) = run(frames)
        let out = merged(log)
        XCTAssertEqual(out.scrolls(.began).count, 1)
        XCTAssertEqual(out.scrolls(.ended).count, 1)
        let content = out.scrolls(.changed).reduce(0) { $0 + $1.1 }
        XCTAssertGreaterThan(content, 40, "hand down, content down (natural scrolling)")
        XCTAssertEqual(out.clicks.count, 0, "stopping after a scroll isn't a click")
        XCTAssertEqual(out.downs, 0)
        guard let before = cursor(at: 0.95, log) else { return XCTFail("no cursor") }
        let during = log.filter { $0.time > 1.0 && $0.time < 3.5 }.compactMap(\.cursor)
        XCTAssertTrue(during.allSatisfy { $0.distance(to: before) < 1 }, "the cursor doesn't move while scrolling")
        XCTAssertFalse(machine.snapshot.isScrolling)

        var reversed = steering
        reversed.naturalScrolling = false
        let opposite = merged(run(frames, reversed).log).scrolls(.changed).reduce(0) { $0 + $1.1 }
        XCTAssertLessThan(opposite, -40)
    }

    /// The fist presets give way to fist steering, and come back when it's off.
    func testFistDragsOnlyWhenSteeringIsOff() {
        let frames = stream(duration: 3.5, fist: { $0 >= 1.0 && $0 < 3.0 }) { t in
            self.move(t, start: 1.6, to: Point2(0.1, 0.04), duration: 0.6)
        }
        XCTAssertEqual(merged(run(frames).log).downs, 0)
        let classic = merged(run(frames, .classic).log)
        XCTAssertEqual([classic.downs, classic.ups], [1, 1])
    }

    /// The owner's free-form recording with fist steering: no presses, every scroll ends, and
    /// scrolls and still-fist clicks happen only while a fist is held.
    func testOwnerRecordingSteering() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("recordings/owner-freeform-2026-10-12.json")
        let recorded = try Recording.load(from: url).rebased()
        let machine = PointerStateMachine(config: steering, displays: [testDisplay])
        _ = machine.setEngaged(true, at: 0)
        var log: [(Double, StepOutput, Double)] = []
        for frame in recorded.frames {
            let out = machine.process(frame)
            log.append((frame.timestamp, out, machine.snapshot.clickProgress))
        }
        let out = log.reduce(into: StepOutput()) { $0.append($1.1) }
        XCTAssertEqual(out.downs, 0)
        XCTAssertEqual(out.scrolls(.began).count, out.scrolls(.ended).count, "every scroll ends")
        let fists: [ClosedRange<Double>] = [12.4...14.0, 15.6...16.8, 56.1...57.8, 59.2...62.5]
        for (time, step, _) in log where !step.scrolls(.began).isEmpty {
            XCTAssertTrue(fists.contains { $0.contains(time) }, "scroll at \(time) s outside a held fist")
        }
    }
}
