#if canImport(AppKit)
import AppKit
import ApplicationServices
import GestureCore
import QuartzCore

/// Finds the clickable things around the pointer through the Accessibility API, for target
/// assist (GestureCore's `TargetAssist` does the rest).
///
/// AX calls are synchronous IPC into other apps, and a busy app can be slow to answer, so they
/// run on this scanner's own queue — never the camera, pipeline or main queue — with a short
/// messaging timeout and a time and element budget per scan. A scan walks the window (or menu
/// bar, or Dock) under the pointer, skipping every subtree whose frame is out of reach, and
/// rescans only when the pointer has moved or the last scan is getting old.
final class TargetScanner {
    private let queue = DispatchQueue(label: "app.wisp.targets", qos: .userInitiated)
    private let systemWide = AXUIElementCreateSystemWide()
    private let onTargets: ([AssistTarget]) -> Void

    // Scanner queue only.
    private var timer: DispatchSourceTimer?
    private var kinds: Set<TargetKind> = []
    private var lastScan: (point: CGPoint, time: CFTimeInterval, root: AXUIElement?)?
    private var lastTargets: [AssistTarget] = []
    private var manualAccessibilityPIDs: Set<pid_t> = []

    /// How often to look (seconds), and when a look can be skipped: the pointer moved less than
    /// `rescanDistance` points since a scan younger than `maxAge`, in the same window.
    static let interval = 0.15
    static let rescanDistance: CGFloat = 24
    static let maxAge = 0.6
    /// Targets are collected within this many points of the pointer (beyond the farthest reach
    /// plus look-ahead the assist uses).
    static let radius: CGFloat = 420
    /// Per-scan budget: a huge web page is cut short rather than costing the CPU.
    static let budget = 0.025
    static let maxVisited = 2500
    static let maxDepth = 48
    static let maxTargets = 250
    /// AX requests to an app that doesn't answer within this time fail instead of waiting.
    static let messagingTimeout: Float = 0.05

