#if canImport(AppKit)
import AppKit
import GestureCore
import QuartzCore

/// One transparent, click-through window per screen, above everything, drawing the cursor halo,
/// the hold and engage rings, the click ripple, the display-jump edge glow, toasts, the standby
/// glyph and target assist's outlines.
///
/// All methods are main-thread only. Updates arrive at camera rate; layer changes that track
/// the hand are made without implicit animations (they would add ~250 ms of visual lag).
@MainActor
final class OverlayController {
    private var windows: [(screen: NSScreen, window: NSWindow, view: OverlayView)] = []
    var showStatusGlyph = true
    /// Outline the target the cursor is drawn to.
    var highlightsTarget = true
    /// Faintly outline every target found; takes effect with the next `showTargets`.
    var outlinesTargets = false {
        didSet { if outlinesTargets != oldValue { showTargets(targets) } }
    }
    private var targets: [AssistTarget] = []

    init() {
        rebuild()
    }

    /// Recreate windows to match the current screens (called on display changes).
    func rebuild() {
        for entry in windows { entry.window.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.contentView = view
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            return (screen, window, view)
        }
        showTargets(targets)
    }

    func close() {
        for entry in windows { entry.window.orderOut(nil) }
        windows = []
    }

    /// Redraw from the latest pointer snapshot.
    func update(_ snapshot: PointerSnapshot, status: MenuBarStatus) {
        // Where the halo goes: the hand's cursor when engaged; the real mouse while a palm
        // hold is engaging (so the filling ring appears where the user is looking).
        var haloPoint: CGPoint?
        if let cursor = snapshot.cursor, snapshot.isEngaged {
            haloPoint = CGPoint(x: cursor.x, y: cursor.y)
        } else if snapshot.engageProgress > 0 {
            haloPoint = Displays.mouseLocation()
        }
        let cocoa = haloPoint.map(Displays.cocoaPoint(fromGlobal:))
        let mainScreen = NSScreen.screens.first

        for entry in windows {
            let frame = entry.screen.frame
            var halo: OverlayView.HaloModel?
            if let cocoa, NSMouseInRect(cocoa, frame, false) {
                let local = CGPoint(x: cocoa.x - frame.minX, y: cocoa.y - frame.minY)
                halo = OverlayView.HaloModel(snapshot: snapshot, at: local)
            }
            let glyph: NSColor? = (showStatusGlyph && !snapshot.isEngaged && entry.screen == mainScreen)
                ? (status == .needsPermission ? Theme.warning : (status == .off ? nil : Theme.idle))
                : nil
            entry.view.render(halo: halo, glyph: glyph, edgeProgress: halo != nil ? snapshot.displayJumpProgress : 0)
            var focus: (rect: NSRect, strength: Double)?
            if highlightsTarget, let assist = snapshot.assistFocus {
                focus = (local(assist.target.frame, on: entry.screen), assist.strength)
            }
            entry.view.renderFocus(focus)
        }
    }

    /// Every target found around the pointer (target assist), outlined faintly while
    /// `outlinesTargets` is on.
    func showTargets(_ targets: [AssistTarget]) {
        self.targets = targets
        for entry in windows {
            let rects = outlinesTargets
                ? targets.map { local($0.frame, on: entry.screen) }.filter { entry.view.bounds.intersects($0) }
                : []
            entry.view.renderTargets(rects)
        }
    }

