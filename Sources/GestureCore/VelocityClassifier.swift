import Foundation

/// What one fast segment means on its own (SPEC-M7 → Classification). Composite gestures
/// (double click, drag, zoom) are layered on top by `VelocityEngine`.
public enum SegmentClass: Equatable {
    case leftClick
    case rightClick
    /// `direction` is a unit vector along the flick's axis in hand space (x right, y down).
    case scroll(direction: Point2)
    case reposition
}

/// Pure classification of a finished segment. No state: the same stats always give the same
/// answer, which is what lets `tune` grid-search thresholds against a recording.
public enum VelocityClassifier {
    public struct Result: Equatable {
        public var segmentClass: SegmentClass
        public var axis: SegmentAxis
        /// The rule that decided, in words, for the "why not?" overlay.
        public var rule: String
    }

    public static func axis(of v: Point2, ratio: Double) -> SegmentAxis {
        if abs(v.y) > ratio * abs(v.x) { return .vertical }
        if abs(v.x) > ratio * abs(v.y) { return .horizontal }
        return .ambiguous
    }

    public static func classify(_ s: SegmentStats, _ p: VelocityParams) -> Result {
        // The dominant axis comes from the furthest point reached, not the end point: a tap
        // comes back to (almost) where it started, so its net displacement has no direction.
        let axis = Self.axis(of: s.excursion, ratio: p.axisRatio)
        func result(_ c: SegmentClass, _ rule: String) -> Result { Result(segmentClass: c, axis: axis, rule: rule) }

        guard s.confident else { return result(.reposition, "ignored: low confidence at anchor or peak") }

        let tapShaped = s.duration < p.clickMaxDuration && s.distance < p.clickMaxDisp && s.pathLength < p.clickMaxPath
        if tapShaped {
            guard s.startedFromStill else {
                return result(.reposition, "no click: hand wasn't still for \(ms(p.preClickStillTime)) before")
            }
            switch (p.clickAxis, axis) {
            case (_, .ambiguous):
                return result(.reposition, "no click: tap direction is diagonal")
            case (.any, _), (.vertical, .vertical), (.horizontal, .horizontal):
                return result(.leftClick, "click: short tap from stillness")
            case (.vertical, .horizontal), (.horizontal, .vertical):
                return p.rightClickEnabled
                    ? result(.rightClick, "right click: short cross-axis tap")
                    : result(.reposition, "no click: right click is off")
            }
        }

        // A scroll is measured on the flick itself: the excursion if the hand came back,
        // otherwise where it ended up.
        let travel = s.reversed ? s.excursion : s.displacement
        if travel.length >= p.scrollMinDisp {
            switch Self.axis(of: travel, ratio: p.axisRatio) {
            case .vertical where s.reversed || s.peakSpeed > p.scrollMinPeak:
                return result(.scroll(direction: Point2(0, travel.y < 0 ? -1 : 1)), "scroll: long vertical flick")
            case .vertical:
                return result(.reposition, "no scroll: vertical move too slow and didn't come back")
            case .horizontal where s.reversed:
                return result(.scroll(direction: Point2(travel.x < 0 ? -1 : 1, 0)), "scroll: horizontal flick and return")
            case .horizontal:
                return result(.reposition, "reposition: horizontal move without return")
            case .ambiguous:
                return result(.reposition, "reposition: diagonal move")
            }
        }
        if s.duration >= p.clickMaxDuration && s.distance < p.clickMaxDisp {
            return result(.reposition, "no click: tap took \(ms(s.duration)) (max \(ms(p.clickMaxDuration)))")
        }
        return result(.reposition, "reposition")
    }

    private static func ms(_ seconds: Double) -> String { "\(Int((seconds * 1000).rounded())) ms" }
}
