import XCTest
@testable import GestureCore

/// Engagement, safety and plumbing: the gestures themselves are in DwellShakeTests.
final class PointerStateMachineTests: XCTestCase {
    func testHoverMovesCursorOnlyWhenEngaged() {
        // A calm move (a fast one would freeze the cursor).
        let frames = SyntheticStream.ramp(from: Point2(0.6, 0.45), to: Point2(0.4, 0.45), duration: 2.0)
        let idle = PointerStateMachine(displays: [testDisplay])
        XCTAssertTrue(drive(idle, frames).intents.isEmpty, "a disengaged machine must never move the cursor")

        let machine = engagedMachine()
        let moves = drive(machine, frames).moves
        XCTAssertGreaterThan(moves.count, 5)
        // Hand moves toward the camera's left = the user's right: cursor moves right (mirrored).
        XCTAssertGreaterThan(moves.last!.x, moves.first!.x + 300)
    }

    func testNoGestureNeedsTicks() {
        // Nothing glides any more, so the app's tick timer never runs.
        let machine = engagedMachine()
        for frame in SyntheticStream.wiggleClick() + SyntheticStream.twoFists().map({
            TrackingFrame(timestamp: $0.timestamp + 5, hands: $0.hands)
        }) {
            _ = machine.process(frame)
            XCTAssertFalse(machine.needsTicks)
        }
    }

    func testBothPalmsEngageOnlyAfterHoldDuration() {
        let short = PointerStateMachine(displays: [testDisplay])
        drive(short, SyntheticStream.palmHold(hold: 0.4))
        XCTAssertFalse(short.isEngaged, "0.4 s is too short")

        let machine = PointerStateMachine(displays: [testDisplay])
        let out = drive(machine, SyntheticStream.palmHold(hold: 1.0))
        XCTAssertTrue(machine.isEngaged)
        XCTAssertEqual(out.events.filter { $0 == .engaged }.count, 1, "holding longer must not toggle again")
    }

    func testBothPalmsDisengage() {
        let machine = engagedMachine()
        let out = drive(machine, SyntheticStream.palmHold(hold: 1.2))
        XCTAssertFalse(machine.isEngaged)
        XCTAssertTrue(out.events.contains(.disengaged(.palm)))
    }

    func testHandLostDisengagesAfterTimeout() {
        let machine = engagedMachine()
        drive(machine, SyntheticStream.handLost(visibleUntil: 0.5, duration: 2.3))
        XCTAssertTrue(machine.isEngaged, "1.8 s without a hand is still within the 2 s timeout")
        let longer = engagedMachine()
        let out = drive(longer, SyntheticStream.handLost(visibleUntil: 0.5, duration: 3.0))
        XCTAssertFalse(longer.isEngaged)
        XCTAssertTrue(out.events.contains(.disengaged(.handLost)))
    }

    /// The fist drag scenario up to `until` (pressed at 2 s, moving from 2.5 s).
    private func dragFrames(until: Double) -> [TrackingFrame] {
        SyntheticStream.fistDrag().filter { $0.timestamp < until }
    }

    func testHandLostDuringDragReleasesButton() {
        var frames = dragFrames(until: 3.0)
        frames += SyntheticStream.generate(duration: 0.5, start: 3.0) { _ in [] }
        let out = drive(engagedMachine(), frames)
        XCTAssertEqual(out.downs, 1)
        XCTAssertEqual(out.ups, 1, "a lost hand must never leave the button held")
    }

    func testDisengageReleasesHeldButton() {
        let machine = engagedMachine()
        _ = drive(machine, dragFrames(until: 3.0))
        XCTAssertEqual(machine.state, .dragging)
        let out = machine.setEngaged(false, reason: .hotkey, at: 3.1)
        XCTAssertEqual(out.ups, 1)
        XCTAssertEqual(out.events.last, .disengaged(.hotkey))
    }

