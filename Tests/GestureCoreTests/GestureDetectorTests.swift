import XCTest
@testable import GestureCore

final class GestureDetectorTests: XCTestCase {
    func testSyntheticPosesClassify() {
        let pointing = HandFeatures(SyntheticHand.pointing(tipAt: Point2(0.5, 0.45)).frame(at: 0))
        XCTAssertGreaterThan(pointing.indexPinch, 0.8)
        XCTAssertGreaterThan(pointing.curlRatios[0], 1.45)

        var fist = SyntheticHand.pointing(tipAt: Point2(0.5, 0.45))
        fist.makeFist()
        XCTAssertTrue(HandFeatures(fist.frame(at: 0)).curlRatios.allSatisfy { $0 < 1.2 })

        var palm = SyntheticHand.pointing(tipAt: Point2(0.5, 0.45))
        palm.makeOpenPalm()
        let palmFeatures = HandFeatures(palm.frame(at: 0))
        XCTAssertTrue(palmFeatures.curlRatios.allSatisfy { $0 > 1.45 })
        XCTAssertGreaterThan(palmFeatures.thumbSpread, 0.55)

        var pinched = SyntheticHand.pointing(tipAt: Point2(0.5, 0.45))
        pinched.pinchAmount = 1
        XCTAssertLessThan(HandFeatures(pinched.frame(at: 0)).indexPinch, 0.2)
    }

    func testPinchDistanceIsScaleInvariant() {
        var near = SyntheticHand.pointing(tipAt: Point2(0.5, 0.45))
        near.size = 0.16
        near.pinchAmount = 0.5
        var far = near
        far.size = 0.06
        XCTAssertEqual(near.frame(at: 0).pinchDistanceNormalized(.index),
                       far.frame(at: 0).pinchDistanceNormalized(.index), accuracy: 1e-9)
    }

    /// Feed a hand whose normalized pinch distance follows `distances` exactly (one per frame).
    private func detectorRun(_ distances: [Double], fps: Double = 30, config: GestureConfig = .default)
        -> (began: [Double], ended: [Double]) {
        var detector = GestureDetector(config: config)
        var began: [Double] = [], ended: [Double] = []
        for (i, target) in distances.enumerated() {
            let t = Double(i) / fps
            var hand = SyntheticHand.pointing(tipAt: Point2(0.5, 0.45))
            hand.pinchAmount = Self.amount(forDistance: target)
            for event in detector.update(hand.frame(at: t)) {
                if case .pinchBegan = event { began.append(t) }
                if case .pinchEnded = event { ended.append(t) }
            }
        }
        return (began, ended)
    }

    /// Invert the synthetic pinch model numerically.
    static func amount(forDistance d: Double) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0..<50 {
            let mid = (lo + hi) / 2
            var h = SyntheticHand.pointing(tipAt: Point2(0.5, 0.45))
            h.pinchAmount = mid
            if h.frame(at: 0).pinchDistanceNormalized(.index) > d { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    func testPinchEntersBelowEnterAndExitsAboveExit() {
        // 0.40 is between the thresholds: never enters from open.
        let between = detectorRun(Array(repeating: 0.9, count: 5) + Array(repeating: 0.40, count: 20))
        XCTAssertTrue(between.began.isEmpty)

        // Enter at 0.30, then hover at 0.45 (inside hysteresis): stays pinched; 0.6 releases.
        let seq = Array(repeating: 0.9, count: 5) + Array(repeating: 0.30, count: 5)
            + Array(repeating: 0.45, count: 20) + Array(repeating: 0.6, count: 5)
        let result = detectorRun(seq)
        XCTAssertEqual(result.began.count, 1)
        XCTAssertEqual(result.ended.count, 1)
        XCTAssertGreaterThanOrEqual(result.ended[0], 30.0 / 30)
    }

    func testNoisyPinchNeverFlickers() {
        // A held pinch with heavy noise around 0.30 (±0.12 uniform, peaks just under exit).
        var rng = SeededRandom(seed: 9)
        let noisy = (0..<90).map { _ in 0.30 + (rng.unit() - 0.5) * 0.24 }
        let result = detectorRun(Array(repeating: 0.9, count: 5) + noisy + Array(repeating: 0.9, count: 5))
        XCTAssertEqual(result.began.count, 1)
        XCTAssertEqual(result.ended.count, 1)
    }

    func testSingleGlitchFrameDoesNotReleasePinch() {
        let seq = Array(repeating: 0.9, count: 3) + Array(repeating: 0.2, count: 10) + [0.9]
            + Array(repeating: 0.2, count: 10) + Array(repeating: 0.9, count: 4)
        let result = detectorRun(seq)
        XCTAssertEqual(result.began.count, 1)
        XCTAssertEqual(result.ended.count, 1)
    }

    func testBriefContactBelowMinimumDurationIgnored() {
        // One 60 fps frame (16 ms) of contact: shorter than the 60 ms minimum.
        let seq = Array(repeating: 0.9, count: 5) + [0.2] + Array(repeating: 0.9, count: 10)
        XCTAssertTrue(detectorRun(seq, fps: 60).began.isEmpty)
    }

    func testRefractoryBlocksImmediateRepinch() {
        // Release then re-close within 60 ms at 60 fps: second pinch is held off until the
        // refractory period ends, so it begins later than its raw start.
        let seq = Array(repeating: 0.9, count: 3) + Array(repeating: 0.2, count: 10)
            + Array(repeating: 0.9, count: 3) + Array(repeating: 0.2, count: 20)
        let result = detectorRun(seq, fps: 60)
        XCTAssertEqual(result.began.count, 2)
        let releaseTime = result.ended[0]
        XCTAssertGreaterThanOrEqual(result.began[1] - releaseTime, GestureConfig.default.pinchRefractory)
    }

    func testMiddlePinchIsAttributedToMiddleFinger() {
        var detector = GestureDetector(config: .default)
        var fingers: [PinchFinger] = []
        for i in 0..<20 {
            var hand = SyntheticHand.pointing(tipAt: Point2(0.5, 0.45))
            hand.pinchFinger = .middle
            hand.pinchAmount = i < 3 ? 0 : 1
            for case let .pinchBegan(finger, _) in detector.update(hand.frame(at: Double(i) / 30)) {
                fingers.append(finger)
            }
        }
        XCTAssertEqual(fingers, [.middle])
    }

    func testFistDoesNotPinch() {
        var detector = GestureDetector(config: .default)
        var pinches = 0
        var pose: HandPose = .point
        for i in 0..<30 {
            var hand = SyntheticHand.pointing(tipAt: Point2(0.5, 0.45))
            if i > 2 { hand.makeFist() }
            for event in detector.update(hand.frame(at: Double(i) / 30)) {
                if case .pinchBegan = event { pinches += 1 }
                if case let .poseChanged(p) = event { pose = p }
            }
        }
        XCTAssertEqual(pinches, 0)
        XCTAssertEqual(pose, .fist)
    }
}
