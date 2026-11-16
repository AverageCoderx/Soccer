import Foundation

/// A simulated shot with known ground truth, for testing the measurement
/// pipeline. This is test data only: it is never presented as a measurement.
public struct SyntheticShotScenario: Sendable {
    public var intrinsics = CameraIntrinsics.fromHorizontalFieldOfView(degrees: 73.7, width: 1920, height: 1080)
    public var ball = BallSpec.size5
    /// True gravity in the camera frame.
    public var gravity = Vec3(0, 9.81, 0)
    public var airDensity = 1.2
    public var dragCoefficient = 0.22
    /// Unmodelled extra acceleration (e.g. Magnus force from spin), m/s².
    public var extraAcceleration = Vec3.zero

    /// Where the ball rests before the kick (camera frame, meters).
    public var restPosition = Vec3(-2.6, 1.0, 6.0)
    /// Velocity right after the kick.
    public var launchVelocity = Vec3(25, -4, 0)

    public var frameRate = 240.0
    /// 1σ jitter of the frame timestamps, seconds.
    public var timestampJitter = 0.00002
    public var droppedFrameProbability = 0.0
    public var restDuration = 0.4
    /// Foot contact: the ball isn't detected for this long before the launch.
    public var contactDuration = 0.010
    public var flightDuration = 0.4

    /// True 1σ detector noise, pixels.
    public var centerNoise = 0.4
    public var radiusNoise = 0.4
    /// Systematic detector error added to every semi-minor axis, pixels.
    public var radiusBias = 0.0
    /// 1σ values the simulated detector reports with each observation.
    public var reportedCenterSigma = 0.5
    public var reportedRadiusSigma = 0.5
    /// Simulated sensor readout time (rolling shutter), seconds.
    public var readoutTime = 0.0

    /// Random false detections per frame.
    public var clutterPerFrame = 0
    /// Adds a large, ball-like detection for the kicking foot near the ball during and after contact.
    public var includeFootDistractor = false
    /// Probability that a ball detection is replaced by a gross outlier.
    public var outlierProbability = 0.0

    public var timestampOrigin = 1000.0
    public var seed: UInt64 = 1

    public init() {}

    public var launchTime: Double { timestampOrigin + restDuration + contactDuration }
}

public struct SyntheticShot: Sendable {
    public var scenario: SyntheticShotScenario
    public var frames: [FrameCandidates]
    /// The noisy detections that really belong to the ball (without clutter).
    public var ballDetections: [BallObservation]

    public var context: ShotContext {
        ShotContext(intrinsics: scenario.intrinsics, ball: scenario.ball, gravity: scenario.gravity, gravityIsMeasured: true)
    }

    private var physics: FlightPhysics {
        FlightPhysics(gravity: scenario.gravity, airDensity: scenario.airDensity, ball: scenario.ball)
    }

    /// True ball state at time t (flight phase).
    public func truthState(at t: Double) -> KinematicState {
        physics.propagate(
            from: KinematicState(time: scenario.launchTime, position: scenario.restPosition, velocity: scenario.launchVelocity),
            to: [t], dragCoefficient: scenario.dragCoefficient,
            extraAcceleration: scenario.extraAcceleration, maxStep: 0.0001)[0]
    }

    public func truthSpeed(at t: Double) -> Double { truthState(at: t).velocity.length }