    func testRealMouseDuringHandDragReleasesButtonWhereTheMouseIs() {
        let machine = engagedMachine()
        var out = StepOutput()
        var tookOver = false
        for frame in SyntheticStream.fistDrag() {
            out.append(machine.process(frame))
            if !tookOver && machine.state == .dragging && frame.timestamp >= 2.6 {
                out.append(machine.noteExternalMouse(at: Point2(10, 10), time: frame.timestamp))
                tookOver = true
            }
        }
        XCTAssertTrue(tookOver)
        XCTAssertEqual(out.downs, 1)
        XCTAssertEqual(out.ups, 1, "the fist opening later sends no second up")
        XCTAssertEqual(out.intents.last { if case .up = $0 { return true } else { return false } }, .up(x: 10, y: 10))
        XCTAssertTrue(out.clicks.isEmpty)
    }

    func testFistWhileMouseSuppressedSendsNoUnmatchedUp() {
        // The fist formed while the real mouse had priority: no down was sent, so opening the
        // fist must not send an up either (it would cut short a real drag).
        let machine = engagedMachine()
        var out = StepOutput()
        for frame in SyntheticStream.fistDrag() {
            if abs(frame.timestamp - 2.0) < 0.001 {
                out.append(machine.noteExternalMouse(at: Point2(10, 10), time: frame.timestamp))
            }
            out.append(machine.process(frame))
        }
        XCTAssertEqual(out.downs, out.ups)
        XCTAssertEqual(out.events.filter { $0 == .dragEnded }.count, out.downs)
    }

    func testExternalMouseSuppressesOutput() {
        let machine = engagedMachine()
        let frames = SyntheticStream.ramp(from: Point2(0.6, 0.45), to: Point2(0.4, 0.45), duration: 1.0)
        var out = StepOutput()
        for frame in frames {
            if abs(frame.timestamp - 0.8) < 0.001 {
                out.append(machine.noteExternalMouse(at: Point2(10, 10), time: frame.timestamp))
            }
            let step = machine.process(frame)
            if frame.timestamp > 0.8 && frame.timestamp < 1.55 {
                XCTAssertTrue(step.intents.isEmpty, "the real mouse wins for a moment")
            }
            out.append(step)
        }
        XCTAssertTrue(out.events.contains(.externalMouseTookOver))
    }

    func testStillHandWithJitterKeepsCursorStill() {
        let out = drive(engagedMachine(), SyntheticStream.steady(duration: 5, noise: 0.0015))
        // After settling, essentially no movement is emitted.
        let lateMoves = out.moves.dropFirst(20)
        var travel = 0.0
        for (a, b) in zip(lateMoves, lateMoves.dropFirst()) { travel += a.distance(to: b) }
        XCTAssertLessThan(travel, 20, "cursor drifted \(travel) pt on a still hand")
        XCTAssertEqual(out.clicks.count, 0)
    }

    func testEachScenarioDoesExactlyItsOneThing() {
        let click = drive(engagedMachine(), SyntheticStream.wiggleClick())
        XCTAssertEqual([click.clicks.count, click.downs, click.zooms.count, click.scrolls(.began).count], [1, 0, 0, 0])
        let drag = drive(engagedMachine(), SyntheticStream.fistDrag())
        XCTAssertEqual([drag.clicks.count, drag.downs, drag.ups, drag.zooms.count, drag.scrolls(.began).count], [0, 1, 1, 0, 0])
    }

    func testMomentumWithZeroFrictionStaysFinite() {
        // Regression: friction 0 made the glide distance 0/0 = NaN.
        var momentum = ScrollMomentum(friction: 0, minSpeed: 40)
        _ = momentum.start(velocity: Point2(0, 1000), at: 0)
        var t = 0.0
        var ended = false
        while t < 120 && !ended {
            t += 1.0 / 60
            for intent in momentum.tick(at: t) {
                guard case let .scroll(dx, dy, phase) = intent else { continue }
                XCTAssertTrue(dx.isFinite && dy.isFinite)
                if phase == .momentumEnded { ended = true }
            }
        }
        XCTAssertTrue(ended)
    }
}