    /// A global target frame in the coordinates of `screen`'s overlay view.
    private func local(_ frame: GestureCore.Rect, on screen: NSScreen) -> NSRect {
        let cocoa = Displays.cocoaRect(fromGlobal: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
        return cocoa.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    /// A ripple where a wiggle clicked (a second ring for a double click), so the click is seen
    /// as well as heard.
    func flashClick(at global: Point2, count: Int) {
        let cocoa = Displays.cocoaPoint(fromGlobal: CGPoint(x: global.x, y: global.y))
        for entry in windows where NSMouseInRect(cocoa, entry.screen.frame, false) {
            let frame = entry.screen.frame
            entry.view.flashClick(at: CGPoint(x: cocoa.x - frame.minX, y: cocoa.y - frame.minY), count: count)
        }
    }

    /// Short status message near the top of the screen the user is looking at.
    func toast(_ text: String, symbol: String, tint: NSColor = Theme.accent) {
        let mouse = Displays.cocoaPoint(fromGlobal: Displays.mouseLocation())
        let target = windows.first { NSMouseInRect(mouse, $0.screen.frame, false) } ?? windows.first
        target?.view.showToast(text, symbol: symbol, tint: tint)
    }
}

// MARK: - View

final class OverlayView: NSView {
    struct HaloModel {
        var point: CGPoint
        var color: NSColor
        var isDown: Bool
        var ringProgress: Double
        var ringColor: NSColor

        init(snapshot: PointerSnapshot, at point: CGPoint) {
            self.point = point
            if snapshot.isEngaged {
                color = Theme.color(for: snapshot.state)
                // The centre dot also marks a steering fist, so the hand's mode is visible.
                isDown = snapshot.state == .dragging || snapshot.isSteeringFist
                if snapshot.engageProgress > 0 {
                    ringProgress = snapshot.engageProgress
                    ringColor = Theme.idle
                } else {
                    // Full while the cursor is held on a point (after a click, while a fist
                    // forms, after a drop) until the hand settles; filling toward a dwell click.
                    ringProgress = snapshot.isHeld ? 1 : snapshot.clickProgress
                    ringColor = Theme.accent
                }
            } else {
                // Engaging: only the outer ring, filling.
                color = Theme.idle
                isDown = false
                ringProgress = snapshot.engageProgress
                ringColor = Theme.accent
            }
        }
    }

    private let halo = HaloLayer()
    private let focusOutline = CAShapeLayer()
    private let targetOutlines = CAShapeLayer()
    private let glyph = CAShapeLayer()
    private let edgeGlow = CAGradientLayer()
    private let toastView = ToastView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        halo.isHidden = true
        layer?.addSublayer(edgeGlow)

        targetOutlines.fillColor = nil
        targetOutlines.strokeColor = Theme.idle.withAlphaComponent(0.45).cgColor
        targetOutlines.lineWidth = 1
        layer?.addSublayer(targetOutlines)

        focusOutline.fillColor = Theme.accent.withAlphaComponent(0.08).cgColor
        focusOutline.strokeColor = Theme.accent.cgColor
        focusOutline.lineWidth = 2
        focusOutline.shadowColor = Theme.accent.cgColor
        focusOutline.shadowOpacity = 0.6
        focusOutline.shadowRadius = 4
        focusOutline.shadowOffset = .zero
        focusOutline.isHidden = true
        layer?.addSublayer(focusOutline)

        layer?.addSublayer(halo)

        let glyphSize: CGFloat = 8
        glyph.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: glyphSize, height: glyphSize), transform: nil)
        glyph.bounds = CGRect(x: 0, y: 0, width: glyphSize, height: glyphSize)
        glyph.strokeColor = NSColor(white: 1, alpha: 0.7).cgColor
        glyph.lineWidth = 1
        glyph.isHidden = true
        layer?.addSublayer(glyph)

