import XCTest
@testable import GestureCore

final class PointerResponseTests: XCTestCase {
    func testPresetGainsAtSlowAndFastSpeeds() {
        let slow = 0.05, fast = 2.0
        XCTAssertEqual(PointerResponse.direct.gain(atSpeed: slow), 1)
        XCTAssertEqual(PointerResponse.direct.gain(atSpeed: fast), 1)
        XCTAssertEqual(PointerResponse.slowBoost.gain(atSpeed: slow), 2)
        XCTAssertEqual(PointerResponse.slowBoost.gain(atSpeed: fast), 1)
        XCTAssertEqual(PointerResponse.fastDamp.gain(atSpeed: slow), 1)
        XCTAssertEqual(PointerResponse.fastDamp.gain(atSpeed: fast), 0.5)
        XCTAssertEqual(PointerResponse.inverted.gain(atSpeed: slow), 2)
        XCTAssertEqual(PointerResponse.inverted.gain(atSpeed: fast), 0.5)
        XCTAssertEqual(PointerResponse.accelerated.gain(atSpeed: slow), 0.5)
        XCTAssertEqual(PointerResponse.accelerated.gain(atSpeed: fast), 2)
    }

    /// Between the slow and fast speeds the gain changes smoothly and monotonically.
    func testGainBlendIsMonotonic() {
        for response in PointerResponse.allCases {
            var previous = response.gain(atSpeed: 0)
            for i in 1...100 {
                let g = response.gain(atSpeed: Double(i) * 0.015)
                if response.fastGain >= response.slowGain {
                    XCTAssertGreaterThanOrEqual(g, previous - 1e-12, "\(response)")
                } else {
                    XCTAssertLessThanOrEqual(g, previous + 1e-12, "\(response)")
                }
                previous = g
            }
        }
    }

    /// The same slow sweep moves the cursor twice as far with `.double` and half as far with
    /// `.half` as with `.direct`, which leaves the cursor under the finger.
    func testScaledPresetsScaleCursorTravel() {
        func travel(_ response: PointerResponse) -> Double {
            var config = GestureConfig.default
            config.pointerResponse = response
            var smoother = PointerSmoother(config: config)
            var first: Point2?, last = Point2.zero
            for i in 0...90 {
                let t = Double(i) / 30
                last = smoother.process(Point2(0.4 + 0.1 * t / 3, 0.5), at: t)
                if first == nil { first = last }
            }
            for i in 91...150 { last = smoother.process(Point2(0.5, 0.5), at: Double(i) / 30) }
            return last.x - (first?.x ?? 0)
        }
        let direct = travel(.direct)
        XCTAssertEqual(direct, 0.1, accuracy: 0.01)
        XCTAssertEqual(travel(.double), 2 * direct, accuracy: 0.01)
        XCTAssertEqual(travel(.half), 0.5 * direct, accuracy: 0.01)
    }

    /// A still hand stays still whatever the preset: the gain multiplies motion, and the rest
    /// lock has already removed the jitter.
    func testStillHandIsSteadyWithEveryPreset() {
        for response in PointerResponse.allCases {
            var config = GestureConfig.default
            config.pointerResponse = response
            var smoother = PointerSmoother(config: config)
            var rng = SeededRandom(seed: 7)
            var outputs: [Point2] = []
            for i in 0..<300 {
                let raw = Point2(0.5 + rng.gaussian() * 0.002, 0.5 + rng.gaussian() * 0.002)
                outputs.append(smoother.process(raw, at: Double(i) / 30) * 1728)
            }
            let settled = outputs.dropFirst(30)
            let travel = zip(settled, settled.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            XCTAssertLessThan(travel, 12, "\(response) wandered \(travel) pt")
        }
    }

    /// Scaled cursors stop at the screen edge and come back as soon as the hand does.
    func testCursorIsKeptOnScreen() {
        var config = GestureConfig.default
        config.pointerResponse = .double
        var smoother = PointerSmoother(config: config)
        var out = Point2.zero
        for i in 0...60 { out = smoother.process(Point2(0.5 + 0.4 * Double(i) / 60, 0.5), at: Double(i) / 30) }
        XCTAssertEqual(out.x, 1, accuracy: 1e-9)
        for i in 61...90 { out = smoother.process(Point2(0.9 - 0.2 * Double(i - 60) / 30, 0.5), at: Double(i) / 30) }
        XCTAssertLessThan(out.x, 0.7)
    }

    func testOldSettingsWithoutResponseDecodeAsDirect() throws {
        let json = Data(#"{"boxScale": 1.2}"#.utf8)
        XCTAssertEqual(try GestureConfig.decodeLenient(json).pointerResponse, .direct)
        var config = GestureConfig()
        config.pointerResponse = .inverted
        let round = try GestureConfig.decodeLenient(JSONEncoder().encode(config))
        XCTAssertEqual(round.pointerResponse, .inverted)
    }
}
