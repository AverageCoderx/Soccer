import XCTest
@testable import KickMetricsCore

final class MatrixTests: XCTestCase {
    func testSolveAndInverse() throws {
        let a = Matrix(rows: 3, cols: 3, elements: [4, 1, 2,
                                                    1, 5, 3,
                                                    2, 3, 6])
        let b = [1.0, 2.0, 3.0]
        let x1 = try XCTUnwrap(a.solve(b))
        let x2 = try XCTUnwrap(a.solveSPD(b))
        let inv = try XCTUnwrap(a.inverted())
        let x3 = inv * b
        let check = a * x1
        for i in 0..<3 {
            XCTAssertEqual(check[i], b[i], accuracy: 1e-12)
            XCTAssertEqual(x1[i], x2[i], accuracy: 1e-12)
            XCTAssertEqual(x1[i], x3[i], accuracy: 1e-12)
        }
        let identity = a * inv
        for r in 0..<3 {
            for c in 0..<3 { XCTAssertEqual(identity[r, c], r == c ? 1 : 0, accuracy: 1e-12) }
        }
    }

    func testCholeskyRejectsIndefinite() {
        let a = Matrix(rows: 2, cols: 2, elements: [1, 2, 2, 1])
        XCTAssertNil(a.cholesky())
    }
}

final class SphereProjectionTests: XCTestCase {
    let k = CameraIntrinsics.fromHorizontalFieldOfView(degrees: 73.7, width: 1920, height: 1080)
    let radius = BallSpec.size5.radius

    func testOnAxisIsCircleWithTangentRadius() throws {
        let z = 6.0
        let img = try XCTUnwrap(SphereProjection.project(center: Vec3(0, 0, z), radius: radius, intrinsics: k))
        let alpha = asin(radius / z)
        XCTAssertEqual(img.semiMinor, k.focalLength * tan(alpha), accuracy: 1e-9)
        XCTAssertEqual(img.semiMajor, img.semiMinor, accuracy: 1e-9)
        XCTAssertEqual(img.centerU, k.cx, accuracy: 1e-9)
        XCTAssertEqual(img.centerV, k.cy, accuracy: 1e-9)
    }

    func testOffAxisStretchesRadiallyAndMinorAxisTracksDepth() throws {
        // Ball 35° off axis horizontally, at depth Z = 6 m.
        let z = 6.0
        let theta = 35.0 * .pi / 180
        let c = Vec3(z * tan(theta), 0, z)
        let img = try XCTUnwrap(SphereProjection.project(center: c, radius: radius, intrinsics: k))
        // Radial stretch ≈ 1/cosθ ≈ 1.22.
        XCTAssertEqual(img.semiMajor / img.semiMinor, 1 / cos(theta), accuracy: 0.002)
        // Tangential semi-axis ≈ f·R/Z (depth along the optical axis), to well under 0.1%.
        XCTAssertEqual(img.semiMinor / (k.focalLength * radius / z), 1, accuracy: 0.001)
    }

    func testBackprojectionRoundTrip() throws {
        let points = [Vec3(0, 0, 3), Vec3(-3.5, 1.2, 6), Vec3(4, -2, 9), Vec3(0.4, 0.3, 20)]
        for c in points {
            let img = try XCTUnwrap(SphereProjection.project(center: c, radius: radius, intrinsics: k))
            let back = try XCTUnwrap(SphereProjection.backproject(
                centerU: img.centerU, centerV: img.centerV, semiMinor: img.semiMinor,
                radius: radius, intrinsics: k))
            XCTAssertEqual((back - c).length, 0, accuracy: 1e-6)
        }
    }

    func testBehindCameraIsRejected() {
        XCTAssertNil(SphereProjection.project(center: Vec3(0, 0, -1), radius: radius, intrinsics: k))
    }
}

final class LevenbergMarquardtTests: XCTestCase {
    func testFitsExponentialExactly() throws {
        let ts = stride(from: 0.0, through: 2.0, by: 0.1).map { $0 }
        let ys = ts.map { 3.0 * exp(-1.3 * $0) }
        let problem = LeastSquaresProblem(parameterCount: 2, parameterScales: [1, 1]) { p in
            zip(ts, ys).map { p[0] * exp(p[1] * $0) - $1 }
        }
        let result = try XCTUnwrap(LevenbergMarquardt.solve(problem, initial: [1, 0]))
        XCTAssertEqual(result.parameters[0], 3.0, accuracy: 1e-6)
        XCTAssertEqual(result.parameters[1], -1.3, accuracy: 1e-6)
    }
}

final class FlightPhysicsTests: XCTestCase {
    func testVacuumMatchesBallistics() {
        let physics = FlightPhysics(gravity: Vec3(0, 9.81, 0), ball: .size5)
        let start = KinematicState(time: 0, position: .zero, velocity: Vec3(10, -5, 2))
        let s = physics.propagate(from: start, to: [0.5, -0.2], dragCoefficient: 0, extraAcceleration: .zero)
        for state in s {
            let t = state.time
            XCTAssertEqual(state.position.x, 10 * t, accuracy: 1e-9)
            XCTAssertEqual(state.position.y, -5 * t + 0.5 * 9.81 * t * t, accuracy: 1e-9)
            XCTAssertEqual(state.velocity.y, -5 + 9.81 * t, accuracy: 1e-9)
        }
    }

    func testDragDecelerationMagnitude() {
        let physics = FlightPhysics(gravity: .zero, ball: .size5)
        let a = physics.acceleration(velocity: Vec3(30, 0, 0), dragCoefficient: 0.25, extraAcceleration: .zero)
        // ½ ρ Cd A v² / m = 0.5·1.2·0.25·0.0379·900/0.43 ≈ 11.9 m/s²
        XCTAssertEqual(-a.x, 11.9, accuracy: 0.2)
    }
}
