import Foundation

/// Runs frame streams through a `PointerStateMachine` exactly as the app would (engaged at the
/// first frame, momentum ticked between frames), for the tests and the replay tool.
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
}
