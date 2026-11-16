import Foundation

/// Constant-velocity Kalman filter on the ball's image position, state
/// [u, v, du/dt, dv/dt].
///
/// Its job is data association, not the final measurement: predicting where
/// the ball should be in the next frame (with the real time step, so dropped
/// frames are handled), gating candidates by Mahalanobis distance, and
/// coasting through brief detection failures. The speed itself comes from the
/// batch physics fit over the whole flight (`FlightFitter`), which is far more
/// accurate than any frame-to-frame estimate.
struct ImageKalmanFilter: Sendable {
    private(set) var state: [Double]
    private(set) var covariance: Matrix

    init(u: Double, v: Double, du: Double, dv: Double, positionVariance: Double, velocityVariance: Double) {
        state = [u, v, du, dv]
        covariance = Matrix.diagonal([positionVariance, positionVariance, velocityVariance, velocityVariance])
    }

    var position: ImagePoint { ImagePoint(u: state[0], v: state[1]) }
    var velocity: ImagePoint { ImagePoint(u: state[2], v: state[3]) }

    /// Advances the state by `dt` seconds. `accelerationSigma` (px/s²) is the
    /// white-noise acceleration that covers gravity, drag and perspective
    /// change; the discrete process noise per axis is
    /// σa² · [[dt⁴/4, dt³/2], [dt³/2, dt²]].
    mutating func predict(dt: Double, accelerationSigma: Double) {
        guard dt > 0 else { return }
        var f = Matrix.identity(4)
        f[0, 2] = dt
        f[1, 3] = dt
        state = f * state
        let q = accelerationSigma * accelerationSigma
        var qm = Matrix(rows: 4, cols: 4)
        let dt2 = dt * dt
        for axis in 0..<2 {
            qm[axis, axis] = q * dt2 * dt2 / 4
            qm[axis, axis + 2] = q * dt2 * dt / 2
            qm[axis + 2, axis] = q * dt2 * dt / 2
            qm[axis + 2, axis + 2] = q * dt2
        }
        covariance = f * covariance * f.transposed + qm
    }

    /// Squared Mahalanobis distance of a measurement from the prediction.
    func mahalanobisSquared(u: Double, v: Double, sigma: Double) -> Double {
        let (innovation, s) = innovationAndCovariance(u: u, v: v, sigma: sigma)
        guard let sInv = s.inverted() else { return .infinity }
        let si = sInv * innovation
        return innovation[0] * si[0] + innovation[1] * si[1]
    }

    mutating func update(u: Double, v: Double, sigma: Double) {
        let (innovation, s) = innovationAndCovariance(u: u, v: v, sigma: sigma)
        guard let sInv = s.inverted() else { return }
        // H = [I₂ 0], so P Hᵀ is the first two columns of P.
        var pht = Matrix(rows: 4, cols: 2)
        for r in 0..<4 {
            pht[r, 0] = covariance[r, 0]
            pht[r, 1] = covariance[r, 1]
        }
        let gain = pht * sInv
        let correction = gain * innovation
        for i in 0..<4 { state[i] += correction[i] }
        var h = Matrix(rows: 2, cols: 4)
        h[0, 0] = 1
        h[1, 1] = 1
        covariance = (Matrix.identity(4) - gain * h) * covariance
    }

    private func innovationAndCovariance(u: Double, v: Double, sigma: Double) -> ([Double], Matrix) {
        let innovation = [u - state[0], v - state[1]]
        var s = Matrix(rows: 2, cols: 2)
        s[0, 0] = covariance[0, 0] + sigma * sigma
        s[0, 1] = covariance[0, 1]
        s[1, 0] = covariance[1, 0]
        s[1, 1] = covariance[1, 1] + sigma * sigma
        return (innovation, s)
    }
}
