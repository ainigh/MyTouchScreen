import XCTest
@testable import GestureCore

/// Target assist: slows the cursor near likely targets, pulls a slowing cursor in, lets go
/// when the hand moves away, and gets the cursor back under the finger afterwards.
final class TargetAssistTests: XCTestCase {
    private let screen = Rect(x: 0, y: 0, width: 1728, height: 1117)
    private let fps = 60.0

    private func button(_ id: Int = 1, x: Double, y: Double, width: Double = 40, height: Double = 24,
                        kind: TargetKind = .button) -> AssistTarget {
        AssistTarget(id: id, frame: Rect(x: x, y: y, width: width, height: height), kind: kind)
    }

    /// Feeds `finger(t)` for `duration` seconds and returns every shown point.
    @discardableResult
    private func run(_ assist: inout TargetAssist, from start: Double = 0, duration: Double,
                     finger: (Double) -> Point2) -> [Point2] {
        (0..<Int((duration * fps).rounded())).map { i in
            let t = start + Double(i) / fps
            return assist.process(finger: finger(t), at: t, bounds: screen)
        }
    }

    /// Constant-speed line from `a` to `b` over `duration`, then held at `b`.
    private func line(_ a: Point2, _ b: Point2, duration: Double, start: Double = 0) -> (Double) -> Point2 {
        { t in a.lerp(to: b, clamp01((t - start) / duration)) }
    }

    func testNoTargetsLeavesTheLaserPointerAlone() {
        var assist = TargetAssist()
        let path = line(Point2(100, 500), Point2(1500, 300), duration: 1)
        let shown = run(&assist, duration: 1.5, finger: path)
        for (i, p) in shown.enumerated() {
            XCTAssertEqual(p.distance(to: path(Double(i) / fps)), 0, accuracy: 1e-9)
        }
    }

    func testDisabledLeavesTheLaserPointerAlone() {
        var params = TargetAssistParams()
        params.enabled = false
        var assist = TargetAssist(params: params)
        assist.setTargets([button(x: 400, y: 488)])
        let path = line(Point2(300, 500), Point2(600, 500), duration: 1)
        let shown = run(&assist, duration: 1, finger: path)
        for (i, p) in shown.enumerated() {
            XCTAssertEqual(p.distance(to: path(Double(i) / fps)), 0, accuracy: 1e-9)
        }
    }

    /// On a button, the same hand movement moves the cursor less (finer aim); at the default
    /// strength too, and in proportion to the setting.
    func testSlowsDownOverAButton() {
        func travel(slowdown: Double) -> Double {
            var params = TargetAssistParams()
            params.magnet = 0
            params.slowdown = slowdown
            var assist = TargetAssist(params: params)
            assist.setTargets([button(x: 400, y: 488, width: 80)])
            run(&assist, duration: 0.5, finger: { _ in Point2(420, 500) })
            // 30 pt at 100 pt/s, slow aiming within the button.
            let shown = run(&assist, from: 0.5, duration: 0.6, finger: line(Point2(420, 500), Point2(450, 500), duration: 0.3, start: 0.5))
            return shown.last!.x - 420
        }
        XCTAssertEqual(travel(slowdown: 0), 30, accuracy: 0.01)
        XCTAssertLessThan(travel(slowdown: 0.5), 20)
        XCTAssertLessThan(travel(slowdown: 1), 8)
    }

    /// Crossing a big button at full slowdown: the cursor falls behind, but never more than the
    /// hold-back budget, so the hand can always move on.
    func testSlowdownNeverTrapsTheCursor() {
        var params = TargetAssistParams()
        params.magnet = 0
        params.slowdown = 1
        var assist = TargetAssist(params: params)
        assist.setTargets([button(x: 400, y: 440, width: 300, height: 120)])
        let path = line(Point2(300, 500), Point2(900, 500), duration: 3)
        let shown = run(&assist, duration: 3, finger: path)
        for (i, p) in shown.enumerated() {
            XCTAssertLessThan(p.distance(to: path(Double(i) / fps)), TargetAssist.holdBackEnd)
        }
    }

