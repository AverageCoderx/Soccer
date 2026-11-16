import Foundation

/// Small dense row-major matrix for the filters and least-squares fits in this
/// package. Sizes here are at most ~10×10 (plus tall Jacobians), so plain loops
/// are fast enough and keep the core portable to Linux.
public struct Matrix: Sendable, Equatable {
    public let rows: Int
    public let cols: Int
    public private(set) var elements: [Double]

    public init(rows: Int, cols: Int, repeating value: Double = 0) {
        precondition(rows >= 0 && cols >= 0)
        self.rows = rows
        self.cols = cols
        self.elements = Array(repeating: value, count: rows * cols)
    }

    public init(rows: Int, cols: Int, elements: [Double]) {
        precondition(elements.count == rows * cols, "Matrix element count mismatch")
        self.rows = rows
        self.cols = cols
        self.elements = elements
    }

    public static func identity(_ n: Int) -> Matrix {
        var m = Matrix(rows: n, cols: n)
        for i in 0..<n { m[i, i] = 1 }
        return m
    }

    public static func diagonal(_ d: [Double]) -> Matrix {
        var m = Matrix(rows: d.count, cols: d.count)
        for i in 0..<d.count { m[i, i] = d[i] }
        return m
    }

    public subscript(r: Int, c: Int) -> Double {
        get { elements[r * cols + c] }
        set { elements[r * cols + c] = newValue }
    }

    public var transposed: Matrix {
        var t = Matrix(rows: cols, cols: rows)
        for r in 0..<rows {
            for c in 0..<cols { t[c, r] = self[r, c] }
        }
        return t
    }

    public static func * (a: Matrix, b: Matrix) -> Matrix {
        precondition(a.cols == b.rows, "Matrix dimension mismatch")
        var out = Matrix(rows: a.rows, cols: b.cols)
        for i in 0..<a.rows {
            for k in 0..<a.cols {
                let aik = a[i, k]
                if aik == 0 { continue }
                for j in 0..<b.cols {
                    out.elements[i * out.cols + j] += aik * b.elements[k * b.cols + j]
                }
            }
        }
        return out
    }

    public static func * (a: Matrix, v: [Double]) -> [Double] {
        precondition(a.cols == v.count, "Matrix-vector dimension mismatch")
        var out = Array(repeating: 0.0, count: a.rows)
        for i in 0..<a.rows {
            var s = 0.0
            for j in 0..<a.cols { s += a[i, j] * v[j] }
            out[i] = s
        }
        return out
    }

    public static func * (s: Double, a: Matrix) -> Matrix {
        Matrix(rows: a.rows, cols: a.cols, elements: a.elements.map { $0 * s })
    }

    public static func + (a: Matrix, b: Matrix) -> Matrix {
        precondition(a.rows == b.rows && a.cols == b.cols)
        return Matrix(rows: a.rows, cols: a.cols, elements: zip(a.elements, b.elements).map { $0 + $1 })
    }

    public static func - (a: Matrix, b: Matrix) -> Matrix {
        precondition(a.rows == b.rows && a.cols == b.cols)
        return Matrix(rows: a.rows, cols: a.cols, elements: zip(a.elements, b.elements).map { $0 - $1 })
    }

    /// Computes AᵀA directly (used for Gauss-Newton normal equations).
    public func gram() -> Matrix {
        var out = Matrix(rows: cols, cols: cols)
        for r in 0..<rows {
            let base = r * cols
            for i in 0..<cols {
                let ai = elements[base + i]
                if ai == 0 { continue }
                for j in i..<cols {
                    out.elements[i * cols + j] += ai * elements[base + j]
                }
            }
        }
        for i in 0..<cols {
            for j in 0..<i { out[i, j] = out[j, i] }
        }
        return out
    }