        edgeGlow.opacity = 0
        addSubview(toastView)
        toastView.alphaValue = 0
    }

    required init?(coder: NSCoder) {
        nil
    }

    func render(halo model: HaloModel?, glyph glyphColor: NSColor?, edgeProgress: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let model {
            halo.isHidden = false
            halo.position = model.point
            halo.apply(color: model.color, isDown: model.isDown, ringProgress: model.ringProgress,
                       ringColor: model.ringColor)
        } else {
            halo.isHidden = true
        }

        if let glyphColor {
            glyph.isHidden = false
            glyph.fillColor = glyphColor.cgColor
            // Bottom-right corner, clear of the Dock's usual position on the bottom edge.
            glyph.position = CGPoint(x: bounds.maxX - 14, y: 14)
        } else {
            glyph.isHidden = true
        }

        if edgeProgress > 0, let model {
            layoutEdgeGlow(near: model.point, color: model.color)
            edgeGlow.opacity = Float(edgeProgress)
        } else {
            edgeGlow.opacity = 0
        }
        CATransaction.commit()
    }

    /// A soft rounded outline around the control target assist is drawing the cursor to, more
    /// visible the stronger the pull.
    func renderFocus(_ focus: (rect: NSRect, strength: Double)?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let focus, focus.strength > 0.05 {
            let rect = focus.rect.insetBy(dx: -3, dy: -3)
            let radius = min(7, rect.height / 2, rect.width / 2)
            focusOutline.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            focusOutline.opacity = Float(0.25 + 0.75 * min(focus.strength, 1))
            focusOutline.isHidden = false
        } else {
            focusOutline.isHidden = true
        }
        CATransaction.commit()
    }

    /// Thin outlines around every target found (tuning aid).
    func renderTargets(_ rects: [NSRect]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if rects.isEmpty {
            targetOutlines.path = nil
        } else {
            let path = CGMutablePath()
            for rect in rects {
                let radius = min(4, rect.height / 2, rect.width / 2)
                path.addRoundedRect(in: rect.insetBy(dx: -1, dy: -1), cornerWidth: radius, cornerHeight: radius)
            }
            targetOutlines.path = path
        }
        CATransaction.commit()
    }

    /// A soft glow along the edge the cursor is pushing against, filling as the jump dwell runs.
    private func layoutEdgeGlow(near point: CGPoint, color: NSColor) {
        let thickness: CGFloat = 10
        let distances: [(CGFloat, Int)] = [(point.x, 0), (bounds.maxX - point.x, 1),
                                           (point.y, 2), (bounds.maxY - point.y, 3)]
        let edge = distances.min { $0.0 < $1.0 }?.1 ?? 1
        let solid = color.withAlphaComponent(0.8).cgColor
        let clear = color.withAlphaComponent(0).cgColor
        edgeGlow.colors = [solid, clear]
        switch edge {
        case 0:
            edgeGlow.frame = CGRect(x: 0, y: 0, width: thickness, height: bounds.height)
            edgeGlow.startPoint = CGPoint(x: 0, y: 0.5); edgeGlow.endPoint = CGPoint(x: 1, y: 0.5)
        case 1:
            edgeGlow.frame = CGRect(x: bounds.maxX - thickness, y: 0, width: thickness, height: bounds.height)
            edgeGlow.startPoint = CGPoint(x: 1, y: 0.5); edgeGlow.endPoint = CGPoint(x: 0, y: 0.5)
        case 2:
            edgeGlow.frame = CGRect(x: 0, y: 0, width: bounds.width, height: thickness)
            edgeGlow.startPoint = CGPoint(x: 0.5, y: 0); edgeGlow.endPoint = CGPoint(x: 0.5, y: 1)
        default:
            edgeGlow.frame = CGRect(x: 0, y: bounds.maxY - thickness, width: bounds.width, height: thickness)
            edgeGlow.startPoint = CGPoint(x: 0.5, y: 1); edgeGlow.endPoint = CGPoint(x: 0.5, y: 0)
        }
    }

    // MARK: Click feedback

    /// Ripple = click, double ripple = double click. Fades within 300 ms.
    func flashClick(at point: CGPoint, count: Int) {
        addFlash(Self.circle(radius: 20), at: point, color: Theme.accent, fill: true, from: 0.4, to: 1.5, delay: 0)
        if count >= 2 {
            addFlash(Self.circle(radius: 20), at: point, color: Theme.accent, fill: false, from: 0.4, to: 2.0, delay: 0.09)
        }
    }

    private static func circle(radius r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
    }

    private func addFlash(_ path: CGPath, at point: CGPoint, color: NSColor, fill: Bool, from: CGFloat, to: CGFloat,
                          delay: CFTimeInterval, lineWidth: CGFloat = 2.5) {
        guard let host = layer else { return }
        let shape = CAShapeLayer()
        shape.path = path
        shape.position = point
        shape.fillColor = fill ? color.withAlphaComponent(0.22).cgColor : nil
        shape.strokeColor = color.cgColor
        shape.lineWidth = lineWidth
        shape.lineCap = .round
        shape.lineJoin = .round
        shape.shadowColor = color.cgColor
        shape.shadowOpacity = 0.8
        shape.shadowRadius = 5
        shape.shadowOffset = .zero
        shape.opacity = 0
        host.addSublayer(shape)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = from
        scale.toValue = to
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.95, 0.8, 0]
        fade.keyTimes = [0, 0.4, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.3
        group.beginTime = CACurrentMediaTime() + delay
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        shape.add(group, forKey: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.35) { [weak shape] in
            shape?.removeFromSuperlayer()
        }
    }

    func showToast(_ text: String, symbol: String, tint: NSColor) {
        toastView.configure(text: text, symbol: symbol, tint: tint)
        let size = toastView.fittingSize
        toastView.frame = NSRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 72,
                                 width: size.width, height: size.height)
        toastView.show()
    }
}

