import XCTest
@testable import SoccerTrackerCore

final class ScaleCheckTests: XCTestCase {
    func dropShot(seed: UInt64, radiusBias: Double = 0) -> SyntheticShot {
        var s = SyntheticShotScenario()
        s.seed = seed
        s.restPosition = Vec3(0.3, -1.0, 5)
        s.launchVelocity = .zero
        s.contactDuration = 0
        s.flightDuration = 0.6
        s.radiusBias = radiusBias
        // A slowly falling ball is below the drag crisis.
        s.dragCoefficient = 0.47
        return SyntheticShot(s)
    }

    func check(_ shot: SyntheticShot) -> (ScaleCheckResult?, [UnavailableReason]) {
        var tracker = ShotTracker(ballRadius: shot.scenario.ball.radius)
        for f in shot.frames { tracker.process(f) }
        return ShotAnalyzer().analyzeDropTest(track: tracker.points, context: shot.context)
    }

    func testDropTestRecoversGravity() throws {
        var measured: [Double] = []
        for seed in 1...8 {
            let (result, reasons) = check(dropShot(seed: UInt64(seed)))
            XCTAssertEqual(reasons, [], "seed \(seed)")
            let r = try XCTUnwrap(result)
            measured.append(r.measuredGravity)
            // Each drop is within its own reported uncertainty (≈ ±1.3% here)…
            XCTAssertLessThan(abs(r.measuredGravity - 9.81), 3 * r.uncertainty, "seed \(seed)")
            XCTAssertLessThan(r.uncertainty / 9.81, 0.02, "seed \(seed)")
            XCTAssertLessThan(r.directionErrorDegrees ?? 99, 3)
        }
        // …and the average of several drops is within 1%.
        XCTAssertEqual(measured.reduce(0, +) / Double(measured.count), 9.81, accuracy: 0.098)
    }

    func testDropTestExposesScaleBias() throws {
        // Measuring the ball 0.5 px too big (≈2.3% at this distance) makes
        // everything look closer, so gravity, like speed, reads low by about that much.
        var errors: [Double] = []
        for seed in 1...6 {
            let r = try XCTUnwrap(check(dropShot(seed: UInt64(seed), radiusBias: 0.5)).0)
            errors.append(r.scaleError)
        }
        let mean = errors.reduce(0, +) / Double(errors.count)
        XCTAssertEqual(mean, -0.5 / 22.0, accuracy: 0.01)
    }

    func testTooShortDropIsUnavailable() {
        var s = SyntheticShotScenario()
        s.launchVelocity = .zero
        s.contactDuration = 0
        s.flightDuration = 0.12
        let (result, reasons) = check(SyntheticShot(s))
        XCTAssertNil(result)
        XCTAssertFalse(reasons.isEmpty)
    }
}
