import Foundation

public struct AnalyzerConfiguration: Sendable, Equatable {
    public var tracker = TrackerConfiguration()
    public var fit = FlightFitConfiguration()
    public var airDensity: Double = 1.2

    public var minFlightObservations: Int = 8
    public var minFlightDuration: Double = 0.025
    /// Only the first part of the flight is fitted: it's where the speed is
    /// highest and it avoids bounces and the ball shrinking into the distance.
    public var maxFitWindow: Double = 0.35

    /// Above this relative 1σ uncertainty the speed is reported unavailable.
    public var maxRelativeUncertainty: Double = 0.10
    public var maxReducedChiSquare: Double = 25
    /// Angle between the velocity and the image plane beyond which the shot is
    /// considered "toward the camera": the speed would then rest mostly on the
    /// ball's change in size, which is much less precise.
    public var maxOutOfPlaneAngleDegrees: Double = 60
    public var warnOutOfPlaneAngleDegrees: Double = 30

    /// Relative 1σ error of the camera-reported focal length.
    public var focalLengthRelativeSigma: Double = 0.01
    /// 1σ of possible detector bias in the semi-minor axis, pixels.
    public var radiusBiasSigmaPixels: Double = 0.3
    /// 1σ assumed for the readout time when it isn't calibrated (`fit.readoutTime == 0`).
    public var uncalibratedReadoutSigma: Double = 0.004
    /// 1σ assumed when it is calibrated.
    public var calibratedReadoutSigma: Double = 0.0005
    /// Extra-acceleration prior when gravity is assumed rather than measured.
    public var unmeasuredGravityExtraAccelerationSigma: Double = 10

    public var plausibleSpeed: ClosedRange<Double> = 0.5...65
    public var plausibleDistance: ClosedRange<Double> = 0.8...40

    public init() {}

    static func confidence(forRelativeUncertainty r: Double) -> MeasurementConfidence {
        if r <= 0.03 { return .high }
        if r <= 0.06 { return .medium }
        return .low
    }
}

/// Camera and scene facts for one shot.
public struct ShotContext: Sendable, Equatable {
    public var intrinsics: CameraIntrinsics
    public var ball: BallSpec
    /// Gravity in the camera frame (m/s²), from the motion sensor.
    public var gravity: Vec3
    public var gravityIsMeasured: Bool

    public init(intrinsics: CameraIntrinsics, ball: BallSpec, gravity: Vec3, gravityIsMeasured: Bool) {
        self.intrinsics = intrinsics
        self.ball = ball
        self.gravity = gravity
        self.gravityIsMeasured = gravityIsMeasured
    }
}

/// Turns a shot's per-frame detections into a speed measurement, or an
/// explanation of why it couldn't be measured.
public struct ShotAnalyzer: Sendable {
    public var configuration: AnalyzerConfiguration

    public init(configuration: AnalyzerConfiguration = AnalyzerConfiguration()) {
        self.configuration = configuration
    }

    public func analyze(frames: [FrameCandidates], context: ShotContext, restHint: ImagePoint? = nil) -> ShotAnalysis {
        var tracker = ShotTracker(configuration: configuration.tracker, ballRadius: context.ball.radius, restHint: restHint)
        for frame in frames.sorted(by: { $0.timestamp < $1.timestamp }) {
            tracker.process(frame)
        }
        return analyze(track: tracker.points, context: context)
    }

