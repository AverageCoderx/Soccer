import AVFoundation
import KickMetricsCore

/// Runs the measurement pipeline on a recorded clip: decode every frame in
/// the window around the kick → detect ball candidates → track → fit.
enum ClipAnalyzer {
    struct Output {
        var shot: ShotAnalysis?
        var drop: ScaleCheckResult?
        var dropReasons: [UnavailableReason]
        var report: DebugReport
    }

    static func analyze(
        clip url: URL, metadata: CaptureMetadata, ball: BallSpec,
        progress: @escaping (Double) -> Void
    ) async throws -> Output {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "KickMetrics", code: 20, userInfo: [NSLocalizedDescriptionKey: "The recording has no video."])
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw NSError(domain: "KickMetrics", code: 21, userInfo: [NSLocalizedDescriptionKey: "Can't read the recording."])
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "KickMetrics", code: 22, userInfo: [NSLocalizedDescriptionKey: "Can't read the recording."])
        }

        // Analyse from a little before the ball left its spot until well into
        // the flight; with no live kick time, the last few seconds.
        let window: ClosedRange<Double>
        if let kick = metadata.kickTime {
            window = max(0, kick - 0.5)...(kick + 1.4)
        } else {
            window = max(0, metadata.duration - 4)...metadata.duration + 1
        }

        var detector = BallDetector()
        var tracker = ShotTracker(ballRadius: ball.radius, restHint: metadata.restPoint)
        var frames: [FrameCandidates] = []
        var firstPTS: Double?
        var restLocated = false

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if firstPTS == nil { firstPTS = pts }
            // Seconds since the clip's first frame, the same clock as `kickTime`.
            let t = pts - (firstPTS ?? pts)
            if t < window.lowerBound { continue }
            if t > window.upperBound { break }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
                  let luma = FrameConversion.luma(pixelBuffer) else { continue }

            if detector.restBall == nil {
                // Re-measure the resting ball on the first analysed frame (it
                // must be the same frame source as the rest of the analysis).
                if let found = BallLocator.locate(in: luma.image, near: metadata.restPoint),
                   hypot(found.centerU - metadata.restPoint.u, found.centerV - metadata.restPoint.v) < metadata.restSemiMinor {
                    detector.restBall = found
                    restLocated = true
                } else {
                    detector.restBall = RefinedBall(centerU: metadata.restPoint.u, centerV: metadata.restPoint.v,
                                                    semiMinor: metadata.restSemiMinor, semiMajor: metadata.restSemiMinor,
                                                    confidence: 0.5)
                }
            }

            let seeds = tracker.predictedPosition(at: t).map { [$0] } ?? []
            let candidates = detector.detect(luma.image, timestamp: t, extraSeeds: seeds)
            frames.append(candidates)
            tracker.process(candidates)

            let fraction = (t - window.lowerBound) / max(window.upperBound - window.lowerBound, 0.001)
            if frames.count % 12 == 0 { progress(min(0.99, fraction)) }
            if tracker.state == .finished { break }
        }
        reader.cancelReading()

        let context = ShotContext(intrinsics: metadata.intrinsics, ball: ball,
                                  gravity: metadata.gravity, gravityIsMeasured: metadata.gravityMeasured)
        let analyzer = ShotAnalyzer()
        var report = DebugReport(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            createdAt: Date(), ball: ball, metadata: metadata,
            analyzedFrom: frames.first?.timestamp ?? window.lowerBound,
            analyzedTo: frames.last?.timestamp ?? window.lowerBound,
            restLocated: restLocated, frames: frames, track: tracker.points,
            outcome: "unavailable", unavailableReasons: [], warnings: [])

        switch metadata.mode {
        case .shot:
            let analysis = analyzer.analyze(track: tracker.points, context: context)
            report.outcome = analysis.isMeasured ? "measured" : "unavailable"
            report.unavailableReasons = analysis.unavailableReasons.map(\.explanation)
            report.warnings = analysis.warnings.map(\.explanation)
            report.fit = analysis.diagnostics.map(DebugReport.FitSummary.init)
            report.breakdown = analysis.speed.map { DebugReport.Breakdown($0.breakdown) }
            report.maxSpeed = analysis.speed?.maxSpeed
            report.averageSpeed = analysis.speed?.averageSpeed
            progress(1)
            return Output(shot: analysis, drop: nil, dropReasons: [], report: report)
        case .dropTest:
            let (result, reasons) = analyzer.analyzeDropTest(track: tracker.points, context: context)
            report.outcome = (result != nil && reasons.isEmpty) ? "measured" : "unavailable"
            report.unavailableReasons = reasons.map(\.explanation)
            report.measuredGravity = result?.measuredGravity
            report.gravityUncertainty = result?.uncertainty
            report.gravityDirectionErrorDegrees = result?.directionErrorDegrees
            progress(1)
            return Output(shot: nil, drop: result, dropReasons: reasons, report: report)
        }
    }
}
