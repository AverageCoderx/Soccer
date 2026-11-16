import Foundation
import SoccerTrackerCore
import SwiftData

/// One recorded shot or drop test, saved on the device.
@Model
final class ShotRecord {
    enum Kind: String, Codable {
        case shot
        case dropTest
    }

    var id: UUID
    var date: Date
    var kindRaw: String
    var isMeasured: Bool

    // Shot results (SI units), present only when measured.
    var maxSpeedMPS: Double?
    var maxSpeedSigma: Double?
    var averageSpeedMPS: Double?
    var averageSpeedSigma: Double?
    var confidenceRaw: String?
    var outOfPlaneAngle: Double?
    var distanceMeters: Double?

    // Drop-test results.
    var measuredGravity: Double?
    var gravitySigma: Double?

    var unavailableReasons: [String]
    var warnings: [String]
    var frameRate: Double
    var ballName: String

    /// Independent reference entered by the user (e.g. a radar gun), mph.
    var referenceMPH: Double?

    /// File names inside the app's Documents/Shots folder.
    var clipFileName: String?
    var reportFileName: String?

    init(kind: Kind, date: Date = .now, frameRate: Double, ballName: String) {
        id = UUID()
        self.date = date
        kindRaw = kind.rawValue
        isMeasured = false
        unavailableReasons = []
        warnings = []
        self.frameRate = frameRate
        self.ballName = ballName
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .shot }
    var confidence: MeasurementConfidence? { confidenceRaw.flatMap(MeasurementConfidence.init(rawValue:)) }

    var maxSpeed: SpeedEstimate? {
        guard let v = maxSpeedMPS, let s = maxSpeedSigma else { return nil }
        return SpeedEstimate(metersPerSecond: v, uncertainty: s)
    }

    var averageSpeed: SpeedEstimate? {
        guard let v = averageSpeedMPS, let s = averageSpeedSigma else { return nil }
        return SpeedEstimate(metersPerSecond: v, uncertainty: s)
    }

    var clipURL: URL? { clipFileName.map { Storage.shotsDirectory.appendingPathComponent($0) } }
    var reportURL: URL? { reportFileName.map { Storage.shotsDirectory.appendingPathComponent($0) } }
}

enum Storage {
    static var shotsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
