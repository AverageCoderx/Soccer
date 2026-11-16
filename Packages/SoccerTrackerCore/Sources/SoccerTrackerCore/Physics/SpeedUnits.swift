import Foundation

public enum SpeedUnits {
    /// 1 mile = 1609.344 m exactly, so 1 m/s = 3600 / 1609.344 mph ≈ 2.2369 mph.
    public static let mphPerMeterPerSecond = 3600.0 / 1609.344
    public static let kmhPerMeterPerSecond = 3.6

    public static func mph(fromMetersPerSecond v: Double) -> Double { v * mphPerMeterPerSecond }
    public static func kmh(fromMetersPerSecond v: Double) -> Double { v * kmhPerMeterPerSecond }
}
