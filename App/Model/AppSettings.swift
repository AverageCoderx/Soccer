import Foundation
import SoccerTrackerCore
import SwiftUI

/// User settings, stored with @AppStorage keys.
enum SettingsKey {
    static let ballSize = "ballSize"
    static let measuredCircumferenceCM = "measuredCircumferenceCM"
    static let frameRate = "frameRate"
    static let primaryUnit = "primaryUnit"
}

enum BallSizeOption: Int, CaseIterable, Identifiable {
    case size5 = 5, size4 = 4, size3 = 3
    var id: Int { rawValue }
    var label: String { "Size \(rawValue)" }

    var spec: BallSpec {
        switch self {
        case .size5: return .size5
        case .size4: return .size4
        case .size3: return .size3
        }
    }
}

enum SpeedUnit: String, CaseIterable, Identifiable {
    case mph, kmh
    var id: String { rawValue }
    var label: String { self == .mph ? "mph" : "km/h" }
}

enum AppSettings {
    /// The ball currently selected, using a tape-measured circumference if entered.
    static func ballSpec(defaults: UserDefaults = .standard) -> BallSpec {
        let size = BallSizeOption(rawValue: defaults.integer(forKey: SettingsKey.ballSize)) ?? .size5
        let circumference = defaults.double(forKey: SettingsKey.measuredCircumferenceCM)
        if circumference >= 40, circumference <= 80 {
            return .measured(basedOn: size.spec, circumference: circumference / 100)
        }
        return size.spec
    }

    static func frameRate(defaults: UserDefaults = .standard) -> Double {
        let value = defaults.double(forKey: SettingsKey.frameRate)
        return [60, 120, 240].contains(value) ? value : 240
    }
}

extension SpeedEstimate {
    func value(in unit: SpeedUnit) -> Double { unit == .mph ? mph : kmh }
    func uncertainty(in unit: SpeedUnit) -> Double { unit == .mph ? uncertaintyMPH : uncertaintyKMH }
}
