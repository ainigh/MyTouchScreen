import XCTest
@testable import GestureCore

/// Behaviour of Velocity mode beyond raw accuracy: where clicks land, scroll momentum,
/// composite gestures, noise rejection, frame-rate independence, settings.
final class VelocityGestureTests: XCTestCase {
    private let config = GestureConfig()

    /// A pointing hand at a fixed spot plus a sum of strokes (hand space), sampled cleanly.
    private func stream(fps: Double, duration: Double, size: Double = 0.12, confidence: ((Int) -> Double)? = nil,
                        offset: @escaping (Double) -> Point2) -> [TrackingFrame] {
        let count = Int((duration * fps).rounded())
        return (0..<count).map { i in
            let t = Double(i) / fps
            var hand = VelocitySynthetic.placedHand(tip: Point2(0.5, 0.45), size: size, offset: offset(t))
            if let confidence { hand.confidence = confidence(i) }
            return TrackingFrame(timestamp: t, hands: [hand.frame(at: t)])
        }
    }

    private func tap(_ t: Double, at start: Double, direction: Point2 = Point2(0, 1), amplitude: Double = 0.65 * 0.12,
                     out: Double = 0.07, back: Double = 0.085) -> Point2 {
        VelocitySynthetic.stroke(t - start, direction: direction, amplitude: amplitude, outTime: out, backTime: back)
    }

    private func flick(_ t: Double, at start: Double, direction: Point2 = Point2(0, 1)) -> Point2 {
        VelocitySynthetic.stroke(t - start, direction: direction, amplitude: 2.4 * 0.12, outTime: 0.12, backTime: 0.2)
    }

    private func run(_ frames: [TrackingFrame], _ config: GestureConfig? = nil) -> [Evaluation.TimedOutput] {
        Evaluation.run(frames, config: config ?? self.config)
    }

    // MARK: Click position

    func testClickLandsAtTheAnchorAndWarpsTheCursorThere() {
        for fps in [30.0, 60.0] {
            let frames = stream(fps: fps, duration: 2) { self.tap($0, at: 0.8) }
            let outputs = run(frames)
            let before = Evaluation.merged(outputs, to: 0.8)
            let all = Evaluation.merged(outputs)
            guard let anchor = before.moves.last, let click = all.clicks.first else {
                return XCTFail("no click at \(fps) fps")
            }
            XCTAssertEqual(all.clicks.count, 1)
            XCTAssertEqual(click.0, anchor.x, accuracy: 1.0, "click x at \(fps) fps")
            XCTAssertEqual(click.1, anchor.y, accuracy: 1.0, "click y at \(fps) fps")
            // The intent right before the click is the warp back to the anchor.
            guard let index = all.intents.firstIndex(where: { if case .click = $0 { return true } else { return false } }),
                  index > 0, case let .move(x, y) = all.intents[index - 1] else {
                return XCTFail("click not preceded by a warp at \(fps) fps")
            }
            XCTAssertEqual(x, click.0, accuracy: 1e-9)
            XCTAssertEqual(y, click.1, accuracy: 1e-9)
        }
    }

    func testCursorFollowsTheHandLiveDuringAFlick() {
        let frames = stream(fps: 60, duration: 2) { self.tap($0, at: 0.8) }
        let during = Evaluation.merged(run(frames), from: 0.81, to: 0.9)
        XCTAssertGreaterThan(during.moves.count, 2, "the cursor must not freeze during a fast segment")
    }

    func testRightClickForSidewaysTap() {
        let frames = stream(fps: 60, duration: 2) { self.tap($0, at: 0.8, direction: Point2(1, 0)) }
        let out = Evaluation.merged(run(frames))
        XCTAssertEqual(out.rightClicks, 1)
        XCTAssertEqual(out.clicks.count, 0)

        var noRight = config
        noRight.velocity.rightClickEnabled = false
        XCTAssertEqual(Evaluation.merged(run(frames, noRight)).rightClicks, 0)

        var horizontal = config
        horizontal.velocity.clickAxis = .horizontal
        let swapped = Evaluation.merged(run(frames, horizontal))
        XCTAssertEqual(swapped.clicks.count, 1)
        XCTAssertEqual(swapped.rightClicks, 0)
    }

    func testTapNeedsStillnessBefore() {
        // The hand drifts slowly (above preClickStillV) right up to the tap.
        let frames = stream(fps: 60, duration: 2) { t in
            Point2(min(t, 0.8) * 0.3, 0) + self.tap(t, at: 0.8)
        }
        XCTAssertEqual(Evaluation.merged(run(frames)).clicks.count, 0)
    }

    // MARK: Double click and drag

