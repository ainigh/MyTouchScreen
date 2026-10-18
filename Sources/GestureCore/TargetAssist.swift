import Foundation

/// What kind of control an on-screen target is. The app reads it from the Accessibility role;
/// the kind decides how likely the target is to be clicked (`priority`) and whether the user
/// wants help with it at all (`TargetAssistParams.kinds`).
public enum TargetKind: String, Codable, CaseIterable, Equatable {
    /// Push buttons, pop-up buttons, menu buttons, Dock items.
    case button
    /// Web and text links.
    case link
    /// Menu items and menu-bar titles.
    case menuItem
    /// Checkboxes, radio buttons, switches, tabs, disclosure triangles.
    case toggle
    /// Text fields, search fields, combo boxes, text areas.
    case field
    /// Rows of lists, tables and outlines (Finder files, mail messages).
    case listItem
    /// Anything else that says it can be pressed (images, labels, groups).
    case other

    public var title: String {
        switch self {
        case .button: return "Buttons"
        case .link: return "Links"
        case .menuItem: return "Menus"
        case .toggle: return "Checkboxes, tabs & switches"
        case .field: return "Text fields"
        case .listItem: return "List rows"
        case .other: return "Other clickable things"
        }
    }

    /// How likely a target of this kind is to be what the hand is reaching for. Small, distinct
    /// controls rank highest; rows and generic pressables are often crossed on the way to
    /// something else.
    public var priority: Double {
        switch self {
        case .button: return 1.0
        case .menuItem: return 0.95
        case .toggle: return 0.9
        case .link: return 0.85
        case .field: return 0.7
        case .other: return 0.6
        case .listItem: return 0.5
        }
    }
}

/// One clickable thing on screen, in CoreGraphics global points (top-left origin, the space
/// `CGEvent` uses).
public struct AssistTarget: Equatable, Codable {
    /// Stable for the same element across scans (the app uses the element's hash), so the
    /// assist can stay on one target and remember which ones were clicked.
    public var id: Int
    public var frame: Rect
    public var kind: TargetKind
    /// The window's default button (Return presses it): more likely to be clicked.
    public var isDefault: Bool

    public init(id: Int, frame: Rect, kind: TargetKind, isDefault: Bool = false) {
        self.id = id
        self.frame = frame
        self.kind = kind
        self.isDefault = isDefault
    }

    private enum CodingKeys: String, CodingKey { case id = "i", frame = "f", kind = "k", isDefault = "d" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        let f = try c.decode([Double].self, forKey: .frame)
        guard f.count == 4 else {
            throw DecodingError.dataCorruptedError(forKey: .frame, in: c, debugDescription: "Expected [x, y, w, h]")
        }
        frame = Rect(x: f[0], y: f[1], width: f[2], height: f[3])
        kind = try c.decodeIfPresent(TargetKind.self, forKey: .kind) ?? .other
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode([frame.x, frame.y, frame.width, frame.height].map { HandFrame.round($0, 1) }, forKey: .frame)
        try c.encode(kind, forKey: .kind)
        if isDefault { try c.encode(true, forKey: .isDefault) }
    }

    /// Distance from `p` to the nearest point of the target (0 inside).
    func distance(to p: Point2) -> Double {
        nearestPoint(to: p).distance(to: p)
    }

    func nearestPoint(to p: Point2) -> Point2 {
        Point2(clamp(p.x, frame.minX, frame.maxX), clamp(p.y, frame.minY, frame.maxY))
    }

    /// Where the magnet pulls: the nearest point of the target's middle (`coreFraction` of each
    /// side), so a wide field or menu item pulls the cursor inside without dragging it to the
    /// centre along its length.
    func aimPoint(from p: Point2) -> Point2 {
        let insetX = frame.width * (1 - TargetAssist.coreFraction) / 2
        let insetY = frame.height * (1 - TargetAssist.coreFraction) / 2
        return Point2(clamp(p.x, frame.minX + insetX, frame.maxX - insetX),
                      clamp(p.y, frame.minY + insetY, frame.maxY - insetY))
    }
}

