import XCTest
@testable import GestureCore

final class OneEuroFilterTests: XCTestCase {
    /// A still hand with tracker jitter of 6 px RMS per axis (at screen scale, roughly what
    /// Vision produces for a fingertip) must produce a cursor that moves less than 0.3 px between
    /// frames once settled: 1€ filter plus the rest lock.
    func testStationaryJitterIsSuppressed() {
        let config = GestureConfig.default
        var smoother = PointerSmoother(config: config)
        var rng = SeededRandom(seed: 42)
        let screenWidth = 1728.0
        let jitterBox = 6.0 / screenWidth
        var outputs: [Point2] = []
        for i in 0..<900 {
            let t = Double(i) / 30
            let raw = Point2(0.5 + rng.gaussian() * jitterBox, 0.5 + rng.gaussian() * jitterBox)
            outputs.append(smoother.process(raw, at: t) * screenWidth)
        }
        let settled = outputs.dropFirst(30)
        var maxStep = 0.0
        for (a, b) in zip(settled, settled.dropFirst()) { maxStep = max(maxStep, a.distance(to: b)) }
        XCTAssertLessThan(maxStep, 0.3, "cursor wandered \(maxStep) px per frame on a still hand")
    }

    /// The raw 1€ filter alone should cut jitter substantially at rest.
    func testFilterReducesJitterVariance() {
        var filter = OneEuroFilter(OneEuroParameters(minCutoff: 0.8, beta: 6))
        var rng = SeededRandom(seed: 3)
        var rawSteps = 0.0, filteredSteps = 0.0
        var lastRaw = 0.5, lastFiltered = 0.5
        for i in 0..<300 {
            let raw = 0.5 + rng.gaussian() * 0.002
            let f = filter.filter(raw, at: Double(i) / 30)
            if i > 30 {
                rawSteps += abs(raw - lastRaw)
                filteredSteps += abs(f - lastFiltered)
            }
            lastRaw = raw
            lastFiltered = f
        }
        XCTAssertLessThan(filteredSteps, rawSteps * 0.25)
    }

    /// A fast sweep (the full screen width in 0.6 s) must be tracked with less than one frame of
    /// lag once the filter has picked up the speed.
    func testFastRampLagUnderOneFrame() {
        var config = GestureConfig.default
        config.precisionEnabled = true
        var smoother = PointerSmoother(config: config)
        let fps = 30.0
        let speed = 1.0 / 0.6 // box widths per second
        let step = speed / fps
        var worstLagFrames = 0.0
        for i in 0..<18 {
            let t = Double(i) / fps
            let raw = Point2(Double(i) * step, 0.5)
            let out = smoother.process(raw, at: t)
            if i >= 6 { worstLagFrames = max(worstLagFrames, (raw.x - out.x) / step) }
        }
        XCTAssertLessThan(worstLagFrames, 1.0)
    }

    func testTwoDimensionalFilterIsDirectionIndependent() {
        var horizontal = OneEuroFilter2D(OneEuroParameters(minCutoff: 1, beta: 5))
        var diagonal = OneEuroFilter2D(OneEuroParameters(minCutoff: 1, beta: 5))
        var h = Point2.zero, d = Point2.zero
        for i in 0..<20 {
            let t = Double(i) / 30
            let s = Double(i) * 0.02
            h = horizontal.filter(Point2(s, 0), at: t)
            d = diagonal.filter(Point2(s / 2.0.squareRoot(), s / 2.0.squareRoot()), at: t)
        }
        XCTAssertEqual(h.length, d.length, accuracy: 1e-9)
    }

    func testDuplicateTimestampDoesNotExplode() {
        var filter = OneEuroFilter(OneEuroParameters(minCutoff: 1, beta: 1))
        _ = filter.filter(0, at: 1)
        let v = filter.filter(1, at: 1)
        XCTAssertTrue(v.isFinite)
        XCTAssertGreaterThan(v, 0)
    }

    func testPrecisionModeSlowsSlowMovementAndRecovers() {
        var config = GestureConfig.default
        config.deadZoneBox = 0
        var smoother = PointerSmoother(config: config)
        var t = 0.0
        var out = Point2.zero
        // Creep slowly 0.02 box over 1 s.
        for i in 0...30 {
            t = Double(i) / 30
            out = smoother.process(Point2(0.5 + 0.02 * Double(i) / 30, 0.5), at: t)
        }
        XCTAssertLessThan(out.x - 0.5, 0.02 * 0.8, "slow motion should be scaled down")
        // Then a fast move: the offset drains and the absolute mapping returns.
        for i in 1...20 {
            t += 1 / 30
            out = smoother.process(Point2(0.52 + 0.3 * Double(i) / 20, 0.5), at: t)
        }
        for _ in 0..<30 {
            t += 1 / 30
            out = smoother.process(Point2(0.82, 0.5), at: t)
        }
        XCTAssertEqual(out.x, 0.82, accuracy: 0.004)
    }
}