    func testDoubleTapIsOneDoubleClickAtTheSamePoint() {
        let frames = stream(fps: 60, duration: 2.5) { self.tap($0, at: 0.8) + self.tap($0, at: 0.8 + 0.155 + 0.22) }
        let clicks = Evaluation.merged(run(frames)).clicks
        XCTAssertEqual(clicks.map(\.2), [1, 2])
        XCTAssertEqual(clicks[0].0, clicks[1].0, accuracy: 1e-9)
        XCTAssertEqual(clicks[0].1, clicks[1].1, accuracy: 1e-9)
    }

    func testTapThenMoveDragsAndReleasesWhenStill() {
        let frames = stream(fps: 60, duration: 3) { t in
            self.tap(t, at: 0.8) + VelocitySynthetic.stroke(t - 1.1, direction: Point2(1, 0), amplitude: 0.25,
                                                            outTime: 0.5, backTime: 0)
        }
        let out = Evaluation.merged(run(frames))
        XCTAssertEqual(out.clicks.count, 1)
        XCTAssertEqual(out.downs, 1)
        XCTAssertEqual(out.ups, 1)
        guard let downIndex = out.intents.firstIndex(where: { if case .down = $0 { return true } else { return false } }),
              case let .down(x, y) = out.intents[downIndex], let click = out.clicks.first else {
            return XCTFail("no mouse down")
        }
        XCTAssertEqual(x, click.0, accuracy: 1e-9, "drag starts at the click")
        XCTAssertEqual(y, click.1, accuracy: 1e-9)
        XCTAssertTrue(out.events.contains(.dragStarted))
        XCTAssertTrue(out.events.contains(.dragEnded))

        var noDrag = config
        noDrag.velocity.dragEnabled = false
        XCTAssertEqual(Evaluation.merged(run(frames, noDrag)).downs, 0)
    }

    func testTapWhileDraggingDropsInsteadOfClicking() {
        let frames = stream(fps: 60, duration: 3) { t in
            self.tap(t, at: 0.8)
                + VelocitySynthetic.stroke(t - 1.1, direction: Point2(1, 0), amplitude: 0.2, outTime: 0.5, backTime: 0)
                + self.tap(t, at: 1.75)
        }
        let out = Evaluation.merged(run(frames))
        XCTAssertEqual(out.clicks.count, 1, "the second tap is the drop, not a click")
        XCTAssertEqual(out.downs, 1)
        XCTAssertEqual(out.ups, 1)
    }

    // MARK: Scroll

    func testScrollFlickWarpsAndGlidesWithPhases() {
        let frames = stream(fps: 60, duration: 2) { self.flick($0, at: 0.8) }
        let outputs = run(frames)
        let out = Evaluation.merged(outputs)
        XCTAssertEqual(out.clicks.count, 0)
        XCTAssertEqual(out.scrolls(.began).count, 1)
        XCTAssertEqual(out.scrolls(.ended).count, 1)
        XCTAssertEqual(out.scrolls(.momentumBegan).count, 1)
        XCTAssertEqual(out.scrolls(.momentumEnded).count, 1)
        // Natural scrolling: a downward flick moves the content down.
        XCTAssertGreaterThan(out.scrolls(.changed).first?.1 ?? 0, 0)
        let phases = out.intents.compactMap { intent -> ScrollPhase? in
            if case let .scroll(_, _, phase) = intent { return phase } else { return nil }
        }
        XCTAssertEqual(phases.first, .began)
        XCTAssertEqual(phases.last, .momentumEnded)

        var reversed = config
        reversed.naturalScrolling = false
        XCTAssertLessThan(Evaluation.merged(run(frames, reversed)).scrolls(.changed).first?.1 ?? 0, 0)
    }

    func testMomentumDecaysMonotonically() {
        let frames = stream(fps: 60, duration: 2) { self.flick($0, at: 0.8, direction: Point2(0, -1)) }
        let glide = Evaluation.merged(run(frames)).scrolls(.momentumChanged).map { abs($0.1) }
        XCTAssertGreaterThan(glide.count, 10)
        for (a, b) in zip(glide, glide.dropFirst()) {
            XCTAssertLessThanOrEqual(b, a + 1e-9, "momentum must never speed up")
        }
        // Up flick → content moves up (natural).
        XCTAssertLessThan(Evaluation.merged(run(frames)).scrolls(.changed).first?.1 ?? 0, 0)
    }

    func testMomentumStopsWhenANewSegmentStarts() {
        // Second flick starts while the first one's glide is still running.
        let frames = stream(fps: 60, duration: 3) { self.flick($0, at: 0.8) + self.flick($0, at: 1.5) }
        let outputs = run(frames)
        guard let secondBegan = outputs.filter({ $0.output.scrolls(.began).count > 0 }).dropFirst().first else {
            return XCTFail("second flick didn't scroll")
        }
        let between = Evaluation.merged(outputs, from: 1.5, to: secondBegan.time)
        XCTAssertEqual(between.scrolls(.momentumEnded).count, 1, "the glide stops when the next flick starts")
        guard let stop = outputs.first(where: { $0.time >= 1.5 && $0.output.scrolls(.momentumEnded).count > 0 }) else {
            return XCTFail("no momentum end")
        }
        XCTAssertLessThan(stop.time, 1.5 + 0.08, "stopped at the start of the segment, not its end")
    }

