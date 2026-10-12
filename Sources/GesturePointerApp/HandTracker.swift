#if canImport(AppKit)
import AVFoundation
import CoreMedia
import Foundation
import GestureCore
import QuartzCore
import Vision

/// Runs Vision's hand pose request on camera frames and converts results to `TrackingFrame`s.
///
/// Must be called on one serial queue (the camera's frame queue). The request object is reused
/// across frames; a new `VNImageRequestHandler` per frame is the documented pattern for
/// independent still images, which is what each camera frame is to the hand pose model.
final class HandTracker {
    struct Stats {
        var fps: Double = 0
        var visionMilliseconds: Double = 0
        var handsInLastFrame = 0
    }

    private let request: VNDetectHumanHandPoseRequest
    private var busy = false
    private var lastProcessed: Double = 0
    private var lastFrameTime: Double?
    private(set) var stats = Stats()

    /// Observations below this confidence are discarded (ghost hands in clutter).
    var minimumObservationConfidence: Float = 0.35
    /// When > 0, frames arriving sooner than this after the last processed one are skipped.
    /// Used in standby to watch for the engage palms at a few fps for near-zero CPU.
    var minimumInterval: Double = 0

    init() {
        request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
    }

    static let jointOrder: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    /// Returns nil when the frame was skipped (busy or throttled); otherwise a frame with zero,
    /// one or two hands. `timestamp` is host time in seconds (CACurrentMediaTime).
    func process(_ sampleBuffer: CMSampleBuffer, timestamp: Double) -> TrackingFrame? {
        guard !busy else { return nil }
        if minimumInterval > 0 && timestamp - lastProcessed < minimumInterval { return nil }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        busy = true
        defer { busy = false }
        lastProcessed = timestamp

        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let height = Double(CVPixelBufferGetHeight(pixelBuffer))
        let aspect = height > 0 ? width / height : 16.0 / 9.0

        let started = CACurrentMediaTime()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        var hands: [GestureCore.HandFrame] = []
        do {
            try handler.perform([request])
            for observation in request.results ?? [] where observation.confidence >= minimumObservationConfidence {
                if let hand = Self.convert(observation, timestamp: timestamp, aspect: aspect) {
                    hands.append(hand)
                }
            }
        } catch {
            // A failed request is treated as "no hands this frame"; the state machine bridges
            // short gaps, so one bad frame never disturbs a gesture.
            hands = []
        }
        updateStats(visionSeconds: CACurrentMediaTime() - started, hands: hands.count, at: timestamp)
        return TrackingFrame(timestamp: timestamp, hands: hands)
    }

    private func updateStats(visionSeconds: Double, hands: Int, at time: Double) {
        if let last = lastFrameTime, time > last {
            let instant = 1 / (time - last)
            stats.fps = stats.fps == 0 ? instant : stats.fps * 0.9 + instant * 0.1
        }
        lastFrameTime = time
        let ms = visionSeconds * 1000
        stats.visionMilliseconds = stats.visionMilliseconds == 0 ? ms : stats.visionMilliseconds * 0.9 + ms * 0.1
        stats.handsInLastFrame = hands
    }

    /// Vision → HandFrame: flip y to a top-left origin and fill any joint Vision omitted.
    static func convert(_ observation: VNHumanHandPoseObservation, timestamp: Double, aspect: Double) -> HandFrame? {
        guard let recognized = try? observation.recognizedPoints(.all) else { return nil }
        var points = [Point2?](repeating: nil, count: GestureCore.Joint.count)
        var confidences = [Double](repeating: 0, count: GestureCore.Joint.count)
        for (index, name) in jointOrder.enumerated() {
            if let point = recognized[name], point.confidence > 0.1 {
                points[index] = Point2(Double(point.location.x), 1 - Double(point.location.y))
                confidences[index] = Double(point.confidence)
            }
        }
        // Without these the hand cannot drive anything reliably.
        let essential: [GestureCore.Joint] = [.wrist, .thumbTip, .indexMCP, .indexTip, .middleMCP]
        guard essential.allSatisfy({ points[$0.rawValue] != nil }) else { return nil }

        // Fill gaps from the nearest known joint on the same finger chain (toward the wrist),
        // so geometry stays plausible; confidence 0 marks them as estimated.
        // Chains are wrist(0), then four joints per digit starting at 1, 5, 9, 13, 17.
        for index in 1..<GestureCore.Joint.count where points[index] == nil {
            let chainStart = ((index - 1) / 4) * 4 + 1
            let previous = index == chainStart ? GestureCore.Joint.wrist.rawValue : index - 1
            points[index] = points[previous] ?? points[GestureCore.Joint.wrist.rawValue]
        }
        let chirality: GestureCore.Chirality
        switch observation.chirality {
        case .left: chirality = .left
        case .right: chirality = .right
        default: chirality = .unknown
        }
        return HandFrame(points: points.map { $0 ?? .zero }, jointConfidences: confidences,
                         chirality: chirality, confidence: Double(observation.confidence),
                         timestamp: timestamp, imageAspect: aspect)
    }
}
#endif
