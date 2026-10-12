import XCTest
@testable import GestureCore

final class CalibrationTests: XCTestCase {
    let skewedCorners = [Point2(0.70, 0.22), Point2(0.33, 0.25), Point2(0.30, 0.66), Point2(0.74, 0.70)]

    func testHomographyMapsCornersExactly() throws {
        let unit = [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)]
        let h = try XCTUnwrap(Homography.solve(from: skewedCorners, to: unit))
        for (c, u) in zip(skewedCorners, unit) {
            let mapped = h.apply(c)
            XCTAssertEqual(mapped.x, u.x, accuracy: 1e-9)
            XCTAssertEqual(mapped.y, u.y, accuracy: 1e-9)
        }
    }

    func testDegenerateQuadIsRejected() {
        let collinear = [Point2(0.1, 0.1), Point2(0.2, 0.2), Point2(0.3, 0.3), Point2(0.4, 0.4)]
        XCTAssertNil(Homography.solve(from: collinear, to: [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)]))
        XCTAssertFalse(CalibrationProfile(corners: collinear, pinchEnter: 0.35, pinchExit: 0.5, isCalibrated: true).isUsable)
        // Corners captured in the wrong order make a bow-tie: not convex.
        let bowTie = [skewedCorners[0], skewedCorners[2], skewedCorners[1], skewedCorners[3]]
        XCTAssertFalse(CalibrationProfile(corners: bowTie, pinchEnter: 0.35, pinchExit: 0.5, isCalibrated: true).isUsable)
    }

    func testCalibratedCornersHitScreenCorners() {
        let profile = CalibrationProfile(corners: skewedCorners, pinchEnter: 0.35, pinchExit: 0.5, isCalibrated: true)
        XCTAssertTrue(profile.isUsable)
        let mapper = ActiveBoxMapper(profile: profile)
        let display = DisplayInfo(id: "ext", frame: Rect(x: 1728, y: -200, width: 2560, height: 1440))
        let expected = [Point2(1728, -200), Point2(1728 + 2559, -200), Point2(1728 + 2559, 1239), Point2(1728, 1239)]
        for (corner, target) in zip(skewedCorners, expected) {
            let screen = ActiveBoxMapper.screenPoint(fromBox: mapper.boxPoint(fromCamera: corner), on: display)
            XCTAssertEqual(screen.x, target.x, accuracy: 1e-6)
            XCTAssertEqual(screen.y, target.y, accuracy: 1e-6)
        }
        // The quad's centre lands near the screen's centre.
        let centre = skewedCorners.reduce(Point2.zero, +) / 4
        let mid = ActiveBoxMapper.screenPoint(fromBox: mapper.boxPoint(fromCamera: centre), on: display)
        XCTAssertEqual(mid.x, display.frame.center.x, accuracy: 120)
        XCTAssertEqual(mid.y, display.frame.center.y, accuracy: 120)
    }

    func testDefaultProfileIsMirrored() {
        let mapper = ActiveBoxMapper(profile: .defaultProfile())
        // Camera's left (small x) is the user's right: maps to the right half of the screen.
        XCTAssertGreaterThan(mapper.boxPoint(fromCamera: Point2(0.4, 0.45)).x, 0.5)
        XCTAssertLessThan(mapper.boxPoint(fromCamera: Point2(0.6, 0.45)).x, 0.5)
    }

    func testSensitivityShrinksBox() {
        let normal = ActiveBoxMapper(profile: .defaultProfile(), boxScale: 1)
        let sensitive = ActiveBoxMapper(profile: .defaultProfile(), boxScale: 0.7)
        let p = Point2(0.45, 0.45)
        XCTAssertGreaterThan(abs(sensitive.boxPoint(fromCamera: p).x - 0.5), abs(normal.boxPoint(fromCamera: p).x - 0.5))
    }

    func testCornerCalibrationSession() {
        var session = CornerCalibrationSession()
        var t = 0.0
        var status = session.process(fingertip: nil, at: t)
        for corner in skewedCorners {
            var rng = SeededRandom(seed: 5)
            // Arrive, then hold still with slight jitter.
            for _ in 0..<60 {
                t += 1.0 / 30
                let p = corner + Point2(rng.gaussian() * 0.002, rng.gaussian() * 0.002)
                status = session.process(fingertip: p, at: t)
                if case .collecting(let index, _) = status, index > skewedCorners.firstIndex(of: corner)! { break }
                if case .finished = status { break }
            }
        }
        guard case let .finished(profile) = status else { return XCTFail("calibration did not finish: \(status)") }
        for (captured, truth) in zip(profile.corners, skewedCorners) {
            XCTAssertEqual(captured.distance(to: truth), 0, accuracy: 0.006)
        }
        XCTAssertTrue(profile.isCalibrated)
    }

    func testCornerCalibrationTimesOut() {
        var session = CornerCalibrationSession()
        var status = CornerCalibrationSession.Status.collecting(corner: 0, stillProgress: 0)
        for i in 0..<300 {
            // A hand that never holds still.
            status = session.process(fingertip: Point2(0.5 + 0.05 * sin(Double(i)), 0.5), at: Double(i) / 30)
        }
        guard case .failed = status else { return XCTFail("expected timeout, got \(status)") }
    }

    func testPinchCalibrationAdaptsThresholds() {
        var session = PinchCalibrationSession()
        var status = PinchCalibrationSession.Status.collecting(pinchesSeen: 0)
        // A user whose pinch closes to 0.25 and opens to 1.2.
        for i in 0..<200 {
            let phase = Double(i % 30) / 30
            let d = phase < 0.4 ? 0.25 : 1.2
            status = session.process(pinchDistance: d, at: Double(i) / 30)
            if case .finished = status { break }
        }
        guard case let .finished(enter, exit) = status else { return XCTFail("\(status)") }
        XCTAssertGreaterThan(enter, 0.25)
        XCTAssertLessThan(enter, 0.6)
        XCTAssertGreaterThan(exit, enter + 0.07)
    }

    func testCalibratedPinchThresholdsReachDetector() {
        var profile = CalibrationProfile.defaultProfile()
        profile.isCalibrated = true
        profile.pinchEnter = 0.2
        profile.pinchExit = 0.3
        let machine = PointerStateMachine(config: .pose, displays: [testDisplay],
                                          calibration: CalibrationSet(profiles: ["main": profile]))
        _ = machine.setEngaged(true, at: 0)
        // A half pinch (~0.4 normalized) would click with defaults? No: 0.4 > 0.35. Use a
        // three-quarter pinch around 0.27: clicks with defaults, not with the tighter profile.
        let frames = SyntheticStream.generate(duration: 1.5) { t in
            var h = SyntheticHand.pointing(tipAt: Point2(0.5, 0.45))
            h.pinchAmount = (t > 0.5 && t < 0.7) ? 0.86 : 0
            return [h]
        }
        XCTAssertEqual(drive(machine, frames).clicks.count, 0)
        XCTAssertEqual(drive(engagedMachine(), frames).clicks.count, 1)
    }
}