/// The settings for target assist (all exposed in Settings → Pointer for experimenting).
public struct TargetAssistParams: Equatable, Codable {
    public var enabled = true
    /// 0…1: how much the cursor slows down over (and on the way into) a target. At 1 the cursor
    /// moves at a fifth of the hand's speed while on a button.
    public var slowdown = 0.5
    /// 0…1: how far a slowing cursor is pulled into the nearest likely target from: a resting
    /// cursor within `magnet × reachPoints` of a target snaps into it, fading out to the reach.
    public var magnet = 0.4
    /// How far from a target's edge (points) it starts to act.
    public var reachPoints = 36.0
    /// 0…1: how much the direction of travel matters. High: targets the cursor is heading for
    /// act from further away, and the ones it passes beside are ignored.
    public var anticipation = 0.5
    /// 0…1: how quickly the cursor gets back under the finger after a slowdown, as a fraction
    /// of the hand's travel once it is clear of targets.
    public var catchUp = 0.5
    /// The kinds of control that get help.
    public var kinds: [TargetKind] = [.button, .link, .menuItem, .toggle, .field]

    public init() {}

    /// Lenient decoding: settings files from before a key existed keep its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TargetAssistParams()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        slowdown = try c.decodeIfPresent(Double.self, forKey: .slowdown) ?? d.slowdown
        magnet = try c.decodeIfPresent(Double.self, forKey: .magnet) ?? d.magnet
        reachPoints = try c.decodeIfPresent(Double.self, forKey: .reachPoints) ?? d.reachPoints
        anticipation = try c.decodeIfPresent(Double.self, forKey: .anticipation) ?? d.anticipation
        catchUp = try c.decodeIfPresent(Double.self, forKey: .catchUp) ?? d.catchUp
        // Unknown kind names (from a newer version) are dropped rather than failing the file.
        let names = try c.decodeIfPresent([String].self, forKey: .kinds)
        kinds = names.map { $0.compactMap(TargetKind.init(rawValue:)) } ?? d.kinds
    }

    /// Every value in its usable range: imported files or replays can carry anything.
    var sanitized: TargetAssistParams {
        var p = self
        func unit(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? clamp01(v) : fallback }
        p.slowdown = unit(slowdown, 0.5)
        p.magnet = unit(magnet, 0.4)
        p.anticipation = unit(anticipation, 0.5)
        p.catchUp = unit(catchUp, 0.5)
        p.reachPoints = reachPoints.isFinite ? clamp(reachPoints, 0, 200) : 36
        return p
    }
}

/// The target the cursor is drawn to, for the overlay.
public struct AssistFocus: Equatable {
    public var target: AssistTarget
    /// 0…1: how strongly it acts right now.
    public var strength: Double
}

/// Makes clickable things easier to hit, between the smoothed pointer and the screen:
///
/// 1. **Slowdown** — near a likely target the cursor moves by a fraction of the hand's motion
///    (lower control-display gain), so the same hand movement aims more finely there. Targets
///    the cursor is heading for slow it down from further away (`anticipation`); targets it
///    flies past sideways, and very fast flicks, are left alone.
/// 2. **Catch-up** — the motion the slowdown held back leaves the cursor short of where the
///    finger points. Once clear of targets the cursor makes it up from the hand's own movement
///    (never on its own while the hand is still), so it ends up back under the finger.
/// 3. **Magnet** — as the hand slows near a target, the shown cursor is pulled into the target's
///    middle. The pull is recomputed every frame rather than accumulated, so moving the hand
///    away always lets go.
///
/// A target only acts while the finger itself is near it too, and the slowdown holds back at
/// most `holdBackEnd` points of hand travel: a cursor left inside a button lets go once the
/// finger is well past it, so the hand can always move on.
///
/// One target acts at a time: the best by priority (kind, size, default button, recently
/// clicked) × proximity × heading, with hysteresis so neighbours don't tug the cursor back
/// and forth. Everything is in screen points; timing comes from frame timestamps.
public struct TargetAssist {
    public var params: TargetAssistParams {
        didSet { params = params.sanitized }
    }
    public private(set) var targets: [AssistTarget] = []
    public private(set) var focus: AssistFocus?

