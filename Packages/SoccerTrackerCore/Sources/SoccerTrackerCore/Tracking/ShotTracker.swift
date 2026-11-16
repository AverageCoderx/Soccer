import Foundation

public struct TrackerConfiguration: Sendable, Equatable {
    /// Upper bound on ball speed, m/s. The hardest shots on record are a little
    /// under 60 m/s (~210 km/h).
    public var maxBallSpeed: Double = 60
    /// Minimum speed for acquiring a ball that's already moving (no rest phase seen), m/s.
    public var minAcquisitionSpeed: Double = 2
    public var minCandidateConfidence: Double = 0.2
    public var minRadiusPixels: Double = 3

    // Rest phase (ball on the kick spot).
    public var restConfirmFrames: Int = 5
    /// Max centre offset from the rest estimate, as a fraction of the ball's semi-minor axis.
    public var restPositionTolerance: Double = 0.35
    /// Max relative size difference from the rest estimate.
    public var restRadiusTolerance: Double = 0.15
    public var restBufferTimeout: Double = 0.1
    /// Rest is abandoned if the ball isn't seen there for this long and no launch is under way.
    public var restLostTimeout: Double = 2.0
    /// Smoothing factor for the rest estimate (exponential moving average).
    public var restSmoothing: Double = 0.1

    // Launch detection.
    /// A launch candidate must be at least this far from the rest position (× semi-minor axis).
    public var launchMinDisplacement: Double = 0.6
    /// Allowed size ratio of a launch candidate to the resting ball.
    public var launchRadiusRatio: ClosedRange<Double> = 0.7...1.4
    /// Allowed size ratio between consecutive points of a candidate chain.
    public var chainRadiusRatio: ClosedRange<Double> = 0.8...1.25
    /// A launch chain is dropped after this many consecutive frames without an extension.
    public var chainMaxMissedFrames: Int = 2
    /// A launch path traced backwards must pass this close to the kick spot (× semi-minor axis).
    public var launchOriginTolerance: Double = 1.5
    public var launchConfirmPoints: Int = 3
    /// Max deviation from a constant-velocity line for a confirmed launch (× semi-minor axis).
    public var launchLineTolerance: Double = 0.35
    public var maxChains: Int = 8

    // Flight.
    /// White-noise acceleration for the image Kalman filter, m/s² (converted to px/s² per frame).
    public var flightAccelerationNoise: Double = 60
    /// Mahalanobis gate (χ², 2 degrees of freedom; 13.8 ≈ 99.9%).
    public var flightGateChiSquare: Double = 13.8
    /// Max relative size change between consecutive flight detections.
    public var flightRadiusTolerance: Double = 0.25
    /// The flight ends when the ball hasn't been seen for this long (left the frame, bounced, occluded).
    public var maxFlightGap: Double = 0.05
    public var maxFlightDuration: Double = 1.5

    public init() {}
}

/// Follows one ball through a shot: resting on the kick spot, launched, in
/// flight. Identity is kept frame to frame (rest consistency, then
/// constant-velocity chains for the launch, then a gated Kalman filter in
/// flight), so players, shoes, cones and other round things are rejected by
/// position, size and motion consistency rather than by appearance alone.
public struct ShotTracker: Sendable {
    public enum State: String, Sendable, Codable {
        case searching, resting, inFlight, finished
    }

    struct RestEstimate: Sendable {
        var u: Double
        var v: Double
        var radius: Double
        var lastSeen: Double
        var count: Int
    }

    public let configuration: TrackerConfiguration
    /// Physical ball radius in meters, used to convert speeds to pixels:
    /// near the ball, pixels per meter ≈ f/Z ≈ semiMinor / radius.
    public let ballRadius: Double
    /// Optional user tap on the ball; when set, the resting ball nearest to it is preferred.
    public var restHint: ImagePoint?

