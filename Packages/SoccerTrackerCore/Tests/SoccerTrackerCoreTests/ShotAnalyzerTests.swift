import XCTest
@testable import SoccerTrackerCore

/// End-to-end tests: synthetic detections → tracker → physics fit → speed.
/// The ground truth is known exactly, so these check both accuracy and that
/// the reported uncertainty is honest.
final class ShotAnalyzerTests: XCTestCase {
    struct Outcome {
        var shot: SyntheticShot
        var analysis: ShotAnalysis
        var truth: Double
        var relativeError: Double
    }

    func run(seed: UInt64 = 1, analyzer: ShotAnalyzer = ShotAnalyzer(),
             _ configure: (inout SyntheticShotScenario) -> Void = { _ in }) -> Outcome {
        var s = SyntheticShotScenario()
        s.seed = seed
        configure(&s)
        let shot = SyntheticShot(s)
        let analysis = analyzer.analyze(frames: shot.frames, context: shot.context)
        guard let speed = analysis.speed else {
            return Outcome(shot: shot, analysis: analysis, truth: .nan, relativeError: .nan)
        }
        let truth = shot.truthSpeed(at: speed.timeOfMaxSpeed)
        return Outcome(shot: shot, analysis: analysis, truth: truth,
                       relativeError: (speed.maxSpeed.metersPerSecond - truth) / truth)
    }

    func testSideOnShotIsAccurateUnbiasedAndHonestAcrossSeeds() {
        var errors: [Double] = []
        var pulls: [Double] = []
        for seed in 1...30 {
            let o = run(seed: UInt64(seed))
            guard let speed = o.analysis.speed else {
                XCTFail("seed \(seed) unavailable: \(o.analysis.unavailableReasons)")
                continue
            }
            errors.append(o.relativeError)
            // The synthetic ball size and detector are exact, so only the
            // statistical part of the uncertainty applies here.
            pulls.append(o.relativeError / speed.breakdown.statistical)
            XCTAssertLessThan(abs(o.relativeError), 0.03, "seed \(seed)")
            XCTAssertEqual(speed.confidence, .high, "seed \(seed)")
        }
        let n = Double(errors.count)
        let bias = errors.reduce(0, +) / n
        let pullRMS = (pulls.map { $0 * $0 }.reduce(0, +) / n).squareRoot()
        XCTAssertLessThan(abs(bias), 0.003, "mean relative error")
        // If the reported statistical σ is right, pulls have RMS ≈ 1.
        XCTAssertGreaterThan(pullRMS, 0.5)
        XCTAssertLessThan(pullRMS, 1.6)
    }

    func testAngledShotUsesBallSizeForDepthMotion() {
        for seed in 1...5 {
            let o = run(seed: UInt64(seed)) { $0.launchVelocity = Vec3(24, -4, 24 * tan(20 * .pi / 180)) }
            XCTAssertTrue(o.analysis.isMeasured, "\(o.analysis.unavailableReasons)")
            XCTAssertLessThan(abs(o.relativeError), 0.03, "seed \(seed)")
            XCTAssertEqual(o.analysis.diagnostics?.outOfPlaneAngleDegrees ?? 0, 19, accuracy: 3)
        }
    }

    func testShotAtCameraIsReportedUnavailable() {
        let o = run { $0.restPosition = Vec3(0, 1, 12); $0.launchVelocity = Vec3(3, -3, -22) }
        XCTAssertFalse(o.analysis.isMeasured)
        XCTAssertNil(o.analysis.speed, "no speed may be exposed when unavailable")
        XCTAssertTrue(o.analysis.unavailableReasons.contains { if case .shotTowardCamera = $0 { return true }; return false })
    }

    func testClutterFootOutliersAndDroppedFrames() {
        for seed in 1...8 {
            let o = run(seed: UInt64(seed)) {
                $0.clutterPerFrame = 4
                $0.includeFootDistractor = true
                $0.outlierProbability = 0.05
                $0.droppedFrameProbability = 0.05
            }
            XCTAssertTrue(o.analysis.isMeasured, "seed \(seed): \(o.analysis.unavailableReasons)")
            XCTAssertLessThan(abs(o.relativeError), 0.03, "seed \(seed)")
        }
    }

    func testLowerFrameRatesStillMeasure() {
        for fps in [120.0, 60.0] {
            for seed in 1...5 {
                let o = run(seed: UInt64(seed)) { $0.frameRate = fps }
                XCTAssertTrue(o.analysis.isMeasured, "\(fps) fps seed \(seed)")
                XCTAssertLessThan(abs(o.relativeError), 0.04, "\(fps) fps seed \(seed)")
            }
        }
    }