    /// The assisted cursor before the magnet's pull.
    private var cursor: Point2?
    private var lastFinger: Point2?
    private var lastTime: Double?
    /// Smoothed finger velocity, points per second.
    private var velocity = Point2.zero
    /// The magnet's current displacement (smoothed toward the wanted one).
    private var pull = Point2.zero
    private var focusID: Int?
    /// Targets clicked recently, by id → time of the click.
    private var clicked: [Int: Double] = [:]

    // Tuning constants. Speeds are finger speeds in points per second.
    /// The slowdown at full strength leaves this much of the hand's motion.
    static let minimumGain = 0.2
    /// Below this speed there is no direction of travel to speak of.
    static let headingSpeedLow = 100.0
    static let headingSpeedHigh = 500.0
    /// How far ahead (seconds of travel at the current speed) a target being headed for acts…
    static let lookaheadTime = 0.2
    /// …at most this many reach radii further out.
    static let lookaheadMaxReach = 3.0
    /// Flicks faster than this start to ignore targets entirely (crossing the screen).
    static let flickSpeedLow = 1500.0
    static let flickSpeedHigh = 3500.0
    /// The magnet works on a slowing hand: full below the low speed, gone above the high one.
    static let magnetSpeedLow = 150.0
    static let magnetSpeedHigh = 700.0
    /// Below this magnet setting the pull is partial as well as short-ranged, so the low end of
    /// the slider fades it out instead of switching it off at 0.
    static let fullPullMagnet = 0.34
    /// A target starts to let go once the finger is `releaseStart` beyond its reach, and has let
    /// go `releaseDistance` further on (points).
    static let releaseStart = 30.0
    static let releaseDistance = 90.0
    /// The slowdown fades out as the cursor falls this far behind the finger (points).
    static let holdBackStart = 45.0
    static let holdBackEnd = 110.0
    /// Fraction of each side of a target the magnet aims for (its middle).
    static let coreFraction = 0.4
    /// Time constants of the velocity estimate and the magnet's pull.
    static let velocityTime = 0.05
    static let pullTime = 0.05
    /// A new target takes over only when it scores this much better than the current one.
    static let switchMargin = 1.3
    /// Catch-up runs only once the cursor is clear of targets (influence below this)…
    static let clearInfluence = 0.15
    /// …and at full setting makes up this fraction of the hand's travel (below 1, so reversing
    /// toward the cursor never moves it backwards).
    static let maxCatchUp = 0.9
    /// The cursor never strays further than this from where the finger points.
    static let maxOffset = 160.0
    /// Targets wider or taller than these aren't controls (whole panes that happen to be
    /// pressable): no help.
    static let maxTargetSide = 600.0
    static let maxTargetArea = 300.0 * 300.0
    /// Small targets need the most help: full weight up to `easySide`, falling to
    /// `largeTargetWeight` at `easySide + largeSideSpan`.
    static let easySide = 24.0
    static let largeSideSpan = 96.0
    static let largeTargetWeight = 0.6
    static let defaultButtonBoost = 1.15
    static let recentClickBoost = 1.2
    static let recentClickMemory = 600.0
    static let recentClickCapacity = 32

    public init(params: TargetAssistParams = TargetAssistParams()) {
        self.params = params.sanitized
    }

