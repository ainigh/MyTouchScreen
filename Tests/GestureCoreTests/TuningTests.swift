import XCTest
@testable import GestureCore

final class TuningTests: XCTestCase {
    func testScriptFollowsTheProtocol() {
        let script = TuningScript()
        XCTAssertEqual(script.steps.count, GestureLabel.scripted.count * 8)
        XCTAssertEqual(script.steps.first?.label, .click)
        XCTAssertEqual(script.steps.last?.label, .outOfFrame)
        // Prompt, 1 s wait, record, 1 s gap.
        let first = script.steps[0], second = script.steps[1]
        XCTAssertEqual(first.recordStart - first.promptAt, 1, accuracy: 1e-9)
        XCTAssertEqual(second.promptAt - first.recordEnd, 1, accuracy: 1e-9)
        XCTAssertEqual(script.steps.first { $0.label == .rest }?.recordEnd ?? 0,
                       (script.steps.first { $0.label == .rest }?.recordStart ?? 0) + 5, accuracy: 1e-9)
        XCTAssertEqual(script.phase(at: 0.5), .prompt(first))
        XCTAssertEqual(script.phase(at: 1.5), .recording(first, remaining: first.recordEnd - 1.5))
        XCTAssertEqual(script.phase(at: first.recordEnd + 0.5), .pause(next: second))
        XCTAssertEqual(script.phase(at: script.duration + 1), .finished)
        let partial = script.segments(startingAt: 100, completedBy: second.recordEnd)
        XCTAssertEqual(partial.count, 2)
        XCTAssertEqual(partial[0], LabeledSegment(label: "click", startTime: 101, endTime: 101 + first.recordEnd - 1))
    }

    func testWriterStoresLabeledSegments() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.json")
        let sample = VelocitySynthetic.sample(.click, fps: 30, seed: 4)
        let writer = try RecordingWriter(url: url, info: ["script": "1"])
        for frame in sample.frames { writer.append(frame) }
        writer.close(segments: [sample.segment])
        let loaded = try Recording.load(from: url)
        XCTAssertEqual(loaded.frames.count, sample.frames.count)
        XCTAssertEqual(loaded.segments, [sample.segment])
        // An old-style recording without segments still loads.
        XCTAssertNil(try Recording.decode(Recording(frames: sample.frames).encoded()).segments)
    }

    func testSyntheticSessionScoresWell() {
        let session = VelocitySynthetic.session(repetitions: 4, fps: 30, seed: 9)
        let score = Evaluation.score(Evaluation.evaluate(session, config: .velocityMode))
        XCTAssertEqual(score.total, GestureLabel.scripted.count * 4)
        XCTAssertGreaterThanOrEqual(score.f1, 0.9)
    }

    /// Owner recordings committed under `recordings/` (SPEC-M7 step 4) must keep scoring well.
    func testCommittedRecordings() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("recordings")
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let sessions = files.filter { $0.pathExtension == "json" }
        for file in sessions {
            let recording = try Recording.load(from: file)
            guard recording.segments?.isEmpty == false else { continue }
            let score = Evaluation.score(Evaluation.evaluate(recording, config: .velocityMode))
            XCTAssertGreaterThanOrEqual(score.f1, 0.9, "\(file.lastPathComponent): F1 \(score.f1)")
        }
    }
}
