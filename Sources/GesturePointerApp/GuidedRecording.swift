#if canImport(AppKit)
import AppKit
import GestureCore
import QuartzCore

/// Runs the guided tuning session (`--record session.json --script`): follows GestureCore's
/// `TuningScript` timetable on a 10 Hz main-thread timer and reports each phase for the
/// overlay. Times are `CACurrentMediaTime()`, the same clock as the frame timestamps, so the
/// labeled segments line up with the recorded frames.
@MainActor
final class GuidedRecording {
    let script = TuningScript()
    private var timer: Timer?
    private var startTime: Double = 0
    private var lastPhase: TuningScript.Phase?

    /// Every phase change and every tick while recording (for the countdown).
    var onPhase: ((TuningScript.Phase) -> Void)?
    /// Called once, with the labeled segments, when the last prompt has been recorded.
    var onFinish: (([LabeledSegment]) -> Void)?

    /// True once `start()` ran (the app starts the clock on the first frame with a hand, so
    /// camera warm-up never eats into the first prompt).
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startTime = CACurrentMediaTime()
        // Common modes: prompts keep updating while the menu-bar menu is open.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Stop early; returns the segments recorded so far.
    func stop() -> [LabeledSegment] {
        timer?.invalidate()
        timer = nil
        guard isRunning else { return [] }
        return script.segments(startingAt: startTime, completedBy: CACurrentMediaTime() - startTime)
    }

    private func tick() {
        let phase = script.phase(at: CACurrentMediaTime() - startTime)
        let isRecording: Bool
        if case .recording = phase { isRecording = true } else { isRecording = false }
        if phase != lastPhase || isRecording {
            lastPhase = phase
            onPhase?(phase)
        }
        if phase == .finished {
            onFinish?(stop())
            onFinish = nil
        }
    }
}
#endif
