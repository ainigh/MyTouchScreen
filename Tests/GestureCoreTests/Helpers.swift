import XCTest
@testable import GestureCore

let testDisplay = DisplayInfo(id: "main", frame: Rect(x: 0, y: 0, width: 1728, height: 1117))

/// Runs frames through a machine, collecting everything it produced. Calls `tick` at 120 Hz
/// between frames, like the app's display timer.
@discardableResult
func drive(_ machine: PointerStateMachine, _ frames: [TrackingFrame], tickRate: Double = 120) -> StepOutput {
    var out = StepOutput()
    var lastTick = frames.first?.timestamp ?? 0
    for frame in frames {
        while lastTick + 1 / tickRate < frame.timestamp {
            lastTick += 1 / tickRate
            out.append(machine.tick(at: lastTick))
        }
        out.append(machine.process(frame))
    }
    // Let momentum play out after the stream.
    if let end = frames.last?.timestamp {
        var t = end
        while t < end + 3 {
            t += 1 / tickRate
            out.append(machine.tick(at: t))
        }
    }
    return out
}

func engagedMachine(_ config: GestureConfig = .default, displays: [DisplayInfo] = [testDisplay]) -> PointerStateMachine {
    let machine = PointerStateMachine(config: config, displays: displays)
    _ = machine.setEngaged(true, reason: .hotkey, at: 0)
    return machine
}

extension StepOutput {
    var clicks: [(Double, Double, Int)] {
        intents.compactMap { if case let .click(x, y, n) = $0 { return (x, y, n) } else { return nil } }
    }
    var rightClicks: Int {
        intents.filter { if case .rightClick = $0 { return true } else { return false } }.count
    }
    var downs: Int { intents.filter { if case .down = $0 { return true } else { return false } }.count }
    var ups: Int { intents.filter { if case .up = $0 { return true } else { return false } }.count }
    var moves: [Point2] {
        intents.compactMap { if case let .move(x, y) = $0 { return Point2(x, y) } else { return nil } }
    }
    func scrolls(_ phase: ScrollPhase) -> [(Double, Double)] {
        intents.compactMap {
            if case let .scroll(dx, dy, p) = $0, p == phase { return (dx, dy) } else { return nil }
        }
    }
    var zooms: [(Double, ZoomPhase)] {
        intents.compactMap { if case let .zoom(f, p) = $0 { return (f, p) } else { return nil } }
    }
}
