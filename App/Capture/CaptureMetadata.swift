import Foundation
import KickMetricsCore

enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case shot
    case dropTest
    var id: String { rawValue }
    var label: String { self == .shot ? "Shot" : "Drop test" }
}

/// Everything about a recording that the analysis needs besides the video itself.
/// Times are seconds since the clip's first frame.
struct CaptureMetadata: Codable {
    var mode: CaptureMode
    var width: Int
    var height: Int
    var requestedFrameRate: Double
    var intrinsics: CameraIntrinsics
    /// "camera" when AVFoundation supplied the intrinsic matrix, "fieldOfView" for the fallback.
    var intrinsicsSource: String
    var gravity: Vec3
    var gravityMeasured: Bool
    var exposureDurationSeconds: Double
    var iso: Double
    var frameCount: Int
    var droppedFrames: Int
    var encoderSkippedFrames: Int
    var duration: Double
    /// When the resting ball disappeared from its spot (kick or release), if seen live.
    var kickTime: Double?
    /// Resting ball as locked by the user's tap (buffer pixels, native orientation).
    var restPoint: ImagePoint
    var restSemiMinor: Double
}
