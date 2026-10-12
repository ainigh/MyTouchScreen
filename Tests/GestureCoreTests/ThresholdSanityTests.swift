import XCTest
@testable import GestureCore

/// Re-checks the default thresholds against synthetic sessions at both camera rates and with
/// realistic tracker noise: every gesture recognised exactly once, nothing extra — and none of
/// the retired ways of clicking (pinches, dwelling, taps) clicks any more.
final class ThresholdSanityTests: XCTestCase {
    /// A still hand pinching (thumb to `finger`) for `tapDuration` at each start time.
    private func pinchTaps(at starts: [Double], finger: PinchFinger = .index, tapDuration: Double = 0.12,
                           fps: Double, noise: Double) -> [TrackingFrame] {
        SyntheticStream.generate(duration: (starts.max() ?? 0) + 1.5, fps: fps, noise: noise) { t in
            var hand = SyntheticHand.pointing(tipAt: Point2(0.5, 0.45))
            hand.pinchFinger = finger
            hand.pinchAmount = starts.map { SyntheticStream.tapAmount(at: t, start: $0, duration: tapDuration) }.max() ?? 0
            return [hand]
        }
    }

    func testGesturesAt30And60FPSWithNoise() {
        for fps in [30.0, 60.0] {
            for noise in [0.0, 0.0008, 0.0015] {
                func run(_ frames: [TrackingFrame]) -> StepOutput { drive(engagedMachine(), frames) }
                let click = run(SyntheticStream.wiggleClick(fps: fps).map { noisy($0, noise) })
                XCTAssertEqual(click.clicks.map(\.2), [1], "wiggle click at \(fps) fps, noise \(noise)")
                let drag = run(SyntheticStream.fistDrag(fps: fps).map { noisy($0, noise) })
                XCTAssertEqual([drag.downs, drag.ups, drag.clicks.count], [1, 1, 0], "fist drag at \(fps) fps, noise \(noise)")
            }
        }
    }

    func testRetiredClickGesturesNeverClick() {
        for fps in [30.0, 60.0] {
            for noise in [0.0, 0.0015] {
                let cases: [(String, [TrackingFrame])] = [
                    ("pinch taps", pinchTaps(at: [0.6, 1.5, 2.4, 3.5], fps: fps, noise: noise)),
                    ("quick double pinch", pinchTaps(at: [0.6, 0.85], fps: fps, noise: noise)),
                    ("middle-finger pinch", pinchTaps(at: [0.6, 2.0], finger: .middle, fps: fps, noise: noise)),
                    ("pinch held (old drag)", pinchTaps(at: [0.6], tapDuration: 1.5, fps: fps, noise: noise)),
                    ("still hand (old dwell)", SyntheticStream.steady(duration: 5, fps: fps, noise: noise)),
                ]
                for (name, frames) in cases {
                    let out = drive(engagedMachine(), frames)
                    // Two pinches in quick succession are in-out-in-out: a wiggle, so one click.
                    let allowed = name == "quick double pinch" ? 1 : 0
                    XCTAssertLessThanOrEqual(out.clicks.count, allowed, "\(name) at \(fps) fps, noise \(noise)")
                    XCTAssertEqual(out.downs, 0, "\(name) at \(fps) fps, noise \(noise)")
                }
            }
        }
        // Velocity mode's taps and flicks, from a still hand.
        for label in [GestureLabel.click, .doubleClick, .rightClick, .scrollUp, .scrollDown, .drag] {
            for seed in 1...20 {
                let sample = MotionSynthetic.sample(label, fps: seed % 2 == 0 ? 60 : 30, seed: UInt64(seed))
                let out = drive(engagedMachine(), sample.frames)
                // A quick double tap is down-up-down-up: itself a wiggle, so it may click once.
                let allowed = label == .doubleClick ? 1 : 0
                XCTAssertLessThanOrEqual(out.clicks.count, allowed, "\(label.rawValue) \(seed)")
                XCTAssertEqual(out.downs, 0, "\(label.rawValue) \(seed)")
            }
        }
    }

    /// Add per-landmark tracker noise to a frame, deterministically.
    private func noisy(_ frame: TrackingFrame, _ noise: Double) -> TrackingFrame {
        guard noise > 0 else { return frame }
        var rng = SeededRandom(seed: UInt64(frame.timestamp * 1000) + 7)
        var copy = frame
        for i in copy.hands.indices {
            let hand = copy.hands[i]
            let points = hand.points.map { $0 + Point2(rng.gaussian(), rng.gaussian()) * noise }
            copy.hands[i] = HandFrame(points: points, chirality: hand.chirality, confidence: hand.confidence,
                                      timestamp: hand.timestamp, imageAspect: hand.imageAspect)
        }
        return copy
    }
}
