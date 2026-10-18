import XCTest
@testable import GestureCore

/// Straight-line trajectory: the cursor moves only horizontally or only vertically, picked by
/// the hand's dominant direction, switching only on a sharp turn.
final class TrajectoryLockTests: XCTestCase {
    private let screen = Rect(x: 0, y: 0, width: 1728, height: 1117)
    private let fps = 60.0

    /// Feeds `finger(t)` for `duration` seconds and returns (finger, shown) per frame.
    @discardableResult
    private func run(_ lock: inout TrajectoryLock, from start: Double = 0, duration: Double,
                     trajectory: Trajectory = .straight, sharpness: Double = 0.5,
                     finger: (Double) -> Point2) -> [(finger: Point2, shown: Point2)] {
        (0..<Int((duration * fps).rounded())).map { i in
            let t = start + Double(i) / fps
            let f = finger(t)
            return (f, lock.process(finger: f, at: t, bounds: screen, trajectory: trajectory, turnSharpness: sharpness))
        }
    }

    func testFreeFollowsTheHand() {
        var lock = TrajectoryLock()
        let frames = run(&lock, duration: 1, trajectory: .free) { t in Point2(200 + 400 * t, 300 + 250 * t) }
        XCTAssertTrue(frames.allSatisfy { $0.finger == $0.shown })
    }

    /// A wavy sideways sweep draws a straight horizontal line.
    func testHorizontalSnakeIsAStraightLine() {
        var lock = TrajectoryLock()
        let frames = run(&lock, duration: 2) { t in Point2(200 + 400 * t, 500 + 30 * sin(2 * .pi * 2 * t)) }
        XCTAssertTrue(frames.allSatisfy { $0.shown.y == 500 }, "y stays put")
        XCTAssertEqual(frames.last!.shown.x, frames.last!.finger.x, accuracy: 0.001, "x follows the hand")
    }

    /// An up-down curve draws a straight vertical line.
    func testVerticalCurveIsAStraightLine() {
        var lock = TrajectoryLock()
        let frames = run(&lock, duration: 1.5) { t in Point2(600 + 60 * sin(.pi * t / 1.5), 200 + 450 * t) }
        XCTAssertTrue(frames.allSatisfy { $0.shown.x == 600 }, "x stays put")
        XCTAssertEqual(frames.last!.shown.y, frames.last!.finger.y, accuracy: 0.001)
    }

    /// A 40° diagonal is mostly horizontal: horizontal, with no vertical creep.
    func testDiagonalPicksTheDominantDirection() {
        var lock = TrajectoryLock()
        let angle = 40 * Double.pi / 180
        let frames = run(&lock, duration: 1) { t in Point2(300 + 500 * t * cos(angle), 400 + 500 * t * sin(angle)) }
        XCTAssertTrue(frames.allSatisfy { $0.shown.y == 400 })
        XCTAssertEqual(lock.axis, .horizontal)
    }

    /// Right, then a sharp turn down: two straight legs, and the cursor ends under the finger
    /// (the dropped start of the turn is made up while moving down).
    func testSharpTurnSwitchesDirection() {
        var lock = TrajectoryLock()
        let right = run(&lock, duration: 0.7) { t in Point2(300 + 500 * min(t, 0.6), 400) }
        let down = run(&lock, from: 0.7, duration: 0.8) { t in Point2(600, 400 + 500 * min(t - 0.7, 0.6)) }
        XCTAssertTrue(right.allSatisfy { $0.shown.y == 400 })
        XCTAssertEqual(lock.axis, .vertical)
        XCTAssertTrue(down.allSatisfy { abs($0.shown.x - right.last!.shown.x) < 0.001 }, "no sideways motion going down")
        XCTAssertEqual(down.last!.shown.distance(to: down.last!.finger), 0, accuracy: 1)
    }