final class DisplayRouterTests: XCTestCase {
    let left = DisplayInfo(id: "L", frame: Rect(x: 0, y: 0, width: 1728, height: 1117))
    let right = DisplayInfo(id: "R", frame: Rect(x: 1728, y: -300, width: 2560, height: 1440))

    func testNeighborDetection() {
        let router = DisplayRouter(displays: [left, right], dwell: 0.4)
        XCTAssertEqual(router.neighbor(of: left, toward: .right)?.id, "R")
        XCTAssertEqual(router.neighbor(of: right, toward: .left)?.id, "L")
        XCTAssertNil(router.neighbor(of: left, toward: .left))
        XCTAssertNil(router.neighbor(of: left, toward: .top))
    }

    func testJumpNeedsDwellAndRearm() {
        var router = DisplayRouter(displays: [left, right], dwell: 0.4)
        XCTAssertNil(router.update(box: Point2(1.05, 0.5), at: 0))
        XCTAssertNil(router.update(box: Point2(1.05, 0.5), at: 0.3))
        XCTAssertEqual(router.update(box: Point2(1.05, 0.5), at: 0.41)?.id, "R")
        // Still at the (now left-hand) right edge: no ping-pong without coming back inside.
        XCTAssertNil(router.update(box: Point2(-0.05, 0.5), at: 0.5))
        XCTAssertNil(router.update(box: Point2(-0.05, 0.5), at: 1.5))
        _ = router.update(box: Point2(0.5, 0.5), at: 1.6)
        XCTAssertNil(router.update(box: Point2(-0.05, 0.5), at: 1.7))
        XCTAssertEqual(router.update(box: Point2(-0.05, 0.5), at: 2.2)?.id, "L")
    }

