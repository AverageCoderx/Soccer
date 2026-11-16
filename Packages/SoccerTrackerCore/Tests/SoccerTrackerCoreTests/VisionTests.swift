import XCTest
@testable import SoccerTrackerCore

final class VisionTests: XCTestCase {
    // Half-resolution frames keep the debug-build tests quick; the ball is
    // placed so its apparent size is like a real 1080p shot from ~6 m.
    static let intrinsics = CameraIntrinsics.fromHorizontalFieldOfView(degrees: 73.7, width: 960, height: 540)
    static let ball = BallSpec.size5
    static let renderer = SyntheticImageRenderer(intrinsics: intrinsics, ballRadius: ball.radius)

    func testRefinerMeasuresBallPrecisely() throws {
        let k = Self.intrinsics
        for c in [Vec3(-0.6, 0.3, 3.5), Vec3(1.3, -0.4, 4.0), Vec3(0.2, 0.5, 3.0)] {
            let truth = try XCTUnwrap(SphereProjection.project(center: c, radius: Self.ball.radius, intrinsics: k))
            let frame = Self.renderer.render(ballFrom: c, to: c, frameIndex: 3)
            let ball = try XCTUnwrap(BallRefiner.refine(image: frame, seedU: truth.centerU + 4, seedV: truth.centerV - 3,
                                                        expectedRadius: truth.semiMinor * 1.2))
            XCTAssertEqual(ball.centerU, truth.centerU, accuracy: 0.4)
            XCTAssertEqual(ball.centerV, truth.centerV, accuracy: 0.4)
            XCTAssertEqual(ball.semiMinor, truth.semiMinor, accuracy: 0.5)
            XCTAssertGreaterThan(ball.confidence, 0.5)
        }
    }

    func testRefinerFindsNothingOnPlainGrass() {
        let frame = Self.renderer.render(ballFrom: nil, to: nil, frameIndex: 1)
        let ball = BallRefiner.refine(image: frame, seedU: 400, seedV: 300, expectedRadius: 16)
        XCTAssertTrue(ball == nil || ball!.confidence < 0.25, "found a ball in empty grass: \(String(describing: ball))")
    }

    func testTapLocatesBall() throws {
        let c = Vec3(-0.5, 0.4, 3.5)
        let truth = try XCTUnwrap(SphereProjection.project(center: c, radius: Self.ball.radius, intrinsics: Self.intrinsics))
        let frame = Self.renderer.render(ballFrom: c, to: c, frameIndex: 0)
        let ball = try XCTUnwrap(BallLocator.locate(in: frame, near: ImagePoint(u: truth.centerU + 6, v: truth.centerV + 4)))
        XCTAssertEqual(ball.centerU, truth.centerU, accuracy: 0.5)
        XCTAssertEqual(ball.semiMinor, truth.semiMinor, accuracy: 0.6)
    }

    /// Rendered video → detector → tracker → physics fit, end to end.
    func testEndToEndFromRenderedFrames() throws {
        var s = SyntheticShotScenario()
        s.intrinsics = Self.intrinsics
        s.restPosition = Vec3(-1.6, 0.6, 3.5)
        s.launchVelocity = Vec3(22, -3.5, 1.5)
        s.restDuration = 0.08
        s.flightDuration = 0.22
        let shot = SyntheticShot(s)
        let r = Self.renderer

        func ballCenter(at t: Double) -> Vec3? {
            if t < s.timestampOrigin + s.restDuration { return s.restPosition }
            if t < s.launchTime { return nil }
            return shot.truthState(at: t).position
        }

        let times = shot.frames.map(\.timestamp)
        let firstFrame = r.render(ballFrom: s.restPosition, to: s.restPosition, frameIndex: 0)
        let restImage = try XCTUnwrap(SphereProjection.project(center: s.restPosition, radius: s.ball.radius, intrinsics: s.intrinsics))
        let restBall = try XCTUnwrap(BallLocator.locate(in: firstFrame, near: ImagePoint(u: restImage.centerU, v: restImage.centerV)))

        var detector = BallDetector(restBall: restBall)
        var tracker = ShotTracker(ballRadius: s.ball.radius, restHint: ImagePoint(u: restBall.centerU, v: restBall.centerV))
        for (i, t) in times.enumerated() {
            let start = ballCenter(at: t - r.exposure / 2)
            let end = ballCenter(at: t + r.exposure / 2)
            let frame = r.render(ballFrom: start ?? end, to: end ?? start, frameIndex: i)
            let candidates = detector.detect(frame, timestamp: t,
                                             extraSeeds: tracker.predictedPosition(at: t).map { [$0] } ?? [])
            tracker.process(candidates)
        }
        XCTAssertGreaterThan(tracker.restObservations.count, 10)
        XCTAssertGreaterThan(tracker.flightObservations.count, 25)

        let analysis = ShotAnalyzer().analyze(track: tracker.points, context: shot.context)
        let speed = try XCTUnwrap(analysis.speed, "unavailable: \(analysis.unavailableReasons)")
        let truth = shot.truthSpeed(at: speed.timeOfMaxSpeed)
        let error = (speed.maxSpeed.metersPerSecond - truth) / truth
        XCTAssertLessThan(abs(error), 0.03, "measured \(speed.maxSpeed.metersPerSecond) vs truth \(truth)")
    }
}
