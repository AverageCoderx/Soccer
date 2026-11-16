import Foundation
import SoccerTrackerCore

/// Everything needed to understand (or re-run) one analysis. Saved as JSON
/// next to the clip; it contains measurement data only, no personal or
/// device-identifying information.
struct DebugReport: Codable {
    struct FitSummary: Codable {
        var observationCount: Int
        var rejectedCount: Int
        var duration: Double
        var reducedChiSquare: Double
        var rmsCenterResidualPixels: Double
        var rmsRadiusResidualPixels: Double
        var fittedDragCoefficient: Double
        var fittedExtraAcceleration: Vec3
        var meanDistance: Double
        var meanApparentRadiusPixels: Double
        var outOfPlaneAngleDegrees: Double
        /// The fit's speed. Only a measurement if `outcome` is "measured".
        var fitMaxSpeed: Double
        var fitRelativeUncertainty: Double
    }

    struct Breakdown: Codable {
        var statistical: Double
        var ballSize: Double
        var radiusBias: Double
        var focalLength: Double
        var rollingShutter: Double
        var total: Double
    }

    var appVersion: String
    var createdAt: Date
    var ball: BallSpec
    var metadata: CaptureMetadata
    var analyzedFrom: Double
    var analyzedTo: Double
    var restLocated: Bool
    var frames: [FrameCandidates]
    var track: [TrackPoint]
    var outcome: String
    var unavailableReasons: [String]
    var warnings: [String]
    var fit: FitSummary?
    var breakdown: Breakdown?
    var maxSpeed: SpeedEstimate?
    var averageSpeed: SpeedEstimate?
    var measuredGravity: Double?
    var gravityUncertainty: Double?
    var gravityDirectionErrorDegrees: Double?

    static func encode(_ report: DebugReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    static func load(from url: URL) -> DebugReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DebugReport.self, from: data)
    }
}

extension DebugReport.FitSummary {
    init(_ d: FitDiagnostics) {
        self.init(observationCount: d.observationCount, rejectedCount: d.rejectedCount, duration: d.duration,
                  reducedChiSquare: d.reducedChiSquare, rmsCenterResidualPixels: d.rmsCenterResidualPixels,
                  rmsRadiusResidualPixels: d.rmsRadiusResidualPixels, fittedDragCoefficient: d.fittedDragCoefficient,
                  fittedExtraAcceleration: d.fittedExtraAcceleration, meanDistance: d.meanDistance,
                  meanApparentRadiusPixels: d.meanApparentRadiusPixels, outOfPlaneAngleDegrees: d.outOfPlaneAngleDegrees,
                  fitMaxSpeed: d.fitMaxSpeed, fitRelativeUncertainty: d.fitRelativeUncertainty)
    }
}

extension DebugReport.Breakdown {
    init(_ b: UncertaintyBreakdown) {
        self.init(statistical: b.statistical, ballSize: b.ballSize, radiusBias: b.radiusBias,
                  focalLength: b.focalLength, rollingShutter: b.rollingShutter, total: b.total)
    }
}
