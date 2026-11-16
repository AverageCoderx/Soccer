import Foundation

public struct BallRefinerConfiguration: Sendable, Equatable {
    public var rayCount: Int = 48
    /// Search range along each ray, as multiples of the expected radius.
    public var minRadiusFactor: Double = 0.45
    public var maxRadiusFactor: Double = 1.9
    public var sampleStep: Double = 0.5
    /// Minimum edge contrast (gray levels per pixel) for an edge point to count.
    public var minEdgeStrength: Double = 4
    /// Along a ray, the outermost gradient peak at least this fraction of the
    /// ray's strongest peak is taken as the ball's outline (so dark panels
    /// inside the ball don't win over the ball/grass edge).
    public var outermostPeakFraction: Double = 0.3
    public var minInliers: Int = 12
    public var passes: Int = 3

    public init() {}
}

/// A ball outline measured in the image.
public struct RefinedBall: Sendable, Equatable {
    public var centerU: Double
    public var centerV: Double
    public var semiMinor: Double
    public var semiMajor: Double
    public var majorAxisAngle: Double
    /// RMS distance of the edge points from the fitted outline, pixels.
    public var rmsResidual: Double
    public var inliers: Int
    public var rays: Int
    public var medianEdgeStrength: Double
    /// Heuristic quality in [0, 1] from edge coverage, contrast and fit residual.
    public var confidence: Double
    public var centerSigma: Double
    public var radiusSigma: Double

    public init(centerU: Double, centerV: Double, semiMinor: Double, semiMajor: Double, majorAxisAngle: Double = 0,
                rmsResidual: Double = 0, inliers: Int = 0, rays: Int = 0, medianEdgeStrength: Double = 0,
                confidence: Double, centerSigma: Double = 0.5, radiusSigma: Double = 0.5) {
        self.centerU = centerU
        self.centerV = centerV
        self.semiMinor = semiMinor
        self.semiMajor = semiMajor
        self.majorAxisAngle = majorAxisAngle
        self.rmsResidual = rmsResidual
        self.inliers = inliers
        self.rays = rays
        self.medianEdgeStrength = medianEdgeStrength
        self.confidence = confidence
        self.centerSigma = centerSigma
        self.radiusSigma = radiusSigma
    }

    public func observation(timestamp: Double) -> BallObservation {
        BallObservation(timestamp: timestamp, centerU: centerU, centerV: centerV, semiMinor: semiMinor,
                        semiMajor: semiMajor, confidence: confidence,
                        centerSigma: centerSigma, radiusSigma: radiusSigma)
    }
}

