import XCTest
@testable import GestureCore

final class ReplayTests: XCTestCase {
    func testRoundTripPreservesFramesToRecordedPrecision() throws {
        var frames = SyntheticStream.twoFists()
        frames += SyntheticStream.handLost(duration: 0.3).map { TrackingFrame(timestamp: $0.timestamp + 5, hands: $0.hands) }
        let recording = Recording(frames: frames, info: ["camera": "Synthetic"])
        let decoded = try Recording.decode(recording.encoded())
        XCTAssertEqual(decoded.frames.count, frames.count)
        XCTAssertEqual(decoded.info["camera"], "Synthetic")
        for (a, b) in zip(frames, decoded.frames) {
            XCTAssertEqual(a.timestamp, b.timestamp, accuracy: 1e-4)
            XCTAssertEqual(a.hands.count, b.hands.count)
            for (ha, hb) in zip(a.hands, b.hands) {
                XCTAssertEqual(ha.chirality, hb.chirality)
                for (pa, pb) in zip(ha.points, hb.points) {
                    XCTAssertEqual(pa.distance(to: pb), 0, accuracy: 1e-5)
                }
            }
        }
        // Encoding the decoded recording is stable (idempotent).
        XCTAssertEqual(try decoded.encoded(), try Recording.decode(decoded.encoded()).encoded())
    }

    func testReplayProducesSameIntentsAsLive() throws {
        let frames = SyntheticStream.wiggleClick() + SyntheticStream.fistDrag().map {
            TrackingFrame(timestamp: $0.timestamp + 4.5, hands: $0.hands.map { hand in
                var moved = hand
                moved.timestamp += 4.5
                return moved
            })
        }
        let live = drive(engagedMachine(), frames)
        let replayed = drive(engagedMachine(), try Recording.decode(Recording(frames: frames).encoded()).frames)
        XCTAssertEqual(live.clicks.map { $0.2 }, replayed.clicks.map { $0.2 })
        XCTAssertEqual(live.intents.count, replayed.intents.count)
    }

    func testStreamingWriterAndTruncatedFileRecovery() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.json")
        let frames = SyntheticStream.steady(duration: 1)
        let writer = try RecordingWriter(url: url, info: ["fps": "30"])
        frames.forEach(writer.append)
        writer.close()
        let loaded = try Recording.load(from: url)
        XCTAssertEqual(loaded.frames.count, frames.count)
        XCTAssertEqual(loaded.info["fps"], "30")

        // Simulate a crash: cut the file in the middle of the last frame.
        var data = try Data(contentsOf: url)
        data.removeLast(200)
        let repaired = try Recording.decode(data)
        XCTAssertEqual(repaired.frames.count, frames.count - 1)
    }

    func testRebase() {
        let recording = Recording(frames: SyntheticStream.steady(duration: 0.5).map {
            TrackingFrame(timestamp: $0.timestamp + 1000, hands: $0.hands)
        })
        let rebased = recording.rebased()
        XCTAssertEqual(rebased.frames.first?.timestamp, 0)
        XCTAssertEqual(rebased.duration, recording.duration, accuracy: 1e-9)
    }

    func testRejectsMalformedHand() {
        let json = #"{"format":"gesturepointer-replay","version":1,"info":{},"frames":[{"t":0,"h":[{"c":"left","s":1,"p":[[0,0,1]]}]}]}"#
        XCTAssertThrowsError(try Recording.decode(Data(json.utf8)))
    }
}

