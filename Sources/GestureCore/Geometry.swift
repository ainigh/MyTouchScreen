import Foundation

/// A 2-D point in whatever space the caller is working in (normalized image, active box, or
/// global screen pixels). Kept tiny and dependency-free so GestureCore stays Foundation-only.
public struct Point2: Equatable, Hashable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2(0, 0)

    public static func + (a: Point2, b: Point2) -> Point2 { Point2(a.x + b.x, a.y + b.y) }
    public static func - (a: Point2, b: Point2) -> Point2 { Point2(a.x - b.x, a.y - b.y) }
    public static func * (a: Point2, s: Double) -> Point2 { Point2(a.x * s, a.y * s) }
    public static func / (a: Point2, s: Double) -> Point2 { Point2(a.x / s, a.y / s) }
    public static func += (a: inout Point2, b: Point2) { a = a + b }
    public static func -= (a: inout Point2, b: Point2) { a = a - b }

    public var length: Double { (x * x + y * y).squareRoot() }

    public func distance(to other: Point2) -> Double { (self - other).length }

    public func lerp(to other: Point2, _ t: Double) -> Point2 {
        Point2(x + (other.x - x) * t, y + (other.y - y) * t)
    }

    public var description: String { String(format: "(%.4f, %.4f)", x, y) }
}

/// Axis-aligned rectangle with a top-left origin (matches CoreGraphics global display space,
/// which is what CGEvent mouse positions use).
public struct Rect: Equatable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var center: Point2 { Point2(x + width / 2, y + height / 2) }

    /// Half-open containment, so adjacent displays never both claim a shared edge.
    public func contains(_ p: Point2) -> Bool {
        p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }

    /// Closest point inside the rect (inclusive of the last pixel row/column).
    public func clamp(_ p: Point2) -> Point2 {
        Point2(min(max(p.x, minX), maxX - 1), min(max(p.y, minY), maxY - 1))
    }

    public func distanceSquared(to p: Point2) -> Double {
        let c = clamp(p)
        return (c - p).length * (c - p).length
    }
}

@inline(__always)
func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

@inline(__always)
func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
