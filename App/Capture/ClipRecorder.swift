import AVFoundation

/// Writes camera frames to a movie file with the hardware HEVC encoder,
/// keeping the original presentation timestamps.
final class ClipRecorder {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private(set) var firstPTS: CMTime?
    private(set) var lastPTS: CMTime?
    private(set) var appendedFrames = 0
    private(set) var skippedFrames = 0

    init(url: URL, settings: [String: Any]?) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NSError(domain: "KickMetrics", code: 1, userInfo: [NSLocalizedDescriptionKey: "Can't set up the video writer."])
        }
        writer.add(input)
    }

    /// Called on the camera's video queue for every frame.
    func append(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer.status == .unknown {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: pts)
            firstPTS = pts
        }
        guard writer.status == .writing else { return }
        if input.isReadyForMoreMediaData, input.append(sampleBuffer) {
            appendedFrames += 1
            lastPTS = pts
        } else {
            skippedFrames += 1
        }
    }

    func finish(completion: @escaping (Error?) -> Void) {
        guard writer.status == .writing else {
            completion(writer.error ?? NSError(domain: "KickMetrics", code: 2,
                                               userInfo: [NSLocalizedDescriptionKey: "Nothing was recorded."]))
            return
        }
        input.markAsFinished()
        writer.finishWriting { [writer] in
            completion(writer.status == .completed ? nil : writer.error)
        }
    }
}
