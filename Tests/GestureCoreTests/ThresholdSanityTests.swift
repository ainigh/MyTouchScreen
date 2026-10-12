import XCTest
@testable import GestureCore

/// Re-checks the default thresholds against synthetic sessions at both camera rates and with
/// realistic tracker noise: every gesture must be recognised exactly once, nothing extra.
final class ThresholdSanityTests: XCTestCase {
    func scenarios(fps: Double, noise: Double) -> [(String, [TrackingFrame], (StepOutput) -> Bool)] {
        [
            ("single taps", SyntheticStream.pinchTaps(at: [0.6, 1.5, 2.4], fps: fps, noise: noise),
             { $0.clicks.map { $0.2 } == [1, 1, 1] && $0.downs == 0 }),
            ("double tap", SyntheticStream.pinchTaps(at: [0.6, 0.85], fps: fps, noise: noise),
             { $0.clicks.map { $0.2 } == [1, 2] }),
            ("right click", SyntheticStream.pinchTaps(at: [0.6], finger: .middle, fps: fps, noise: noise),
             { $0.rightClicks == 1 && $0.clicks.isEmpty }),
            ("still hand", SyntheticStream.steady(duration: 3, fps: fps, noise: noise),
             { $0.clicks.isEmpty && $0.downs == 0 && $0.scrolls(.began).isEmpty }),
        ]
    }

    func testDefaultsAt30And60FPSWithNoise() {
        for fps in [30.0, 60.0] {
            for noise in [0.0, 0.0008, 0.0015] {
                for (name, frames, check) in scenarios(fps: fps, noise: noise) {
                    let out = drive(engagedMachine(), frames)
                    XCTAssertTrue(check(out), "\(name) at \(fps) fps, noise \(noise): clicks \(out.clicks.map { $0.2 }), downs \(out.downs), right \(out.rightClicks)")
                }
            }
        }
    }

    func testDragAndScrollAt60FPS() {
        let drag = drive(engagedMachine(), SyntheticStream.drag(fps: 60))
        XCTAssertEqual(drag.downs, 1)
        XCTAssertEqual(drag.ups, 1)
        let scroll = drive(engagedMachine(), SyntheticStream.fistScroll(fps: 60))
        XCTAssertEqual(scroll.scrolls(.began).count, 1)
        XCTAssertEqual(scroll.scrolls(.momentumBegan).count, 1)
        XCTAssertEqual(scroll.clicks.count, 0)
    }
}