/// Sub-pixel measurement of a ball's outline around a seed point.
///
/// Rays are cast from the seed; along each, the ball's edge is the outermost
/// strong intensity gradient, located to sub-pixel precision with a parabola
/// fit. A circle is fitted to the edge points (algebraic least squares, with
/// robust outlier rejection), re-seeded from its centre, and repeated. Finally
/// the radial distance is fitted as R + A·cos2θ + B·sin2θ: the second harmonic
/// is the ellipse's elongation (from perspective or motion blur), giving the
/// semi-major R + √(A²+B²) and the semi-minor R − √(A²+B²). The semi-minor is
/// what the distance measurement uses (see `SphereProjection`).
public enum BallRefiner {
    public static func refine(
        image: GrayImage, seedU: Double, seedV: Double, expectedRadius: Double,
        configuration c: BallRefinerConfiguration = BallRefinerConfiguration()
    ) -> RefinedBall? {
        guard expectedRadius >= 2 else { return nil }
        var cu = seedU
        var cv = seedV
        var radius = expectedRadius
        var last: (points: [(theta: Double, x: Double, y: Double)], strengths: [Double])?

        for pass in 0..<c.passes {
            // First pass searches widely around the seed; later passes are
            // centred on the fit and search a tighter band.
            let lo = pass == 0 ? c.minRadiusFactor : 0.7
            let hi = pass == 0 ? c.maxRadiusFactor : 1.35
            guard let edges = castRays(image, cu, cv, radius * lo, radius * hi, c) else { return nil }
            guard edges.points.count >= c.minInliers,
                  let circle = robustCircle(edges.points.map { ($0.x, $0.y) }) else { return nil }
            // Reject wild jumps: the outline must be near where we looked.
            guard hypot(circle.u - cu, circle.v - cv) < 1.5 * radius + 3,
                  circle.r > 0.4 * expectedRadius, circle.r < 2.2 * expectedRadius else { return nil }
            cu = circle.u
            cv = circle.v
            radius = circle.r
            last = edges
        }
        guard let edges = last else { return nil }

        // Inliers relative to the final circle.
        var thetas: [Double] = []
        var dists: [Double] = []
        var strengths: [Double] = []
        for (p, s) in zip(edges.points, edges.strengths) {
            let d = hypot(p.x - cu, p.y - cv)
            if abs(d - radius) < max(2.0, 0.2 * radius) {
                thetas.append(atan2(p.y - cv, p.x - cu))
                dists.append(d)
                strengths.append(s)
            }
        }
        guard dists.count >= c.minInliers else { return nil }

        // Ellipse elongation from the second harmonic of r(θ).
        guard let harmonic = fitHarmonic(thetas, dists) else { return nil }
        let elongation = (harmonic.a * harmonic.a + harmonic.b * harmonic.b).squareRoot()
        let semiMajor = harmonic.r0 + elongation
        let semiMinor = harmonic.r0 - elongation
        guard semiMinor > 1 else { return nil }
        let majorAngle = 0.5 * atan2(harmonic.b, harmonic.a)
        var ss = 0.0
        for (t, d) in zip(thetas, dists) {
            let model = harmonic.r0 + harmonic.a * cos(2 * t) + harmonic.b * sin(2 * t)
            ss += (d - model) * (d - model)
        }
        let rms = (ss / Double(dists.count)).squareRoot()
        let medianStrength = FlightFitter.median(strengths)

        let coverage = Double(dists.count) / Double(c.rayCount)
        let contrast = min(1, medianStrength / 25)
        let sharpness = exp(-rms / 1.2)
        let roundness = semiMajor / semiMinor < 2.5 ? 1.0 : 0.3
        let confidence = max(0, min(1, coverage * (0.4 + 0.6 * contrast) * sharpness * roundness))

        // Standard errors of the centre and radius from the residual scatter
        // (n points around the circle: σ_centre ≈ rms·√(2/n), σ_r ≈ rms/√n),
        // floored because edge localisation also has small systematic errors.
        let n = Double(dists.count)
        let centerSigma = max(0.15, rms * (2 / n).squareRoot() * 1.5)
        let radiusSigma = max(0.15, rms / n.squareRoot() * 1.5)

        return RefinedBall(centerU: cu, centerV: cv, semiMinor: semiMinor, semiMajor: semiMajor,
                           majorAxisAngle: majorAngle, rmsResidual: rms, inliers: dists.count,
                           rays: c.rayCount, medianEdgeStrength: medianStrength, confidence: confidence,
                           centerSigma: centerSigma, radiusSigma: radiusSigma)
    }

