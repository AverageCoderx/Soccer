import Foundation

/// Result of a drop test: how well the app's distance scale agrees with gravity.
public struct ScaleCheckResult: Sendable, Equatable {
    /// Acceleration of the falling ball measured by the app, m/s².
    public var measuredGravity: Double
    /// 1σ statistical uncertainty of `measuredGravity`.
    public var uncertainty: Double
    /// Reference value used (standard gravity 9.81 unless set).
    public var referenceGravity: Double
    /// measured / reference − 1. Since every distance (and so every speed) the
    /// app reports scales the same way, this is also its speed scale error.
    public var scaleError: Double { measuredGravity / referenceGravity - 1 }
    public var scaleErrorUncertainty: Double { uncertainty / referenceGravity }
    /// Angle in the image plane between the measured fall direction and the motion sensor's gravity, degrees.
    public var directionErrorDegrees: Double?
    public var observationCount: Int
    public var duration: Double
}

extension ShotAnalyzer {
    /// Drop test: a ball released from rest in front of the tripod camera.
    ///
    /// The fall is fitted with gravity *free*: the model's "extra acceleration"
    /// gets an essentially flat prior and the fixed gravity is set to zero, so
    /// the fit measures the ball's acceleration in meters per second², using
    /// only the ball-size scale. True gravity is 9.78–9.83 m/s² everywhere on
    /// Earth, so the ratio is an independent check of the scale that every speed
    /// depends on: no tape measure or radar needed.
    public func analyzeDropTest(
        track: [TrackPoint], context: ShotContext, referenceGravity: Double = 9.81
    ) -> (result: ScaleCheckResult?, reasons: [UnavailableReason]) {
        let flight = track.filter { $0.phase == .flight }.map(\.observation).sorted { $0.timestamp < $1.timestamp }
        guard !track.isEmpty else { return (nil, [.ballNotFound]) }
        guard let first = flight.first else { return (nil, [.noFlightDetected]) }
        let window = flight.filter { $0.timestamp - first.timestamp <= 0.7 }
        let duration = (window.last?.timestamp ?? first.timestamp) - first.timestamp
        // The fall must be long enough for its curvature to pin down the
        // acceleration: after 0.2 s from release the ball has dropped ~20 cm.
        guard window.count >= 20, duration >= 0.2 else {
            return (nil, [.insufficientFlightData(observations: window.count, duration: duration)])
        }

        var fitConfig = configuration.fit
        fitConfig.extraAccelerationPriorSigma = 1000
        // Slow balls are below the drag crisis: C_d ≈ 0.45. At drop-test
        // speeds drag is < 0.3 m/s², so this prior barely matters.
        fitConfig.dragCoefficientPrior = 0.45
        fitConfig.dragCoefficientPriorSigma = 0.1
        fitConfig.estimateInitialAcceleration = true
        let physics = FlightPhysics(gravity: .zero, airDensity: configuration.airDensity, ball: context.ball)
        let fitter = FlightFitter(physics: physics, intrinsics: context.intrinsics, configuration: fitConfig)
        guard let fit = fitter.fit(window), fit.converged else { return (nil, [.fitFailed]) }
        if fit.reducedChiSquare > configuration.maxReducedChiSquare {
            return (nil, [.poorModelFit(reducedChiSquare: fit.reducedChiSquare)])
        }

        // The acceleration component toward the camera comes from the ball's
        // change in size and is far noisier than the in-image components. So
        // the magnitude is taken along the motion sensor's "down" direction
        // (good to ~1°) when available, otherwise from the in-image components.
        let a = fit.parameters.extraAcceleration
        let down = context.gravity.normalized
        let useSensor = context.gravityIsMeasured && context.gravity.length > 0
        let magnitude: ([Double]) -> Double = { p in
            let v = Vec3(p[7], p[8], p[9])
            return useSensor ? v.dot(down) : (v.x * v.x + v.y * v.y).squareRoot()
        }
        let g = magnitude(fit.parameters.vector)
        let sigma = Self.propagate(fit.parameters.vector, covariance: fit.covariance, magnitude)
        var directionError: Double?
        if useSensor, a.length > 0 {
            let inPlane = Vec3(a.x, a.y, 0)
            let downInPlane = Vec3(down.x, down.y, 0)
            if inPlane.length > 0, downInPlane.length > 0 {
                let cosine = max(-1, min(1, inPlane.dot(downInPlane) / (inPlane.length * downInPlane.length)))
                directionError = acos(cosine) * 180 / .pi
            }
        }
        let result = ScaleCheckResult(
            measuredGravity: g, uncertainty: sigma, referenceGravity: referenceGravity,
            directionErrorDegrees: directionError, observationCount: fit.usedObservations.count,
            duration: duration)
        if sigma / referenceGravity > 0.05 {
            return (result, [.uncertaintyTooHigh(relative: sigma / referenceGravity)])
        }
        return (result, [])
    }
}
