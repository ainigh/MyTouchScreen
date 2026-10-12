#if canImport(AppKit)
import AppKit
import GestureCore

/// Wisp's visual identity in one place. See DECISIONS.md → Concept.
enum Theme {
    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    static let accent = rgb(0x2EC4B6)      // Wisp Teal: hover / engaged
    static let dragging = rgb(0x8B7CF6)    // Violet
    static let zooming = rgb(0xFF6B9A)     // Rose
    static let warning = rgb(0xFF6B5B)     // Coral
    static let idle = rgb(0x9AA3AD)        // Slate, for standby glyphs

    static func color(for state: PointerState) -> NSColor {
        switch state {
        case .idle: return idle
        case .engaged, .hover: return accent
        case .dragging: return dragging
        case .twoFists: return zooming
        }
    }

    static func rounded(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: descriptor, size: size) ?? base
        }
        return base
    }

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static let haloRadius: CGFloat = 17
}
#endif