    /// The cursor is under the finger again (engaging, a display jump, a drag, a held click
    /// point, the real mouse): forget the offset and the pull.
    public mutating func reset() {
        cursor = nil
        lastFinger = nil
        lastTime = nil
        velocity = .zero
        pull = .zero
        focus = nil
        focusID = nil
    }

    public mutating func setTargets(_ targets: [AssistTarget]) {
        self.targets = targets
    }

    /// A click landed at `point`: the target there counts as recently clicked, so it ranks
    /// higher next time.
    public mutating func noteClick(at point: Point2, time: Double) {
        guard let target = targets.first(where: { $0.frame.contains(point) }) else { return }
        clicked[target.id] = time
        if clicked.count > Self.recentClickCapacity,
           let oldest = clicked.min(by: { $0.value < $1.value }) {
            clicked[oldest.key] = nil
        }
    }

    /// Where the cursor should be shown, given where the (smoothed) finger points this frame.
    /// `bounds` is the display the cursor is on.
    public mutating func process(finger: Point2, at time: Double, bounds: Rect) -> Point2 {
        guard params.enabled else {
            reset()
            return finger
        }
        guard let previousFinger = lastFinger, let previousCursor = cursor else {
            cursor = finger
            lastFinger = finger
            lastTime = time
            return finger
        }
        let dt = min(max(time - (lastTime ?? time), 0), 0.1)
        let moved = finger - previousFinger
        lastFinger = finger
        lastTime = time
        if dt > 0 {
            let follow = 1 - exp(-dt / Self.velocityTime)
            velocity += (moved / dt - velocity) * follow
        }
        let speed = velocity.length

        // 1. Slowdown, from the best target around the cursor.
        let chosen = chooseTarget(near: previousCursor, finger: finger, speed: speed)
        let lag = previousCursor.distance(to: previousFinger)
        let holdBack = 1 - smoothstep(Self.holdBackStart, Self.holdBackEnd, lag)
        let influence = (chosen?.score ?? 0) * holdBack
        let flickRelief = 1 - smoothstep(Self.flickSpeedLow, Self.flickSpeedHigh, speed)
        let gain = 1 - (1 - Self.minimumGain) * params.slowdown * influence * flickRelief
        var next = previousCursor + moved * gain

        // 2. Catch-up: away from targets, part of the hand's travel brings the cursor back under
        //    the finger.
        var offset = next - finger
        let clear = 1 - smoothstep(0, Self.clearInfluence, influence)
        let catchUp = moved.length * params.catchUp * Self.maxCatchUp * clear
        if offset.length > 0 {
            let reduced = max(offset.length - catchUp, 0)
            offset = offset * (min(reduced, Self.maxOffset) / offset.length)
            next = finger + offset
        }
        next = Self.keep(next, in: bounds)
        cursor = next

        // 3. Magnet, recomputed from scratch each frame.
        var wantedPull = Point2.zero
        if let chosen {
            let slowness = 1 - smoothstep(Self.magnetSpeedLow, Self.magnetSpeedHigh, speed)
            let strength = chosen.capture * min(params.magnet / Self.fullPullMagnet, 1) * slowness
            wantedPull = (chosen.target.aimPoint(from: next) - next) * strength
        }
        if dt > 0 {
            pull += (wantedPull - pull) * (1 - exp(-dt / Self.pullTime))
        }
        focusID = chosen?.target.id
        focus = chosen.map { AssistFocus(target: $0.target, strength: clamp01(max($0.score, $0.capture * params.magnet))) }
        return Self.keep(next + pull, in: bounds)
    }

    // MARK: Choosing a target

    struct Candidate {
        var target: AssistTarget
        /// Kind × size × default × recently clicked.
        var weight: Double
        /// 0…1 by distance alone.
        var proximity: Double
        /// 0…1: how much it slows the cursor (weight, distance and heading together).
        var score: Double
        /// 0…1: how much of the way into the target the magnet pulls a still cursor.
        var capture: Double
    }