    /// How sharp a turn has to be is a setting: 60° switches at the gentle end, not at the sharp end.
    func testTurnSharpnessSetting() {
        let angle = 60 * Double.pi / 180
        func axisAfterTurn(sharpness: Double) -> TrajectoryLock.Axis? {
            var lock = TrajectoryLock()
            run(&lock, duration: 0.5, sharpness: sharpness) { t in Point2(300 + 500 * t, 400) }
            run(&lock, from: 0.5, duration: 0.5, sharpness: sharpness) { t in
                Point2(550 + 400 * (t - 0.5) * cos(angle), 400 + 400 * (t - 0.5) * sin(angle))
            }
            return lock.axis
        }
        XCTAssertEqual(axisAfterTurn(sharpness: 0), .vertical)
        XCTAssertEqual(axisAfterTurn(sharpness: 1), .horizontal)
    }

    /// After a rest, the next movement goes its own dominant way, no sharp turn needed.
    func testMovingOffFromRestPicksAfresh() {
        var lock = TrajectoryLock()
        run(&lock, duration: 0.5) { t in Point2(300 + 400 * t, 400) }
        run(&lock, from: 0.5, duration: 0.5) { _ in Point2(500, 400) }
        // 40° off vertical: not sharp enough to switch while moving, but mostly vertical.
        let angle = 50 * Double.pi / 180
        run(&lock, from: 1.0, duration: 0.5) { t in Point2(500 + 400 * (t - 1) * cos(angle), 400 + 400 * (t - 1) * sin(angle)) }
        XCTAssertEqual(lock.axis, .vertical)
    }

    /// Tracker-sized jitter on a still hand never moves the cursor.
    func testJitterNeverMovesTheCursor() {
        var lock = TrajectoryLock()
        var rng = SeededRandom(seed: 3)
        let frames = run(&lock, duration: 3) { _ in
            Point2(700 + Double.random(in: -1...1, using: &rng), 500 + Double.random(in: -1...1, using: &rng))
        }
        let first = frames.first!.shown
        XCTAssertTrue(frames.allSatisfy { $0.shown == first })
    }

    func testSettingsDecodeLeniently() throws {
        XCTAssertEqual(GestureConfig().trajectory, .straight, "straight lines by default")
        let old = try GestureConfig.decodeLenient(Data(#"{"boxScale": 0.9}"#.utf8))
        XCTAssertEqual(old.trajectory, .straight)
        let free = try GestureConfig.decodeLenient(Data(#"{"trajectory": "free", "turnSharpness": 0.8}"#.utf8))
        XCTAssertEqual(free.trajectory, .free)
        XCTAssertEqual(free.turnSharpness, 0.8)
    }

    // MARK: In the state machine (default settings)

    /// A sweep that drifts a little vertically moves the cursor horizontally only.
    func testMachineDrawsStraightLines() {
        let machine = engagedMachine()
        let moves = drive(machine, SyntheticStream.ramp(from: Point2(0.65, 0.45), to: Point2(0.35, 0.41), duration: 0.8)).moves
        guard let first = moves.first, let last = moves.last else { return XCTFail("no moves") }
        XCTAssertGreaterThan(abs(last.x - first.x), 300)
        XCTAssertTrue(moves.allSatisfy { $0.y == first.y })
    }

    /// A wiggle still clicks once, and once the hold after the click ends the cursor stays put
    /// for a still hand (no glide bent onto one axis).
    func testMachineClickThenStillHand() {
        let machine = engagedMachine()
        var outputs: [(Double, StepOutput)] = []
        for frame in SyntheticStream.wiggleClick() { outputs.append((frame.timestamp, machine.process(frame))) }
        let clicks = outputs.flatMap { $0.1.clicks }
        XCTAssertEqual(clicks.count, 1)
        guard let clickTime = outputs.first(where: { !$0.1.clicks.isEmpty })?.0 else { return }
        let settled = outputs.filter { $0.0 > clickTime + PointerStateMachine.maxHoldTime + 0.1 }.flatMap { $0.1.moves }
        if let first = settled.first {
            XCTAssertTrue(settled.allSatisfy { $0.distance(to: first) < 3 }, "cursor still after the click")
        }
    }
}