final class ConfigTests: XCTestCase {
    func testLenientDecodeKeepsDefaultsForMissingKeys() throws {
        // Old settings files carry keys of retired models (inputModel, pinchEnter, velocity…).
        // Precision mode, the freeze and the hand-lost timeout are retired too.
        let json = #"{"inputModel": "pose", "pinchEnter": 0.3, "scrollSpeed": 2.5, "precisionEnabled": true, "handLostTimeout": 2, "shake": {"lockTime": 1.5, "freezeSpeed": 3.5, "minStroke": 0.4}, "velocity": {"vEnter": 1}}"#
        let config = try GestureConfig.decodeLenient(Data(json.utf8))
        XCTAssertEqual(config.scrollSpeed, 2.5)
        XCTAssertEqual(config.shake.minStroke, 0.4)
        XCTAssertEqual(config.shake.window, ShakeParams().window)
        XCTAssertEqual(config.palmThumbClearance, GestureConfig.default.palmThumbClearance)
    }

    func testSteadinessIsOneKnobForTheSmoothing() {
        var config = GestureConfig()
        XCTAssertEqual(config.steadiness, 0.5, accuracy: 1e-9, "the defaults are the middle of the slider")
        var middle = GestureConfig()
        middle.steadiness = 0.5
        XCTAssertEqual(middle.filter, config.filter)
        XCTAssertEqual(middle.restDeadZoneBox, config.restDeadZoneBox, accuracy: 1e-12)
        config.steadiness = 1
        XCTAssertEqual(config.steadiness, 1, accuracy: 1e-9)
        XCTAssertLessThan(config.filter.minCutoff, GestureConfig().filter.minCutoff)
        XCTAssertGreaterThan(config.restDeadZoneBox, GestureConfig().restDeadZoneBox)
        config.steadiness = 0
        XCTAssertEqual(config.steadiness, 0, accuracy: 1e-9)
        config.steadiness = .nan
        XCTAssertEqual(config.steadiness, 0.5, accuracy: 1e-9)
        // Reset brings back the defaults and leaves everything else alone.
        config.steadiness = 0.9
        config.boxScale = 0.7
        config.resetPointerTuning()
        XCTAssertEqual(config.filter, GestureConfig().filter)
        XCTAssertEqual(config.boxScale, 0.7)
    }

    func testRoundTrip() throws {
        var config = GestureConfig()
        config.filter.beta = 9
        config.preferredHand = .left
        let decoded = try GestureConfig.decodeLenient(JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
    }
}

final class MomentumTests: XCTestCase {
    func testDistanceIndependentOfTickRate() {
        func totalDistance(rate: Double) -> Double {
            var m = ScrollMomentum(friction: 4, minSpeed: 1)
            _ = m.start(velocity: Point2(0, 1000), at: 0)
            var total = 0.0
            var t = 0.0
            while t < 3 {
                t += 1 / rate
                for case let .scroll(_, dy, _) in m.tick(at: t) { total += dy }
            }
            return total
        }
        XCTAssertEqual(totalDistance(rate: 60), totalDistance(rate: 120), accuracy: 2)
        XCTAssertEqual(totalDistance(rate: 120), 1000.0 / 4, accuracy: 3) // v0 / k
    }

    func testStopEndsMomentum() {
        var m = ScrollMomentum(friction: 4, minSpeed: 1)
        _ = m.start(velocity: Point2(0, 1000), at: 0)
        XCTAssertEqual(m.stop(), [.scroll(dx: 0, dy: 0, phase: .momentumEnded)])
        XCTAssertTrue(m.tick(at: 1).isEmpty)
    }

    func testNonPositiveImageAspectIsRejected() {
        // Regression: aspect 0 decoded fine and turned every distance into NaN, which left a
        // pinch (and so a drag) unable to release.
        let points = (0..<21).map { _ in "[0.5,0.5,1]" }.joined(separator: ",")
        for aspect in ["0", "-1.7"] {
            let json = "{\"format\":\"gesturepointer-replay\",\"version\":1,\"info\":{},\"frames\":[{\"t\":0,\"h\":[{\"c\":\"right\",\"s\":1,\"a\":\(aspect),\"p\":[\(points)]}]}]}"
            XCTAssertThrowsError(try Recording.decode(Data(json.utf8)), "aspect \(aspect)")
        }
    }
}
