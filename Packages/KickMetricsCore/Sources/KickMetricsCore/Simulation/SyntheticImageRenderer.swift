import Foundation

/// Renders simple synthetic camera frames (textured "grass" background, a
/// shaded ball with dark panels, motion blur, sensor noise) so the image
/// pipeline can be tested without real video. Test data only.
public struct SyntheticImageRenderer: Sendable {
    public var intrinsics: CameraIntrinsics
    public var ballRadius: Double
    public var background: GrayImage
    /// Exposure time for motion blur, seconds.
    public var exposure: Double
    public var noiseSigma: Double
    private var noiseTable: [Double]

    public init(intrinsics: CameraIntrinsics, ballRadius: Double, exposure: Double = 1.0 / 2000,
                noiseSigma: Double = 2.0, seed: UInt64 = 7) {
        self.intrinsics = intrinsics
        self.ballRadius = ballRadius
        self.exposure = exposure
        self.noiseSigma = noiseSigma
        var rng = SeededRandom(seed: seed)
        let w = intrinsics.imageWidth, h = intrinsics.imageHeight
        // Grass: mid-gray with blotchy low-frequency variation and fine texture.
        var px = [UInt8](repeating: 0, count: w * h)
        let phases = (0..<6).map { _ in rng.uniform(0...(2 * .pi)) }
        for y in 0..<h {
            for x in 0..<w {
                let fx = Double(x), fy = Double(y)
                var v = 95.0
                v += 10 * sin(fx * 0.013 + phases[0]) * cos(fy * 0.017 + phases[1])
                v += 6 * sin(fx * 0.051 + fy * 0.023 + phases[2])
                v += 4 * sin(fx * 0.37 + phases[3]) * sin(fy * 0.29 + phases[4])
                v += 5 * (rng.uniform() - 0.5)
                px[y * w + x] = UInt8(max(0, min(255, v)))
            }
        }
        background = GrayImage(width: w, height: h, pixels: px)
        noiseTable = (0..<8192).map { _ in rng.gaussian() }
    }

    /// Renders a frame with the ball's centre moving linearly from `start` to
    /// `end` during the exposure (nil = no ball).
    public func render(ballFrom start: Vec3?, to end: Vec3?, frameIndex: Int) -> GrayImage {
        var img = background
        if let start, let end {
            drawBall(&img, from: start, to: end)
        }
        if noiseSigma > 0 {
            let offset = (frameIndex &* 7919) % noiseTable.count
            img.pixels.withUnsafeMutableBufferPointer { p in
                for i in 0..<p.count {
                    let n = noiseTable[(i &+ offset) % noiseTable.count] * noiseSigma
                    p[i] = UInt8(max(0, min(255, Double(p[i]) + n)))
                }
            }
        }
        return img
    }

    private func drawBall(_ img: inout GrayImage, from start: Vec3, to end: Vec3) {
        let subSteps = 5
        let images: [(BallImage, Vec3)] = (0..<subSteps).compactMap { k in
            let a = subSteps == 1 ? 0 : Double(k) / Double(subSteps - 1)
            let c = start + (end - start) * a
            return SphereProjection.project(center: c, radius: ballRadius, intrinsics: intrinsics).map { ($0, c) }
        }
        guard !images.isEmpty else { return }
        let minU = images.map { $0.0.centerU - $0.0.semiMajor }.min()! - 3
        let maxU = images.map { $0.0.centerU + $0.0.semiMajor }.max()! + 3
        let minV = images.map { $0.0.centerV - $0.0.semiMajor }.min()! - 3
        let maxV = images.map { $0.0.centerV + $0.0.semiMajor }.max()! + 3
        let x0 = max(0, Int(minU)), x1 = min(img.width - 1, Int(maxU))
        let y0 = max(0, Int(minV)), y1 = min(img.height - 1, Int(maxV))
        guard x0 <= x1, y0 <= y1 else { return }

        for y in y0...y1 {
            for x in x0...x1 {
                let pu = Double(x) + 0.5, pv = Double(y) + 0.5
                var coverage = 0.0
                var shade = 0.0
                for (bi, _) in images {
                    // Point in the ellipse's frame.
                    let du = pu - bi.centerU, dv = pv - bi.centerV
                    let ca = cos(bi.majorAxisAngle), sa = sin(bi.majorAxisAngle)
                    let a = du * ca + dv * sa
                    let b = -du * sa + dv * ca
                    let rn = ((a / bi.semiMajor) * (a / bi.semiMajor) + (b / bi.semiMinor) * (b / bi.semiMinor)).squareRoot()
                    // ~1 px anti-aliased edge.
                    let edgeDistance = (1 - rn) * bi.semiMinor
                    let cov = max(0, min(1, edgeDistance + 0.5))
                    guard cov > 0 else { continue }
                    // Lit from above, darker towards the bottom; a few dark panels.
                    let nx = du / bi.semiMinor, ny = dv / bi.semiMinor
                    var value = 215 - 35 * ny
                    let panel = sin(4.2 * nx + 1.1) * cos(3.7 * ny - 0.4)
                    if panel > 0.55 && rn < 0.85 { value = 55 }
                    coverage += cov
                    shade += cov * value
                }
                coverage /= Double(images.count)
                guard coverage > 0 else { continue }
                let ballValue = shade / (coverage * Double(images.count))
                let bg = Double(img[x, y])
                img[x, y] = UInt8(max(0, min(255, bg + (ballValue - bg) * coverage)))
            }
        }
    }
}
