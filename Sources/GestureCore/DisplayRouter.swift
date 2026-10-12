import Foundation

/// Decides which display the hand is driving. The pointer lives on one display at a time;
/// holding the hand past an edge for `dwell` seconds moves it to the adjacent display in that
/// direction. After a jump the hand must come back inside the box before another jump can
/// happen, otherwise a hand resting at the edge would ping-pong between screens.
public struct DisplayRouter {
    public enum Edge: Equatable { case left, right, top, bottom }

    public private(set) var displays: [DisplayInfo]
    public private(set) var currentID: String?
    public var dwell: Double
    /// Stay on the current display: no edge jumps. Engaging still picks the display (the one
    /// the real mouse is on), via `focus(containing:)`.
    public var locked = false

    private var pendingEdge: (edge: Edge, since: Double)?
    private var armed = true

    public init(displays: [DisplayInfo], dwell: Double) {
        self.displays = displays
        self.dwell = dwell
        self.currentID = displays.first?.id
    }

    public var current: DisplayInfo? {
        displays.first { $0.id == currentID } ?? displays.first
    }

    public mutating func setDisplays(_ newDisplays: [DisplayInfo]) {
        displays = newDisplays
        if !newDisplays.contains(where: { $0.id == currentID }) {
            currentID = newDisplays.first?.id
        }
        pendingEdge = nil
    }

    /// Make the display under `point` (global coordinates) current, e.g. where the real mouse is.
    public mutating func focus(containing point: Point2) {
        if let hit = displays.first(where: { $0.frame.contains(point) }) {
            currentID = hit.id
        } else if let nearest = displays.min(by: { $0.frame.distanceSquared(to: point) < $1.frame.distanceSquared(to: point) }) {
            currentID = nearest.id
        }
        pendingEdge = nil
    }

    /// Feed the unclamped box-space pointer. Returns the new display when a jump happens.
    public mutating func update(box: Point2, at time: Double) -> DisplayInfo? {
        guard !locked else { return nil }
        let margin = 0.0
        let edge: Edge?
        if box.x < margin { edge = .left }
        else if box.x > 1 - margin { edge = .right }
        else if box.y < margin { edge = .top }
        else if box.y > 1 - margin { edge = .bottom }
        else { edge = nil }

        guard let edge else {
            pendingEdge = nil
            // Re-arm once the hand is comfortably inside again.
            if box.x > 0.08 && box.x < 0.92 && box.y > 0.08 && box.y < 0.92 { armed = true }
            return nil
        }
        guard armed, let from = current, let target = neighbor(of: from, toward: edge) else {
            pendingEdge = nil
            return nil
        }
        if let pending = pendingEdge, pending.edge == edge {
            if time - pending.since >= dwell {
                currentID = target.id
                pendingEdge = nil
                armed = false
                return target
            }
        } else {
            pendingEdge = (edge, time)
        }
        return nil
    }

    /// Fraction of the dwell completed toward a jump (for the overlay), 0 when not at an edge.
    public func jumpProgress(at time: Double) -> Double {
        guard let pending = pendingEdge, dwell > 0 else { return 0 }
        return clamp01((time - pending.since) / dwell)
    }

    /// The display adjacent to `from` in direction `edge`: it must lie beyond that edge and
    /// overlap it along the other axis. Among several, the one closest to the edge wins.
    public func neighbor(of from: DisplayInfo, toward edge: Edge) -> DisplayInfo? {
        let f = from.frame
        let candidates = displays.filter { other in
            guard other.id != from.id else { return false }
            let o = other.frame
            let overlapsY = o.minY < f.maxY && o.maxY > f.minY
            let overlapsX = o.minX < f.maxX && o.maxX > f.minX
            switch edge {
            case .left: return o.maxX <= f.minX + 1 && overlapsY
            case .right: return o.minX >= f.maxX - 1 && overlapsY
            case .top: return o.maxY <= f.minY + 1 && overlapsX
            case .bottom: return o.minY >= f.maxY - 1 && overlapsX
            }
        }
        return candidates.min { a, b in
            gap(from: f, to: a.frame, edge: edge) < gap(from: f, to: b.frame, edge: edge)
        }
    }

    private func gap(from f: Rect, to o: Rect, edge: Edge) -> Double {
        switch edge {
        case .left: return f.minX - o.maxX
        case .right: return o.minX - f.maxX
        case .top: return f.minY - o.maxY
        case .bottom: return o.minY - f.maxY
        }
    }
}
