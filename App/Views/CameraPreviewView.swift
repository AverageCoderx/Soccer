import AVFoundation
import KickMetricsCore
import SwiftUI
import UIKit

/// Live camera preview. Taps are converted to the capture device's
/// normalised coordinates (native sensor orientation), and the locked ball is
/// outlined, converting back the other way.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// Locked ball in buffer pixels, with the buffer size, for the outline.
    var ball: RefinedBall?
    var bufferSize: CGSize
    var onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.onTap = onTap
        view.attachRotationCoordinator()
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        view.onTap = onTap
        view.updateOutline(ball: ball, bufferSize: bufferSize)
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onTap: ((CGPoint) -> Void)?

    private let outline = CAShapeLayer()
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var lastBall: RefinedBall?
    private var lastBufferSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        outline.strokeColor = UIColor.systemBlue.cgColor
        outline.fillColor = UIColor.clear.cgColor
        outline.lineWidth = 2.5
        layer.addSublayer(outline)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Keeps the preview upright as the phone rotates. Only the preview is
    /// rotated; the frames used for measurement stay in the sensor's native
    /// orientation.
    func attachRotationCoordinator() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            DispatchQueue.main.async {
                guard let self, let connection = self.previewLayer.connection else { return }
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
                self.redrawOutline()
            }
        }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        onTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: point))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        outline.frame = bounds
        redrawOutline()
    }

    func updateOutline(ball: RefinedBall?, bufferSize: CGSize) {
        lastBall = ball
        lastBufferSize = bufferSize
        redrawOutline()
    }

    private func redrawOutline() {
        guard let ball = lastBall, lastBufferSize.width > 0, lastBufferSize.height > 0 else {
            outline.path = nil
            return
        }
        // Convert the ball's left/right/top/bottom extremes to layer points;
        // the preview may be rotated relative to the buffer.
        let w = lastBufferSize.width, h = lastBufferSize.height
        let r = CGFloat(ball.semiMinor) * 1.25
        let c = CGPoint(x: CGFloat(ball.centerU), y: CGFloat(ball.centerV))
        let extremes = [CGPoint(x: c.x - r, y: c.y), CGPoint(x: c.x + r, y: c.y),
                        CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x, y: c.y + r)]
            .map { previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: $0.x / w, y: $0.y / h)) }
        let xs = extremes.map(\.x), ys = extremes.map(\.y)
        let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        outline.path = UIBezierPath(ovalIn: rect).cgPath
    }
}
