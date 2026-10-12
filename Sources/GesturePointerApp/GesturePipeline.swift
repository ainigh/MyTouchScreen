#if canImport(AppKit)
import CoreGraphics
import Foundation
import GestureCore
import QuartzCore

/// Owns the PointerStateMachine and runs it on one serial queue, between the hand tracker and
/// InputSynth. Every input to the machine (frames, ticks, hotkey, settings) is funnelled through
/// `queue`, so the machine is never touched concurrently and never touched from the main thread.
///
/// UI updates are coalesced: however many frames arrive, at most one snapshot hop to the main
/// queue is pending at a time, so a busy main thread can never back up the pipeline.
final class GesturePipeline {
    let queue = DispatchQueue(label: "app.wisp.pipeline", qos: .userInteractive)
    let synth: InputSynth

    private let machine: PointerStateMachine
    private var recorder: RecordingWriter?
    private var tickTimer: DispatchSourceTimer?
    private var frameTap: ((TrackingFrame) -> Void)?

    /// Print one line per frame (`--no-overlay` headless mode). Pipeline queue only.
    private var printsFrames = false
    private var printedFrames = 0
    private var lastPrintTime: Double = 0
    private var printFPS: Double = 0

    /// Delivered on the main queue.
    var onUpdate: ((PointerSnapshot, [PointerEvent]) -> Void)?

    private let uiLock = NSLock()
    private var pendingSnapshot: PointerSnapshot?
    private var pendingEvents: [PointerEvent] = []
    private var uiFlushScheduled = false

    init(config: GestureConfig, displays: [DisplayInfo], calibration: CalibrationSet, synth: InputSynth) {
        self.synth = synth
        self.machine = PointerStateMachine(config: config, displays: displays, calibration: calibration)
    }

    // MARK: Inputs (any thread)

    /// Output options from the command line, applied on the pipeline queue like everything else.
    func configureOutput(postsEvents: Bool, logsIntents: Bool, printsFrames: Bool) {
        queue.async {
            self.synth.postsEvents = postsEvents
            self.synth.log = logsIntents ? { print("intent: \($0)") } : nil
            self.printsFrames = printsFrames
        }
    }

    func submit(_ frame: TrackingFrame) {
        queue.async { self.handle(frame) }
    }

    func setEngaged(_ engaged: Bool, reason: DisengageReason) {
        let mouse = Displays.mouseLocation()
        queue.async {
            let out = self.machine.setEngaged(engaged, reason: reason, at: CACurrentMediaTime(),
                                              mouseLocation: Point2(mouse.x, mouse.y))
            self.perform(out)
            if !engaged { self.synth.releaseAll() }
            self.updateTicking()
        }
    }

    /// Flip engagement based on the machine's own state (the main thread's copy may lag).
    func toggleEngaged(reason: DisengageReason) {
        let mouse = Displays.mouseLocation()
        queue.async {
            let engage = !self.machine.isEngaged
            let out = self.machine.setEngaged(engage, reason: reason, at: CACurrentMediaTime(),
                                              mouseLocation: Point2(mouse.x, mouse.y))
            self.perform(out)
            if !engage { self.synth.releaseAll() }
            self.updateTicking()
        }
    }

    func noteExternalMouse(at location: CGPoint) {
        queue.async {
            self.perform(self.machine.noteExternalMouse(at: Point2(location.x, location.y), time: CACurrentMediaTime()))
        }
    }

    func update(config: GestureConfig, zoomStyle: ZoomStyle) {
        queue.async {
            self.machine.updateConfig(config)
            self.synth.zoomStyle = zoomStyle
        }
    }

    func update(displays: [DisplayInfo]) {
        queue.async { self.machine.setDisplays(displays) }
    }

    func update(calibration: CalibrationSet) {
        queue.async { self.machine.setCalibration(calibration) }
    }

    /// While set, frames go to `tap` (calibration) instead of the state machine.
    func setFrameTap(_ tap: ((TrackingFrame) -> Void)?) {
        queue.async { self.frameTap = tap }
    }

    func startRecording(to url: URL, info: [String: String]) throws {
        let writer = try RecordingWriter(url: url, info: info)
        queue.async {
            self.recorder?.close()
            self.recorder = writer
        }
    }

    /// Stops recording; `completion` runs on the main queue with the number of frames written.
    func stopRecording(completion: ((Int) -> Void)? = nil) {
        queue.async {
            let count = self.recorder?.framesWritten ?? 0
            self.recorder?.close()
            self.recorder = nil
            if let completion { DispatchQueue.main.async { completion(count) } }
        }
    }

    /// Release held buttons/modifiers and close the recording. Blocks until done (quit path).
    func shutdown() {
        queue.sync {
            self.synth.releaseAll()
            self.recorder?.close()
            self.recorder = nil
            self.tickTimer?.cancel()
            self.tickTimer = nil
        }
    }

    // MARK: Queue-confined work

    private func handle(_ frame: TrackingFrame) {
        recorder?.append(frame)
        if printsFrames { printLine(for: frame) }
        if let frameTap {
            frameTap(frame)
            var snapshot = machine.snapshot
            snapshot.hands = frame.hands
            publish(snapshot, [])
            return
        }
        perform(machine.process(frame))
        updateTicking()
    }

    private func perform(_ out: StepOutput) {
        for intent in out.intents { synth.perform(intent) }
        publish(machine.snapshot, out.events)
    }

    /// 120 Hz ticks only while engaged: they drive scroll momentum between camera frames.
    private func updateTicking() {
        if machine.isEngaged && tickTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let out = self.machine.tick(at: CACurrentMediaTime())
                if !out.intents.isEmpty { self.perform(out) }
            }
            timer.resume()
            tickTimer = timer
        } else if !machine.isEngaged, let timer = tickTimer {
            timer.cancel()
            tickTimer = nil
        }
    }

    private func printLine(for frame: TrackingFrame) {
        printedFrames += 1
        if lastPrintTime > 0, frame.timestamp > lastPrintTime {
            let instant = 1 / (frame.timestamp - lastPrintTime)
            printFPS = printFPS == 0 ? instant : printFPS * 0.9 + instant * 0.1
        }
        lastPrintTime = frame.timestamp
        let hands = frame.hands.map { "\($0.chirality.rawValue)(\(String(format: "%.2f", $0.confidence)))" }
        let landmarks = frame.hands.count * Joint.count
        let state = machine.snapshot.state.rawValue
        print(String(format: "frame %6d  t=%10.3f  fps=%5.1f  hands=%d  landmarks=%2d  state=%@  %@",
                     printedFrames, frame.timestamp, printFPS, frame.hands.count, landmarks,
                     state, hands.joined(separator: " ")))
    }

    private func publish(_ snapshot: PointerSnapshot, _ events: [PointerEvent]) {
        uiLock.lock()
        pendingSnapshot = snapshot
        pendingEvents += events
        let needsFlush = !uiFlushScheduled
        uiFlushScheduled = true
        uiLock.unlock()
        if needsFlush {
            DispatchQueue.main.async { [weak self] in self?.flushUI() }
        }
    }

    private func flushUI() {
        uiLock.lock()
        let snapshot = pendingSnapshot
        let events = pendingEvents
        pendingEvents = []
        uiFlushScheduled = false
        uiLock.unlock()
        if let snapshot { onUpdate?(snapshot, events) }
    }
}
#endif