    func testFastShotAndFartherCamera() {
        let fast = run { $0.launchVelocity = Vec3(40, -3, 0) }
        XCTAssertLessThan(abs(fast.relativeError), 0.03)
        let far = run { $0.restPosition = Vec3(-4, 1.5, 10) }
        XCTAssertLessThan(abs(far.relativeError), 0.04)
    }

    func testRollingShutterCorrection() {
        let readout = 0.004
        var calibratedConfig = AnalyzerConfiguration()
        calibratedConfig.fit.readoutTime = readout
        let calibrated = ShotAnalyzer(configuration: calibratedConfig)
        var uncorrectedErrors: [Double] = []
        var correctedErrors: [Double] = []
        for seed in 1...10 {
            let configure: (inout SyntheticShotScenario) -> Void = {
                $0.readoutTime = readout
                $0.launchVelocity = Vec3(15, -14, 0)  // steep rise: crosses many rows
                $0.centerNoise = 0.1
                $0.radiusNoise = 0.1
            }
            uncorrectedErrors.append(run(seed: UInt64(seed), configure).relativeError)
            let c = run(seed: UInt64(seed), analyzer: calibrated, configure)
            correctedErrors.append(c.relativeError)
            XCTAssertFalse(c.analysis.warnings.contains { if case .rollingShutterUncalibrated = $0 { return true }; return false })
        }
        let meanUncorrected = uncorrectedErrors.reduce(0, +) / 10
        let meanCorrected = correctedErrors.reduce(0, +) / 10
        XCTAssertLessThan(abs(meanCorrected), abs(meanUncorrected), "correction should remove the timing bias")
        XCTAssertLessThan(abs(meanCorrected), 0.003)
    }

    func testRadiusBiasIsCoveredByReportedUncertainty() {
        // A detector that systematically measures the ball 0.3 px too big
        // (the configured 1σ bias) makes the ball look closer and so slower,
        // by ≈ bias / semi-minor ≈ 0.3 / 23.5 ≈ 1.3%. Low pixel noise and an
        // average over seeds isolate the bias from random error.
        var errors: [Double] = []
        for seed in 1...12 {
            let o = run(seed: UInt64(seed)) {
                $0.radiusBias = 0.3
                $0.centerNoise = 0.1
                $0.radiusNoise = 0.1
            }
            guard let speed = o.analysis.speed else { return XCTFail("unavailable") }
            errors.append(o.relativeError)
            XCTAssertLessThan(abs(o.relativeError), 3 * speed.maxSpeed.relativeUncertainty, "seed \(seed)")
            XCTAssertEqual(speed.breakdown.radiusBias, 0.3 / (o.analysis.diagnostics?.meanApparentRadiusPixels ?? 1), accuracy: 1e-9)
        }
        let mean = errors.reduce(0, +) / Double(errors.count)
        XCTAssertEqual(mean, -0.013, accuracy: 0.004, "bias should read slow by about bias/radius")
    }

    func testDropTestReadsGravitationalSpeed() {
        for seed in 1...5 {
            let o = run(seed: UInt64(seed)) {
                $0.restPosition = Vec3(0, -0.9, 5)
                $0.launchVelocity = .zero
                $0.contactDuration = 0
                $0.flightDuration = 0.6
            }
            XCTAssertTrue(o.analysis.isMeasured, "\(o.analysis.unavailableReasons)")
            XCTAssertLessThan(abs(o.relativeError), 0.03, "seed \(seed)")
        }
    }

    func testTooShortFlightIsUnavailable() {
        let o = run { $0.flightDuration = 0.02 }
        XCTAssertFalse(o.analysis.isMeasured)
        XCTAssertNil(o.analysis.speed)
    }

    func testNoKickIsUnavailable() {
        let o = run { $0.flightDuration = 0; $0.contactDuration = 0 }
        XCTAssertEqual(o.analysis.unavailableReasons, [.noFlightDetected])
    }

    func testNoDetectionsIsBallNotFound() {
        let frames = (0..<50).map { FrameCandidates(timestamp: Double($0) / 240, candidates: []) }
        let context = SyntheticShot(SyntheticShotScenario()).context
        let a = ShotAnalyzer().analyze(frames: frames, context: context)
        XCTAssertEqual(a.unavailableReasons, [.ballNotFound])
    }

    func testUnitConversions() {
        let s = SpeedEstimate(metersPerSecond: 10, uncertainty: 1)
        XCTAssertEqual(s.kmh, 36, accuracy: 1e-12)
        XCTAssertEqual(s.mph, 22.369362920544, accuracy: 1e-9)
    }
}
