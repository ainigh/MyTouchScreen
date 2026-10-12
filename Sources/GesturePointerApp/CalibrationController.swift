#if canImport(AppKit)
import AppKit
import GestureCore
import QuartzCore

/// The 15-second calibration: point at each corner of the screen (highlighted in turn).
/// Produces a `CalibrationProfile` for one display. Esc skips at any point
/// and keeps whatever was there before (defaults if never calibrated).
@MainActor
final class CalibrationController {
    enum Outcome {
        case calibrated(CalibrationProfile)
        case cornersFailed(String)
        case skipped
    }

    private let window: KeyableWindow
    private let view: CalibrationView
    private var corners = CornerCalibrationSession()
    private var finished = false
    var onFinish: ((Outcome) -> Void)?

    init(screen: NSScreen) {
        window = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        view = CalibrationView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = view
        window.setFrame(screen.frame, display: false)
        view.onEscape = { [weak self] in self?.finish(.skipped) }
    }

    func begin() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate()
        view.showCorner(0, progress: 0)
    }

    /// Feed every tracking frame (main thread).
    func handle(_ frame: TrackingFrame) {
        guard !finished else { return }
        let hand = frame.hands.first
        switch corners.process(fingertip: hand?[.indexTip], at: frame.timestamp) {
        case let .collecting(corner, progress):
            view.showCorner(corner, progress: progress, handVisible: hand != nil)
        case .finished(let profile):
            finish(.calibrated(profile))
        case .failed(let reason):
            finish(.cornersFailed(reason))
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        switch outcome {
        case .calibrated: view.showMessage("All set", detail: "Calibration saved for this display.")
        case .cornersFailed(let reason): view.showMessage("Using the default area", detail: reason)
        case .skipped: view.showMessage("Skipped", detail: "Using the default area. Calibrate any time from the menu.")
        }
        onFinish?(outcome)
        // Capture the window, not self: onFinish drops the owner's reference to this controller,
        // and a weak self here would leave the full-screen dimming window up for good.
        let window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated { window.orderOut(nil) }
        }
    }

    func cancel() {
        finish(.skipped)
    }
}

/// A borderless window that can take keyboard focus (for Esc).
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class CalibrationView: NSView {
    var onEscape: (() -> Void)?

    private let target = CAShapeLayer()
    private let targetProgress = CAShapeLayer()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var currentCorner = -1
    private let inset: CGFloat = 56
    private let radius: CGFloat = 26

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.04, alpha: 0.72).cgColor

        let circle = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        target.path = circle
        target.fillColor = Theme.accent.withAlphaComponent(0.18).cgColor
        target.strokeColor = Theme.accent.cgColor
        target.lineWidth = 3
        target.shadowColor = Theme.accent.cgColor
        target.shadowOpacity = 1
        target.shadowRadius = 14
        target.shadowOffset = .zero
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.9
        pulse.toValue = 1.15
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        target.add(pulse, forKey: "pulse")
        layer?.addSublayer(target)

        let arc = CGMutablePath()
        arc.addArc(center: .zero, radius: radius + 10, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        targetProgress.path = arc
        targetProgress.fillColor = nil
        targetProgress.strokeColor = NSColor.white.cgColor
        targetProgress.lineWidth = 4
        targetProgress.lineCap = .round
        targetProgress.strokeEnd = 0
        layer?.addSublayer(targetProgress)

        title.font = Theme.rounded(30, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        detail.font = Theme.rounded(16)
        detail.textColor = NSColor(white: 1, alpha: 0.75)
        detail.alignment = .center
        for label in [title, detail] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
            detail.centerXAnchor.constraint(equalTo: centerXAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    private func cornerPoint(_ index: Int) -> CGPoint {
        // Corner order matches CalibrationProfile: TL, TR, BR, BL (view space is y-up).
        switch index {
        case 0: return CGPoint(x: inset, y: bounds.maxY - inset)
        case 1: return CGPoint(x: bounds.maxX - inset, y: bounds.maxY - inset)
        case 2: return CGPoint(x: bounds.maxX - inset, y: inset)
        default: return CGPoint(x: inset, y: inset)
        }
    }

    func showCorner(_ index: Int, progress: Double, handVisible: Bool = true) {
        CATransaction.begin()
        CATransaction.setDisableActions(index == currentCorner)
        target.isHidden = false
        targetProgress.isHidden = false
        target.position = cornerPoint(index)
        targetProgress.position = cornerPoint(index)
        targetProgress.strokeEnd = CGFloat(progress)
        CATransaction.commit()
        currentCorner = index
        let names = ["top-left", "top-right", "bottom-right", "bottom-left"]
        title.stringValue = "Point at the \(names[min(index, 3)]) corner"
        detail.stringValue = handVisible
            ? "Hold your finger still until the ring fills.  \(index + 1) of 4   ·   Esc to skip"
            : "Raise your hand so the camera can see it.   Esc to skip"
    }

    func showMessage(_ text: String, detail message: String) {
        target.isHidden = true
        targetProgress.isHidden = true
        title.stringValue = text
        detail.stringValue = message
    }
}
#endif
