import Foundation

/// The image of a ball: an ellipse.
public struct BallImage: Sendable, Equatable {
    public var centerU: Double
    public var centerV: Double
    /// Semi-axis along the radial direction (from the principal point towards the ball), pixels.
    public var semiMajor: Double
    /// Semi-axis perpendicular to the radial direction, pixels.
    public var semiMinor: Double
    /// Direction of the major axis in the image, radians from +u.
    public var majorAxisAngle: Double
}

/// Exact perspective projection of a sphere.
///
/// A sphere doesn't image as a circle unless it's on the optical axis. The rays
/// tangent to the sphere form a circular cone with half-angle α = asin(R/ρ)
/// around the ray to the sphere's centre (ρ = distance to the centre). Cutting
/// that cone with the image plane gives an ellipse. With θ the angle between the
/// centre ray and the optical axis and A = cos²α − sin²θ, in units of the focal
/// length:
///
///     centre offset (radial)  r₀ = sinθ cosθ / A
///     semi-major (radial)     a  = sinα cosα / A
///     semi-minor (tangential) b  = sinα / √A
///
/// Why this matters: near the edge of a wide image (θ ≈ 35°) the ball is
/// stretched ~20% radially. Using its widest extent as "the diameter" would put
/// the distance off by that much. For small balls b ≈ f·R/Z, where Z is depth
/// along the optical axis, so the tangential semi-axis is the right size
/// measurement and the radial one is not. The fitter uses this exact model.
public enum SphereProjection {
    /// Projects a sphere centred at `center` (camera frame, meters) of radius `radius`.
    /// Returns nil when the sphere is behind the camera or the camera is inside it.
    public static func project(center c: Vec3, radius: Double, intrinsics k: CameraIntrinsics) -> BallImage? {
        guard c.z > 0 else { return nil }
        let rho = c.length
        guard rho > radius * 1.000001 else { return nil }
        let sinA = radius / rho
        let cos2A = 1 - sinA * sinA
        let cosA = cos2A.squareRoot()
        let lateral = (c.x * c.x + c.y * c.y).squareRoot()
        let sinT = lateral / rho
        let cosT = c.z / rho
        let a = cos2A - sinT * sinT
        // A ≤ 0 means the tangent cone reaches the image plane's horizon (ball ~90° off axis).
        guard a > 1e-9 else { return nil }
        let r0 = sinT * cosT / a
        let dirX: Double
        let dirY: Double
        if lateral > 1e-12 {
            dirX = c.x / lateral
            dirY = c.y / lateral
        } else {
            dirX = 1
            dirY = 0
        }
        let f = k.focalLength
        return BallImage(
            centerU: k.cx + k.fx * r0 * dirX,
            centerV: k.cy + k.fy * r0 * dirY,
            semiMajor: f * sinA * cosA / a,
            semiMinor: f * sinA / a.squareRoot(),
            majorAxisAngle: atan2(dirY, dirX)
        )
    }

    /// Recovers the sphere's 3D centre from its image centre and tangential
    /// semi-axis by inverting `project` with Newton's method.
    ///
    /// The starting point is the small-ball approximation Z = f·R/b, X = (u−cx)·Z/fx.
    public static func backproject(
        centerU u: Double, centerV v: Double, semiMinor b: Double,
        radius: Double, intrinsics k: CameraIntrinsics
    ) -> Vec3? {
        guard b > 0, radius > 0 else { return nil }
        let z0 = k.focalLength * radius / b
        var c = Vec3((u - k.cx) / k.fx * z0, (v - k.cy) / k.fy * z0, z0)
        for _ in 0..<12 {
            guard let img = project(center: c, radius: radius, intrinsics: k) else { return nil }
            let r = [img.centerU - u, img.centerV - v, img.semiMinor - b]
            if r.allSatisfy({ abs($0) < 1e-10 }) { break }
            var j = Matrix(rows: 3, cols: 3)
            for col in 0..<3 {
                let h = 1e-7 * max(c.length, 1)
                var cp = c
                cp[col] += h
                guard let ip = project(center: cp, radius: radius, intrinsics: k) else { return nil }
                j[0, col] = (ip.centerU - img.centerU) / h
                j[1, col] = (ip.centerV - img.centerV) / h
                j[2, col] = (ip.semiMinor - img.semiMinor) / h
            }
            guard let delta = j.solve(r) else { return nil }
            c = c - Vec3(delta[0], delta[1], delta[2])
            guard c.z > 0 else { return nil }
        }
        return c
    }
}
