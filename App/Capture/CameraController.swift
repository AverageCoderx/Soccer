import AVFoundation
import Combine
import KickMetricsCore
import UIKit

/// Traffic-light state for one setup check.
enum CheckLevel: Int, Comparable {
    case bad = 0, warn = 1, good = 2
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct PlacementCheck: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var level: CheckLevel
}

/// Owns the camera: configuration for measurement (fixed physical lens, high
/// frame rate, stabilisation off, fast fixed shutter), the live ball check,
/// and recording.
///
/// Threading: AVFoundation work runs on `sessionQueue`, frames arrive on
/// `videoQueue`, and published state is only changed on the main thread.
final class CameraController: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case unauthorized
        case failed(String)
        case previewing
        case recording
        case finishing
    }

    struct FinishedRecording {
        var clipURL: URL
        var metadata: CaptureMetadata
    }

    // MARK: Published state (main thread only)

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var formatDescription = "—"
    @Published private(set) var activeFrameRate: Double = 0
    /// Size of the measurement frames (native sensor orientation).
    @Published private(set) var bufferSize = CGSize(width: 1920, height: 1080)
    @Published private(set) var lockedBall: RefinedBall?
    @Published private(set) var ballDistance: Double?
    @Published private(set) var ballConfidence: Double = 0
    @Published private(set) var checks: [PlacementCheck] = []
    @Published private(set) var recordingSeconds: Double = 0
    @Published private(set) var statusText = "Starting camera…"
    @Published private(set) var lastTapMissed = false

    /// Delivered on the main thread when a recording has been written.
    var onRecordingFinished: ((Result<FinishedRecording, Error>) -> Void)?

    let session = AVCaptureSession()

    // MARK: Private state

    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.video", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private let motion = MotionMonitor()

    // Touched only on videoQueue.
    private var pendingTap: CGPoint?
    private var restBall: RefinedBall?
    private var intrinsics: CameraIntrinsics?
    private var intrinsicsSource = "fieldOfView"
    private var frameCounter = 0
    private var recorder: ClipRecorder?
    private var recordingMode: CaptureMode = .shot
    private var recordingStartPTS: Double?
    private var recordingFrameCount = 0
    private var droppedFrames = 0
    private var restSeenAt: Double?
    private var restMissingSince: Double?
    private var kickTime: Double?
    private var stopRequested = false
    private var lastPublish: Double = 0
    private var recordingGravity: Vec3?
    private var exposureAtStart: (duration: Double, iso: Double) = (0, 0)

    /// Longest recording before giving up on seeing a kick, seconds.
    private let maxRecordingSeconds = 15.0

    // MARK: Lifecycle

    func start(frameRate: Double) {
        motion.start()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure(frameRate: frameRate)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.configure(frameRate: frameRate)
                } else {
                    DispatchQueue.main.async { self?.phase = .unauthorized }
                }
            }
        default:
            phase = .unauthorized
        }
    }

    func stop() {
        motion.stop()
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: Configuration

    private func configure(frameRate: Double) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureSession(frameRate: frameRate)
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async {
                    if self.phase == .idle || self.phase == .previewing { self.phase = .previewing }
                    self.statusText = "Tap the ball to lock on to it."
                }
            } catch {
                DispatchQueue.main.async { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func configureSession(frameRate: Double) throws {
        // The physical wide (1×) camera, never the multi-camera virtual device:
        // that one can switch lenses mid-shot, which changes the focal length.
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw NSError(domain: "KickMetrics", code: 10, userInfo: [NSLocalizedDescriptionKey: "No back camera found."])
        }
        self.device = device

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "KickMetrics", code: 11, userInfo: [NSLocalizedDescriptionKey: "Can't use the camera."])
        }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        // Every frame matters for the measurement; dropped frames are counted.
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else {
            throw NSError(domain: "KickMetrics", code: 12, userInfo: [NSLocalizedDescriptionKey: "Can't read camera frames."])
        }
        session.addOutput(videoOutput)

        let (format, fps) = try Self.bestFormat(for: device, frameRate: frameRate)
        try device.lockForConfiguration()
        device.activeFormat = format
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        if format.isVideoHDRSupported {
            device.automaticallyAdjustsVideoHDREnabled = false
            device.isVideoHDREnabled = false
        }
        if device.isLowLightBoostSupported {
            device.automaticallyEnablesLowLightBoostWhenAvailable = false
        }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        device.unlockForConfiguration()

        if let connection = videoOutput.connection(with: .video) {
            // Stabilisation crops and warps frames, which breaks the geometry.
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
            if connection.isCameraIntrinsicMatrixDeliverySupported { connection.isCameraIntrinsicMatrixDeliveryEnabled = true }
        }

        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let fov = Double(format.videoFieldOfView)
        videoQueue.async { [weak self] in
            // Fallback until the first frame brings the real intrinsic matrix.
            self?.intrinsics = CameraIntrinsics.fromHorizontalFieldOfView(
                degrees: fov > 0 ? fov : 73, width: Int(dims.width), height: Int(dims.height))
            self?.intrinsicsSource = "fieldOfView"
        }
        DispatchQueue.main.async {
            self.formatDescription = "\(dims.width)×\(dims.height) · \(Int(fps)) fps · 1× camera"
            self.activeFrameRate = fps
            self.bufferSize = CGSize(width: Int(dims.width), height: Int(dims.height))
        }
    }

    /// Picks a 1080p 4:2:0 8-bit format that supports the requested frame rate,
    /// falling back to the highest available rate.
    static func bestFormat(for device: AVCaptureDevice, frameRate: Double) throws -> (AVCaptureDevice.Format, Double) {
        let wanted: Set<FourCharCode> = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let candidates = device.formats.filter { format in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            return d.width == 1920 && d.height == 1080 && wanted.contains(subtype)
        }
        func maxRate(_ f: AVCaptureDevice.Format) -> Double {
            f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }
        if let exact = candidates
            .filter({ maxRate($0) >= frameRate - 0.5 })
            .sorted(by: { lhs, rhs in
                // Prefer full-range pixels and formats that don't need more than we ask for.
                let l = CMFormatDescriptionGetMediaSubType(lhs.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                let r = CMFormatDescriptionGetMediaSubType(rhs.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                if l != r { return l }
                return maxRate(lhs) < maxRate(rhs)
            }).first {
            return (exact, frameRate)
        }
        if let best = candidates.max(by: { maxRate($0) < maxRate($1) }) {
            return (best, min(frameRate, maxRate(best)))
        }
        throw NSError(domain: "KickMetrics", code: 13,
                      userInfo: [NSLocalizedDescriptionKey: "This camera has no 1080p format for measurement."])
    }

    // MARK: Ball lock

    /// `devicePoint` is in the capture device's normalised coordinates (0…1,
    /// native sensor orientation), from the preview layer's conversion.
    func lockBall(atDevicePoint devicePoint: CGPoint) {
        videoQueue.async { [weak self] in self?.pendingTap = devicePoint }
    }

    func clearBall() {
        videoQueue.async { [weak self] in self?.restBall = nil }
        lockedBall = nil
        ballDistance = nil
        ballConfidence = 0
        statusText = "Tap the ball to lock on to it."
    }

    // MARK: Recording

    func startRecording(mode: CaptureMode) {
        guard phase == .previewing, lockedBall != nil else { return }
        phase = .recording
        recordingSeconds = 0
        statusText = mode == .shot ? "Recording — kick when ready." : "Recording — let the ball drop."
        let gravity = motion.cameraGravity
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let exposure = self.lockExposureForMotion()
            let settings = self.videoOutput.recommendedVideoSettings(forVideoCodecType: .hevc, assetWriterOutputFileType: .mov)
            let url = Storage.shotsDirectory.appendingPathComponent("\(UUID().uuidString).mov")
            do {
                let recorder = try ClipRecorder(url: url, settings: settings)
                self.videoQueue.async {
                    self.recorder = recorder
                    self.recordingMode = mode
                    self.recordingStartPTS = nil
                    self.recordingFrameCount = 0
                    self.droppedFrames = 0
                    self.restSeenAt = nil
                    self.restMissingSince = nil
                    self.kickTime = nil
                    self.stopRequested = false
                    self.recordingGravity = gravity
                    self.exposureAtStart = exposure
                }
            } catch {
                DispatchQueue.main.async {
                    self.phase = .previewing
                    self.statusText = error.localizedDescription
                }
            }
        }
    }

    func stopRecording() {
        videoQueue.async { [weak self] in self?.stopRequested = true }
    }

    /// Fixes the shutter fast enough to freeze the ball, raising ISO to keep
    /// brightness; also locks focus and white balance so nothing changes mid-shot.
    /// Returns the exposure used (seconds, ISO).
    private func lockExposureForMotion() -> (duration: Double, iso: Double) {
        guard let device else { return (0, 0) }
        let plan = Self.exposurePlan(for: device)
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.custom) {
                device.setExposureModeCustom(duration: CMTime(seconds: plan.duration, preferredTimescale: 1_000_000),
                                             iso: Float(plan.iso), completionHandler: nil)
            }
            if device.isFocusModeSupported(.locked) {
                device.setFocusModeLocked(lensPosition: device.lensPosition, completionHandler: nil)
            }
            if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            device.unlockForConfiguration()
        } catch {
            return (device.exposureDuration.seconds, Double(device.iso))
        }
        return (plan.duration, plan.iso)
    }

    private func restoreAutoExposure() {
        sessionQueue.async { [weak self] in
            guard let device = self?.device, (try? device.lockForConfiguration()) != nil else { return }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            device.unlockForConfiguration()
        }
    }

    /// Shutter and ISO for a moving ball. At 1/240 s a 30 m/s ball smears
    /// 12.5 cm (over half its width); at 1/2000 s it's 1.5 cm. Brightness ∝
    /// shutter × ISO, so ISO is scaled up from what auto-exposure chose, as far
    /// as the sensor allows. `stopsShort` > 0 means the image will be darker.
    static func exposurePlan(for device: AVCaptureDevice) -> (duration: Double, iso: Double, stopsShort: Double) {
        let format = device.activeFormat
        let autoDuration = device.exposureDuration.seconds
        let autoISO = Double(device.iso)
        let minD = format.minExposureDuration.seconds
        let maxD = format.maxExposureDuration.seconds
        let maxISO = Double(format.maxISO)
        let minISO = Double(format.minISO)
        guard autoDuration > 0, autoISO > 0 else { return (max(minD, 1.0 / 1000), maxISO, 0) }
        let exposureValue = autoDuration * autoISO
        for target in [1.0 / 2000, 1.0 / 1500, 1.0 / 1000] {
            let d = min(max(target, minD), maxD)
            let iso = exposureValue / d
            if iso <= maxISO { return (d, max(minISO, iso), 0) }
        }
        let d = min(max(1.0 / 1000, minD), maxD)
        return (d, maxISO, log2((exposureValue / d) / maxISO))
    }

    // MARK: Live checks

    private func updateChecks(ball: RefinedBall?, intrinsics: CameraIntrinsics?, timestamp: Double) {
        guard timestamp - lastPublish > 0.1 else { return }
        lastPublish = timestamp
        let radius = AppSettings.ballSpec().radius
        var checks: [PlacementCheck] = []
        var distance: Double?

        if let ball, let k = intrinsics {
            let z = k.focalLength * radius / ball.semiMinor
            distance = z
            let sizeLevel: CheckLevel = ball.semiMinor >= 10 ? .good : (ball.semiMinor >= 7 ? .warn : .bad)
            let distanceLevel: CheckLevel = (3...12).contains(z) ? .good : ((2...16).contains(z) ? .warn : .bad)
            checks.append(PlacementCheck(id: "ball", title: "Ball",
                                         detail: String(format: "Locked · %.0f px wide", 2 * ball.semiMinor),
                                         level: min(sizeLevel, ball.confidence > 0.5 ? .good : .warn)))
            checks.append(PlacementCheck(id: "distance", title: "Distance",
                                         detail: String(format: "%.1f m from camera", z) + (z > 12 ? " · move closer" : (z < 3 ? " · move back" : "")),
                                         level: distanceLevel))
        } else if restBall != nil {
            checks.append(PlacementCheck(id: "ball", title: "Ball", detail: "Not seen at the locked spot · tap it again", level: .bad))
        } else {
            checks.append(PlacementCheck(id: "ball", title: "Ball", detail: "Tap the ball on screen", level: .bad))
        }

        if let device {
            let plan = Self.exposurePlan(for: device)
            let shutter = Int((1 / plan.duration).rounded())
            if plan.stopsShort <= 0 {
                checks.append(PlacementCheck(id: "light", title: "Light", detail: "Shutter 1/\(shutter) s", level: .good))
            } else {
                checks.append(PlacementCheck(id: "light", title: "Light",
                                             detail: String(format: "Too dark for a fast shutter (%.1f stops short)", plan.stopsShort),
                                             level: plan.stopsShort < 1 ? .warn : .bad))
            }
        }

        if let rotation = motion.recentRotationRate {
            let level: CheckLevel = rotation < 0.02 ? .good : (rotation < 0.06 ? .warn : .bad)
            checks.append(PlacementCheck(id: "steady", title: "Steady",
                                         detail: level == .good ? "On tripod" : "Phone is moving · use a tripod",
                                         level: level))
        }
        if let g = motion.cameraGravity {
            // Side-on recording works best with the phone level and in landscape.
            let tilt = atan2(abs(g.x), abs(g.y)) * 180 / .pi
            let level: CheckLevel = tilt < 8 ? .good : (tilt < 20 ? .warn : .bad)
            checks.append(PlacementCheck(id: "level", title: "Level",
                                         detail: String(format: "%.0f° from level%@", tilt, tilt >= 8 ? " · hold landscape and level" : ""),
                                         level: level))
        }

        let confidence = ball?.confidence ?? 0
        DispatchQueue.main.async {
            self.checks = checks
            self.ballDistance = distance
            self.ballConfidence = confidence
        }
    }

    /// Re-measures the resting ball in a small window around where it was
    /// locked. Cheap enough to run many times a second.
    private func checkRestBall(_ pixelBuffer: CVPixelBuffer) -> RefinedBall? {
        guard let rest = restBall else { return nil }
        let r = rest.semiMinor
        let box = CGRect(x: rest.centerU - 3 * r, y: rest.centerV - 3 * r, width: 6 * r, height: 6 * r)
        guard let crop = FrameConversion.luma(pixelBuffer, crop: box) else { return nil }
        let seedU = rest.centerU - Double(crop.originX)
        let seedV = rest.centerV - Double(crop.originY)
        guard let found = BallRefiner.refine(image: crop.image, seedU: seedU, seedV: seedV, expectedRadius: r),
              found.confidence >= 0.35,
              hypot(found.centerU - seedU, found.centerV - seedV) < 0.5 * r,
              abs(found.semiMinor / r - 1) < 0.2 else { return nil }
        var shifted = found
        shifted.centerU += Double(crop.originX)
        shifted.centerV += Double(crop.originY)
        return shifted
    }
}

