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
    }

    func testFingerDistancesAreScaleInvariant() {
        var near = SyntheticHand.pointing(tipAt: Point2(0.5, 0.45))
        near.size = 0.16
        near.pinchAmount = 0.5
        var far = near
        far.size = 0.06
        XCTAssertEqual(near.frame(at: 0).pinchDistanceNormalized(.index),
                       far.frame(at: 0).pinchDistanceNormalized(.index), accuracy: 1e-9)
    }

    /// Feed `pose(t)` at 30 fps for `duration`; return the confirmed pose after each frame.
    private func poses(duration: Double, _ pose: (Double) -> SyntheticHand) -> [(Double, HandPose)] {
        var detector = GestureDetector(config: .default)
        return (0..<Int(duration * 30)).map { i in
            let t = Double(i) / 30
            detector.update(pose(t).frame(at: t))
            return (t, detector.state.pose)
        }
    }

    func testFistIsConfirmedAfterTheConfirmationDelay() {
        let result = poses(duration: 1) { t in
            var hand = SyntheticHand.pointing(tipAt: Point2(0.5, 0.45))
            if t >= 0.5 { hand.makeFist() }
            return hand
        }
        let firstFist = result.first { $0.1 == .fist }?.0 ?? 99
        XCTAssertGreaterThanOrEqual(firstFist, 0.5 + GestureConfig.default.poseConfirmDuration - 1e-9)
        XCTAssertLessThan(firstFist, 0.5 + GestureConfig.default.poseConfirmDuration + 0.05)
    }

    func testOneFrameFistGlitchIsIgnored() {
        let result = poses(duration: 1) { t in
            var hand = SyntheticHand.pointing(tipAt: Point2(0.5, 0.45))
            if abs(t - 0.5) < 0.01 { hand.makeFist() }
            return hand
        }
        XCTAssertFalse(result.contains { $0.1 == .fist })
    }

    func testThumbTouchingAFingerIsNotAnOpenPalm() {
        let result = poses(duration: 1) { _ in
            var hand = SyntheticHand.pointing(tipAt: Point2(0.5, 0.45))
            hand.makeOpenPalm()
            hand.pinchAmount = 1
            return hand
        }
        XCTAssertFalse(result.contains { $0.1 == .openPalm })
    }
}
