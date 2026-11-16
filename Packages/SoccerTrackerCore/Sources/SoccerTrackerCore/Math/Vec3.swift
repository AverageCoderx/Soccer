import Foundation

/// Minimal double-precision 3-vector.
///
/// `simd` isn't available on Linux and this package must build and test there,
/// so we use a small value type of our own. Vectors in this package are in the
/// camera frame unless stated otherwise: +x right, +y down, +z forward along the
/// optical axis, in meters.
public struct Vec3: Sendable, Equatable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)

    public subscript(index: Int) -> Double {
        get {
            switch index {
            case 0: return x
            case 1: return y
            case 2: return z
            default: preconditionFailure("Vec3 index out of range")
            }
        }
        set {
            switch index {
            case 0: x = newValue
            case 1: y = newValue
            case 2: z = newValue
            default: preconditionFailure("Vec3 index out of range")
            }
        }
    }

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public static func * (s: Double, a: Vec3) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public static func / (a: Vec3, s: Double) -> Vec3 { Vec3(a.x / s, a.y / s, a.z / s) }
    public static func += (a: inout Vec3, b: Vec3) { a = a + b }
    public static func -= (a: inout Vec3, b: Vec3) { a = a - b }

    public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }

    public func cross(_ b: Vec3) -> Vec3 {
        Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x)
    }

    public var lengthSquared: Double { x * x + y * y + z * z }
    public var length: Double { lengthSquared.squareRoot() }

    public var normalized: Vec3 {
        let l = length
        return l > 0 ? self / l : .zero
    }

    public var components: [Double] { [x, y, z] }
}