// MARK: - Frame delivery

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let (width, height) = FrameConversion.dimensions(pixelBuffer)
        frameCounter += 1

        if intrinsicsSource != "camera", let k = FrameConversion.intrinsics(from: sampleBuffer, width: width, height: height) {
            intrinsics = k
            intrinsicsSource = "camera"
        }

        if let tap = pendingTap {
            pendingTap = nil
            handleTap(tap, pixelBuffer: pixelBuffer, width: width, height: height)
        }

        if let recorder {
            recorder.append(sampleBuffer)
            if recordingStartPTS == nil { recordingStartPTS = pts }
            recordingFrameCount += 1
            let elapsed = pts - (recordingStartPTS ?? pts)
            monitorRecording(pixelBuffer: pixelBuffer, elapsed: elapsed)
            if stopRequested || elapsed > maxRecordingSeconds || (kickTime.map { elapsed > $0 + postKickDuration } ?? false) {
                finishRecording(width: width, height: height, duration: elapsed)
            }
            return
        }

        // Preview: re-check the locked ball ~15 times a second.
        if restBall != nil, frameCounter % max(1, Int(activeRate / 15)) == 0 {
            updateChecks(ball: checkRestBall(pixelBuffer), intrinsics: intrinsics, timestamp: pts)
        } else if restBall == nil, frameCounter % max(1, Int(activeRate / 5)) == 0 {
            updateChecks(ball: nil, intrinsics: intrinsics, timestamp: pts)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if recorder != nil { droppedFrames += 1 }
    }

    private var activeRate: Double {
        device.map { 1 / max($0.activeVideoMinFrameDuration.seconds, 1.0 / 240) } ?? 240
    }

    /// Time kept after the ball leaves its spot: enough flight to fit.
    private var postKickDuration: Double { recordingMode == .shot ? 1.2 : 1.0 }

    private func handleTap(_ devicePoint: CGPoint, pixelBuffer: CVPixelBuffer, width: Int, height: Int) {
        guard let full = FrameConversion.luma(pixelBuffer) else { return }
        let tap = ImagePoint(u: Double(devicePoint.x) * Double(width), v: Double(devicePoint.y) * Double(height))
        let ball = BallLocator.locate(in: full.image, near: tap)
        restBall = ball
        let k = intrinsics
        DispatchQueue.main.async {
            self.lockedBall = ball
            self.lastTapMissed = ball == nil
            self.statusText = ball == nil
                ? "Couldn't find a ball there. Tap right on the ball."
                : "Ball locked. Check the list, then press Start."
        }
        lastPublish = 0
        updateChecks(ball: ball, intrinsics: k, timestamp: CACurrentMediaTime())
    }

    /// During recording: watch the resting ball ~60 times a second. When it
    /// has left its spot, note the time; recording then stops automatically.
    private func monitorRecording(pixelBuffer: CVPixelBuffer, elapsed: Double) {
        let step = max(1, Int(activeRate / 60))
        guard kickTime == nil, recordingFrameCount % step == 0 else {
            publishRecordingTime(elapsed)
            return
        }
        if checkRestBall(pixelBuffer) != nil {
            restSeenAt = elapsed
            restMissingSince = nil
        } else if let seen = restSeenAt {
            if restMissingSince == nil { restMissingSince = elapsed }
            // Gone for 50 ms: the kick (or release) happened just after it was last seen.
            if let since = restMissingSince, elapsed - since >= 0.05 {
                kickTime = seen
                DispatchQueue.main.async { self.statusText = "Ball in flight…" }
            }
        }
        publishRecordingTime(elapsed)
    }

    private func publishRecordingTime(_ elapsed: Double) {
        if recordingFrameCount % 24 == 0 {
            DispatchQueue.main.async { self.recordingSeconds = elapsed }
        }
    }

    private func finishRecording(width: Int, height: Int, duration: Double) {
        guard let recorder, let rest = restBall else { return }
        self.recorder = nil
        let gravity = recordingGravity
        let k = intrinsics ?? CameraIntrinsics.fromHorizontalFieldOfView(degrees: 73, width: width, height: height)
        let metadata = CaptureMetadata(
            mode: recordingMode, width: width, height: height, requestedFrameRate: activeRate,
            intrinsics: k, intrinsicsSource: intrinsicsSource,
            gravity: gravity ?? Vec3(0, 9.80665, 0), gravityMeasured: gravity != nil,
            exposureDurationSeconds: exposureAtStart.duration, iso: exposureAtStart.iso,
            frameCount: recordingFrameCount, droppedFrames: droppedFrames,
            encoderSkippedFrames: recorder.skippedFrames, duration: duration, kickTime: kickTime,
            restPoint: ImagePoint(u: rest.centerU, v: rest.centerV), restSemiMinor: rest.semiMinor)
        DispatchQueue.main.async {
            self.phase = .finishing
            self.statusText = "Saving…"
        }
        restoreAutoExposure()
        recorder.finish { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.phase = .previewing
                self.statusText = "Ball locked. Check the list, then press Start."
                if let error {
                    self.onRecordingFinished?(.failure(error))
                } else {
                    self.onRecordingFinished?(.success(FinishedRecording(clipURL: recorder.url, metadata: metadata)))
                }
            }
        }
    }
}
