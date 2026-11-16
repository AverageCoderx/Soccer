import Foundation

/// Parameters of the fitted flight, at the reference time (first observation).
public struct FlightParameters: Sendable, Equatable {
    public var position: Vec3
    public var velocity: Vec3
    public var dragCoefficient: Double
    public var extraAcceleration: Vec3

    static let count = 10

    init(vector p: [Double]) {
        position = Vec3(p[0], p[1], p[2])
        velocity = Vec3(p[3], p[4], p[5])
        dragCoefficient = p[6]
        extraAcceleration = Vec3(p[7], p[8], p[9])
    }

    public init(position: Vec3, velocity: Vec3, dragCoefficient: Double, extraAcceleration: Vec3) {
        self.position = position
        self.velocity = velocity
        self.dragCoefficient = dragCoefficient
        self.extraAcceleration = extraAcceleration
    }

    var vector: [Double] {
        position.components + velocity.components + [dragCoefficient] + extraAcceleration.components
    }
}

public struct FlightFitConfiguration: Sendable, Equatable {
    /// Prior on the drag coefficient. A soccer ball's C_d drops from ≈0.45 below
    /// the "drag crisis" (slow balls) to ≈0.15–0.25 above it (most shots); a
    /// short flight alone can't pin it down, so it gets a weak prior.
    public var dragCoefficientPrior: Double = 0.30
    public var dragCoefficientPriorSigma: Double = 0.15
    /// Zero-mean prior on the extra constant acceleration (Magnus force, gravity-direction error), m/s².
    public var extraAccelerationPriorSigma: Double = 4.0
    /// Observations whose whitened residual norm exceeds this (after robust
    /// rescaling) are rejected as outliers. √χ²₃(0.9999) ≈ 4.6.
    public var outlierThreshold: Double = 4.6
    public var maxOutlierFraction: Double = 0.2
    public var maxIntegrationStep: Double = 0.0005
    /// Rolling-shutter readout time (s): how long the sensor takes to read from
    /// the first row to the last. A ball at row v is exposed at
    /// timestamp + (v / height) · readoutTime. 0 = not calibrated.
    public var readoutTime: Double = 0
    /// Known detector bias in the measured semi-minor axis, pixels (subtracted).
    public var radiusBiasPixels: Double = 0

    public init() {}
}

public struct FlightFitResult: Sendable {
    public var referenceTime: Double
    public var parameters: FlightParameters
    /// Parameter covariance, scaled up by the reduced χ² when that exceeds 1.
    public var covariance: Matrix
    public var reducedChiSquare: Double
    public var usedObservations: [BallObservation]
    public var rejectedObservations: [BallObservation]
    public var rmsCenterResidualPixels: Double
    public var rmsRadiusResidualPixels: Double
    public var iterations: Int
}

/// Fits a physical flight model to the tracked ball by least squares in image
/// space.
///
/// Measurement model: at each frame's (rolling-shutter-corrected) time, the
/// ball's 3D centre from the equations of motion is projected through the
/// exact sphere projection, giving the predicted ellipse centre and minor
/// semi-axis, compared to what the detector measured. Fitting all frames at
/// once (instead of differencing positions frame to frame) averages out pixel
/// noise: at 240 fps a 2 cm position error between two frames would be a 7 m/s
/// speed error, but over ~60 frames the fit's speed error from pixel noise is
/// tiny.
///
/// Free parameters: initial position (3), initial velocity (3), drag
/// coefficient (1, weak prior), extra constant acceleration (3, zero-mean prior).
public struct FlightFitter: Sendable {
    public var physics: FlightPhysics
    public var intrinsics: CameraIntrinsics
    public var configuration: FlightFitConfiguration

    public init(physics: FlightPhysics, intrinsics: CameraIntrinsics, configuration: FlightFitConfiguration = FlightFitConfiguration()) {
        self.physics = physics
        self.intrinsics = intrinsics
        self.configuration = configuration
    }

    /// Time the ball's centre was actually exposed, correcting for rolling shutter.
    public func effectiveTime(of o: BallObservation) -> Double {
        o.timestamp + (o.centerV / Double(intrinsics.imageHeight)) * configuration.readoutTime
    }

    public func states(for parameters: FlightParameters, referenceTime: Double, at times: [Double]) -> [KinematicState] {
        physics.propagate(
            from: KinematicState(time: referenceTime, position: parameters.position, velocity: parameters.velocity),
            to: times, dragCoefficient: parameters.dragCoefficient,
            extraAcceleration: parameters.extraAcceleration, maxStep: configuration.maxIntegrationStep)
    }

