import AVFoundation
import CoreMedia
import CoreVideo
import KickMetricsCore
import simd

enum FrameConversion {
    /// Copies the luma (Y) plane of a bi-planar 4:2:0 pixel buffer, optionally a sub-rectangle.
    /// Returns the image and the crop origin in full-buffer pixels.
    static func luma(_ pixelBuffer: CVPixelBuffer, crop: CGRect? = nil) -> (image: GrayImage, originX: Int, originY: Int)? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        var x0 = 0, y0 = 0, w = width, h = height
        if let crop {
            x0 = max(0, min(width - 1, Int(crop.minX)))
            y0 = max(0, min(height - 1, Int(crop.minY)))
            w = max(1, min(width - x0, Int(crop.width)))
            h = max(1, min(height - y0, Int(crop.height)))
        }
        guard w >= 8, h >= 8 else { return nil }
        let start = UnsafeRawPointer(base).advanced(by: y0 * bytesPerRow + x0)
        let image = GrayImage(width: w, height: h, bytesPerRow: bytesPerRow, base: start)
        return (image, x0, y0)
    }

    static func dimensions(_ pixelBuffer: CVPixelBuffer) -> (width: Int, height: Int) {
        (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
    }

    /// The camera intrinsic matrix AVFoundation attaches to each frame when
    /// `isCameraIntrinsicMatrixDeliveryEnabled` is on (pixel units, buffer orientation).
    static func intrinsics(from sampleBuffer: CMSampleBuffer, width: Int, height: Int) -> CameraIntrinsics? {
        guard let attachment = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                               attachmentModeOut: nil) as? Data,
              attachment.count >= MemoryLayout<matrix_float3x3>.size else { return nil }
        let m = attachment.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
        var fx = Double(m.columns.0.x)
        var fy = Double(m.columns.1.y)
        var cx = Double(m.columns.2.x)
        var cy = Double(m.columns.2.y)
        guard fx > 0, fy > 0, cx > 0, cy > 0 else { return nil }
        // The matrix should already be for this buffer size. If its principal
        // point is clearly for a different resolution (e.g. the full sensor),
        // rescale it to the buffer.
        let scale = Double(width) / (2 * cx)
        if scale < 0.8 || scale > 1.25 {
            fx *= scale
            fy *= scale
            cx *= scale
            cy *= scale
        }
        return CameraIntrinsics(fx: fx, fy: fy, cx: cx, cy: cy, imageWidth: width, imageHeight: height)
    }
}