    public func analyze(track: [TrackPoint], context: ShotContext) -> ShotAnalysis {
        let restCount = track.filter { $0.phase == .rest }.count
        let flight = track.filter { $0.phase == .flight }.map(\.observation).sorted { $0.timestamp < $1.timestamp }
        var warnings: [ShotWarning] = []

        func unavailable(_ reasons: [UnavailableReason], diagnostics: FitDiagnostics? = nil,
                         trajectory: [KinematicState] = []) -> ShotAnalysis {
            ShotAnalysis(outcome: .unavailable(reasons), speed: nil, diagnostics: diagnostics,
                         restObservationCount: restCount, flightObservationCount: flight.count,
                         warnings: warnings, fittedTrajectory: trajectory)
        }

        guard !track.isEmpty else { return unavailable([.ballNotFound]) }
        guard let first = flight.first else { return unavailable([.noFlightDetected]) }
        if restCount == 0 { warnings.append(.noRestPhase) }

        let window = flight.filter { $0.timestamp - first.timestamp <= configuration.maxFitWindow }
        let duration = (window.last?.timestamp ?? first.timestamp) - first.timestamp
        guard window.count >= configuration.minFlightObservations, duration >= configuration.minFlightDuration else {
            return unavailable([.insufficientFlightData(observations: window.count, duration: duration)])
        }

        if let gap = Self.maxGap(window), let typical = Self.medianInterval(window), gap > 3.5 * typical {
            warnings.append(.frameGaps(maxGapSeconds: gap))
        }

        var fitConfig = configuration.fit
        if !context.gravityIsMeasured {
            fitConfig.extraAccelerationPriorSigma = max(fitConfig.extraAccelerationPriorSigma,
                                                        configuration.unmeasuredGravityExtraAccelerationSigma)
            warnings.append(.gravityNotMeasured)
        }
        let physics = FlightPhysics(gravity: context.gravity, airDensity: configuration.airDensity, ball: context.ball)
        let fitter = FlightFitter(physics: physics, intrinsics: context.intrinsics, configuration: fitConfig)
        guard let fit = fitter.fit(window), fit.converged else { return unavailable([.fitFailed]) }
        if !fit.rejectedObservations.isEmpty {
            warnings.append(.observationsRejected(count: fit.rejectedObservations.count))
        }

        // Speeds along the fitted path at the observed times.
        let times = fit.usedObservations.map(fitter.effectiveTime).sorted()
        let params = fit.parameters
        let states = fitter.states(for: params, referenceTime: fit.referenceTime, at: times)
        let speeds = states.map { $0.velocity.length }
        guard let iMax = speeds.indices.max(by: { speeds[$0] < speeds[$1] }),
              let tStart = times.first, let tEnd = times.last, tEnd > tStart else {
            return unavailable([.fitFailed])
        }
        let maxSpeed = speeds[iMax]
        let tMax = times[iMax]
        let averageSpeed = Self.averageSpeed(times: times, speeds: speeds)

        // Statistical uncertainty: propagate the parameter covariance through
        // speed(params) with a numerical gradient.
        func speedFunction(_ p: [Double], _ f: @escaping ([KinematicState]) -> Double, at ts: [Double]) -> Double {
            f(fitter.states(for: FlightParameters(vector: p), referenceTime: fit.referenceTime, at: ts))
        }
        let sigmaMaxStat = Self.propagate(params.vector, covariance: fit.covariance) {
            speedFunction($0, { $0[0].velocity.length }, at: [tMax])
        }
        let sigmaAvgStat = Self.propagate(params.vector, covariance: fit.covariance) {
            speedFunction($0, { Self.averageSpeed(times: times, speeds: $0.map { $0.velocity.length }) }, at: times)
        }

        // Systematic uncertainties (relative).
        // Lateral positions scale as R/b (ball size / apparent size), independent
        // of the focal length; depth scales with f·R/b. So the ball's diameter and
        // any bias in measuring its edge scale the whole speed, while focal-length
        // error only affects the depth part: d|v|/|v| = (v_z/|v|)² · df/f.
        let vAtMax = states[iMax].velocity
        let depthFraction = abs(vAtMax.z) / max(vAtMax.length, 1e-9)
        let meanRadius = fit.usedObservations.map(\.semiMinor).reduce(0, +) / Double(fit.usedObservations.count)
        let readoutSigma = fitConfig.readoutTime > 0 ? configuration.calibratedReadoutSigma : configuration.uncalibratedReadoutSigma
        // Rolling shutter: a ball moving across rows at ṙ rows/s has its times
        // stretched by ṙ·T/H, which scales the speed by the same fraction.
        let rowRate = abs((states.last!.position.y / states.last!.position.z - states[0].position.y / states[0].position.z)
                          * context.intrinsics.fy / (tEnd - tStart))
        let rollingShutter = rowRate * readoutSigma / Double(context.intrinsics.imageHeight)

        let breakdownMax = UncertaintyBreakdown(
            statistical: sigmaMaxStat / maxSpeed,
            ballSize: context.ball.diameterRelativeSigma,
            radiusBias: configuration.radiusBiasSigmaPixels / meanRadius,
            focalLength: configuration.focalLengthRelativeSigma * depthFraction * depthFraction,
            rollingShutter: rollingShutter)
        let maxEstimate = SpeedEstimate(metersPerSecond: maxSpeed, uncertainty: breakdownMax.total * maxSpeed)
        var breakdownAvg = breakdownMax
        breakdownAvg.statistical = sigmaAvgStat / averageSpeed
        let avgEstimate = SpeedEstimate(metersPerSecond: averageSpeed, uncertainty: breakdownAvg.total * averageSpeed)

        if fitConfig.readoutTime <= 0 && rollingShutter > 0.005 {
            warnings.append(.rollingShutterUncalibrated(relative: rollingShutter))
        }
        let outOfPlane = asin(min(1, depthFraction)) * 180 / .pi
        if outOfPlane > configuration.warnOutOfPlaneAngleDegrees {
            warnings.append(.largeOutOfPlaneMotion(angleDegrees: outOfPlane))
        }

        let meanDistance = states.map { $0.position.length }.reduce(0, +) / Double(states.count)
        let diagnostics = FitDiagnostics(
            observationCount: fit.usedObservations.count, rejectedCount: fit.rejectedObservations.count,
            duration: tEnd - tStart, reducedChiSquare: fit.reducedChiSquare,
            rmsCenterResidualPixels: fit.rmsCenterResidualPixels,
            rmsRadiusResidualPixels: fit.rmsRadiusResidualPixels,
            fittedDragCoefficient: params.dragCoefficient, fittedExtraAcceleration: params.extraAcceleration,
            meanDistance: meanDistance, meanApparentRadiusPixels: meanRadius,
            outOfPlaneAngleDegrees: outOfPlane, fitMaxSpeed: maxSpeed,
            fitRelativeUncertainty: maxEstimate.relativeUncertainty)

        var reasons: [UnavailableReason] = []
        if fit.reducedChiSquare > configuration.maxReducedChiSquare {
            reasons.append(.poorModelFit(reducedChiSquare: fit.reducedChiSquare))
        }
        if outOfPlane > configuration.maxOutOfPlaneAngleDegrees {
            reasons.append(.shotTowardCamera(angleDegrees: outOfPlane))
        }
        if !configuration.plausibleSpeed.contains(maxSpeed) || !configuration.plausibleDistance.contains(meanDistance) {
            reasons.append(.implausibleResult)
        }
        if maxEstimate.relativeUncertainty > configuration.maxRelativeUncertainty {
            reasons.append(.uncertaintyTooHigh(relative: maxEstimate.relativeUncertainty))
        }
        guard reasons.isEmpty else {
            return unavailable(reasons, diagnostics: diagnostics, trajectory: states)
        }

        let report = SpeedReport(
            maxSpeed: maxEstimate, averageSpeed: avgEstimate, timeOfMaxSpeed: tMax,
            measuredInterval: tStart...tEnd,
            confidence: AnalyzerConfiguration.confidence(forRelativeUncertainty: maxEstimate.relativeUncertainty),
            breakdown: breakdownMax)
        return ShotAnalysis(outcome: .measured, speed: report, diagnostics: diagnostics,
                            restObservationCount: restCount, flightObservationCount: flight.count,
                            warnings: warnings, fittedTrajectory: states)
    }

