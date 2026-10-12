import XCTest
@testable import GestureCore

/// SPEC-M7 acceptance tests against the synthetic generator (until the owner's recordings
/// replace it): every class ≥ 95% over 200 samples, rest/jitter/reposition stay silent.
final class VelocityAccuracyTests: XCTestCase {
    private let config = GestureConfig.velocityMode

    private func outcomes(_ label: GestureLabel, count: Int = 200) -> [GestureOutcome] {
        (0..<count).map { i in
            // Alternate camera rates: half the samples at 60 fps, half at 30 fps.
            let sample = VelocitySynthetic.sample(label, fps: i % 2 == 0 ? 60 : 30, seed: UInt64(i + 1))
            return GestureOutcome.of(Evaluation.merged(Evaluation.run(sample.frames, config: config)).events)
        }
    }

    func testEveryClassIsRecognisedAtLeast95Percent() {
        var report: [String] = []
        for label in GestureLabel.allCases {
            let results = outcomes(label)
            let correct = results.filter { $0 == label.expected }.count
            let accuracy = Double(correct) / Double(results.count)
            report.append("\(label.rawValue): \(correct)/\(results.count)")
            XCTAssertGreaterThanOrEqual(accuracy, 0.95, "\(label.rawValue) recognised \(correct)/\(results.count)")
        }
        print("Velocity accuracy — " + report.joined(separator: ", "))
    }

    func testRestAndJitterProduceNoIntents() {
        for label in [GestureLabel.rest, .jitter] {
            for i in 0..<100 {
                let sample = VelocitySynthetic.sample(label, fps: i % 2 == 0 ? 60 : 30, seed: UInt64(i + 1))
                let outputs = Evaluation.run(sample.frames, config: config)
                let actions = Evaluation.merged(outputs).intents.filter {
                    if case .move = $0 { return false } else { return true }
                }
                XCTAssertEqual(actions, [], "\(label.rawValue) sample \(i) produced \(actions)")
            }
        }
    }

    func testFastRepositionNeverClicksOrScrolls() {
        for i in 0..<200 {
            let sample = VelocitySynthetic.sample(.repositionFast, fps: i % 2 == 0 ? 60 : 30, seed: UInt64(i + 1))
            let out = Evaluation.merged(Evaluation.run(sample.frames, config: config))
            XCTAssertEqual(out.clicks.count + out.rightClicks + out.downs, 0, "sample \(i) clicked")
            XCTAssertEqual(out.scrolls(.began).count, 0, "sample \(i) scrolled")
        }
    }
}
