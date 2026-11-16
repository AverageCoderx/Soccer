import Foundation

/// Pinhole camera intrinsics in pixels, for the image buffer the detector sees.
///
/// On device these come from the per-frame intrinsic matrix AVFoundation attaches
/// to each sample buffer, expressed for the buffer's native (landscape sensor)
/// orientation. Coordinates: u to the right, v down, origin at the top-left pixel.
public struct CameraIntrinsics: Sendable, Equatable, Codable {
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    public var imageWidth: Int
    public var imageHeight: Int

    public init(fx: Double, fy: Double, cx: Double, cy: Double, imageWidth: Int, imageHeight: Int) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    /// Single focal length for lengths measured in the image (iPhone pixels are square, so fx ≈ fy).
    public var focalLength: Double { 0.5 * (fx + fy) }

    /// Intrinsics from a horizontal field of view, centred principal point.
    /// For tests and as a fallback only: the app uses the camera's reported matrix.
    public static func fromHorizontalFieldOfView(degrees: Double, width: Int, height: Int) -> CameraIntrinsics {
        let f = Double(width) / 2 / tan(degrees * .pi / 360)
        return CameraIntrinsics(fx: f, fy: f, cx: Double(width) / 2, cy: Double(height) / 2,
                                imageWidth: width, imageHeight: height)
    }

    public func contains(u: Double, v: Double, margin: Double = 0) -> Bool {
        u >= margin && v >= margin && u <= Double(imageWidth) - margin && v <= Double(imageHeight) - margin
    }
}
