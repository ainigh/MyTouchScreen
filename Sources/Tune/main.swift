import Foundation
import GestureCore

// tune: replay a labeled recording (from `GesturePointer --record session.json --script`)
// through Velocity mode, show how each prompt was classified, and grid-search the key
// thresholds for the best F1. Foundation only, so it runs on Linux as well as macOS.

let usage = """
Usage:
  swift run -c release tune <session.json> [--config settings.json] [--no-grid]
      Confusion matrix (labels × what Wisp did), per-class precision/recall, the T / |d| / L /
      vpeak distribution for each label, then a coarse grid search over the key thresholds.
  swift run tune --synthetic <out.json> [--fps 30|60] [--seed N]
      Write a synthetic labeled session (every prompt 8 times) to try the tool on.

"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n\n\(usage)".utf8))
    exit(2)
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func padLeft(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(arguments.isEmpty ? 2 : 0)
}

// MARK: Synthetic session

if arguments.first == "--synthetic" {
    guard arguments.count >= 2 else { fail("--synthetic needs an output path") }
    var fps = 60.0
    var seed: UInt64 = 1
    var rest = arguments.dropFirst(2).makeIterator()
    while let option = rest.next() {
        switch option {
        case "--fps":
            guard let v = rest.next().flatMap(Double.init), v >= 10 else { fail("--fps needs a number") }
            fps = v
        case "--seed":
            guard let v = rest.next().flatMap(UInt64.init) else { fail("--seed needs a number") }
            seed = v
        default:
            fail("unknown option \(option)")
        }
    }
    let recording = VelocitySynthetic.session(fps: fps, seed: seed)
    do {
        try recording.write(to: URL(fileURLWithPath: arguments[1]))
        print("Wrote \(recording.frames.count) frames, \(recording.segments?.count ?? 0) labeled segments to \(arguments[1])")
        exit(0)
    } catch {
        fail("can't write \(arguments[1]): \(error.localizedDescription)")
    }
}

// MARK: Options

var config = GestureConfig()
var path: String?
var runGrid = true
var iterator = arguments.makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--config":
        guard let file = iterator.next() else { fail("--config needs a file") }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: file))
            if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let inner = root["config"] {
                config = try GestureConfig.decodeLenient(JSONSerialization.data(withJSONObject: inner))
            } else {
                config = try GestureConfig.decodeLenient(data)
            }
        } catch {
            fail("can't read config \(file): \(error.localizedDescription)")
        }
    case "--no-grid":
        runGrid = false
    default:
        if argument.hasPrefix("--") { fail("unknown option \(argument)") }
        path = argument
    }
}
config.inputModel = .velocity

guard let path else { fail("no recording given") }
let recording: Recording
do {
    recording = try Recording.load(from: URL(fileURLWithPath: path))
} catch {
    fail("can't read \(path): \(error.localizedDescription)")
}
guard let segments = recording.segments, !segments.isEmpty else {
    fail("\(path) has no labeled segments. Record one with: GesturePointer --record session.json --script")
}
print(String(format: "%@: %d frames, %.0f s, %d labeled segments", path, recording.frames.count,
             recording.duration, segments.count))

// MARK: Confusion matrix

let results = Evaluation.evaluate(recording, config: config)
let labels = GestureLabel.allCases.filter { label in results.contains { $0.label == label.rawValue } }
let unknownLabels = Set(results.map(\.label)).subtracting(GestureLabel.allCases.map(\.rawValue))
if !unknownLabels.isEmpty { print("Ignoring unknown labels: \(unknownLabels.sorted().joined(separator: ", "))") }
let outcomes = GestureOutcome.allCases

print("\nConfusion matrix (rows: what you were asked to do; columns: what Wisp did)\n")
let labelWidth = 16
let cell = 7
var header = pad("", labelWidth)
for outcome in outcomes { header += padLeft(String(outcome.rawValue.prefix(cell - 1)), cell) }
print(header)
for label in labels {
    var row = pad(label.rawValue, labelWidth)
    let mine = results.filter { $0.label == label.rawValue }
    for outcome in outcomes {
        let n = mine.filter { $0.outcome == outcome }.count
        let mark = outcome == label.expected ? "*" : " "
        row += padLeft(n == 0 ? "." : "\(n)\(mark)", cell)
    }
    print(row)
}
print("(* = the expected result)")

print("\nPer class\n")
print(pad("", labelWidth) + padLeft("precision", 11) + padLeft("recall", 9) + padLeft("n", 5))
for outcome in outcomes where outcome != .none {
    let actual = results.filter { GestureLabel(rawValue: $0.label)?.expected == outcome }
    let predicted = results.filter { $0.outcome == outcome }
    guard !actual.isEmpty || !predicted.isEmpty else { continue }
    let tp = actual.filter { $0.outcome == outcome }.count
    let precision = predicted.isEmpty ? "-" : String(format: "%.2f", Double(tp) / Double(predicted.count))
    let recall = actual.isEmpty ? "-" : String(format: "%.2f", Double(tp) / Double(actual.count))
    print(pad(outcome.rawValue, labelWidth) + padLeft(precision, 11) + padLeft(recall, 9) + padLeft("\(actual.count)", 5))
}
let falseAlarms = results.filter { GestureLabel(rawValue: $0.label)?.expected == GestureOutcome.none && $0.outcome != .none }
print("\nFalse alarms on prompts that should do nothing: \(falseAlarms.count) of " +
      "\(results.filter { GestureLabel(rawValue: $0.label)?.expected == GestureOutcome.none }.count)")

// MARK: Distributions

func summary(_ values: [Double]) -> String {
    guard !values.isEmpty else { return padLeft("-", 23) }
    let sorted = values.sorted()
    func q(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(p * Double(sorted.count - 1) + 0.5))] }
    return padLeft(String(format: "%.2f / %.2f / %.2f", sorted[0], q(0.5), sorted[sorted.count - 1]), 23)
}

print("\nSegment measurements per label (min / median / max; displacements in hand sizes)\n")
print(pad("", labelWidth) + padLeft("segs", 5) + padLeft("T (s)", 23) + padLeft("|d|", 23) + padLeft("L", 23) + padLeft("vpeak (/s)", 23))
for label in labels {
    let stats = results.filter { $0.label == label.rawValue }.flatMap(\.reports).compactMap(\.stats)
    print(pad(label.rawValue, labelWidth) + padLeft("\(stats.count)", 5)
          + summary(stats.map(\.duration)) + summary(stats.map(\.distance))
          + summary(stats.map(\.pathLength)) + summary(stats.map(\.peakSpeed)))
}

let baseline = Evaluation.score(results)
print(String(format: "\nCurrent settings: F1 %.3f (precision %.3f, recall %.3f), %d/%d prompts right",
             baseline.f1, baseline.precision, baseline.recall, baseline.correct, baseline.total))

// MARK: Grid search

guard runGrid else { exit(0) }

struct Axis {
    let name: String
    let values: [Double]
    let current: (VelocityParams) -> Double
    let apply: (inout VelocityParams, Double) -> Void
}

let axes = [
    Axis(name: "vEnter", values: [0.7, 0.9, 1.1], current: \.vEnter) { $0.vEnter = $1; $0.vExit = $1 * 0.5 },
    Axis(name: "clickMaxDuration", values: [0.14, 0.18, 0.22], current: \.clickMaxDuration) { $0.clickMaxDuration = $1 },
    Axis(name: "clickMaxDisp", values: [0.7, 0.9, 1.1], current: \.clickMaxDisp) { $0.clickMaxDisp = $1 },
    Axis(name: "scrollMinDisp", values: [1.2, 1.6, 2.0], current: \.scrollMinDisp) { $0.scrollMinDisp = $1 },
    Axis(name: "scrollMinPeak", values: [1.4, 1.8, 2.2], current: \.scrollMinPeak) { $0.scrollMinPeak = $1 },
]
// Ties are broken toward the current settings, so a flat optimum doesn't move anything.
let currentIndices = axes.map { axis -> Int in
    let value = axis.current(config.velocity)
    return axis.values.indices.min { abs(axis.values[$0] - value) < abs(axis.values[$1] - value) } ?? 0
}
func distanceFromCurrent(_ indices: [Int]) -> Int {
    zip(indices, currentIndices).reduce(0) { $0 + abs($1.0 - $1.1) }
}
let combinations = axes.reduce(1) { $0 * $1.values.count }
print("\nGrid search over \(axes.map(\.name).joined(separator: ", ")) (\(combinations) runs; vExit follows vEnter × 0.5)…")

var best: (score: Evaluation.Score, indices: [Int])?
var indices = Array(repeating: 0, count: axes.count)
let started = Date()
for run in 0..<combinations {
    var remainder = run
    for a in axes.indices.reversed() {
        indices[a] = remainder % axes[a].values.count
        remainder /= axes[a].values.count
    }
    var candidate = config
    for (a, axis) in axes.enumerated() { axis.apply(&candidate.velocity, axis.values[indices[a]]) }
    let score = Evaluation.score(Evaluation.evaluate(recording, config: candidate))
    if let current = best {
        let better = score.f1 > current.score.f1 + 1e-9
        let tie = abs(score.f1 - current.score.f1) <= 1e-9
        if better || (tie && (score.correct > current.score.correct
            || (score.correct == current.score.correct && distanceFromCurrent(indices) < distanceFromCurrent(current.indices)))) {
            best = (score, indices)
        }
    } else {
        best = (score, indices)
    }
    if run % 27 == 26 {
        FileHandle.standardError.write(Data(String(format: "  %d/%d (%.0f s)\r", run + 1, combinations,
                                                    Date().timeIntervalSince(started)).utf8))
    }
}
FileHandle.standardError.write(Data("\n".utf8))

if let best {
    print(String(format: "\nBest: F1 %.3f (precision %.3f, recall %.3f), %d/%d prompts right",
                 best.score.f1, best.score.precision, best.score.recall, best.score.correct, best.score.total))
    var atEdge: [String] = []
    for (a, axis) in axes.enumerated() {
        let i = best.indices[a]
        print("  \(pad(axis.name, 18)) \(axis.values[i])")
        if (i == 0 || i == axis.values.count - 1) && i != currentIndices[a] { atEdge.append(axis.name) }
    }
    if !atEdge.isEmpty {
        print("\nWarning: \(atEdge.joined(separator: ", ")) ended at the edge of the grid; the best value may lie " +
              "beyond it. Widen that axis in Sources/Tune/main.swift and run again.")
    }
    if best.score.f1 <= baseline.f1 + 1e-9 {
        print("\nThe current settings are already as good as anything in the grid.")
    }
}