    public private(set) var state: State = .searching
    public private(set) var points: [TrackPoint] = []
    /// Confidence of the current track in [0, 1], for the live UI.
    public private(set) var currentConfidence: Double = 0

    private var restBuffer: [BallObservation] = []
    private var rest: RestEstimate?
    private var chains: [[BallObservation]] = []
    private var filter: ImageKalmanFilter?
    private var filterTime: Double = 0
    private var lastFlight: BallObservation?
    private var flightStart: Double?
    private var lastFrameTime: Double?
    /// Running estimate of the frame interval, from the real timestamps.
    private var frameInterval: Double?

    public init(configuration: TrackerConfiguration = TrackerConfiguration(), ballRadius: Double, restHint: ImagePoint? = nil) {
        self.configuration = configuration
        self.ballRadius = ballRadius
        self.restHint = restHint
    }

    public var restObservations: [BallObservation] {
        points.filter { $0.phase == .rest }.map(\.observation)
    }

    public var flightObservations: [BallObservation] {
        points.filter { $0.phase == .flight }.map(\.observation)
    }

    /// Where the ball is expected at time `t` while in flight (for guiding the detector).
    public func predictedPosition(at t: Double) -> ImagePoint? {
        guard state == .inFlight, let kf = filter else { return nil }
        let dt = t - filterTime
        return ImagePoint(u: kf.position.u + kf.velocity.u * dt, v: kf.position.v + kf.velocity.v * dt)
    }

    /// The resting ball's current estimate, if the tracker has confirmed one.
    public var restPosition: ImagePoint? {
        rest.map { ImagePoint(u: $0.u, v: $0.v) }
    }

    /// Feeds one frame. Frames must arrive in timestamp order.
    public mutating func process(_ frame: FrameCandidates) {
        let c = configuration
        let candidates = frame.candidates.filter {
            $0.confidence >= c.minCandidateConfidence && $0.semiMinor >= c.minRadiusPixels
                && $0.centerU.isFinite && $0.centerV.isFinite && $0.semiMinor.isFinite
        }
        let t = frame.timestamp
        if let last = lastFrameTime, t > last {
            let dt = t - last
            // Track the typical interval; ignore gaps from dropped frames.
            if let fi = frameInterval {
                if dt < 1.5 * fi { frameInterval = fi + 0.1 * (dt - fi) }
            } else {
                frameInterval = dt
            }
        }
        lastFrameTime = t
        switch state {
        case .searching: processSearching(candidates, t)
        case .resting: processResting(candidates, t)
        case .inFlight: processFlight(candidates, t)
        case .finished: return
        }
    }

    // MARK: - Searching

    private mutating func processSearching(_ cands: [BallObservation], _ t: Double) {
        var used = Set<Int>()
        if let last = restBuffer.last {
            let ref = Self.mean(restBuffer)
            if let i = bestRestMatch(cands, u: ref.u, v: ref.v, radius: ref.radius) {
                restBuffer.append(cands[i])
                used.insert(i)
                currentConfidence = 0.5 * restBuffer.map(\.confidence).reduce(0, +) / Double(restBuffer.count)
                if restBuffer.count >= configuration.restConfirmFrames {
                    confirmRest()
                    return
                }
            } else if t - last.timestamp > configuration.restBufferTimeout {
                restBuffer = []
            }
        }
        if restBuffer.isEmpty, let i = seedIndex(cands) {
            restBuffer = [cands[i]]
        }
        let remaining = cands.enumerated().filter { !used.contains($0.offset) }.map(\.element)
        advanceChains(remaining, t)
    }

    private func seedIndex(_ cands: [BallObservation]) -> Int? {
        guard !cands.isEmpty else { return nil }
        if let hint = restHint {
            return cands.indices.min { cands[$0].distance(u: hint.u, v: hint.v) < cands[$1].distance(u: hint.u, v: hint.v) }
        }
        return cands.indices.max { cands[$0].confidence < cands[$1].confidence }
    }

