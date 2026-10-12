import Foundation
import GestureCore

// gesture-replay: run a recorded (or synthetic) landmark stream through GestureCore on any
// platform and print what the app would have done. This is how gesture bugs recorded on a Mac
// with `--record` get reproduced and fixed on Linux.

let usage = """
Usage:
  gesture-replay <recording.json> [--config settings.json] [--display WxH] [--moves] [--disengaged]
      Replay a recording through the pointer state machine (engaged from the first frame unless
      --disengaged) and print every intent and event with its time. --moves includes cursor moves.
  gesture-replay --synthetic <scenario> <out.json>
      Write a synthetic recording. Scenarios: \(Scenario.allCases.map(\.rawValue).joined(separator: ", "))

"""

enum Scenario: String, CaseIterable {
    case steady, jitter, ramp, taps, doubletap, drag, rightclick, scroll, palm, lost, zoom, demo

    var frames: [TrackingFrame] {
        switch self {
        case .steady: return SyntheticStream.steady(duration: 3)
        case .jitter: return SyntheticStream.steady(duration: 5, noise: 0.0015)
        case .ramp: return SyntheticStream.ramp(from: Point2(0.65, 0.45), to: Point2(0.35, 0.45), duration: 0.6)
        case .taps: return SyntheticStream.pinchTaps(at: [0.6, 1.4, 2.2])
        case .doubletap: return SyntheticStream.pinchTaps(at: [0.6, 0.85])
        case .drag: return SyntheticStream.drag()
        case .rightclick: return SyntheticStream.pinchTaps(at: [0.6], finger: .middle)
        case .scroll: return SyntheticStream.fistScroll()
        case .palm: return SyntheticStream.palmHold(hold: 1.0)
        case .lost: return SyntheticStream.handLost()
        case .zoom: return SyntheticStream.twoHandZoom()
        case .demo:
            // A little of everything, back to back.
            var all: [TrackingFrame] = []
            var offset = 0.0
            for part in [Scenario.ramp, .taps, .doubletap, .drag, .rightclick, .scroll, .zoom] {
                let frames = part.frames
                all += frames.map { frame in
                    var f = frame
                    f.timestamp += offset
                    for i in f.hands.indices { f.hands[i].timestamp = f.timestamp }
                    return f
                }
                offset += (frames.last?.timestamp ?? 0) + 0.5
            }
            return all
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n\n\(usage)".utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(arguments.isEmpty ? 2 : 0)
}

if arguments.first == "--synthetic" {
    guard arguments.count == 3, let scenario = Scenario(rawValue: arguments[1]) else {
        fail("--synthetic needs a scenario name and an output path")
    }
    let recording = Recording(frames: scenario.frames, info: ["source": "synthetic:\(scenario.rawValue)"])
    do {
        try recording.write(to: URL(fileURLWithPath: arguments[2]))
        print("Wrote \(recording.frames.count) frames (\(String(format: "%.1f", recording.duration)) s) to \(arguments[2])")
        exit(0)
    } catch {
        fail("can't write \(arguments[2]): \(error.localizedDescription)")
    }
}

var config = GestureConfig()
var display = DisplayInfo(id: "main", frame: Rect(x: 0, y: 0, width: 1728, height: 1117))
var showMoves = false
var startEngaged = true
var path: String?

var iterator = arguments.makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--config":
        guard let file = iterator.next() else { fail("--config needs a file") }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: file))
            // Accept either a bare GestureConfig or a Wisp settings export.
            if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let inner = root["config"] {
                config = try GestureConfig.decodeLenient(JSONSerialization.data(withJSONObject: inner))
            } else {
                config = try GestureConfig.decodeLenient(data)
            }
        } catch {
            fail("can't read config \(file): \(error.localizedDescription)")
        }
    case "--display":
        guard let value = iterator.next() else { fail("--display needs WxH") }
        let parts = value.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { fail("--display needs WxH, e.g. 1728x1117") }
        display = DisplayInfo(id: "main", frame: Rect(x: 0, y: 0, width: parts[0], height: parts[1]))
    case "--moves":
        showMoves = true
    case "--disengaged":
        startEngaged = false
    default:
        if argument.hasPrefix("--") { fail("unknown option \(argument)") }
        path = argument
    }
}

guard let path else { fail("no recording given") }
let recording: Recording
do {
    recording = try Recording.load(from: URL(fileURLWithPath: path)).rebased()
} catch {
    fail("can't read \(path): \(error.localizedDescription)")
}

let machine = PointerStateMachine(config: config, displays: [display])
var counts: [String: Int] = [:]
func report(_ out: StepOutput, at time: Double) {
    for intent in out.intents {
        let name = String(describing: intent).components(separatedBy: "(").first ?? "intent"
        counts[name, default: 0] += 1
        if case .move = intent, !showMoves { continue }
        print(String(format: "%8.3f  intent  ", time) + String(describing: intent))
    }
    for event in out.events {
        print(String(format: "%8.3f  event   ", time) + String(describing: event))
    }
}

if startEngaged { report(machine.setEngaged(true, at: 0), at: 0) }
var lastTick = 0.0
for frame in recording.frames {
    while lastTick + 1.0 / 120 < frame.timestamp {
        lastTick += 1.0 / 120
        report(machine.tick(at: lastTick), at: lastTick)
    }
    report(machine.process(frame), at: frame.timestamp)
}
let end = (recording.frames.last?.timestamp ?? 0)
while lastTick < end + 2 {
    lastTick += 1.0 / 120
    report(machine.tick(at: lastTick), at: lastTick)
}

print("\n\(recording.frames.count) frames, \(String(format: "%.1f", recording.duration)) s. Totals:")
for (name, count) in counts.sorted(by: { $0.key < $1.key }) {
    print("  \(name): \(count)")
}
