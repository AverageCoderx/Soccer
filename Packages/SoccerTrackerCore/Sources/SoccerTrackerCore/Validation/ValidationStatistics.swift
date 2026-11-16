import Foundation

/// One comparison between the app and an independent reference (radar gun,
/// drop test, synthetic truth).
public struct ValidationSample: Sendable, Equatable, Codable {
    public var reference: Double
    public var measured: Double

    public init(reference: Double, measured: Double) {
        self.reference = reference
        self.measured = measured
    }

    public var error: Double { measured - reference }
    public var absoluteError: Double { abs(error) }
    public var percentError: Double { reference != 0 ? 100 * error / reference : .nan }
}

/// Agreement statistics between measured and reference speeds.
public struct ValidationSummary: Sendable, Equatable, Codable {
    public var count: Int
    /// Mean error (measured − reference): systematic bias.
    public var meanError: Double
    /// Sample standard deviation of the error.
    public var errorStandardDeviation: Double
    public var meanAbsoluteError: Double
    public var rootMeanSquareError: Double
    public var meanAbsolutePercentError: Double
    public var maxAbsolutePercentError: Double
    /// Bland–Altman 95% limits of agreement: bias ± 1.96·SD.
    public var limitsOfAgreement: ClosedRange<Double>

    public init?(_ samples: [ValidationSample]) {
        let valid = samples.filter { $0.reference > 0 && $0.measured.isFinite }
        guard !valid.isEmpty else { return nil }
        let n = Double(valid.count)
        let errors = valid.map(\.error)
        let mean = errors.reduce(0, +) / n
        let sd = valid.count > 1
            ? (errors.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / (n - 1)).squareRoot()
            : 0
        count = valid.count
        meanError = mean
        errorStandardDeviation = sd
        meanAbsoluteError = valid.map(\.absoluteError).reduce(0, +) / n
        rootMeanSquareError = (errors.map { $0 * $0 }.reduce(0, +) / n).squareRoot()
        meanAbsolutePercentError = valid.map { abs($0.percentError) }.reduce(0, +) / n
        maxAbsolutePercentError = valid.map { abs($0.percentError) }.max() ?? 0
        limitsOfAgreement = (mean - 1.96 * sd)...(mean + 1.96 * sd)
    }
}

public enum DropTest {
    /// Speed of a ball dropped from rest after falling `height` meters, ignoring
    /// drag (v = √(2gh)). Over the ~2 m of a drop test drag changes this by well
    /// under 1%.
    public static func impactSpeed(height: Double, gravity: Double = 9.81) -> Double {
        (2 * gravity * max(height, 0)).squareRoot()
    }
}