    private func bestRestMatch(_ cands: [BallObservation], u: Double, v: Double, radius: Double) -> Int? {
        var best: Int?
        var bestDistance = Double.infinity
        for (i, cand) in cands.enumerated() {
            let d = cand.distance(u: u, v: v)
            let tolerance = max(configuration.restPositionTolerance * radius, 3 * cand.centerSigma)
            let sizeOK = abs(cand.semiMinor / radius - 1) <= configuration.restRadiusTolerance
            if d <= tolerance, sizeOK, d < bestDistance {
                best = i
                bestDistance = d
            }
        }
        return best
    }

    private mutating func confirmRest() {
        let m = Self.mean(restBuffer)
        rest = RestEstimate(u: m.u, v: m.v, radius: m.radius, lastSeen: restBuffer.last!.timestamp, count: restBuffer.count)
        points += restBuffer.map { TrackPoint(observation: $0, phase: .rest) }
        restBuffer = []
        chains = []
        state = .resting
    }

    // MARK: - Resting

    private mutating func processResting(_ cands: [BallObservation], _ t: Double) {
        guard var r = rest else {
            state = .searching
            return
        }
        if let i = bestRestMatch(cands, u: r.u, v: r.v, radius: r.radius) {
            let o = cands[i]
            let a = configuration.restSmoothing
            r.u += a * (o.centerU - r.u)
            r.v += a * (o.centerV - r.v)
            r.radius += a * (o.semiMinor - r.radius)
            r.lastSeen = t
            r.count += 1
            rest = r
            points.append(TrackPoint(observation: o, phase: .rest))
            currentConfidence = o.confidence
            // The ball is still on the spot, so nothing seen so far can be its flight.
            chains = []
            return
        } else if t - r.lastSeen > configuration.restLostTimeout && chains.isEmpty {
            // The ball was picked up or moved off: start over.
            rest = nil
            points.removeAll { $0.phase == .rest }
            state = .searching
            currentConfidence = 0
            return
        } else {
            currentConfidence *= 0.9
        }
        advanceChains(cands, t)
    }

    // MARK: - Launch chains

    /// Candidate trajectories for the launch. Each new candidate either extends
    /// an existing chain (if it's where that chain predicts) or starts a new one
    /// (if it's a plausible first flight position). The first chain with enough
    /// points on a consistent constant-velocity line becomes the flight.
    private mutating func advanceChains(_ cands: [BallObservation], _ t: Double) {
        var used = Set<Int>()
        var updated: [[BallObservation]] = []
        for chain in chains.sorted(by: { $0.count > $1.count }) {
            guard let last = chain.last, t - last.timestamp <= chainTimeout else { continue }
            var bestIndex: Int?
            var bestError = Double.infinity
            for (i, cand) in cands.enumerated() where !used.contains(i) {
                if let e = extensionError(chain, cand), e < bestError {
                    bestIndex = i
                    bestError = e
                }
            }
            if let i = bestIndex {
                used.insert(i)
                updated.append(chain + [cands[i]])
            } else {
                updated.append(chain)
            }
        }
        for (i, cand) in cands.enumerated() where !used.contains(i) && canStartChain(cand, t) {
            updated.append([cand])
        }
        updated.sort { lhs, rhs in
            lhs.count != rhs.count ? lhs.count > rhs.count : lhs.last!.timestamp > rhs.last!.timestamp
        }
        chains = Array(updated.prefix(configuration.maxChains))

        let confirmed = chains.filter { $0.count >= configuration.launchConfirmPoints && isConsistentLaunch($0) }
        if let best = confirmed.max(by: { Self.meanConfidence($0) < Self.meanConfidence($1) }) {
            startFlight(best)
        }
    }

    /// Time after which an unextended chain is dropped.
    private var chainTimeout: Double {
        (Double(configuration.chainMaxMissedFrames) + 1.5) * (frameInterval ?? 1.0 / 60)
    }

