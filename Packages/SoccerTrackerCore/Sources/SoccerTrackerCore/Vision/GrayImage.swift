import Foundation

/// 8-bit grayscale image (the camera's luma plane), row-major, tightly packed.
///
/// Coordinates are continuous: pixel (i, j) covers [i, i+1) × [j, j+1), so its
/// centre is at (i + 0.5, j + 0.5). This matches `CameraIntrinsics`, where
/// cx = width / 2 is the image centre.
public struct GrayImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "GrayImage pixel count mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        self.init(width: width, height: height, pixels: Array(repeating: fill, count: width * height))
    }

    /// Copies a luma plane that may have row padding (`bytesPerRow` ≥ width).
    public init(width: Int, height: Int, bytesPerRow: Int, base: UnsafeRawPointer) {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { dst in
            for row in 0..<height {
                let src = base.advanced(by: row * bytesPerRow)
                (dst.baseAddress! + row * width).copyMemory(from: src, byteCount: width)
            }
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    @inline(__always)
    public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Bilinear sample at a continuous coordinate, or nil outside the image.
    @inline(__always)
    public func sample(_ x: Double, _ y: Double) -> Double? {
        let fx = x - 0.5
        let fy = y - 0.5
        guard fx >= 0, fy >= 0, fx <= Double(width - 1), fy <= Double(height - 1) else { return nil }
        let x0 = min(Int(fx), width - 2)
        let y0 = min(Int(fy), height - 2)
        let ax = fx - Double(x0)
        let ay = fy - Double(y0)
        let i = y0 * width + x0
        let p00 = Double(pixels[i])
        let p10 = Double(pixels[i + 1])
        let p01 = Double(pixels[i + width])
        let p11 = Double(pixels[i + width + 1])
        let top = p00 + (p10 - p00) * ax
        let bottom = p01 + (p11 - p01) * ax
        return top + (bottom - top) * ay
    }

    /// Box-filtered downsample by an integer factor.
    public func downsampled(by factor: Int) -> GrayImage {
        precondition(factor >= 1)
        if factor == 1 { return self }
        let w = width / factor
        let h = height / factor
        var out = [UInt8](repeating: 0, count: w * h)
        let area = factor * factor
        pixels.withUnsafeBufferPointer { src in
            for oy in 0..<h {
                for ox in 0..<w {
                    var sum = 0
                    let baseY = oy * factor
                    let baseX = ox * factor
                    for dy in 0..<factor {
                        let row = (baseY + dy) * width + baseX
                        for dx in 0..<factor { sum += Int(src[row + dx]) }
                    }
                    out[oy * w + ox] = UInt8(sum / area)
                }
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }
}