    func testMomentumDecayIsFrameRateCorrected() {
        var params = VelocityParams()
        params.momentumDecay = 0.92
        let rate = params.momentumFriction
        // 0.92 per 1/60 s, whatever the tick rate.
        XCTAssertEqual(exp(-rate / 60), 0.92, accuracy: 1e-9)
        var a = ScrollMomentum(friction: rate, minSpeed: 1)
        var b = ScrollMomentum(friction: rate, minSpeed: 1)
        _ = a.start(velocity: Point2(0, 1000), at: 0)
        _ = b.start(velocity: Point2(0, 1000), at: 0)
        var distA = 0.0, distB = 0.0
        for i in 1...60 { for case let .scroll(_, dy, _) in a.tick(at: Double(i) / 60) { distA += dy } }
        for i in 1...120 { for case let .scroll(_, dy, _) in b.tick(at: Double(i) / 120) { distB += dy } }
        XCTAssertEqual(distA, distB, accuracy: 1e-6)
    }

    // MARK: Two hands

    func testTwoHandSpreadZoomsWithoutClickOrScroll() {
        let sample = VelocitySynthetic.sample(.zoom, fps: 60, seed: 3, clean: true)
        let out = Evaluation.merged(run(sample.frames))
        XCTAssertGreaterThan(out.zooms.count, 1)
        XCTAssertEqual(out.zooms.first?.1, .began)
        XCTAssertEqual(out.zooms.last?.1, .ended)
        XCTAssertEqual(out.clicks.count + out.rightClicks + out.scrolls(.began).count, 0)
    }

    // MARK: Noise rejection

    func testSingleFrameGlitchResetsTheSegment() {
        var tracker = MotionTracker(params: VelocityParams())
        var events: [MotionEvent] = []
        for i in 0..<60 {
            let t = Double(i) / 60
            var c = Point2(0.5, 0.3)
            if i == 30 { c.x += 0.5 }   // > 2.5 hand sizes in one frame
            events += tracker.update(MotionSample(time: t, centroid: c, handSize: 0.12, confidence: 0.9))
        }
        XCTAssertTrue(events.contains(.glitch(time: 30.0 / 60)))
        XCTAssertFalse(events.contains { if case .segmentStarted = $0 { return true } else { return false } })
    }

    func testLowConfidenceAtAnchorIgnoresTheSegment() {
        // The frame just before the tap starts is low confidence.
        let frames = stream(fps: 60, duration: 2, confidence: { $0 == 48 ? 0.2 : 0.95 }) { self.tap($0, at: 0.8) }
        let outputs = run(frames)
        let out = Evaluation.merged(outputs)
        XCTAssertEqual(out.clicks.count, 0)
        let rules = out.events.compactMap { event -> String? in
            if case let .segmentClassified(r) = event { return r.rule } else { return nil }
        }
        XCTAssertTrue(rules.contains { $0.contains("low confidence") }, "\(rules)")
    }

    func testRefractoryBlocksAnImmediateSecondSegment() {
        var params = VelocityParams()
        params.refractory = 0.5
        var engine = VelocityEngine(params: params)
        var clicks = 0
        for i in 0..<150 {
            let t = Double(i) / 60
            let offset = tap(t, at: 0.5) + tap(t, at: 0.5 + 0.3)
            let c = Point2(0.5, 0.3) + offset
            for action in engine.update(primary: MotionSample(time: t, centroid: c, handSize: 0.12, confidence: 0.9),
                                        secondary: nil) {
                if case .click = action { clicks += 1 }
            }
        }
        XCTAssertEqual(clicks, 1)
    }

    func testIncoherentFramesDontStartASegmentAt60fps() {
        var tracker = MotionTracker(params: VelocityParams())
        var events: [MotionEvent] = []
        // Fast but zig-zagging every frame: 0.025 per frame at 60 fps = 1.5/s, direction flips.
        for i in 0..<60 {
            let t = Double(i) / 60
            let c = Point2(0.5 + (i % 2 == 0 ? 0 : 0.025), 0.3)
            events += tracker.update(MotionSample(time: t, centroid: c, handSize: 0.12, confidence: 0.9))
        }
        XCTAssertFalse(events.contains { if case .segmentStarted = $0 { return true } else { return false } })
    }

    // MARK: Frame-rate independence

