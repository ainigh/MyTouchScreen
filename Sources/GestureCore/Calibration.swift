import Foundation

/// A display as GestureCore sees it: a stable identifier plus its frame in global display
/// coordinates (points, top-left origin of the primary display — the space `CGEvent` uses).
public struct DisplayInfo: Equatable, Codable {
    public var id: String
    public var frame: Rect

    public init(id: String, frame: Rect) {
        self.id = id
        self.frame = frame
    }
}

/// Projective map between a quadrilateral and the unit square.
///
/// A homography rather than a bilinear or affine map, because the user points at the four screen
/// corners from an angle: the fingertip positions form a perspective-distorted quad in camera
/// space, and a homography is exactly the transform that undoes that.
public struct Homography: Equatable, Codable {
    /// Row-major 3x3, with m[8] == 1.
    public var m: [Double]

    public init(m: [Double]) {
        precondition(m.count == 9)
        self.m = m
    }

    public static let identity = Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    public func apply(_ p: Point2) -> Point2 {
        let w = m[6] * p.x + m[7] * p.y + m[8]
        let safeW = abs(w) < 1e-12 ? 1e-12 : w
        return Point2((m[0] * p.x + m[1] * p.y + m[2]) / safeW,
                      (m[3] * p.x + m[4] * p.y + m[5]) / safeW)
    }

    /// Solve for H with H(source[i]) = target[i] for four point pairs.
    /// Returns nil when the points are degenerate (three collinear, or coincident).
    public static func solve(from source: [Point2], to target: [Point2]) -> Homography? {
        guard source.count == 4, target.count == 4 else { return nil }
        // Standard DLT with h33 = 1: two equations per correspondence, eight unknowns.
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let (x, y) = (source[i].x, source[i].y)
            let (u, v) = (target[i].x, target[i].y)
            a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        guard let h = solveLinear(&a) else { return nil }
        return Homography(m: h + [1])
    }

    /// Gaussian elimination with partial pivoting on an n x (n+1) augmented matrix.
    private static func solveLinear(_ a: inout [[Double]]) -> [Double]? {
        let n = a.count
        for col in 0..<n {
            var pivot = col
            for row in (col + 1)..<n where abs(a[row][col]) > abs(a[pivot][col]) {
                pivot = row
            }
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)
            for row in 0..<n where row != col {
                let factor = a[row][col] / a[col][col]
                if factor == 0 { continue }
                for k in col...n {
                    a[row][k] -= factor * a[col][k]
                }
            }
        }
        return (0..<n).map { a[$0][n] / a[$0][$0] }
    }
}

/// Where the user's fingertip was (in camera space) when pointing at each screen corner.
/// Stored per display. (Profiles saved by older versions also carry pinch thresholds; decoding
/// ignores them.)
public struct CalibrationProfile: Equatable, Codable {
    /// Camera-space fingertip positions for the screen's top-left, top-right, bottom-right and
    /// bottom-left corners, in that order.
    public var corners: [Point2]
    /// True when this came from a real calibration rather than the defaults.
    public var isCalibrated: Bool

    public init(corners: [Point2], isCalibrated: Bool) {
        self.corners = corners
        self.isCalibrated = isCalibrated
    }

    /// A centered box covering ~42% of the image width, mirrored (the user's right, which is
    /// the camera's left, maps to the screen's right) and a little above center because people
    /// hold their hand up, not in their lap.
    public static func defaultProfile() -> CalibrationProfile {
        let center = Point2(0.5, 0.45)
        let halfWidth = 0.21
        let halfHeight = 0.23
        return CalibrationProfile(
            corners: [
                Point2(center.x + halfWidth, center.y - halfHeight), // screen top-left
                Point2(center.x - halfWidth, center.y - halfHeight), // screen top-right
                Point2(center.x - halfWidth, center.y + halfHeight), // screen bottom-right
                Point2(center.x + halfWidth, center.y + halfHeight), // screen bottom-left
            ],
            isCalibrated: false)
    }

