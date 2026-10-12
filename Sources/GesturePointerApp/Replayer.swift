#if canImport(AppKit)
import Foundation
import GestureCore
import QuartzCore

/// `--replay`: feeds a recorded landmark stream into the pipeline with its original timing,
/// in place of the camera. Timestamps are shifted onto the live clock so momentum ticks and
/// timeouts behave exactly as they did when recorded.
final class Replayer {
    private let queue = DispatchQueue(label: "app.wisp.replay", qos: .userInteractive)

    /// `completion` runs on the main queue with the number of frames played.
    func play(_ recording: Recording, into pipeline: GesturePipeline, completion: @escaping (Int) -> Void) {
        let rebased = recording.rebased(to: CACurrentMediaTime() + 0.3)
        queue.async {
            for frame in rebased.frames {
                let wait = frame.timestamp - CACurrentMediaTime()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                pipeline.submit(frame)
            }
            // Give momentum and timeouts a moment to finish before reporting.
            Thread.sleep(forTimeInterval: 1.0)
            DispatchQueue.main.async { completion(rebased.frames.count) }
        }
    }
}
#endif