    private func chooseTarget(near point: Point2, finger: Point2, speed: Double) -> Candidate? {
        let reach = params.reachPoints
        let heading = speed > 1e-6 ? velocity / speed : .zero
        let motion = smoothstep(Self.headingSpeedLow, Self.headingSpeedHigh, speed)
        let kinds = Set(params.kinds)
        var best: Candidate?
        var current: Candidate?
        for target in targets where kinds.contains(target.kind) {
            guard let weight = weight(of: target) else { continue }
            let nearest = target.nearestPoint(to: point)
            let distance = nearest.distance(to: point)
            // Alignment: 1 straight ahead (or inside, or no clear direction), 0 beside or behind.
            var alignment = 1.0
            if distance > 0 && motion > 0 {
                let toward = (nearest - point) / distance
                alignment = 1 - motion * (1 - max(0, toward.x * heading.x + toward.y * heading.y))
            }
            let lookahead = params.anticipation * alignment * min(speed * Self.lookaheadTime, reach * Self.lookaheadMaxReach)
            let effectiveReach = reach + lookahead
            // The finger has moved on well past the target: let go.
            let releaseFrom = reach + Self.releaseStart
            let release = 1 - smoothstep(releaseFrom, releaseFrom + Self.releaseDistance, target.distance(to: finger))
            let proximity = Self.proximity(distance, reach: reach) * release
            let headedProximity = Self.proximity(distance, reach: effectiveReach) * release
            let headingFactor = 1 - params.anticipation * (1 - alignment)
            let score = min(headedProximity * headingFactor * weight, 1)
            let captureReach = reach * params.magnet
            let capture = (1 - smoothstep(captureReach, max(reach, captureReach + 1), distance)) * release
            guard score > 0 || proximity > 0 else { continue }
            let candidate = Candidate(target: target, weight: weight, proximity: proximity, score: score,
                                      capture: capture)
            if target.id == focusID { current = candidate }
            if best.map({ Self.rank(candidate) > Self.rank($0) }) ?? true { best = candidate }
        }
        // Stay on the current target unless another is clearly better.
        if let current, let best, best.target.id != current.target.id,
           Self.rank(best) < Self.rank(current) * Self.switchMargin, Self.rank(current) > 0 {
            return current
        }
        return best
    }

    private static func rank(_ c: Candidate) -> Double { max(c.score, c.proximity * min(c.weight, 1) * 0.5) }

    /// How likely `target` is to be clicked, or nil when it's no control at all (too big).
    func weight(of target: AssistTarget) -> Double? {
        let w = target.frame.width, h = target.frame.height
        guard w >= 2, h >= 2, max(w, h) <= Self.maxTargetSide, w * h <= Self.maxTargetArea else { return nil }
        let sizeWeight = 1 - (1 - Self.largeTargetWeight) * clamp01((min(w, h) - Self.easySide) / Self.largeSideSpan)
        var weight = target.kind.priority * sizeWeight
        if target.isDefault { weight *= Self.defaultButtonBoost }
        if let when = clicked[target.id], let now = lastTime, now - when <= Self.recentClickMemory {
            weight *= Self.recentClickBoost
        }
        return weight
    }

    /// 1 inside the target, falling smoothly to 0 at `reach` points from its edge.
    static func proximity(_ distance: Double, reach: Double) -> Double {
        guard distance > 0 else { return 1 }
        guard reach > 0, distance < reach else { return 0 }
        let t = 1 - distance / reach
        return t * t * (3 - 2 * t)
    }

    static func keep(_ p: Point2, in bounds: Rect) -> Point2 {
        Point2(clamp(p.x, bounds.minX, bounds.maxX - 1), clamp(p.y, bounds.minY, bounds.maxY - 1))
    }
}

/// 0 at or below `low`, 1 at or above `high`, smooth in between.
func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
    let t = clamp01((value - low) / (high - low))
    return t * t * (3 - 2 * t)
}