    /// After the slowdown, moving on brings the cursor back under the finger; a still hand
    /// never makes it drift there on its own.
    func testCatchesUpWithHandMotionOnlyAndNeverDriftsAtRest() {
        var params = TargetAssistParams()
        params.magnet = 0
        params.slowdown = 1
        var assist = TargetAssist(params: params)
        assist.setTargets([button(x: 400, y: 488, width: 80)])
        // Across the button and stop well past it.
        var shown = run(&assist, duration: 1.2, finger: line(Point2(300, 500), Point2(560, 500), duration: 1.2))
        let lag = Point2(560, 500).distance(to: shown.last!)
        XCTAssertGreaterThan(lag, 20, "the slowdown left the cursor behind the finger")
        // Hand still: the cursor doesn't move.
        shown = run(&assist, from: 1.2, duration: 1, finger: { _ in Point2(560, 500) })
        XCTAssertEqual(shown.first!.distance(to: shown.last!), 0, accuracy: 0.01)
        // Moving on, clear of the button: back under the finger.
        shown = run(&assist, from: 2.2, duration: 1, finger: line(Point2(560, 500), Point2(900, 500), duration: 0.8, start: 2.2))
        XCTAssertEqual(shown.last!.distance(to: Point2(900, 500)), 0, accuracy: 1)
    }

    /// A hand that stops just beside a button puts the cursor inside it; the cursor then holds
    /// still; and moving away lets go completely.
    func testMagnetPullsAStoppingCursorInAndLetsGo() {
        var params = TargetAssistParams()
        params.magnet = 1
        params.slowdown = 0
        var assist = TargetAssist(params: params)
        let target = button(x: 400, y: 488)
        assist.setTargets([target])
        // Arrive 10 pt short of the button's left edge, and rest there.
        run(&assist, duration: 0.6, finger: line(Point2(250, 500), Point2(390, 500), duration: 0.5))
        let rest = run(&assist, from: 0.6, duration: 1, finger: { _ in Point2(390, 500) })
        XCTAssertTrue(target.frame.contains(rest.last!), "rested at \(rest.last!)")
        let lastHalf = rest.suffix(30)
        XCTAssertEqual(lastHalf.first!.distance(to: lastHalf.last!), 0, accuracy: 0.25, "rock steady at rest")
        // Move away (down, out of reach) and stop: the cursor is back on the finger.
        let away = run(&assist, from: 1.6, duration: 1, finger: line(Point2(390, 500), Point2(390, 700), duration: 0.5, start: 1.6))
        XCTAssertEqual(away.last!.distance(to: Point2(390, 700)), 0, accuracy: 1)
    }

    /// Heading straight for a target slows the cursor sooner than passing beside it.
    func testAnticipatesTheTargetBeingHeadedFor() {
        var params = TargetAssistParams()
        params.magnet = 0
        params.slowdown = 1
        params.anticipation = 1
        let target = button(x: 600, y: 488)
        // Toward the target, 600 pt/s, stopping 60 pt short of it (beyond reach at rest).
        var toward = TargetAssist(params: params)
        toward.setTargets([target])
        let towardShown = run(&toward, duration: 0.7, finger: line(Point2(240, 500), Point2(540, 500), duration: 0.5))
        // The same speed, passing 88 pt beside its bottom edge.
        var beside = TargetAssist(params: params)
        beside.setTargets([target])
        let besideShown = run(&beside, duration: 0.7, finger: line(Point2(450, 600), Point2(750, 600), duration: 0.5))
        let towardTravel = towardShown.last!.x - towardShown.first!.x
        let besideTravel = besideShown.last!.x - besideShown.first!.x
        XCTAssertLessThan(towardTravel, 295, "heading for a target slows before reaching it")
        XCTAssertEqual(besideTravel, 300, accuracy: 0.5, "passing beside a target is not slowed")
    }

    /// A fast flick across the screen is not slowed by buttons on the way.
    func testFlicksIgnoreTargets() {
        var params = TargetAssistParams()
        params.slowdown = 1
        var assist = TargetAssist(params: params)
        assist.setTargets((0..<10).map { button($0, x: 300 + Double($0) * 100, y: 488) })
        // 5000 pt/s.
        let shown = run(&assist, duration: 0.25, finger: line(Point2(100, 500), Point2(1350, 500), duration: 0.25))
        XCTAssertGreaterThan(shown.last!.x, 1100)
    }

    /// Between a button and a list row at the same distance, the button wins; a target too big
    /// to be a control, or of a kind that's switched off, gets no help.
    func testPrioritisesLikelyTargets() {
        var assist = TargetAssist()
        let row = button(1, x: 300, y: 470, width: 40, height: 20, kind: .listItem)
        let btn = button(2, x: 360, y: 470, width: 40, height: 20, kind: .button)
        var params = TargetAssistParams()
        params.kinds = [.button, .listItem]
        assist.params = params
        assist.setTargets([row, btn])
        run(&assist, duration: 0.5, finger: { _ in Point2(350, 480) })
        XCTAssertEqual(assist.focus?.target.id, 2)

        let pane = button(3, x: 0, y: 0, width: 900, height: 700)
        XCTAssertNil(assist.weight(of: pane))
        params.kinds = [.button]
        assist.params = params
        assist.setTargets([button(4, x: 360, y: 470, kind: .link)])
        run(&assist, from: 0.5, duration: 0.5, finger: { _ in Point2(350, 480) })
        XCTAssertNil(assist.focus)
    }