    public func fit(_ observations: [BallObservation]) -> FlightFitResult? {
        var active = observations.sorted { $0.timestamp < $1.timestamp }
        var rejected: [BallObservation] = []
        let maxRejected = Int(configuration.maxOutlierFraction * Double(active.count))
        var previous: [Double]?

        for _ in 0..<5 {
            guard active.count >= 4, let result = fitOnce(active, initial: previous) else { return nil }
            previous = result.solution.parameters

            // Robust outlier rejection: scale residual norms by a median-based
            // noise estimate so one bad frame can't hide behind an inflated χ².
            let norms = result.perObservationNorms
            let medianSquared = Self.median(norms.map { $0 * $0 })
            // Median of a χ² variable with 3 degrees of freedom ≈ 2.366.
            let scale = max(1, medianSquared / 2.366).squareRoot()
            let budget = maxRejected - rejected.count
            let outliers = norms.indices
                .filter { norms[$0] / scale > configuration.outlierThreshold }
                .sorted { norms[$0] > norms[$1] }
                .prefix(max(budget, 0))
            if outliers.isEmpty {
                return makeResult(result, used: active, rejected: rejected)
            }
            let drop = Set(outliers)
            rejected += drop.map { active[$0] }
            active = active.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
        guard let final = fitOnce(active, initial: previous) else { return nil }
        return makeResult(final, used: active, rejected: rejected)
    }

    // MARK: - Internals

    private struct SingleFit {
        var solution: LeastSquaresResult
        var referenceTime: Double
        var perObservationNorms: [Double]
        var centerResiduals: [Double]
        var radiusResiduals: [Double]
    }

    private func fitOnce(_ obs: [BallObservation], initial: [Double]?) -> SingleFit? {
        let times = obs.map(effectiveTime)
        guard let tRef = times.min() else { return nil }
        guard let start = initial ?? initialGuess(obs, times: times, referenceTime: tRef) else { return nil }
        let radius = physics.ball.radius
        let config = configuration
        let k = intrinsics
        let fitter = self

        let problem = LeastSquaresProblem(
            parameterCount: FlightParameters.count,
            parameterScales: [1, 1, 1, 10, 10, 10, 0.1, 1, 1, 1]
        ) { p in
            let params = FlightParameters(vector: p)
            let states = fitter.states(for: params, referenceTime: tRef, at: times)
            var r: [Double] = []
            r.reserveCapacity(obs.count * 3 + 4)
            for (o, s) in zip(obs, states) {
                guard let img = SphereProjection.project(center: s.position, radius: radius, intrinsics: k) else { return nil }
                r.append((img.centerU - o.centerU) / o.centerSigma)
                r.append((img.centerV - o.centerV) / o.centerSigma)
                r.append((img.semiMinor - (o.semiMinor - config.radiusBiasPixels)) / o.radiusSigma)
            }
            r.append((params.dragCoefficient - config.dragCoefficientPrior) / config.dragCoefficientPriorSigma)
            for i in 0..<3 { r.append(params.extraAcceleration[i] / config.extraAccelerationPriorSigma) }
            return r
        }
        guard let solution = LevenbergMarquardt.solve(problem, initial: start) else { return nil }

        var norms: [Double] = []
        var centerRes: [Double] = []
        var radiusRes: [Double] = []
        for i in 0..<obs.count {
            let ru = solution.residuals[3 * i] * obs[i].centerSigma
            let rv = solution.residuals[3 * i + 1] * obs[i].centerSigma
            let rb = solution.residuals[3 * i + 2] * obs[i].radiusSigma
            let wu = solution.residuals[3 * i], wv = solution.residuals[3 * i + 1], wb = solution.residuals[3 * i + 2]
            norms.append((wu * wu + wv * wv + wb * wb).squareRoot())
            centerRes.append(hypot(ru, rv))
            radiusRes.append(rb)
        }
        return SingleFit(solution: solution, referenceTime: tRef, perObservationNorms: norms,
                         centerResiduals: centerRes, radiusResiduals: radiusRes)
    }

    /// Back-projects every observation to 3D and fits a straight line per axis.
    private func initialGuess(_ obs: [BallObservation], times: [Double], referenceTime: Double) -> [Double]? {
        var pts: [(Double, Vec3)] = []
        for (o, t) in zip(obs, times) {
            if let c = SphereProjection.backproject(
                centerU: o.centerU, centerV: o.centerV, semiMinor: o.semiMinor - configuration.radiusBiasPixels,
                radius: physics.ball.radius, intrinsics: intrinsics) {
                pts.append((t - referenceTime, c))
            }
        }
        guard pts.count >= 2 else { return nil }
        let n = Double(pts.count)
        let tm = pts.map(\.0).reduce(0, +) / n
        let pm = pts.map(\.1).reduce(Vec3.zero, +) / n
        var stt = 0.0
        var stp = Vec3.zero
        for (t, p) in pts {
            stt += (t - tm) * (t - tm)
            stp += (p - pm) * (t - tm)
        }
        guard stt > 0 else { return nil }
        let v = stp / stt
        let p0 = pm - v * tm
        return FlightParameters(position: p0, velocity: v, dragCoefficient: configuration.dragCoefficientPrior,
                                extraAcceleration: .zero).vector
    }

    private func makeResult(_ fit: SingleFit, used: [BallObservation], rejected: [BallObservation]) -> FlightFitResult? {
        guard let unscaled = fit.solution.unscaledCovariance else { return nil }
        let chi2 = fit.solution.reducedChiSquare
        let covariance = max(1, chi2) * unscaled
        let n = Double(used.count)
        let rmsCenter = (fit.centerResiduals.map { $0 * $0 }.reduce(0, +) / n).squareRoot()
        let rmsRadius = (fit.radiusResiduals.map { $0 * $0 }.reduce(0, +) / n).squareRoot()
        return FlightFitResult(
            referenceTime: fit.referenceTime,
            parameters: FlightParameters(vector: fit.solution.parameters),
            covariance: covariance, reducedChiSquare: chi2,
            usedObservations: used, rejectedObservations: rejected,
            rmsCenterResidualPixels: rmsCenter, rmsRadiusResidualPixels: rmsRadius,
            iterations: fit.solution.iterations)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? 0.5 * (s[m - 1] + s[m]) : s[m]
    }
}
