import Foundation

/// The guided recording session (`--record session.json --script`) as a timetable: for each
/// prompt, `repetitions` times, show the prompt, wait `lead` seconds, record the label's
/// duration, then pause `gap` seconds. The app only follows the timetable; the timing lives
/// here so it is tested on Linux.
public struct TuningScript: Equatable {
    public struct Step: Equatable {
        public var label: GestureLabel
        /// 1-based repetition number.
        public var repetition: Int
        public var repetitions: Int
        /// Seconds from the start of the session.
        public var promptAt: Double
        public var recordStart: Double
        public var recordEnd: Double
    }

    public private(set) var steps: [Step] = []

    public init(labels: [GestureLabel] = GestureLabel.scripted, repetitions: Int = 8,
                lead: Double = 1.0, gap: Double = 1.0) {
        var t = 0.0
        for label in labels {
            for n in 1...max(repetitions, 1) {
                let start = t + lead
                let end = start + label.recordDuration
                steps.append(Step(label: label, repetition: n, repetitions: max(repetitions, 1),
                                  promptAt: t, recordStart: start, recordEnd: end))
                t = end + gap
            }
        }
    }

    public var duration: Double { (steps.last?.recordEnd ?? 0) }

    /// What the overlay should show `elapsed` seconds into the session.
    public enum Phase: Equatable {
        /// Get ready: the prompt is shown, recording for this step hasn't started.
        case prompt(Step)
        case recording(Step, remaining: Double)
        /// Between steps.
        case pause(next: Step)
        case finished
    }

    public func phase(at elapsed: Double) -> Phase {
        for (i, step) in steps.enumerated() {
            if elapsed < step.promptAt { return .pause(next: step) }
            if elapsed < step.recordStart { return .prompt(step) }
            if elapsed < step.recordEnd { return .recording(step, remaining: step.recordEnd - elapsed) }
            if i == steps.count - 1 { return .finished }
        }
        return .finished
    }

    /// The labeled segments for a session that started at `start` (on the frames' clock),
    /// keeping only the steps finished by `elapsed` (a session stopped early keeps what it has).
    public func segments(startingAt start: Double, completedBy elapsed: Double = .infinity) -> [LabeledSegment] {
        steps.filter { $0.recordEnd <= elapsed }.map { LabeledSegment(label: $0.label.rawValue, startTime: start + $0.recordStart, endTime: start + $0.recordEnd) }
    }
}
