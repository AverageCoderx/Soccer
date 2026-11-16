import Foundation

/// A speed with its 1σ standard uncertainty.
public struct SpeedEstimate: Sendable, Equatable, Codable {
    public var metersPerSecond: Double
    public var uncertainty: Double

    public init(metersPerSecond: Double, uncertainty: Double) {
        self.metersPerSecond = metersPerSecond
        self.uncertainty = uncertainty
    }

    public var mph: Double { SpeedUnits.mph(fromMetersPerSecond: metersPerSecond) }
    public var kmh: Double { SpeedUnits.kmh(fromMetersPerSecond: metersPerSecond) }
    public var uncertaintyMPH: Double { SpeedUnits.mph(fromMetersPerSecond: uncertainty) }
    public var uncertaintyKMH: Double { SpeedUnits.kmh(fromMetersPerSecond: uncertainty) }
    public var relativeUncertainty: Double { metersPerSecond > 0 ? uncertainty / metersPerSecond : .infinity }
}

public enum MeasurementConfidence: String, Sendable, Codable, Comparable {
    case low, medium, high

    public static func < (a: Self, b: Self) -> Bool {
        let order: [Self] = [.low, .medium, .high]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
}

/// Relative (fractional) 1σ contributions to the speed uncertainty.
public struct UncertaintyBreakdown: Sendable, Equatable, Codable {
    /// From pixel noise, propagated through the fit.
    public var statistical: Double
    /// From not knowing the ball's exact diameter.
    public var ballSize: Double
    /// From possible bias in how the detector measures the ball's edge.
    public var radiusBias: Double
    /// From focal-length error (only affects motion towards/away from the camera).
    public var focalLength: Double
    /// From the uncalibrated rolling-shutter readout time.
    public var rollingShutter: Double

    public var total: Double {
        (statistical * statistical + ballSize * ballSize + radiusBias * radiusBias
            + focalLength * focalLength + rollingShutter * rollingShutter).squareRoot()
    }
}

public struct SpeedReport: Sendable, Equatable {
    /// Highest speed of the fitted flight over the observed interval. For a kick
    /// this is at the first clean frame after the foot (drag only slows the
    /// ball afterwards); at 240 fps that's within a few ms of the ball leaving
    /// the foot, so it's directly comparable to a radar gun's peak reading.
    public var maxSpeed: SpeedEstimate
    /// Mean speed over the observed interval (distance travelled / time).
    public var averageSpeed: SpeedEstimate
    /// Timestamp of `maxSpeed`.
    public var timeOfMaxSpeed: Double
    /// Observed interval, timestamps.
    public var measuredInterval: ClosedRange<Double>
    public var confidence: MeasurementConfidence
    public var breakdown: UncertaintyBreakdown
}

public enum UnavailableReason: Sendable, Equatable, Codable {
    case ballNotFound
    case noFlightDetected
    case insufficientFlightData(observations: Int, duration: Double)
    case fitFailed
    case poorModelFit(reducedChiSquare: Double)
    case uncertaintyTooHigh(relative: Double)
    case shotTowardCamera(angleDegrees: Double)
    case implausibleResult

    public var explanation: String {
        switch self {
        case .ballNotFound:
            return "The ball wasn't found."
        case .noFlightDetected:
            return "No kick was detected."
        case let .insufficientFlightData(n, d):
            return String(format: "The ball was tracked for too short a time (%d frames, %.0f ms).", n, d * 1000)
        case .fitFailed:
            return "The ball's path couldn't be fitted."
        case let .poorModelFit(chi2):
            return String(format: "The tracked path doesn't match a ball in flight (fit quality %.1f).", chi2)
        case let .uncertaintyTooHigh(rel):
            return String(format: "The measurement is too uncertain (±%.0f%%).", rel * 100)
        case let .shotTowardCamera(angle):
            return String(format: "The shot went too directly toward or away from the camera (%.0f°). Set the camera more side-on.", angle)
        case .implausibleResult:
            return "The result was physically implausible, so it was discarded."
        }
    }
}

public enum ShotWarning: Sendable, Equatable, Codable {
    /// The ball wasn't seen resting before the kick.
    case noRestPhase
    /// Gravity direction came from an assumption, not the motion sensor.
    case gravityNotMeasured
    /// Rolling-shutter timing isn't calibrated and adds noticeable uncertainty.
    case rollingShutterUncalibrated(relative: Double)
    case observationsRejected(count: Int)
    case frameGaps(maxGapSeconds: Double)
    /// The shot had a large component toward/away from the camera; that part relies on size change.
    case largeOutOfPlaneMotion(angleDegrees: Double)

    public var explanation: String {
        switch self {
        case .noRestPhase:
            return "The ball wasn't seen resting before the kick."
        case .gravityNotMeasured:
            return "The motion sensor's gravity reading wasn't available; an assumed direction was used."
        case let .rollingShutterUncalibrated(rel):
            return String(format: "Camera line-by-line readout timing isn't calibrated (adds ±%.1f%%).", rel * 100)
        case let .observationsRejected(n):
            return "\(n) frame\(n == 1 ? "" : "s") didn't fit the ball's path and were ignored."
        case let .frameGaps(gap):
            return String(format: "Some frames were missing (largest gap %.0f ms).", gap * 1000)
        case let .largeOutOfPlaneMotion(angle):
            return String(format: "The shot went %.0f° toward or away from the camera; that part of the speed is less precise.", angle)
        }
    }
}

/// Diagnostics for the debug screen. Values here are fit internals, not results:
/// when the shot is unavailable they must not be shown as a measurement.
public struct FitDiagnostics: Sendable, Equatable {
    public var observationCount: Int
    public var rejectedCount: Int
    public var duration: Double
    public var reducedChiSquare: Double
    public var rmsCenterResidualPixels: Double
    public var rmsRadiusResidualPixels: Double
    public var fittedDragCoefficient: Double
    public var fittedExtraAcceleration: Vec3
    public var meanDistance: Double
    public var meanApparentRadiusPixels: Double
    public var outOfPlaneAngleDegrees: Double
    public var fitMaxSpeed: Double
    public var fitRelativeUncertainty: Double
}

public struct ShotAnalysis: Sendable {
    public enum Outcome: Sendable, Equatable {
        case measured
        case unavailable([UnavailableReason])
    }

    public var outcome: Outcome
    /// Present only when `outcome == .measured`.
    public var speed: SpeedReport?
    public var diagnostics: FitDiagnostics?
    public var restObservationCount: Int
    public var flightObservationCount: Int
    public var warnings: [ShotWarning]
    /// Fitted ball states at each used observation time (camera frame), for plotting.
    public var fittedTrajectory: [KinematicState]

    public var isMeasured: Bool { outcome == .measured }

    public var unavailableReasons: [UnavailableReason] {
        if case let .unavailable(r) = outcome { return r }
        return []
    }
}