    func testBriefEdgeTouchDoesNotJump() {
        var router = DisplayRouter(displays: [left, right], dwell: 0.4)
        _ = router.update(box: Point2(1.05, 0.5), at: 0)
        _ = router.update(box: Point2(0.9, 0.5), at: 0.2)
        XCTAssertNil(router.update(box: Point2(1.05, 0.5), at: 0.3))
        XCTAssertNil(router.update(box: Point2(1.05, 0.5), at: 0.6))
        XCTAssertEqual(router.current?.id, "L")
    }

    func testMachineJumpsDisplayWhenHeldAtEdge() {
        var config = GestureConfig.pose
        config.stayOnEngagedDisplay = false   // edge jumps are only on when not locked
        let machine = engagedMachine(config, displays: [left, right])
        // Hold the finger far to the user's right (camera's left) for a second.
        let out = drive(machine, SyntheticStream.steady(tip: Point2(0.22, 0.45), duration: 1.2))
        XCTAssertTrue(out.events.contains(.displayChanged("R")))
        XCTAssertGreaterThan(out.moves.last!.x, 1728)
    }

    func testLockedRouterNeverJumps() {
        let small = DisplayInfo(id: "S", frame: Rect(x: 0, y: 0, width: 1440, height: 900))
        let big = DisplayInfo(id: "B", frame: Rect(x: 1440, y: 0, width: 2560, height: 1440))
        var router = DisplayRouter(displays: [small, big], dwell: 0.4)
        router.locked = true
        router.focus(containing: Point2(2000, 100))
        XCTAssertEqual(router.current?.id, "B")
        XCTAssertNil(router.update(box: Point2(-0.1, 0.5), at: 0))
        XCTAssertNil(router.update(box: Point2(-0.1, 0.5), at: 1))
        XCTAssertEqual(router.current?.id, "B")
    }

    func testFocusFollowsRealMouse() {
        var router = DisplayRouter(displays: [left, right], dwell: 0.4)
        router.focus(containing: Point2(2000, 100))
        XCTAssertEqual(router.current?.id, "R")
        router.focus(containing: Point2(-50, 50)) // off-screen: nearest display
        XCTAssertEqual(router.current?.id, "L")
    }

    func testNonPositiveBoxScaleFallsBackToDefaultScale() {
        // Regression: scale 0 collapsed the quad, the solve failed and the identity map
        // (unmirrored) was used; a negative scale flipped the box.
        let profile = CalibrationProfile.defaultProfile()
        let reference = ActiveBoxMapper(profile: profile, boxScale: 1)
        for bad in [0.0, -1.0, .nan, .infinity] {
            let mapper = ActiveBoxMapper(profile: profile, boxScale: bad)
            for p in [Point2(0.4, 0.4), Point2(0.6, 0.5)] {
                XCTAssertEqual(mapper.boxPoint(fromCamera: p).distance(to: reference.boxPoint(fromCamera: p)), 0,
                               accuracy: 1e-9, "boxScale \(bad)")
            }
        }
    }
}
