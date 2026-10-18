#if canImport(AppKit)
import AppKit
import CoreGraphics
import GestureCore

/// Bridges NSScreen / CGDisplay to GestureCore's `DisplayInfo` and converts between the two
/// coordinate systems:
/// - CoreGraphics global space (CGEvent, CGDisplayBounds): origin top-left of the primary display.
/// - Cocoa screen space (NSWindow, NSEvent.mouseLocation): origin bottom-left of the primary display.
enum Displays {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// A stable identifier that survives reboots and re-plugging (the display UUID), so
    /// per-display calibration sticks to the physical screen.
    static func stableID(for displayID: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) {
            return string as String
        }
        return "display-\(displayID)"
    }

    static func stableID(of screen: NSScreen) -> String? {
        displayID(of: screen).map(stableID(for:))
    }

    /// Current displays in CoreGraphics global coordinates (points).
    static func current() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let id = displayID(of: screen) else { return nil }
            let b = CGDisplayBounds(id)
            return DisplayInfo(id: stableID(for: id),
                               frame: GestureCore.Rect(x: b.origin.x, y: b.origin.y, width: b.width, height: b.height))
        }
    }

    /// Height of the primary display, the pivot for flipping between the two spaces.
    static var primaryHeight: CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }

    static func cocoaPoint(fromGlobal p: CGPoint) -> NSPoint {
        NSPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// A global (top-left origin) rect in Cocoa screen space.
    static func cocoaRect(fromGlobal r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func globalPoint(fromCocoa p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// Current cursor location in global (top-left) coordinates.
    static func mouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? globalPoint(fromCocoa: NSEvent.mouseLocation)
    }

    static func screen(containingGlobal p: CGPoint) -> NSScreen? {
        let cocoa = cocoaPoint(fromGlobal: p)
        return NSScreen.screens.first { NSMouseInRect(cocoa, $0.frame, false) } ?? NSScreen.main
    }
}
#endif