    /// The default button and recently clicked targets rank higher.
    func testDefaultAndRecentlyClickedRankHigher() {
        var assist = TargetAssist()
        let plain = button(1, x: 300, y: 470)
        let preferred = AssistTarget(id: 2, frame: plain.frame, kind: .button, isDefault: true)
        assist.setTargets([plain, preferred])
        run(&assist, duration: 0.1, finger: { _ in Point2(320, 480) })
        XCTAssertGreaterThan(assist.weight(of: preferred)!, assist.weight(of: plain)!)
        let before = assist.weight(of: plain)!
        assist.noteClick(at: Point2(310, 480), time: 0.1)
        XCTAssertGreaterThan(assist.weight(of: plain)! + assist.weight(of: preferred)!, before + assist.weight(of: preferred)!)
    }

    /// Wild settings (an edited file) are kept in range.
    func testParamsAreSanitized() {
        var params = TargetAssistParams()
        params.slowdown = 7
        params.magnet = .nan
        params.reachPoints = -5
        let assist = TargetAssist(params: params)
        XCTAssertEqual(assist.params.slowdown, 1)
        XCTAssertEqual(assist.params.magnet, 0.4)
        XCTAssertEqual(assist.params.reachPoints, 0)
    }

    func testSettingsDecodeLeniently() throws {
        let old = try GestureConfig.decodeLenient(Data(#"{"boxScale": 0.9}"#.utf8))
        XCTAssertEqual(old.assist, TargetAssistParams())
        let partial = try GestureConfig.decodeLenient(Data(#"{"assist": {"magnet": 0.9, "kinds": ["link", "hologram"]}}"#.utf8))
        XCTAssertEqual(partial.assist.magnet, 0.9)
        XCTAssertEqual(partial.assist.slowdown, TargetAssistParams().slowdown)
        XCTAssertEqual(partial.assist.kinds, [.link])
    }

    func testTargetsRoundTripInRecordings() throws {
        let hand = SyntheticHand.pointing(tipAt: Point2(0.5, 0.5)).frame(at: 1)
        let frame = TrackingFrame(timestamp: 1, hands: [hand],
                                  targets: [AssistTarget(id: -42, frame: Rect(x: 10, y: 20, width: 30.5, height: 40), kind: .link, isDefault: true)])
        let data = try Recording(frames: [frame, TrackingFrame(timestamp: 2, hands: [hand])]).encoded()
        let decoded = try Recording.decode(data)
        XCTAssertEqual(decoded.frames[0].targets, frame.targets)
        XCTAssertNil(decoded.frames[1].targets)
    }

    // MARK: In the state machine

    /// The pointer resting just beside a button ends up on it; with no targets it stays where
    /// the finger points. Targets arrive in the frame stream, as the app (and a replay) sends them.
    func testMachineRestsOnANearbyButton() {
        let frames = SyntheticStream.steady(tip: Point2(0.5, 0.45), duration: 2)
        let plain = engagedMachine()
        drive(plain, frames)
        guard let resting = plain.snapshot.cursor else { return XCTFail("no cursor") }

        let target = button(x: resting.x + 12, y: resting.y - 12)
        var withTargets = frames
        withTargets[0].targets = [target]
        let assisted = engagedMachine()
        drive(assisted, withTargets)
        guard let cursor = assisted.snapshot.cursor else { return XCTFail("no cursor") }
        XCTAssertTrue(target.frame.contains(cursor), "cursor \(cursor) not in \(target.frame)")
        XCTAssertEqual(assisted.snapshot.assistFocus?.target.id, target.id)
    }

    /// A wiggle made with the finger pointing just beside a button clicks the button.
    func testWiggleBesideAButtonClicksIt() {
        let frames = SyntheticStream.wiggleClick()
        guard let plain = drive(engagedMachine(), frames).clicks.first else { return XCTFail("no click") }
        for offset in [-20.0, -12, 12, 20] {
            let x = offset > 0 ? plain.0 + offset : plain.0 + offset - 40
            let target = button(x: x, y: plain.1 - 12)
            var withTargets = frames
            withTargets[0].targets = [target]
            let clicks = drive(engagedMachine(), withTargets).clicks
            XCTAssertEqual(clicks.count, 1)
            XCTAssertTrue(clicks.allSatisfy { target.frame.contains(Point2($0.0, $0.1)) }, "offset \(offset): \(clicks)")
        }
    }
}