    /// Rejects quads that would produce a nonsensical mapping: too small (the user did not move
    /// between corners) or not convex (corners captured in the wrong order).
    public var isUsable: Bool {
        guard corners.count == 4 else { return false }
        var sign: Double = 0
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4], c = corners[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-9 { return false }
            if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
        }
        return Self.polygonArea(corners) > 0.004 // ~6% x 6% of the image at minimum
    }

    static func polygonArea(_ p: [Point2]) -> Double {
        var sum = 0.0
        for i in 0..<p.count {
            let a = p[i], b = p[(i + 1) % p.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }
}

/// Maps camera-space points into the calibrated active box, and box coordinates to a display.
///
/// Box coordinates are 0...1 across the calibrated region and are *not* clamped here, so callers
/// can tell when the hand is past an edge (display jumping depends on that).
public struct ActiveBoxMapper: Equatable {
    public let profile: CalibrationProfile
    /// Sensitivity: < 1 shrinks the box (smaller hand motions cover the screen), > 1 grows it.
    public let boxScale: Double
    /// Extra reach past each edge, as a fraction of the box. The calibrated corners map *beyond*
    /// the screen corners by this much, so the user can comfortably hit the menu bar and the
    /// Dock without stretching to the exact calibrated spot. The result is then clamped.
    public let edgeOvershoot: Double
    private let homography: Homography

    public init(profile: CalibrationProfile, boxScale: Double = 1.0, edgeOvershoot: Double = 0.04) {
        let usable = profile.isUsable ? profile : CalibrationProfile.defaultProfile()
        self.profile = usable
        // A zero scale collapses the box (the solve fails and the identity map is unmirrored);
        // a negative one rotates it 180 degrees. Neither is a sensitivity, so use the default.
        let scale = boxScale > 0 && boxScale.isFinite ? boxScale : 1
        self.boxScale = scale
        self.edgeOvershoot = edgeOvershoot
        let centroid = usable.corners.reduce(Point2.zero, +) / 4
        let scaled = usable.corners.map { centroid + ($0 - centroid) * scale }
        let unit = [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)]
        self.homography = Homography.solve(from: scaled, to: unit) ?? .identity
    }

    /// Camera space → box space (unclamped, with overshoot applied: 0 and 1 are the screen edges).
    public func boxPoint(fromCamera p: Point2) -> Point2 {
        let raw = homography.apply(p)
        let gain = 1 + 2 * edgeOvershoot
        return Point2((raw.x - 0.5) * gain + 0.5, (raw.y - 0.5) * gain + 0.5)
    }

    /// Box space → global screen points on `display`, clamped to the display.
    public static func screenPoint(fromBox b: Point2, on display: DisplayInfo) -> Point2 {
        let f = display.frame
        let x = f.minX + clamp01(b.x) * (f.width - 1)
        let y = f.minY + clamp01(b.y) * (f.height - 1)
        return Point2(x, y)
    }

    /// Global screen point → box space on `display` (inverse of `screenPoint`, used to seed the
    /// pointer where the real mouse is).
    public static func boxPoint(fromScreen p: Point2, on display: DisplayInfo) -> Point2 {
        let f = display.frame
        return Point2((p.x - f.minX) / max(f.width - 1, 1), (p.y - f.minY) / max(f.height - 1, 1))
    }
}

/// Calibration profiles keyed by display id, with a fallback default.
public struct CalibrationSet: Equatable, Codable {
    public var profiles: [String: CalibrationProfile]
    public var fallback: CalibrationProfile

    public init(profiles: [String: CalibrationProfile] = [:],
                fallback: CalibrationProfile = .defaultProfile()) {
        self.profiles = profiles
        self.fallback = fallback
    }

    public func profile(for displayID: String) -> CalibrationProfile {
        profiles[displayID] ?? fallback
    }
}

// MARK: - Interactive calibration

/// Drives the four-corner calibration from a stream of fingertip positions.
///
/// For each corner, waits a short settle time (the user is moving there), then captures once the
/// fingertip has been still for `stillDuration`. The captured point is the median of the still
/// window, which rejects the occasional landmark glitch. Each corner times out so the flow can
/// never hang; a timed-out corner is reported so the UI can fall back to defaults.
public struct CornerCalibrationSession {
    public enum Status: Equatable {
        case collecting(corner: Int, stillProgress: Double)
        case finished(CalibrationProfile)
        case failed(reason: String)
    }

    public var settleDuration = 0.8
    public var stillDuration = 0.6
    public var stillRadius = 0.012       // normalized image units
    public var cornerTimeout = 7.0

    public private(set) var cornerIndex = 0
    public private(set) var captured: [Point2] = []
    private var cornerStart: Double?
    private var window: [(time: Double, point: Point2)] = []

    public init() {}

    /// Feed the pointing fingertip (camera space) or nil when no hand is visible.
    public mutating func process(fingertip: Point2?, at time: Double) -> Status {
        if cornerIndex >= 4 { return finish() }
        if cornerStart == nil { cornerStart = time }
        let elapsed = time - (cornerStart ?? time)
        if elapsed > cornerTimeout {
            return .failed(reason: "Couldn't see a steady finger for corner \(cornerIndex + 1)")
        }
        guard let tip = fingertip, elapsed >= settleDuration else {
            if fingertip == nil { window.removeAll() }
            return .collecting(corner: cornerIndex, stillProgress: 0)
        }
        window.append((time, tip))
        // Drop samples that are no longer within the still window, and restart the window
        // whenever the newest sample leaves the neighbourhood of the window's median.
        window.removeAll { time - $0.time > stillDuration + 0.1 }
        let center = Self.median(window.map { $0.point })
        if window.contains(where: { $0.point.distance(to: center) > stillRadius }) {
            window = [(time, tip)]
            return .collecting(corner: cornerIndex, stillProgress: 0)
        }
        let span = time - (window.first?.time ?? time)
        if span >= stillDuration {
            captured.append(center)
            cornerIndex += 1
            cornerStart = time
            window.removeAll()
            if cornerIndex >= 4 { return finish() }
            return .collecting(corner: cornerIndex, stillProgress: 0)
        }
        return .collecting(corner: cornerIndex, stillProgress: min(span / stillDuration, 1))
    }

    private func finish() -> Status {
        let profile = CalibrationProfile(corners: captured, isCalibrated: true)
        return profile.isUsable
            ? .finished(profile)
            : .failed(reason: "The four corners didn't form a usable box; try pointing more widely")
    }

    static func median(_ points: [Point2]) -> Point2 {
        guard !points.isEmpty else { return .zero }
        let xs = points.map { $0.x }.sorted(), ys = points.map { $0.y }.sorted()
        return Point2(xs[xs.count / 2], ys[ys.count / 2])
    }
}
