import Foundation

/// Runs frame streams through a `PointerStateMachine` and scores what it did against labels.
/// Shared by the tests and the `tune` tool so both measure exactly the same thing.
public enum Evaluation {
    public struct TimedOutput {
        public var time: Double
        public var output: StepOutput
    }

    public static let defaultDisplay = DisplayInfo(id: "main", frame: Rect(x: 0, y: 0, width: 1728, height: 1117))

    /// Feed `frames` to a fresh machine engaged at the first frame, ticking momentum at
    /// `tickRate` between frames (as the app's timer does) and for `settle` seconds after.
    public static func run(_ frames: [TrackingFrame], config: GestureConfig,
                           display: DisplayInfo = defaultDisplay, tickRate: Double = 120,
                           settle: Double = 1.5) -> [TimedOutput] {
        let machine = PointerStateMachine(config: config, displays: [display])
        let start = frames.first?.timestamp ?? 0
        var outputs = [TimedOutput(time: start, output: machine.setEngaged(true, reason: .hotkey, at: start))]
        var lastTick = start
        for frame in frames {
            while lastTick + 1 / tickRate < frame.timestamp {
                lastTick += 1 / tickRate
                let out = machine.tick(at: lastTick)
                if !out.intents.isEmpty { outputs.append(TimedOutput(time: lastTick, output: out)) }
            }
            outputs.append(TimedOutput(time: frame.timestamp, output: machine.process(frame)))
        }
        let end = frames.last?.timestamp ?? start
        while lastTick < end + settle {
            lastTick += 1 / tickRate
            let out = machine.tick(at: lastTick)
            if !out.intents.isEmpty { outputs.append(TimedOutput(time: lastTick, output: out)) }
        }
        return outputs
    }

    /// Everything produced between `from` and `to` (inclusive).
    public static func merged(_ outputs: [TimedOutput], from: Double = -.infinity, to: Double = .infinity) -> StepOutput {
        var out = StepOutput()
        for o in outputs where o.time >= from && o.time <= to { out.append(o.output) }
        return out
    }

    public struct LabeledResult {
        public var label: String
        public var outcome: GestureOutcome
        public var reports: [SegmentReport]
    }

    /// Run a labeled recording in one pass (state carries across segments, as it would live)
    /// and summarize each labeled stretch.
    public static func evaluate(_ recording: Recording, config: GestureConfig) -> [LabeledResult] {
        let outputs = run(recording.frames, config: config, settle: 0)
        return (recording.segments ?? []).map { segment in
            let window = merged(outputs, from: segment.startTime, to: segment.endTime)
            let reports = window.events.compactMap { event -> SegmentReport? in
                if case let .segmentClassified(report) = event { return report } else { return nil }
            }
            return LabeledResult(label: segment.label, outcome: GestureOutcome.of(window.events), reports: reports)
        }
    }

    /// Precision, recall and F1 of the action classes (labels expecting `.none` count as
    /// negatives: anything they trigger is a false positive).
    public struct Score: Equatable {
        public var truePositives = 0
        public var falsePositives = 0
        public var falseNegatives = 0
        public var correct = 0
        public var total = 0

        public var precision: Double { Double(truePositives) / Double(max(truePositives + falsePositives, 1)) }
        public var recall: Double { Double(truePositives) / Double(max(truePositives + falseNegatives, 1)) }
        public var f1: Double {
            let p = precision, r = recall
            return p + r > 0 ? 2 * p * r / (p + r) : 0
        }
        public var accuracy: Double { Double(correct) / Double(max(total, 1)) }
    }

    public static func score(_ results: [LabeledResult]) -> Score {
        var score = Score()
        for result in results {
            guard let label = GestureLabel(rawValue: result.label) else { continue }
            let expected = label.expected
            score.total += 1
            if result.outcome == expected { score.correct += 1 }
            if expected == .none {
                if result.outcome != .none { score.falsePositives += 1 }
            } else if result.outcome == expected {
                score.truePositives += 1
            } else {
                score.falseNegatives += 1
                if result.outcome != .none { score.falsePositives += 1 }
            }
        }
        return score
    }
}