    private func canStartChain(_ cand: BallObservation, _ t: Double) -> Bool {
        guard let r = rest else { return true }
        let d = cand.distance(u: r.u, v: r.v)
        guard d >= configuration.launchMinDisplacement * r.radius else { return false }
        guard configuration.launchRadiusRatio.contains(cand.semiMinor / r.radius) else { return false }
        let elapsed = max(t - r.lastSeen, 1e-3)
        let reach = configuration.maxBallSpeed * elapsed * (r.radius / ballRadius) + 2 * r.radius
        return d <= reach
    }

    private func extensionError(_ chain: [BallObservation], _ cand: BallObservation) -> Double? {
        guard let last = chain.last else { return nil }
        let dt = cand.timestamp - last.timestamp
        guard dt > 0 else { return nil }
        guard configuration.chainRadiusRatio.contains(cand.semiMinor / last.semiMinor) else { return nil }
        let pxPerMeter = last.semiMinor / ballRadius
        let d = cand.distance(to: last)

        if chain.count == 1 {
            let reach = configuration.maxBallSpeed * dt * pxPerMeter + 3 * cand.centerSigma + 0.25 * last.semiMinor
            guard d <= reach else { return nil }
            if let r = rest {
                // Must keep moving away from the kick spot (allowing for noise).
                guard cand.distance(u: r.u, v: r.v) > last.distance(u: r.u, v: r.v) - 2 * cand.centerSigma else { return nil }
            } else {
                guard d >= configuration.minAcquisitionSpeed * dt * pxPerMeter else { return nil }
            }
            return d / reach
        }

        let prev = chain[chain.count - 2]
        let dtPrev = last.timestamp - prev.timestamp
        guard dtPrev > 0 else { return nil }
        let vu = (last.centerU - prev.centerU) / dtPrev
        let vv = (last.centerV - prev.centerV) / dtPrev
        let error = cand.distance(u: last.centerU + vu * dt, v: last.centerV + vv * dt)
        let span = dt + dtPrev
        let accelerationSlack = 0.5 * configuration.flightAccelerationNoise * span * span * pxPerMeter
        let tolerance = max(0.5 * last.semiMinor, 4 * cand.centerSigma) + accelerationSlack
        guard error <= tolerance else { return nil }
        return error / tolerance
    }

    private func isConsistentLaunch(_ chain: [BallObservation]) -> Bool {
        guard let line = Self.fitLine(chain) else { return false }
        let meanRadius = chain.map(\.semiMinor).reduce(0, +) / Double(chain.count)
        let maxSigma = chain.map(\.centerSigma).max() ?? 0
        let tolerance = max(configuration.launchLineTolerance * meanRadius, 3 * maxSigma)
        for o in chain {
            let dt = o.timestamp - line.t0
            let e = o.distance(u: line.u0 + line.vu * dt, v: line.v0 + line.vv * dt)
            if e > tolerance { return false }
        }
        let speed = hypot(line.vu, line.vv) * ballRadius / meanRadius
        if speed > configuration.maxBallSpeed * 1.1 { return false }
        if let r = rest {
            // The ball was launched from the kick spot: tracing the path back,
            // it must pass close to the spot, and reach it before the first point.
            let speedPx2 = line.vu * line.vu + line.vv * line.vv
            guard speedPx2 > 0 else { return false }
            let tStar = ((r.u - line.u0) * line.vu + (r.v - line.v0) * line.vv) / speedPx2
            let closest = hypot(line.u0 + line.vu * tStar - r.u, line.v0 + line.vv * tStar - r.v)
            if closest > configuration.launchOriginTolerance * r.radius + 3 * maxSigma { return false }
            if line.t0 + tStar > chain[0].timestamp { return false }
        }
        if rest == nil && speed < configuration.minAcquisitionSpeed { return false }
        return true
    }

