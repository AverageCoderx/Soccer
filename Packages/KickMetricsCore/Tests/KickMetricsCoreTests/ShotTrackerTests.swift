import XCTest
@testable import KickMetricsCore

final class ShotTrackerTests: XCTestCase {
    func track(_ shot: SyntheticShot, hint: ImagePoint? = nil) -> ShotTracker {
        var tracker = ShotTracker(ballRadius: shot.scenario.ball.radius, restHint: hint)
        for frame in shot.frames { tracker.process(frame) }
        return tracker
    }

    func testFollowsRestLaunchAndFlight() {
        let shot = SyntheticShot(SyntheticShotScenario())
        let tracker = track(shot)
        XCTAssertEqual(tracker.state, .finished)
        XCTAssertGreaterThan(tracker.restObservations.count, 80)
        // Nearly every in-frame flight detection should be picked up.
        let trueFlight = shot.ballDetections.filter { $0.timestamp >= shot.scenario.launchTime }
        XCTAssertGreaterThanOrEqual(tracker.flightObservations.count, trueFlight.count - 3)
    }

    func testRejectsClutterAndFoot() {
        for seed in 1...10 {
            var s = SyntheticShotScenario()
            s.seed = UInt64(seed)
            s.clutterPerFrame = 5
            s.includeFootDistractor = true
            let shot = SyntheticShot(s)
            let tracker = track(shot)
            let genuine = Set(shot.ballDetections.map(\.timestamp))
            for point in tracker.points {
                let o = point.observation
                let isBall = genuine.contains(o.timestamp)
                    && shot.ballDetections.contains { $0 == o }
                XCTAssertTrue(isBall, "seed \(seed): tracker accepted a non-ball detection in phase \(point.phase)")
            }
            XCTAssertGreaterThan(tracker.flightObservations.count, 40, "seed \(seed)")
        }
    }

    func testRestHintPicksTheRightBall() {
        var s = SyntheticShotScenario()
        s.clutterPerFrame = 0
        let shot = SyntheticShot(s)
        // A second, stationary ball-like object elsewhere, detected more confidently.
        let frames = shot.frames.map { frame -> FrameCandidates in
            var f = frame
            f.candidates.append(BallObservation(timestamp: frame.timestamp, centerU: 1500, centerV: 800,
                                                semiMinor: 25, confidence: 0.99))
            return f
        }
        let restImage = SphereProjection.project(center: s.restPosition, radius: s.ball.radius, intrinsics: s.intrinsics)!
        var tracker = ShotTracker(ballRadius: s.ball.radius,
                                  restHint: ImagePoint(u: restImage.centerU + 5, v: restImage.centerV - 5))
        for f in frames { tracker.process(f) }
        let rest = tracker.restObservations
        XCTAssertFalse(rest.isEmpty)
        XCTAssertTrue(rest.allSatisfy { abs($0.centerU - restImage.centerU) < 5 })
        XCTAssertGreaterThan(tracker.flightObservations.count, 40)
    }
}

final class ValidationStatisticsTests: XCTestCase {
    func testSummary() throws {
        let samples = [ValidationSample(reference: 20, measured: 21),
                       ValidationSample(reference: 25, measured: 24),
                       ValidationSample(reference: 30, measured: 30.6)]
        let s = try XCTUnwrap(ValidationSummary(samples))
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.meanError, 0.2, accuracy: 1e-12)
        XCTAssertEqual(s.meanAbsoluteError, 2.6 / 3, accuracy: 1e-12)
        XCTAssertEqual(s.meanAbsolutePercentError, (5 + 4 + 2) / 3, accuracy: 1e-9)
        XCTAssertEqual(s.maxAbsolutePercentError, 5, accuracy: 1e-9)
        XCTAssertEqual(s.rootMeanSquareError, ((1 + 1 + 0.36) / 3).squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(s.limitsOfAgreement.lowerBound, 0.2 - 1.96 * s.errorStandardDeviation, accuracy: 1e-12)
    }

    func testDropTestSpeed() {
        XCTAssertEqual(DropTest.impactSpeed(height: 2), 6.264, accuracy: 0.001)
    }
}
