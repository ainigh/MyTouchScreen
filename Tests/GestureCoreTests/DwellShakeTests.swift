import XCTest
@testable import GestureCore

/// Hold & wiggle, the default input model: hold still 2 s = click, three direction changes
/// along one axis within 1 s = scroll, everything else moves the cursor.
final class DwellShakeTests: XCTestCase {
    private let config = GestureConfig()

    /// A pointing hand at a fixed spot plus `offset(t)` (hand space), optionally noisy.
    private func stream(fps: Double = 60, duration: Double, noise: Double = 0,
                        offset: @escaping (Double) -> Point2) -> [TrackingFrame] {
        var rng = SeededRandom(seed: 5)
        return (0..<Int((duration * fps).rounded())).map { i in
            let t = Double(i) / fps
            let hand = VelocitySynthetic.placedHand(tip: Point2(0.5, 0.45), size: 0.12, offset: offset(t))
            return TrackingFrame(timestamp: t, hands: [hand.frame(at: t, noise: noise, rng: &rng)])
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
        XCTAssertEqual(GestureConfig().shake.dwellTime, 2.0)
        XCTAssertEqual(GestureConfig().shake.reversals, 3)
        XCTAssertEqual(GestureConfig().shake.window, 1.0)
    }

    // MARK: Click

    func testHoldingStillTwoSecondsClicksOnceWhereTheCursorRests() {
        for fps in [30.0, 60.0] {
            // Move to a target at 0.5 s, arrive by 1.0 s, then hold still (with tracker noise).
            let frames = stream(fps: fps, duration: 4.5, noise: 0.0008) { self.move($0, start: 0.5, to: Point2(0.08, 0.05)) }
            let outputs = run(frames)
            XCTAssertEqual(Evaluation.merged(outputs, to: 2.8).clicks.count, 0, "no click before 2 s of stillness at \(fps) fps")
            let clicks = Evaluation.merged(outputs).clicks
            XCTAssertEqual(clicks.count, 1, "exactly one click while the hand stays at \(fps) fps")
            guard let click = clicks.first, let lastMove = Evaluation.merged(outputs).moves.last else { continue }
            XCTAssertEqual(click.0, lastMove.x, accuracy: 15)
            XCTAssertEqual(click.1, lastMove.y, accuracy: 15)
            XCTAssertEqual(click.2, 1)
        }
    }

    func testEngagingWithAStillHandDoesNotClick() {
        let frames = stream(duration: 4) { _ in .zero }
        XCTAssertEqual(Evaluation.merged(run(frames)).clicks.count, 0)
    }

    func testMovingAgainAfterAClickAllowsTheNextOne() {
        let frames = stream(duration: 8) { t in
            self.move(t, start: 0.5, to: Point2(0.08, 0)) + self.move(t, start: 3.6, to: Point2(-0.16, 0.04))
        }
        XCTAssertEqual(Evaluation.merged(run(frames)).clicks.count, 2)
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
            // Wiggle up/down (4 strokes = 3 direction changes in ~0.7 s), then move the hand down.
            let frames = stream(fps: fps, duration: 4) { t in
                self.wiggle(t, start: 1.0, axis: Point2(0, 1)) + self.move(t, start: 2.0, to: Point2(0, 0.12))
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
            let before = Evaluation.merged(outputs, to: 1.0).moves.last
            let during = Evaluation.merged(outputs, from: 1.9, to: 3.0).moves
            XCTAssertEqual(during.count, 0, "cursor holds still while scrolling")
            if let before, let warp = Evaluation.merged(outputs, from: 1.0, to: 1.9).moves.last {
                XCTAssertEqual(warp.x, before.x, accuracy: 3)
                XCTAssertEqual(warp.y, before.y, accuracy: 3)
            }
        }
    }

    func testHorizontalWiggleScrollsSideways() {
        let frames = stream(duration: 4) { t in
            self.wiggle(t, start: 1.0, axis: Point2(1, 0)) + self.move(t, start: 2.0, to: Point2(0.12, 0))
        }
        let out = Evaluation.merged(run(frames))
        XCTAssertEqual(out.scrolls(.began).count, 1)
        let changed = out.scrolls(.changed)
        XCTAssertGreaterThan(abs(changed.map(\.0).reduce(0, +)), 100)
        XCTAssertEqual(changed.map { abs($0.1) }.reduce(0, +), 0)
    }

    func testTwoDirectionChangesAreJustMovement() {
        let frames = stream(duration: 3) { self.wiggle($0, start: 1.0, axis: Point2(0, 1), count: 3) }
        XCTAssertEqual(Evaluation.merged(run(frames)).scrolls(.began).count, 0)
    }

    func testSlowBackAndForthIsJustMovement() {
        // Four strokes, but spread over 2.4 s: never three changes within one second.
        let frames = stream(duration: 5) { self.wiggle($0, start: 1.0, axis: Point2(0, 1), stroke: 0.6) }
        XCTAssertEqual(Evaluation.merged(run(frames)).scrolls(.began).count, 0)
    }

    func testTinyTremorIsNotAWiggle() {
        let frames = stream(duration: 3) { self.wiggle($0, start: 0.5, axis: Point2(0, 1), amplitude: 0.01, stroke: 0.1, count: 12) }
        XCTAssertEqual(Evaluation.merged(run(frames)).scrolls(.began).count, 0)
    }

    func testDetectorCountsChangesPerAxis() {
        var detector = ShakeDetector(params: ShakeParams())
        var detections: [ShakeDetector.Detection] = []
        for i in 0..<120 {
            let t = Double(i) / 60
            let y = wiggle(t, start: 0.2, axis: Point2(0, 1)).y
            if let d = detector.update(centroid: Point2(0.5, 0.3 + y), handSize: 0.12, at: t) { detections.append(d) }
        }
        XCTAssertEqual(detections.count, 1)
        XCTAssertEqual(detections.first?.vertical, true)
        XCTAssertEqual(detections.first?.startTime ?? -1, 0.2, accuracy: 0.05)
    }

    // MARK: Engagement and modes

    func testPalmStillTogglesEngagement() {
        let machine = PointerStateMachine(config: config, displays: [testDisplay])
        var out = StepOutput()
        for frame in SyntheticStream.palmHold(hold: 1.0) { out.append(machine.process(frame)) }
        XCTAssertTrue(out.events.contains(.engaged))
        XCTAssertTrue(machine.isEngaged)
    }

    func testSwitchingModelMidScrollEndsTheScroll() {
        let frames = stream(duration: 2.2) { t in
            self.wiggle(t, start: 1.0, axis: Point2(0, 1)) + self.move(t, start: 1.8, to: Point2(0, 0.12), duration: 1)
        }
        let machine = PointerStateMachine(config: config, displays: [testDisplay])
        _ = machine.setEngaged(true, at: 0)
        for frame in frames { _ = machine.process(frame) }
        XCTAssertEqual(machine.state, .scrolling)
        let switched = machine.updateConfig(.velocityMode)
        XCTAssertEqual(switched.scrolls(.ended).count, 1)
    }
}