    private static func castRays(
        _ image: GrayImage, _ cu: Double, _ cv: Double, _ rMin: Double, _ rMax: Double, _ c: BallRefinerConfiguration
    ) -> (points: [(theta: Double, x: Double, y: Double)], strengths: [Double])? {
        let start = max(1, rMin - 1)
        let steps = Int(((rMax + 1) - start) / c.sampleStep)
        guard steps >= 4 else { return nil }
        var points: [(theta: Double, x: Double, y: Double)] = []
        var strengths: [Double] = []
        var profile = [Double](repeating: 0, count: steps + 1)

        for i in 0..<c.rayCount {
            let theta = 2 * Double.pi * Double(i) / Double(c.rayCount)
            let dx = cos(theta)
            let dy = sin(theta)
            var valid = 0
            for k in 0...steps {
                let s = start + Double(k) * c.sampleStep
                guard let value = image.sample(cu + dx * s, cv + dy * s) else { break }
                profile[k] = value
                valid = k + 1
            }
            guard valid >= 5 else { continue }
            // Central-difference gradient magnitude along the ray.
            var grad = [Double](repeating: 0, count: valid)
            for k in 1..<(valid - 1) {
                grad[k] = abs(profile[k + 1] - profile[k - 1]) / (2 * c.sampleStep)
            }
            var maxGrad = 0.0
            for k in 1..<(valid - 1) {
                let s = start + Double(k) * c.sampleStep
                if s >= rMin && s <= rMax { maxGrad = max(maxGrad, grad[k]) }
            }
            guard maxGrad >= c.minEdgeStrength else { continue }
            // Outermost local peak that is strong enough.
            var chosen = -1
            for k in stride(from: valid - 2, through: 1, by: -1) {
                let s = start + Double(k) * c.sampleStep
                guard s >= rMin && s <= rMax else { continue }
                if grad[k] >= c.outermostPeakFraction * maxGrad,
                   grad[k] >= grad[k - 1], grad[k] >= grad[k + 1] {
                    chosen = k
                    break
                }
            }
            guard chosen > 0 else { continue }
            // Parabolic sub-sample peak.
            let gm = grad[chosen - 1], g0 = grad[chosen], gp = grad[chosen + 1]
            let denom = gm - 2 * g0 + gp
            let offset = abs(denom) > 1e-12 ? max(-0.5, min(0.5, 0.5 * (gm - gp) / denom)) : 0
            let s = start + (Double(chosen) + offset) * c.sampleStep
            points.append((theta, cu + dx * s, cv + dy * s))
            strengths.append(g0)
        }
        return (points, strengths)
    }

    /// Algebraic (Kåsa) circle fit with iterative rejection of points far from the fit.
    static func robustCircle(_ pts: [(Double, Double)]) -> (u: Double, v: Double, r: Double)? {
        var active = pts
        var circle: (u: Double, v: Double, r: Double)?
        for _ in 0..<4 {
            guard active.count >= 5, let fit = kasa(active) else { return circle }
            circle = fit
            let residuals = active.map { abs(hypot($0.0 - fit.u, $0.1 - fit.v) - fit.r) }
            let mad = FlightFitter.median(residuals)
            let limit = max(1.0, 3 * 1.4826 * mad)
            let kept = zip(active, residuals).filter { $0.1 <= limit }.map(\.0)
            if kept.count == active.count { break }
            active = kept
        }
        return circle
    }

    /// Minimises Σ(x² + y² + D·x + E·y + F)².
    static func kasa(_ pts: [(Double, Double)]) -> (u: Double, v: Double, r: Double)? {
        let n = Double(pts.count)
        let mx = pts.map(\.0).reduce(0, +) / n
        let my = pts.map(\.1).reduce(0, +) / n
        var a = Matrix(rows: 3, cols: 3)
        var b = [0.0, 0.0, 0.0]
        for (px, py) in pts {
            let x = px - mx, y = py - my
            let row = [x, y, 1.0]
            let z = -(x * x + y * y)
            for i in 0..<3 {
                for j in 0..<3 { a[i, j] += row[i] * row[j] }
                b[i] += row[i] * z
            }
        }
        guard let s = a.solve(b) else { return nil }
        let cu = -s[0] / 2, cv = -s[1] / 2
        let r2 = cu * cu + cv * cv - s[2]
        guard r2 > 0 else { return nil }
        return (cu + mx, cv + my, r2.squareRoot())
    }

    /// Least squares for r(θ) = r0 + a·cos2θ + b·sin2θ.
    static func fitHarmonic(_ thetas: [Double], _ dists: [Double]) -> (r0: Double, a: Double, b: Double)? {
        var m = Matrix(rows: 3, cols: 3)
        var rhs = [0.0, 0.0, 0.0]
        for (t, d) in zip(thetas, dists) {
            let row = [1.0, cos(2 * t), sin(2 * t)]
            for i in 0..<3 {
                for j in 0..<3 { m[i, j] += row[i] * row[j] }
                rhs[i] += row[i] * d
            }
        }
        guard let s = m.solve(rhs) else { return nil }
        return (s[0], s[1], s[2])
    }
}