    /// `onTargets` runs on the scanner's queue whenever the list changes.
    init(onTargets: @escaping ([AssistTarget]) -> Void) {
        self.onTargets = onTargets
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)
    }

    /// Start scanning (or change which kinds of control are collected).
    func start(kinds: [TargetKind]) {
        let wanted = Set(kinds)
        queue.async {
            if self.kinds != wanted {
                self.kinds = wanted
                self.lastScan = nil
            }
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(Int(Self.interval * 1000)),
                           leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.scan() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Stop scanning and clear the targets (so nothing stale is left acting).
    func stop() {
        queue.async {
            guard self.timer != nil || !self.lastTargets.isEmpty else { return }
            self.timer?.cancel()
            self.timer = nil
            self.lastScan = nil
            self.lastTargets = []
            self.onTargets([])
        }
    }

    // MARK: Scanning

    private func scan() {
        guard let mouse = CGEvent(source: nil)?.location else { return }
        let now = CACurrentMediaTime()
        let hit = element(at: mouse)
        let root = hit.flatMap(topLevel(of:)) ?? focusedWindow()
        if let last = lastScan, now - last.time < Self.maxAge,
           hypot(mouse.x - last.point.x, mouse.y - last.point.y) < Self.rescanDistance,
           Self.same(root, last.root) {
            return
        }
        lastScan = (mouse, now, root)

        let region = CGRect(x: mouse.x - Self.radius, y: mouse.y - Self.radius,
                            width: Self.radius * 2, height: Self.radius * 2)
        var found: [AssistTarget] = []
        var seen = Set<Int>()
        if let root {
            enableManualAccessibility(for: root)
            let defaultButton = elementAttribute(root, "AXDefaultButton")
            // The budget starts here: finding the root can itself take a few round trips.
            walk(root, region: region, deadline: CACurrentMediaTime() + Self.budget, defaultButton: defaultButton,
                 found: &found, seen: &seen)
        }
        // Whatever is right under the pointer counts even if the walk ran out of budget first.
        if let hit, let target = clickableAncestor(of: hit, region: region), !seen.contains(target.id) {
            found.append(target)
        }
        if found.count > Self.maxTargets {
            let p = Point2(mouse.x, mouse.y)
            found.sort { $0.frame.distanceSquared(to: p) < $1.frame.distanceSquared(to: p) }
            found.removeLast(found.count - Self.maxTargets)
        }
        if found != lastTargets {
            lastTargets = found
            onTargets(found)
        }
    }

    /// Depth-first walk of `root`, collecting targets inside `region`. Each element carries the
    /// visible area it can show in (`clip`): rows and links scrolled out of a scroll area or web
    /// page still report frames, under toolbars and other panes, and must not count.
    private func walk(_ root: AXUIElement, region: CGRect, deadline: CFTimeInterval, defaultButton: AXUIElement?,
                      found: inout [AssistTarget], seen: inout Set<Int>) {
        var stack: [(element: AXUIElement, depth: Int, clip: CGRect)] = [(root, 0, region)]
        var visited = 0
        while let entry = stack.popLast() {
            let element = entry.element
            let depth = entry.depth
            var clip = entry.clip
            visited += 1
            // Every visit is a round trip or more to another app: check the clock each time.
            if visited > Self.maxVisited || CACurrentMediaTime() > deadline { return }
            let info = basics(of: element)
            // An open menu hangs outside the menu bar item (or button) it belongs to.
            if info.role == "AXMenu" { clip = region }
            if let frame = info.frame, frame.width > 0, frame.height > 0 {
                guard frame.intersects(clip) else { continue } // Out of view, and so is everything inside it.
                if Self.clippingRoles.contains(info.role ?? "") { clip = clip.intersection(frame) }
            }
            if info.enabled != false, let frame = info.frame, frame.width >= 2, frame.height >= 2,
               clip.intersects(frame),
               let kind = targetKind(of: element, role: info.role, subrole: info.subrole, frame: frame) {
                let target = Self.target(element, frame: frame, kind: kind,
                                         isDefault: defaultButton.map { CFEqual($0, element) } ?? false)
                if seen.insert(target.id).inserted { found.append(target) }
                // A button's insides (its label, its image) are the same target.
                if Self.leafKinds.contains(kind) { continue }
            }
            guard depth < Self.maxDepth else { continue }
            for child in children(of: element, role: info.role).reversed() {
                stack.append((child, depth + 1, clip))
            }
        }
    }

    /// Containers that show only part of their content: children outside them are hidden.
    private static let clippingRoles: Set<String> = ["AXWindow", "AXScrollArea", "AXWebArea"]

    /// Targets whose children are part of them, not separate targets.
    private static let leafKinds: Set<TargetKind> = [.button, .link, .toggle, .field]

    // MARK: Roles

    /// The kind of control `element` is, if it's one the user wants help with.
    private func targetKind(of element: AXUIElement, role: String?, subrole: String?, frame: CGRect) -> TargetKind? {
        guard let role else { return nil }
        let kind: TargetKind?
        switch role {
        case "AXButton", "AXPopUpButton", "AXMenuButton", "AXDockItem", "AXIncrementor", "AXColorWell":
            kind = .button
        case "AXLink":
            kind = .link
        case "AXMenuItem", "AXMenuBarItem":
            kind = .menuItem
        case "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle":
            kind = .toggle
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
            kind = .field
        case "AXRow":
            kind = .listItem
        case "AXImage", "AXStaticText", "AXGroup", "AXCell":
            // Only when it says it can be pressed (asking costs a round trip, so only small
            // elements, and only when "other" targets are wanted).
            guard kinds.contains(.other), frame.width <= 300, frame.height <= 300, canPress(element) else { return nil }
            kind = .other
        default:
            kind = nil
        }
        if subrole == "AXTabButton" { return kinds.contains(.toggle) ? .toggle : nil }
        guard let kind, kinds.contains(kind) else { return nil }
        return kind
    }

    private static func target(_ element: AXUIElement, frame: CGRect, kind: TargetKind, isDefault: Bool) -> AssistTarget {
        AssistTarget(id: Int(truncatingIfNeeded: CFHash(element)),
                     frame: GestureCore.Rect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height),
                     kind: kind, isDefault: isDefault)
    }

    /// The element under the pointer or its nearest clickable ancestor, as a target.
    private func clickableAncestor(of hit: AXUIElement, region: CGRect) -> AssistTarget? {
        var current: AXUIElement? = hit
        for _ in 0..<6 {
            guard let element = current else { return nil }
            let info = basics(of: element)
            if info.enabled != false, let frame = info.frame, frame.width >= 2, frame.height >= 2,
               region.intersects(frame),
               let kind = targetKind(of: element, role: info.role, subrole: info.subrole, frame: frame) {
                return Self.target(element, frame: frame, kind: kind, isDefault: false)
            }
            current = elementAttribute(element, "AXParent")
        }
        return nil
    }

    // MARK: Finding the window

    /// The deepest element at a global point, unless it's one of Wisp's own windows.
    private func element(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid == getpid() { return nil }
        return element
    }

    /// The window, menu bar or Dock list that `element` sits in: the ancestor just below the
    /// application.
    private func topLevel(of element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<64 {
            guard let parent = elementAttribute(current, "AXParent") else { return current }
            if stringAttribute(parent, "AXRole") == "AXApplication" { return current }
            current = parent
        }
        return current
    }

    /// Fallback when nothing answers at the pointer: the focused app's focused window.
    private func focusedWindow() -> AXUIElement? {
        guard let app = elementAttribute(systemWide, "AXFocusedApplication") else { return nil }
        var pid: pid_t = 0
        if AXUIElementGetPid(app, &pid) == .success, pid == getpid() { return nil }
        return elementAttribute(app, "AXFocusedWindow")
    }

    /// Chromium and Electron apps build their accessibility tree only when asked to; this is
    /// the documented switch for that (apps that don't know it ignore it). Once per app.
    private func enableManualAccessibility(for element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, !manualAccessibilityPIDs.contains(pid) else { return }
        manualAccessibilityPIDs.insert(pid)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString,
                                     kCFBooleanTrue)
    }

    // MARK: Attributes

    private struct Basics {
        var role: String?
        var subrole: String?
        /// Global (top-left origin) frame, when the element has one.
        var frame: CGRect?
        var enabled: Bool?
    }

    private static let basicNames = ["AXRole", "AXSubrole", "AXPosition", "AXSize", "AXEnabled"] as CFArray

    /// Role, subrole, frame and enabled state in one round trip.
    private func basics(of element: AXUIElement) -> Basics {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, Self.basicNames, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                     &values) == .success,
              let array = values as? [AnyObject], array.count == 5 else { return Basics() }
        var basics = Basics()
        basics.role = array[0] as? String
        basics.subrole = array[1] as? String
        if let origin = Self.point(array[2]), let size = Self.size(array[3]) {
            basics.frame = CGRect(origin: origin, size: size)
        }
        // Missing attributes come back as AXValues holding an error, not as booleans.
        if CFGetTypeID(array[4]) == CFBooleanGetTypeID() { basics.enabled = array[4] as? Bool }
        return basics
    }

    private static func point(_ value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetType(axValue) == .cgPoint, AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(_ value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetType(axValue) == .cgSize, AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Children to walk. Long lists and tables report just their visible rows when they can.
    private func children(of element: AXUIElement, role: String?) -> [AXUIElement] {
        if role == "AXTable" || role == "AXOutline" || role == "AXList" || role == "AXBrowser" {
            if let rows = elementsAttribute(element, "AXVisibleRows") ?? elementsAttribute(element, "AXVisibleChildren") {
                return rows
            }
        }
        return elementsAttribute(element, "AXChildren") ?? []
    }

    private func canPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let actions = names as? [String] else { return false }
        return actions.contains("AXPress")
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func elementsAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement]? {
        attribute(element, name) as? [AXUIElement]
    }

    private static func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return CFEqual(a, b)
        default: return false
        }
    }
}
#endif
