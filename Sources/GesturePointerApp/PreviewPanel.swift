#if canImport(AppKit)
import AppKit
import AVFoundation
import GestureCore
import QuartzCore

/// Picture-in-picture camera preview with the tracked hand skeleton drawn on top. Floating,
/// draggable, and it snaps to the nearest screen corner when released.
@MainActor
final class PreviewPanel {
    private let panel: NSPanel
    private let view: PreviewView
    private var moveObserver: NSObjectProtocol?
    private var snapTimer: Timer?
    private var isSnapping = false
    /// Called with the new corner index (0 TL, 1 TR, 2 BR, 3 BL) after a drag.
    var onCornerChange: ((Int) -> Void)?
    var showsSkeleton = true

    init(session: AVCaptureSession, corner: Int) {
        let size = NSSize(width: 256, height: 144)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        view = PreviewView(frame: NSRect(origin: .zero, size: size), session: session)
        panel.contentView = view
        place(corner: corner, animate: false)

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelMoved() }
        }
    }

    func show() { panel.orderFrontRegardless() }

    func close() {
        snapTimer?.invalidate()
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        panel.orderOut(nil)
    }

    func update(hands: [HandFrame], primaryIndex: Int?) {
        view.update(hands: showsSkeleton ? hands : [], primaryIndex: primaryIndex)
    }

    // MARK: Corner snapping

    private func panelMoved() {
        guard !isSnapping else { return }
        snapTimer?.invalidate()
        // Wait until the drag has settled, then glide into the nearest corner.
        snapTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapToNearestCorner() }
        }
    }

    private func snapToNearestCorner() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let left = center.x < visible.midX
        let top = center.y > visible.midY
        let corner = top ? (left ? 0 : 1) : (left ? 3 : 2)
        place(corner: corner, animate: true, on: screen)
        onCornerChange?(corner)
    }

    private func place(corner: Int, animate: Bool, on screen: NSScreen? = nil) {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let inset: CGFloat = 16
        let size = panel.frame.size
        let x = (corner == 0 || corner == 3) ? visible.minX + inset : visible.maxX - size.width - inset
        let y = (corner == 0 || corner == 1) ? visible.maxY - size.height - inset : visible.minY + inset
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        isSnapping = true
        panel.setFrame(frame, display: true, animate: animate)
        isSnapping = false
    }
}

/// Mirrored camera image plus skeleton. Mirrored because people expect to see themselves as in
/// a mirror; the skeleton is mirrored with the same mapping so it sits on the hand.
final class PreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let bones = CAShapeLayer()
    private let joints = CAShapeLayer()
    private let label = NSTextField(labelWithString: "")
    private var imageAspect: Double = 16.0 / 9.0

    private static let boneList: [(GestureCore.Joint, GestureCore.Joint)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
        (.indexMCP, .middleMCP), (.middleMCP, .ringMCP), (.ringMCP, .littleMCP),
    ]

    init(frame: NSRect, session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        layer?.borderWidth = 1

        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        layer?.addSublayer(previewLayer)

        bones.strokeColor = Theme.accent.withAlphaComponent(0.85).cgColor
        bones.fillColor = nil
        bones.lineWidth = 1.5
        bones.lineCap = .round
        joints.fillColor = NSColor.white.cgColor
        layer?.addSublayer(bones)
        layer?.addSublayer(joints)

        label.font = Theme.mono(10, weight: .medium)
        label.textColor = .white
        label.drawsBackground = false
        label.frame = NSRect(x: 10, y: 6, width: frame.width - 20, height: 14)
        label.autoresizingMask = [.width]
        addSubview(label)
        layoutLayers()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // bounds + position (not frame), because the layer carries a mirroring transform.
        previewLayer.bounds = bounds
        previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        bones.frame = bounds
        joints.frame = bounds
        CATransaction.commit()
    }

    /// Normalized, un-mirrored, top-left-origin image point → mirrored, aspect-filled layer point.
    private func layerPoint(_ p: Point2) -> CGPoint {
        let w = Double(bounds.width), h = Double(bounds.height)
        let imageW = imageAspect, imageH = 1.0
        let scale = max(w / imageW, h / imageH)
        let offsetX = (w - imageW * scale) / 2
        let offsetY = (h - imageH * scale) / 2
        let x = offsetX + (1 - p.x) * imageW * scale
        let yFromTop = offsetY + p.y * imageH * scale
        return CGPoint(x: x, y: h - yFromTop)
    }

    func update(hands: [HandFrame], primaryIndex: Int?) {
        // The mirror comes from our own transform only. The connection exists once the camera
        // has an input (and is replaced when the camera changes), so pin it here; left on its
        // automatic default it can mirror too and the image would be flipped under the skeleton.
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported,
           connection.automaticallyAdjustsVideoMirroring || connection.isVideoMirrored {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        let bonePath = CGMutablePath()
        let jointPath = CGMutablePath()
        for hand in hands {
            imageAspect = hand.imageAspect
            for (a, b) in Self.boneList {
                bonePath.move(to: layerPoint(hand[a]))
                bonePath.addLine(to: layerPoint(hand[b]))
            }
            for joint in GestureCore.Joint.allCases {
                let p = layerPoint(hand[joint])
                let r: CGFloat = joint == .indexTip || joint == .thumbTip ? 2.6 : 1.6
                jointPath.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bones.path = bonePath
        joints.path = jointPath
        CATransaction.commit()

        if let index = primaryIndex, hands.indices.contains(index) {
            let hand = hands[index]
            let side = hand.chirality == .unknown ? "hand" : hand.chirality.rawValue.capitalized
            label.stringValue = String(format: "%@  ·  %.0f%%  ·  %d hand%@", side, hand.confidence * 100,
                                       hands.count, hands.count == 1 ? "" : "s")
        } else {
            label.stringValue = hands.isEmpty ? "no hand" : "\(hands.count) hand\(hands.count == 1 ? "" : "s")"
        }
    }
}
#endif