    public init(_ s: SyntheticShotScenario) {
        scenario = s
        var rng = SeededRandom(seed: s.seed)
        let physics = FlightPhysics(gravity: s.gravity, airDensity: s.airDensity, ball: s.ball)
        let radius = s.ball.radius
        let dt = 1 / s.frameRate
        let total = s.restDuration + s.contactDuration + s.flightDuration
        let frameCount = Int(total * s.frameRate)

        var frameTimes: [Double] = []
        for k in 0..<frameCount {
            if rng.uniform() < s.droppedFrameProbability { continue }
            frameTimes.append(s.timestampOrigin + Double(k) * dt + s.timestampJitter * rng.gaussian())
        }

        // True flight positions, including the rolling-shutter exposure delay of
        // the rows the ball is on: two passes (row at frame time → exposure time).
        let launch = KinematicState(time: s.launchTime, position: s.restPosition, velocity: s.launchVelocity)
        let flightIndices = frameTimes.indices.filter { frameTimes[$0] >= s.launchTime }
        var flightCenters: [Int: Vec3] = [:]
        if !flightIndices.isEmpty {
            let firstPass = physics.propagate(from: launch, to: flightIndices.map { frameTimes[$0] },
                                              dragCoefficient: s.dragCoefficient, extraAcceleration: s.extraAcceleration,
                                              maxStep: 0.0001)
            let exposureTimes = zip(flightIndices, firstPass).map { idx, state -> Double in
                let row = s.intrinsics.cy + s.intrinsics.fy * state.position.y / state.position.z
                return frameTimes[idx] + max(0, min(1, row / Double(s.intrinsics.imageHeight))) * s.readoutTime
            }
            let second = physics.propagate(from: launch, to: exposureTimes, dragCoefficient: s.dragCoefficient,
                                           extraAcceleration: s.extraAcceleration, maxStep: 0.0001)
            for (idx, state) in zip(flightIndices, second) { flightCenters[idx] = state.position }
        }

        var frames: [FrameCandidates] = []
        var ballDetections: [BallObservation] = []
        for (idx, t) in frameTimes.enumerated() {
            var cands: [BallObservation] = []
            let center: Vec3?
            if t < s.timestampOrigin + s.restDuration {
                center = s.restPosition
            } else if t < s.launchTime {
                center = nil  // occluded by the foot
            } else {
                center = flightCenters[idx]
            }

            if let c = center, let img = SphereProjection.project(center: c, radius: radius, intrinsics: s.intrinsics),
               s.intrinsics.contains(u: img.centerU, v: img.centerV, margin: img.semiMinor) {
                var o = BallObservation(
                    timestamp: t,
                    centerU: img.centerU + s.centerNoise * rng.gaussian(),
                    centerV: img.centerV + s.centerNoise * rng.gaussian(),
                    semiMinor: img.semiMinor + s.radiusBias + s.radiusNoise * rng.gaussian(),
                    semiMajor: img.semiMajor,
                    confidence: rng.uniform(0.7...0.95),
                    centerSigma: s.reportedCenterSigma, radiusSigma: s.reportedRadiusSigma)
                if rng.uniform() < s.outlierProbability {
                    let angle = rng.uniform(0...(2 * .pi))
                    let jump = rng.uniform(3...6) * img.semiMinor
                    o.centerU += jump * cos(angle)
                    o.centerV += jump * sin(angle)
                } else {
                    ballDetections.append(o)
                }
                cands.append(o)
            }

            if s.includeFootDistractor, t >= s.launchTime - s.contactDuration - 0.02, t < s.launchTime + 0.03,
               let restImage = SphereProjection.project(center: s.restPosition, radius: radius, intrinsics: s.intrinsics) {
                // The foot follows through along the shot direction, slower than the ball.
                let since = t - (s.launchTime - s.contactDuration)
                let footSpeedPx = 0.3 * s.launchVelocity.x * restImage.semiMinor / radius
                cands.append(BallObservation(
                    timestamp: t,
                    centerU: restImage.centerU - 1.2 * restImage.semiMinor + footSpeedPx * since,
                    centerV: restImage.centerV + 0.8 * restImage.semiMinor,
                    semiMinor: 1.5 * restImage.semiMinor, confidence: 0.45,
                    centerSigma: s.reportedCenterSigma, radiusSigma: s.reportedRadiusSigma))
            }

            for _ in 0..<s.clutterPerFrame {
                cands.append(BallObservation(
                    timestamp: t,
                    centerU: rng.uniform(0...Double(s.intrinsics.imageWidth)),
                    centerV: rng.uniform(0...Double(s.intrinsics.imageHeight)),
                    semiMinor: rng.uniform(5...40), confidence: rng.uniform(0.2...0.6),
                    centerSigma: s.reportedCenterSigma, radiusSigma: s.reportedRadiusSigma))
            }
            cands.shuffle(using: &rng)
            frames.append(FrameCandidates(timestamp: t, candidates: cands))
        }
        self.frames = frames
        self.ballDetections = ballDetections
    }
}
