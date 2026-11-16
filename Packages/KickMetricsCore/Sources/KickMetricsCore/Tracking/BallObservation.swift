import Foundation

/// One ball candidate produced by a detector in one frame.
public struct BallObservation: Sendable, Equatable, Codable {
    /// Frame presentation timestamp in seconds (from the capture clock, not an
    /// assumed frame interval).
    public var timestamp: Double
    /// Ellipse centre in pixels, native buffer orientation.
    public var centerU: Double
    public var centerV: Double
    /// Tangential (minor) semi-axis in pixels. This is the size measurement used
    /// for distance; see `SphereProjection`. Motion blur stretches the ball along
    /// its direction of travel, which also leaves the minor axis closest to the
    /// true size.
    public var semiMinor: Double
    /// Major semi-axis in pixels, if the detector measured it.
    public var semiMajor: Double?
    /// Detector confidence in [0, 1].
    public var confidence: Double
    /// 1σ uncertainty of the centre position, pixels.
    public var centerSigma: Double
    /// 1σ uncertainty of `semiMinor`, pixels.
    public var radiusSigma: Double

    public init(
        timestamp: Double, centerU: Double, centerV: Double, semiMinor: Double,
        semiMajor: Double? = nil, confidence: Double,
        centerSigma: Double = 0.5, radiusSigma: Double = 0.5
    ) {
        self.timestamp = timestamp
        self.centerU = centerU
        self.centerV = centerV
        self.semiMinor = semiMinor
        self.semiMajor = semiMajor
        self.confidence = confidence
        self.centerSigma = centerSigma
        self.radiusSigma = radiusSigma
    }

    func distance(to other: BallObservation) -> Double {
        hypot(centerU - other.centerU, centerV - other.centerV)
    }

    func distance(u: Double, v: Double) -> Double {
        hypot(centerU - u, centerV - v)
    }
}

/// All ball candidates detected in one frame (possibly none).
public struct FrameCandidates: Sendable, Equatable, Codable {
    public var timestamp: Double
    public var candidates: [BallObservation]

    public init(timestamp: Double, candidates: [BallObservation]) {
        self.timestamp = timestamp
        self.candidates = candidates
    }
}

/// A point in the image, pixels.
public struct ImagePoint: Sendable, Equatable, Codable {
    public var u: Double
    public var v: Double

    public init(u: Double, v: Double) {
        self.u = u
        self.v = v
    }
}

/// An observation the tracker accepted as the ball, with the phase it was in.
public struct TrackPoint: Sendable, Equatable, Codable {
    public enum Phase: String, Sendable, Codable {
        /// Ball resting on the kick spot.
        case rest
        /// Ball in flight after the kick.
        case flight
    }

    public var observation: BallObservation
    public var phase: Phase

    public init(observation: BallObservation, phase: Phase) {
        self.observation = observation
        self.phase = phase
    }
}
