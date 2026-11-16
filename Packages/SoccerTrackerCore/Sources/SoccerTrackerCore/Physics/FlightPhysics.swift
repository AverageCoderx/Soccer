import Foundation

/// Position and velocity of the ball's centre at a time (camera frame, SI units).
public struct KinematicState: Sendable, Equatable {
    public var time: Double
    public var position: Vec3
    public var velocity: Vec3

    public init(time: Double, position: Vec3, velocity: Vec3) {
        self.time = time
        self.position = position
        self.velocity = velocity
    }
}

/// Equations of motion for a ball in flight:
///
///     dv/dt = g + a_extra − k |v| v,    k = ρ C_d A / (2 m)
///
/// The last term is quadratic aerodynamic drag, F = ½ ρ C_d A v², acting
/// opposite to the velocity, divided by the mass. For a size-5 ball at 30 m/s
/// with C_d ≈ 0.25 that's ≈ 12 m/s² of deceleration: the ball loses roughly 4%
/// of its speed every 0.1 s, so the fit must model drag rather than assume a
/// constant speed. `a_extra` is a small constant acceleration that absorbs
/// unmodelled effects (Magnus force from spin, error in the gravity direction).
public struct FlightPhysics: Sendable {
    /// Gravity in the camera frame, m/s² (|g| ≈ 9.81).
    public var gravity: Vec3
    /// Air density, kg/m³ (1.2 at sea level, ~20 °C).
    public var airDensity: Double
    public var ball: BallSpec

    public init(gravity: Vec3, airDensity: Double = 1.2, ball: BallSpec) {
        self.gravity = gravity
        self.airDensity = airDensity
        self.ball = ball
    }

    public func dragConstant(dragCoefficient cd: Double) -> Double {
        0.5 * airDensity * max(cd, 0) * ball.crossSectionArea / ball.mass
    }

    public func acceleration(velocity v: Vec3, dragCoefficient cd: Double, extraAcceleration: Vec3) -> Vec3 {
        let k = dragConstant(dragCoefficient: cd)
        return gravity + extraAcceleration - v * (k * v.length)
    }

    /// Integrates the equations of motion from `initial` to each requested time
    /// (forwards or backwards) with classical RK4, using steps no larger than
    /// `maxStep`. The output is in the same order as `times`.
    public func propagate(
        from initial: KinematicState, to times: [Double],
        dragCoefficient cd: Double, extraAcceleration: Vec3, maxStep: Double = 0.0005
    ) -> [KinematicState] {
        var out = Array(repeating: initial, count: times.count)
        let order = times.indices.sorted { times[$0] < times[$1] }
        let forward = order.filter { times[$0] >= initial.time }
        let backward = order.filter { times[$0] < initial.time }.reversed()

        for group in [Array(forward), Array(backward)] {
            var p = initial.position
            var v = initial.velocity
            var t = initial.time
            for idx in group {
                let target = times[idx]
                let span = target - t
                if span != 0 {
                    let n = max(1, Int((abs(span) / maxStep).rounded(.up)))
                    let h = span / Double(n)
                    for _ in 0..<n {
                        rk4Step(position: &p, velocity: &v, h: h, cd: cd, extra: extraAcceleration)
                    }
                    t = target
                }
                out[idx] = KinematicState(time: target, position: p, velocity: v)
            }
        }
        return out
    }

    private func rk4Step(position p: inout Vec3, velocity v: inout Vec3, h: Double, cd: Double, extra: Vec3) {
        let k1v = acceleration(velocity: v, dragCoefficient: cd, extraAcceleration: extra)
        let k1p = v
        let v2 = v + k1v * (h / 2)
        let k2v = acceleration(velocity: v2, dragCoefficient: cd, extraAcceleration: extra)
        let k2p = v2
        let v3 = v + k2v * (h / 2)
        let k3v = acceleration(velocity: v3, dragCoefficient: cd, extraAcceleration: extra)
        let k3p = v3
        let v4 = v + k3v * h
        let k4v = acceleration(velocity: v4, dragCoefficient: cd, extraAcceleration: extra)
        let k4p = v4
        p += (k1p + 2 * k2p + 2 * k3p + k4p) * (h / 6)
        v += (k1v + 2 * k2v + 2 * k3v + k4v) * (h / 6)
    }
}