    // MARK: - Helpers

    /// Time-average of speed by the trapezoid rule = path length / duration.
    static func averageSpeed(times: [Double], speeds: [Double]) -> Double {
        guard times.count >= 2, let first = times.first, let last = times.last, last > first else {
            return speeds.first ?? 0
        }
        var path = 0.0
        for i in 1..<times.count {
            path += 0.5 * (speeds[i] + speeds[i - 1]) * (times[i] - times[i - 1])
        }
        return path / (last - first)
    }

    /// 1σ of f(p) given the covariance of p, by first-order propagation σ² = ∇fᵀ Σ ∇f.
    static func propagate(_ p: [Double], covariance: Matrix, _ f: ([Double]) -> Double) -> Double {
        let scales = [1.0, 1, 1, 10, 10, 10, 0.1, 1, 1, 1]
        var gradient = Array(repeating: 0.0, count: p.count)
        for i in p.indices {
            let h = 1e-6 * max(abs(p[i]), scales[i % scales.count])
            var plus = p
            plus[i] += h
            var minus = p
            minus[i] -= h
            gradient[i] = (f(plus) - f(minus)) / (2 * h)
        }
        let sg = covariance * gradient
        let variance = zip(gradient, sg).map { $0 * $1 }.reduce(0, +)
        return max(variance, 0).squareRoot()
    }

    static func maxGap(_ obs: [BallObservation]) -> Double? {
        guard obs.count >= 2 else { return nil }
        return (1..<obs.count).map { obs[$0].timestamp - obs[$0 - 1].timestamp }.max()
    }

    static func medianInterval(_ obs: [BallObservation]) -> Double? {
        guard obs.count >= 2 else { return nil }
        return FlightFitter.median((1..<obs.count).map { obs[$0].timestamp - obs[$0 - 1].timestamp })
    }
}