    private mutating func startFlight(_ chain: [BallObservation]) {
        guard let line = Self.fitLine(chain), let last = chain.last else { return }
        let dt = last.timestamp - line.t0
        let speedPx = hypot(line.vu, line.vv)
        let sigma = last.centerSigma
        filter = ImageKalmanFilter(
            u: line.u0 + line.vu * dt, v: line.v0 + line.vv * dt, du: line.vu, dv: line.vv,
            positionVariance: sigma * sigma,
            velocityVariance: pow(max(0.2 * speedPx, 20), 2)
        )
        filterTime = last.timestamp
        points += chain.map { TrackPoint(observation: $0, phase: .flight) }
        lastFlight = last
        flightStart = chain.first?.timestamp
        chains = []
        state = .inFlight
        currentConfidence = Self.meanConfidence(chain)
    }

    // MARK: - Flight

    private mutating func processFlight(_ cands: [BallObservation], _ t: Double) {
        guard var kf = filter, let last = lastFlight else {
            state = .finished
            return
        }
        let pxPerMeter = last.semiMinor / ballRadius
        kf.predict(dt: t - filterTime, accelerationSigma: configuration.flightAccelerationNoise * pxPerMeter)
        filterTime = t

        var best: Int?
        var bestDistance = Double.infinity
        for (i, cand) in cands.enumerated() {
            guard abs(cand.semiMinor / last.semiMinor - 1) <= configuration.flightRadiusTolerance else { continue }
            let m = kf.mahalanobisSquared(u: cand.centerU, v: cand.centerV, sigma: cand.centerSigma)
            if m <= configuration.flightGateChiSquare, m < bestDistance {
                best = i
                bestDistance = m
            }
        }
        if let i = best {
            let o = cands[i]
            kf.update(u: o.centerU, v: o.centerV, sigma: o.centerSigma)
            points.append(TrackPoint(observation: o, phase: .flight))
            lastFlight = o
            currentConfidence = o.confidence * exp(-bestDistance / (2 * configuration.flightGateChiSquare))
        } else {
            currentConfidence *= 0.8
            if t - last.timestamp > configuration.maxFlightGap { state = .finished }
        }
        if let start = flightStart, t - start > configuration.maxFlightDuration { state = .finished }
        filter = kf
    }

    // MARK: - Helpers

    private struct Line {
        var t0: Double
        var u0: Double
        var v0: Double
        var vu: Double
        var vv: Double
    }

    /// Least-squares constant-velocity line through the chain's image positions.
    private static func fitLine(_ obs: [BallObservation]) -> Line? {
        guard obs.count >= 2 else { return nil }
        let t0 = obs[0].timestamp
        let n = Double(obs.count)
        let ts = obs.map { $0.timestamp - t0 }
        let tm = ts.reduce(0, +) / n
        let um = obs.map(\.centerU).reduce(0, +) / n
        let vm = obs.map(\.centerV).reduce(0, +) / n
        var stt = 0.0, stu = 0.0, stv = 0.0
        for (t, o) in zip(ts, obs) {
            stt += (t - tm) * (t - tm)
            stu += (t - tm) * (o.centerU - um)
            stv += (t - tm) * (o.centerV - vm)
        }
        guard stt > 0 else { return nil }
        let vu = stu / stt
        let vv = stv / stt
        return Line(t0: t0, u0: um - vu * tm, v0: vm - vv * tm, vu: vu, vv: vv)
    }

    private static func mean(_ obs: [BallObservation]) -> (u: Double, v: Double, radius: Double) {
        let n = Double(obs.count)
        return (obs.map(\.centerU).reduce(0, +) / n,
                obs.map(\.centerV).reduce(0, +) / n,
                obs.map(\.semiMinor).reduce(0, +) / n)
    }

    private static func meanConfidence(_ obs: [BallObservation]) -> Double {
        obs.isEmpty ? 0 : obs.map(\.confidence).reduce(0, +) / Double(obs.count)
    }
}