    func testSameMotionAt30And60FpsGivesTheSameIntents() {
        for label in [GestureLabel.click, .rightClick, .doubleClick, .scrollUp, .scrollDown, .drag,
                      .repositionFast, .repositionSlow, .zoom] {
            for seed in UInt64(1)...10 {
                let a = VelocitySynthetic.sample(label, fps: 30, seed: seed, clean: true)
                let b = VelocitySynthetic.sample(label, fps: 60, seed: seed, clean: true)
                let outA = Evaluation.merged(run(a.frames))
                let outB = Evaluation.merged(run(b.frames))
                XCTAssertEqual(summary(outA), summary(outB), "\(label.rawValue) seed \(seed)")
                for (ca, cb) in zip(outA.clicks, outB.clicks) {
                    XCTAssertEqual(ca.0, cb.0, accuracy: 6, "\(label.rawValue) seed \(seed) click x")
                    XCTAssertEqual(ca.1, cb.1, accuracy: 6, "\(label.rawValue) seed \(seed) click y")
                }
                if let va = outA.scrolls(.changed).first, let vb = outB.scrolls(.changed).first {
                    XCTAssertEqual(va.1, vb.1, accuracy: abs(vb.1) * 0.25 + 1, "\(label.rawValue) seed \(seed) scroll speed")
                }
            }
        }
    }

    /// The gesture intents in order, without positions or cursor moves.
    private func summary(_ out: StepOutput) -> [String] {
        out.intents.compactMap { intent in
            switch intent {
            case .move: return nil
            case let .click(_, _, count): return "click\(count)"
            case .rightClick: return "right"
            case .down: return "down"
            case .up: return "up"
            case let .scroll(dx, dy, phase):
                guard phase == .began else { return nil }
                return "scroll" + (abs(dy) >= abs(dx) ? (dy < 0 ? "Up" : "Down") : "Side")
            case let .zoom(_, phase): return phase == .changed ? nil : "zoom-\(phase.rawValue)"
            case .key: return "key"
            }
        }
    }

    // MARK: Settings and modes

    func testVelocityIsTheDefaultAndPoseIsSelectable() {
        XCTAssertEqual(GestureConfig().inputModel, .velocity)
        // A pinch tap does nothing in Velocity mode, and clicks in Pose mode.
        let pinch = SyntheticStream.pinchTaps(at: [0.6], fps: 30)
        XCTAssertEqual(Evaluation.merged(run(pinch)).clicks.count, 0)
        XCTAssertEqual(Evaluation.merged(run(pinch, .pose)).clicks.count, 1)
    }

    func testSwitchingModeMidDragReleasesTheButton() {
        let frames = stream(fps: 60, duration: 1.6) { t in
            self.tap(t, at: 0.8) + VelocitySynthetic.stroke(t - 1.1, direction: Point2(1, 0), amplitude: 0.25,
                                                            outTime: 0.5, backTime: 0)
        }
        let machine = PointerStateMachine(config: config, displays: [testDisplay])
        _ = machine.setEngaged(true, at: 0)
        var out = StepOutput()
        for frame in frames { out.append(machine.process(frame)) }
        XCTAssertEqual(out.downs, 1)
        XCTAssertEqual(machine.state, .dragging)
        let switched = machine.updateConfig(.pose)
        XCTAssertEqual(switched.ups, 1)
        XCTAssertNotEqual(machine.state, .dragging)
    }

    func testLenientDecodingKeepsNestedVelocityDefaults() throws {
        let json = #"{"inputModel":"pose","velocity":{"vEnter":1.2}}"#
        let decoded = try GestureConfig.decodeLenient(Data(json.utf8))
        XCTAssertEqual(decoded.inputModel, .pose)
        XCTAssertEqual(decoded.velocity.vEnter, 1.2)
        XCTAssertEqual(decoded.velocity.vExit, VelocityParams().vExit)
        // A settings file from before M7 gets Velocity mode with default parameters.
        let old = try GestureConfig.decodeLenient(Data(#"{"pinchEnter":0.3}"#.utf8))
        XCTAssertEqual(old.inputModel, .velocity)
        XCTAssertEqual(old.velocity, VelocityParams())
    }

    func testSegmentReportsReachTheSnapshot() {
        let machine = PointerStateMachine(config: config, displays: [testDisplay])
        _ = machine.setEngaged(true, at: 0)
        var sawTrail = false
        for frame in stream(fps: 60, duration: 2, offset: { self.tap($0, at: 0.8) }) {
            _ = machine.process(frame)
            if machine.snapshot.segmentTrail.count > 1 { sawTrail = true }
        }
        XCTAssertTrue(sawTrail)
        XCTAssertEqual(machine.snapshot.segmentTrail, [])
        XCTAssertEqual(machine.snapshot.lastSegment?.gesture, .click)
        XCTAssertNotNil(machine.snapshot.lastSegment?.anchor)
    }
}
