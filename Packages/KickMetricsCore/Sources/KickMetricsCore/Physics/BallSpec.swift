import Foundation

/// Physical description of the ball. The diameter is the app's ruler: every
/// distance, and so every speed, scales with it, so its uncertainty feeds
/// straight into the speed uncertainty.
public struct BallSpec: Sendable, Equatable, Codable {
    public var name: String
    /// Circumference in meters.
    public var circumference: Double
    /// 1σ uncertainty of the circumference in meters.
    public var circumferenceSigma: Double
    /// Mass in kilograms (only affects air-drag deceleration).
    public var mass: Double

    public init(name: String, circumference: Double, circumferenceSigma: Double, mass: Double) {
        self.name = name
        self.circumference = circumference
        self.circumferenceSigma = circumferenceSigma
        self.mass = mass
    }

    public var diameter: Double { circumference / .pi }
    public var radius: Double { diameter / 2 }
    /// Relative 1σ uncertainty of the diameter (= relative uncertainty of the circumference).
    public var diameterRelativeSigma: Double { circumferenceSigma / circumference }
    public var crossSectionArea: Double { .pi * radius * radius }

    // Regulation ranges (IFAB Laws of the Game for size 5; common youth standards
    // for sizes 4 and 3). When the size is only known by its number, the
    // circumference is taken as the middle of the allowed range with a uniform
    // distribution over it: σ = half-range / √3.

    /// Size 5: circumference 68–70 cm (diameter ≈ 21.6–22.3 cm), mass 410–450 g.
    public static let size5 = BallSpec(name: "Size 5", circumference: 0.69,
                                       circumferenceSigma: 0.01 / 3.0.squareRoot(), mass: 0.43)
    /// Size 4: circumference 63.5–66 cm, mass 350–390 g.
    public static let size4 = BallSpec(name: "Size 4", circumference: 0.6475,
                                       circumferenceSigma: 0.0125 / 3.0.squareRoot(), mass: 0.37)
    /// Size 3: circumference 58.5–61 cm, mass 300–320 g.
    public static let size3 = BallSpec(name: "Size 3", circumference: 0.5975,
                                       circumferenceSigma: 0.0125 / 3.0.squareRoot(), mass: 0.31)

    /// A ball whose circumference was measured with a tape (±3 mm taken as 1σ).
    public static func measured(basedOn base: BallSpec, circumference: Double) -> BallSpec {
        BallSpec(name: "\(base.name) (measured)", circumference: circumference,
                 circumferenceSigma: 0.003, mass: base.mass)
    }
}