// MARK: - Halo

/// The cursor halo: a translucent puck for contrast on any background, a glowing ring in the
/// state colour, a dot while the button is down (fist drag), and an outer arc for the palm hold
/// and, full, while the cursor is frozen.
final class HaloLayer: CALayer {
    private let puck = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let dot = CAShapeLayer()
    private let outerArc = CAShapeLayer()
    private let size: CGFloat = 72

    override init() {
        super.init()
        bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let center = CGPoint(x: size / 2, y: size / 2)
        let r = Theme.haloRadius

        puck.path = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2), transform: nil)
        puck.fillColor = NSColor(white: 0, alpha: 0.10).cgColor
        puck.strokeColor = NSColor(white: 1, alpha: 0.55).cgColor
        puck.lineWidth = 0.75

        ring.path = puck.path
        ring.fillColor = nil
        ring.lineWidth = 2.5
        ring.shadowOpacity = 0.9
        ring.shadowRadius = 6
        ring.shadowOffset = .zero

        dot.path = CGPath(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8), transform: nil)
        dot.isHidden = true

        outerArc.path = Self.arcPath(center: center, radius: r + 7)
        outerArc.fillColor = nil
        outerArc.lineWidth = 3
        outerArc.lineCap = .round
        outerArc.strokeEnd = 0

        for layer in [puck, ring, dot, outerArc] {
            layer.frame = bounds
            addSublayer(layer)
        }
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// A full circle starting at 12 o'clock and running clockwise (layer space is y-up).
    private static func arcPath(center: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        return path
    }

    func apply(color: NSColor, isDown: Bool, ringProgress: Double, ringColor: NSColor) {
        let cg = color.cgColor
        ring.strokeColor = cg
        ring.shadowColor = cg
        dot.fillColor = cg
        dot.isHidden = !isDown
        // A held fist shrinks the ring slightly, like a button going down.
        ring.setAffineTransform(isDown ? Self.pressed : .identity)
        outerArc.strokeColor = ringColor.cgColor
        outerArc.strokeEnd = CGFloat(max(0, min(1, ringProgress)))
        outerArc.isHidden = ringProgress <= 0.01
    }

    /// Layer transforms apply about the anchor point (the centre), so a plain scale suffices.
    private static let pressed = CGAffineTransform(scaleX: 0.82, y: 0.82)
}

// MARK: - Toast

final class ToastView: NSVisualEffectView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var generation = 0

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        label.font = Theme.rounded(14, weight: .semibold)
        label.textColor = .labelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(text: String, symbol: String, tint: NSColor) {
        label.stringValue = text
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
    }

    func show() {
        generation += 1
        let shown = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            MainActor.assumeIsolated {
                // A newer toast replaced this one: let it run its own timer.
                guard let self, self.generation == shown else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.35
                    self.animator().alphaValue = 0
                }
            }
        }
    }
}
#endif