    /// Computes Aᵀv.
    public func transposeTimes(_ v: [Double]) -> [Double] {
        precondition(v.count == rows)
        var out = Array(repeating: 0.0, count: cols)
        for r in 0..<rows {
            let vr = v[r]
            if vr == 0 { continue }
            let base = r * cols
            for c in 0..<cols { out[c] += elements[base + c] * vr }
        }
        return out
    }

    /// Lower-triangular Cholesky factor L with A = L Lᵀ, or nil if A is not
    /// (numerically) symmetric positive definite.
    public func cholesky() -> Matrix? {
        precondition(rows == cols)
        let n = rows
        var l = Matrix(rows: n, cols: n)
        for j in 0..<n {
            var d = self[j, j]
            for k in 0..<j { d -= l[j, k] * l[j, k] }
            guard d > 0, d.isFinite else { return nil }
            let ljj = d.squareRoot()
            l[j, j] = ljj
            for i in (j + 1)..<max(n, j + 1) {
                var s = self[i, j]
                for k in 0..<j { s -= l[i, k] * l[j, k] }
                l[i, j] = s / ljj
            }
        }
        return l
    }

    /// Solves A x = b for symmetric positive definite A.
    public func solveSPD(_ b: [Double]) -> [Double]? {
        guard let l = cholesky() else { return nil }
        let n = rows
        var y = b
        for i in 0..<n {
            var s = y[i]
            for k in 0..<i { s -= l[i, k] * y[k] }
            y[i] = s / l[i, i]
        }
        var x = y
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = x[i]
            for k in (i + 1)..<max(n, i + 1) { s -= l[k, i] * x[k] }
            x[i] = s / l[i, i]
        }
        return x
    }

    /// Solves A x = b for a general square A (Gaussian elimination with partial pivoting).
    public func solve(_ b: [Double]) -> [Double]? {
        precondition(rows == cols && b.count == rows)
        let n = rows
        var a = elements
        var x = b
        for col in 0..<n {
            var pivot = col
            var best = abs(a[col * n + col])
            for r in (col + 1)..<max(n, col + 1) where abs(a[r * n + col]) > best {
                best = abs(a[r * n + col])
                pivot = r
            }
            guard best > 1e-300 else { return nil }
            if pivot != col {
                for c in 0..<n { a.swapAt(col * n + c, pivot * n + c) }
                x.swapAt(col, pivot)
            }
            let p = a[col * n + col]
            for r in (col + 1)..<max(n, col + 1) {
                let f = a[r * n + col] / p
                if f == 0 { continue }
                for c in col..<n { a[r * n + c] -= f * a[col * n + c] }
                x[r] -= f * x[col]
            }
        }
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = x[r]
            for c in (r + 1)..<max(n, r + 1) { s -= a[r * n + c] * x[c] }
            x[r] = s / a[r * n + r]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    /// Inverse of a square matrix (Gauss-Jordan with partial pivoting).
    public func inverted() -> Matrix? {
        precondition(rows == cols)
        let n = rows
        var a = elements
        var inv = Matrix.identity(n).elements
        for col in 0..<n {
            var pivot = col
            var best = abs(a[col * n + col])
            for r in (col + 1)..<max(n, col + 1) where abs(a[r * n + col]) > best {
                best = abs(a[r * n + col])
                pivot = r
            }
            guard best > 1e-300 else { return nil }
            if pivot != col {
                for c in 0..<n {
                    a.swapAt(col * n + c, pivot * n + c)
                    inv.swapAt(col * n + c, pivot * n + c)
                }
            }
            let p = a[col * n + col]
            for c in 0..<n {
                a[col * n + c] /= p
                inv[col * n + c] /= p
            }
            for r in 0..<n where r != col {
                let f = a[r * n + col]
                if f == 0 { continue }
                for c in 0..<n {
                    a[r * n + c] -= f * a[col * n + c]
                    inv[r * n + c] -= f * inv[col * n + c]
                }
            }
        }
        let result = Matrix(rows: n, cols: n, elements: inv)
        return result.elements.allSatisfy(\.isFinite) ? result : nil
    }
}
