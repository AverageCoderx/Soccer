import Foundation

/// A nonlinear least-squares problem: minimise ‖r(p)‖² where r returns
/// residuals that are already whitened (divided by their 1σ uncertainty).
/// Returning nil from `residuals` marks a parameter vector as invalid (e.g. the
/// ball would be behind the camera); the solver treats that as an infinite cost.
public struct LeastSquaresProblem {
    public var parameterCount: Int
    /// Typical magnitude of each parameter, used to size finite-difference steps.
    public var parameterScales: [Double]
    public var residuals: ([Double]) -> [Double]?

    public init(parameterCount: Int, parameterScales: [Double], residuals: @escaping ([Double]) -> [Double]?) {
        precondition(parameterScales.count == parameterCount)
        self.parameterCount = parameterCount
        self.parameterScales = parameterScales
        self.residuals = residuals
    }
}

public struct LeastSquaresResult: Sendable {
    public var parameters: [Double]
    public var residuals: [Double]
    /// Sum of squared whitened residuals at the solution.
    public var cost: Double
    /// (JᵀJ)⁻¹ at the solution. Because residuals are whitened this is the
    /// parameter covariance if the assumed measurement noise is correct; callers
    /// scale it by the reduced χ² when the fit shows the noise was underestimated.
    public var unscaledCovariance: Matrix?
    public var iterations: Int
    public var converged: Bool

    public var degreesOfFreedom: Int { residuals.count - parameters.count }

    public var reducedChiSquare: Double {
        degreesOfFreedom > 0 ? cost / Double(degreesOfFreedom) : .infinity
    }
}

public enum LevenbergMarquardt {
    public static func solve(
        _ problem: LeastSquaresProblem,
        initial: [Double],
        maxIterations: Int = 100,
        relativeTolerance: Double = 1e-10
    ) -> LeastSquaresResult? {
        precondition(initial.count == problem.parameterCount)
        var p = initial
        guard var r = problem.residuals(p), r.allSatisfy(\.isFinite) else { return nil }
        var cost = sumOfSquares(r)
        var lambda = 1e-3
        var converged = false
        var iterations = 0

        while iterations < maxIterations {
            iterations += 1
            guard let j = jacobian(problem, at: p, base: r) else { return nil }
            let jtj = j.gram()
            let g = j.transposeTimes(r)

            var improved = false
            while lambda < 1e12 {
                var a = jtj
                for i in 0..<problem.parameterCount {
                    a[i, i] += lambda * max(jtj[i, i], 1e-12)
                }
                guard let step = a.solveSPD(g.map { -$0 }) else {
                    lambda *= 4
                    continue
                }
                let candidate = zip(p, step).map { $0 + $1 }
                if let rc = problem.residuals(candidate), rc.allSatisfy(\.isFinite) {
                    let cc = sumOfSquares(rc)
                    if cc < cost {
                        let decrease = (cost - cc) / max(cost, 1e-300)
                        let stepSize = zip(step, problem.parameterScales).map { abs($0) / max($1, 1e-300) }.max() ?? 0
                        p = candidate
                        r = rc
                        cost = cc
                        lambda = max(lambda / 3, 1e-12)
                        improved = true
                        if decrease < relativeTolerance || stepSize < 1e-10 { converged = true }
                        break
                    }
                }
                lambda *= 4
            }
            if !improved {
                // No step reduces the cost: we are at a (local) minimum.
                converged = true
            }
            if converged { break }
        }

        let finalJ = jacobian(problem, at: p, base: r)
        let covariance = finalJ?.gram().inverted()
        return LeastSquaresResult(
            parameters: p, residuals: r, cost: cost,
            unscaledCovariance: covariance, iterations: iterations, converged: converged
        )
    }

    /// Central-difference Jacobian, falling back to one-sided differences when a
    /// perturbed parameter vector is invalid.
    static func jacobian(_ problem: LeastSquaresProblem, at p: [Double], base: [Double]) -> Matrix? {
        let m = base.count
        let n = problem.parameterCount
        var j = Matrix(rows: m, cols: n)
        for col in 0..<n {
            let h = 1e-6 * max(abs(p[col]), problem.parameterScales[col])
            var plus = p
            plus[col] += h
            var minus = p
            minus[col] -= h
            let rp = problem.residuals(plus)
            let rm = problem.residuals(minus)
            if let rp, let rm, rp.count == m, rm.count == m {
                for row in 0..<m { j[row, col] = (rp[row] - rm[row]) / (2 * h) }
            } else if let rp, rp.count == m {
                for row in 0..<m { j[row, col] = (rp[row] - base[row]) / h }
            } else if let rm, rm.count == m {
                for row in 0..<m { j[row, col] = (base[row] - rm[row]) / h }
            } else {
                return nil
            }
        }
        return j
    }

    static func sumOfSquares(_ r: [Double]) -> Double {
        r.reduce(0) { $0 + $1 * $1 }
    }
}
